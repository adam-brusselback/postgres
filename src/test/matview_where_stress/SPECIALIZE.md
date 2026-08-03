# One algorithm, several specialisations — the Phase 4 design

Both `REFRESH ... WHERE` forms converge on the general algorithm: lock the
scope, evaluate the source, fused upsert/prune. Match/merge leaves the predicate
path unless a measurement finds a workload it fits perfectly. What remains is
deciding, per call, which parts of the general algorithm to skip — and *where*
that decision can be made.

Written because the axis set changed three times in one sitting, each addition
invalidating a recommendation already made.

---

## 0. Reading the numbers

Four different quantities appear below and **they do not share a direction.**
Earlier drafts wrote them all as bare `+`/`−` percentages, which meant a reader
had to already know which way each one pointed. They are now spelled out:

| written as | is | which way is good |
|---|---|---|
| **"N% faster"** / **"N% slower"** | change in how long one refresh takes | faster |
| **"N points"** | the gap between two percentages, added to a saving that is already there — not a ratio | more |
| **"N× the throughput"** | pgbench transactions per second, one setting over another | higher |
| **"N% of refresh time"** | where the time goes *inside* one refresh | **neither** — it says where work sits, not whether that is good |

Two traps worth naming, because both have caught this document before:

- **A share is not a saving.** "The fused DML is 87% of a large refresh" says
  where to look for wins. It does not say a win is available there, and reading
  it as though it did is exactly how mutability came to be called the largest
  saving available before anyone measured it (§1, mutability).
- **A ratio's denominator has a direction too.** Where one arm writes and the
  other does not, everything that makes writing expensive inflates the saving.
  See the heap-state axis, and §6 for what it cost.

---

## 1. The axes

| axis | values | selects | evidence |
|---|---|---|---|
| **scope** | 1 · small · large · near-total | prune elision; whether fixed costs matter at all | measured, **share of refresh time** (locates work, does not judge it): source planning 16.2% → 0.9% → 0.0% at scope 1/100/10k, while the fused DML goes 52% → 58% → **87%**. So fixed costs only matter at scope 1, and at scale there is nowhere to look but the DML |
| **predicate shape** | equality on all arbiter key columns · array · range · non-key | at-most-one-row proofs; whether the index supplies the lock order | measured, `bench/optmatrix.sql`, 94 comparisons — **positive = the generic plan is faster**: **21.7% slower** overall, but the spread is the point, **+28.6% on range/span 1** (best +72.8%) against **−33.5% on array/span 100**. Grouped by *span*, not by scope rows; regrouping it changes the numbers and was how these figures once got wrongly retracted. Full matrix in PLAN.md 4.1. `ORDER BY` on the pre-lock costs **4–26% of the pre-lock when aligned** and **20–69% when not**, growing with scope on `nonkey` (20 → 35 → 56% at scope 100 → 1000 → 10000). It is not free even when aligned — it is *invisible*, because the pre-lock is only 12–15% of a refresh |
| **index shape** | do the updated columns sit under any index? | whether an avoided write saves index maintenance or just a HOT update | measured: the row comparison is **27–53% faster** with a covering index and **makes no difference at all** without one. Treat the magnitude as an upper bound — it was measured fresh-heap (see below) — but not the presence/absence result, which compares two arms that both write |
| **churn fraction** | share of the scope whose values actually changed | whether the row comparison pays | measured, `bench/churn.sql`, on `nonkey`/scope 10000 — **faster is better, and it runs out**: **54–56% faster** at churn 0, then 41–51 → 27–36 → 18–27 → **≈0%** at churn 5/25/50/100 (ranges are two protocols disagreeing). At full churn every comparison fails and the row-wise `IS DISTINCT FROM` is bought for nothing. Break-even ≈ 60–70% churn |
| **heap state** | never-updated · settled · bloated | nothing about the code — it decides the *measured* value of everything above | measured, `bench/heapstate.sh`: one comparison reads **"54% faster" or "82% faster"** on identical code, data and boot. Neither number is better than the other; **54% is the honest one.** At zero churn only the un-optimized arm writes, so free space, full-page images, extension and bloat all land on one side of the ratio, and a matview `bench_setup` has just built is that arm's worst case |
| **driver pattern** | D1 statement trigger · D2 queue drain · D3 scheduled window | frequency, transaction context, and the priors for every axis above | measured, `--perxact`, as **D1's throughput over D2's — above 1× D1 wins, below 1× it loses**: **3.5–3.7×** at scope 1, **2.1–3.1×** at scope 10, **1.25–1.9×** at scope 100, then it *inverts* to **0.47× (2.1× slower)** at scope 1000 and **0.30× (3.3× slower)** at scope 10000. Twenty rewrites of one scope inside one transaction build update chains nothing can prune until it commits. D1 is not "D2 minus the commit" |
| **overlap probability** | none · concurrent-disjoint · concurrent-overlapping | whether the lock and its ordering buy anything | measured, 54 cells. Correctness first, **lower is better and all three are zero**: no deadlocks, no failed transactions, no serialization failures. Then throughput at 4 clients over 1, **higher is better**: disjoint scopes reach **3.4–5.9×**, flattening by 16 clients. Overlapping scopes go the other way — `nonkey` range/scope 1000 hot falls **161 → 141 → 26 tps** at 1 → 4 → 16 clients, which is the lock serialising on purpose, not a defect |
| **mutability** | append-only · no-delete · general | whether the prune exists at all | measured, `bench/mutability.sql`, **on top of the row comparison rather than instead of it** — these do not add to the figures above, they are what is left after them. Dropping the prune (`no_delete`) is **13–19% faster** at scope ≥1000, and only **1.1% faster** on `expensive`, where GIN maintenance dominates.  **Those are model figures**; measured on the implementation it is **10.9% at scope 1000 and 13.7% at scope 10000** (R42), bare form only — see §3b-ii for why. `DO NOTHING` (`append_only`) adds **10–22 points** on top, reaching **26–39% faster** in total |

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
  it, **though not as simply as this paragraph once said — see §3b, which
  refutes the rule below with a case that leaves the matview holding a row its
  own definition does not produce.** The fused statement knows how many source rows it saw, how many it
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

