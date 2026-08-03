# Query plan caching in PostgreSQL: what exists, what's been tried, what's missing

Research notes, compiled 2026-08-03 against `master` @ `1ae87df63` (20devel).

Focus: the generic/custom plan decision (promotion and, especially, demotion), and
plan caching in RI/foreign-key triggers.

Release boundaries used below (from `Stamp HEAD as NNdevel` commits):
PG18 = 2024-07-01..2025-06-29, PG19 = 2025-06-29..2026-06-29, PG20 = after 2026-06-29.

---

## 1. What master actually does today

### 1.1 The decision point

Everything lives in `src/backend/utils/cache/plancache.c`. A `CachedPlanSource`
holds the analyzed query plus four counters (`src/include/utils/plancache.h:143-146`):

```c
double  generic_cost;       /* cost of generic plan, or -1 if not known */
double  total_custom_cost;  /* total cost of custom plans so far */
int64   num_custom_plans;   /* # of custom plans included in total */
int64   num_generic_plans;  /* # of generic plans */
```

The policy is `choose_custom_plan()` (`plancache.c:1174-1222`), called from
`GetCachedPlan()` (`plancache.c:1297`):

1. one-shot plans → custom;
2. no bound params, or nothing to re-plan → generic;
3. `plan_cache_mode` forces the answer if set;
4. `cursor_options & CURSOR_OPT_{CUSTOM,GENERIC}_PLAN` forces the answer;
5. **fewer than 5 custom plans so far → custom** (`plancache.c:1203`, the "arbitrary" 5);
6. otherwise: `generic_cost < total_custom_cost / num_custom_plans` → generic, else custom.

Custom-plan cost includes a planning-effort charge; generic-plan cost does not
(`cached_plan_cost(plan, include_planner)`, `plancache.c:1231`). The planning charge
is `1000 * cpu_operator_cost * (nrelations + 1)`, introduced by
`2aac3399a` (2013, Tom Lane) after 9.2 was found to over-prefer custom plans for
trivial statements. **That formula and the constant 5 have not changed since 2013.**

### 1.2 The only demotion that exists today

There is exactly one place where PostgreSQL backs out of a generic plan, and it is
immediate rather than adaptive — `GetCachedPlan()`, `plancache.c:1348-1367`:

```c
/* Update generic_cost whenever we make a new generic plan */
plansource->generic_cost = cached_plan_cost(plan, false);

/*
 * If, based on the now-known value of generic_cost, we'd not have
 * chosen to use a generic plan, then forget it and make a custom
 * plan.  This is a bit of a wart but is necessary to avoid a
 * glitch in behavior when the custom plans are consistently big
 * winners; ...
 */
customplan = choose_custom_plan(plansource, boundParams);
```

Before the generic plan is built, `generic_cost` is -1, which compares as cheaper
than any custom average — so the 6th execution *always* builds a generic plan
speculatively, then reconsiders once its real cost is known. If the generic plan
turns out expensive, it is discarded for this execution and a custom plan is built.
But the generic plan stays cached in `plansource->gplan`, and the comparison is
re-run on every subsequent call, so the statement keeps paying for custom planning
and can flip back and forth *at the cost level*.

### 1.3 Why the generic decision is effectively sticky

Once `choose_custom_plan()` starts answering "generic":

- `num_custom_plans` and `total_custom_cost` stop advancing (`plancache.c:1371-1383`
  only updates them on the custom branch), so `avg_custom_cost` is frozen at whatever
  the first five executions happened to see;
- `generic_cost` is only recomputed when a *new* generic plan is built, i.e. after an
  invalidation;
- nothing in the loop ever observes actual execution — no row counts, no timing.
  The comparison is estimated-cost vs. estimated-cost forever.

So there is a second, accidental demotion path: on sinval-driven replanning
(`RevalidateCachedQuery` → `CheckCachedPlan` fails → `BuildCachedPlan` generic), the
new `generic_cost` is compared against the *stale* five-execution custom average. That
comparison is explicitly left stale on purpose (`plancache.c:927-934`):

```c
/*
 * Note: we do not reset generic_cost or total_custom_cost, although we
 * could choose to do so.  If the DDL or statistics change that prompted
 * the invalidation meant a significant change in the cost estimates, it
 * would be better to reset those variables and start fresh; but often it
 * doesn't, and we're better retaining our hard-won knowledge about the
 * relative costs.
 */
```

