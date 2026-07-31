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
| **index shape** | do the updated columns sit under any index? | whether an avoided write saves index maintenance or just a HOT update | measured: row comparison worth 27–53% with a covering index, **nothing** without. The magnitude is fresh-heap and overstated (see heap state); the *presence/absence* result is not, since both arms of it write |
| **churn fraction** | share of the scope whose values actually changed | whether the row comparison pays | measured, `bench/churn.sql`: on `nonkey`/scope 10000 the saving runs **54–56 → 41–51 → 27–36 → 18–27 → ≈0%** at churn 0/5/25/50/100 (range = two protocols). Monotonic, and it reaches zero — at full churn every comparison fails and the row-wise `IS DISTINCT FROM` is bought for nothing. Break-even ≈ 60–70% |
| **heap state** | never-updated · settled · bloated | nothing — but it decides the *measured* value of everything above | measured, `bench/heapstate.sh`: **the same comparison reads 54% or 82% depending on it.** At zero churn only the un-optimized arm writes, so free space, full-page images, extension and bloat all land on one side. A matview `bench_setup` just built is that arm's worst case; every figure taken straight after a setup is inflated |
| **driver pattern** | D1 statement trigger · D2 queue drain · D3 scheduled window | frequency, transaction context, and the priors for every axis above | measured, `--perxact`: amortising the commit over 20 refreshes (D1) is worth **3.5–3.7× at scope 1**, **2.1–3.1× at scope 10**, **1.25–1.9× at scope 100** — then *inverts*, costing **2.1× at scope 1000 and 3.3× at scope 10000**, because 20 successive rewrites of one scope inside one transaction build update chains nothing can prune until it commits. D1 is not "D2 minus the commit" |
| **overlap probability** | none · concurrent-disjoint · concurrent-overlapping | whether the lock and its ordering buy anything | measured, 54 cells: **zero deadlocks, zero failed transactions, zero serialization failures.** Disjoint scopes scale 3.4–5.9× from 1 to 4 clients and flatten at 16. Overlapping is where it bites — `nonkey` range/scope 1000 hot goes 161 → 141 → **26** tps as clients go 1 → 4 → 16, a collapse the lock is doing on purpose |
| **mutability** | append-only · no-delete · general | whether the prune exists at all | measured, `bench/mutability.sql`, against the row comparison already on: dropping the prune (`no_delete`) is worth **13–19%** at scope ≥1000 (1.1% on `expensive`, where GIN maintenance dominates), and `DO NOTHING` on top of it (`append_only`) adds **10–22 points** for a total of **26–39%**. Fresh-heap protocol, but at zero churn every form compared writes little, so the bias is small here |

What mutability turns on is whether the view's output *for a scope* can lose a
row: **no-delete** kills the prune and keeps `DO UPDATE`, removing the anti-join
and the second scan of the scope; **append-only** kills the prune *and* makes
the upsert `DO NOTHING` — one idempotent `INSERT ... SELECT`.

This was written down as "the largest structural saving available", on the
argument that the prune sits inside the phase that is 87% of a large refresh.
Measurement does not support it. 13–19%, and a further 10–22 points, is worth
having — but the row comparison, already implemented, is worth more, and
mutability's share of the 87% turned out to be smaller than its share of the
statement text. The estimate was reasoning about which phase the work sat in
rather than how much work it was.

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
empty". And, once the pre-lock and the upsert have run, three counts that turn
out to decide more than the emptiness test does — rows the pre-lock matched,
rows the upsert inserted, rows the source produced. If
`n_locked + n_inserted == n_source` then every source row is accounted for by a
matview row that already existed or one just created, so nothing in scope is
orphaned and the prune cannot delete. That is `no_delete`, derived per refresh
rather than declared for all time — see Tier 4.

**The plans are already built.** An observable arriving after `SPI_prepare` can
only *select among* plans that already exist, and each alternative costs a
prepare on the miss plus a cache slot. Budget: two or three variants, not a
family — an "upsert only" and a "prune only" beside the fused statement.

