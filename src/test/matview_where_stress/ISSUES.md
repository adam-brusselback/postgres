# REFRESH MATERIALIZED VIEW ... WHERE ... — open review items

Branch-local tracking file. Not part of the patch; delete this directory before
posting to -hackers.

Three sections: items raised on the -hackers thread **[Patch] Add WHERE clause
support to REFRESH MATERIALIZED VIEW**, items found separately that have not
been mentioned there, and designs that were considered and rejected. Each row in
the first two names the test that covers it, so a fix shows up as that test
turning green. Section C carries no tests of its own — it records why the shape
of the write path is what it is, because both of the obvious alternatives to it
will be proposed by a reviewer who has not read the whole thread.

**B14 is FIXED, for the second time, and this time with a test that has been
seen to fail.** Everything is fixed unless marked otherwise, and the declared
suite is green except for one pre-existing failure — regress 250/250, isolation
135/135, injection_points 5 regress + 13 specs, **pg_stat_statements 15/16 (B25, red since the
routing change and unrelated to B14 — verified by running it both ways)**, most
recently on a `-O2 --enable-cassert` build with
the two `Assert()`s in `refresh_by_direct_modification()` live.  (That clause
used to end "run both with `matview_partial_refresh_querytree` off and with it
forced on"; that GUC and the path it selected went in `82f71d8`, and the last
remaining GUC in `f93e664`.  There are no arms left to run.) The State column
records what happened.

The suite being green is not the same as the suite being a guard, and B14 is why
that sentence is here. It was green throughout, on an assertions build, while a
nested partial refresh could execute another matview's plan — no test in it
nested a refresh, so nothing could have caught it. The new test
(`matview_where_cache` Test 5) was written, run against the unfixed code, and
**passed**, for a reason that had nothing to do with the bug: `REFRESH` runs
under `RestrictSearchPath()`, the unqualified names in the nested function did
not resolve, the `ALTER TABLE` raised, the `EXCEPTION` block swallowed it and the
nested refresh never ran. Schema-qualifying the two names is what turned it into
a test. Both arms of the A/B are recorded below.

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
| A8 | `CONCURRENTLY` semantics are inverted for `WHERE`: the bare form is the more permissive one | Vellaipandiyan | `matview_where` Test 14 | **DONE** — and since superseded: routing is now by unique-index count, not by spelling.  Both spellings take direct modification on a matview with one unique index, and both take match/merge on one with more, because only match/merge can delete before it inserts | **REPLACE** — the swap has landed, so this condition has fired. It asserts a lock level (mechanism) rather than whether a writer blocks (guarantee), the same defect as Test 16 and the `pg_stat_statements` block. The behavioural version belongs beside `matview-where-serialize` |
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

### On B14 being reopened, and why the first fix was only half right

Half of it was right and is not in question: **an invalidation callback must not
free.** `plancache.c`'s own callbacks only ever set `is_valid = false`, and
`ri_triggers.c` states the rule outright — *"at the time a cache invalidation
message is processed there may be active references to the cache. Because of
this we never remove entries from the cache, but only mark them invalid."*

The other half — deferring the free to "the start of the next partial refresh,
before any plan is taken" — rests on an invariant that is false, and the code
says so in its own words at the sweep's call site:

> Afterwards nothing removes entries **until the next refresh**, so `cacheEntry`
> stays valid for the whole maintenance window.

A **nested** refresh is the next refresh. The predicate and the view definition
are both evaluated inside the maintenance window — B5 is the same observation
from the privileges angle, and the code comment there already says a predicate
function "could modify any matview in the database". Such a function can issue
`REFRESH MATERIALIZED VIEW ... WHERE`, which re-enters at the sweep before
anything can reject it.

There is **one** reachable free site, `matview_cache_sweep()`. It frees entries
the callback marked, and reaching it needs a relcache invalidation to have
arrived — any one, from anywhere, because `InvalidateMatViewCache()` ignores its
`relid` argument and marks every entry.

An earlier draft of this section named a second site, the mismatch branch that
frees `lockPlan`/`refreshPlan` when an entry's arbiter index or predicate text
differs from the caller's, and claimed it needed no invalidation because a
nested refresh of the *same* matview under a different predicate would reach it.
**That was wrong, and this file already contradicted itself about it** — the
reproducer notes below say same-matview nesting is stopped earlier. Checked by
running it: the nested call dies at `CheckTableNotInUse()` with *"cannot REFRESH
MATERIALIZED VIEW ... because it is being used by active queries in this
session"*, before any cache code. The mismatch branch only ever frees plans
under the OID its own caller passed, and that OID cannot be an enclosing
refresh's, so it is cache thrash — the two-callers-one-matview case, a row
trigger keyed `= $1` beside a statement trigger keyed `= ANY($1)` — and not a
memory-safety defect. The fix covers it regardless, being upstream of both.

What breaks is not protected by refcounting. `DropCachedPlan()` deletes
`plansource->context` and `SPI_freeplan()` deletes `plan->plancxt`, neither with
a refcount test — only the derived `CachedPlan` is refcounted. So
`_SPI_execute_plan`'s `foreach(lc1, plan->plancache_list)` iterates freed list
cells, and `spicallbackarg.query = plansource->query_string` stays on
`error_context_stack` pointing at freed memory.

Unlike the original B14, this reproduces deterministically on an
`--enable-cassert` build. Three symptoms, worst first:

1. **A refresh of `mv1` executes `mv2`'s cached plan.** dynahash hands the
   `HASH_REMOVE`d element straight back to the nested refresh while the outer
   still holds its pointer. In the reproducer it errored only because
   `matview_maintenance_relid` still named `mv1` — an incidental guard, not a
   defence. This is B1's failure mode ("writes to a different matview") arriving
   by a different route.
2. **A freed `query_string` printed by the error context**, one read landing
   mid-word in a reused buffer.
3. **SIGSEGV** in `_SPI_execute_plan`, with `l->elements` reading
   `0x7f7f7f7f7f7f7f7f` — the `CLOBBER_FREED_MEMORY` wipe pattern.

