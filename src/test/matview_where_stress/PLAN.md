# Plan: tests, then implementation, then performance

Branch-local. Not part of the patch.

Seven phases. The first three are the substance -- the tests are what let the
implementation change safely, and the implementation change is what makes the
performance work worth doing -- and the rest carry it to a posted patch. Doing them in any other order means optimising
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
| the safety oracle, 3272 mutations | mutates base data, refreshes, diffs against a full refresh — never looks at how the refresh is done |
| the benchmark suite | same, and it becomes the before/after measurement |
| `matview_where` Tests 1–15 | behavioural: INCLUDE columns, NULL keys, drift, multiple unique indexes, lock levels |
| `matview_where_privs` Tests 2, 3 | scoped maintenance exemption; `PG_TRY` restoring the flag |
| `matview-where-serialize.spec` | readers never block; overlapping refreshes serialize; disjoint ones do not |
| `matview-where-deadlock.spec` | characterisation of cross-statement deadlock |
| `matview-where-insertorder.spec` | P3, via `pg_blocking_pids()` — added in Phase 1 |
| `matview_where_contract.sql` | the promises, stated with no reference to the implementation — added in Phase 1 |
| `fuzz.sh`, `safety/rundiff.sh` | concurrency and cross-implementation gates; probabilistic, and deleted at Phase 4 |

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
| `pg_stat_statements` structural block | asserted the literal text of generated SQL. In an implementation that generates no SQL there is nothing to assert. **DELETED** in the Phase 2 opening commit, before the first line of the rewrite; no replacement is possible |
| `matview_where_privs` Test 1 (A6) | the leakproof-or-ownership rule exists *only* because SPI runs one statement under one userid. If the rewrite allows the predicate to run as the invoker, this test's expectation inverts — which is a win, not a loss |

## Restate the requirements as properties, not as mechanisms

The current gates pin *how* three guarantees are met rather than *that* they are
met. That is a defect in the gates, not a constraint on the implementation. Any
replacement that delivers the property is equally valid, and a test that says
otherwise is punishing correct work.

| property | what must hold | current mechanism (one way to satisfy it) | is the gate property-level? |
|---|---|---|---|
| **P1 — single evaluation** | the upsert and the prune agree about which rows the view produces | one `MATERIALIZED` CTE | **not deterministically, and it cannot be** — a correct implementation has no observable window (1.1b). Gated by `fuzz.sh`'s `serial` mode, which catches M3 and M6 at 45 and 55 events. The `pg_stat_statements` block matched the literal text and has been deleted |
| **P2 — deterministic lock order, existing rows** | two overlapping refreshes lock the rows they share in the same order | `ORDER BY` on the locking `SELECT` | **yes** — `matview-where-lockorder.spec` observes *which rows are locked* via `xmax`, and says nothing about how the order was achieved |
| **P3 — deterministic lock order, inserted rows** | two refreshes inserting the same new keys do not deadlock | `ORDER BY` inside `new_data` | **yes, since Phase 1** — `matview-where-insertorder.spec` reads which session a covering refresh blocked on via `pg_blocking_pids()`, which names the order the locks were taken in and not the order the rows landed in. Test 16's ctid proxy is retained only as a smoke test |

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

**Done — first commit of Phase 2**, ahead of any change to `matview.c`. The
rows-tracking case immediately above it is kept, on its own disposition;
`pg_stat_statements` is 16/16 without the block. M4 now has no detector
anywhere in the tree, which is the intended end state and not an oversight: it
was already `MISSED` by both calibrated instruments, and the only thing that
ever saw it was the assertion on the mechanism it removes.

### Test 16 needs restating at the property level

The property is P3: two refreshes inserting overlapping new keys must not
deadlock. The current test asserts ctid order, which is a proxy that holds only
while the implementation inserts in lock order. An implementation that acquires
the locks separately, in order, and then inserts in any order satisfies P3 and
fails Test 16.

**Done, deterministically, which was not the expected outcome.**
`matview-where-insertorder.spec`. The plan assumed P3 would need a
probabilistic reproducer, because provoking the deadlock needs two refreshes
in flight at once and isolationtester drives one step at a time — the same
constraint that pushed `matview-where-lockorder` into reading `xmax` instead.

The way through is that the deadlock does not have to be provoked; the *order*
has to be observed, and for inserted rows there is an observable that does not
depend on the rows existing yet. A refresh that reaches a key another
transaction has speculatively inserted waits on that transaction, and
`pg_blocking_pids()` names it. So pin the two ends of the key range in separate
sessions, one key each, send a refresh covering both, and ask which end it
stopped on. That is the order it started from.

    with ORDER BY on new_data   blocked_by = pin_lo
    without it                  blocked_by = pin_hi   (heap order, descending)

