# Which predicates are safe, and how do we know?

Branch-local. Not part of the patch; delete this directory before posting to
-hackers. The harness that produced every number here is in `safety/`; run it
with `safety/run.sh [port] [db]` against a cluster with the patch installed.

---

## What "safe" has to mean

The obvious contract — *"after `REFRESH ... WHERE p`, the rows matching `p` are
correct and the rows not matching `p` are untouched"* — is nearly vacuous. It
is satisfied by every failure in this document, including the one that puts two
players at rank 1. The refresh always does exactly what it was asked.

The property users actually want is **convergence**:

> a partial refresh leaves the matview in the state a full refresh would produce.

Everything below is measured against that. Formally, writing `V` for the view
query, `D` for the base data before the change and `D'` after:

    partial refresh with predicate P converges  iff  σ¬ₚ(V(D')) = σ¬ₚ(V(D))

— the complement of the predicate must be *unchanged* by whatever the base
tables did. That is the whole condition, and every failure mode below is a
different way of violating it.

---

## The oracle

For each (view, predicate, mutation) triple:

1. build the base data and create the matview — fully populated, so correct
2. apply the mutation
3. `REFRESH MATERIALIZED VIEW [CONCURRENTLY] mv WHERE <predicate>`
4. snapshot the matview
5. `REFRESH MATERIALIZED VIEW mv` — ground truth
6. symmetric difference of 4 and 5, with `EXCEPT ALL` in both directions

A non-empty difference is a **counterexample**: proof of unsafety for that
triple. An empty difference is evidence of safety, not proof — it says nothing
about the mutations you did not try. That distinction turned out to matter more
than anything else here.

Run at two resolutions:

| harness | shapes | runs | what it is for |
|---|---|---|---|
| single-shot | 42 | 84 | wide coverage, plus the planner-signal measurement |
| exhaustive | 18 | 2792 | the *complete* single-row mutation space per shape |

The exhaustive space, for a 12-row base table, is: every row set to each of
4–5 values in the domain, every row deleted, every row moved to every group,
and a fresh row inserted into every group. Both refresh forms (bare and
`CONCURRENTLY`) were run for every case; **they agreed on all 36 shape-runs**,
so nothing below is an artifact of one implementation path.

### What it found before it answered anything

The harness crashed the server twice on its first full run, both times on the
same call, and only on the `CONCURRENTLY` form:

    LOG:  client backend (PID 13304) was terminated by signal 11: Segmentation fault
    DETAIL:  Failed process was running: SELECT run_exh('proj_nonkey_union','concurrently')

That turned out to be a use-after-free in the partial-refresh plan cache:
`InvalidateMatViewCache()` freed plans and removed hash entries from inside a
relcache callback, while `refresh_by_direct_modification()` held a pointer to
one of those entries across the entire maintenance window — and the refresh
itself generates the invalidations, by locking and writing the matview. Written
up as B14 in `ISSUES.md`; fixed by having the callback mark rather than free.

Worth stating plainly: the crash has not reproduced since, so it is evidence
that something was wrong, not evidence that this was it. What justifies the fix
is reading the code. What the harness did was make anyone look.

### Hand-picked mutations are not good enough

Three cases were classified **SAFE by a hand-picked mutation and UNSAFE by the
exhaustive space**:

| shape | single mutation | exhaustive |
|---|---|---|
| `WHERE g = k AND score > 400` over a `rank() OVER (PARTITION BY g)` | SAFE | **20/60 diverge** |
| the same, with the mutation lowering the score instead of raising it | SAFE | (same 20/60) |
| `WHERE total > 200` over `GROUP BY g` | SAFE | **22/48 diverge** |

The first two got lucky twice in a row for the same reason: raising row 55's
score to the top only disturbs rows that ranked above it, and those all
happened to satisfy `score > 400` too. Lowering it to 501 kept it inside the
band. Only a mutation that crosses the 400 boundary exposes it — and the
exhaustive space contains one.

At the other end, `DISTINCT ON` diverged on **1 mutation out of 96**. No amount
of hand-picking finds that.

---

## Five independent ways to be unsafe

Convergence fails for five structurally different reasons. They compose: a
predicate has to clear all five.

### 1. Blast radius — the output changes where the input didn't

An output row's value depends on *other* rows, so refreshing only the rows
whose inputs changed leaves the rest stale.

```
rank() OVER (PARTITION BY g ORDER BY score DESC), refreshed WHERE id = $1
  -> 25 of 60 mutations diverge
```

**This is exactly what the planner already refuses to push a qual through.**
From `check_output_expressions()` in `src/backend/optimizer/path/allpaths.c`:

> If the subquery has any window functions, we must not push down quals that
> reference any output columns that are not listed in all the subquery's window
> `PARTITION BY` clauses. We can push down quals that use only partitioning
> columns because they should succeed or fail identically for every row of any
> one window partition, and **totally excluding some partitions will not change
> a window function's results for remaining partitions**.

That last clause is the convergence condition, stated by the planner about
itself. The reasoning transfers because it is the same structural fact: if
removing rows outside `P` cannot change results inside `P`, then changing rows
inside `P` cannot change results outside `P`.

So the check is: **does every conjunct of the predicate reach a base relation,
or does one survive as a `Filter` on an `Aggregate` / `WindowAgg` / `Limit` /
`Unique` / `SetOp` / `CTE Scan` node?** A surviving conjunct is the planner
telling you the scope is wrong.

### 2. Global dependency — an uncorrelated sub-select

```sql
SELECT g, sum(amt) AS total,
       sum(amt) / (SELECT sum(amt) FROM b) AS share    -- <- every row depends on every row
  FROM b GROUP BY g;
```

**35 of 36 mutations diverge.** And the predicate `g = $1` pushes down
perfectly — push-down analysis cannot see this, because the sub-select becomes
an `InitPlan` evaluated off to the side, nowhere near the qual's path. Any
percentage-of-total, share-of-max, or rank-against-the-whole-table column has
this shape.

Detectable separately, and cheaply: an uncorrelated `InitPlan` in the view's
plan means no predicate is safe.

### 3. Non-determinism — the view is not a function of the base data

```sql
SELECT DISTINCT ON (k) k, ts, v FROM b ORDER BY k, ts DESC;   -- (k, ts) is not unique
```

With a tie on `ts`, the answer depends on the plan:

```
rows in k = 2 after the update       partial refresh    full refresh
 id | k | ts | v                      k | ts | v        k | ts | v
  6 | 2 |  6 | 18                     2 |  6 | 18       2 |  6 | 30
 10 | 2 |  6 | 30
  2 | 2 |  2 |  6

  Limit                               Unique
    -> Sort (ts DESC)                   -> Sort (k, ts DESC)
         -> Seq Scan, Filter k=2             -> Seq Scan
```

Two different plans, two different legal answers. This is not a partial-refresh
bug — *two full refreshes* may also disagree — but partial refresh reaches it
far more often because it plans a different query. Adding `, id` to the
`ORDER BY` makes it a total order and the counterexample disappears: **0/96**.

Same shape applies to `LIMIT` without a total order and to ordered aggregates
over tied inputs.

### 4. Scope drift — the row leaves the predicate's selection

A row whose predicate column *changes* is the asymmetric case, and the
asymmetry is not the one you would guess:

| the driver's predicate names | result | measured |
|---|---|---|
| the **old** value only | the row is **deleted** from the matview | 48/60 diverge |
| the **new** value only | correct | **0/60** |
| **old `OR` new** | correct | **0/96** |
| the **arbiter key** (cannot drift) | correct | **0/108** |

Naming the new value works because the upsert arbitrates on the unique key: it
finds the matview's stale row by key regardless of what its predicate column
says, and overwrites it. Naming the old value selects that stale row on the
matview side, finds no match on the view side, and prunes it.

Two consequences worth stating plainly:

- **A predicate on the arbiter-index columns cannot drift**, because the key is
  what identifies the row. Proven over the full mutation space including
  inserts, deletes and key-column moves: 0/108.
- A driver written as an `AFTER UPDATE ... FOR EACH ROW` trigger firing on
  `NEW` is accidentally correct for updates and wrong for deletes. One using
  `OLD` is wrong for updates. The union of both transition tables is right —
  which is the same advice as `USE-CASES.md` gives for the join case, arrived
  at independently.

### 5. Coverage — the driver named the wrong rows

Not a property of the predicate at all, and not checkable at `REFRESH` time.

```sql
-- matview: SELECT f.id, f.v, d.nm FROM f JOIN d ON d.id = f.did
UPDATE d SET nm = 'RENAMED' WHERE id = 5;
REFRESH MATERIALIZED VIEW mv WHERE id = 5;      -- wrong: id is f.id, not d.id
                                                --   30 rows left stale
REFRESH MATERIALIZED VIEW mv
  WHERE id IN (SELECT id FROM f WHERE did = 5); -- correct: 0 rows stale
```

Same for a correlated sub-select in the target list: changing a *child* row
changes the *parent's* output row, so the scope is the parent key, not the
child's.

> The correct predicate here is blocked today. `RestrictSearchPath()` means the
> sub-select cannot see `f` unless it is schema-qualified — `ERROR: relation
> "f" does not exist`. That is item B9 in `ISSUES.md`, and this is the case
> that makes it matter: expressing a correct scope for a dimension change
> *requires* a sub-query over a base table.

---

## Planner signal against measured outcome

Over the 42 single-shot shapes, classifying each predicate by what the planner
did with it:

| planner signal | SAFE | UNSAFE |
|---|---|---|
| fully pushed to base quals | 22 | 4 |
| a conjunct survives as a residual `Filter` | 5 | 10 |
| uncorrelated `InitPlan` in the view | 0 | 1 |

The off-diagonal cells are the whole story:

**Pushed but unsafe (4).** Two are coverage failures (§5) — the driver named
rows that were not the ones that changed; both become SAFE with the correct
predicate. Two are drift-out (§4). None is a blast-radius failure. So
push-down did not miss a single case of the thing it is being used to detect.

**Residual but safe (5).** Three are measurement artifacts rather than real
disagreements:

- `having` — the residual `Filter` is the *view's own* `HAVING sum(amt) > 100`,
  not the refresh predicate. Reading the plan cannot tell them apart; real code
  can, because it knows which qual it added. Exhaustively 0/60.
- `agg_output` and `win_part_and` were only "safe" under a single hand-picked
  mutation. Exhaustively they are 22/48 and 20/60. **The planner was right and
  the single mutation was wrong.**

That leaves one true conservative refusal: `except_key` — a predicate on the
key of `a EXCEPT b`, exhaustively safe at 0/64, which the planner declines to
push for bag-semantics reasons unrelated to blast radius. You pay a scan; you
do not get a wrong answer.

---

## So: can it be proved?

Three different questions, three different answers.

### "Is this predicate safe for this view, for all base data and all changes?"

**Undecidable in general.** It reduces to query equivalence: recursion and
opaque user-defined functions put it out of reach, which is why the recursive
closure case can only be tested, never certified.

**Decidable for the conjunctive fragment.** Query-update independence for
conjunctive queries is decidable (Levy & Sagiv, *Queries Independent of
Updates*, VLDB 1993), and by the Chandra–Merlin homomorphism theorem testing on
a canonical database whose size is the number of query atoms is *complete*, not
a sample. For select-project-join views over a small canonical instance, the
exhaustive harness in `safety/` is therefore a decision procedure, not a
heuristic. Conjunctive queries with `min`/`max`/`count`/`sum` are also decidable
(Nutt, Sagiv & Shurin). Windows, recursion and `LIMIT` are not covered by any of
this — for those the harness is exactly what it looks like, bounded testing
under the small-scope hypothesis.

### "Is there a sound check cheap enough to run on every refresh?"

Close to it, and mostly out of parts that already exist. Four conditions:

1. **No residual conjunct** — every conjunct of the predicate reaches a base
   relation. This is `subquery_is_pushdown_safe()` + `check_output_expressions()`
   applied to the refresh predicate instead of a user qual, and it decides the
   blast-radius question. Sound and incomplete: it refuses `EXCEPT` and it
   cannot distinguish the view's own `HAVING` from the predicate unless the
   caller tags its qual, which the caller can.
2. **No uncorrelated sub-select** in the view — otherwise every row depends on
   every row. `contain_subplans()` over the target list, or an `InitPlan` check
   on the plan.
3. **Deterministic view** — `DISTINCT ON` / `LIMIT` / ordered aggregates need a
   total order. Reduces to a functional-dependency question, which
   `check_functional_grouping()` already answers for the unique-index case.
4. **Predicate on the arbiter-index columns**, or the caller accepts that a row
   leaving the scope is deleted. Trivially checkable — compare the predicate's
   `Var`s against `indnkeyatts` of the index the refresh picked.

Conditions 1–4 held on every safe case here and rejected every unsafe one that
is not a coverage failure. That is not a soundness proof; it is 42 shapes and
2792 mutations without a counterexample. Coverage (§5) is outside what any
`REFRESH`-time check can see, because the command is not told what changed.

### Is that check cheap enough for a row-level trigger?

Only if it never invokes the planner. Measured on a 100k-row matview, scope-1
refresh, minimum of 5 runs of 300 single-row `UPDATE`s:

| | µs/row |
|---|---|
| plain `UPDATE`, no refresh at all | 69.8 |
| row trigger, **parameterised** predicate (plan cache hits) | 427.9 |
| row trigger, **literal** predicate (plan cache misses every call) | 1372.5 |
| statement trigger, batch of 100, array predicate | 89.8 |
| **one extra planner pass** | **141.4** |

The refresh itself, on a cache hit, is 427.9 − 69.8 = **358 µs**. The plan cache
is saving 1372.5 − 427.9 = **945 µs** of parse and plan per call.

So an extra planner pass is **141 µs against a 358 µs refresh — +39%, on every
call**, and no cache can absorb it, because the planning *is* the check. That
rules out the shape this document's own harness uses: `EXPLAIN` the query and
walk the plan for residual quals. Correct for a test oracle, wrong for the
server.

Done the other way it is free, and the parts are already in hand:

- **Conditions 1–3 are functions of (view definition, predicate text, argument
  types)** — which is exactly the partial-refresh cache key. Compute them where
  the plans are built, store the verdict in the same entry, and a cache hit
  reads a `bool`. The relcache callback already drops entries when the view
  definition changes, so the verdict cannot outlive its premises.
- **No parsing is needed to get the view's `Query`.** `ExecRefreshMatView()`
  already has it as `dataQuery` (`matview.c:603`), taken straight from
  `matviewRel->rd_rules` in the relcache — the same place `get_view_query()`
  reads. Conditions 1–3 are a walk over that target list plus a look at
  `limitCount`/`groupingSets`/`windowClause`/`distinctClause`: proportional to
  the size of the view definition, not to the data, with no catalog access.
- **Condition 4 is cheap even uncached** — `pull_varattnos()` over the qual the
  code already transformed, tested against the arbiter index's `indkey`. Worth
  running unconditionally.

On a cache miss the check is recomputed, but a miss is already spending 945 µs
on parse and plan; a target-list walk does not register against that.

One caveat worth keeping straight: condition 3 (determinism) is the only one
needing functional-dependency reasoning, which does hit the catalog for unique
indexes. It is also the only one that is a pure function of the view definition
with no dependence on the predicate — so it wants caching **per matview**, not
per (matview, predicate).

And the number that frames all of this: a row-level trigger already costs
**6.1×** the write it is attached to (427.9 vs 69.8), while statement-level
batching costs **89.8 µs/row — 4.8× less than the row trigger**. Whatever the
check costs, it is not what makes row-level triggers expensive.

### "Will *this* refresh, right now, converge?"

**Yes — exactly, completely, and expensively.** Do the full refresh and diff,
which is what the oracle does. That is the answer to "even if it costs a ton":

- cost is one full rebuild per partial refresh, so ~11× the partial refresh's
  own cost at the break-even scope and unboundedly more below it
- it is sound *and* complete for the transition that just happened
- it needs no static analysis and no new theory

There is precedent in the tree for exactly this trade — `wal_consistency_checking`,
`debug_discard_caches`, `ignore_system_indexes` are all "recompute the expensive
way and compare, for development". A `matview_verify_partial_refresh` GUC
following that pattern would be a contained change to `ExecRefreshMatView()`:
build the full result into a transient relation, symmetric-difference it against
the post-refresh matview, and `ERROR` (or `WARNING`) on any difference.

That is what makes the feature testable by the people who will deploy it. The
static checks tell you a predicate is wrong before it corrupts anything; the
verification GUC tells you your *driver* is wrong, which is the failure mode the
static checks provably cannot reach.