**The source count alone cannot see the matview side.** It knows what the *view*
produced, not what the matview currently holds in scope, so "the prune is a
no-op" does not follow from a non-empty source — that inference needs Tier 1's
at-most-one-row proof, where both sides are bounded by one. Getting it wrong
strands rows the view no longer produces.

The three-count test above escapes that because `n_locked` **is** matview-side:
the pre-lock counts rows the matview holds in scope right now, under a lock that
stops them changing. Source, existing and inserted are then three sides of the
same accounting, and no proof about the predicate's shape is needed. This is the
only place in the design where a cheap runtime count replaces a static proof
outright, which is why it moved `no_delete` out of the declared tier entirely.

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

### Tier 4 — declared, and why almost nothing should be

This tier was for mutability and overlap probability: properties of the
deployment rather than functions of the statement, the data, or the history.
**Guessing either wrong is silent corruption, not a slow query** — that, not
difficulty, is what put them here.

Most of what was in it has since left, for different reasons. What remains is
one item, and the reasons the others left are the argument for treating that one
sceptically too:

- **overlap** — should not be declarable at all. A deployment that believes it
  has no overlapping refreshes needs the lock exactly as much as one that knows
  it does. See §3e.
- **`no_delete`** — need not be declared, because the algorithm already computes
  it. The fused statement knows how many source rows it saw, how many it
  inserted, and how many matview rows the pre-lock matched. If
  `n_locked + n_inserted == n_source`, every row in scope is accounted for and
  the prune has nothing to delete. That is Tier 2 evidence about *this* refresh,
  not a promise about all future ones, so a wrong answer is impossible rather
  than merely detectable.
- **`append_only`** — the part that does not fall out of a counter, since
  `DO NOTHING` is a claim that existing rows never need rewriting, and no count
  taken during a refresh can establish that. It stays a declaration or it stays
  unimplemented.

A reloption is user-visible surface that is hard to withdraw, and the on-list
question would be why the server cannot work it out. For `no_delete` the honest
answer turned out to be that it can. The earlier design here — declare it, then
run the prune anyway on a sampled fraction of refreshes and `WARNING` if it
would have deleted something — was a verifier for a declaration that no longer
needs to exist, and adding user-visible surface in order to check it later is
worse than deriving it now.

**Nowhere observable: frequency and transaction context.** They belong in the
documentation, and they are why a benchmark that commits once per refresh
describes one driver pattern rather than the feature — an assumption the D1/D2
measurement has since shown to be load-bearing in both directions.

---

## 3. The specialisations

Each states what it changes, which tier decides it, and **which detector
catches it if it is wrong** — a detector nobody has watched catch anything is
the same defect as a test that cannot fail.

| specialisation | tier | effect | detector |
|---|---|---|---|
| **row comparison** — `WHERE (mv.cols) IS DISTINCT FROM (EXCLUDED.cols)` on the `DO UPDATE`. *Implemented*, currently a GUC; should be T3 churn with a T1 veto when no index covers a written column | 3 + 1 | **+25–54% at zero churn**, scope ≥1000, covering index, settled heap; falls to **−9%** at full churn; **−18.5% at scope 1**; nil without the index. Quote the protocol with the number — see the heap-state axis in §1 | oracle — 22 shapes, 1636 mutations, 0 divergences |
| **cache the source plan** — removes rewrite + plan from every refresh | — | 12.2 µs, 16.2% at scope 1, ~0 at scale | `matview_where_cache` 1–3, which need a **base-table** variant: a stashed `PlannedStmt` is not revalidated when a base table changes, so this must go through the plancache, not a pointer |
| **stop deparsing for the cache key** — store the qual tree, compare with `equal()`, deparse only on a miss | — | 4.5–5.3 µs, 7.4% at scope 1. Closes **B3**: the tree carries parameter types, `$1` does not | `matview_where_cache` Test 4, already two predicates that deparse identically and need different plans |
| **parameterise predicate `Const`s** | — | **8×**, by turning cold refreshes warm | oracle. Changes what the cache key *is*, so it lands first or last, never in the middle |
| **skip the prune** when the source is **empty** — the non-empty case is now covered by derived `no_delete` below, which needs no at-most-one-row proof | 1 + 2 | the mirror of the row above: this is the row-trigger delete path, and it applies at *any* scope | **none yet** — see 3c |
| **drop both `ORDER BY`s** | 1 | small: the index already supplies the order in the aligned case | oracle |
| **drop the prune** — `no_delete`, now **derived** rather than declared: `n_locked + n_inserted == n_source` means nothing in scope is orphaned | **2**, not 4 | **13–19%** at scope ≥1000 on top of the row comparison; 1.1% on `expensive`, where GIN maintenance dominates everything | oracle, plus the `mutations.py` entry that forces the elision when the counts do *not* agree |
| **`DO NOTHING`** (`append_only`) — the half that cannot be derived, because no count taken during a refresh proves existing rows never need rewriting | 4 | a further **10–22 points**, taking the pair to 26–39% at scope ≥1000 | sampling verifier, plus a `mutations.py` entry declaring `append_only` on a view that updates |