Verified both ways: under M2 the answer flips, so it is a detector and not a
decoration. It asserts the order the locks were actually taken in rather than
the physical order of the resulting rows, so the implementation Test 16 gets
wrong — lock separately in order, then insert in any order — passes it, which
is the whole point of replacing Test 16.

Test 16 is now redundant; kept as a cheap single-session smoke test, marked for
deletion at Phase 4.

## What to build before Phase 2 starts

### 1.1 Differential mode in the safety oracle — the highest-value item

Today the oracle compares a partial refresh against a full refresh. During the
rewrite it can do something far stronger: **compare the old implementation
against the new one, over the same 3272 mutations.**

Keep both paths reachable behind a developer GUC for the duration of the
rewrite. For each mutation, run it under old and under new and diff the
resulting matview. Any divergence is a rewrite bug, localised to one mutation,
with no need to reason about whether the old behaviour was correct.

This turns "did I preserve semantics" from a judgement call into a test. It is
the single thing that makes the rewrite tractable, and it should exist before
the first line of Phase 2.

**Built and calibrated, against the pair that exists today.**
`safety/diff_driver.sql` and `safety/rundiff.sh`. For each mutation it stands up
two identical matviews over the same base, refreshes one each way, and diffs
them — so "these two implementations disagree" is a single number with the
offending mutation and predicate attached.

The Query-tree path does not exist yet, so the two ways are the two that do:
the bare form (match/merge) against `CONCURRENTLY` (direct modification). They
are genuinely different implementations of one contract, and the contract file
already states they must agree (Promise 7). When the new path lands, the two
form strings become the two GUC settings and nothing else in the harness
changes.

Instantiating it now rather than on the first day of Phase 2 is the whole
point. A harness written against an implementation that does not exist yet is a
harness nobody has watched catch anything — the exact defect 1.1c exists to
find, one level up. This one has been watched:

    pristine   21 shapes, 1533 mutations, 0 divergence, 0 errors either side
    under B4   nullable_key 76/96 and nullable_composite 12/48 disagree

Worth noting what it stays quiet about, because it is not a weakness. The
unsafe shapes — `drift_out`, `topn`, `win_rowkey` and the rest — show zero
divergence here while diverging heavily in the oracle. Both forms are wrong in
the same way on those, and that is exactly the distinction: the oracle asks "is
this predicate safe", this asks "do the two implementations agree". A rewrite
can be perfectly faithful and still be refreshing an unsafe shape, so both
questions have to be asked separately.

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
| A4 · drop `ON CONFLICT` | A4 | one session | **CAUGHT** 46s | `errs` 0→96, not `diverged` |
| B4 · anti-join NULL handling | B4 | one session | **CAUGHT** 56s | `nullable_key` 0→76, `nullable_composite` 0→12 |
| B6 · wrong unique index | B6 | one session | **CAUGHT** 52s | `two_ukeys` `errs` 0→12 |
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

- **B6 needed a change to the driver, not another case.** `exh_driver.sql`
  created exactly one unique index per case, and B6 is a collision on a
  *non-arbiter* index — inexpressible, not merely unwritten. `probe_exh` now
  carries an optional `ukey2`, and case 20 `two_ukeys` uses it. B6 moved from
  MISSED to CAUGHT.

  It surfaces as **errors, not divergence**, which is worth recording: with the
  wrong arbiter the upsert finds nothing to conflict on, inserts a second row
  with the same `id`, and collides with the other unique index inside the same
  statement — because the prune's `DELETE` is not visible to the upsert's
  `INSERT`. A vector that compared only `diverged` would have called this a
  miss. That is the second bug the `errs` column has caught.

  Note also what makes the arbiter choice decidable at all: a matview cannot
  have a `PRIMARY KEY`, so `indisprimary` is false for every index on it and
  `matview_pick_arbiter_index` falls through to "first usable". The mutation
  reverses that to "last". Without two indexes there is no difference between
  those two rules.

- **A NULLable key needed both shapes.** Case 19 covers a single-column
  NULLable key; case 21 `nullable_composite` covers a composite `(a, bcol)`
  where only `bcol` is NULLable. The second is not implied by the first — the
  operator choice applies to every column of the key, and getting one column
  right says nothing about a key where only some columns can be NULL. Both
  catch B4 (76 and 12 divergences).

**Consequence for Phase 4.** "Delete the static tests the fuzzer covers"
requires knowing which those are. As of this run the fuzzer does cover Test 11
(B4) and Test 15 (B6) — but it covered neither before cases 19–21 existed, and
nothing about reading the tests would have revealed that. Any deletion list has
to be derived from a calibration run.

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

The `pg_stat_statements` block asserted things that are genuinely load-bearing —
one materialised `new_data`, upsert and prune fused, locking `SELECT` ordered —
but it asserted them by pattern-matching SQL text, which is why it could not
survive, and why it would have gone red against a correct rewrite.

