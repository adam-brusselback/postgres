# One algorithm, several specialisations — the Phase 4 design

Both `REFRESH ... WHERE` forms converge on the general algorithm: lock the
scope, evaluate the source, fused upsert/prune. Match/merge leaves the predicate
path unless a measurement finds a workload it fits perfectly. What remains is
deciding, per call, which parts of the general algorithm to skip — and *where*
that decision can be made.

Written because the axis set changed three times in one sitting, each addition
invalidating a recommendation already made.

---

## 1. The axes

| axis | values | selects | evidence |
|---|---|---|---|
| **scope** | 1 · small · large · near-total | prune elision; whether fixed costs matter at all | measured: source planning 16.2% → 0.9% → 0.0% of the refresh at scope 1/100/10k, while the fused DML goes 52% → 58% → **87%** |
| **predicate shape** | equality on all arbiter key columns · array · range · non-key | at-most-one-row proofs; whether the index supplies the lock order | measured: generic plan +28.6% on range/1, −33.5% on array/100. `ORDER BY` on the lock is free when the arbiter index matches the predicate column, **3.6×** when not — it hands `LockRows` the heap in random rather than physical order |
| **index shape** | do the updated columns sit under any index? | whether an avoided write saves index maintenance or just a HOT update | measured: row comparison worth 27–53% with a covering index, **nothing** without |
| **churn fraction** | share of the scope whose values actually changed | whether the row comparison pays | **unmeasured** — only the 100%-unchanged extreme. Scope was used as a proxy; it correlates (D1 small/high-churn, D3 large/low-churn) so the gate is right by luck, not argument |
| **driver pattern** | D1 statement trigger · D2 queue drain · D3 scheduled window | frequency, transaction context, and the priors for every axis above | `USE-CASES.md` §157. D1 runs inside the writer's transaction; D2 commits per refresh (**12×**, and it is commit cost — the re-planning hypothesis was tested and disproven); D3 runs nightly. **`bench/run.sh` commits per refresh, so every number so far describes D2 alone** |
| **overlap probability** | none · concurrent-disjoint · concurrent-overlapping | whether the lock and its ordering buy anything | **unmeasured** — every run has been `--clients 1 --overlap disjoint` and both knobs have existed throughout. Cost/benefit is inverted: the lock costs most where it buys least (D3, one refresher, huge scope) |
| **mutability** | append-only · no-delete · general | whether the prune exists at all | **unmeasured**, and barely covered — `USE-CASES.md` mentions append-only once, about a ledger *base table*. Different property: a ledger is append-only and its `GROUP BY` roll-up is rewritten constantly |

Mutability is the largest structural saving available, because the prune sits
inside the phase that is 87% of a large refresh. What matters is whether the
view's output *for a scope* can lose a row: **append-only** kills the prune and
makes the upsert `DO NOTHING` — one idempotent `INSERT ... SELECT`;
**no-delete** kills the prune and keeps `DO UPDATE`, removing the anti-join and
the second scan of the scope.

---

## 2. What is observable, and where

Four tiers. The load-bearing content is what each tier **cannot** see.

### Tier 1 — static, on a plan-cache miss

A property of the request's shape, not of the data. Computed once, stored in
the cache entry, read as a byte thereafter.

| observable | how |
|---|---|
| qual is a conjunction of equalities covering every arbiter key column | walk the qual, match operators against the index opclass's equality operator |
| predicate's leading column is the index's leading column | compare attnums |
| do the columns the upsert writes intersect any index? | `RelationGetIndexAttrBitmap(rel, INDEX_ATTR_BITMAP_ALL)` — relcache-cached, already built |
| arbiter arity and key nullability | already read from `indexStruct` |

**Cannot see cardinality.** It distinguishes "at most one row, provably" from
"unknown" and nothing else — `id = $1` and `tenant = $1` are indistinguishable
here, though one is a row and the other may be ten million. Anything gated on a
*row count* rather than a shape cannot live in this tier, which rules out
deciding the row comparison here: its break-even is a count.

### Tier 2 — post-materialise

Once the tuplestore is filled: `tuplestore_tuple_count()`, hence "is the source
empty".

**The plans are already built.** An observable arriving after `SPI_prepare` can
only *select among* plans that already exist, and each alternative costs a
prepare on the miss plus a cache slot. Budget: two or three variants, not a
family — an "upsert only" and a "prune only" beside the fused statement.