### 3c. The at-most-one-row proof, and why it needs a new detector

The qual is equality on every arbiter key column, so at most one matview row
matches. The source — the view under the same qual, unique on the arbiter key
because the upsert requires it — yields at most one row. If it produced that
row, the upsert writes it and the single row in scope *is* that row: nothing can
be orphaned and the anti-join cannot delete. If the source is empty, the mirror
holds and the refresh is the `DELETE` alone.

The oracle is single-session and will not see the hazard, which is concurrent:
another session inserting the key between the materialise and the DML. Two specs
already sit on that seam, both under `src/test/modules/injection_points/specs/`
rather than `src/test/isolation/specs/`: `matview-where-snapshot` pins the gap
between the locking SELECT and the DML, and `matview-where-prune-gap` pins the
prune against a row another refresh committed mid-flight. The latter drives a
key the matview does not yet hold, because a key with no row locks nothing —
which is the only way to be inside the window at all, and the reason the fuzzer
cannot stand in for it.

What is missing is a **permutation with the elision enabled**, and it must be
**shown to fail against a deliberately naive elision before it is trusted with a
correct one** — a detector that has never gone red is indistinguishable from a
test that cannot.

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

- **`no_delete` first**, and it is now a *smaller* change than when it was
  written down as a reloption: three counters the fused statement already has,
  compared, with the prune skipped when they agree. No catalog change, no
  user-visible surface, no verifier, and a wrong answer is not possible rather
  than merely detectable. It also subsumes the non-empty case of the T2 prune
  elision, which is why that one dropped off this list entirely — what is left
  of it is the empty-source path, which is the row-trigger delete path and needs
  the detector described in §3c.
- Source plan + deparse elision **together** — one change to the cache-entry
  miss path, not two.
- T3 churn gate next — turns the row comparison from a GUC into a decision, and
  the curve it needs now exists (§1, churn fraction). Break-even 60–70% churn,
  which is far from where the current scope-based gate sits; the gate was right
  by correlation and should stop relying on it.
- `Const` parameterisation after that, since it redefines the cache key.
- `append_only` **last, or never**. It is worth 10–22 points on top of
  `no_delete`, which is real, but it is the only item left that needs a
  declaration — and a declaration whose failure mode is rows that silently
  never leave has to earn its surface against that number, not against zero.

---

## 4. What convergence breaks

`matview_where` asserts `concurrently_blocks_writers = f` and
`bare_where_blocks_writers = t`. That used to hold only because bare selected
match/merge, which takes `ExclusiveLock` as a side effect — so the assertion was
describing an accident, and it was written down as the spec for the decision
that would have to replace it.

**Convergence has since happened, and the decision was taken.** Both forms now
reach the general algorithm when the matview has at most one unique index, and
`ExclusiveLock` for the bare form is chosen explicitly rather than inherited:

| form | lock | why |
|---|---|---|
| `WHERE` + `CONCURRENTLY` | `RowExclusiveLock` | refreshes over disjoint scopes must not block each other — the whole point of the row-level locking |
| `WHERE`, bare | `ExclusiveLock` | keeps the documented "bare blocks writers" contract, and buys a **precondition**: with no second refresh possible against the same matview, specialisations that are unsound under concurrency become available |
| no `WHERE`, bare | `AccessExclusiveLock` | unchanged |