The **effect** column is always "how much faster one refresh gets", so higher
is better everywhere in it, and a *slower* entry is spelled out as such.

| specialisation | tier | effect (higher = better) | detector |
|---|---|---|---|
| **row comparison** — `WHERE (mv.cols) IS DISTINCT FROM (EXCLUDED.cols)` on the `DO UPDATE`. *Implemented*, currently a GUC; should be T3 churn with a T1 veto when no index covers a written column | 3 + 1 | **25–54% faster** at zero churn — scope ≥1000, covering index, settled heap. Degrades with churn to **9% slower** at full churn, and is **18.5% slower** at scope 1, where the comparison costs more than the write it avoids. No effect at all without a covering index. Always quote the protocol with the number — see heap state in §1 | oracle — 22 shapes, 1636 mutations, 0 divergences |
| **cache the source plan** — removes rewrite + plan from every refresh | — | **12.2 µs faster** per refresh — worth **16.2%** at scope 1 and nothing at scale, because it is a fixed cost | `matview_where_cache` 1–3, which need a **base-table** variant: a stashed `PlannedStmt` is not revalidated when a base table changes, so this must go through the plancache, not a pointer |
| **stop deparsing for the cache key** — store the qual tree, compare with `equal()`, deparse only on a miss | — | **4.5–5.3 µs faster** per refresh, **7.4%** at scope 1, again fixed. Closes **B3**: the tree carries parameter types, `$1` does not | `matview_where_cache` Test 4, already two predicates that deparse identically and need different plans |
| **parameterise predicate `Const`s** — *implemented*; each Const becomes a `Param` of the same type, typmod and collation before the deparse, and the values ride the `ParamListInfo` the path already carried | — | **8× in-backend** (R15), **0.3-45.3% end to end across 40 paired cells, none slower** (R37).  It turns refreshes that would miss the plan cache into hits | oracle, plus `matview_where` Test 19 for the values reaching the right rows and `matview_where_source_plan` part 3 for the plan actually being reused.  Changes what the cache key *is*, so it lands first or last, never in the middle |
| **skip the prune** when the source is **empty** — the non-empty case is now covered by derived `no_delete` below, which needs no at-most-one-row proof | 1 + 2 | unmeasured. It is the mirror of the row above — the row-trigger delete path — and it applies at *any* scope | **none yet** — see 3c |
| **drop the pre-lock's `ORDER BY`** — *not* the source's, and gated on the **lock level**, not on index alignment | 1 | **Measured directly on the pre-lock: 20–69% of it** when misaligned, growing with scope, and 4–26% when aligned. The pre-lock is 12–15% of a refresh, so the implied whole-refresh saving is **~3–10% — implied, not measured.** Direct whole-refresh measurement cannot resolve it at scope 1000, where the effect is smaller than the harness's own ±11% wobble; only `nonkey`/scope 10000 (+4.8 to +9.4%) is plausibly resolved. Do **not** bundle the source `ORDER BY` in — see below | oracle, plus an isolation permutation showing two refreshes deadlocking if it is dropped under `RowExclusiveLock` |
| **drop the prune** — `no_delete`, **derived** rather than declared, but **not by the rule this row used to state**: `n_locked + n_inserted == n_source` is unsound on its own, and unsound again under concurrency. §3b has the first counterexample, §3b-ii the second. *Implemented*, gated on the qual being key-only **and** on holding `ExclusiveLock` | **2 + 1**, and a lock level | **10.9% faster at scope 1000 and 13.7% at scope 10000** on the implementation (R42), against a control that reads 0.  R6's model said 13–19% and this is the bottom of that band, which is the direction to expect.  Bare form only.  Model figures: only **1.1% faster** on `expensive`, where GIN maintenance dominates | matview_where Test 20 with `mutations.py` **N1** (drop the key-only gate) and **N2** (skip unconditionally); `matview-where-prune-elide.spec` with **N4** (drop the lock-level condition) — each seen to fail, and each fails a different file |
| **`DO NOTHING`** (`append_only`) — the half that cannot be derived, because no count taken during a refresh proves existing rows never need rewriting | 4 | a further **10–22 points** on top of `no_delete`, taking the pair to **26–39% faster** at scope ≥1000 | sampling verifier, plus a `mutations.py` entry declaring `append_only` on a view that updates |