The reproducer needs four ingredients, each verified load-bearing:

- a relcache invalidation generator (`ALTER TABLE`; `ANALYZE` is not enough,
  since an in-place `pg_class` update queues its invalidation for commit),
- an `EXCEPTION` block so the nested failure does not unwind the outer refresh,
- two matviews — nesting the same one is stopped by `CheckTableNotInUse()`,
- **schema-qualified names inside the nested function.** `REFRESH` runs under
  `RestrictSearchPath()`, so an unqualified name does not resolve, the
  `ALTER TABLE` raises, the `EXCEPTION` block swallows it, and the nested
  refresh never runs. This is the one that made the first version of the
  regression test pass against the unfixed code.

### The fix, and what was verified about it

A refresh at `matview_maintenance_depth > 0` prepares private plans and touches
neither the hash table nor the entries in it. That is the shape `funccache.c`
documents — *"we can release the subsidiary storage, but **only if there are no
active evaluations in progress**. Otherwise we'll just leak that storage… a leak
seems acceptable"* — and which `evtcache.c` uses for the same situation: decline
to free while an operation is in progress. The private plans are not
`SPI_keepplan`'d, so `SPI_finish()` reclaims them; nesting is rare enough that
losing the cache there costs nothing. A per-entry use count would be more
precise and is not worth it for a case this rare. Separately, `cacheEntry`
should still not be held across execution at all.

The A/B, on one `-O2 --enable-cassert` build, flipping only `matview.c`:

| | unfixed (HEAD) | fixed |
|---|---|---|
| `matview_where_cache` Test 5 | **fails** — `ERROR: cannot change materialized view "mv_c4_inner"` from a refresh of `mv_c4`, and the outer's rows unapplied | passes |
| standalone reproducer, classic path | error-context frames print `0x7F` fill and the tail of the outer's own fused DML | every frame prints the outer's intact query string |
| full `installcheck` | 249/250 | 250/250 |
| `matview_where*` under `debug_discard_caches = 1` | — | **5/5**, first ever run of the suite that way (R25) |