The invariants themselves are worth keeping — as `Assert()`s at the point the
guarantee is established, each naming the fix it protects (A3, A5). An assertion
says "this implementation delivers P1"; the deleted test said "this
implementation delivers P1 *by writing a CTE*". The first survives any
mechanism; the second forbids all but one.

**Done, and smaller than the heading promises.** Two assertions went in, both
preconditions rather than restatements of the SQL:

    Assert(conflict_cols.len > 0);   /* an order exists to impose (A5, P3) */
    Assert(join_clause.len > 0);     /* the prune has a condition */

What is *not* asserted is the P1 invariant itself, and the reason belongs here
rather than in a footnote. There is nothing at build time to look at: whether
the upsert and the prune see one evaluation is a property of how the statement
executes, and 1.1b already establishes that a correct implementation has no
window in which the difference is observable. An `Assert()` that pattern-matched
the generated text for `MATERIALIZED` would be the `pg_stat_statements` block
again, in C, with the same defect — red against a correct rewrite.

So P1's gates stay where 1.1b put them: `fuzz.sh`'s `serial` mode, which catches
M3 and M6 at 45 and 55 events, and differential mode when it exists. The
assertions cover the preconditions that any implementation needs; the fuzzer
covers the behaviour.

Verified against a `--enable-cassert` build (`rebuild.sh --full ...
--enable-cassert`), which the working `-O2` build does not have: assertions
report `on`, the suites are green with them live, and — separately, because the
two are not the same claim — `Assert(conflict_cols.len > 0)` was made to fail on
purpose and does: `TRAP: failed Assert("conflict_cols.len > 0")`.

That last step caught a mistake that had already invalidated the first one.
`mutations.py` defines pristine as `git show HEAD:`, so it overwrites matview.c
wholesale — and the restore after an unrelated mutation test deleted both
assertions before they had ever been committed. The suites that ran green
afterwards were green because there was nothing left to check, which is exactly
what success looks like. `mutations.py` now refuses to overwrite matview.c
unless its current contents are one of the variants that script itself can
write; anything else is someone's work in progress and needs `--force`.

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

**Done:** `src/test/regress/sql/matview_where_contract.sql`. Six promises in
one session — scope matches the view, out-of-scope rows untouched, rows leaving
and entering the scope, a no-op refresh is a no-op, both forms agree — with the
concurrency promises cross-referenced to the specs that hold them, so the
contract reads in one place even though it executes in two.

Two of the seven promises originally written did not survive contact:

- **The rowcount promise could not fail here.** `pg_regress` does not echo
  command tags, so three refreshes with three different answers produced three
  identical blanks and the check passed vacuously. It is only observable
  through `pg_stat_statements`, where it already lives. Removed, with the
  reason recorded in the file — a check that cannot fail is the defect this
  whole phase exists to find, and writing one while writing the rules against
  it is worth admitting to.

- **The no-op promise passed with the bug present.** It did two `CONCURRENTLY`
  refreshes and one bare one, then counted. Under B4 the concurrent pair took
  the matview from 3 rows to 7 — and the bare refresh, which compares whole
  rows, repaired it before the count ran. The check was measuring the repair.
  Counting after each form instead makes it fail under B4, verified.

Both were found by running the file against a mutation rather than by reading
it. Neither is visible on inspection: one looks like a test and the other looks
like a stronger test.

### 1.4 Close the two gaps the oracle structurally cannot see

The oracle is single-session, so it cannot see locking or privilege behaviour at
all. Those are covered today by four specs and three privilege tests, two of
which are Tier 3. Before the rewrite, make sure the *behavioural* half of each
has a Tier 1 home, so the coverage does not disappear with the spec.

**Done — the audit, and it found exactly two things without a home.**

Locking:

| gate | property it holds | survives a rewrite? |
|---|---|---|
| `matview-where-serialize` | readers never block; overlapping refreshes serialize, disjoint ones do not | **yes** — observes blocking, names no mechanism |
| `matview-where-lockorder` | P2, order over existing rows | **yes** — observes `xmax` |
| `matview-where-insertorder` | P3, order over inserted rows | **yes** — observes `pg_blocking_pids()` |
| `matview-where-deadlock` | characterisation of cross-statement deadlock | conditional; already marked REPLACE-or-DELETE |
| `matview-where-snapshot` | *that a refresh is two SPI statements* | **no** |

`matview-where-snapshot` is the gap. Its disposition claimed it was "the only
gate on the two-statement structure of a partial refresh", which states the
problem rather than a justification: the two-statement structure is a mechanism,
and a rewrite that fuses the lock into one plan dissolves the premise while
delivering the guarantee. Its behavioural content — a base-table change landing
between the lock and the work must not corrupt the matview — is P1, and P1's
gate is `fuzz.sh`'s `serial` mode, which catches M3 and M6 at 45 and 55 events.
So it has a home; the spec is now marked for deletion when the premise goes,
with the replacement named.

