# REFRESH MATERIALIZED VIEW ... WHERE ... — open review items

Branch-local tracking file. Not part of the patch; delete this directory before
posting to -hackers.

Two sections: items raised on the -hackers thread **[Patch] Add WHERE clause
support to REFRESH MATERIALIZED VIEW**, and items found separately that have not
been mentioned there. Each row names the test that covers it, so a fix shows up
as that test turning green.

**All of these are now fixed unless marked otherwise, and the whole suite is
green** — regress 248/248, isolation 133/133, pg_stat_statements 16/16, verified
on both a `-O0 --enable-cassert` and a `-O2` build. The State column records what
happened.

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
| A8 | `CONCURRENTLY` semantics are inverted for `WHERE`: the bare form is the more permissive one | Vellaipandiyan | `matview_where` Test 14 | **DONE** — CONCURRENTLY selects direct modification, the bare form match/merge | **DELETE once the swap lands** — it asserts a lock level, not a behaviour, so it will break on unrelated locking changes. What should survive is the documented statement of which form blocks writers |
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
plans. It has not reproduced since — three full harness runs, ~2800 refresh
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

---

## B. Not mentioned on the thread

| # | Item | Test | Notes | Disposition |
|---|------|------|-------|-------------|
| B1 | Cached plans re-resolve relations by name. After a rename, or once another relation takes the old name, a refresh reports success, leaves its own target untouched, and **writes to a different matview** — with no lock and no `MAINTAIN` check taken there | `matview_where_cache` Tests 1–2 | **FIXED** — a relcache callback drops cached plans | delete if the plan cache goes away; keep as invalidation guards if it stays |
| B2 | Same hazard through the view definition: after a base-table rename the matview fills from an unrelated table and diverges from its own `pg_get_viewdef()` | `matview_where_cache` Test 3 | **FIXED** — same callback | n/a |
| B3 | Parameter types are not in the cache key and `pg_get_expr()` does not render them, so predicates differing only in parameter type share an entry and the **wrong rows are refreshed**, silently | `matview_where_cache` Test 4 | **FIXED** — argument types are part of the cache key | keep — asserts the refresh acts on the rows its predicate identifies, cache or no cache |
| B4 | A nullable unique key makes every refresh duplicate the NULL-keyed rows: `ON CONFLICT` never arbitrates on NULL, the anti-join's `IS NOT DISTINCT FROM` always matches it | `matview_where` Test 11 | **FIXED** — the anti-join operator now follows the arbiter index's NULL handling, which also removes an O(n^2) nested loop | keep |
| B5 | The predicate is evaluated inside the maintenance window, so a predicate function can modify **any** matview in the database | `matview_where_privs` Test 2 | **FIXED** — the exemption is scoped to the matview being refreshed | keep |
| B6 | With more than one unique index, `direct_mod` can collide on a non-arbiter index and reject a row set that both the full and the concurrent refresh accept | `matview_where` Test 15 | **DOCUMENTED LIMITATION** — direct modification cannot; the bare form can | keep |
| B7 | Cache entries are never invalidated or freed — no relcache callback, no `HASH_REMOVE`. Leaks saved plans for dropped matviews, and underlies B1–B3 | none | **FIXED** by the relcache callback | n/a |
| B8 | Rowcount handed to `SetQueryCompletion()` is `SPI_processed` after the fused CTE, whose top statement is the `DELETE` — so `pg_stat_statements` sees deletions only | `contrib/pg_stat_statements` `utility` | **FIXED** — both forms report rows written; they differ because match/merge applies a change as delete+insert | keep |
| B9 | The predicate is analyzed under `RestrictSearchPath()`, so callers must schema-qualify everything | `matview_where` Test 13 (first half); `safety/cases2.sql` case `dim_change_fixed` | **OPEN, and upgraded from cosmetic.** The safety work showed that the *correct* predicate for a change to a joined dimension table is `id IN (SELECT id FROM f WHERE did = $1)` — a sub-select over a base table. Unqualified, that fails with `ERROR: relation "f" does not exist`. The feature's own correctness story depends on a predicate form the restriction makes awkward | revisit with A6 — becomes an assertion of new behaviour if the path opens up, or moves to the docs if it stays restricted |
| B10 | The volatility check is a weaker guarantee than the patch claims — a STABLE wrapper around a VOLATILE body passes, which is how both A6 and B5 work | covered indirectly by A6 / B5 | Worth a doc note either way | n/a |
| B11 | Index opened `AccessShareLock` at `matview.c:1063`, closed `NoLock` at `:1126`, with no comment saying the lock is meant to be held (unlike `:1466`) | none | Cosmetic | n/a |
| B12 | `opt_refresh_where_clause` duplicates the existing `where_clause` production; its `ereport` has no `parser_errposition()` | none | Cosmetic | n/a |
| B13 | `SetMatViewPopulatedState()`'s new early return also changes the full-rebuild path: it now skips the `pg_class` update *and* the `CommandCounterIncrement()` | none | Only two callers, both benign, but it should be called out rather than slipped in | n/a |
| B15 | **The documentation does not mention blast radius.** A reader following `refresh_materialized_view.sgml` today will refresh a `rank() OVER (PARTITION BY ...)` matview by row key and silently corrupt it. Nor does it mention that a row leaving the predicate's scope is deleted, or that a non-deterministic view definition can diverge between partial and full refresh | `safety/` covers all three | **OPEN** — needs a decision, not just prose: warn, error, or document. `SAFETY.md` has the material and the measured cost of a static check | keep |
| B14 | **Use-after-free in the plan cache.** `InvalidateMatViewCache()` freed plans and `HASH_REMOVE`d entries from inside a relcache callback, while `refresh_by_direct_modification()` held a pointer to one of those entries across the whole maintenance window | found by `safety/run.sh`; no deterministic test | **FIXED** — the callback now only marks; `matview_cache_sweep()` frees at the next refresh. See below | keep the sweep |