Only the Query-tree arm of Test 5 fails on the unfixed code. The classic path
hands SPI its plan pointer once and never re-reads `cacheEntry`, so the freed
plan keeps executing and the damage surfaces as a garbage `query_string` or a
crash — neither of which can be written into an expected file. That is recorded
in the test itself, so nobody reads the classic arm as a detector.

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
| B2 | Same hazard through the view definition: after a base-table rename the matview fills from an unrelated table and diverges from its own `pg_get_viewdef()` | `matview_where_cache` Test 3 | **PARTIALLY FIXED.** The relcache callback covers renames of *relations*. The view definition also names functions, operators, types and schemas, and we register **one** callback where `plancache.c` registers **seven** — `PROCOID`, `TYPEOID`, `NAMESPACEOID`, `OPEROID`, `AMOPOPID` and two FDW ones besides the relcache one. So `ALTER FUNCTION f RENAME TO g` invalidates plancache's plan but not our entry; we keep serving cached SQL that still names `f`, and re-analysis binds it to whatever holds that name now. Test 3 does not cover a function rename **NOT scheduled inside 3.7 -- see CACHE.md §4.** An earlier plan pulled this ahead of 3.7 on the argument that the shotgun invalidation makes any cache measurement meaningless; PLAN.md 3.1 refutes that (300 committed refreshes, plans survive, `SPI_prepare` 0.79 us warm), and B16 adds that `ANALYZE` was not even sufficient to mark an entry stale. Four things must be solved before this can be attempted at all, none of which were written down: it **reopens B7** (the sweep is the only thing that reclaims a dropped matview's plans, and `HASH_REMOVE` appears nowhere else); gating on `SPI_plan_is_valid()` **detects without rebuilding**, and the regenerate path is gated on the plans being NULL, so stale text would be reused; the validity check is documented as trustworthy only once the caller holds the locks, and the base tables are not locked at that point; and the obvious fail-first **cannot fail** -- `whereClauseStr` is regenerated every call *and is the cache key*, so a renamed predicate function changes the key and forces a rebuild. The demonstrable route is the view definition, which is text only on the text path -- the path Phase 2's step 4 deletes, which may close this by subtraction. | keep, and extend to a function rename |
| B3 | Parameter types are not in the cache key and `pg_get_expr()` does not render them, so predicates differing only in parameter type share an entry and the **wrong rows are refreshed**, silently | `matview_where_cache` Test 4 | **FIXED** — argument types are part of the cache key | keep — asserts the refresh acts on the rows its predicate identifies, cache or no cache |
| B4 | A nullable unique key makes every refresh duplicate the NULL-keyed rows: `ON CONFLICT` never arbitrates on NULL, the anti-join's `IS NOT DISTINCT FROM` always matches it | `matview_where` Test 11 | **FIXED** — the anti-join operator now follows the arbiter index's NULL handling, which also removes an O(n^2) nested loop | keep |
| B5 | The predicate is evaluated inside the maintenance window, so a predicate function can modify **any** matview in the database | `matview_where_privs` Test 2 | **FIXED** — the exemption is scoped to the matview being refreshed | keep |
| B6 | With more than one unique index, `direct_mod` can collide on a non-arbiter index and reject a row set that both the full and the concurrent refresh accept | `matview_where` Test 15; `safety/` case 20 `two_ukeys` | **DOCUMENTED LIMITATION** — direct modification cannot; the bare form can. Now also **visible to the oracle**: the corpus could not express two unique indexes at all until `probe_exh` grew a `ukey2`, so the 1.1c calibration recorded B6 as MISSED for a reason no new case could fix. With case 20 the B6 mutation is CAUGHT, as `errs` 0→12 rather than as divergence — the wrong arbiter inserts a duplicate key that collides inside the same statement | keep |
| B7 | Cache entries are never invalidated or freed — no relcache callback, no `HASH_REMOVE`. Leaks saved plans for dropped matviews, and underlies B1–B3 | none | **FIXED** by the relcache callback | n/a |
| B8 | Rowcount handed to `SetQueryCompletion()` is `SPI_processed` after the fused CTE, whose top statement is the `DELETE` — so `pg_stat_statements` sees deletions only | `contrib/pg_stat_statements` `utility` | **FIXED** — both forms report rows written; they differ because match/merge applies a change as delete+insert | keep |
| B9 | The predicate is analyzed under `RestrictSearchPath()`, so callers must schema-qualify everything | `matview_where` Test 13 (first half); `safety/cases2.sql` case `dim_change_fixed` | **RESOLVED — keep the restriction, and the documentation half is now DONE.** It is load-bearing, not incidental; see below. `refresh_materialized_view.sgml` now states, on the `WHERE` parameter and beside the ownership rule it shares a cause with, that the condition is analyzed under the restricted `search_path` and so must schema-qualify what it names. **The `errhint` half is deliberately NOT done and is a decision, not an oversight**: the bare *relation "f" does not exist* is raised by parse analysis, so adding a hint means an `ErrorContextCallback` around `transformRefreshWhereClause()` — new code, in a pass whose brief was to remove rather than add. Worth doing; worth doing on purpose | keep the test as an assertion of the documented requirement |
| B10 | The volatility check is a weaker guarantee than the patch claims — a STABLE wrapper around a VOLATILE body passes, which is how both A6 and B5 work | covered indirectly by A6 / B5 | Worth a doc note either way | n/a |
| B11 | Index opened `AccessShareLock` at `matview.c:1063`, closed `NoLock` at `:1126`, with no comment saying the lock is meant to be held (unlike `:1466`) | none | Cosmetic | n/a |
| B12 | `opt_refresh_where_clause` duplicates the existing `where_clause` production; its `ereport` has no `parser_errposition()` | none | Cosmetic | n/a |
| B13 | `SetMatViewPopulatedState()`'s new early return also changes the full-rebuild path: it now skips the `pg_class` update *and* the `CommandCounterIncrement()` | none | Only two callers, both benign, but it should be called out rather than slipped in | n/a |
| B17 | **The test suite does not protect a performance phase.** Four mutations of the kind an optimizer would plausibly write were injected; three passed every gate. Detail below | mutation matrix in `safety/` notes; now `fuzz.sh` + `calibrate-fuzz.sh` | **CLOSED for the development phase** — `fuzz.sh` catches all four (M1 76/160 deadlocks, M2 40/80, M3 45 lost updates, M6 55) and is quiet on pristine. M2, recorded here as the one mutation no gate caught, is now the most strongly detected of the four. Not closed for the *shipped* suite: the fuzzer is probabilistic and is deleted at Phase 4, so the deterministic tests it is meant to write still have to be written | n/a |
| B16 | **A refresh may cost ~12x more when each one commits.** 300 scope-1 refreshes in a single transaction measured 82.8 us each; the same 300 via pgbench, one transaction each with `synchronous_commit=off`, measured 970 us | `bench/run.sh --perxact` | **MEASURED, and the named candidate is disproven.** The re-planning mechanism guessed at here requires a partial refresh to emit a relcache invalidation; it does not, because `SetMatViewPopulatedState()` early-returns when the state already matches, and an in-place `pg_class` update queues its invalidation for commit anyway rather than delivering it mid-transaction. Confirmed incidentally while building the B14 reproducer: `ANALYZE` was *not* sufficient to mark an entry stale mid-transaction; forcing it needed an `ALTER TABLE`. What `--perxact` then measured is the axis itself: **RESULTS.md R7**, smaller and more interesting than the 12x suggested. It *inverts* above scope 100, because 20 rewrites of one scope inside one transaction build update chains nothing can prune until it commits. So D1 is not "D2 minus the commit", and a statement trigger firing repeatedly against a large scope is this feature's worst case | n/a |
| B15 | **The documentation does not mention blast radius.** A reader following `refresh_materialized_view.sgml` today will refresh a `rank() OVER (PARTITION BY ...)` matview by row key and silently corrupt it. Nor does it mention that a row leaving the predicate's scope is deleted, or that a non-deterministic view definition can diverge between partial and full refresh | `safety/` covers all three | **FIXED, and the decision was DOCUMENT rather than warn or error.** All three now appear on the reference page: a `<warning>` on the `WHERE` parameter stating that the condition must cover every row whose *output* changes rather than every row whose input changed, with the window-function case spelled out and the push-down proxy given as a self-check (and labelled a proxy, since a scalar-subquery share pushes down perfectly and is still wrong); a paragraph on scope drift; and a paragraph on non-determinism.  Both behavioural claims were run rather than transcribed — `WHERE status = 'open'` after the row closes deletes it, and naming both values updates it.  **Why not error:** the check SAFETY.md designs is sound but *incomplete*, and refuses `except_key`, which is exhaustively safe at 0/64.  A restriction is far harder to withdraw than to add, so shipping an incomplete refusal in v1 forecloses valid use cases permanently.  Cost is **not** the objection and should not be offered as one — conditions 1-3 are functions of the cache key and free on a hit.  **Why not warn:** it would fire on the safe-but-unprovable cases too, which trains people to filter it, and in a row-trigger loop it is per-refresh noise.  **And the decisive point: no `REFRESH`-time check can see the failure that actually bites.**  Coverage (SAFETY.md §5) — the driver naming the wrong rows — is outside anything the command can detect, because it is not told what changed; two of the four "pushed but unsafe" cases in the planner-signal table are exactly that.  So the static check goes on-list as a follow-on with its analysis and its measured cost attached, which is Phase 7's rule about naming unresolved decisions rather than burying them | keep |
| B14 | **Use-after-free in the plan cache.** `InvalidateMatViewCache()` freed plans and `HASH_REMOVE`d entries from inside a relcache callback, while `refresh_by_direct_modification()` held a pointer to one of those entries across the whole maintenance window | `matview_where_cache` Test 5 | **FIXED, twice.** The callback marking rather than freeing was necessary and correct; deferring the free to "the next refresh" was not, because **a nested refresh is the next refresh**. Confirmed by execution on an assertions build, three symptoms, worst first: a refresh of `mv1` executing `mv2`'s cached plan; `_SPI_error_callback` printing a freed `query_string`; SIGSEGV in `_SPI_execute_plan`. Now closed by refusing the shared cache at maintenance depth > 0, with a test seen to fail against the unfixed code. See below | keep. It is the only test in the tree that nests a refresh, which is the gap that let this survive the first fix |
| B28 | **The match/merge path is never exercised with a name that needs quoting.** Q2 removes the quoting of the matview name on that path and **no instrument catches it**: the path is reached (`mv_multi2` pins the routing rule with two unique indexes) but only ever with plain lowercase identifiers, so unquoted output is still valid SQL. Q1 and Q3 are both caught, so the direct-modification path is covered and this is the one gap | `matview_where_inject` **Test 9** | **FIXED.** Found by `calibrate-all.sh`: Q2 was quiet in all four instruments. Test 9 gives a hostile-named matview **two** unique indexes, which is what routes it to match/merge, and refreshes it with a predicate. Seen to fail: with Q2 applied the generated SQL raises `unterminated quoted identifier`; pristine is green | keep |
| B27 | **The row comparison is never exercised against a NULL.** B7 changes it from `IS DISTINCT FROM` to `<>`, which differ only when a value is NULL, and **no instrument catches it**. The comparison did run in other cases, but their data has no NULLs, so the two operators agree on every row. The failure this hides is silent: a NULL-valued row would never be updated | `matview_where` **Test 17** | **FIXED.** Found by `calibrate-all.sh`: B7 was quiet in all four instruments. Test 17 adds a nullable non-key column and refreshes it **both** ways -- NULL to value and value to NULL -- because the two fail differently and a test doing one catches one. Seen to fail: with B7 applied, id 1 stays NULL and id 2 stays 20; pristine is green, 250/250 | keep |
| B30 | **Nothing distinguishes the row comparison from its absence.** B27 gave it a NULL case, which is what a wrong *operator* corrupts. Neither that test nor any other can see the comparison not being emitted at all: without it every matched row is rewritten, which is what the code did before `03cb4f0` and is still correct, so every value a test can read back is identical either way. `O1` forces exactly that -- `use_optimized` is an `&&` of two GUCs, and a rewrite dropping one leaves all the code in place and none of it reachable -- and it was **UNCAUGHT by all four instruments** | `matview_where` **Test 18** | **FIXED.** The optimisation's whole purpose is invisible in the contents, so Test 18 reads the heap: an UPDATE writes a new tuple at a new location, so a row that kept its `ctid` across the refresh is a row the refresh did not write. It asserts the contents too, because skipping *too much* is the other way to fail and looks identical in the `ctid` column. Verified as a detector: under `O1` every row comes back `f` | keep.  The `SET` lines went when the comparison became the default, the GUC itself in `f93e664`, and the case is unchanged by either -- the write-amplification promise outlives the flag |
| B31 | **DELETED with the GUC it was about** (`f93e664`); the row is kept because the reasoning below is what says the escape clause did not apply.  **The plan-cache key is not checked against the thing it exists for.** The key carries `querytree` and `optimized` because both change the SQL that gets prepared, and `O2` drops the second. Nothing noticed: the stale plan is still valid SQL refreshing exactly the right rows, and only the row versions it writes differ. **UNCAUGHT by all four instruments** | `matview_where_cache` **Test 6** | **FIXED**, on the second attempt, and the first attempt is the point. It warmed the entry, created a temp table to snapshot `ctid`s, then flipped the flag -- and passed under `O2`, because `InvalidateMatViewCache()` ignores its relid and marks every entry, so the `CREATE` had discarded the entry the case existed to reuse. The plan was rebuilt for the right reason by accident. Filling the snapshot table first fixes it. A refresh is **not** such an event -- verified under the mutation with only DML and a `SET` in between, the entry survived a refresh that rewrote every row in scope -- which agrees with **B16** | **DONE — deleted** with `matview_partial_refresh_optimized`.  The key HAS gained another such input, the predicate itself (B36), so the escape clause was live — but the case for it already existed as Test 7, which reads values rather than ctids because a confused predicate refreshes the wrong rows outright.  Rewriting Test 6 around the predicate would have duplicated it |
| B29 | **The arbiter search's usability test has no coverage.** `is_usable_unique_index()` rejects partial and expression unique indexes, and routing counts those as unique (`indisunique && indisvalid && indimmediate`), so a matview whose only unique index is rejectable does reach the partial-refresh path and must be turned away there. No test in the tree builds one | none | **OPEN.** Found while removing B26: the mutation that used to sit here targeted the dead primary-key preference, and once that was deleted there was nothing left to break except this check -- which has never been exercised. Needs the **bare** form, not `CONCURRENTLY`: the concurrent precondition raises from a different call site and fires first, so a `CONCURRENTLY` test never reaches the arbiter search. A `mutations.py` entry belongs here once the test exists, not before | add the case, then the mutation |
| B26 | **The primary-key preference in the arbiter search was dead code, in both copies.** `refresh_by_direct_modification()` and `matview_pick_arbiter_index()` each walked the index list preferring `indisprimary`. It can never be set: **a materialized view cannot have a primary key** — `ALTER MATERIALIZED VIEW ... ADD PRIMARY KEY` and `ALTER TABLE ... ADD PRIMARY KEY` both fail with *"This operation is not supported for materialized views"* — so every index a matview owns came from `CREATE INDEX` | none, by construction | **FIXED.** Both preferences deleted; each loop now takes the first usable index. Behaviour-identical, since without a PK the old code already took the first usable one. A narrower first explanation (routing guarantees at most one unique index) was true of one copy only and did not account for the other, which is why the reason recorded here is the one that was verified by running it. `mutations.py` B6 is deleted with it — see B29 for what remains untested | 250/250 green after |
| B25 | **`pg_stat_statements` `utility` has been red since the routing change, and this file said 16/16.** The case at `contrib/pg_stat_statements/sql/utility.sql:370` exists to show that the two spellings report different row counts for the same logical change -- 6 for the bare form, 3 for `CONCURRENTLY` -- because the bare form used diff/merge and applied a changed row as a delete plus an insert. Routing now keys on unique-index count rather than spelling (B21), `pgss_pr_matv` has one unique index, so **both** spellings take direct modification and both report 3. The expected file, the `rows` value and the three explanatory comments all still describe the old routing | `pg_stat_statements` `utility` (**red**) | **OPEN, and it is not a number bump.** Verified pre-existing: `make -C contrib/pg_stat_statements check` gives the identical one-line diff with and without B14's fix applied, so it predates this work rather than being caused by it. The case's premise -- that the counts differ -- is now false as written, so restating it means giving the diff/merge arm a matview with two unique indexes, which is what routes there today. Left red deliberately: correcting the count alone would make the suite green while the comments beside it still explain a mechanism the statement no longer uses | keep, restated. The count is part of the command's contract |
| B24 | **Eleven `XXX` markers described the behaviour of code that no longer existed.** Every one named a defect as present -- "currently errors", "currently allowed", "currently both succeed", "CONCURRENTLY still selects match/merge" -- while the expected output beside it recorded the fixed behaviour. A reader of the `.sql` files, which is where a -hackers reviewer starts, would conclude the feature was broken in eleven ways it is not. Found by building `c8beb05` to answer a different question and noticing the markers were describing *that* build | `matview_where`, `matview_where_cache`, `matview_where_privs` | **FIXED** -- markers removed or rewritten to say what the pre-fix behaviour was and why the case exists. The file headers no longer claim unfixed defects they do not have. Comment-only, plus one `\set VERBOSITY` guard that existed to shorten an error that no longer happens | keep |
| B23 | **The mutation corpus rotted against the code it mutates, and said nothing.** Phase 2.1 restructured the generated SQL and gave `matview_execute_spi_plan()` a snapshot argument; A4 and M6 stopped matching and would have failed the next time either was applied. Worse, two entries matched *twice* and were applied with `replace(..., 1)`: B4's anti-join edit and Q3's column quoting each have two call sites, so each was breaking one and leaving the other correct. A half-applied mutation still builds, still misbehaves, and still yields a plausible detection number, with nothing recording which half was measured | `mutations.py --list`, and the apply path itself | **FIXED** -- patterns repaired, and an edit now declares how many occurrences it expects; a count that does not match is a hard error instead of a silent single substitution. All 11 apply and restore | keep the check |
| B22 | **A test that asserted nothing looked exactly like a test that passed.** The bound-parameter case in `matview_where_inject` bound a tag value matching no row, so all three refreshes were correctly no-ops -- and read back a matview an earlier case had already made correct. It reported the right answer three times without executing any of the code it named. The same shape was latent in every other case in the file: run three implementations in sequence over one matview and only the first has work to do | `matview_where_inject` | **FIXED** in `608b3ad` -- the base is mutated afresh before each form with a value carrying the iteration number, and the matview read back after each, so a form that refreshed nothing shows the previous form's number. This is the fourth time in this directory that a clean run meant an absent test rather than an absent bug | keep the pattern |
| B21 | **`ExecRefreshMatView()`'s two strategy comments read as the opposite of their conditions.** "STRATEGY 1: PARTIAL NON-CONCURRENT" guards `qual && concurrent`, and "STRATEGY 2: CONCURRENT (PARTIAL or FULL)" is the branch a bare `REFRESH ... WHERE` takes. The labels describe which *mechanism* runs -- direct modification versus match/merge -- but `concurrent` is a live variable three lines above meaning the user's syntax, so both readings are available and they disagree | none; found by reading | **FIXED** — the strategy comments were rewritten when routing moved off the spelling. "STRATEGY 1: PARTIAL REFRESH, either spelling" now guards `qual && !skipData && nUniqueIndexes <= 1`, and the labels and the conditions say the same thing | keep as a record; nothing left to do |
| B20 | **`matview-where-deadlock.spec` is flaky.** Its expected output records *which* of the two sessions receives `ERROR: deadlock detected`, and that is the deadlock detector's choice of victim, not a property of the refresh. Observed failing once in six runs of an unchanged tree, which is exactly often enough to be blamed on whatever was committed most recently | `src/test/isolation/expected/matview-where-deadlock_1.out` | **FIXED** — alternative expected file, the standard mechanism for legitimately variable output. Both orderings are correct deadlock resolutions | keep both files |
| B19 | **The transformed `WHERE` clause never had collations assigned.** `transformRefreshWhereClause()` did not call `assign_expr_collations()`. Invisible for as long as the only thing done with the tree was to deparse it — the text goes back through the parser, which assigns them the second time round — so the omission was covered by the very round trip this rewrite exists to remove. Executing the tree directly fails on a predicate as ordinary as `tag = 'hot'` with "could not determine which collation to use". The corpus could not see it: all 21 shapes compared numbers | `safety/exh3.sql` case 22 `text_key`, which errors on all 48 of its mutations with the fix reverted | **FIXED** in `9a5195b` | keep the shape |
| B32 | **`matview-where-snapshot` is flaky, the same way B20 was.**  Two steps that are both waiting complete in whichever order the scheduler picks, and the expected file records one of them: `step s1_ref: <... completed>` before `step s2b_ref` in the file, the other way round in a failing run.  Observed **once in four consecutive runs** of an otherwise untouched tree -- green on the three after it -- while verifying the text-path deletion, which does not touch this spec.  Not caused by that change; found by it | `injection_points` `matview-where-snapshot` | **FIXED.**  B20's mechanism: `expected/matview-where-snapshot_1.out`, an alternative expected file.  It stayed open for want of a *failing run* to capture -- an expected file typed out by hand is a test that cannot fail -- and one turned up during the verification of the predicate parameterisation, unrelated to it: `step s2b_ref: <... completed>` before `step s1_ref`, the reverse of the recorded ordering.  Taken verbatim from that run's output rather than written.  17/17 green after | keep both files |
| B33 | **`--predmode param` measured the literal path for two of the three predicate shapes, and reported it as param.** `run.sh` substituted `:k` -> `$1` on `$PREDT` and expanded `:arraylit` afterwards.  The array shape's predicate is `id = ANY(:arraylit)`, which contains **no `:k` at that moment** -- every key it will name arrives inside the array literal, which landed later still carrying its own `:k`, and pgbench then substituted those client-side.  So the param arm ran a varying literal wrapped in a `DO ... EXECUTE` block: the miss path, plus the wrapper's cost, recorded as the hit path.  It read **+10% slower than literal** on `projection`/array/10 where a direct four-arm probe reads **1.84x faster** (`bench/predparam.sh`: lit 737.8 us, param 400.8 us).  The `initplan` shape has the same defect.  The `key` and `range` shapes name `:k` themselves and were correct throughout, which is why this was invisible until two shapes were compared against one another -- a single-shape sweep would have shipped the wrong number with nothing to contradict it | `bench/run.sh`, and the `pp-*` rows it produced | **FIXED** -- `:arraylit` and `:span` are expanded before `:k` -> `$1`, and two guards refuse the measurement rather than take a wrong one: any surviving `:name` is an unexpanded placeholder, and a param-mode predicate with no `$1` binds nothing.  The first guard is the one that would have caught this, and it was **seen to fire** on the old form (`:arraylit` still present).  Introduced by the commit that added the axis, so no recorded result predates it -- but PLAN.md 3.6 says nothing else in Phase 3 can be evaluated until the axis is right, and for two shapes it was not | keep the guards |
| B34 | **The derived `no_delete` rule was unsound twice, and both times every single-session gate passed.** SPECIALIZE.md 3b found the first: with a predicate on a non-key column the upsert matches a matview row the pre-lock never counted, and a genuinely orphaned row elsewhere cancels the discrepancy exactly. The second is the snapshot `n_locked` is taken under -- the pre-lock runs under an earlier one than the DELETE it stands in for, and a refresh over a key the matview does not hold yet locks nothing, does not queue, and can commit a row into the scope inside that window | `matview_where` **Test 20a/20b** (`mutations.py` N1, N2) and `matview-where-prune-elide.spec` (N4) | **FIXED**, with both conditions, and the second was found by building the detector 3c asks for rather than by reading the design. Recorded because of what it says about the gates rather than about the rule: regress, the contract file, the differential oracle and the concurrent fuzzer are all green under the unsound version. RESULTS.md **R43**, **X13** | keep all three mutations; each fails a different file |
| B35 | **`matview-where-prune-elide` is flaky the same way B20 and B32 were.** In its second permutation `s1_bare` and `s2_add` are both waiting when the wake-up fires, and isolationtester reports whichever it notices first. A reporting race rather than a semantic one -- `s2_add` cannot complete before `s1_bare` commits and releases the `ExclusiveLock`, which is the thing that permutation exists to show | `injection_points` `matview-where-prune-elide` | **FIXED**, by B32's mechanism: `expected/matview-where-prune-elide_1.out`, **taken verbatim from the run that produced it** rather than written -- an expected file typed out by hand is a test that cannot fail. Found on the first full-gate run after the spec landed, green 5/5 after. Third instance of this shape in this suite, which is worth reading as a fact about isolationtester rather than about any of the three specs | keep both files |
| B37 | **`leakcheck.sh`'s `churn` mode stopped exercising the path it is named after, and kept printing ok.** It alternated `WHERE id = 1` with `WHERE id = 2` so that every other refresh would be a cache-key mismatch and rebuild the entry -- which is the only path two of the three plansource drop sites are reached by. When the predicate's constants started being replaced by parameters (R37), both spellings began deparsing to `id = $1` and comparing equal, so every refresh HIT and the mismatch path was never taken. The mode reported ok throughout, which is also what it prints when there is no leak: **B23's rot, in the one instrument whose whole subject is a failure with no other symptom** | `leakcheck.sh churn`, calibrated against `mutations.py` **L3** | **FIXED.** Not caught by reading it -- caught by re-running L3, whose recorded calibration on this mode is **+400 over 400 refreshes**, and getting **+0**. The two predicates are now on different *columns* (`id = 1` against `v = 1`), which is what survives parameterisation, since the Var is what differs and no substitution touches it. Re-calibrated: L3 reads **+800** (the body issues two refreshes, both mismatches now) and pristine **+0**. Found while calibrating **L5**, which leaks the cache key's own memory context and read +0 for the same reason | keep. **The timeline is the point and it cuts the other way from how this entry first read.** `leakcheck.sh` was written and calibrated at 08-02 00:19 and 00:48; the parameterisation landed at 08-03 02:18, about 25 hours later; the rot was caught at ~15:00 the same day, about 13 hours after it started. This is not an instrument that quietly rotted for a long time -- it is one that broke and was caught by the next person to use it, which is the calibration rule working rather than failing. The lesson is still that a recorded number is only evidence while the code it was taken against still exists, but "how long was it wrong" is a fact worth having before drawing a conclusion about the suite's health from it |
| B36 | **Nothing checked that the plan cache key reads the predicate.** The key exists so two different predicates on one matview do not share plans -- that is the whole of what it is for -- and no case anywhere refreshed one matview through two different predicates in one session, so nothing could have observed it. `mutations.py C7` drops the predicate from the comparison outright and **all four instruments stay quiet**: regress 5/5, the differential oracle's vector identical to `calibrate.baseline`, `fuzz.sh` PASS on all four modes. Tests 1-4 cover ways the key can be right and the plans still wrong -- a rename underneath it, a parameter type it cannot see -- and none of them covers it not looking. **Not a new class: B31 carries almost this headline already**, for the flag half of the key, and was likewise uncaught by all four instruments. This is the third component of the same key to be checked and the third to have been unchecked; what was new is which one. Note also that SPECIALIZE.md §3 had *predicted* a detector for this -- "`matview_where_cache` Test 4" -- and the prediction was wrong, because Test 4 pins parameter types, which `argtypes` decides either way | `matview_where_cache` **Test 7** | **FIXED.** Both predicates carry a single int4 constant, so `argtypes` cannot stand in for the missing check, and `grp = 3` names rows 1 and 2 while the warmed plan (`id = $1` executed with 3) names row 3 -- so a confusion refreshes exactly the rows the right answer leaves alone, which a refresh that merely did nothing cannot produce. Seen to fail under C7 and under **C8**, the near miss that compares only the top node, with `matview_where` staying green under C8 so the detector is specific. Found while preparing the deparse elision (R48), which replaces this comparison: replacing an ungated comparison is how a silent one gets shipped, so the gate landed as its own commit first | keep. It asserts that a refresh acts on the rows its own predicate names, which holds however the plans are or are not cached |
| B18 | **The oracle's own gate excluded the one shape that failed it.** `safety/exh.sql` case 7 `distincton` was labelled `SAFE` but diverges on 1 of its 96 mutations; the shape list in `checkall.sh` names `distincton_total` and omits `distincton`, so nothing ever looked at it. The divergence is not a defect — the view's `ORDER BY k, ts DESC` is a partial order, and case 13 is the same view with a total order and diverges zero times — but the label said one thing and the data said another for as long as both existed | `safety/exh.sql`; baseline recorded in `calibrate.baseline` | **FIXED** — relabelled `NONDET`, and `calibrate.sh` now compares against a recorded pristine vector instead of a hand-written shape list | keep the baseline file |