That comment is the closest thing in the tree to an acknowledgement of the problem
the user is asking about. Note also `CopyCachedPlan()` (`plancache.c:1747-1750`)
propagates all four counters to the copy.

Practical summary matching field reports (e.g. Richard Yen,
*The Hidden Behavior of plan_cache_mode*, 2026-03-30): custom for 5 executions,
compare on the 6th, and if generic wins it is generic for the life of that session's
cached plan.

### 1.4 Escape hatches and observability that did land

| Feature | Commit | Release |
| --- | --- | --- |
| Redesigned plancache (generic/custom machinery as we know it) | `e6faf910d` (Tom Lane) | 9.2 |
| One-shot `CachedPlan` variant | `94afbd583` | 9.3 |
| Planning-cost accounting in the custom/generic comparison | `2aac3399a` | 9.3 |
| Parallel query allowed for generic plans | `682ce911f` | 11 |
| `plan_cache_mode` GUC (`auto`/`force_generic_plan`/`force_custom_plan`) | `f7cb2842b` (Peter Eisentraut) | 12 |
| `pg_prepared_statements.generic_plans` / `.custom_plans` | `d05b172a7` (Fujii Masao) | 14 |
| `EXPLAIN (GENERIC_PLAN)` | `3c05284d8` (Tom Lane) | 16 |
| SQL-language functions now use the plan cache (so they get custom plans too) | `0dca5d68d` (Tom Lane) | 18 |
| `PlannedStmt.planOrigin` — plan came from cache, generic vs custom | `719dcf3c4` / `e125e3600` (Sami Imseih) | 19 |
| `pg_stat_statements.generic_plan_calls` / `.custom_plan_calls` | `3357471cf` (Sami Imseih) | 19 |

The PG19 observability pair is the notable recent movement: for the first time you can
see the generic/custom split cluster-wide and per-queryid, not just per-session. That
was explicitly motivated as groundwork for tooling that reacts to bad decisions.

`plan_cache_mode` is a plain GUC, so the only per-statement control is
`SET`/`SET LOCAL` around the `EXECUTE`, or the C-level `cursor_options` flags used by
callers such as SPI (`CURSOR_OPT_CUSTOM_PLAN`, `parsenodes.h:3545`).

---

## 2. RI / foreign-key triggers

### 2.1 The historical design

`src/backend/utils/adt/ri_triggers.c` builds SQL text per constraint
(`SELECT 1 FROM pk x WHERE pkcol = $1 FOR KEY SHARE OF x` and friends), prepares it
through SPI, and caches the `SPIPlanPtr` in a process-lifetime dynahash keyed by
`RI_QueryKey` (constraint OID + query type). From the file header:

```
 *  across query and transaction boundaries, in fact they live as long as
 *  the backend does. ... The SPI plans they point to are saved using
 *  SPI_keepplan().  There is not currently any provision for throwing away
 *  a no-longer-needed plan --- consider improving this someday.
```

Key consequences:

- `ri_PlanCheck()` calls plain `SPI_prepare(querystr, nargs, argtypes)` with **no**
  cursor options, so RI check queries go through the *ordinary* `choose_custom_plan()`
  policy: 5 custom plans per constraint per backend, then generic. For the canonical
  `pkcol = $1` probe the generic plan is the right answer, so promotion happens fast
  and is stable — RI is the one workload where the current heuristic works well.
- `ri_FetchPreparedPlan()` re-checks `SPI_plan_is_valid()` and rebuilds the query text
  from scratch if invalid, because relation/column renames would otherwise leave stale
  SQL text.
- Nothing evicts entries, and `DISCARD ALL` does not drop them (there is a long-running
  pgsql-hackers thread, "Release SPI plans for referential integrity with DISCARD ALL",
  proposing exactly that).
- `c3ffe3486` (Tom Lane, PG14, from Keisuke Kuroda and Amit Langote) made all leaf
  partitions of a partitioned FK share one cached plan instead of one per partition —
  a direct memory fix for plan-cache blowup on large partition trees.

### 2.2 Attempts to get RI off the plan cache entirely

This is where most of the actual engineering has gone.

- **2020-2021, Amit Langote, "Avoid using SPI for some RI checks" / "simplifying
  foreign key/RI checks"**: replace the SPI query for the referenced-key existence
  check with a direct index probe.
- **2022-04-07, Álvaro Herrera, `99392cdd7` "Rewrite some RI code to avoid using SPI"**,
  reverted the same day by `a90641eac` with: *"We'd rather rewrite ri_triggers.c as a
  whole rather than piecemeal."* Related isolation tests (`00cb86e75`) covering snapshot
  behavior in `ri_triggers.c` were kept.
