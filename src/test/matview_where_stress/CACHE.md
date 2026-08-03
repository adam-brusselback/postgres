# The source plan cache — subplan for 3.7

Branch-local; delete with this directory.

PLAN.md 3.7 is one row in a table: *"cache the source plan | pursue, required |
12.20 µs … the entire reason it currently loses."* This file is the plan behind
that row.

**Revision note.** The first two drafts were reviewed by three independent
readers against the source, and all three returned **DO NOT PROCEED**, agreeing
on thirteen findings. The largest was that the draft's go/no-go was decided
against the work by an argument that does not apply to the cell the work exists
to fix. That is corrected below, and the ordering it produced — B2's
invalidation restructure ahead of everything — is **reversed**. Findings whose
correction leaves no trace in the text are recorded in §9.

## 0. Where this sits, and what it gates

The overall order is in PLAN.md "Where we are". This is step 1 of the six-step
tail:

| | | state |
|---|---|---|
| **1** | **this file** — cache the source plan | **next** |
| 2 | flip `matview_partial_refresh_querytree` on, re-measure | blocked on 1 |
| 3 | B2 / the invalidation restructure | **its own item, no longer inside 1** — §4 |
| 4 | delete the text path, the two GUCs, and the oracle's A/B axis | blocked on 2 |
| 5 | B15 — warn, error, or document the blast radius | independent, needs a decision |
| 6 | B25, derived `no_delete` | `no_delete` **done** (RESULTS.md R42, R43); B25 independent and open |

**Why it gates.** Phase 2.2 decided to ship (b), the Query-tree read side. Both
GUCs still boot `false`, so the default today is the text path, and flipping it
without 3.7 ships a regression: **RESULTS.md R26**, 49.7 µs text against 61.6 µs
Query-tree warm at scope 1 (24%), confirmed over three alternating pairs at 60.1
against 78.4 (30%). The deficit is a fixed cost — R2 puts source planning at
16.2% → 0.9% → 0.0% at scope 1/100/10k — and on a *cold* cache the Query-tree
path wins outright (233 against 315 µs) because it skips `pg_get_viewdef`. It
bites where D1 and D2 live: trigger and drain, small scope, warm cache.

Quote the share as **16.2%** (R13, and RESULTS.md is canonical for settled
numbers). Earlier drafts said 22%, which is neither 12.20/61.6 = 19.8% nor R13's
figure, and carried no protocol.

## 1. What is being cached, and the cell it pays in

`matview_materialize_source()` (`matview.c:1371`) rewrites and plans the source
query on **every** refresh:

    AcquireRewriteLocks(sourceQuery, true, false);
    rewritten = QueryRewrite(sourceQuery);
    sourceQuery = linitial_node(Query, rewritten);
    plan = pg_plan_query(sourceQuery, NULL, CURSOR_OPT_PARALLEL_OK, params, NULL);

**The 12.20 µs was rewrite *and* plan together**, not `pg_plan_query` alone —
`profile.py`'s timer opened before `AcquireRewriteLocks` and closed after
`pg_plan_query`. **Measured** (R27): the plan is **97.3%** of that line, the
rewrite **2.7%** (41.25 µs against 1.13 µs). So the prize is the plan half, and
the rewrite is not worth designing around.

### Two things step 0 found that change what 3.7 can claim

**3.7 is necessary but not sufficient (R28).** In one run, both arms, same clone
and boot: text **75.42 µs** against Query-tree **149.58 µs** per refresh, a
**74.16 µs** deficit. `srcplan` is **41.25 µs of it — 56%**. `srcbuild` (5.30)
and `srcexec` (9.94) are most of the remainder, and `srcexec` is work the text
arm does inside `dmlexec`, so it is not a like-for-like saving. **R26's
explanation — "the whole deficit is one line" — is false.** Caching the source
plan closes a bit over half the gap; something else has to close the rest, and
step E's re-measurement must be read with that in mind rather than as a
pass/fail on parity.