Privilege:

| test | property it holds | survives a rewrite? |
|---|---|---|
| Test 2 (B5) | the maintenance exemption is scoped to the matview being refreshed | **yes** |
| Test 3 (A7) | an error during refresh restores the flag | **yes** |
| Test 1 (A6) | *that a non-leakproof predicate requires ownership* | **no** |

Test 1 is the other gap, and it is subtler than the snapshot spec because it
does not merely stop applying — it **inverts**. The property is that a predicate
cannot be used to read across a privilege boundary. Today that is delivered by
refusing non-leakproof predicates from non-owners, because SPI runs the whole
statement under one userid. A rewrite that evaluates the predicate as the
invoker delivers the same property by making the leak impossible instead of
forbidding the expression — at which point the correct expected output is
"succeeds", and a test asserting "ERROR" fails against the better
implementation.

That is a win being recorded as a regression, which is the same failure mode as
the `pg_stat_statements` block. Noted in the test itself: if Phase 2 changes who
the predicate runs as, Test 1 is to be rewritten to assert that the leak cannot
happen, not that the rejection does.

Neither gap needs a new test today. Both need the disposition to say what
happens when the premise moves, which is what was missing.

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

**Done** — `9a5195b`, behind `matview_partial_refresh_querytree`, off by
default so `safety/rundiff.sh spi querytree` can compare the two.

Replace `pg_get_viewdef()` → text → SPI with `copyObject(dataQuery)` +
`AddQual(predicate)`. The relcache copy must not be scribbled on, hence the
copy.

**`AddQual()` was the wrong tool and this plan was wrong to name it.** It
attaches the predicate to the view's *own* `WHERE` clause, which is evaluated
before grouping, windowing and `DISTINCT` — a different answer for every matview
that aggregates, and not even a well-formed question for one over a window
function. The predicate filters the view's **output**, so the view goes in a
subquery RTE and the predicate becomes the outer `WHERE`. That is what the text
version was doing all along, spelled `SELECT * FROM (viewdef) mv WHERE (pred)`;
the plan read the SQL as though the subselect were incidental.

Two more things only became visible once the tree was executed rather than
printed:

- **The transformed predicate had no collations assigned.**
  `transformRefreshWhereClause()` never called `assign_expr_collations()`, and
  nothing noticed, because a deparse does not look at collations and the text
  went back through the parser which assigned them the second time round.
  Executing the tree fails on `tag = 'hot'`. The corpus could not see it either:
  every predicate in all 21 shapes compared numbers. Shape 22 `text_key` closes
  that, and is a detector — with the fix reverted it errors on all 48 of its
  mutations and nothing else in the corpus moves.

- **Evaluating the view separately from the DML opens a window the fused CTE did
  not have.** A refresh whose scope contains a key the matview does not hold yet
  locks nothing on the locking `SELECT`, so it runs unordered beside a wider
  refresh over the same scope. If the wider one reads the matview at a later
  moment than it computed its rows, that key is in one and not the other, and
  the prune deletes a row the base still produces. Both now run under one
  snapshot, taken in `refresh_by_direct_modification()` rather than by SPI.
  Gated by `injection_points/specs/matview-where-prune-gap.spec`, demonstrated
  failing with the snapshot split and passing with it shared.

  The fuzzer could not gate this, and the attempt is worth recording. `serial`
  mode only ever `UPDATE`s, so every key it touches already exists and every
  overlapping refresh is serialized by the lock — structurally unable to reach
  it. An insert-driven mode was written and measured against a build with the
  bug deliberately present: **clean run**. The window is microseconds wide and
  the violation needs two commits inside it. The mode was deleted rather than
  kept as a detector that has been watched not to detect. Third time the
  intuitive instrument has been the wrong one; the pattern is that a window
  needs an injection point, and a rate needs a fuzzer.

This alone removes, by construction rather than by fix:

| item | why it stops existing |
|---|---|
| B1, B2 | a Query holds OIDs; a rename cannot re-resolve it to a different relation |
| B3 | parameter types live in the tree, not in a rendered `$1` |
| B7, B14 | the bespoke plan cache and its use-after-free exist to avoid re-deparsing; with no deparse, most of its reason to exist goes |
| B9 | `RestrictSearchPath()` guards name resolution in generated text; the view side no longer resolves names at all |

Five tracked items and one CVE-shaped hazard, deleted rather than patched.

### 2.1b Measure here, and again after 2.2

A deliberate pause between the two halves of the rewrite, so the second half
can be compared against something rather than asserted about.