### 3b. `n_locked + n_inserted == n_source` is UNSOUND, and here is the case

The derivation above is wrong as written, and the failure is silent corruption
rather than a slow refresh. **Do not implement it in that form.**

It assumes every source row that conflicts with an existing matview row
conflicts with one *in scope*. A predicate on a non-key column breaks that: a
matview row can carry the same key as a source row and not satisfy the
predicate, so the conflict is invisible to `n_locked` and the two errors
cancel.

Reduced, and **run rather than reasoned** — the counters below are the real
ones, measured on the shipped code:

```sql
CREATE TABLE nd_base(k int primary key, status text);
INSERT INTO nd_base VALUES (1,'A'), (2,'B');
CREATE MATERIALIZED VIEW nd_mv AS SELECT k, status FROM nd_base;
CREATE UNIQUE INDEX ON nd_mv(k);

UPDATE nd_base SET status='B' WHERE k=1;   -- leaves the scope
UPDATE nd_base SET status='A' WHERE k=2;   -- enters it

REFRESH MATERIALIZED VIEW nd_mv WHERE status = 'A';
```

    n_locked = 1     the matview's (1,'A')
    n_source = 1     the base's  (2,'A')
    n_inserted = 0   k=2 conflicts with the matview's (2,'B')

`1 + 0 == 1`, so the derivation says nothing is orphaned. The refresh in fact
**deletes k=1**, correctly, because the source no longer produces it. Under the
elision the matview would keep `(1,'A')` — a row its own definition does not
produce — and report success.