---

## C. Designs considered and rejected

Not issues, and nothing here is open. Two alternatives to the fused
`INSERT ... ON CONFLICT` write path get proposed on sight, and one of them was
already built and thrown away. The record exists so neither has to be argued
from scratch a second time.

| Alternative | Verdict | Why |
|---|---|---|
| Transaction-level advisory locks on the logical key | **Built, then abandoned** | Shared lock table entries scale with the predicate's scope, which is the caller's number and not ours |
| `MERGE` instead of, or fused with, the upsert | **Rejected without building** | `MERGE`'s insert cannot take the speculative path, so it cannot serialize two refreshes inserting the same new key |

### Advisory locks on the logical key

Proposed on the thread 2026-01-04, in the message that first described the
`DELETE`→`INSERT` consistency gap that is now A3:

> My plan is to replace that row-locking strategy with transaction-level
> advisory locks inside the refresh logic: Before the DELETE, run a
> `SELECT pg_advisory_xact_lock(mv_oid, hashtext(ROW(unique_keys)::text))` for
> the rows matching the WHERE clause. […] This effectively locks the "logical"
> ID of the row, preventing concurrent refreshes on the same ID even while the
> physical tuple is temporarily gone.

— <https://www.postgresql.org/message-id/CAMjNa7egcgUMf2tdQ1qeTYj1J1bBvyth3thoZPioujusFsBd4Q@mail.gmail.com>

