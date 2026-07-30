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

# Operating model: fuzz while it moves, crystallise when it stops

The fuzzer and the static suite are not alternatives. They are the two ends of a
pipeline, and the direction matters:

    fuzz -> find a divergence -> minimise it -> commit it as a static test

Every case in the shipped suite should be a failure that **actually happened**,
reduced to its smallest reproducing form. That is a better basis than the one
used so far, which was: imagine a failure mode, write a test for it, and
discover afterwards that half of them could not fail.

Which instrument is in use depends on how much the implementation is moving:

| stage | fuzzer mode | why |
|---|---|---|
| Phase 1 | oracle mode, against a full refresh | establish it is quiet on current code, so later noise means something |
| Phase 2, implementation | **differential: old vs new** | the strongest signal available, and only available while both paths exist |
| Phase 3, optimisation | oracle mode, continuous | the implementation is stable; what changes is how it performs |
| after | **deleted** | it is a development instrument |

What ships to -hackers is deterministic tests only. A probabilistic test in the
regression suite is a flaky test, and reviewers are right to reject it. The
static suite is not a downgrade from the fuzzer — it is the deliverable, and the
fuzzer is the thing that writes it.

## Two things this needs that a naive fuzzer does not have

**A shrinker.** A raw failure is "these 400 interleaved operations produced a
wrong matview", which is an anecdote, not a test. It has to reduce to the
smallest reproducing case before it is worth anything. For the single-session
oracle that is easy — it already enumerates one mutation at a time. For
concurrency failures it means recording the operation log and replaying with
operations removed, or with forced serialisation, until it stops failing; then
building a deterministic isolation spec around whichever rows diverged. Without
this the fuzzer generates work rather than tests.

**An exit criterion.** "The fuzzer is quiet" has to be a number, decided before
it is needed rather than when someone wants to move on: clean across the full
shape matrix for K operations, at N concurrency levels, on both refresh forms.
Otherwise the transition from Phase 2 to Phase 3 is a judgement call made by
whoever is tired.

## The differential window closes

Differential mode — running the same mutation under both implementations and
diffing — is the highest-value configuration in the whole plan, and it exists
only while the old path is still reachable. Once the old implementation is
deleted the fuzzer drops back to comparing against a full refresh, which is
weaker: it can tell you the answer is wrong, but not that it *changed*.

So the old path stays until the fuzzer's exit criterion is met, not until the
new one looks finished.

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

## Restate the requirements as properties, not as mechanisms

The current gates pin *how* three guarantees are met rather than *that* they are
met. That is a defect in the gates, not a constraint on the implementation. Any
replacement that delivers the property is equally valid, and a test that says
otherwise is punishing correct work.

| property | what must hold | current mechanism (one way to satisfy it) | is the gate property-level? |
|---|---|---|---|
| **P1 — single evaluation** | the upsert and the prune agree about which rows the view produces | one `MATERIALIZED` CTE | **no** — the `pg_stat_statements` block matches on the literal text `new_data AS MATERIALIZED` |
| **P2 — deterministic lock order, existing rows** | two overlapping refreshes lock the rows they share in the same order | `ORDER BY` on the locking `SELECT` | **yes** — `matview-where-lockorder.spec` observes *which rows are locked* via `xmax`, and says nothing about how the order was achieved |
| **P3 — deterministic lock order, inserted rows** | two refreshes inserting the same new keys do not deadlock | `ORDER BY` inside `new_data` | **no** — Test 16 reads ctid order, a proxy that only holds while insertion order and lock order are the same thing |

P2 is the model. It was arrived at by accident — the direct probe was
unorderable, so it fell back to observing state — but the accident produced the
right shape: assert the outcome, not the construction.

### The `pg_stat_statements` block is worse than untestable — it is obstructive

It does not merely fail to survive Phase 2. It would **fail against a correct
rewrite** that delivers P1 by other means: a single `ModifyTable` plan, an
explicit tuplestore read twice, anything that is not the literal string
`new_data AS MATERIALIZED`. A gate that goes red when the work is done properly
is worse than no gate.

**Delete it at the start of Phase 2, not the end.** Its only unique coverage is
M4, and M4 was only ever interesting because it removed the mechanism that
happens to deliver P1 today. If P1 is delivered another way, M4 is not a
regression and there is nothing to catch.