**What is sound instead**, and the shape is verified against the executor:

- **`n_locked == 0`** — no matview row is in scope, so the prune cannot delete
  anything. ~~Unconditional; needs no gate and no counting.~~ **Not
  unconditional — see 3b-ii, which applies to this rule as much as to the next
  one.**
- **`n_locked + n_inserted == n_source`, gated on the qual referencing only the
  arbiter index's key columns.** That gate is what makes drift impossible: two
  rows with the same key then agree on the qual, so every conflicting matview
  row is necessarily in scope. §3c's at-most-one-row proof is the special case
  of this where the qual is equality on every key column.

`n_inserted` is not known until the upsert has run, and the upsert and the
prune are one statement — so the decision has to be made *inside* it:

```sql
WITH upsert AS (INSERT ... ON CONFLICT ... RETURNING (OLD.k IS NULL) AS ins),
     pruned AS (DELETE FROM mv WHERE (qual) AND NOT EXISTS (...)
                  AND NOT ($force_skip
                           OR $n_locked + (SELECT count(*) FILTER (WHERE ins)
                                             FROM upsert) = $n_source)
                RETURNING 1)
```

Two things make that work rather than merely look right, both checked on this
build:

- the `DELETE` gets a **`One-Time Filter`**, so a false guard skips the scan
  entirely rather than scanning and matching nothing — which is where the
  saving comes from;
- its `InitPlan` reads the upsert CTE, and that **data dependency is what
  orders them**. `WITH` sub-statements are otherwise executed in no defined
  order relative to each other, so a guard that did not read the upsert would
  be reading a count that may not exist yet.

The gate then lives in the *values*, not in the SQL: pass the real `n_source`
when the qual is key-only and `-1` when it is not, since the left-hand side is
never negative. One statement, one plan, one cache key — which also keeps B31's
rule, that anything changing the generated SQL has to be in the key.

### 3b-ii. Both rules need the lock level too, and here is that case

The two rules above were written down as though `n_locked` were a count of what
the matview holds in scope *at the moment the prune would run*. It is not. It is
what the pre-lock matched, under an **earlier snapshot** — and the ordering is
not an accident that can be tidied away: the snapshot is taken *after* the lock
precisely so that a refresh which queued behind another does not evaluate its
source from before that one committed and write the stale values back over it.
That is mutation M3's lost update, at 45 events a run, and §3e is the same
argument from the other side.

The lock stops the rows it matched from changing. It does not stop new ones
appearing. A refresh over a key the matview does not hold yet locks nothing, so
it does not queue behind us and can commit a row into our scope inside that
window — the same "a key with no row locks nothing" that §3c relies on to reach
the prune gap at all. Neither count has seen that row, so **the accounting
balances while the row is orphaned**, and the refresh reports success.

Which is §3b's own failure mode arriving from concurrency instead of from
predicate shape. Worth saying plainly, because the pattern has now repeated
twice in one section: **every single-session gate is green under it.**
matview_where Test 20, the contract file, the differential oracle and the
fuzzer all pass. It was found by building the detector that §3c asks for, not
by reading the design — RESULTS.md **R43**, and **X13**.

**The condition that closes it is the lock level**, which is §4's argument
arriving with a second customer: at `ExclusiveLock` no other session can write
the matview at all, so the in-scope set cannot change between the pre-lock and
the DELETE. So the elision is available to the **bare** `WHERE` form and not to
`CONCURRENTLY`, and the saving is once again available exactly where the lock
makes it safe to take. Ask the lock manager rather than the statement's
spelling: what the guard needs is the fact, not the form that chose it.

Two things this rules out, both of which look like the obvious fix:

- **Taking the snapshot before the pre-lock** closes the window and reopens M3.
- **Counting the in-scope rows under the DML's snapshot** is the scan being
  elided.

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

