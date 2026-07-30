# Plan: tests, then implementation, then performance

Branch-local. Not part of the patch.

Three phases, in this order and for this reason: the tests are what let the
implementation change safely, and the implementation change is what makes the
performance work worth doing. Doing them in any other order means optimising
code that is about to be replaced, or replacing code with no way to tell whether
it still behaves.

Everything below is grounded in what is already measured or verified in this
directory. Where something is unknown it says so.

---

# Phase 1 — Tests

The goal is not more coverage. It is **coverage that survives a rewrite**, so the
rewrite can be judged by whether the tests still pass rather than by reading the
diff.

## Sort what exists by coupling

The single most useful thing to know before touching the implementation is which
tests are asserting *behaviour* and which are asserting *shape*. Behaviour
survives; shape does not.

### Tier 1 — implementation-independent. This is the safety net.

| what | why it survives |
|---|---|
| the safety oracle, 2792 mutations | mutates base data, refreshes, diffs against a full refresh — never looks at how the refresh is done |
| the benchmark suite | same, and it becomes the before/after measurement |
| `matview_where` Tests 1–15 | behavioural: INCLUDE columns, NULL keys, drift, multiple unique indexes, lock levels |
| `matview_where_privs` Tests 2, 3 | scoped maintenance exemption; `PG_TRY` restoring the flag |
| `matview-where-serialize.spec` | readers never block; overlapping refreshes serialize; disjoint ones do not |
| `matview-where-deadlock.spec` | characterisation of cross-statement deadlock |

**Action: none.** Run them before and after every step of Phase 2. They must not
change. If one of them changes, the rewrite altered semantics.

### Tier 2 — coupled to an observable, needs re-verification

| what | what it depends on |
|---|---|
| `matview_where` Test 16 (ctid insert order) | that rows inserted by the refresh still land in the heap in the order the DML touched them. The *property* is unchanged; whether ctid still reveals it depends on the new plan shape |
| `matview-where-lockorder.spec` (xmax) | that a distinct, ordered row-locking step still exists. The `xmax` observable itself is implementation-neutral |
| `matview_where_cache` Tests 1–3 | that a plan cache exists at all |

**Action:** re-run and re-derive expected output after Phase 2. For the cache
tests specifically, expect them to become **vacuous**: a Query tree holds OIDs,
not names, so the rename-aliasing hazard they guard (B1, B2) stops being
expressible. Their own Disposition note already says "delete if the plan cache
goes away."

### Tier 3 — coupled to implementation shape. Rewrite or delete.

| what | why |
|---|---|
| `matview-where-snapshot.spec` | its premise is *two SPI statements with separate snapshots*. If the rewrite makes it one plan, the premise dissolves and the injection point moves or goes |
| `pg_stat_statements` structural block | asserts the literal text of generated SQL. In an implementation that generates no SQL there is nothing to assert. **Delete; no replacement is possible** |
| `matview_where_privs` Test 1 (A6) | the leakproof-or-ownership rule exists *only* because SPI runs one statement under one userid. If the rewrite allows the predicate to run as the invoker, this test's expectation inverts — which is a win, not a loss |

## What to build before Phase 2 starts

### 1.1 Differential mode in the safety oracle — the highest-value item

Today the oracle compares a partial refresh against a full refresh. During the
rewrite it can do something far stronger: **compare the old implementation
against the new one, over the same 2792 mutations.**

Keep both paths reachable behind a developer GUC for the duration of the
rewrite. For each mutation, run it under old and under new and diff the
resulting matview. Any divergence is a rewrite bug, localised to one mutation,
with no need to reason about whether the old behaviour was correct.

This turns "did I preserve semantics" from a judgement call into a test. It is
the single thing that makes the rewrite tractable, and it should exist before
the first line of Phase 2.

### 1.2 Move structural invariants from tests into the code