**Performance.** `bench/run.sh --forms spi,querytree` measures both
implementations *on one binary*, which removes build variance from the
comparison — the thing that made the earlier debug-vs-`-O2` numbers
untransferable. Start it from `bench/detach.sh`: a sweep outlives the shell that
starts it only if it is put in its own session, and three sweeps were lost here
before that was diagnosed rather than guessed at. The pre-2.2 sweep is labelled
`p21-O2`; label the post-2.2 one to match.

**Injection.** `matview_where_inject` (`608b3ad`) states the case for this whole
phase as something checkable instead of something argued. There are three SQL
generators, not one — the transient-heap fill and match/merge on the bare path,
direct modification on the concurrent one — and between them they interpolate
the schema and relation name, every column name, the deparsed predicate, the
deparsed view body, and seven names they invent themselves. Each is driven with
a value chosen to close the construct it lands in and start a new statement,
against a canary table a successful escape would write to.

Two things this cost, both worth remembering:

- Every case runs all three implementations over one matview, and only the
  first has work to do. Written naively, forms two and three read back form
  one's answer and pass having executed nothing. The fix is to mutate the base
  afresh before each form with a value carrying the iteration number, and read
  the matview back after each.
- The corpus that calibrates it had rotted: 2.1's own refactor moved the text
  A4 and M6 mutate, and two other entries matched twice while being applied
  once. ISSUES.md B23.

Calibrate against `mutations.py Q1`, `Q2`, `Q3` — dropping a quoting call is
how this regresses during 2.2, and a detector for a regression that has not
happened yet cannot be calibrated against one that has.

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

### 2.3 The predicate — the last piece of text

The `WHERE` clause is already a parsed node tree by the time
`refresh_by_direct_modification()` sees it; it is deparsed to text only because
SPI needs a string, and it is rendered twice — into the locking `SELECT` and
into the prune's `DELETE`. Once (a) lands there is no reason for either.

This is also what forces the rule that a non-leakproof predicate requires
ownership (A6, `matview_where_privs` Test 1): the predicate runs inside a
statement executed as the matview owner, so a caller holding only `MAINTAIN`
could otherwise read the owner's data through it. Whether removing the deparse
changes that is a **separate question** and must not be settled as a side effect
— see 2.4. The disposition on Test 1 says it inverts rather than lapsing, and
must be rewritten rather than regenerated.

**The open design question that gates this choice:** A3's fix depends on the
upsert and the prune being *one statement over one materialised `new_data`* —
proven necessary in `safety/a3-split-gap.sh`, where splitting them leaves a
stale row that neither statement corrects. Any option that separates view
evaluation from DML has to preserve that guarantee by some other means. That
question should be answered before choosing, not during.

### The question is answered, and (b) has already been built

Separating them preserves A3 **if and only if** the DML runs under the snapshot
the evaluation used, and 2.1 establishes that by measurement rather than by
argument — `matview-where-prune-gap.spec` fails with the snapshot split and
passes with it shared. So the guarantee is not "one statement"; it is "one
snapshot, and one physical set of source rows". A tuplestore read twice
delivers both, and delivers the second more strongly than a `MATERIALIZED` CTE
did, because the materialisation is real rather than a planner hint.

2.1 therefore shipped (b) as its landing point: the source rows are registered
as an ephemeral named relation and the existing fused upsert-and-prune SQL reads
that instead of its CTE. What is still generated text is short and fixed —
relation and column identifiers, and the predicate.

**The decision is to go on to (a) anyway: no generated SQL at all.** (b) is the
waypoint, not the destination. That means the `INSERT ... ON CONFLICT` and the
`DELETE` become `Query` trees, with arbiter-index inference done by hand, and
2.3 below stops deparsing the predicate as well. The cost is exactly the review
risk named above — nothing in core outside `analyze.c` builds an upsert — and
the differential harness is what makes it checkable: every step is compared
against the text path over all 22 shapes before it lands.

## 2.4 What this phase does not change

It does not settle the two-implementation question (whether `CONCURRENTLY`
should select a different *algorithm*), and it should not try to. That is a
semantics decision; this phase is a mechanism change. Doing both at once makes
the differential oracle useless, because divergence could mean either.

---

# Phase 3 — Performance

Only after Phase 2, because most of what follows is measured against code that
will have changed.

## What is already known

Two apportionments, and they answer different questions.

**Where a refresh's time goes, warm cache versus cold** (`-O2`, in-backend, 300
scope-1 refreshes of `projection`, `pg_stat_statements.track = all`):

| | warm cache | cold cache |
|---|---|---|
| whole refresh | 72 µs | 546 µs |
| the fused upsert/prune statement | 26.0 µs | 26.0 µs |
| the locking `SELECT` | 6.5 µs | 6.5 µs |
| `pg_get_viewdef` (`pg_rewrite` lookup) | — | 6.6 µs |
| everything else | ~39 µs | ~507 µs |

