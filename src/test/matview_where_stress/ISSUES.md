# REFRESH MATERIALIZED VIEW ... WHERE ... — open review items

Branch-local tracking file. Not part of the patch; delete this directory before
posting to -hackers.

Two sections: items raised on the -hackers thread **[Patch] Add WHERE clause
support to REFRESH MATERIALIZED VIEW**, and items found separately that have not
been mentioned there. Each row names the test that covers it, so a fix shows up
as that test turning green.

**All of these are now fixed unless marked otherwise, and the whole suite is
green** — regress 249/249, isolation 135/135, injection_points 12/12,
pg_stat_statements 16/16, most recently on a `-O2 --enable-cassert` build with
the two `Assert()`s in `refresh_by_direct_modification()` live, run both with
`matview_partial_refresh_querytree` off and with it forced on. The State column
records what happened.

The **Disposition** column says whether a test is worth leaving in the tree once
its issue is fixed, or is scaffolding to remove then. The reasoning for each is
in a `Disposition:` comment on the test itself. Greps that find everything:

    grep -rn 'hackers' src/test/regress/sql/matview_where*.sql \
                       src/test/isolation/specs/matview-where-*.spec
    grep -rn 'Disposition:' src/test/regress/sql/matview_where*.sql \
                            src/test/isolation/specs/matview-where-*.spec \
                            contrib/pg_stat_statements/sql/utility.sql
    grep -rn 'XXX' src/test/regress/sql/matview_where*.sql

---

## A. Raised on the -hackers thread

| # | Item | Raised by | Test | State | Disposition |
|---|------|-----------|------|-------|-------------|
| A1 | `ON CONFLICT` target built from `indnatts`, so INCLUDE columns broke it | Dharin Shah | `matview_where` Test 10 | **fixed** — green, guard added | keep |
| A2 | "Subqueries -> Error" comment did not match the expected output; nothing forbids subqueries | Dharin Shah | `matview_where` Test 13 (second half) | **fixed** — green, guard added | keep |
| A3 | `DELETE`→`INSERT` left a consistency gap; tuple locks vanish after `DELETE` | Adam Brusselback | `matview-where-serialize.spec` | **fixed** — green, replaced by `FOR UPDATE` + fused CTE | keep |
| A4 | Scope drift promised to be fixed "in both the direct-modification and match/merge paths" | Adam Brusselback | `matview_where` Test 12 | **FIXED** — the diff insert now uses ON CONFLICT against the arbiter index | keep |
| A5 | Overlapping refreshes can deadlock; ORDER BY on the locking SELECT promised | Vellaipandiyan | `matview_where_stress/run.sh` (**red**, exits non-zero); `matview-where-deadlock.spec` (green, see below) | **FIXED for the single-statement variant** — the locking SELECT and the CTE now order by the arbiter key. Cross-statement ordering is the caller's, as with ordinary DML | delete the reproducer with this directory; replace or delete the spec |
| A6 | Predicate functions run with the owner's privileges, not the caller's | Zsolt Parragi | `matview_where_privs` Test 1 | **FIXED** — a non-leakproof predicate now requires ownership | keep |
| A7 | An error during refresh removes the matview modification restrictions | Zsolt Parragi | `matview_where_privs` Test 3 | **FIXED** — PG_TRY restores the flag | keep |
| A8 | `CONCURRENTLY` semantics are inverted for `WHERE`: the bare form is the more permissive one | Vellaipandiyan | `matview_where` Test 14 | **DONE** — CONCURRENTLY selects direct modification, the bare form match/merge | **REPLACE** — the swap has landed, so this condition has fired. It asserts a lock level (mechanism) rather than whether a writer blocks (guarantee), the same defect as Test 16 and the `pg_stat_statements` block. The behavioural version belongs beside `matview-where-serialize` |
| A9 | Document the intended safety model and the guarantees for overlapping refreshes | Dharin Shah, Vellaipandiyan | `matview-where-serialize.spec` covers the executable part | **FIXED for what it asked** — `refresh_materialized_view.sgml` now describes both forms, their lock levels and their deadlock behaviour; the false `ROW EXCLUSIVE` "blocks other modification commands" claim is gone. But see B15: the docs still say nothing about the hazard that matters most | keep the spec |

### On A5 and the two lock-ordering variants