The `pg_stat_statements` block asserts things that are genuinely load-bearing —
one materialised `new_data`, upsert and prune fused, locking `SELECT` ordered —
but it asserts them by pattern-matching SQL text, which is why it cannot
survive. Those invariants belong as `Assert()`s at the point where the
statements are constructed, each with a comment naming the fix it protects
(A3, A5). Then the invariant survives the rewrite even though the test does not.

### 1.3 Write down the contract as one black-box file

The feature's promises are currently spread across 16 regression tests, four
isolation specs and several thousand words of prose in this directory. Before
rewriting the thing that implements them, they should exist in one place as
executable, implementation-blind assertions:

- a refresh makes its scope match a full refresh, for every safe predicate shape
- rows outside the scope are untouched
- readers never block
- overlapping refreshes serialize; disjoint ones do not
- a row leaving the scope is deleted (documented, deliberate — see B15)
- the rowcount reported is the number of rows changed

That file is the acceptance criterion for Phase 2.

### 1.4 Close the two gaps the oracle structurally cannot see

The oracle is single-session, so it cannot see locking or privilege behaviour at
all. Those are covered today by four specs and three privilege tests, two of
which are Tier 3. Before the rewrite, make sure the *behavioural* half of each
has a Tier 1 home, so the coverage does not disappear with the spec.

---

# Phase 2 — Implementation

## What is verified about the current code

- `ExecRefreshMatView()` already holds the parsed view `Query` as `dataQuery`
  (`matview.c:604`), taken from the relcache rule, and the **full refresh path
  already uses it properly** — `refresh_matview_datafill()` does
  `QueryRewrite` → `pg_plan_query` → `ExecutorRun`. The partial refresh is the
  odd one out in its own file.
- `AddQual(Query *parsetree, Node *qual)` is exported from `rewriteManip.h`.
  Attaching a predicate to a Query is a supported operation, and the rewriter
  does exactly this.
- **`commandType = CMD_INSERT` is set only in `analyze.c`.** Nothing else in the
  backend constructs an INSERT `Query`. `OnConflictExpr` is likewise built only
  in `transformOnConflictClause()`. There is **no precedent in core** for
  building an upsert programmatically.

That asymmetry is the whole shape of this phase: the read side is well
supported, the write side is not.

## 2.1 The read side — low risk, high payoff

Replace `pg_get_viewdef()` → text → SPI with `copyObject(dataQuery)` +
`AddQual(predicate)`. The relcache copy must not be scribbled on, hence the
copy.

This alone removes, by construction rather than by fix:

| item | why it stops existing |
|---|---|
| B1, B2 | a Query holds OIDs; a rename cannot re-resolve it to a different relation |
| B3 | parameter types live in the tree, not in a rendered `$1` |
| B7, B14 | the bespoke plan cache and its use-after-free exist to avoid re-deparsing; with no deparse, most of its reason to exist goes |
| B9 | `RestrictSearchPath()` guards name resolution in generated text; the view side no longer resolves names at all |

Five tracked items and one CVE-shaped hazard, deleted rather than patched.

## 2.2 The write side — the real work, and an open question

Three options, none free:

**(a) Build the DML `Query` trees by hand.** Most correct, no text anywhere.
But it means reproducing `transformInsertStmt` and `transformOnConflictClause`
logic with no precedent to copy, and getting arbiter-index inference right by
hand. High review risk precisely because it is novel.

**(b) Keep the DML in SPI, but static.** The upsert and prune SQL become fixed
strings whose only variable parts are relation and index identifiers resolved
once, with the *source rows* supplied from the Phase 2.1 Query rather than by
deparsing the view. Much less string-building, and the dangerous part — the view
definition — stops being text. Lower risk, and it leaves a smaller version of
the current design in place.

**(c) Drive `ModifyTable` directly.** Most control, most work, and the least
like anything else in `matview.c`.