"Everything else" is the C path: predicate parse analysis, the deparse, the
arbiter-index scan, the cache probe, `SPI_connect`, and on the Query-tree path
building and planning the source query. **SQL execution is half of a warm
refresh and 6% of a cold one** — the target is the C path either way, and which
one to attack depends entirely on 3.6.

The Query-tree path is **28% faster in-backend** on the same measurement (244 µs
against 342 µs, cold), against ~10% through pgbench, because a commit and a
round trip per refresh dilute it.

An older decomposition of the SQL alone, kept because the property argument
below refers to it — a scope-1 refresh's **41.5 µs** of statement time:

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

**3.1 B16 — the commit-per-refresh cliff. ANSWERED, and the hypothesis was
wrong.** The proposed mechanism was that a refresh's own write invalidates the
plan cache and the next refresh re-plans, so a drain committing per refresh
pays for planning every time. Measured directly: 300 committed refreshes with a
constant predicate call `pg_get_viewdef` **once**, not 300 times, so the plans
survive commits and nothing re-plans. The 12× is the cost of committing — WAL,
`XLogFlush`, the transaction itself — and it is not something this patch can
optimise away. Close it and stop treating it as a lead.

    -- the whole measurement, on a warm cache
    printf 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE id = 1;\n%.0s' {1..300} > loop.sql
    psql -f loop.sql
    SELECT calls FROM pg_stat_statements WHERE query LIKE '%pg_rewrite%';   -- 1

**3.2 Parameterise predicate `Const`s. The largest single number here, and the
one the benchmark has been measuring without saying so.** The cache is keyed on
the deparsed predicate text, so a literal that varies per call misses it every
time. Re-measured on `-O2` after 2.1, in-backend, 300 scope-1 refreshes of
`projection`:

| predicate | per refresh | |
|---|---|---|
| varying literal — `WHERE id = 1`, `= 2`, … | 546 µs | misses every time |
| constant literal — `WHERE id = 1` | 72 µs | hits |
| bound parameter, varying value — `WHERE id = $1` | 67 µs | hits |

**8×, not the 4.2× recorded before.** Two consequences, and the second is the
awkward one:

- A caller who binds a parameter already gets the fast path, because
  `pg_get_expr` renders a `Param` as `$1` and the key is stable. A caller who
  builds the predicate as text does not. Both are ordinary things to write.
- **`bench/run.sh` interpolates `:k` client-side**, so every measurement in
  every run recorded so far is on the miss path. The suite has been measuring
  the 546 µs case exclusively and reporting it as the cost of a partial
  refresh. Fix the benchmark before optimising against it — see 3.6.

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

### Tier 1 and 2 sized, and one of them inverts a conclusion

Measured with temporary `INSTR_TIME` timers around every phase of
`refresh_by_direct_modification()` plus the transform and deparse above it
(`-O2`, 300 scope-1 refreshes of `projection`, in-backend, instrumentation
reverted afterwards).  `perf` is not installable on this kernel -- no matching
`linux-tools` -- and was not needed: the unattributed residual is 1.4 µs of the
spi path and 4.3 µs of the Query-tree path.

Per refresh, µs:

| phase | spi warm | spi cold | querytree warm | querytree cold |
|---|---|---|---|---|
| transform (parse-analyse the predicate) | 1.02 | 2.50 | 1.08 | 2.38 |
| **deparse (`nodeToString` + `pg_get_expr`)** | **4.53** | 10.14 | **5.25** | 9.47 |
| arbiter index scan | 0.08 | 0.02 | 0.00 | 0.02 |
| cache sweep | 0.00 | 0.00 | 0.00 | 0.00 |
| `SPI_prepare` of both statements | 5.95 | 112.85 | 0.79 | 58.29 |
| build the source Query | — | — | 1.22 | 2.12 |
| **rewrite + `pg_plan_query` the source** | — | — | **12.20** | 14.43 |
| execute the source | — | — | 2.65 | 3.63 |
| locking `SELECT` | 8.50 | 30.86 | 8.32 | 27.31 |
| fused upsert/prune | 28.16 | 154.42 | 25.83 | 109.15 |
| **whole refresh** | **49.7** | **314.8** | **61.6** | **233.4** |

**The Query-tree path is 24% SLOWER than the text path on a warm cache**, and
the whole deficit is one line: 12.20 µs re-planning a source query whose plan
never changes, against 11.9 µs of measured gap.  Confirmed over three
alternating pairs -- 60.1 µs spi against 78.4 µs querytree, steady state.

That inverts what the p21b-O2 charts say, and both are true of what they
measured.  The charts sweep a varying literal, which misses the plan cache on
every call, and on that path the Query-tree implementation wins because it
skips `pg_get_viewdef` and re-parsing the view text (233 against 315 µs).  On a
stable predicate or a bound parameter -- what a trigger or a drain actually
issues -- the text path wins, because it has one cached plan and the Query-tree
path re-plans half its work every time.