The middle row is the load-bearing one, and the reason it is a lock level rather
than a reloption is §2's Tier 4 argument in miniature: the lock *enforces* the
condition the specialisation needs, where a declaration would merely *assert*
it. Nothing exploits that precondition yet. It is recorded here so that the lock
level is understood as an enabling choice rather than a conservative one, and so
that anything later built on it can point at where the guarantee comes from.

---

## 5. Measurement gaps, in the order to close them

All five are now closed. What each one turned out to say — and, where it
matters, what its numbers are still worth — is below.

1. ~~**Mutability** — nothing has ever been measured against an append-only or
   no-delete matview. Largest saving, zero data.~~ Closed by
   `bench/mutability.sql`, which hand-writes the six statement forms and times
   them against a plain-heap clone, because the code cannot emit four of them
   yet. Against the row comparison already on: `no_delete` **13–19%** at scope
   ≥1000, `append_only` a further **10–22 points**. It was billed as the largest
   saving available; it is real but it is not that. The bigger consequence is
   §2: the `no_delete` half does not need declaring at all, which leaves
   `append_only` as the only declared thing in the design.
2. ~~**Concurrency** — `--clients 4,16 --overlap hot`, plus `fuzz.sh`.~~ Closed,
   54 cells: **zero deadlocks, zero failed transactions, zero serialization
   failures** at 1/4/16 clients across both overlap settings. Disjoint scales
   3.4–5.9× to 4 clients then flattens. Overlapping collapses where it should —
   `nonkey` range/scope 1000 hot falls to 26 tps at 16 clients — and that
   collapse is the lock working, not failing. `--overlap hot` is still one point
   ("everyone fights over keys 1–10") rather than a sweep of intersection
   probability, which is the part left undone.
3. ~~**Churn** — `--mutate on` across a varying changed-fraction.~~ Closed by
   `bench/churn.sql`: 54–56 → 41–51 → 27–36 → 18–27 → ≈0% at churn
   0/5/25/50/100 on `nonkey`/scope 10000, break-even ≈ 60–70%. The gate is on
   scope, and scope is still a proxy — but the proxy now has the curve behind
   it rather than an argument about driver patterns. Remaining weakness:
   `churn.sql` measures one arm per invocation, so the comparison is
   cross-process; at the 100% end, where the true difference is a few
   percent, that variance swamps the signal and the sign flips between runs.
   Cells where the two arms are close need an alternating harness.
4. ~~**The match/merge crossover** — needs a deliberate 50/75/90/100% sweep with
   the `run.sh` ≥90% guard lifted.~~ Closed, and **there is no crossover.**
   Direct modification wins at every scope swept, and by a widening margin:

   | scope of matview | 10% | 25% | 50% | 75% | 90% |
   |---|---|---|---|---|---|
   | `aggregate` (1000 rows) | +63% | +43% | +31% | +34% | +34% |
   | `timerange` (20001 rows) | +68% | +101% | +106% | +109% | +95% |

   Match/merge builds a transient heap of the whole scope and diffs it whatever
   happens; direct modification's cost tracks what actually changed. So the
   region where match/merge should have won is the region where it loses worst.
   It keeps its place in the code for the case the fast path cannot serve — more
   than one unique index, where there is no single arbiter to conflict on — and
   that is a capability boundary, not a performance one.

   Caveat: measured before today's routing change, when a bare `WHERE` still
   reached match/merge, so `bare` and `conc` are standing in for the two
   algorithms. The comparison is algorithm-vs-algorithm; it is not a claim about
   what the two spellings do now.
5. ~~**Transaction context** — every run commits per refresh; D1 amortises into
   the writing transaction, D3 calls once a night.~~ Closed with `--perxact`,
   and the answer is not the one assumed. Amortising the commit over 20
   refreshes helps only while the scope is small — **3.5–3.7× at scope 1,
   2.1–3.1× at scope 10, 1.25–1.9× at scope 100** — and then reverses hard:
   **2.1× slower at scope 1000, 3.3× slower at scope 10000**. Twenty rewrites
   of one scope inside one transaction leave update chains that no cleanup can
   touch until it commits, and later refreshes walk them. D1 is therefore not
   "D2 minus the commit cost", and a statement trigger firing repeatedly
   against a large scope inside one writing transaction is the worst case for
   this feature rather than the best.