The promised ORDER BY fixes only the variant the stress script reproduces: a
single refresh statement locking rows in plan order, so two refreshes with
different plans over overlapping rows deadlock. That script is the red assertion.

`matview-where-deadlock.spec` covers a second variant — two transactions each
issuing several single-row refreshes in opposite orders — which ORDER BY does not
help, because ordering within one statement says nothing about the order of
separate statements. That spec is deliberately green: the permutation violates
the stated guarantee, but no row-granularity locking can satisfy it, and under
the coarser lock that could, the permutation would not be drivable by
isolationtester at all. There is no correct output to assert until A8-adjacent
locking questions are settled.

Note that A8's test asserts the lock level each form takes, so implementing the
swap will change that spec's premise as well: after the swap it is the bare form
that takes ExclusiveLock, and this permutation would need rewriting around
whichever form still uses row locks.

### On B14, and what the evidence for it is

The safety harness crashed the server twice, both times on the same call:

    LOG:  client backend (PID 13304) was terminated by signal 11: Segmentation fault
    DETAIL:  Failed process was running: SELECT run_exh('proj_nonkey_union','concurrently')

Only the `CONCURRENTLY` form, which is the only one that uses these cached
plans. It has not reproduced since — three full harness runs of the corpus as it then stood, ~2800 refresh
cycles each, are clean before *and* after the fix — so **the crash is evidence
that something is wrong, not evidence that this was it**. What justifies the fix
is the code, which is wrong by construction whether or not it can be made to
crash on demand:

- `refresh_by_direct_modification()` takes `cacheEntry` from the hash table and
  holds it across `SPI_prepare`, `SPI_execute_plan` and the whole maintenance
  window, writing through it afterwards.
- `InvalidateMatViewCache()` ran `SPI_freeplan()` and `hash_search(HASH_REMOVE)`
  over **every** entry.
- Relcache callbacks fire at `CommandCounterIncrement()`, on lock acquisition,
  and during abort — all of which the refresh itself triggers, because it locks
  and writes the matview.

So an invalidation arriving mid-refresh put the entry back on dynahash's
freelist while a live pointer to it was still in use, and freed a `CachedPlan`
that could be the one executing. The callback also called `elog(ERROR)`, which
is not allowed during abort processing.

The fix is the pattern `plancache.c` uses: the callback only sets a flag, and
`matview_cache_sweep()` does the freeing at the start of the next partial
refresh, before any plan is taken. Sweeping every stale entry rather than only
the current one preserves B7 — plans belonging to dropped matviews are still
reclaimed. Behaviour is unchanged: all 36 harness shape-runs return identical
verdicts before and after, and regress 248/248, isolation 133/133 and
pg_stat_statements 16/16 are green.

### On B9, and why the thread settles it

Adam's own answer on the privilege escalation is the decisive fact:

> There's one plan, executed under one userid.  I can't run the (<view
> definition>) subquery as the owner and the WHERE (<predicate>) as the invoker,
> SPI executes the whole statement in whatever security context is active when
> it runs.  **So the predicate runs as the owner.**

A caller-supplied `search_path` combined with owner-context execution is the
CVE-2018-1058 shape exactly, and it is why `RestrictSearchPath()` exists and is
already used for `REFRESH`, index builds and maintenance commands generally.
Opening the path up would hand an unprivileged caller control over name
resolution inside a statement running as the matview's owner — reopening, by a
different route, the hole A6 closes.

Dharin's note on the thread points the same way rather than against it:

> the regression script has a comment "Subqueries -> Error" but the expected
> output shows no error for the **schema-qualified** subquery.

That is a complaint about the *comment*, not about the requirement — and he
found the escape hatch (qualify the names) without prompting. The requirement is
discoverable; what is not discoverable is *why* an unqualified name fails, since
today it surfaces as a bare `relation "f" does not exist`.

So: keep `RestrictSearchPath()`, document that predicates must schema-qualify
and say that it is a consequence of the predicate running as the owner, and give
the error an `errhint` pointing at qualification rather than leaving the user to
guess.

### On the fused CTE, and whether it can be split for speed

It cannot. Two plain statements measured 1.5× cheaper than the fused CTE
(20.7 vs 32.0 µs), but splitting reopens a consistency gap of the same family as
A3 — not the original `DELETE`→`INSERT` one, a second one that the fusion is
what closes. Demonstrated directly:

    matview and base both hold (1,10) (2,20) (3,30); base row 3 is then deleted,
    so a refresh over id 1..3 should prune it.  A concurrent session re-inserts
    base row 3 as (3,999) partway through the refresh.

    two statements:  mv row 3 = 30   <- stale, and neither statement corrects it
    fused CTE:       mv row 3 = 999  <- correct