Withdrawn on the thread 2026-04-09, after prototyping:

> In my last email, I mentioned planning to use transaction-level advisory locks
> to fix the consistency gap. After prototyping it, I had to abandon that
> approach. Testing revealed that it falls over at scale, quickly hitting
> `max_locks_per_transaction` limits and causing issues with bulk operations. I
> worked on this for a while before deciding it wasn't workable.

— <https://www.postgresql.org/message-id/CAMjNa7d8f3sj-1ZsmsqiUPLzjXFtjOgeM7GFKvU_1EugyzJ5jw@mail.gmail.com>

That is the measured result and it is the one to cite. What the thread does not
say is *why* the limit is structural rather than a tuning problem, and that is
worth recording because it is also the reason `ON CONFLICT` is not just a
convenient substitute: **the two designs differ in where the lock lives.**

`pg_advisory_xact_lock` puts one entry in the shared lock table per key and
holds it until commit. N keys in scope means N entries held simultaneously, and
the lock table is sized once at startup —
`max_locks_per_transaction × (MaxBackends + max_prepared_xacts)`, allocated in
shared memory and unable to grow. So the ceiling scales with the predicate's
scope, which is exactly the number the feature exists to let the caller choose
and therefore the one number we do not control. Raising
`max_locks_per_transaction` moves the wall; it cannot remove it, and it costs
every backend in the cluster whether or not it refreshes anything.