- **`no_delete` first** — **DONE**, and it was a smaller change than the
  reloption it replaced but a larger one than this line predicted: three
  counters the fused statement already has, compared, with the prune skipped
  when they agree, **plus two conditions neither of which is about the
  counters** — the qual must read key columns only (§3b) and the matview must be
  held at `ExclusiveLock` (§3b-ii). No catalog change, no user-visible surface
  and no verifier, but "a wrong answer is not possible rather than merely
  detectable" was wrong twice: it is possible, it is silent, and both times the
  only thing that found it was a test written to look for it. It also subsumes the non-empty case of the T2 prune
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
  **Done, and it went before the churn gate rather than after** — it was
  unblocked the moment the benchmark could tell the two predicate modes
  apart, and nothing else in Phase 3 could be evaluated until then.
- The pre-lock `ORDER BY` elision whenever the bare form is being worked on
  anyway. It removes a clause measured at 20–69% of the pre-lock, it is a
  one-line condition on the lock level rather than on anything about the
  predicate, and it is the only thing so far that cashes in §4's
  `ExclusiveLock`. Do **not** bundle the source `ORDER BY` into it — that one
  has never been resolved above the noise, and pairing them would make a
  measurable change unmeasurable.
- `append_only` **last, or never**. It is worth 10–22 points faster on top of
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
condition the specialisation needs, where a declaration merely *asserts* it.

**The first thing to exploit it is the pre-lock's `ORDER BY`.** That clause is
not there for speed; it gives two refreshes with overlapping scopes a
deterministic order to take rows in, so they queue instead of deadlocking. Under
`ExclusiveLock` there is no second refresh to deadlock with — verified rather
than assumed: a held `ExclusiveLock` blocks both `RowExclusiveLock` (a
`CONCURRENTLY` partial refresh) and another `ExclusiveLock` (a second bare one),
while still admitting `AccessShareLock` readers. So for the bare form the
ordering has no job, and dropping it removes a clause measured at 20–69% of the
pre-lock, which is 12–15% of a refresh.

That is a small win, and it is the *shape* of it that matters: the saving is
available exactly where it cannot be taken safely without the lock. Under
`RowExclusiveLock` the same elision is a deadlock generator. A reloption saying
"I never run refreshes concurrently" would have unlocked the same few percent
and been wrong the first time someone ran two — which is §3e's argument
arriving from the other direction, with a number attached.

**The source `ORDER BY` is a different question, and nothing here answers it.**
Four runs have given it four answers — a 2–5% regression, then noise, then
16-of-16 faster on `nonkey` against 1-of-8 on `window`, then 7-of-10 and
4-of-10 with the clone held constant. That last pair is a coin flip, which is
the honest reading of all of them: at scope 1000 the effect is below the floor
described in §6, and the confident-looking win counts came from estimators that
were not robust to a single 73%-high measurement. Leave the source ordering
alone. It needs a cell where its effect exceeds the noise, not more repeats of
one where it does not.

---

## 5. Measurement gaps, in the order to close them

All five are now closed. What each one turned out to say — and, where it
matters, what its numbers are still worth — is below.

1. ~~**Mutability** — nothing has ever been measured against an append-only or
   no-delete matview. Largest saving, zero data.~~ Closed by
   `bench/mutability.sql`, which hand-writes the six statement forms and
   times them against a plain-heap clone, because the code cannot emit four
   of them yet. Measured on top of the row comparison rather than instead of
   it: **R6**. It was billed as the largest saving available; it is real but
   it is not that. The bigger consequence is §2: the `no_delete` half does
   not need declaring at all, which leaves `append_only` as the only declared
   thing in the design.
2. ~~**Concurrency** — `--clients 4,16 --overlap hot`, plus `fuzz.sh`.~~ Closed,
   54 cells — **R8**: no deadlocks, no failed transactions, no serialization
   failures, disjoint scaling cleanly and overlapping collapsing. That
   collapse is the lock working, not failing. `--overlap hot` is still one
   point ("everyone fights over keys 1–10") rather than a sweep of
   intersection probability, which is the part left undone.