At `READ COMMITTED` each statement takes its own snapshot, so the upsert sees a
base without row 3 and skips it, and the prune then sees a base *with* row 3 and
declines to delete it. The stale row survives both. The fused CTE computes
`new_data` once and has no such window. The `SELECT ... FOR UPDATE` does not
help: it locks matview rows, and the interfering write is to the base table.

That closes the largest of the scope-1 overheads. The `ORDER BY` inside
`new_data` (13%) is a separate question and is not obviously removable either:
the locking `SELECT` only covers matview rows that already exist and match the
predicate, so rows the refresh *inserts* take their locks in `new_data` order
and two concurrent refreshes inserting the same new keys could deadlock without
it.

### On B17: what a mutation test says about the gates

Four mutations, each the kind of change a performance pass would plausibly
make, against every gate in the tree:

| mutation | regress | isolation | oracle | A5 stress | a3 gap | verdict |
|---|---|---|---|---|---|---|
| M1 · drop `ORDER BY` from the row-locking `SELECT` | pass | pass | pass | **FAIL** after the fix below | pass | caught |
| M2 · drop `ORDER BY` from `new_data` | pass | pass | pass | pass | pass | **uncovered** |
| M3 · remove the row-locking `SELECT` entirely | pass | **FAIL** | pass | pass | pass | caught |
| M4 · `new_data` `NOT MATERIALIZED` | pass | pass | pass | pass | pass | **benign, nothing to catch** |

M4 is not a coverage gap. `NOT MATERIALIZED` inlines the CTE but keeps everything
in one statement, so base-table reads still share one snapshot and both
references see the same rows — it costs a second scan and changes nothing else.
Verified by driving the real `REFRESH` with a concurrent base-table insert
landing before it: pristine and mutated trees both produce the correct row
(`3|999`, zero divergence) and neither deadlocks. So the honest count is **one
genuinely uncovered mutation, M2**, not three.

Reading across the rest:

- **`regress` cannot see any of it.** All 22 tests are single-session; none of
  these mutations changes a single-session result.
- **The safety oracle cannot either**, for the same reason — it is a
  single-session differential harness by construction. It answers "is this
  predicate safe", not "is this refresh correct under concurrency".
- **`a3-split-gap.sh` did not catch M4**, which is the exact hazard it was
  written for. It hand-writes the two-statement SQL against a plain table
  rather than driving the real `REFRESH`, so it demonstrates the hazard without
  testing the product.
- **The A5 stress reproducer passed M1** — the mutation it exists to catch.
  Cause: it issued the bare form, and the A8 swap moved the row-locking
  `SELECT` to `CONCURRENTLY`. The test had been exercising a path that no
  longer contains the code it tests. Fixed by adding `CONCURRENTLY`, and
  verified as a detector rather than assumed: on the pristine tree it reports
  "no deadlocks in 80 refreshes" and exits 0; under M1 it reports "1 of 80
  refreshes aborted with a deadlock" and exits 1.

M1's silence was the useful result. A test that passes both with and without
the fix it was written for is worse than no test, because the tracker was
counting it as the red assertion for A5.

### This is expressible in the built-in suites

The gap is not a limitation of PostgreSQL's test infrastructure — it is a gap in
what has been written. Three built-in mechanisms, in ascending power:

1. **`isolationtester`** already covers anything expressible as step-at-a-time
   interleaving, and two specs here use it. What it cannot do is hold two
   sessions simultaneously *mid-statement*, which is exactly what M1 and M2
   need, because a partial refresh takes all its row locks inside one statement.

2. **Injection points** remove that limitation, and they are already in this
   tree: `src/test/modules/injection_points`, with **ten isolation specs**
   using them — including `heap_lock_update.spec` and `repack.spec`, which are
   the same class of problem (an intra-statement race in a heap-rewriting
   command). An `INJECTION_POINT()` between the row-locking `SELECT` and the
   CTE lets a spec park session A mid-refresh while session B acts, so M1 and
   M2 become deterministic isolation tests rather than a probabilistic shell
   loop. Requires `--enable-injection-points`, and the specs live under
   `src/test/modules/injection_points/specs/`, which `make check-world` runs.