**The open design question that gates this choice:** A3's fix depends on the
upsert and the prune being *one statement over one materialised `new_data`* —
proven necessary in `safety/a3-split-gap.sh`, where splitting them leaves a
stale row that neither statement corrects. Any option that separates view
evaluation from DML has to preserve that guarantee by some other means. That
question should be answered before choosing, not during.

## 2.3 What this phase does not change

It does not settle the two-implementation question (whether `CONCURRENTLY`
should select a different *algorithm*), and it should not try to. That is a
semantics decision; this phase is a mechanism change. Doing both at once makes
the differential oracle useless, because divergence could mean either.

---

# Phase 3 — Performance

Only after Phase 2, because most of what follows is measured against code that
will have changed.

## What is already known

A scope-1 refresh is **41.5 µs** (`-O2`), decomposed:

| component | µs | share |
|---|---|---|
| the upsert — the work asked for | 11.1 | 27% |
| the prune | 9.6 | 23% |
| separate `SELECT ... FOR UPDATE` | 7.1 | 17% |
| `ORDER BY` inside `new_data` | 5.3 | 13% |
| CTE fusion penalty vs two statements | 4.4 | 11% |
| `count(*)` rowcount wrapper | 1.6 | 4% |
| scaffolding | 2.4 | 6% |

## What is already ruled out — do not re-litigate

- **Splitting the fused CTE** (1.5× on paper) reopens a consistency gap.
  Demonstrated, not argued: `safety/a3-split-gap.sh`.
- **Dropping `new_data`'s `ORDER BY`** (13%) breaks insert-order locking.
  Gated by `matview_where` Test 16.
- **Dropping the locking `SELECT`'s `ORDER BY`** breaks A5. Gated by
  `matview-where-lockorder.spec`.

## Candidates, in rough order of expected value

**3.1 B16 — the commit-per-refresh cliff.** 300 scope-1 refreshes in one
transaction measure 82.8 µs each; the same refreshes one-transaction-each
measure 970 µs. **~12×, unconfirmed.** The hypothesis worth testing first: a
refresh writes to the matview, that write sends a relcache invalidation, and the
next refresh's cache sweep discards the plans — so a drain process committing per
refresh re-plans every time while a trigger inside one transaction never does.
If it holds it affects every queue-and-drain pattern in `USE-CASES.md`, and
Phase 2.1 may dissolve it outright.

**3.2 Parameterise predicate `Const`s.** A literal predicate that varies per call
costs **4.2×** because the cache is keyed on deparsed text. Identified, never
built. Phase 2.1 changes the shape of this problem — possibly removes it.

**3.3 Revisit the rowcount wrapper.** 4% for reporting, and B8 is being changed
anyway to unify the count across both forms. Worth doing at the same time.

**3.4 The two-implementation question, as a performance matter.** The crossover
run says `CONCURRENTLY` wins at **every scope tested on four of six workloads**,
including at 100% of the matview. Only the two plain-projection shapes ever
favour the bare form, and not until ~2000–5000 rows. That is an argument that
the second implementation earns its place in a narrower band than assumed — and
it is measurable, not a matter of taste.

**3.5 Re-run the on-list benchmark.** The numbers Adam posted describe v1.
Everything since has moved, in both directions.

## Method, which has bitten twice already

- **`make clean` after every `configure`.** This tree has `autodepend` empty, so
  no `.deps` files exist and `make` never knows a `.o` depends on `pg_config.h`.
  It relinks stale objects and reports success. This has produced two silently
  wrong builds here — a "`-O2`" build that was still `-O0` with assertions on,
  and an "`--enable-injection-points`" build whose server said injection points
  were unsupported. See `bench/README` item 0 for the checks that catch it.
- **Record the build with every number.** `bench_result` stores
  `debug_assertions`; a debug measurement is not comparable to an optimised one
  even as a ratio. Several ratios in this tree moved by more than 2× when that
  was corrected.
- **Settle between measurements.** Sweep position otherwise correlates with
  accumulated bloat and whatever is measured last looks worst.
