# One algorithm, several specialisations — the Phase 4 design

Both `REFRESH ... WHERE` forms converge on the general algorithm (lock the
scope, evaluate the source, fused upsert/prune).  Match/merge leaves the
predicate path unless a measurement shows it fits some workload perfectly.
What remains is choosing, per call, which parts of the general algorithm to
skip.

This file exists because the axis set changed three times in one sitting, each
time because a real one had been left out, and each time it invalidated a
recommendation that had already been made out loud.  Writing them all down
first is cheaper than discovering the fourth one after implementing against
three.

---

## 1. The axes

Seven, not the two (scope, predicate shape) the measurements so far cover.

| axis | values | what it selects |
|---|---|---|
| **scope** | 1 · small · large · near-total | prune elision, batching, whether fixed costs matter at all |
| **predicate shape** | equality on all arbiter key columns · array · range · non-key | at-most-one-row proofs, whether the index supplies the lock order |
| **index shape** | are the updated columns indexed? | whether an avoided write saves index maintenance or just a HOT update |
| **churn fraction** | share of the scope whose values actually changed | whether the row comparison pays for itself |
| **driver pattern** | D1 statement trigger · D2 queue drain · D3 scheduled window | frequency, transaction context, and the priors for every axis above |
| **overlap probability** | none · concurrent-disjoint · concurrent-overlapping | whether the lock and its ordering buy anything |
| **mutability** | append-only · no-delete · general | whether the prune exists at all |

### Why each one earned its place

**Scope** — measured.  The phase profile inverts across it: rewriting the
source plan is 16.2% of a scope-1 refresh, 0.9% at 100 and 0.0% at 10,000,
while the fused DML goes 52% → 58% → 87%.  Every small-scope optimisation is
irrelevant at scale and vice versa.

**Predicate shape** — measured.  Forcing a generic plan is +28.6% on a narrow
range predicate and −33.5% on a wide array one; the sign follows the shape.
And the `ORDER BY` on the lock is free when the arbiter index matches the
predicate's column and costs 3.6× when it does not, because ordering by the
key hands `LockRows` the heap in random order where the scan had it in
physical order.

**Index shape** — measured.  Suppressing an unchanged row's write is worth
27–53% when an index covers an updated column and nothing at all when it does
not, because those updates are HOT and cheap to begin with.

**Churn fraction** — *not* measured, and it is the axis the row comparison
actually keys on.  Everything recorded for it is the 100%-unchanged extreme.
Scope was used as a proxy and happens to correlate — D1 has the smallest scope
and the highest churn, D3 the largest scope and the lowest — so the
scope-based gate is right, but by accident rather than by argument.

**Driver pattern** — `USE-CASES.md` §157.  D1 fires per statement inside the
writer's transaction; D2 commits once per refresh, which is a 12× difference
that is commit cost and not re-planning (measured, and the re-planning
hypothesis was disproven); D3 runs nightly, where per-call fixed costs are
irrelevant by definition.  All of `bench/run.sh` commits once per refresh, so
every number recorded so far describes D2 and only D2.

**Overlap probability** — the lock's whole reason for existing, and entirely
unmeasured: every run has been `--clients 1 --overlap disjoint`, and both
knobs have existed since the beginning.  The cost/benefit is inverted along
this axis — the lock costs most where it buys least (D3, one refresher, huge
scope) and is cheapest where it is indispensable (D1, many overlapping
writers, small scope).

**Mutability** — raised late and barely covered: `USE-CASES.md` mentions
append-only once, about a *ledger base table*, which is a different property.
A ledger is append-only and its `SUM(...) GROUP BY account` roll-up is updated
constantly.  What matters is whether the view's output *for a given scope* can
lose or change a row:

- **append-only** — rows only ever added.  The prune is dead, and `ON CONFLICT`
  becomes `DO NOTHING`: the refresh is one idempotent `INSERT ... SELECT`.
- **no-delete** — rows added or changed but never disappear from a scope.  The
  prune is dead; `DO UPDATE` stays.  Probably the more common of the two, and
  it removes the anti-join and the second scan of the scope.
- **general** — what is implemented today.

This is the largest structural saving on the list, because the prune is inside
the phase that is 87% of a large refresh.

---

## 2. What is observable, and where

The specialisation cannot be decided in one place, because the axes are not
knowable in one place.  Four tiers:

| tier | when | axes | cost |
|---|---|---|---|
| **static** | once, on a plan-cache miss | predicate shape, index shape, arbiter/predicate alignment | free per refresh — a byte in the cache entry |
| **post-materialise** | after the tuplestore is filled | source row count, hence "is the source empty" | `tuplestore_tuple_count()`, free |
| **adaptive** | across refreshes of the same cache entry | churn fraction, typical scope | two counters and an increment |
| **declared** | DDL or statement | mutability, overlap probability | nothing at run time |