- **2026-03-31, `2da86c1ef` "Add fast path for foreign key constraint checks"**
  (Junwang Zhao, co-authored by Amit Langote) — PG19. The whole-rewrite finally landed
  in the form of a fast path that bypasses SPI and the plan cache for `RI_FKey_check`
  by probing the PK's unique index directly. ~1.8x on bulk FK inserts. It handles the
  things the SPI path got for free: permission checks (`ri_CheckPermissions()`),
  security context switch with `SECURITY_NOFORCE_RLS`, `LockTupleKeyShare` via
  `ri_LockPKTuple()`, and EPQ emulation via `recheck_matched_pk_tuple()` when the
  update chain was traversed.
  **Not covered** (still on SPI + plan cache): partitioned referenced tables, temporal
  constraints, and *all* action triggers — CASCADE, SET NULL, SET DEFAULT, RESTRICT,
  NO ACTION — because those must find and modify FK-side rows through the full
  executor. The commit message names extending the fast path to action triggers as
  future work needing new infrastructure.
- **2026-04-03, `b7b27eb41` "Optimize fast-path FK checks with batched index probes"**
  (Amit Langote, suggested by David Rowley) — PG19. Buffers up to 64 FK rows in a
  per-constraint `RI_FastPathEntry` and flushes them as one batch, sharing a single
  CCI, snapshot, permission check and security-context switch. Single-column FKs build
  an `ArrayType` and use `SK_SEARCHARRAY` so the index AM sorts/dedups and walks leaf
  pages once. ~1.6x on top of the previous commit (~2.9x combined). Introduced a
  general `AfterTriggerBatchCallback` mechanism in `trigger.c`.
  Follow-ups: `5c54c3ed1`, `980c1a85d` (scan key ordering for mismatched column order),
  `1b9dc2cb7`, and `6f4bac854` "Hardwire RI fast-path end-of-xact cleanup into xact.c"
  (2026-06-29, still PG19).
- **2026-06-05, `1fbe2066d` "refint: Remove plan cache"** (Nathan Bossart) — PG19.
  The `contrib/spi` refint module's per-backend plan cache was removed outright:
  `check_foreign_key()` embedded new key values in cascade-UPDATE queries so a cached
  plan reused stale values, and the cache was never invalidated. A small but pointed
  precedent: when a hand-rolled plan cache can't be invalidated correctly, deleting it
  was the accepted fix.

So the trajectory for RI is *away from* plan caching, not toward smarter plan caching.
The remaining SPI users are the action triggers and the partitioned/temporal cases.

---

## 3. Partitioning: the reason generic plans were unattractive

This matters to the promote/demote question because partitioned tables are where the
"generic plan is catastrophically worse" reports come from, and where the fix was
attempted at the executor level rather than in the decision heuristic.

- `AcquireExecutorLocks()` (`plancache.c`) locks *every* relation in the plan's range
  table before executing a cached generic plan. With thousands of partitions that is
  the dominant cost, and it happens before runtime pruning could eliminate them.
- `525392d57` (Amit Langote, 2025-02-20) "Don't lock partitions pruned by initial
  pruning" deferred those locks to `ExecDoInitialPruning()`, added
  `ExecutorStartCachedPlan()` / `UpdateCachedPlan()` to handle invalidation during the
  new window, and used `PlannedStmt.unprunableRelids` (from `cbc127917e`).
- Reverted 2025-05-22 by `1722d5eb0` on Tom Lane's objection: *"fragile and invasive
  design around plan invalidation handling ... violated assumptions about CachedPlan
  immutability and altered executor APIs in ways that are difficult to justify."*
  `PlannedStmt.unprunableRelids` still exists in `plannodes.h:113` but plancache.c no
  longer uses it — the scaffolding is still in the tree if someone wants to retry.
- The pgsql-performance thread "inefficient/wrong plan cache mode selection for queries
  with partitioned tables (postgresql 17)" (Maxim Boguk, with Tom Lane, David Rowley,
  Andrei Lepikhov, May 2025) is the best-documented statement of the user-facing
  problem: planning a custom plan over a large partition tree costs ~60ms while the
  generic plan plans in ~0.3ms, but the generic plan then locks every partition. The
  heuristic picks badly in both directions depending on the constant.