### Test 16 needs restating at the property level

The property is P3: two refreshes inserting overlapping new keys must not
deadlock. The current test asserts ctid order, which is a proxy that holds only
while the implementation inserts in lock order. An implementation that acquires
the locks separately, in order, and then inserts in any order satisfies P3 and
fails Test 16.

The property-level version is the one already written for P2's cousin:
`matview_where_stress/run.sh` drives two concurrent refreshes over overlapping
*existing* rows and asserts no deadlock. The same shape over overlapping *new*
keys tests P3 directly. Write that during Phase 1; keep Test 16 only until it
exists, and only as a cheap smoke test with a comment saying it is a proxy.

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

### 1.1b What a correctness gate for P1 looks like, and where the limit is

A test should prove the matview is right, not that a CTE exists to make it
right. For P2 and P3 that is straightforward — the correctness statement is
"overlapping refreshes do not deadlock and lock the same rows in the same
order", and both are observable without knowing how ordering was achieved.

P1 is harder, and the reason is worth stating plainly rather than working
around: **a correct implementation has no window to exploit.** The failure it
prevents — the upsert and the prune disagreeing about which rows the view
produces — requires a base-table change to land *between* two evaluations. An
implementation that evaluates once has no such moment, so no injection point can
be placed there, so no deterministic test can distinguish a correct
implementation from a differently-correct one. That is not a gap in the test
suite; it is what the guarantee means.

Two things can be done instead, and they are complementary:

**(a) Assert it where it is constructed.** Whatever mechanism delivers P1, the
code knows it is delivering it. An `Assert()` at that point, naming A3, survives
any rewrite that keeps the guarantee and fires on one that drops it by accident.
This replaces what the `pg_stat_statements` block was reaching for, without
pinning the mechanism.

**(b) Fuzz for the consequence.** A P1 violation is a *transient* inconsistency:
the matview briefly holds a row matching no snapshot of the base. It is not
permanent divergence — a later refresh repairs it — which is why a
converge-at-the-end test cannot see it. What can see it is a reader looking
during the window.

The gate is therefore a concurrent correctness fuzzer: N sessions churning the
base, M sessions refreshing overlapping scopes, and a reader asserting that
every matview row in scope matches the view. Probabilistic, and honest about
being so — it is the same trade `matview_where_stress/run.sh` already makes for
lock ordering, and that one found real deadlocks. Build it in Phase 1, run it
against the current implementation to establish it is quiet, and run it against
each step of Phase 2.

It is worth being explicit that (b) is weaker than the gates for P2 and P3.
Absence of a failure over N runs is not proof. But it is a correctness gate —
it fails when the matview is wrong, and only then — which is the property that
matters, and it is strictly better than a gate that fails when the matview is
right but built differently.

### 1.1c Calibrate the fuzzer against every bug already known

A fuzzer nobody has seen catch anything is the same defect as a test that cannot
fail, one level up. Before it is trusted to guard a rewrite it has to be shown to
find the bugs that are already understood.

There is a ready-made corpus: every fix in `ISSUES.md` and every mutation from
B17. Re-apply each, one at a time, and record whether the fuzzer finds it and
how long it took.

    A3   split the fused CTE                    must find
    A4   drop ON CONFLICT from the diff insert  must find
    A5   drop ORDER BY from the locking SELECT  must find
    B4   arbiter NULL handling on the anti-join must find
    B6   arbitrate on the wrong unique index    must find
    M1   drop ORDER BY, locking SELECT          must find
    M2   drop ORDER BY, new_data                must find
    M3   remove the locking SELECT              must find
    M6   lock after the CTE instead of before   must find

Anything on that list the fuzzer misses is a gap in its generators — probably a
shape it never builds, a predicate form it never emits, or a concurrency pattern
it never schedules — and it should be fixed before moving on. The time-to-find
for each is also the calibration for the exit criterion: if the slowest known bug
takes twenty minutes to surface, "clean for five minutes" means nothing.

Expect some misses. A6, A7, B5 and B9 are privilege behaviour and B14 is a
use-after-free; a data-correctness fuzzer will not see any of them, and that is
fine — it says which coverage has to stay static rather than being folded in.