3. ~~**Churn** — `--mutate on` across a varying changed-fraction.~~ Closed by
   `bench/churn.sql` — the curve and its break-even are **R4**. Past
   break-even the comparison is not worth turning on. The gate is on scope,
   and scope is still a proxy — but the proxy now has the curve behind it
   rather than an argument about driver patterns. Remaining weakness:
   `churn.sql` measures one arm per invocation, so the comparison is
   cross-process; at the 100% end, where the true difference is a few
   percent, that variance swamps the signal and the sign flips between runs.
   Cells where the two arms are close need an alternating harness.
4. ~~**The match/merge crossover** — needs a deliberate 50/75/90/100% sweep with
   the `run.sh` ≥90% guard lifted.~~ Closed, and **there is no crossover.**
   Throughput of direct modification over match/merge — **above 1× direct
   modification wins, and it never gets near 1×**:

   | predicate covers … of the matview | 10% | 25% | 50% | 75% | 90% |
   |---|---|---|---|---|---|
   | `aggregate` (1000 rows) | 1.63× | 1.43× | 1.31× | 1.35× | 1.34× |
   | `timerange` (20001 rows) | 1.68× | 2.01× | 2.06× | 2.09× | 1.95× |

   The margin does not close as the predicate widens: it narrows a little on
   `aggregate` (1.63× to 1.34×) and widens on `timerange` (1.68× to 1.95×),
   with no sign of converging on either. Match/merge builds a transient heap
   of the whole scope and diffs it no matter what; direct modification's cost
   tracks what actually changed. So the region where match/merge should have
   won — near-total scopes, where it does the same work either way — is the
   region where it loses by the most on the larger matview.

   It keeps its place in the code for the case the fast path cannot serve —
   more than one unique index, where there is no single arbiter to conflict
   on — and that is a capability boundary, not a performance one.

   Caveat: measured before today's routing change, when a bare `WHERE` still
   reached match/merge, so `bare` and `conc` are standing in for the two
   algorithms. The comparison is algorithm-vs-algorithm; it is not a claim
   about what the two spellings do now.
5. ~~**Transaction context** — every run commits per refresh; D1 amortises into
   the writing transaction, D3 calls once a night.~~ Closed with `--perxact`,
   and the answer is not the one assumed. Amortising the commit over 20
   refreshes helps only while the scope is small and then reverses hard —
   **R7**. Twenty rewrites of one scope inside one transaction leave update
   chains that no cleanup can touch until it commits, and later refreshes
   walk them. D1 is therefore not "D2 minus the commit cost", and a statement
   trigger firing repeatedly against a large scope inside one writing
   transaction is the worst case for this feature rather than the best.

---

## 6. State at time of writing

**Implemented and verified** — the row comparison
(`matview_partial_refresh_optimized`): oracle 22 shapes / 1636 mutations / 0
divergences, five `matview_where` suites green with it forced on. Routing of the
bare `WHERE` form onto the general algorithm, with `ExclusiveLock` chosen
deliberately (§4). `FOR NO KEY UPDATE` on the pre-lock.

**Implemented since that line was written** — source plan caching (R34) and
`Const` parameterisation (R37).

**Implemented since that line was written, part 2** — derived `no_delete`
(R42, R43), bare form only.

**Sized, unimplemented** — deparse elision, `append_only`.

**Measured and rejected** — forcing a generic plan (**21.7% slower** net over 94
comparisons; faster only on range/span 1, where it is +28.6%), the arbiter index
scan (0.08 µs), the cache sweep (below timer resolution), bypassing SPI (~2 µs
per statement, not the ~20 a noisy run suggested).