The third tier is the interesting one and it is not speculative: the cache
entry already survives across refreshes, already carries the plans, and is
already invalidated correctly.  Adding "rows in scope" and "rows actually
changed" over the last few calls gives the churn fraction that no static test
can, for the price of two integers.  It is the same shape as plancache's own
custom-versus-generic decision, applied to our decision.

The fourth tier is the uncomfortable one.  **Overlap probability and
mutability are properties of the deployment, not of the call**, and guessing
either wrong is a correctness bug rather than a slow query.  They have to be
declared — a reloption, or a statement-level modifier — defaulting to the safe
side.  Frequency and transaction context are not observable at all and belong
in documentation.

---

## 3. The specialisations

| specialisation | gated on | measured effect |
|---|---|---|
| skip the row comparison | scope 1, or low churn | −18.5% at scope 1 if applied wrongly; +27–53% at scope ≥100 with the right index |
| skip the prune when the source is non-empty | at-most-one-row (static) | unmeasured; removes a scan and an anti-join |
| **drop the prune entirely** | `no-delete` or `append-only` (declared) | unmeasured; targets the 87% |
| **`ON CONFLICT DO NOTHING`** | `append-only` (declared) | unmeasured |
| drop both `ORDER BY`s | at-most-one-row (static) | small — the index already supplies the order in the aligned case |
| cache the source plan | always | 12.2 µs, 16.2% at scope 1, ~0 at scale |
| stop deparsing for the cache key | always | 4.5–5.3 µs, 7.4% at scope 1 |
| parameterise predicate `Const`s | always | 8×, by turning every cold refresh warm |

### What must not be specialised

**The pre-lock, on any axis.**  It looks removable at scope 1 — one row cannot
have an ordering problem — and that reasoning is wrong.  Mutation M3 (remove
the locking `SELECT`) produced **45 lost updates** in `fuzz.sh` serial mode,
and the mechanism is scope-independent: without it a second session evaluates
the source from a snapshot taken before the first commits, blocks at the
upsert, and then writes a value computed too early over the first session's
result.  `ON CONFLICT DO UPDATE` re-reads the row for the *conflict*; the
value it writes came from `new_data`.

The lock is not there to order rows within a scope.  It is there to stop a
second refresh starting before the first commits.  Single-row scopes need that
exactly as much.

---

## 4. What convergence breaks

`matview_where` asserts `concurrently_blocks_writers = f` and
`bare_where_blocks_writers = t`.  That holds today only because bare selects
match/merge, which takes `ExclusiveLock` as a side effect.  When both forms use
the general algorithm, bare stops blocking writers unless the conservative
posture is taken **deliberately** — a lock chosen for the syntax rather than
inherited from the algorithm.  Those two assertions are the spec for that
decision and will go red the moment the paths converge, which is correct.

---

## 5. Measurement gaps, in the order they should be closed

1. **Concurrency.**  `--clients 4,16 --overlap hot`, plus `fuzz.sh`.  The
   largest unmeasured region, and the one the lock exists to serve.  The metric
   is throughput, deadlock rate and lost-update count, not latency.  Note
   `--overlap hot` today means "everyone fights over keys 1–10", one point on
   the axis rather than a sweep of intersection probability.
2. **Churn.**  `--mutate on` with a varying changed-fraction.  Everything about
   the row comparison rests on the 100%-unchanged extreme.
3. **The match/merge crossover.**  `run.sh` now skips any scope ≥90% of the
   matview — right for measuring partial refresh, and it removes exactly the
   region where match/merge would win if it wins anywhere.  Deciding whether it
   survives needs a deliberate sweep at 50/75/90/100% with that guard lifted.
4. **Transaction context.**  Every run commits once per refresh, which is D2's
   shape.  D1 amortises into the writing transaction; D3 calls once a night.
5. **Mutability.**  Nothing has ever been measured against an append-only or
   no-delete matview, because the concept did not exist here until now.

---

## 6. State when this was written

Implemented and verified: the conditional `DO UPDATE`
(`matview_partial_refresh_optimized`), differential oracle 22 shapes / 1636
mutations / 0 divergences against the unoptimised Query-tree path, five
`matview_where` suites green with it forced on.

Sized but not implemented: caching the source plan, dropping the deparse from
the cache key, parameterising `Const`s.

Measured and rejected: forcing a generic plan (net −21.7% across 94
comparisons), the arbiter index scan (0.08 µs), the cache sweep (below timer
resolution), bypassing SPI (~2 µs per statement, not the ~20 a noisy run
suggested).

Three-way benchmark `p3opt`: 4 of 7 workloads, `nonkey` +26–35%, others
+4–16% at scope ≥100, −18.5% at scope 1.