---

## 6. State at time of writing

**Implemented and verified** — the row comparison
(`matview_partial_refresh_optimized`): oracle 22 shapes / 1636 mutations / 0
divergences, five `matview_where` suites green with it forced on. Routing of the
bare `WHERE` form onto the general algorithm, with `ExclusiveLock` chosen
deliberately (§4). `FOR NO KEY UPDATE` on the pre-lock.

**Sized, unimplemented** — source plan caching, deparse elision, `Const`
parameterisation, derived `no_delete`, `append_only`.

**Measured and rejected** — forcing a generic plan (net −21.7% over 94
comparisons), the arbiter index scan (0.08 µs), the cache sweep (below timer
resolution), bypassing SPI (~2 µs per statement, not the ~20 a noisy run
suggested).

**Benchmark `p3opt`** — 4 of 7 workloads: `nonkey` +26–35%, others +4–16% at
scope ≥100, −18.5% at scope 1. **Do not quote the positive figures.** The label
covers two runs 2h43m apart (01:36–01:56 and 04:39–04:55) with server restarts
at 03:20 and 03:27 between them, so its two halves were measured on different
postmaster incarnations. It predates `bench_result.server_start`, which is why
this had to be reconstructed from the server log rather than read off the row.
The −18.5% at scope 1 is corroborated elsewhere; the rest needs re-measuring.

**Provenance of the gap runs** — `gaps-concurrency`, `gaps-crossover`,
`gaps-txn-d1` and `gaps-txn-d2` also predate `server_start`, but the log puts
all four inside one incarnation (started 03:27, next restart 05:15), running
back to back from 04:10:50 to 04:39:21 with nothing else on the machine —
`p3opt` resumes at 04:39:40, nineteen seconds after the last of them finishes.
So they are single-boot and mutually comparable; `gaps-txn-d1` against
`gaps-txn-d2` in particular is a clean comparison. What they are *not* is
heap-state-controlled: they use `run.sh`, which sets up per cell, so any figure
in them that compares a writing arm with a non-writing one carries the bias
below. Gap 4 compares two arms that both write, and gap 5 compares one arm with
itself at two commit rates, so neither is exposed.

### How these numbers were checked

Every figure above that compares an arm which writes against an arm which does
not is a ratio whose denominator is the fragile half. Four hazards produced
wrong answers here, all of them in the same direction — flattering the
optimization — and all of them plausible-looking at the time:

- **Cross-boot comparison.** The container restarts without warning. Two arms
  measured either side of one showed a uniform 3–38% "regression" that vanished
  when both were run on one boot. `bench_result.server_start` now records the
  incarnation; a run that straddles a restart is detectable rather than
  something the reader must remember to worry about. Replaying an old protocol
  on a new boot reproduced it to within 10%, so the hazard is real but was not,
  in the end, contaminating these cells.
- **Fresh-heap bias.** `bench_setup` hands the writing arm a heap with no free
  space and nothing dirtied since the last checkpoint. Worth 14–25 points.
  `bench/heapstate.sh` maps it; `churn.sql` now settles the heap first.
- **Per-arm sample counts.** An adaptive best-of-N budget gave the faster form
  4× the draws. Worth 8–9.5 points, and 1.6 points on the one cell where the
  rule happened to give both forms the same count — which is the control that
  identifies the cause.
- **Integer division in the reporting query.** `1 - a/b` on two integers reads
  exactly 100.0 or 0.0, which looks like an emphatic result rather than a broken
  one. It sat in `modelcheck.sh` across all 40 rows.

The one quantity that reproduced everywhere — three scripts, two boots, four
protocols, ±4% — is the *optimized* arm's absolute cost. That is the signal to
trust. Anything divided by the un-optimized arm needs its protocol stated.