**Benchmark `p3opt`** — 4 of 7 workloads: `nonkey` **26–35% faster**, others
**4–16% faster** at scope ≥100, and **18.5% slower** at scope 1. **Do not quote
the faster figures.** The label covers two runs 2h43m apart (01:36–01:56 and
04:39–04:55) with server restarts at 03:20 and 03:27 between them, so its two
halves were measured on different postmaster incarnations. It predates
`bench_result.server_start`, which is why this had to be reconstructed from the
server log rather than read off the row.
The 18.5%-slower result at scope 1 is corroborated elsewhere; the rest needs
re-measuring.

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
- **Measuring under the noise floor.** The `ORDER BY` question was answered four
  different ways — including two runs of one script disagreeing by 7 points —
  before anyone asked what the floor was. Measured: on a 2.5 ms cell the
  baseline wobbles **6.8–11.3% between clones**, and roughly one measurement in
  40 lands **73% high**. An effect of 1–7% cannot be read off that, and win
  counts like "16 of 16" are the first thing to look confident while meaning
  nothing: a mean or a per-repeat ratio is not robust to one excursion, and
  three repeats cannot detect one. What the floor rules out is worth knowing
  before the sweep, not after: **`bench/orderby.sh` measures it directly, and
  anything competing with it belongs on a bigger cell or on a sub-component
  where the effect is large** — the pre-lock alone moved 20–69%, which is why
  that number survived when the whole-refresh version of it did not.

The one quantity that reproduced everywhere — three scripts, two boots, four
protocols, ±4% — is the *optimized* arm's absolute cost. That is the signal to
trust. Anything divided by the un-optimized arm needs its protocol stated.


---

## 7. The plan cache — lifespan, and what it is allowed to assume

Everything above assumes cached plans. The cache exists (`MatViewRefreshCache`,
a session HTAB in `CacheMemoryContext` holding two `SPIPlanPtr` per matview),
and its lifespan decides how much of §3 is reachable at all.

**Where it lives, and when it pays.** Backend-local, so it lives exactly as long
as the backend. Reuse needs all six of: same backend · same matview ·
byte-identical predicate text · same argtypes · same GUCs · no invalidation
since. That is D1 through a pooled connection and D2 through a drain loop. It is
**nothing at all for D3** — a nightly job in a fresh backend gets a cold cache
on every run, and no design fixes that, because a plan cache cannot outlive a
backend. That bounds the whole caching effort before any of it is written.

**Maintenance is cheap, so the answer is never "cache less".** `SPI_keepplan()`
reparents rather than copies — `MemoryContextSetParent(plan->plancxt,
CacheMemoryContext)` — so a wasted entry costs a pointer swap and a hash insert
while a hit saves a full parse, rewrite and plan. The asymmetry favours caching
even at a poor hit rate.

**Three defects follow from that, and all three are subtractions.**

- *The invalidation is a shotgun.* `InvalidateMatViewCache()` accepts `relid`
  and never uses it, so any relcache event anywhere marks every entry for every
  matview. Autoanalyze on an unrelated table does it. `plancache.c` does the
  same job precisely, against `plansource->relationOids`.
- *It is also too narrow.* One relcache callback where plancache registers
  **seven**, so a function, operator, type or schema rename invalidates
  plancache's plan and not our entry — B2, still open.
- *It is keyed too coarsely.* One entry per `matviewOid`, so two callers with
  different predicates on one matview evict each other every time. That is worse
  than no cache: maintenance paid for a guaranteed miss. It is **not** a second
  free site in B14 — an earlier version of this line said it was, and RESULTS.md
  X8 says why it is not.

The fix for all three is `ri_triggers.c`'s pattern: **let plancache be the
detector and own the text yourself.** `ri_FetchPreparedPlan()` gates reuse on
`SPI_plan_is_valid()` and, when stale, rebuilds the query text from the catalog
rather than letting plancache re-analyse a raw parse tree that still names the
old object. That inherits all seven callbacks and deletes our callback entirely.

### 7a. One argument not to make

The PG19 foreign-key fast path documents its cache as *"not subject to cache
invalidation. The cached relations are held open with locks for the transaction
duration, preventing relcache invalidation."* **Do not reuse that reasoning.**
It conflates two things: a lock stops concurrent DDL from changing the object,
but it does not stop *your own backend* from processing queued invalidations —
`LockRelationOid()` calls `AcceptInvalidationMessages()` (`lmgr.c:136`). So the
window is between deciding to use a cached entry and finishing the opens, and
`table_open()` can invalidate what you cached. That argument went into review
unchallenged and broke on the CLOBBER_CACHE_ALWAYS buildfarm animal **one day
after commit**.

