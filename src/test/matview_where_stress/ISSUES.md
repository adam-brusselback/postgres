# REFRESH MATERIALIZED VIEW ... WHERE ... — open review items

Branch-local tracking file. Not part of the patch; delete this directory before
posting to -hackers.

Two sections: items raised on the -hackers thread **[Patch] Add WHERE clause
support to REFRESH MATERIALIZED VIEW**, and items found separately that have not
been mentioned there. Each row names the test that covers it, so a fix shows up
as that test turning green.

Every test listed as **red** fails today by design: its expected output describes
correct behaviour. Greps that find everything:

    grep -rn 'hackers' src/test/regress/sql/matview_where*.sql \
                       src/test/isolation/specs/matview-where-*.spec
    grep -rn 'XXX' src/test/regress/sql/matview_where*.sql

---

## A. Raised on the -hackers thread

| # | Item | Raised by | Test | State |
|---|------|-----------|------|-------|
| A1 | `ON CONFLICT` target built from `indnatts`, so INCLUDE columns broke it | Dharin Shah | `matview_where` Test 10 | **fixed** — green, guard added |
| A2 | "Subqueries -> Error" comment did not match the expected output; nothing forbids subqueries | Dharin Shah | `matview_where` Test 13 (second half) | **fixed** — green, guard added |
| A3 | `DELETE`→`INSERT` left a consistency gap; tuple locks vanish after `DELETE` | Adam Brusselback | `matview-where-serialize.spec` | **fixed** — green, replaced by `FOR UPDATE` + fused CTE |
| A4 | Scope drift promised to be fixed "in both the direct-modification and match/merge paths" | Adam Brusselback | `matview_where` Test 12 | **red** — only `direct_mod` does it; `refresh_by_match_merge()`'s final insert is still a plain `INSERT` |
| A5 | Overlapping refreshes can deadlock; ORDER BY on the locking SELECT promised | Vellaipandiyan | `matview_where_stress/run.sh` (**red**, exits non-zero); `matview-where-deadlock.spec` (green, see below) | **not started** — no ORDER BY in the tree |
| A6 | Predicate functions run with the owner's privileges, not the caller's | Zsolt Parragi | `matview_where_privs` Test 1 | **red** — leakproof gating proposed in reply, not written |
| A7 | An error during refresh removes the matview modification restrictions | Zsolt Parragi | `matview_where_privs` Test 3 | **red** — "Will fix", `PG_TRY` still missing |
| A8 | `CONCURRENTLY` semantics are inverted for `WHERE`: the bare form is the more permissive one | Vellaipandiyan | none | **not started** — Adam agreed to swap the two paths. Left untested on purpose: the direction is a naming decision, not a defect, and asserting either mapping would prejudge it. |
| A9 | Document the intended safety model and the guarantees for overlapping refreshes | Dharin Shah, Vellaipandiyan | `matview-where-serialize.spec` covers the executable part | **partial** — the three lock claims are pinned; the prose Adam wrote on-list has not landed in `refresh_materialized_view.sgml`, and the paragraph that is there claims `ROW EXCLUSIVE` "blocks other modification commands", which is wrong |

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

---

## B. Not mentioned on the thread

| # | Item | Test | Notes |
|---|------|------|-------|
| B1 | Cached plans re-resolve relations by name. After a rename, or once another relation takes the old name, a refresh reports success, leaves its own target untouched, and **writes to a different matview** — with no lock and no `MAINTAIN` check taken there | `matview_where_cache` Tests 1–2 | **red**. Most serious of this group: correctness and a privilege bypass |
| B2 | Same hazard through the view definition: after a base-table rename the matview fills from an unrelated table and diverges from its own `pg_get_viewdef()` | `matview_where_cache` Test 3 | **red** |
| B3 | Parameter types are not in the cache key and `pg_get_expr()` does not render them, so predicates differing only in parameter type share an entry and the **wrong rows are refreshed**, silently | `matview_where_cache` Test 4 | **red**. Hits the trigger-driven `EXECUTE ... USING` pattern in Test 9 |
| B4 | A nullable unique key makes every refresh duplicate the NULL-keyed rows: `ON CONFLICT` never arbitrates on NULL, the anti-join's `IS NOT DISTINCT FROM` always matches it | `matview_where` Test 11 | **red**. `NULLS NOT DISTINCT` and the match/merge path both behave correctly |
| B5 | The predicate is evaluated inside the maintenance window, so a predicate function can modify **any** matview in the database | `matview_where_privs` Test 2 | **red**. Amplifies A6 and is not covered by the leakproof gating proposed for it |
| B6 | With more than one unique index, `direct_mod` can collide on a non-arbiter index and reject a row set that both the full and the concurrent refresh accept | `matview_where` Test 14 | **red** |
| B7 | Cache entries are never invalidated or freed — no relcache callback, no `HASH_REMOVE`. Leaks saved plans for dropped matviews, and underlies B1–B3 | none | Fixing B1–B3 should subsume this |
| B8 | Rowcount handed to `SetQueryCompletion()` is `SPI_processed` after the fused CTE, whose top statement is the `DELETE` — so `pg_stat_statements` sees deletions only | none | Not observable from core regress; needs `contrib` |
| B9 | The predicate is analyzed under `RestrictSearchPath()`, so callers must schema-qualify everything | `matview_where` Test 13 (first half) | Green, characterisation only. What is correct here depends on how A6 is settled |
| B10 | The volatility check is a weaker guarantee than the patch claims — a STABLE wrapper around a VOLATILE body passes, which is how both A6 and B5 work | covered indirectly by A6 / B5 | Worth a doc note either way |
| B11 | Index opened `AccessShareLock` at `matview.c:1063`, closed `NoLock` at `:1126`, with no comment saying the lock is meant to be held (unlike `:1466`) | none | Cosmetic |
| B12 | `opt_refresh_where_clause` duplicates the existing `where_clause` production; its `ereport` has no `parser_errposition()` | none | Cosmetic |
| B13 | `SetMatViewPopulatedState()`'s new early return also changes the full-rebuild path: it now skips the `pg_class` update *and* the `CommandCounterIncrement()` | none | Only two callers, both benign, but it should be called out rather than slipped in |