Speculative insertion holds **at most one** lock table entry per backend at any
instant, regardless of how many rows it inserts. The token generator is
backend-local (`src/backend/storage/lmgr/lmgr.c:45`), and in
`src/backend/executor/nodeModifyTable.c` the acquire (`:1232`) and the release
(`:1258`) bracket a single tuple's insertion — take token, insert speculative,
insert index entries, complete, release. The per-key rendezvous is not in shared
memory at all: it is the token stored in the heap tuple, which a would-be
conflicter reaches through the index. Unbounded distinct keys, O(1) shared
memory.

The core paid for that with an imprecision it documented rather than fixed
(`lmgr.c:33-43`): the counter can wrap, so a waiter can end up

> waiting for the latest unrelated insertion instead. Even then, nothing
> particularly bad happens: in the worst case they deadlock, causing one of the
> transactions to abort.

Occasional false waits, bought in exchange for constant memory. The advisory
lock design structurally cannot make that trade, because its keys must stay
distinct to be *correct*, not merely to be fast.

Two further problems follow from the same line, neither raised on the thread and
neither measured here — they are arithmetic and reading, recorded so the
rejection does not have to rest on the memory limit alone:

- **The hash is 32 bits.** `hashtext` returns `int4` (`pg_proc.dat:1267`) and
  the two-argument `pg_advisory_xact_lock` takes `int4 int4`
  (`pg_proc.dat:9228`), so with the OID consuming one slot the key space per
  matview is 2^32. Collisions do not corrupt anything — they falsely serialize
  two unrelated logical keys — but they degrade the property the feature is
  sold on, and they get worse precisely as scope grows. Birthday arithmetic: at
  10,000 distinct keys the chance of at least one collision is about 1%; at
  100,000 it is about 69%.