- Background reading: Amit Langote, *"Postgres: on performance of prepared statements
  with partitioning"* (amitlan.com, 2022-05-16); pganalyze 5mins E18.

---

## 4. Proposals aimed directly at the promote/demote logic

None of these are committed. Ordered roughly by how close they are to what you asked about.

### 4.1 Force custom plans when a parameter hits skewed data
*"Improvement discussion of custom and generic plans"* — Quan Zongliang
(`quanzongliang@yeah.net`), first posted 2024-02-19, message-id
`9365b39d-a748-4e61-9396-466689ea0aa5@yeah.net`.

Approach: teach the planner to notice that a `Const` originated from a `Param`, then in
`var_eq_const` (via a new `var_eq_const_ext`) check whether the compared column has
skewed statistics (MCV-heavy distribution). If so, set a new `PARAM_FLAG_SKEWEDSTAT`
flag on the parameter, which `choose_custom_plan()` consults to force a custom plan.

This is the closest published patch to "notice issues with specific shapes of query
parameters". Its weakness — raised in the thread — is that it is a *static* property of
the column, evaluated at plan time, not feedback from what the plan actually did.
The thread also contains the clearest articulation of the two failure modes of the
current heuristic: queries with no hope of benefiting still pay for 5 custom plans, and
queries that would benefit sometimes give up before ever seeing the parameter value
that would have justified replanning.

### 4.2 "Referenced generic plan mode"
Vlada Pogozhelskaya, posted 2025-09-04, `[PATCH] Referenced generic plan mode`,
patch attachment `0001-Referenced-optimisation-of-Generic-plans.patch`.

Adds `plan_cache_mode` values `ref_auto` and `force_ref_generic_plan`, an
`EXPLAIN (REF_GENERIC_PLAN)` option (not combinable with ANALYZE), and a flag that
prevents constant-folding of `Param`s when building a generic plan — so the generic
plan can be built *with reference to* actual parameter values without baking them in.
The submission explicitly cites the prior art you'd want to compare against: Oracle
Adaptive Cursor Sharing, SQL Server Parameter Sensitive Plan optimization, Db2 REOPT.

### 4.3 Make the forced modes less blunt
Andrei Lepikhov, 2025-07-15, *"Let plan_cache_mode to be a little less strict"* /
"Make the plan cache forced modes more flexible". Today `force_generic_plan` overrides
an explicit `CURSOR_OPT_CUSTOM_PLAN` request from a caller or extension. The proposal
inverts precedence so `cursor_options` wins, turning the GUC from "forced" into
"default". Small, but it is the enabling change for any extension that wants to make
per-statement decisions.

### 4.4 Per-block control in PL/pgSQL (historical, became the GUC)
Pavel Stehule, *"PoC plpgsql - possibility to force custom or generic plan"* — a
`PRAGMA PLAN_CACHE` at block level. Robert Haas argued it should be a GUC set for the
scope of a block; Peter Eisentraut noted the behavior is runtime, not lexical. The
outcome was `plan_cache_mode` (`f7cb2842b`, PG12). Worth reading for the design
rationale of why control landed as a session GUC rather than per-statement syntax.

### 4.5 Autoprepare / statement generalization / global plan cache
Konstantin Knizhnik (Postgres Professional), *"Cached plans and statement
generalization"* and *"Cached/global query plans, autopreparation"*, 2017-2019.
Auto-parameterizes unparameterized queries and caches plans in an LRU
(`autoprepare_limit`); reported >2x on read-only pgbench through pgbouncer. Rejected —
core developers objected that it overrides the application's deliberate choice of
unnamed statements and would hurt more cases than it helps. Relevant here mainly as
evidence for how the community reacts to implicit plan caching for arbitrary queries.

### 4.6 pg_plan_advice (in tree, contrib-adjacent)
Robert Haas's `pg_plan_advice` work is present in master (2026: `6455e55b0`,
`e0e4c132e`, `b335fe56f`). It's a plan-shape advice/hint mechanism rather than a plan
cache change, but it is the current in-tree answer to "I know better than the planner
for this query shape", and any demotion mechanism would want to compose with it.

---

## 5. Out-of-core implementations of the feedback loop you described

### 5.1 pg_mentor (Andrei Lepikhov / danolivo)
<https://github.com/danolivo/pg_mentor> — the closest existing implementation of
promote-then-demote using observed behavior. It reads `pg_stat_statements` and
maintains a shared hash of queryId → plan cache mode. Its "Plain Switch Strategy" is
worth reproducing because it's a concrete answer to "how would you decide?":

