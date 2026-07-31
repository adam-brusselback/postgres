# The source plan cache — subplan for 3.7, and the invalidation it lands on

Branch-local; delete with this directory.

PLAN.md 3.7 is one row in a table: *"cache the source plan | pursue, required |
12.20 µs, 22% of a warm Query-tree refresh, and the entire reason it currently
loses."* This file is the plan behind that row, because it is more work than a
row suggests and it touches the structure B14 lives in.

## 0. Where this sits, and what it gates

The overall order is in PLAN.md "Where we are". This is step 1 of the six-step
tail, and steps 2–4 are blocked on it:

| | | state |
|---|---|---|
| **1** | **this file** — cache the source plan, on a corrected invalidation | **next** |
| 2 | flip `matview_partial_refresh_querytree` to on, re-run the differential harness and the benchmark sweep | blocked on 1 |
| 3 | B2 / the invalidation restructure | **pulled forward into 1** — see §4 |
| 4 | delete the text path, the two GUCs, and the oracle's A/B axis | blocked on 2 |
| 5 | B15 — warn, error, or document the blast radius | independent, needs a decision |
| 6 | B25, task #17 (derived `no_delete`) | independent |

**Why it gates.** Phase 2.2 decided to ship (b), the Query-tree read side. Both
GUCs still boot `false`, so the default today is the text path, and flipping the
default without 3.7 ships a **24% regression on a warm cache at scope 1** — 60.1
µs text against 78.4 µs Query-tree, three alternating pairs, RESULTS.md R2. The
deficit is a fixed cost, so it is ~0 at scale and the Query-tree path actually
wins on a predicate that misses the plan cache (233 against 315 µs). It bites
exactly where D1 and D2 live: trigger and drain, small scope, warm cache. That
is the primary use case, so "it is fine at scale" is not an answer.

## 1. What is being cached, and the one line it replaces

`matview_materialize_source()` (`matview.c:1371`) rewrites and plans the source
query on **every** refresh:

    AcquireRewriteLocks(sourceQuery, true, false);
    rewritten = QueryRewrite(sourceQuery);
    plan = pg_plan_query(sourceQuery, NULL, CURSOR_OPT_PARALLEL_OK, params, NULL);

`pg_plan_query` is the 12.20 µs. The Query it plans is built fresh each time by
`matview_build_source_query()` from the view's `dataQuery` and the predicate,
neither of which changes between refreshes with the same predicate.

Nothing else in `refresh_by_direct_modification()` re-plans: the locking
`SELECT` and the fused upsert/prune are `SPI_prepare`d once and cached. The
source query is the only survivor, and it is half the planning work.

## 2. The mechanism, and why it is not novel

`CreateCachedPlanForQuery(Query *analyzed_parse_tree, const char *query_string,
CommandTag commandTag)` exists for exactly this shape: a `Query` that has
already been through parse analysis, with no source text. Its comment says so —
*"Currently this is used only for new-style SQL functions, where we have a Query
from the function's prosqlbody, but no source text."*

`functions.c:929` is the pattern to copy:

    plansource = CreateCachedPlanForQuery(parsetree, src, CreateCommandTag(...));
    AcquireRewriteLocks(parsetree, true, false);
    queryTree_list = pg_rewrite_query(parsetree);
    CompleteCachedPlan(plansource, queryTree_list, ...);
    /* then SaveCachedPlan() to outlive the statement, and per call: */
    cplan = GetCachedPlan(plansource, params, owner, queryEnv);
    /* linitial_node(PlannedStmt, cplan->stmt_list), execute, ReleaseCachedPlan */

**This matters for review.** SPECIALIZE.md §7b's whole warning is that a bespoke
cache draws the objection a standard one does not. There is one in-tree caller,
which is thin, but the API is public, documented for our situation, and the
alternative — holding a `PlannedStmt *` ourselves — has no invalidation at all.

## 3. What it gets for free, and it is more than speed

On revalidation, plancache handles a pre-analysed `Query` by **re-rewriting
only** (`plancache.c:833`):

    /* Source is pre-analyzed query, so we only need to rewrite */
    analyzed_tree = copyObject(plansource->analyzed_parse_tree);
    AcquireRewriteLocks(analyzed_tree, true, false);
    tlist = pg_rewrite_query(analyzed_tree);