- **`ROW(...)::text` is not a canonical form of the key.** Equality on the
  unique index and equality of the rendered text are different relations for
  any type whose output function is not injective over its equality class —
  `citext` is the clean example, where `'A'` and `'a'` are the same key and
  render differently. Two refreshes touching the same logical row would take
  *different* advisory locks and fail to serialize at all. That is a
  correctness failure, not a performance one, and it is silent.

Not to be confused with the `ROW()` that *does* survive in the tree, at
`matview.c:2414` — a `grep` from this section lands on it. That one is a shape
fix and carries none of the above. On the partial path the diff query's `mv` is
no longer a relation but the subquery `(SELECT ctid, * FROM mv WHERE ...)`
(`:2267`), one column wider than the matview's rowtype, so upstream's
`newdata.* OPERATOR(pg_catalog.*=) mv.*` would be an arity mismatch; the branch
rebuilds the rowtype explicitly instead, over live attributes in attnum order
skipping `attisdropped`, and for the same reason the outer-join null test
becomes `mv.ctid IS NULL` rather than `mv.* IS NULL`. It is handed to
`record_eq`, which compares column by column under each type's own equality and
treats two NULLs as equal — which is why upstream chose `*=` there — and it is
never rendered to text or hashed. The canonicalization hazard is specific to
hashing a rendered key, which nothing in the tree now does.