1. **Probe looks-good-to-be-generic**: for a statement with no reference stamp, if
   `(max-min)/mean_exec_time <= 2.0` OR `total_exec_time <= total_plan_time`, force
   generic and stamp `total_exec_time` as the reference time (RT).
2. **Detect a bad promotion**: for a generic-forced statement with an RT stamp, if
   `total_exec_time / RT > 2.0`, demote to custom and re-stamp. (Marks the statement
   "fixed" afterwards to prevent oscillation.)
3. **Probe looks-good-to-be-custom**: for a core-chosen generic plan, if execution is
   *unstable* (`(max-min)/mean_exec_time > 2`) AND `total_exec_time > total_plan_time`,
   force custom.
4. **Detect a bad demotion**: for a custom-forced statement, if
   `RT / total_exec_time < 2.0` (custom didn't buy enough), go back to generic.
5. Reset `pg_stat_statements` and repeat.

Its own notes list the hard parts: preventing oscillation (a switch counter / time
window), remembering previous states so you don't cycle 4→2, and the fact that
`total_exec_time` includes `total_plan_time`. Also: `pg_mentor_nail_long_planned()`
forces generic wherever max execution time is below average planning time — the
cheapest useful heuristic in the whole space.

Companion writeup: Lepikhov, *"On Postgres Plan Cache Mode Management"*
(danolivo.substack.com).

### 5.2 Aurora PostgreSQL shared plan cache
Aurora 16.10+/17.6+ (announced 2026-01) added a cross-backend shared cache of **generic
plans** keyed by query string + planner GUCs (incl. `search_path`) + userid + dbid,
configured via `apg_shared_plan_cache.enable` / `.max`. It solves the *memory
duplication* problem (a cited 40GB → 400MB), not the promote/demote decision. Useful as
the reference point for what a shared plan cache key has to include.

### 5.3 Research
- Kepler: *Robust Learning for Faster Parametric Query Optimization* (arXiv 2306.06798)
  — learned plan selection for parameterized queries; directly the "different plan per
  parameter shape" idea.
- PARQO: *Penalty-Aware Robust Plan Selection* (arXiv 2406.01526).
- Knizhnik's Adaptive Query Optimization (AQO) work, discussed on -hackers 2019.

---

## 6. Gaps — where the work isn't

If you're looking for something to build, these are the holes as of `master`:

1. **No execution feedback reaches the plan cache at all.** `choose_custom_plan()` sees
   only planner cost estimates. Nothing records actual rows or actual time per
   `CachedPlanSource`. The `planOrigin` field (PG19) plus pg_stat_statements counters
   now make the *decision* observable, but the loop is still open — the information
   flows out to monitoring, never back in.
2. **The custom-cost average is never refreshed after promotion.** Even without
   execution feedback, an obvious increment is periodically re-sampling a custom plan
   (say, 1 in N executions after promotion) and letting `total_custom_cost` keep
   moving. That alone would make demotion possible with existing infrastructure. The
   cost is one extra planning cycle per N executions.
3. **The counters are never reset on invalidation, deliberately** (`plancache.c:927`).
   ANALYZE that materially changes selectivity does not reconsider the decision except
   through the stale comparison described in §1.3.
4. **No per-parameter-value plan variants.** One generic plan per `CachedPlanSource`,
   full stop. Everything in §4.1/§4.2 is trying to route around this rather than add a
   second cached plan keyed by parameter class, which is what Oracle ACS and SQL Server
   PSP actually do.
5. **The 5 and the `1000 * cpu_operator_cost * (nrelations + 1)` planning charge are
   unconfigurable constants from 2013.** Making them GUCs has been floated repeatedly
   (Tom Lane pushed back in the partitioned-table thread, preferring the planner learn
   to skip work it knows the executor can prune).
6. **RI action triggers and partitioned/temporal FK checks are still on SPI plans** with
   a per-backend, never-evicted, never-`DISCARD`-able cache. Extending the `2da86c1ef`
   fast path to action triggers is named as future work in the commit message itself.
7. **`plan_cache_mode` has no per-statement form** — no `PREPARE ... USING GENERIC PLAN`,
   no per-queryid setting in core. §4.3 is the prerequisite for an extension supplying
   one.

A minimal, committable-shaped first step consistent with the above: keep counting
custom plans after promotion by re-planning occasionally, and let `choose_custom_plan()`
demote when the refreshed average beats `generic_cost`. It needs no new plan-cache
state, no executor changes, and no new invalidation hazards — the objections that sank
`525392d57`. The open question is the sampling rate and how to avoid oscillation, which
is exactly what pg_mentor's notes flag as the hard part.

---

## 7. Reference index

Commits (all in this repo, `git show <sha>`):

- `e6faf910d` 2011-09-16 — Redesign the plancache mechanism
- `94afbd583` 2013-01-04 — One-shot CachedPlans
- `2aac3399a` 2013-08-24 — Account better for planning cost in custom/generic choice
- `682ce911f` 2017-10-27 — Parallel query for generic plans
- `f7cb2842b` 2018-07-16 — Add plan_cache_mode setting
- `d05b172a7` 2020-07-20 — generic_plans/custom_plans in pg_prepared_statements
- `c3ffe3486` 2021-03-10 — Avoid duplicate cached plans for inherited FK constraints
- `99392cdd7` / `a90641eac` 2022-04-07 — Rewrite RI code to avoid SPI, and its revert
- `00cb86e75` 2022-04-07 — Isolation tests for snapshot behavior in ri_triggers.c
- `3c05284d8` 2023-03-24 — EXPLAIN (GENERIC_PLAN)
- `cbc127917e` — PlannedStmt.unprunableRelids
- `525392d57` 2025-02-20 / `1722d5eb0` 2025-05-22 — Don't lock pruned partitions, and its revert
- `0dca5d68d` 2025-04-02 — SQL-language functions use the plan cache
- `719dcf3c4` 2025-07-24 / `e125e3600` — PlannedStmt cached-plan-type tracking
- `3357471cf` 2025-07-31 — pg_stat_statements generic/custom plan counters
- `2da86c1ef` 2026-03-31 — Fast path for FK constraint checks (bypasses SPI)
- `b7b27eb41` 2026-04-03 — Batched index probes for fast-path FK checks
- `5c54c3ed1`, `980c1a85d`, `1b9dc2cb7`, `6f4bac854` — fast-path follow-ups
- `1fbe2066d` 2026-06-05 — refint: Remove plan cache

Threads and writeups:

- Improvement discussion of custom and generic plans — <https://www.postgresql.org/message-id/9365b39d-a748-4e61-9396-466689ea0aa5%40yeah.net>
- [PATCH] Referenced generic plan mode — <https://www.mail-archive.com/pgsql-hackers@lists.postgresql.org/msg206119.html>
- Let plan_cache_mode to be a little less strict — <https://www.postgresql.org/message-id/458ace73-4827-43e1-8a30-734a93d4720f@gmail.com>
- inefficient/wrong plan cache mode selection for queries with partitioned tables — <https://www.postgresql.org/message-id/34dbb623-e7ef-403f-b7b1-082c856f897e%40gmail.com>
- generic plans and "initial" pruning — <https://www.postgresql.org/message-id/CA%2BHiwqFGkMSge6TgC9KQzde0ohpAycLQuV7ooitEEpbKB0O_mg%40mail.gmail.com>
- PoC plpgsql - possibility to force custom or generic plan — <https://www.postgresql.org/message-id/CA+TgmobgD_UZRs44cOutY1odNbR0C_HJSxvx_dMREvz-CwuiaQ@mail.gmail.com>
- Cached plans and statement generalization (autoprepare) — <https://postgrespro.com/list/thread-id/2317092>
- track generic and custom plans in pg_stat_statements — <https://www.postgresql.org/message-id/CAA5RZ0uFw8Y9GCFvafhC=OA8NnMqVZyzXPfv_EePOt+iv1T-qQ@mail.gmail.com>
- FK fast path — <https://postgr.es/m/CA+HiwqF4C0ws3cO+z5cLkPuvwnAwkSp7sfvgGj3yQ=Li6KNMqA@mail.gmail.com>
- pg_mentor — <https://github.com/danolivo/pg_mentor>
- On Postgres Plan Cache Mode Management — <https://danolivo.substack.com/p/on-postgres-plan-cache-mode-management>
- The Hidden Behavior of plan_cache_mode — <https://richyen.com/postgres/2026/03/30/plan_cache_mode.html>
- Postgres: on performance of prepared statements with partitioning — <https://amitlan.com/2022/05/16/param-query-partition-woes.html>
- Using the shared plan cache for Amazon Aurora PostgreSQL — <https://aws.amazon.com/blogs/database/using-the-shared-plan-cache-for-amazon-aurora-postgresql/>