#### Measured, against the single-session oracle

`./calibrate.sh`, eight mutations, each rebuilt and re-run from a recorded
pristine baseline. A run is ~40s, which is the number the exit criterion has to
be built from.

| mutation | issue | observable in | verdict | how |
|---|---|---|---|---|
| A4 · drop `ON CONFLICT` | A4 | one session | **CAUGHT** 33s | `errs` 0→96, not `diverged` |
| B4 · anti-join NULL handling | B4 | one session | **CAUGHT** 38s | `nullable_key/concurrently` 0→76 |
| B6 · wrong unique index | B6 | one session | MISSED 40s | corpus cannot express it |
| M1 · drop `ORDER BY`, locking `SELECT` | A5 | two sessions | MISSED 41s | structural |
| M2 · drop `ORDER BY`, `new_data` | P3 | two sessions | MISSED 40s | structural |
| M3 · remove the locking `SELECT` | A3 | two sessions | MISSED 42s | structural |
| M4 · `NOT MATERIALIZED` | — | benign | MISSED 38s | correct: nothing to catch |
| M6 · lock after instead of before | A3 | two sessions | MISSED 41s | structural |

**Two of three data bugs, none of the four concurrency bugs.** The concurrency
misses are not a defect — the oracle is single-session by construction and there
is no second session for a lock-ordering bug to be a bug *in*. They are the
measurement that says the concurrent fuzzer of 1.1b(b) is a separate instrument
that has to be built, not a mode of this one.

The two data-bug results are the ones worth reading closely, because both were
mispredicted and each was a gap of a different kind:

- **B4 was missed until the corpus grew a shape for it.** Every base table in
  the space started `id int primary key`, so no case had a NULLable unique key,
  and B4 cannot occur without one. Adding case 19 `nullable_key` moved it from
  MISSED to CAUGHT with no change to the detector. This is the generator gap
  1.1c predicts, and it is worth noting how it presented: as a clean run.

- **B6 is missed for a reason a new case cannot fix.** `exh_driver.sql` creates
  exactly one unique index per case, and B6 is a collision on a *non-arbiter*
  index. Closing it means changing the driver's schema to carry an optional
  second index, not adding another row. Left open deliberately — B6 is a
  documented limitation rather than a live bug, so the cost is knowing the
  fuzzer cannot stand in for `matview_where` Test 15.

**Consequence for Phase 4.** "Delete the static tests the fuzzer covers"
requires knowing which those are, and right now the fuzzer does not cover Test
11 (B4) — it only does since case 19 — or Test 15 (B6) at all. Any deletion
list has to be derived from a calibration run, not from reading the tests.

#### Measured, against the concurrent fuzzer

`fuzz.sh`, the instrument for the four the oracle cannot see. Three modes, each
aimed at a guarantee rather than at the code that currently delivers it:
`p2` and `p3` drive two sessions through predicates that plan differently — an
index scan against a sequential scan over rows stored in descending order — over
existing rows and over rows the refresh has to insert, and watch for deadlock.
`serial` drives the base monotonically upward under concurrent refreshes and
watches for the matview's total over the scope going *down*, which is a lost
update and means the refreshes did not serialize.

| mutation | issue | mode that fires | verdict | signal |
|---|---|---|---|---|
| M1 · drop `ORDER BY`, locking `SELECT` | A5 | `p2` | **CAUGHT** 92s | 76 of 160 deadlocked |
| M2 · drop `ORDER BY`, `new_data` | P3 | `p3` | **CAUGHT** 81s | 40 of 80 deadlocked |
| M3 · remove the locking `SELECT` | A3 | `serial` | **CAUGHT** 44s | 45 lost updates |
| M6 · lock after instead of before | A3 | `serial` | **CAUGHT** 49s | 55 lost updates |
| *pristine* | — | — | **QUIET** 39s | — |

Each is caught by the mode aimed at it and by no other. That specificity is the
useful part: `p2` stays quiet under M2, `p3` stays quiet under M1, and both stay
quiet under M3 and M6, where removing the locking altogether leaves nothing to
deadlock on. M3's signal reads exactly 6000 — two increments across 3000 rows —
which is what a stale snapshot committing last looks like.

