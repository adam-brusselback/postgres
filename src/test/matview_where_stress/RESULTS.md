# Settled results — the index

Branch-local; delete with this directory.

Every measured number this project relies on, with **the protocol that produced
it** and **where the derivation lives**. This file owns no derivations. It
exists because two facts have already been re-derived — once wrongly — after
being recorded in one file and looked for in another.

**The rule this file enforces: a figure may not be quoted without its
protocol.** A number without its protocol is not a result, it is a rumour. Two
of the mistakes below were exactly that:

- `B16` sat "OPEN, unconfirmed" in ISSUES.md while PLAN.md 3.1 had closed it
  with a direct measurement. Answered twice, by different routes.
- `+28.6%` was retracted as unreproducible. PLAN.md 4.1 groups by **span**; the
  recheck grouped by **scope rows** — a different partition, since span 1 on
  `nonkey` is scope 100 — got different numbers, and read them as a
  contradiction. The figure was correct.

**Status values.** `settled` — measured, protocol recorded, reproduced.
`provisional` — measured once, or on a protocol since found biased.
`unresolvable` — the effect is smaller than the harness's own noise floor, and
no number should be quoted at all. `superseded` — kept because it is still
cited elsewhere and someone will otherwise re-derive it.

---

## Performance

| # | question | answer | protocol | derivation | status |
|---|---|---|---|---|---|
| R1 | generic vs custom plan | **21.7% slower** net; **+28.6%** on range/span 1 (best +72.8%), **−33.5%** on array/span 100 | 94 comparisons, 7 workloads × 3 shapes × 3 spans × 2 paths, 6 warm-ups; **grouped by span, not scope rows** | PLAN.md 4.1; `bench/optmatrix.sql`; `opt_result` | settled |
| R2 | where the time goes | source planning **16.2% → 0.9% → 0.0%** at scope 1/100/10k; fused DML **52% → 58% → 87%**; pre-lock **17.8% → 10.3%** | `INSTR_TIME` timers around every phase, `-O2`, 300 scope-1 refreshes, instrumentation reverted after | PLAN.md "Tier 1 and 2 sized" and "The locking SELECT, researched" | settled |
| R3 | row comparison, zero churn | **54–58% faster** on `nonkey`/scope 10000 | **settled heap**, VACUUM before each timed refresh, arms alternated, 15 samples | SPECIALIZE.md §1; `bench/churn.sql` | settled |
| R4 | row comparison vs churn | **54–56 → 41–51 → 27–36 → 18–27 → ≈0** at churn 0/5/25/50/100; break-even **60–70%** | as R3; ranges are two protocols disagreeing | SPECIALIZE.md §1; `bench/churn.sql` | settled |
| R5 | heap state | the same comparison reads **54% or 82%** on identical code, data and boot; **54% is the honest one** | 10 clones, novac bands vs VACUUM-before-each | SPECIALIZE.md §1; `bench/heapstate.sh` | settled |
| R6 | mutability | `no_delete` **13–19% faster** at scope ≥1000 (1.1% on `expensive`); `append_only` **+10–22 points** on top, **26–39%** total | fresh-clone model, **on top of** the row comparison, not instead of it | SPECIALIZE.md §1; `bench/mutability.sql` | settled |
| R7 | commit amortisation (D1 vs D2) | **3.5–3.7×** at scope 1, **1.25–1.9×** at scope 100, then **inverts** to 3.3× *slower* at scope 10000 | `bench/run.sh --perxact`, 20 refreshes per transaction vs 1 | ISSUES.md B16; SPECIALIZE.md §1 | settled |
| R8 | concurrency | **0 deadlocks, 0 failed txns, 0 serialization failures** over 54 cells; disjoint **3.4–5.9×** at 4 clients; `nonkey` range/scope 1000 hot **161 → 141 → 26 tps** at 1/4/16 | `bench/run.sh`, single boot verified from the server log | SPECIALIZE.md §1 and §5 | settled |
| R9 | match/merge crossover | **none.** Direct modification **1.31–1.63×** (`aggregate`) and **1.68–2.09×** (`timerange`) from 10% to 90% scope | measured before the routing change, so `bare`/`conc` stand in for the two algorithms | SPECIALIZE.md §5 | settled |
| R10 | pre-lock `ORDER BY` | **20–69% of the pre-lock** when misaligned, growing with scope; **4–26%** when aligned. The pre-lock is 12–15% of a refresh (R2), so ~3–10% of a refresh is **implied, not measured** | `bench/orderby.sh`, plain-heap clone, row comparison on so neither arm writes | SPECIALIZE.md §1 and §3 | settled |
| R11 | `ORDER BY`, whole-refresh | **do not quote a number.** Effect (1–7%) is below the floor | see R12 | `bench/orderby-floor.sh` | **unresolvable** |
| R12 | the noise floor | baseline wobbles **6.8–11.3%** between clones; **1 measurement in 40** lands **73% above** the median; no plan flips; position within a clone is inside the wobble | 10 clones, all forms timed on **each** clone | SPECIALIZE.md §6; `bench/orderby-floor.sh` | settled |
| R13 | source plan caching | **12.2 µs faster** per refresh, **16.2%** at scope 1, ~0 at scale.  **This is the canonical share — not 19.8% or 22%.**  It is the cost of the thing to be removed, measured as one line covering *rewrite and plan together*; the split is R27 and the saving cannot exceed the plan half | as R2, and a fixed cost, so it only shows at scope 1 | SPECIALIZE.md §3; PLAN.md 3.7; CACHE.md §1 | settled |
| R14 | deparse elision | **4.5–5.3 µs faster**, **7.4%** at scope 1 | as R13 | SPECIALIZE.md §3; PLAN.md 3.8 | settled |
| R15 | `Const` parameterisation | **8× faster**, by turning plan-cache misses into hits | PLAN.md 3.2 | SPECIALIZE.md §3 | settled |
| R16 | `ORDER BY` on the pre-lock, aligned vs not | ~~3.6×~~ | superseded by R10, which measures 1.2–1.7× | PLAN.md "The locking SELECT" | **superseded** |
| R17 | `FOR UPDATE` cost | the cost is the **locking, not the scan** — it defeats the index-only scan, 5.4 ms of 6.5 ms at scope 10000 | clean 100,000-row table | PLAN.md "The locking SELECT" | settled |
| R26 | **Query-tree path against text path, warm, CONSTANT LITERAL predicate** | **24% slower** at scope 1 (49.7 µs text against 61.6 µs Query-tree); confirmed at a different absolute level over three alternating pairs, 60.1 against 78.4, which is **30%**.  The whole deficit is one line: 12.20 µs re-planning the source query.  On a *cold* cache the Query-tree path **wins** (233 against 315 µs), because it skips `pg_get_viewdef` and re-parsing the view text | as R2 — `INSTR_TIME` timers, `-O2`, **`REFRESH ... WHERE id = 1` x300** on `projection`, whose span-1 predicate is `id = :k`.  **The predicate mode was unrecorded and three reviewers each had to infer it; it is a constant literal, so `params` is NULL and plancache serves a generic plan unconditionally** | PLAN.md "Tier 1 and 2 sized" and 3.1; CACHE.md §1 | settled |