It never re-analyses, so **names are never re-resolved**. That is precisely the
B1/B2 hazard — a saved raw parse tree re-analysed after a rename resolves to a
different object — and on this path it cannot arise, without our writing
anything. It also inherits all **seven** of plancache's invalidation callbacks
against the one we register.

So 3.7 is not only the performance item. It is the first piece of the feature
whose invalidation is correct by construction rather than by our own callback.

## 4. Scope: the invalidation restructure comes first, not after

**Decision: do B2's restructure as step A of this work, before the source plan
is added.**

The reasoning, so it is not relitigated. Today `MatViewPartialRefreshCache` has
one `invalid` flag per entry, set by our own relcache callback for *every* entry
regardless of `relid`, and cleared by `matview_cache_sweep()` freeing the whole
entry. Adding a third cached object to that structure means writing a third
consumer of a flag we already know is wrong — too broad (any relcache event
anywhere) and too narrow (one callback where plancache has seven) — and then
unwriting it. The restructure is also the *smaller* diff, because it deletes:
`InvalidateMatViewCache()`, `matview_cache_sweep()`, the `invalid` field, and
the `CacheRegisterRelcacheCallback()` call. It replaces them with the
`ri_triggers.c` pattern — let plancache be the detector, ask it per plan:

    if (cacheEntry->lockPlan && !SPI_plan_is_valid(cacheEntry->lockPlan)) ...

**A consequence worth stating.** B14's guard exists because the sweep freed
*other* entries. With the sweep gone, nothing frees another entry's plans, and
the mismatch branch only ever frees the caller's own (R24, and same-matview
nesting is blocked by `CheckTableNotInUse()`). The guard becomes belt-and-braces
rather than the fix. **Keep it anyway** — it is three lines, and "a nested
refresh shares an entry with a caller that is mid-execution" is a shape worth
refusing on principle, not only when we can name the free.

**What is deliberately NOT in scope here**, so this does not sprawl:

- widening the cache key beyond `matviewOid` — see §7, it is separable and it
  wants a measurement first;
- generic-versus-custom plan selection, SPECIALIZE.md §7c;
- a bounded LRU across matviews;
- anything in Phase 3 beyond 3.7 and 3.8.

## 5. The steps, each with the check that has to fail before it passes

The rule this project keeps relearning: **a test that has not been seen to fail
is not evidence.** Each step names what must go red first.

### A. Invalidation restructure (B2)

Gate each cached plan on `SPI_plan_is_valid()`; delete the callback, the sweep,
and the `invalid` field.

- *fail-first*: a test that renames a **function** used in the view definition
  between two refreshes and asserts the second uses the new one. B2 says this is
  broken today, so it must fail on the current tree before the restructure. If
  it passes on the current tree, B2 is wrong and stop to find out why.
- *also*: `matview_where_cache` Tests 1–3 stay green (they cover the rename
  cases the callback did handle), full `installcheck`, `debug_discard_caches=1`.
- *closes*: ISSUES.md B2, and PLAN.md's "invalidation restructure" item.

### B. Source plan through plancache, per-refresh lifetime

Create the plansource, complete it, get the plan, execute, drop it — every
refresh. **No caching yet.** This separates "is plancache wired correctly" from
"did caching help", and either question is hard enough alone.

- *expect*: timing neutral, within R12's 6.8–11.3% noise floor. A large move
  either way means the wiring is wrong, not that it worked.
- *verify*: `safety/rundiff.sh` quiet over all 21 shapes; `matview_where*` green;
  both isolation specs (`matview-where-snapshot`, `matview-where-prune-gap`)
  green, since this touches the snapshot handling around the source.

### C. Give it a lifetime

`SaveCachedPlan()`, a third field on the cache entry, released with the rest.

- *fail-first*: the measurement from §6, run before and after. If the warm scope-1
  deficit does not close, the plan is not being reused and step D will say so.
- *verify*: as B, plus `debug_discard_caches=1`.

### D. Prove the plan is actually reused

**The step this project cannot skip.** Four times now a clean run has meant an
absent test. A cache that silently misses looks exactly like a cache that works,
only slower — and "slower" is inside the noise floor at scale.