### MERGE

**Not mentioned anywhere on the thread** — all thirteen messages checked, from
2025-12-08 to 2026-05-29. This is a pre-emptive record, because "why not
`MERGE`?" is a cheap question to ask of any upsert-shaped patch and the answer
takes a paragraph of executor reading that a reviewer should not have to do.

`MERGE`'s `WHEN NOT MATCHED ... THEN INSERT` cannot reach speculative insertion.
The entire speculative path is gated on one condition
(`nodeModifyTable.c:1131`):

```c
if (onconflict != ONCONFLICT_NONE && resultRelInfo->ri_NumIndices > 0)
{
    /* Perform a speculative insertion. */
```

where `onconflict` is read from the plan node at `:889`
(`OnConflictAction onconflict = node->onConflictAction;`). `ExecMergeNotMatched`
reaches the insert through `ExecInsert(context, mtstate->rootResultRelInfo,
newslot, canSetTag, NULL, NULL)` (`:4139`) on a ModifyTable whose
`onConflictAction` the `MERGE` grammar has no way to set. So it is a plain heap
insert that takes no token: two overlapping refreshes producing the same new key
both see NOT MATCHED, both insert, and the second gets a unique violation at
index-insert time instead of waiting for the first to decide.

That is exactly the case the thread already assigned to `ON CONFLICT`, 2026-05-26:

> `SELECT FOR UPDATE` only serializes overlapping refreshes covering rows that
> already exist in the MV. Two refreshes that both insert the same new logical
> key are serialized by `ON CONFLICT` and the unique index, not by
> `FOR UPDATE`. The outcome is still correct. The last writer wins on that key.

— <https://www.postgresql.org/message-id/CAMjNa7cnyWqWQT5FwXX8myfej4ZLhEKLsBUdtW1vmvYK-KxbPA@mail.gmail.com>

The pre-lock structurally cannot cover it, because a row that does not exist yet
cannot be locked. `merge.sgml:715` says the same thing from the other direction:

> You may also wish to consider using `INSERT ... ON CONFLICT` as an
> alternative statement which offers the ability to run an `UPDATE` or return
> the existing row (with `DO SELECT`) if a concurrent `INSERT` occurs. There are
> a variety of differences and restrictions between the two statement types and
> they are not interchangeable.

Two corrections to objections that are *not* the reason, so they do not get
raised as though they were:

- **Row ordering is expressible under `MERGE`.** `merge.sgml:704-707`: the
  source order is indeterminate by default, but "A `source_query` can be used
  to specify a consistent ordering, if required, which might be needed to avoid
  deadlocks between concurrent transactions." So M1/M2's ordering requirement
  could be met. Ordering solves deadlock; it does not solve the unique
  violation.
- **`MERGE` is allowed as a data-modifying CTE in this tree**, so a hybrid is
  syntactically available. Verified directly:

  ```sql
  WITH m AS (
    MERGE INTO mg_t t USING mg_s s ON t.id = s.id
    WHEN MATCHED THEN UPDATE SET v = s.v
    WHEN NOT MATCHED BY SOURCE THEN DELETE
    RETURNING t.id
  ) SELECT count(*) FROM m;   -- 1
  ```

The hybrid is therefore the only version worth weighing: `MERGE` for the prune
via `WHEN NOT MATCHED BY SOURCE`, `ON CONFLICT` for the upsert, fused in one
statement so A3's consistency gap stays closed. It buys one thing — the
anti-join is replaced by a clause that reads better — and that thing does **not**
fix B4, because `ON t.k = s.k` is exactly as NULL-unsafe as the anti-join was and
would need the same `IS NOT DISTINCT FROM` treatment B4's fix already applied.
Net gain approximately cosmetic; net cost a second write path that the whole
mutation corpus and both fuzzer modes have to be recalibrated against.

The dependency on `ON CONFLICT` is load-bearing rather than incidental, and the
branch already says so in executable form: `matview-where-insertorder.spec` is
the deterministic gate for insert-side lock ordering, and `mutations.py` M2 —
drop the `ORDER BY` feeding `new_data` — is the calibration proving that gate is
a real detector (`fuzz.sh` p3, 40/80, quiet on pristine).
