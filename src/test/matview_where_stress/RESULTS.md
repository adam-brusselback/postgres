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
| R13 | source plan caching | **12.2 µs faster** per refresh, **16.2%** at scope 1, ~0 at scale | fixed cost, so it only shows at scope 1 | SPECIALIZE.md §3; PLAN.md 3.7 | settled |
| R14 | deparse elision | **4.5–5.3 µs faster**, **7.4%** at scope 1 | as R13 | SPECIALIZE.md §3; PLAN.md 3.8 | settled |
| R15 | `Const` parameterisation | **8× faster**, by turning plan-cache misses into hits | PLAN.md 3.2 | SPECIALIZE.md §3 | settled |
| R16 | `ORDER BY` on the pre-lock, aligned vs not | ~~3.6×~~ | superseded by R10, which measures 1.2–1.7× | PLAN.md "The locking SELECT" | **superseded** |
| R17 | `FOR UPDATE` cost | the cost is the **locking, not the scan** — it defeats the index-only scan, 5.4 ms of 6.5 ms at scope 10000 | clean 100,000-row table | PLAN.md "The locking SELECT" | settled |

## Correctness instruments

| # | question | answer | protocol | derivation | status |
|---|---|---|---|---|---|
| R18 | differential harness | quiet on pristine (**21 shapes, 1533 mutations, 0 divergence**); loud under B4 (**76/96** and **12/48**) | two matviews, one base, refreshed each way and diffed | PLAN.md 1.1; `safety/rundiff.sh` | settled |
| R19 | concurrent fuzzer | M1 **76/160** deadlocks, M2 **40/80**, M3 **45** lost updates, M6 **55**; quiet on pristine | probabilistic; absence over N runs is not proof | PLAN.md 1.1b; `fuzz.sh` | settled |
| R20 | mutation corpus | **16/16 apply** against the current tree | `mutations.py --check`; an edit declares its expected occurrence count | ISSUES.md B23 | settled |
| R21 | what the oracle cannot see | P1 admits **no deterministic test**: a correct implementation has no window to exploit, so there is nowhere to put an injection point | — | PLAN.md 1.1b and 1.4 | settled |

## Retracted, and why — read before re-deriving

| # | claim | what happened |
|---|---|---|
| X1 | row comparison worth 72–78% | fresh-heap protocol. `bench_setup` hands the writing arm a heap with no free space and nothing dirtied since the last checkpoint, and only that arm writes. Worth 14–25 points. See R3, R5 |
| X2 | mutability is "the largest structural saving available" | reasoned from the prune sitting inside the phase that is 87% of a refresh (R2). A **share is not a saving**. Measured, it is smaller than the row comparison. See R6 |
| X3 | D1 is "D2 minus the commit cost" | inverts above scope 100. See R7 |
| X4 | "drop both `ORDER BY`s" is one decision | one saving and one regression, and the second is unresolvable. See R10, R11 |
| X5 | `+28.6%` does not reproduce | it does — the recheck regrouped it. See the header of this file, and R1 |
| X6 | a batch-scoped cache needs no invalidation because locks are held | false. `LockRelationOid()` calls `AcceptInvalidationMessages()`, so your own `table_open()` can invalidate what you cached. See SPECIALIZE.md §7a |
| X7 | B14 is fixed | reopened. "Frees at the next refresh" — and a nested refresh is the next refresh. See ISSUES.md B14 |

---

## Provenance hazards that have produced wrong answers here

Recorded once, in SPECIALIZE.md §6. Summarised only: cross-boot comparison;
fresh-heap bias; per-arm sample counts; integer division in a reporting query;
measuring under the noise floor. **Check R1–R21 before measuring anything** —
twice now, it had already been measured.