**M2 closes B17's open item.** It was recorded there as the single genuinely
uncovered mutation, caught by no gate in the tree.

#### Catching it once is not the same as being a gate

A mutation caught in one run can still be missed in the next, and a gate that
misses is worse than no gate because it is believed. So each detection was
repeated six times, counting not just whether it fired but how hard.

| mutation | mode | rate | events per run |
|---|---|---|---|
| M1 | `p2` | 6/6 | 1 1 1 1 4 1 |
| M2 | `p3` | 6/6 | 40 40 40 40 39 40 |
| M3 | `serial` | 6/6 | 24 25 24 25 27 29 |
| M6 | `serial` | 6/6 | 28 28 28 26 33 25 |

Never missed in 24 runs — but read the M1 row, not the rate column. One event
means the catch hangs on a single scheduling coincidence, and a detector that
reports a clean run when the coincidence does not happen is exactly the failure
this table exists to find. It is why the repeat pass is worth its runtime: the
one-shot calibration showed M1 CAUGHT and said nothing about how narrowly.

Those numbers are from *before* the `p2` change described below; the final
figures are in the calibration table above. Two rounds of tuning got there, and
both are worth recording, because the parameter that looked obvious was the
wrong one each time.

**`serial` was a coin flip.** The writer and watcher ran for a fixed count and
finished long before the refreshers, so most of each run raced over a base
nobody was changing — where no lost update is possible even under a mutation
that guarantees them. Measured rate for M6: **3 of 6**, 1–2 events when it fired.
Driving both until the refreshers finish took it to 6/6 at 25–33 events.

**`p2` did not respond to a longer run at all.** Under M1, `ITER=40` across two
sessions found 4 deadlocks and `ITER=150` across the same two found **1**. The
rate is per run, not per refresh: two sessions settle into lockstep and stop
overlapping in the way that deadlocks, so a longer run mostly adds refreshes
that cannot fail. Sessions are the lever instead —

    2 sessions    1 of 80    (1%)
    4 sessions   77 of 160  (48%)
    6 sessions  173 of 240  (72%)

so the default is 4, and pristine stays quiet at that width.

The common thread is worth stating because it will recur in Phase 3. Neither
detector was wrong about *what* to observe — both invariants were right and both
did fire. They were wrong about *when* and *how widely*, and a detector that is
live for only part of the window, or that lets its sessions fall into step,
reports a clean run for the same reason a correct implementation does. "Ran
longer" is the intuitive knob and it was the useless one in both cases.

### 1.2 Move structural invariants from tests into the code

The `pg_stat_statements` block asserts things that are genuinely load-bearing —
one materialised `new_data`, upsert and prune fused, locking `SELECT` ordered —
but it asserts them by pattern-matching SQL text, which is why it cannot
survive, and why it would go red against a correct rewrite.

The invariants themselves are worth keeping — as `Assert()`s at the point the
guarantee is established, each naming the fix it protects (A3, A5). An assertion
says "this implementation delivers P1"; the deleted test said "this
implementation delivers P1 *by writing a CTE*". The first survives any
mechanism; the second forbids all but one.

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

## What is ruled out is a property, not a mechanism

Each of these is a *guarantee that cannot be given up*. None of them is a
requirement to keep the current construction. Replace the CTE, replace either
`ORDER BY`, restructure all of it — as long as the property still holds and a
property-level gate still passes.

- **P1, single evaluation** cannot be abandoned: the upsert and the prune must
  agree about which rows the view produces. Demonstrated, not argued —
  `safety/a3-split-gap.sh` shows two statements over two snapshots leaving a
  stale row that neither corrects. The 1.5× that splitting appears to buy is
  the cost of that guarantee, not waste.
- **P2, deterministic lock order over existing rows** cannot be abandoned
  (A5). Gated property-level by `matview-where-lockorder.spec`.
- **P3, deterministic lock order over inserted rows** cannot be abandoned.
  Gated only by proxy today — see Phase 1.

The 13% attributed to `new_data`'s `ORDER BY` and the 11% to CTE fusion are
therefore **not** off the table. They are the current price of P1 and P3. A
cheaper way to pay it is a legitimate optimisation; not paying it is not.

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