**Cannot see the matview side.** It knows what the *view* produced, not what
the matview currently holds in scope. So "the prune is a no-op" does not follow
from a non-empty source in general — only under Tier 1's at-most-one-row proof,
where both sides are bounded by one. Getting that wrong strands rows the view
no longer produces.

### Tier 3 — adaptive, across refreshes of one cache entry

The entry already survives refreshes, holds the plans, and is invalidated
correctly. Two counters — `rows_in_scope` and `rows_changed` over the last N
refreshes — give the churn fraction no static test can.

Three non-negotiable properties:

- **A hint, never an input to correctness.** Counters reset on any invalidation
  and start empty in every backend. Anything *wrong* rather than *slow* without
  them does not belong here.
- **Hysteresis.** Flipping around a threshold re-prepares the statement each
  time, costing more than either choice.
- **Keyed on (matview, predicate, arbiter), not on the call site.** Two
  predicates get two independent histories, which is right. One predicate driven
  by two callers with different churn gets one blended history, which is not —
  and is where a declaration beats adaptation.

**Cannot see anything on its first call**, which for D3 — nightly, one call —
is every call.

### Tier 4 — declared

Mutability and overlap probability are properties of the deployment, not
functions of the statement, the data, or the history. **Guessing either wrong
is silent corruption, not a slow query** — that, not difficulty, is what puts
them in their own tier.

That is a real cost: a reloption is user-visible surface, and the on-list
question will be why the server cannot work it out. The answer must be that it
cannot, and that the failure is silent. So a declaration needs a cheap way to
catch itself being wrong:

- **`no_delete` / `append_only`** — run the prune anyway on a sampled fraction
  of refreshes and `WARNING` if it would have deleted anything. Trust becomes
  trust-but-verify; a wrong declaration surfaces in the log rather than as rows
  that quietly never leave.
- **overlap** — needs no verifier because it should not exist. See §3e.

**Nowhere observable: frequency and transaction context.** They belong in the
documentation, and they are why a benchmark that commits once per refresh
describes one driver pattern rather than the feature.

---

## 3. The specialisations

Each states what it changes, which tier decides it, and **which detector
catches it if it is wrong** — a detector nobody has watched catch anything is
the same defect as a test that cannot fail.

| specialisation | tier | effect | detector |
|---|---|---|---|
| **row comparison** — `WHERE (mv.cols) IS DISTINCT FROM (EXCLUDED.cols)` on the `DO UPDATE`. *Implemented*, currently a GUC; should be T3 churn with a T1 veto when no index covers a written column | 3 + 1 | +27–53% at scope ≥100 with a covering index; **−18.5% at scope 1**; nil without the index | oracle — 22 shapes, 1636 mutations, 0 divergences |
| **cache the source plan** — removes rewrite + plan from every refresh | — | 12.2 µs, 16.2% at scope 1, ~0 at scale | `matview_where_cache` 1–3, which need a **base-table** variant: a stashed `PlannedStmt` is not revalidated when a base table changes, so this must go through the plancache, not a pointer |
| **stop deparsing for the cache key** — store the qual tree, compare with `equal()`, deparse only on a miss | — | 4.5–5.3 µs, 7.4% at scope 1. Closes **B3**: the tree carries parameter types, `$1` does not | `matview_where_cache` Test 4, already two predicates that deparse identically and need different plans |
| **parameterise predicate `Const`s** | — | **8×**, by turning cold refreshes warm | oracle. Changes what the cache key *is*, so it lands first or last, never in the middle |
| **skip the prune** when the source is non-empty | 1 + 2 | removes a scan and an anti-join; the empty-source mirror is the row-trigger delete path at *any* scope | **none yet** — see 3c |
| **drop both `ORDER BY`s** | 1 | small: the index already supplies the order in the aligned case | oracle |
| **drop the prune entirely** (`no_delete`), plus `DO NOTHING` (`append_only`) | 4 | unmeasured, and the only item that removes work from the 87% | sampling verifier, plus a `mutations.py` entry declaring `no_delete` on a view that deletes |

### 3c. The at-most-one-row proof, and why it needs a new detector