**R26's magnitude did not reproduce, and it is now `provisional`.** The recorded
deficit is 24%; on this container, on R26's own protocol, it is **98%**. Both
arms slowed — text 1.52×, Query-tree 2.43× — so it is not a uniform environment
shift. The container is not the one R2 ran on and the tree has changed since;
the cause is unestablished. **The direction and sign hold and the case for 3.7 is
stronger, not weaker. Do not quote 24% again until it is re-measured.** This is
RESULTS.md's cross-boot hazard, and the fix is to re-measure both arms in one
run — which step E does anyway.

**And the cache is not being dropped (R29).** `prepare = 0.0` in all nine warm
bands of both arms: over 270 refreshes each, the plans were prepared once and
never rebuilt. That is direct confirmation of PLAN.md 3.1 and of §4's reason for
taking B2's restructure out of this work — observed now, not inferred.

### The cell this was measured in, which decides everything below

R26's protocol is literally `REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv
WHERE id = 1;` **×300** (PLAN.md 3.1), on `projection`, whose span-1 predicate is
`id = :k` (`bench/workloads.sql:45`). So the 24% deficit was measured with a
**constant literal**, and that has three consequences the earlier drafts missed:

- **The entry hits.** The key is `strcmp` on the deparsed predicate
  (`matview.c:1586`); a constant literal deparses identically every call. PLAN.md
  3.2 measures all three modes: varying literal **546 µs** (misses every time),
  constant literal **72 µs** (hits), bound parameter **67 µs** (hits). Only a
  *varying* literal misses.
- **`params` is NULL**, so `choose_custom_plan()` returns false immediately
  (`plancache.c:1184-1185`) — **generic plan, unconditionally, forever.** A saved
  plansource is reused with no replanning at all.
- Therefore **3.7 recovers essentially the whole 12.20 µs in the cell that
  motivates it**, with no pinning, no `CURSOR_OPT_GENERIC_PLAN`, and none of
  SPECIALIZE.md §7c's novel machinery.

### What does *not* hold, and where the real residual is

"Nothing else in `refresh_by_direct_modification()` re-plans" is **false when the
predicate is parameterised.** `matview_execute_spi_plan()` hands `params` to
`SPI_execute_plan`, so the fused DML's plansource goes through
`choose_custom_plan()` too — and PLAN.md 4.1 measured it: `WHERE id = $1`, `auto`
**138.7 µs** against `force_generic_plan` **51.4 µs**, *"invisible to the phase
profile … because it happens inside `SPI_execute_plan`, counted under
`dmlexec`."*

So in the **bound-parameter** cell a cost roughly seven times the one 3.7 chases
already dominates, and 3.7 is not the right lever there. That is 4.1's problem,
not this one. **3.7 is scoped to the constant-literal cell**, which is what R26
measured and what §6 re-measures.

## 2. The mechanism

`CreateCachedPlanForQuery(Query *analyzed_parse_tree, const char *query_string,
CommandTag commandTag)` is for exactly this shape — *"used only for new-style SQL
functions, where we have a Query from the function's prosqlbody, but no source
text"* (`plancache.c:254-263`). `functions.c:929` is the only in-tree caller and
the pattern to copy. That precedent matters: SPECIALIZE.md §7b's warning is that
a bespoke cache draws objections a standard one does not.

Four mechanics the sketch must not elide, each a silent behaviour change if
dropped:

- **`cursor_options`.** Today the source is planned `CURSOR_OPT_PARALLEL_OK`
  (`matview.c:1390`). That must reach `CompleteCachedPlan()`'s `cursor_options`
  argument, which is what `BuildCachedPlan` passes to `pg_plan_queries`. Drop it
  and parallel source evaluation goes away — invisible at scope 1, material at
  the scale where the source is largest in absolute terms.
- **`SaveCachedPlan()` ordering.** It asserts `!plansource->is_saved` and calls
  `ReleaseGenericPlan()` — *"Best thing to do seems to be to discard the plan"*
  (`plancache.c:1666-1673`). Save **before** the first `GetCachedPlan()`, once,
  not per refresh.
- **ResourceOwner.** `GetCachedPlan()` errors with *"cannot apply ResourceOwner
  to non-saved cached plan"* (`plancache.c:1309-1310`), so an unsaved plansource
  must pass `owner = NULL` — and then nothing releases the refcount if the
  executor throws. `refresh_by_direct_modification()`'s `PG_CATCH` restores only
  the maintenance flags. SPECIALIZE.md §7b lists Noah Misch's *"tracking
  resources by subtransaction"* objection as one review will raise.
- **`pg_rewrite_query()` vs `QueryRewrite()`.** `functions.c` uses the former, we
  use the latter. Harmless, but it changes parser-stats logging; the step A diff
  should name the swap rather than inherit it.

## 3. What it gets for free

On revalidation, plancache handles a pre-analysed `Query` by **re-rewriting
only** (`plancache.c:833-843`) — it never re-analyses, so **names are never
re-resolved**. That is the B1/B2 hazard, unreachable on this path without our
writing anything. And when the plansource is still valid,
`RevalidateCachedQuery()` returns without touching the tree at all, so even a
custom plan skips the rewrite.

One framing correction: plancache registers **eight** callbacks — one relcache
plus seven syscache (`plancache.c:150-157`). And because `SPI_keepplan()` calls
`SaveCachedPlan()`, our two SPI plans are *already* on `saved_plan_list` and
*already* receive all eight. **B2 is not "plancache never learns" — it is "we
never ask, and plancache's revalidation then re-analyses the raw parse tree."**

**One trap, smaller than the last draft claimed.** `RevalidateCachedQuery()`
forces a replan when `SearchPathMatchesCurrentEnvironment()` is false, and
`REFRESH` runs under `RestrictSearchPath()`. But that function uses the
generation counter only as a fast path and then compares **by content**
(`namespace.c:3983-4034`), and `refresh_by_direct_modification()` is reachable
only from inside the restricted region (`matview.c:648`), so the paths match by
content and the "every call replans" failure cannot happen the way the last draft
described. The narrow real case: if the session's temp namespace comes into
existence between two refreshes, the resolved path changes and the content
comparison fails once. Step C still stands — it just is not hunting this.

## 4. B2's restructure is NOT part of this work

**Reversed from the previous draft, which put it first.** Two reasons, and the
first is that the argument for pulling it forward was refuted.

**The refuted argument.** The draft said the shotgun invalidation makes the
cache's hit rate depend on background activity, so measuring the cache before
fixing it measures the wrong thing. The mechanism is real —
`InvalidateMatViewCache()` ignores `relid` and marks every entry
(`matview.c:1193-1204`) — but the project had already measured the effect and it
does not occur: PLAN.md 3.1 says *"300 committed refreshes with a constant
predicate call `pg_get_viewdef` **once**, not 300 times, so the plans survive
commits and nothing re-plans"*, and the warm phase table shows `SPI_prepare` at
**0.79 µs** sustained over 300 refreshes, which is a near-100% hit rate. ISSUES.md
B16 adds that `ANALYZE` was *not* sufficient to mark an entry stale; it took an
`ALTER TABLE`.

**And the restructure is not the small subtraction the draft claimed.** Four
things it has to solve that were not written down:

- **It reopens B7.** `HASH_REMOVE` appears once in `matview.c`, in
  `matview_cache_sweep()`, whose own comment says *"Sweeping every entry rather
  than just this refresh's own is what reclaims the plans of matviews that have
  since been dropped."* ISSUES.md B7 is that leak by name, closed by this
  mechanism, test coverage **none**. Gate per-plan on the caller's own entry and
  a dropped matview's plans — three of them after 3.7 — are never reclaimed.
  PLAN.md 3.10 proposed *narrowing* the sweep, not deleting it.
- **Detection is only half of `ri_triggers.c`'s pattern.** `ri_FetchPreparedPlan()`
  says *"we don't want to simply rely on plancache.c to regenerate it; rather we
  should start from scratch and **rebuild the query text too**."* Our regenerate
  path is gated on `lockPlan == NULL || refreshPlan == NULL` (`matview.c:1660`),
  so an invalid-but-non-NULL plan reuses the stale text and nothing changes.
- **The precondition is not met.** `ri_triggers.c` and `plancache.c` both warn
  that the validity check *"is only trustworthy if the caller has already
  locked"* the relations. At the top of the refresh only the matview is locked;
  on the text path the fused statement's `relationOids` include base tables that
  are not.
- **The designated fail-first probably cannot fail.** `whereClauseStr` is
  regenerated from the freshly analysed qual on *every* refresh
  (`matview.c:705`) **and is simultaneously the cache key** (`matview.c:1586`).
  After `ALTER FUNCTION f RENAME TO g` the qual holds the OID, deparses to the
  new name, the `strcmp` fails, and the plans are rebuilt from regenerated text.
  Two reviewers independently could find no route to a stale binding through the
  predicate. The demonstrable B2 route is the **view definition**, text only on
  the text path — the path step 4 deletes.

**So B2 goes back to being its own item**, with its own investigation of whether
it is still reachable at all once the text path is gone. Nothing in 3.7 depends
on it: a `CachedPlanSource` self-validates through `GetCachedPlan()`, so the
source plan's correctness is plancache's business regardless of what our flag
does. The one real coupling — `matview_cache_sweep()` would `DropCachedPlan()` a
plansource that is in use — is already closed by B14's depth guard, and §5 step B
must not undo that.

## 5. The steps

The rule this project keeps relearning: **a test that has not been seen to fail
is not evidence.** Each step names what must go red first, or says plainly that
nothing can.

### 0. Repair the instruments, and split the 12.20 µs — **DONE**

Returned R27 (the split), R28 (necessary but not sufficient) and R29 (the cache
survives). Both findings that change the plan are in §1. What was done:

- **`profile.py` had not instrumented anything since `49a3528`** — this session's
  own B14 fix moved the sweep its edit anchored on. 13 of 14 patterns matched, so
  `on` exited having written nothing, and the only symptom would have been a
  phase profile that never appeared. Repaired, and given a `--check` that reports
  **every** miss rather than the first: 15/15. This was ISSUES.md B23's rot one
  file over.
- The sweep edit became **two** edits, which is not cosmetic:
  `MVP_STOP(MVP_ARBITER)` must fire before `if (use_cache)`, because a nested
  refresh takes the `else` arm and would otherwise leave that timer running
  across the whole refresh. Re-anchoring the old pattern inside the branch would
  have reintroduced that quietly.
- **A GUC trap worth recording**, because it is the same shape as the ones the
  reviews caught: the first version of the measurement script set no GUCs, and
  `matview_materialize_source()` — where both new timers live — is reached only
  when `querytree=on`, which boots `false`. It would have run cleanly and
  reported zeros.

### A. Source plan through plancache, per-refresh lifetime

Create, complete, get, execute, drop — every refresh. **No caching yet**, so "is
plancache wired correctly" is separated from "did caching help".

- *expect **slower**, slightly.* This adds `copyObject` of the analysed tree
  (`plancache.c:275`), a second copy at rewrite, `extract_query_dependencies`,
  `GetSearchPathMatcher`, `PlanCacheComputeResultDesc`, and two context
  create/deletes, on top of the rewrite and plan already paid. The previous draft
  said "expect neutral; a large move either way means the wiring is wrong", which
  would have read a correct implementation as a bug.
- *fail-first*: **none is available** for a pure mechanism swap, and saying so is
  better than inventing one. The gate is the differential harness: `rundiff.sh`
  quiet across the corpus in both GUC arms, `matview_where*` green, and both
  `matview-where-snapshot` and `matview-where-prune-gap` green, since this touches
  the snapshot handling around the source.

### B. Give it a lifetime

`SaveCachedPlan()` once, a third field on the cache entry, `DropCachedPlan()` on
release. Watch §2's four mechanics.

- *fail-first*: **step C's probe, written first and run against step A's build**,
  where it must go red. Do **not** use the benchmark as the gate — the effect may
  be a few µs on a 61.6 µs cell and this protocol's floor is not yet established.
- B14's guard must still hold: a nested refresh at depth > 0 takes no entry, so it
  must build a private plansource and drop it rather than reach the saved one.

### C. Prove the plan is reused — and that no planning happens

**The step this project cannot skip**, and the previous draft's version could not
do its job.

- An injection point cannot live at "the reuse branch" in `matview.c`: that only
  observes that the *entry* was reused, which is true even when `BuildCachedPlan`
  re-plans. Assert on plancache's own state — `plansource->generation`,
  `num_generic_plans`, `num_custom_plans`, `gplan` (`plancache.h:133-148`).
- The precedent is **not** `matview_where_inject`, which is the SQL-injection
  suite and whose header says *"Nothing here should be able to fail"* — the
  opposite of this rule. It is `INJECTION_POINT("matview-where-locked")` and
  `("matview-where-source-materialized")` (`matview.c:1976, 2005`), driven from
  `src/test/modules/injection_points/specs/`. So the test needs
  `--enable-injection-points` and will not run in a default `make check`.
- **It cannot also run under `debug_discard_caches = 1`.** That setting calls
  `InvalidateSystemCachesExtended()` at every invalidation-acceptance point, which
  invalidates every saved plansource with a non-empty `relationOids`; a reuse
  assertion must go red. Guard the case and say so, or R25's 5/5 silently becomes
  4/5.
- Add the case SPECIALIZE.md §3 already asked for and the draft dropped: **a base
  table changing must invalidate the source plansource.** That is the correctness
  failure mode of this item and the whole reason plancache was chosen over a
  stashed `PlannedStmt`.

### D. Repair what these steps break

Both are calibrated instruments, both break silently, and B23 is the precedent.

- **`mutations.py`.** C1 ("never invalidate the partial-refresh plan cache")
  anchors on `CacheRegisterRelcacheCallback(InvalidateMatViewCache, (Datum) 0);`
  (`mutations.py:156-157`). 3.7 does not delete that line — B2's restructure
  would — but C1 needs a sibling that breaks the *source* plansource's validity,
  or the new mechanism ships with no mutation ever seen to break it.
  `mutations.py --check` goes from 20/20 (R20) to 21/21.
- **`profile.py`** patches by literal match inside
  `refresh_by_direct_modification()`, including the block step A rewrites. Update
  it in the same commit and re-run `--check`.

### E. Hand back to the main plan

Re-measure (§6), then PLAN.md step 2.

## 6. The measurement, decided in advance — and corrected

The previous draft's protocol was broken three ways. Each is recorded because
each looks like ordinary care.

- **No VACUUM before timed refreshes.** `vac_update_relstats()` updates
  `pg_class` **in place** (`vacuum.c:1460, 1574`), which routes through
  `CacheInvalidateHeapTupleInplace()` — whose comment says it detects *"whether a
  relcache invalidation is implied"*. So a VACUUM before each timed refresh drops
  the plan cache before each timed refresh, converting the **warm** cell into the
  **cold** cell, where the Query-tree arm already wins 233 to 315 µs for an
  unrelated reason. The measurement would report success whether or not 3.7
  worked. R3/R5's heap-state control belongs to a comparison where one arm writes
  and the other does not (RESULTS.md X1); both arms here write identically.
- **Arms are `querytree=off` against `querytree=on`, not `qtopt`.**
  `optimized=on` adds the row comparison, separately measured **18.5% slower at
  scope 1** — the exact cell and direction of the bar — handing the arm that must
  reach parity a handicap unrelated to 3.7. It is also not what R26 measured (the
  phase table has two arms) nor what step 2 ships. SPECIALIZE.md §3f: *"Do not
  bundle … pairing them would make a measurable change unmeasurable."*
- **Cell: constant literal, scope 1, warm** — R26's cell, per §1. Not a bound
  parameter: that cell is dominated by 4.1's DML replanning, and `bench/run.sh`
  cannot produce it anyway. It interpolates `:k` client-side into a **varying**
  literal (`run.sh:203-224`), which is the *miss* path, where the Query-tree arm
  already wins. PLAN.md 3.6 — *"`run.sh` needs a `--predmode literal|param` axis
  … nothing else in this list can be evaluated until this is fixed"* — is a
  precondition for step E's sweep and was not listed as one.

Otherwise: alternate arms on the same clone, equal sample counts per arm (the
per-form adaptive budget was worth 8–9.5 points elsewhere), scope 1000 as a
control where the effect should be ~0 either way.

**Success**: R28 says parity is **not achievable by 3.7 alone** — `srcplan` is
56% of the deficit. So the bar is a **measured reduction of the deficit by
roughly the `srcplan` share**, with the residual attributed. Claiming parity as
the target would fail a working implementation. (The previous draft additionally
said "no worse than … outside R12's noise floor", which demands the opposite of
parity and is readable two ways.)

**Establish the floor first.** R12's 6.8–11.3% is a between-clone wobble on a
**2.5 ms** cell from `bench/orderby-floor.sh`. This is a ~50–62 µs in-backend
`INSTR_TIME` cell on one clone. Quoting R12 here breaks RESULTS.md's own rule and
gives an acceptance band wide enough to hide the entire 12.20 µs. Measure the
floor of *this* protocol, then set the bar.

**The numbers this section reserved were taken while it waited.** R30 went to
the fuzzer's `nest` calibration and R31 to the p2/p3 question, so the floor is
**R33** and the result is **R34**.  Recorded rather than renumbered: RESULTS.md
is an index other files cite by number, and quietly reusing one destroys the
finding already under it.

Record the result as **R34** (see above). Not R26 — that is the "before" number
this work is justified by, it is `settled`, and overwriting it destroys the
comparison.

**And R26 turned out not to be usable as the before at all.** Its magnitude was
already `provisional` after failing to reproduce, so the honest before had to be
measured on this protocol, this build and this container -- which is what
`mutations.py C4` is for: it switches the source-plan cache off and nothing
else, putting both arms of the comparison inside one configuration.

## 7. Recorded but not built: why one plan per matview may not be enough

Still out of scope — with one correction: deferring the key widening is **not
neutral**, it gets worse. Step B adds a third saved object whose miss costs two
`copyObject`s, dependency extraction and a search-path capture, on top of the
rewrite and plan already paid. SPECIALIZE.md §7 already calls the two-caller case
*"worse than no cache: maintenance paid for a guaranteed miss"*; 3.7 raises the
price of each miss, and `bench/run.sh`'s varying literal is that path.

The workloads that want more than one plan per matview:

1. **The five-join invoice.** One table in the join tree returns no rows but
   still changes the result. Predicates that do and do not constrain it are
   structurally different plans over one matview.
2. **The sales rollup with two writers.** A scheduled job drains a queue in
   batches (`= ANY($1)`) while an on-update/delete trigger refreshes single rows
   (`= $1`). Two callers, two predicates, one matview, evicting each other.
3. **Tax rules by company type.** Different predicates select genuinely different
   plans, not the same plan with different constants.

A fourth — sales moving between customers, refreshed on both ad hoc — was raised
and **withdrawn**; recorded so it is not re-proposed.

`nodeMemoize.c` is the in-tree precedent for a backend-local bounded LRU, and
`pg_stat_statements`' `entry_dealloc()` for scan-resistant usage decay. **Do not
build either until case 2 is measured** — the thrash is asserted from the code,
not observed, and RESULTS.md X1 and X2 are what happens when this project sizes
something by reasoning.

## 8. Exit criteria

- **R27** (the split), **R28** (necessary-not-sufficient) and **R29** (the cache
  survives) recorded — **done**; this protocol's noise floor still outstanding
  and now **R33** -- **done**: sd 4.11 us on a 67.40 us cell, 6.1%, SEM 0.48 us
  over 72 bands;
- the source plan is reused **and no planning occurs** on a warm repeat refresh
  in the constant-literal cell, proven by step C's plancache-state assertion, not
  by timing;
- a base-table change invalidates the source plansource, with a test;
- **R34** recorded -- **done, and it beat the bar**: the deficit goes 54.25 us to
  0.38 us, a 99.3% reduction, with the source line 44.88 us to 0.07 us.  The bar
  was "roughly the `srcplan` share, with the residual attributed", because R28
  said 3.7 could not reach parity alone.  It reached parity, and the reason is
  that R28 credited 3.7 with `srcplan` only: as implemented it also removes
  `srcbuild` and `srcrewrite`, since the source query is built on a miss and not
  on a hit.  §1's "necessary but not sufficient" is superseded for this cell;
- `mutations.py --check` 21/21 and `profile.py --check` green, both repaired in
  the commits that break them;
- `installcheck` 250/250, isolation 135/135, injection_points 5 regress + 12
  specs -- **all green**;
- **`debug_discard_caches = 1` green** on all five `matview_where*` files, with
  the probe's reuse case explicitly guarded to 0 as this criterion requires.
  The runtimes are the evidence it was actually in effect: 10-79 s per file
  against ~0.15 s normally.  A fast pass would have meant the setting was being
  ignored, which is this directory's recurring failure shape;
- `contrib/pg_stat_statements` **15/16, confirmed as B25's exact diff** -- the
  bare form reporting 3 rows rather than 6 since routing moved off spelling.
  Note that `installcheck` there is a silent no-op (`NO_INSTALLCHECK = 1`, the
  tests need `shared_preload_libraries`); it must be `make check`, and reading
  the no-op's silence as a pass is the same mistake one level up;
- **`rundiff.sh` quiet: 23 shapes, 0 divergences, 0 errors in either arm**;
- **no leaks**: `leakcheck.sh` reports +0 plansources on all four modes over 300
  refreshes each, with `churn` calibrated against `L3` (+400/400) and `dropmv`
  against `L4` (+200/200).  `steady` is a control and `nested` is not live --
  the per-mode table in that script says which is which and why.

**Step E is done and §8 is met.**  PLAN.md step 2 -- flip the `querytree`
default and re-run 2.1b -- was blocked on this and is now unblocked by R34.

It is **not** done because the code compiles and the tests are green. B14's first
fix was green throughout.

## 9. Corrections from the three-reviewer pass, not otherwise visible above

All three reviewers returned DO NOT PROCEED and agreed on thirteen findings.
These are the ones whose fix is a deletion or a one-word change and would
otherwise leave no trace.

| was | is |
|---|---|
| "a literal predicate … never reaches a saved plansource" | only a **varying** literal misses; a constant literal hits, and R26 is a constant-literal measurement (§1) |
| "a narrow range predicate at scope 1 is exactly the cell where the deficit lives" | `projection`'s span-1 predicate is `id = :k`, the **key** shape. R1's `+28.6%` is the **range** row; key/span-1 is **−5.2%**. This is RESULTS.md's own regrouping hazard, repeated |
| "`pg_plan_query` is the 12.20 µs" | rewrite **and** plan together; the split is R27 |
| "nothing else re-plans … the source is half the planning work" | the fused DML re-plans per call under a bound parameter (4.1: 138.7 against 51.4 µs). Warm, the source is 12.20 against `SPI_prepare`'s 0.79 — ~94%, not half |
| "12.20 µs, 22% of a warm refresh" | 16.2% (R13, canonical); 12.20/61.6 = 19.8%; 22% has no protocol |
| "all seven of plancache's callbacks" | **eight**: one relcache + seven syscache |
| "all 21 shapes" | **23 defined** (`exh.sql` 10, `exh2.sql` 3, `exh3.sql` 10), **22 in `calibrate.baseline`**. R18's run really was over 21, so it is *stale, not wrong* — flagged there, and it needs re-running before the exit criteria in §8 can cite a count |
| step D "in the style `matview_where_inject` already uses" | that is the SQL-injection suite; the injection-*point* precedent is under `src/test/modules/injection_points/specs/` |
| §0 "task #17" | task IDs are session-local and mean nothing in this file; refer to items by their ISSUES.md or PLAN.md name |