The standard to build to is Tom Lane's, stated about RI caching specifically:

> if such caching behavior is at all competently implemented, **it will be
> transparent because the cache will notice and respond to events that should
> change its outputs**.

Caching is welcome; caching that cannot notice is not. `SPI_plan_is_valid()`
meets that bar and a relcache-only callback does not.

### 7b. What review will ask, from the same reviewers

The RI work is the closest precedent — a session cache keyed on a catalog
object, bypassing SPI — and its history is worth reading before posting:

- **Discharge Tom's 2021 checklist explicitly**, in the commit message: SELECT
  and schema permission checks; `SetUserIdAndSecContext()` to the owner; RLS
  (state that predicate privilege does not become an RLS bypass); non-btree and
  non-heap AMs; and **which snapshot, and whether a *pair* is needed** — that
  last item is why the RI fast path covers only `RI_FKey_check`.
- **Hybrid fast path with a mandatory fallback**, gated by an explicit
  applicability predicate, is what broke a five-year deadlock on the RI work.
  Robert Haas's objection — *"the only way to be 100% certain we're doing all
  the things that would happen if you executed a plan is to execute a plan,
  which kind of defeats the point"* — is unanswerable in general, so narrow to
  where equivalence is checkable and fall back everywhere else. No reviewer ever
  asked for such a predicate to be *wider*.
- **Enumerate what re-entrant user code can do**, and show the guard. All three
  post-commit defects in the RI fast path were re-entrancy defects, and none was
  caught in review.
- **Track resources by subtransaction.** Noah Misch rejected a fix that disabled
  batching below the top level as "a bad user experience not seen elsewhere"
  that "departs from the PostgreSQL norm of tracking resources by
  subtransaction". A session cache that cannot unwind on subxact abort will meet
  the same objection.
- **Run under `debug_discard_caches = 1` before posting.** The RI feature's suite
  did not; the buildfarm did it for them on day one. Ours now does — all five
  `matview_where*` files green, `matview_where` taking 85 s against 409 ms
  normally, which is how you can tell the setting was actually in effect. Re-run
  it after any change to the cache; it is not in `make check`, so nothing will
  remind you.
- **Do not read silence as approval.** That feature shipped with two named
  reviewers, no committer review beside the author's, and a `Tested-by:` that
  was benchmarks only — then took six follow-up commits in eleven weeks.

### 7c. On holding two plans rather than choosing one

§2's Tier 3 wants a churn signal; §1's heap-state and churn axes say scope is
what actually separates the cases. The obvious mechanism — keep a pinned-generic
and a pinned-custom plansource and select per call on the row count the pre-lock
returns for free — is **novel**: `CURSOR_OPT_GENERIC_PLAN` and
`CURSOR_OPT_CUSTOM_PLAN` have **zero in-tree users**, appearing only in the
enum, in `choose_custom_plan()`, and in the SPI docs.

It also sidesteps rather than collides with the recorded objections to changing
plancache's policy: we never compare `generic_cost` against `avg_custom_cost`
(Lane: those estimates are "apples-to-oranges", and the planning-cost estimate
is "pretty laughable"), and we never probe (Johnston: *"any algorithm that
requires computing the custom plan unconditionally amounts to simply setting the
GUC to infinity"*). Lane has himself floated gating on how much rowcounts "move
around" — on *estimated* ones; ours would be measured.

One trap: `plan_cache_mode` is checked **before** `cursor_options`, so a session
setting `force_custom_plan` silently defeats both pinned plansources. And one
thing to measure first: whether the pre-lock's row count predicts the
*predicate's selectivity* rather than merely its scope. `opt_result` has 94
auto-versus-forced-generic comparisons and can answer it.