So 3.7 is not a nice-to-have.  It is the difference between the rewrite being a
win in the common case and being a regression there.

Verdicts:

| | verdict | why |
|---|---|---|
| 3.2 parameterise `Const`s | **pursue, largest** | 6.3× on the spi path, 3.8× on the Query-tree path; turns every cold refresh warm |
| 3.7 cache the source plan | **pursue, required** | 12.20 µs, 22% of a warm Query-tree refresh, and the entire reason it currently loses |
| 3.8 stop deparsing for the key | **pursue** | 4.5-5.3 µs, 9% warm.  Second-order but real, and 2.3 removes the other reason it exists anyway |
| 3.9 arbiter index scan | **drop** | 0.00-0.08 µs.  0.2% at the very most |
| 3.10 cache sweep | **drop** | 0.00 µs.  Below the resolution of the timer, at one cache entry |

Two things the sizing killed that were not on the list.  SPI execution overhead
is ~2 µs per statement, not the ~20 µs an earlier noisy run suggested --
`dmlexec` at 28.16 µs against the statement's own 26.0 µs from
`pg_stat_statements` -- so bypassing SPI buys nothing by itself, and Phase 2.2
has to be argued on the grounds it was always argued on.  And executing the
source query costs 2.65 µs against 12.20 µs to plan it: planning the read side
is 4.6× its execution at this scope.

**3.6 The benchmark measures one predicate mode and does not say which.** See
3.2. `run.sh` needs a `--predmode literal|param` axis and `bench_result` a
column to record it, because the two differ by 8× and are both real. Nothing
else in this list can be evaluated until this is fixed: a candidate that only
helps the miss path will look like a triumph, and one that only helps the hit
path will look like noise.

**3.7 The source query is re-planned on every refresh (Query-tree path only).**
`matview_materialize_source()` runs `AcquireRewriteLocks` → `QueryRewrite` →
`pg_plan_query` per call, while the DML side beside it is plan-cached. This did
not exist before 2.1 and is the obvious asymmetry it left behind. Cache the
`PlannedStmt` in the same entry as the other two plans, under the same
invalidation.

**3.8 The predicate is deparsed on every refresh, for the cache key alone.**
`deparseRefreshWhereClause()` runs `nodeToString()` + `pg_get_expr()` on every
call including a hit, and the only consumer on the Query-tree path is
`strcmp()` against the stored key. Compare the trees with `equal()`, or hash
the `nodeToString()` and compare hashes, or key on the jumble. 2.3 removes the
other reason the deparse exists, so these land together.

**3.9 The arbiter index is re-derived on every refresh.** `RelationGetIndexList()`
plus an `index_open()` per index, before the cache is even probed — and the
result is then used as part of the cache key, so it cannot simply move inside
the miss branch without a cheaper validity check.