3. **TAP tests** (`--enable-tap-tests`) can drive genuine parallelism via
   `background_psql`, which is what the stress reproducer does by hand. This is
   the fallback if a hazard resists being pinned to a single injection point.

So `src/test/matview_where_stress/run.sh` should not ship as a shell script at
all. Its logic belongs in an injection-point isolation spec, where it is
deterministic, runs under the standard suites, and does not depend on winning a
race often enough to notice.

### The three gates, and what each was proved to catch

All three are written and each was verified by failing under a mutation, not
assumed to work. B17 is closed.

| gate | property | mutation | result |
|---|---|---|---|
| `matview-where-lockorder.spec` (isolation) | the locking `SELECT` orders by the arbiter key | M1 · drop that `ORDER BY` | **fails in 60 ms**; the `locked` column inverts from rows 1-5 to rows 6-10 |
| `matview_where` Test 16 (regress) | `new_data` orders by the arbiter key | M2 · drop that `ORDER BY` | **fails**; insert order goes `{11..20}` → `{20..11}` |
| `matview-where-snapshot.spec` (injection points) | the row locks are held **before** the CTE runs | M6 · move the locking `SELECT` after the CTE | **fails**; the overlapping refresh stops reporting `<waiting ...>` |
| `pg_stat_statements` `utility` | the *shape* of what a refresh issues | M4 · `new_data NOT MATERIALIZED` | **fails**; `new_data_is_materialised` flips to `f` — **but this gate has since been deleted**; see below |

### On the fourth gate, and why an analogy was not good enough

`a3-split-gap.sh` demonstrates that splitting the fused CTE reopens a
consistency gap, but it hand-writes the two-statement SQL against a plain table
— it never runs `REFRESH`. That is fine as a demonstration and useless as a
regression gate: the analogy drifts silently the moment the implementation it is
imitating changes, which is precisely what a performance pass does.

The split hazard also cannot be tested behaviourally on unsplit code. It needs a
concurrent write landing *between* the upsert and the prune, and on the current
implementation those are one statement — there is no "between" to inject into. A
test asserting that hazard could only exist on code that already has the bug.

What is testable is the *structure*, through the real command. With
`pg_stat_statements.track = 'all'`, the statements a refresh issues internally
become visible, so the implementation's shape can be asserted directly:

    nested_statements          2      splitting the CTE makes it 3
    locking_select_is_ordered  t      A5's ORDER BY
    new_data_is_materialised   t      A3's single evaluation
    upsert_and_prune_are_fused t      A3's single statement
    new_data_is_ordered        t      insert-order locking

That is white-box, and **that turned out to be the defect, not the point.**

The requirement is single evaluation, not a CTE. A test matching the literal
text `new_data AS MATERIALIZED` goes red against any correct implementation that
delivers the same guarantee another way — one `ModifyTable` plan, a tuplestore
read twice — which makes it obstructive rather than merely fragile. A gate that
fails when the work is done properly is worse than no gate.

M4 is not evidence the gate earns its place; it is evidence the gate is watching
the mechanism. M4 is behaviourally benign, so nothing behavioural can see it —
but it is only *interesting* while the CTE is how the guarantee is delivered.
The invariant belongs as an `Assert()` where the guarantee is established.

`PLAN.md` scheduled this block for deletion at the **start** of the Query-tree
work, and that is where it went — the opening commit of Phase 2, ahead of any
change to `matview.c`. M4 consequently has no detector left anywhere, which is
the intended end state: both calibrated instruments already recorded it as
`MISSED`, and the only thing that ever saw it was an assertion on the mechanism
it removes.

`PLAN.md` also restates the three guarantees as properties (P1 single
evaluation, P2 and P3 deterministic lock order) with a note on which gates are
property-level. When that was written only the `xmax` spec was; since Phase 1,
`matview-where-insertorder.spec` is too, and P1's is behavioural rather than
structural (`fuzz.sh` `serial`).

Two things went wrong on the way to these and are worth not repeating.

**The obvious lock-order design cannot work.** A third session probing each end
with a competing refresh cannot be ordered to terminate: whichever probe
succeeds holds a row the blocked refresh still needs, so the permutation stalls
in one of the two cases. The first version did exactly that and hung for 720
seconds under M1 — a far worse failure than a diff. Reading `xmax` off the heap
works because the observer takes no lock anyone wants.