## Correctness instruments

| # | question | answer | protocol | derivation | status |
|---|---|---|---|---|---|
| R18 | differential harness | quiet on pristine (**21 shapes, 1533 mutations, 0 divergence**) — **the run is stale, not wrong**: the corpus has since grown to **23 defined** (`exh.sql` 10, `exh2.sql` 3, `exh3.sql` 10) with **22 in `calibrate.baseline`**, so this needs re-running before it is quoted as current coverage; loud under B4 (**76/96** and **12/48**) | two matviews, one base, refreshed each way and diffed | PLAN.md 1.1; `safety/rundiff.sh` | settled |
| R19 | concurrent fuzzer | M1 **76/160** deadlocks, M2 **40/80**, M3 **45** lost updates, M6 **55**; quiet on pristine | probabilistic; absence over N runs is not proof | PLAN.md 1.1b; `fuzz.sh` | settled |
| R20 | mutation corpus | **16/16 apply** against the current tree | `mutations.py --check`; an edit declares its expected occurrence count | ISSUES.md B23 | settled |
| R21 | what the oracle cannot see | P1 admits **no deterministic test**: a correct implementation has no window to exploit, so there is nowhere to put an injection point | — | PLAN.md 1.1b and 1.4 | settled |
| R22 | the B14 use-after-free, and that its test is a test | **unfixed 249/250, fixed 250/250.** Test 5 fails on unfixed with `ERROR: cannot change materialized view "mv_c4_inner"` from a refresh of `mv_c4`; standalone reproducer shows `0x7F` fill in the error context | one `-O2 --enable-cassert` build, flipping only `matview.c` between arms, full `installcheck` each way | ISSUES.md B14 | settled |
| R23 | why the first version of that test passed | `REFRESH` runs under `RestrictSearchPath()`, so **unqualified names in a nested function do not resolve**; the `ALTER TABLE` raised, the `EXCEPTION` block swallowed it, the nested refresh never ran | observed directly by replacing the trap with `RAISE NOTICE` | ISSUES.md B14 | settled |
| R24 | same-matview nesting | **blocked**, by `CheckTableNotInUse()`: *"cannot REFRESH MATERIALIZED VIEW … because it is being used by active queries in this session"* | run, not read: `scratch/uaf/selfnest.sql` | ISSUES.md B14; RESULTS.md X8 | settled |
| R25 | the suite under `debug_discard_caches = 1` | **5/5 green**, first time it has been run. `matview_where` **85 s against 409 ms**, which is the evidence the setting was in effect rather than silently ignored | `pg_regress --dbname=regression_dcc` with `PGOPTIONS='-c debug_discard_caches=1'`, assert build | SPECIALIZE.md §7b | settled |