The qual is equality on every arbiter key column, so at most one matview row
matches. The source — the view under the same qual, unique on the arbiter key
because the upsert requires it — yields at most one row. If it produced that
row, the upsert writes it and the single row in scope *is* that row: nothing can
be orphaned and the anti-join cannot delete. If the source is empty, the mirror
holds and the refresh is the `DELETE` alone.

The oracle is single-session and will not see the hazard, which is concurrent:
another session inserting the key between the materialise and the DML. That is
the window `matview-where-prune-gap.spec` was built for, and this widens it. The
spec needs a variant with the elision on, **shown to fail against a naive
implementation before it is trusted with a correct one**.

### 3e. What must not be specialised, on any axis

**The pre-lock.** It looks removable at scope 1 — one row cannot have an
ordering problem — and that is wrong. Mutation M3 (remove the locking `SELECT`)
produced **45 lost updates** in `fuzz.sh` serial mode, and the mechanism is
scope-independent: a second session evaluates the source from a snapshot taken
before the first commits, blocks at the upsert, then writes a value computed too
early over the first session's result. `ON CONFLICT DO UPDATE` re-reads the row
for the *conflict*; the value it writes came from `new_data`.

The lock does not order rows within a scope. It stops a second refresh starting
before the first commits. A single-row scope needs that exactly as much, and so
does a deployment that believes it has no overlapping refreshes — which is why
overlap probability, alone among the seven axes, should not be declarable. The
one thing worth taking from that axis is `FOR NO KEY UPDATE` for rows that will
only be updated: identical acquisition cost (measured), fewer conflicts, so a
concurrency gain that will never appear in a single-client sweep.

### 3f. Order, and why

- `no_delete` / `append_only` **first** — largest, entirely unmeasured, and
  sizeable by hand-running the two statement forms against a corpus shape before
  any declaration exists.
- Source plan + deparse elision **together** — one change to the cache-entry
  miss path, not two.
- T3 churn gate next — turns the row comparison from a GUC into a decision.
- `Const` parameterisation after that, since it redefines the cache key.
- T2 prune elision **last**: `no_delete` subsumes its non-empty case, so only
  the empty-source path is left, and it is the one needing a new detector.

---

## 4. What convergence breaks

`matview_where` asserts `concurrently_blocks_writers = f` and
`bare_where_blocks_writers = t`. That holds today only because bare selects
match/merge, which takes `ExclusiveLock` as a side effect. Once both forms use
the general algorithm, bare stops blocking writers unless the conservative
posture is taken **deliberately** — a lock chosen for the syntax rather than
inherited from the algorithm. Those two assertions are the spec for that
decision, and they will go red at convergence, correctly.

---

## 5. Measurement gaps, in the order to close them

1. **Mutability** — nothing has ever been measured against an append-only or
   no-delete matview. Largest saving, zero data.
2. **Concurrency** — `--clients 4,16 --overlap hot`, plus `fuzz.sh`. The axis
   the lock exists to serve. Metric is throughput, deadlock rate and lost
   updates, not latency. Note `--overlap hot` today means "everyone fights over
   keys 1–10", one point rather than a sweep of intersection probability.
3. **Churn** — `--mutate on` across a varying changed-fraction.
4. **The match/merge crossover** — `run.sh` now skips any scope ≥90% of the
   matview, which is right for measuring partial refresh and removes exactly the
   region where match/merge would win if it wins anywhere. Needs a deliberate
   50/75/90/100% sweep with the guard lifted.
5. **Transaction context** — every run commits per refresh; D1 amortises into
   the writing transaction, D3 calls once a night.

---

## 6. State at time of writing

**Implemented and verified** — the row comparison
(`matview_partial_refresh_optimized`): oracle 22 shapes / 1636 mutations / 0
divergences, five `matview_where` suites green with it forced on.

**Sized, unimplemented** — source plan caching, deparse elision, `Const`
parameterisation.

**Measured and rejected** — forcing a generic plan (net −21.7% over 94
comparisons), the arbiter index scan (0.08 µs), the cache sweep (below timer
resolution), bypassing SPI (~2 µs per statement, not the ~20 a noisy run
suggested).

**Benchmark `p3opt`** — 4 of 7 workloads: `nonkey` +26–35%, others +4–16% at
scope ≥100, −18.5% at scope 1.