- an injection point at the reuse branch, in the style `matview_where_inject`
  already uses; a case that refreshes twice with the same bound parameter and
  asserts the second **hit**, and one that changes the predicate and asserts it
  **missed**.
- *fail-first*: the hit case must fail against step B's build, where nothing is
  saved.

### E. Hand back to the main plan

Re-measure (§6), then PLAN.md step 2 — flip the default, re-run the sweep with a
label matching `p21-O2`, per PLAN.md 2.1b.

## 6. The measurement, decided in advance

Deciding this before measuring, because RESULTS.md's provenance-hazard list is
what happens otherwise.

- **Arms**: `querytree=off` (text) against `querytree=on,optimized=on`, one
  binary, alternated, on the same clone.
- **Cell**: warm cache, **bound parameter** predicate, scope 1 — the D1/D2 shape,
  and the only place the deficit exists. Plus scope 1000 as a control where it
  should already be ~0 either way.
- **Heap state**: settled heap, VACUUM before each timed refresh (R3's protocol,
  the honest one — R5 says the alternative reads 82% where the truth is 54%).
- **Success**: the Query-tree arm at scope 1 warm is **no worse than** the text
  arm, outside R12's noise floor. Not "faster" — the text path is going away, so
  parity is the bar and anything better is a bonus.
- **Sample counts equal per arm.** The per-form adaptive budget was worth 8–9.5
  points elsewhere.
- Record as R26 in RESULTS.md with the protocol, before quoting it anywhere.

## 7. Recorded but not built: why one plan per matview may not be enough

This came out of working through real workloads and is written down here so the
key question is not re-derived from scratch when §4 defers it.

The source plansource embeds the predicate, so a *different predicate* is a
different plansource by construction — the same coarse-key problem the two SPI
plans already have. With a **bound parameter** one plansource serves every value
and plancache's generic/custom machinery does the rest, which is why R15's
`Const` parameterisation was worth 8×: it turns misses into hits. The question
is whether one entry per matview is enough when a single matview has more than
one *caller*.

Workloads where it is not:

1. **The five-join invoice.** One table in the join tree returns no rows but
   still changes the result. Predicates that do and do not constrain that table
   are structurally different plans over one matview.
2. **The sales rollup with two writers.** A scheduled job drains a queue in
   batches (`= ANY($1)`) while an on-update/delete trigger refreshes single rows
   (`= $1`). Two callers, two predicates, one matview — they evict each other on
   every call. SPECIALIZE.md §7 calls this "worse than no cache: maintenance paid
   for a guaranteed miss."
3. **Tax rules by company type.** A sale-by-customer rollup whose rules differ by
   company type, so different predicates select genuinely different plans rather
   than the same plan with different constants.

A fourth — sales moving between customers, refreshed on both ad hoc — was raised
and then **withdrawn**; it is recorded only so it is not re-proposed.

What that implies, and what has to be measured before building any of it:
key on `(matviewOid, predicate)` rather than `matviewOid`, which needs a bounded
number of entries and therefore an eviction policy. `nodeMemoize.c` is the
in-tree precedent for a backend-local bounded LRU (`dlist`), and
`pg_stat_statements`' `entry_dealloc()` for usage-decay eviction that resists
scans. **Do not build either until case 2 is measured** — the thrash is asserted
from the code, not observed, and this project has a record of sizing things by
reasoning and getting them wrong (RESULTS.md X1, X2).

## 8. Exit criteria

3.7 is done when all of:

- ISSUES.md B2 closed, with the fail-first rename test in the tree;
- `pg_plan_query()` no longer runs on a warm repeat refresh, proven by the
  injection-point test from step D, not by timing;
- R26 recorded: Query-tree arm at parity or better with the text arm, warm,
  scope 1, bound parameter, on the protocol in §6;
- `installcheck`, isolation, injection_points green, and the suite re-run under
  `debug_discard_caches = 1` (SPECIALIZE.md §7b — it is not in `make check`, so
  nothing will remind you);
- `safety/rundiff.sh` quiet across all 21 shapes, both GUC arms.

It is **not** done because the code compiles and the tests are green. B14's first
fix was green throughout.