## Retracted, and why — read before re-deriving

| # | claim | what happened |
|---|---|---|
| X1 | row comparison worth 72–78% | fresh-heap protocol. `bench_setup` hands the writing arm a heap with no free space and nothing dirtied since the last checkpoint, and only that arm writes. Worth 14–25 points. See R3, R5 |
| X2 | mutability is "the largest structural saving available" | reasoned from the prune sitting inside the phase that is 87% of a refresh (R2). A **share is not a saving**. Measured, it is smaller than the row comparison. See R6 |
| X3 | D1 is "D2 minus the commit cost" | inverts above scope 100. See R7 |
| X4 | "drop both `ORDER BY`s" is one decision | one saving and one regression, and the second is unresolvable. See R10, R11 |
| X5 | `+28.6%` does not reproduce | it does — the recheck regrouped it. See the header of this file, and R1 |
| X6 | a batch-scoped cache needs no invalidation because locks are held | false. `LockRelationOid()` calls `AcceptInvalidationMessages()`, so your own `table_open()` can invalidate what you cached. See SPECIALIZE.md §7a |
| X7 | B14 is fixed | reopened once. "Frees at the next refresh" — and a nested refresh is the next refresh. Fixed again and now covered by R22; the retraction stays because the first fix was believed on a green suite that could not have caught it |
| X8 | the mismatch branch is a second use-after-free site, needing no invalidation | it is not. It frees only under the OID its own caller passed, and same-matview nesting is blocked before any cache code (R24). ISSUES.md already contradicted itself about this in two places. It is cache thrash, not memory-unsafety |
| X10 | 3.7 may not pay, because plancache will pick a custom plan and re-plan anyway | wrong cell.  R26 was measured with a **constant literal**, where `params == NULL` and `choose_custom_plan()` returns generic unconditionally.  The custom-plan risk is real only for a **bound parameter**, which is a different cell — and one already dominated by the fused DML's own re-planning (PLAN.md 4.1, 138.7 against 51.4 µs).  Three independent reviews caught this; see CACHE.md §1 and §9 |
| X11 | VACUUM before each timed refresh is the honest heap protocol, everywhere | only where one arm writes and the other does not (X1).  `vac_update_relstats()` updates `pg_class` in place, which implies a relcache invalidation, so on a plan-cache measurement it converts a **warm** cell into a **cold** one — and the Query-tree path already wins cold.  See CACHE.md §6 |
| X9 | a green suite means the fix is verified | the first B14 fix was believed this way, and so was the first version of its test (R23). **A test that has not been seen to fail is not evidence** — record both arms or record nothing |

---

## Provenance hazards that have produced wrong answers here

Recorded once, in SPECIALIZE.md §6. Summarised only: cross-boot comparison;
fresh-heap bias; per-arm sample counts; integer division in a reporting query;
measuring under the noise floor. **Check R1–R21 before measuring anything** —
twice now, it had already been measured.