**The first snapshot spec was a characterisation test that could not fail.** It
parked a refresh at the injection point, landed a base change, and pinned the
resulting state — and passed identically under M6, because the CTE runs after
the injection point either way and so sees the change either way. Adding an
overlapping refresh that must block while the first is parked turned it into a
detector: that step can only wait if the locks are already held when the
injection point is reached, which is exactly the A3 property. The lesson from
the A5 reproducer applies to tests you just wrote, not only to old ones.

---

## B. Not mentioned on the thread

| # | Item | Test | Notes | Disposition |
|---|------|------|-------|-------------|
| B1 | Cached plans re-resolve relations by name. After a rename, or once another relation takes the old name, a refresh reports success, leaves its own target untouched, and **writes to a different matview** — with no lock and no `MAINTAIN` check taken there | `matview_where_cache` Tests 1–2 | **FIXED** — a relcache callback drops cached plans | delete if the plan cache goes away; keep as invalidation guards if it stays |
| B2 | Same hazard through the view definition: after a base-table rename the matview fills from an unrelated table and diverges from its own `pg_get_viewdef()` | `matview_where_cache` Test 3 | **FIXED** — same callback | n/a |
| B3 | Parameter types are not in the cache key and `pg_get_expr()` does not render them, so predicates differing only in parameter type share an entry and the **wrong rows are refreshed**, silently | `matview_where_cache` Test 4 | **FIXED** — argument types are part of the cache key | keep — asserts the refresh acts on the rows its predicate identifies, cache or no cache |
| B4 | A nullable unique key makes every refresh duplicate the NULL-keyed rows: `ON CONFLICT` never arbitrates on NULL, the anti-join's `IS NOT DISTINCT FROM` always matches it | `matview_where` Test 11 | **FIXED** — the anti-join operator now follows the arbiter index's NULL handling, which also removes an O(n^2) nested loop | keep |
| B5 | The predicate is evaluated inside the maintenance window, so a predicate function can modify **any** matview in the database | `matview_where_privs` Test 2 | **FIXED** — the exemption is scoped to the matview being refreshed | keep |
| B6 | With more than one unique index, `direct_mod` can collide on a non-arbiter index and reject a row set that both the full and the concurrent refresh accept | `matview_where` Test 15; `safety/` case 20 `two_ukeys` | **DOCUMENTED LIMITATION** — direct modification cannot; the bare form can. Now also **visible to the oracle**: the corpus could not express two unique indexes at all until `probe_exh` grew a `ukey2`, so the 1.1c calibration recorded B6 as MISSED for a reason no new case could fix. With case 20 the B6 mutation is CAUGHT, as `errs` 0→12 rather than as divergence — the wrong arbiter inserts a duplicate key that collides inside the same statement | keep |
| B7 | Cache entries are never invalidated or freed — no relcache callback, no `HASH_REMOVE`. Leaks saved plans for dropped matviews, and underlies B1–B3 | none | **FIXED** by the relcache callback | n/a |
| B8 | Rowcount handed to `SetQueryCompletion()` is `SPI_processed` after the fused CTE, whose top statement is the `DELETE` — so `pg_stat_statements` sees deletions only | `contrib/pg_stat_statements` `utility` | **FIXED** — both forms report rows written; they differ because match/merge applies a change as delete+insert | keep |
| B9 | The predicate is analyzed under `RestrictSearchPath()`, so callers must schema-qualify everything | `matview_where` Test 13 (first half); `safety/cases2.sql` case `dim_change_fixed` | **RESOLVED — keep the restriction.** It is load-bearing, not incidental; see below. What changes is the documentation and the error message, not the behaviour | keep the test as an assertion of the documented requirement |
| B10 | The volatility check is a weaker guarantee than the patch claims — a STABLE wrapper around a VOLATILE body passes, which is how both A6 and B5 work | covered indirectly by A6 / B5 | Worth a doc note either way | n/a |
| B11 | Index opened `AccessShareLock` at `matview.c:1063`, closed `NoLock` at `:1126`, with no comment saying the lock is meant to be held (unlike `:1466`) | none | Cosmetic | n/a |
| B12 | `opt_refresh_where_clause` duplicates the existing `where_clause` production; its `ereport` has no `parser_errposition()` | none | Cosmetic | n/a |
| B13 | `SetMatViewPopulatedState()`'s new early return also changes the full-rebuild path: it now skips the `pg_class` update *and* the `CommandCounterIncrement()` | none | Only two callers, both benign, but it should be called out rather than slipped in | n/a |
| B17 | **The test suite does not protect a performance phase.** Four mutations of the kind an optimizer would plausibly write were injected; three passed every gate. Detail below | mutation matrix in `safety/` notes; now `fuzz.sh` + `calibrate-fuzz.sh` | **CLOSED for the development phase** — `fuzz.sh` catches all four (M1 76/160 deadlocks, M2 40/80, M3 45 lost updates, M6 55) and is quiet on pristine. M2, recorded here as the one mutation no gate caught, is now the most strongly detected of the four. Not closed for the *shipped* suite: the fuzzer is probabilistic and is deleted at Phase 4, so the deterministic tests it is meant to write still have to be written | n/a |
| B16 | **A refresh may cost ~12x more when each one commits.** 300 scope-1 refreshes in a single transaction measured 82.8 us each; the same 300 via pgbench, one transaction each with `synchronous_commit=off`, measured 970 us. Not yet isolated. The candidate worth checking first: a partial refresh writes to the matview, that write sends a relcache invalidation, the invalidation marks every plan-cache entry stale, and the *next* refresh's `matview_cache_sweep()` then discards them -- so a drain process committing per refresh would re-plan every single time while a trigger inside one transaction never does | `bench/` reproduces it | **OPEN, unconfirmed** — if it holds it affects every D2 drain pattern in USE-CASES.md, and it predates B14 (the old callback did HASH_REMOVE, which has the same effect) | n/a |
| B15 | **The documentation does not mention blast radius.** A reader following `refresh_materialized_view.sgml` today will refresh a `rank() OVER (PARTITION BY ...)` matview by row key and silently corrupt it. Nor does it mention that a row leaving the predicate's scope is deleted, or that a non-deterministic view definition can diverge between partial and full refresh | `safety/` covers all three | **OPEN** — needs a decision, not just prose: warn, error, or document. `SAFETY.md` has the material and the measured cost of a static check | keep |
| B14 | **Use-after-free in the plan cache.** `InvalidateMatViewCache()` freed plans and `HASH_REMOVE`d entries from inside a relcache callback, while `refresh_by_direct_modification()` held a pointer to one of those entries across the whole maintenance window | found by `safety/run.sh`; no deterministic test | **FIXED** — the callback now only marks; `matview_cache_sweep()` frees at the next refresh. See below | keep the sweep |
| B20 | **`matview-where-deadlock.spec` is flaky.** Its expected output records *which* of the two sessions receives `ERROR: deadlock detected`, and that is the deadlock detector's choice of victim, not a property of the refresh. Observed failing once in six runs of an unchanged tree, which is exactly often enough to be blamed on whatever was committed most recently | `src/test/isolation/expected/matview-where-deadlock_1.out` | **FIXED** — alternative expected file, the standard mechanism for legitimately variable output. Both orderings are correct deadlock resolutions | keep both files |
| B19 | **The transformed `WHERE` clause never had collations assigned.** `transformRefreshWhereClause()` did not call `assign_expr_collations()`. Invisible for as long as the only thing done with the tree was to deparse it — the text goes back through the parser, which assigns them the second time round — so the omission was covered by the very round trip this rewrite exists to remove. Executing the tree directly fails on a predicate as ordinary as `tag = 'hot'` with "could not determine which collation to use". The corpus could not see it: all 21 shapes compared numbers | `safety/exh3.sql` case 22 `text_key`, which errors on all 48 of its mutations with the fix reverted | **FIXED** in `9a5195b` | keep the shape |
| B18 | **The oracle's own gate excluded the one shape that failed it.** `safety/exh.sql` case 7 `distincton` was labelled `SAFE` but diverges on 1 of its 96 mutations; the shape list in `checkall.sh` names `distincton_total` and omits `distincton`, so nothing ever looked at it. The divergence is not a defect — the view's `ORDER BY k, ts DESC` is a partial order, and case 13 is the same view with a total order and diverges zero times — but the label said one thing and the data said another for as long as both existed | `safety/exh.sql`; baseline recorded in `calibrate.baseline` | **FIXED** — relabelled `NONDET`, and `calibrate.sh` now compares against a recorded pristine vector instead of a hand-written shape list | keep the baseline file |