## Phase 3 is a loop, not a pass

Optimise, run the fuzzer, run the static gates, measure. Any divergence stops
the loop and gets minimised into a static test before anything else proceeds.
Exit when the candidate list is exhausted or the remaining items are not worth
their risk — not when the numbers look good, which is a different question.

Each iteration ends with a `bench_result` row under a new run label, so the
whole optimisation history is diffable afterwards rather than being a memory of
what seemed faster.

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

---

# Phase 4 — Crystallise the shipped suite

The fuzzer is a development instrument and does not ship. What ships is the
static suite it produced, against whatever implementation actually landed.

- Every minimised fuzzer finding becomes a regression test or an isolation spec,
  each with a comment saying what it is guarding and, where relevant, which
  reviewer raised it.
- The property gates get re-derived against the final implementation: P2's spec
  re-verified, P3's no-deadlock test in place, P1's `Assert()` sited where the
  final code establishes the guarantee.
- Every test that only existed to guard the old mechanism is deleted, not
  carried forward. `ISSUES.md`'s Disposition column says which — but several
  entries are *conditional*, and the conditions have to be read as fired or not
  rather than taken at face value:

  | disposition | condition | state |
  |---|---|---|
  | A8 · Test 14, "DELETE once the swap lands" | the swap landed in `0607847` | **fired** — replace with a behavioural test beside `matview-where-serialize` |
  | A5 · `run.sh`, "delete with this directory" | Phase 4 | fires here |
  | B1/B2 · cache tests, "delete if the plan cache goes away" | Phase 2.1 removes most of the cache's reason to exist | **read at Phase 2 exit**, not before |
  | B9 · Test 13 search_path half | settled: the restriction stays | **resolved** — keep, add an `errhint` |

  A conditional disposition nobody re-reads is how Test 14 came to sit in the
  tree for a dozen commits announcing that a swap which had already landed was
  "not in the tree".
- **Both build systems.** `parallel_schedule` and `isolation_schedule` are read
  by autoconf *and* meson, so regress and isolation tests need registering once.
  Module specs are not — `src/test/modules/injection_points/meson.build` lists
  them individually and has to be edited alongside the `Makefile`. This was
  missed once already for `matview-where-snapshot`.
- Delete `src/test/matview_where_stress/` — the whole directory, including the
  fuzzer, the benchmark suite and these notes.

# Phase 5 — Review pass

Read the patch as a reviewer would, before a reviewer does.

- **Correctness re-read**, with the fuzzer no longer available as a crutch:
  locking, error paths, memory contexts, what happens on `ERROR` at each stage.
- **Style**: `pgindent`, `typedefs.list` for any new struct, comment conventions,
  `ereport` with the right `errcode` and a `errhint` where the cause is not
  obvious — B9's bare "relation does not exist" is the outstanding one.
- **Scope discipline**: anything not needed for this feature comes out.
- **Commit splitting**: the fixes should be reviewable independently of the
  implementation change, which means several commits with self-contained
  messages, not one large one.

# Phase 6 — Final performance regression check

A full benchmark run against the final tree, compared to the run label from the
end of Phase 3. The review pass changes code; changed code changes performance.
This is the check that nothing regressed while being tidied.

Also the point at which the numbers stop being working notes and become
evidence, so this run is the one worth keeping: full sweep, every workload, the
build recorded, normalised against a full rebuild so it is comparable on someone
else's machine.

# Phase 7 — Patch and the -hackers response

- Rebase onto current master and re-run everything.
- **Per-reviewer replies.** Dharin (A1, A2, A9), Vellaipandiyan (A5, A8, A9),
  Zsolt (A6, A7), Kirk (the wide-row case), Nico (the recursive case). Each
  raised something specific and each is owed a specific answer, including where
  the answer is "you were right and here is the measurement".
- **The independently-found items** get their own section — B1 through B17 are
  not on the thread, and several are more serious than what is.
- **The benchmark material from Phase 6** goes on-list. Note that the numbers
  Adam posted originally describe v1 and have to be superseded explicitly rather
  than quietly.
- **The open questions get asked rather than hidden**: the two-implementation
  question, blast radius handling, scope-drift semantics. A patch that names its
  unresolved design decisions gets better review than one that buries them.