**3.10 `matview_cache_sweep()` walks the whole cache on every refresh.**
`hash_seq_search()` over every entry to find the invalid ones, per call. Cheap
at one entry and O(sessions' matviews) at scale. A counter of pending
invalidations turns it into a branch.

**3.11 The ENR claims the whole matview's row count.**
`enr->md.enrtuples = matviewRel->rd_rel->reltuples` tells the planner that
`new_data` holds every row of the matview when it holds only the scope — for a
scope-1 refresh of a 100,000-row matview that is a hundred-thousand-fold
overestimate, feeding the join and upsert plan choice. The true count is known
after `matview_materialize_source()` returns, and the statement is prepared
before that, so this is not a one-line fix — but it is a plan-quality defect
and not merely a constant factor.

**3.12 Fold the locking `SELECT` into the fused statement.** Two SPI executions
per refresh; the lock is 6.5 µs of the 33 µs the SQL costs on a warm cache.
Constrained hard by A3/P1/P2 — the lock has to be taken before the source rows
are read, in arbiter-key order. Listed for completeness, not recommended: the
risk is to the guarantees and the prize is small.

## Phase 4 candidates, found after the first list was exhausted

**4.1 The fused statement is re-planned on every call when the predicate is
parameterised.** SPI plans go through the plan cache's custom-versus-generic
choice, and for this statement `auto` keeps picking custom -- so a bound
parameter, the pattern a trigger or a drain actually issues, pays a full
planning round every refresh.  Invisible to the phase profile above because it
happens inside `SPI_execute_plan`, counted under `dmlexec`.  Measured, 300
scope-1 refreshes with `WHERE id = $1`:

| `plan_cache_mode` | per refresh |
|---|---|
| `auto` (default) | 138.7 µs |
| `force_custom_plan` | 162.1 µs |
| **`force_generic_plan`** | **51.4 µs** |

**2.7×, and larger than everything in the previous list put together.**  It is
also faster than the constant-literal case, which still re-parses.
`SPI_prepare_cursor(src, nargs, argtypes, CURSOR_OPT_GENERIC_PLAN)` is a
one-line change from the `SPI_prepare()` calls today.

Do not adopt it on this measurement alone.  A generic plan is the wrong answer
where a custom one is genuinely better -- a skewed predicate column, an
`= ANY(array)` whose selectivity varies with the array -- and `auto` exists
because of those cases.  Measure across all eight workloads and all three
predicate shapes first, and expect the answer to be "generic, except when",
not "generic".

**4.2 Suppress the write when the row has not changed.**  The upsert writes a
new row version for every row in scope whether or not anything about it
differs.  Adding `WHERE mv IS DISTINCT FROM EXCLUDED` to the `DO UPDATE`
measured, against a target with indexes on the updated columns and a source
identical to it:

| scope | plain | conditional | |
|---|---|---|---|
| 1 | 35 µs | 37 µs | 2 µs worse |
| 100 | 473 µs | 344 µs | 27% better |
| 1,000 | 9,084 µs | 4,310 µs | 53% better |
| 10,000 | 92,748 µs | 52,720 µs | 43% better |

With no index on the updated columns the effect vanishes -- those updates are
HOT and cost little -- so this is worth what the matview's own indexes make it
worth.  The benefit also scales with the *unchanged fraction* of the scope, and
the benchmark refreshes without mutating anything, so a sweep would show the
maximum and call it typical.  Measure it with `--mutate on`.

**4.3 Everything sized so far is scope 1, and the winners differ at scale.**
The phase profile, the plan-cache finding, the whole Tier 1/2 exercise: all at
one row, where fixed costs are everything.  4.2 is *negative* at scope 1 and
worth half the statement at 10,000.  Re-run the phase profile at scope 100 and
10,000 before picking anything else -- there is no reason to expect the same
list.

**4.4 The scope is scanned twice.**  The locking `SELECT` reads every row the
predicate selects, and the prune's anti-join reads them all again.  At scope
10,000 that is two index scans plus a hash anti-join over one set of rows.
Whether the second can reuse the first is a real question; P2 constrains the
first, not the second.

**4.5 `FOR NO KEY UPDATE` for rows that will only be updated.**  The pre-lock
takes `FOR UPDATE` over the whole scope because some of those rows will be
deleted.  Rows that will only be upserted need the weaker mode, which does not
conflict with foreign-key checks.  A concurrency optimisation, not a latency
one -- measure it with `--clients 4,16 --overlap hot`, where the current sweep
has nothing to say.

**4.6 Skip the prune when it provably cannot delete anything.**  On the
Query-tree path the source row count is known once the tuplestore is filled.
If it matches the number of matview rows in scope and the upsert inserted none,
nothing can be missing.  The derivation is the hard part and it has to be right
every time, not usually.

**4.7 Reuse the tuplestore and the ENR tuple descriptor across refreshes.**
`CreateTupleDescCopy()` and a `tuplestore_begin_heap()`/`_end()` pair per
refresh, inside the 4.3 µs the Query-tree path does not otherwise account for.
Small, and cheap to do while touching that code for 3.7.

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
- The property gates get re-derived against the final implementation. All three
  exist as of Phase 1: P2's spec and P3's spec both re-verified against the new
  code, and P1's gates re-run — noting that P1 has no `Assert()` and is not
  going to get one, because there is nothing at build time to inspect (1.2). Its
  gate is `fuzz.sh`'s `serial` mode, which is why the fuzzer outlives the
  implementation work by one phase.
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
  | Test 16 · ctid order, "keep until the property-level version exists" | `matview-where-insertorder.spec` landed in Phase 1 | **fired** — delete here |
  | `pg_stat_statements` structural block, "delete at the start of Phase 2" | Phase 2 opening | **fired** — deleted before the first line of the rewrite, not after |
  | `matview-where-snapshot`, "delete when the premise goes" | the rewrite fusing the lock into one plan | **read at Phase 2 exit** |
  | `matview_where_privs` Test 1, "rewrite if the predicate runs as the invoker" | Phase 2's privilege model | **read at Phase 2 exit** — it inverts rather than lapsing, so it must be rewritten, not regenerated |
  | `matview_partial_refresh_querytree` GUC + the text path it selects | the fuzzer's exit criterion, not "the new path looks finished" | **fires here** — delete the GUC (`guc_parameters.dat`, the `commands/matview.h` declaration, the `guc_tables.c` include), the text branch, and the two `SET` lines in `matview-where-prune-gap.spec`. Losing it also loses `rundiff.sh`'s old-vs-new mode, which is why it is the last thing to go |
  | `matview-where-prune-gap.spec`, "delete if the seam closes" | an implementation with no separate evaluation step | **read at Phase 2 exit** — the *property* is data loss and is not scaffolding; the injection point and the GUC are. If the seam closes, delete it and say why |

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
