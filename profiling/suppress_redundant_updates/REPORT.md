# Profiling `suppress_redundant_updates_trigger`

CPU profile of `suppress_redundant_updates_trigger()` across several UPDATE
workloads, with flamegraphs, to find optimization opportunities.

**Headline:** the comparison the trigger exists to perform is essentially free —
**1–3% of the trigger's own cost**. Almost everything else is the generic
BEFORE-ROW-trigger machinery wrapped around it, and **63–76% of the cost is a
single thing**: the mandatory `heap_lock_tuple()` on the old tuple, taken
*before* we can possibly know the update will be suppressed.

So there is essentially nothing to win inside `trigfuncs.c`. The wins are in
the machinery, and the biggest one is structural — see §6, which implements
it as a table storage parameter and removes the lock, the WAL and the XID
entirely.

---

## 1. Method

* Source: this tree (`20devel`), built `-O2 -g -fno-omit-frame-pointer`, asserts
  off, not stripped — so frame-pointer stacks are complete and symbolized.
* `perf record -F 999 --call-graph fp` attached to the single pgbench backend
  for 30 s of each 40 s run; flamegraphs via Brendan Gregg's FlameGraph.
* Server: `shared_buffers=1GB`, `fsync=off`, `synchronous_commit=off`,
  `full_page_writes=off`, `autovacuum=off`. Every table fits in shared buffers,
  so all workloads are CPU-bound and in-memory. That is deliberate: it puts the
  trigger's CPU cost under a microscope instead of hiding it behind I/O.
* 4 vCPU container, single client (`-c 1`), so the profile maps to one backend.

### Tables

| table | shape | size | notes |
|---|---|---|---|
| `t_narrow_*` | 4 cols | 5 MB / 100k rows (~52 B/row) | updates are HOT-eligible |
| `t_wide_*` | 62 cols | 87 MB / 100k rows (~870 B/row) | no TOAST; stresses memcmp and `heap_form_tuple` |
| `t_idx_*` | 5 cols + 3 secondary indexes | 100k rows | real updates must maintain indexes |

Each shape exists twice — `_trig` (trigger attached) and `_notrig` — so every
number is a paired comparison.

### Workloads

* **redundant** — `SET a = a, b = b`: NEW is byte-identical to OLD, so the
  trigger suppresses every row. Best case.
* **changing** — `SET a = a + 1, b = b + 1`: nothing can be suppressed, so the
  trigger is pure overhead. Worst case.

Both the simple query protocol and `-M prepared` were measured. Under the simple
protocol ~20–25% of backend CPU is parse+plan, which dilutes the executor
signal; the `_prep` numbers are the ones to reason about.

### Reading the percentages

Raw "% of all samples" understates everything: with one client the backend
spends ~20% of its samples in the scheduler/socket path
(`finish_task_switch`, `_raw_spin_unlock_irqrestore`) waiting on pgbench.
Percentages below are **normalized to in-query backend CPU** (the
`exec_simple_query` / `exec_execute_message` subtree).

---

## 2. Where the time goes

### Cost attribution, % of in-query backend CPU

| workload | ExecModifyTable | ExecBRUpdateTriggers | GetTupleForTrigger | heap_lock_tuple | trigger fn | ExecGetAllUpdatedCols | heap_update |
|---|---|---|---|---|---|---|---|
| narrow_notrig_redundant | 32.75 | – | – | – | – | – | 3.94 |
| narrow_trig_redundant | 22.79 | 6.54 | 5.20 | 4.51 | **0.07** | 0.39 | 0.00 |
| narrow_notrig_changing | 31.42 | – | – | – | – | – | 3.93 |
| narrow_trig_changing | 33.05 | 4.15 | 2.75 | 2.44 | **0.12** | 0.37 | 1.99 |
| wide_notrig_redundant | 29.65 | – | – | – | – | – | 4.42 |
| wide_trig_redundant | 25.04 | 6.26 | 5.10 | 4.50 | **0.09** | 0.33 | 0.00 |
| wide_notrig_changing | 29.55 | – | – | – | – | – | 4.87 |
| wide_trig_changing | 30.53 | 3.89 | 2.69 | 2.33 | **0.07** | 0.34 | 3.12 |

### Breakdown *within* `ExecBRUpdateTriggers` (= 100%)

| workload | GetTupleForTrigger | ↳ heap_lock_tuple | ExecGetAllUpdatedCols | ExecFetchSlotHeapTuple | **trigger fn** |
|---|---|---|---|---|---|
| narrow_trig_redundant | 80.97 | 70.33 | 6.15 | 2.25 | **1.06** |
| wide_trig_redundant | 82.18 | 72.64 | 5.40 | 2.41 | **1.38** |
| narrow_trig_redundant_prep | 83.82 | 75.83 | 5.56 | 1.95 | **1.27** |
| wide_trig_redundant_prep | 78.45 | 70.62 | 6.46 | 3.82 | **1.37** |
| idx_trig_redundant_prep | 79.73 | 72.28 | 5.86 | 2.69 | **1.83** |
| narrow_trig_changing_prep | 71.91 | 63.36 | 7.79 | 3.05 | **1.37** |
| idx_trig_changing_prep | 72.57 | 65.93 | 7.33 | – | **2.90** |

The shape is the same in all eight workloads, narrow or wide, suppressing or
not, simple or prepared. Even on 870-byte tuples the `memcmp` never becomes
visible — it does not even reliably show up as a distinct frame under
`ExecCallTriggerFunc`.

### Why the lock is there

`ExecBRUpdateTriggers()` (`src/backend/commands/trigger.c:3034`) calls
`GetTupleForTrigger()`, which does a real `table_tuple_lock()` →
`heap_lock_tuple()` on the old tuple before any trigger runs
(`trigger.c:3400`). `heap_lock_tuple()` in turn does
`MarkBufferDirty()` and `XLogInsert(RM_HEAP_ID, XLOG_HEAP_LOCK)`
(`heapam.c:638`, `heapam.c:672`).

That lock is required by BEFORE-ROW-trigger semantics in general — the row must
not change between the trigger seeing OLD and `heap_update()` applying NEW. But
it is taken *unconditionally, before* the trigger can say "skip this update".
When the trigger suppresses, the entire lock was wasted work.

Its single most expensive child is XID assignment
(`GetCurrentTransactionId` → `AssignTransactionId` → `XactLockTableInsert` →
`LockAcquire`), because writing `xmax` forces the transaction to acquire a real
XID. Note this is *not* extra cost attributable to the trigger —
`AssignTransactionId` measures ~1.05% in the no-trigger runs too, since a real
`heap_update()` needs an XID anyway. What the trigger changes is that a
transaction which now performs **no table modification at all** still burns an
XID.

---

## 3. A suppressed update is not a free update

`EXPLAIN (ANALYZE, WAL, BUFFERS)` over a 10,000-row batch:

| case | WAL records | WAL bytes | buffers dirtied | exec time |
|---|---|---|---|---|
| narrow, no trigger, redundant | 30,140 | 2,252,165 | 815 | 51.7 ms |
| **narrow, trigger, redundant (all suppressed)** | **10,000** | **540,000** | **150** | **12.1 ms** |
| narrow, no trigger, changing | 30,511 | 2,219,322 | 65 | 58.0 ms |
| narrow, trigger, changing (nothing suppressed) | 40,128 | 2,791,225 | 649 | 60.2 ms |
| wide, no trigger, redundant | 28,191 | 9,403,189 | 10,057 | 81.4 ms |
| **wide, trigger, redundant (all suppressed)** | **10,000** | **540,000** | **2,417** | **31.1 ms** |

Read the suppressed rows carefully: **exactly 10,000 WAL records for 10,000
suppressed updates — 54 bytes each, one `XLOG_HEAP_LOCK` per row**, in both the
narrow and wide cases (the record size is independent of tuple width). Pages are
still dirtied.

So suppression cuts WAL by 76% (narrow) and 94% (wide) — but never to zero, and
the transaction is still a writing transaction: it consumes an XID, dirties
heap pages, and must write a commit record. `suppress_redundant_updates_trigger`
does not turn a no-op UPDATE into a read-only transaction. (Measured directly:
`txid_current_if_assigned()` is non-NULL after a fully suppressed batch.)

And when it *cannot* suppress, it adds 10,000 lock records — **+26% WAL
records and +3.8% execution time** on top of the plain UPDATE.

### With `full_page_writes = on` it is much worse

The numbers above were taken with `full_page_writes = off`. That is not the
production default, and it hides the real cost: because `heap_lock_tuple()`
dirties the page, the first touch of a page after a checkpoint emits a full
page image even for a row that is not being modified. Re-running the same
batches with `full_page_writes = on`:

| case | WAL records | FPIs | WAL bytes | exec time |
|---|---|---|---|---|
| narrow, no trigger, redundant | 29,987 | 699 | 7,822,192 | 59.5 ms |
| narrow, trigger, redundant (all suppressed) | 10,000 | **287** | **2,853,223** | 14.5 ms |
| wide, no trigger, redundant | 22,125 | 10,034 | 81,266,260 | 304.0 ms |
| wide, trigger, redundant (all suppressed) | 10,000 | **3,761** | **27,065,905** | 99.9 ms |

A batch of 10,000 updates that changed nothing at all still wrote **27 MB of
WAL**, almost all of it full page images. Still an improvement on the 81 MB the
plain UPDATE writes, but a long way from free.

---

## 4. Optimization opportunities

Ranked by value.

### 4.1 The tuple lock — 63–76% of the cost, structural

The only way to remove it is to not take it when the update will be suppressed,
which means deciding *before* locking. Two shapes:

* **Do the redundancy check in the executor, not in a trigger.** `ExecUpdate()`
  already holds both the old tuple and the new slot. A core fast path (a
  reloption, or a check in `ExecUpdatePrepareSlot`/`ExecUpdateAct`) could
  `memcmp` them and skip the update with *no* tuple lock, *no* XID, *no* WAL and
  *no* dirtied page — capturing the entire benefit and none of the trigger
  overhead. This is the highest-value change, and it is also the honest
  conclusion of this profile: **the feature is mis-sited as a BEFORE ROW
  trigger.**

  Caveat worth stating plainly: today a suppressed update still *locks* the row,
  so it still serializes against concurrent updaters. A lock-free fast path
  would change that concurrency semantic, and that is a design decision, not a
  free optimization.

* **Optimistic locking in `ExecBRUpdateTriggers`** — run the trigger against an
  unlocked read of OLD, and only lock + re-verify if the trigger returns
  non-NULL. This keeps the feature as a trigger but can re-run a BEFORE trigger
  twice, which is a user-visible semantic change for triggers with side effects.
  Riskier and probably not worth it.

### 4.2 `ExecGetAllUpdatedCols()` — 5.4–7.8% of the cost, genuinely easy

`ExecBRUpdateTriggers()` calls it once per row (`trigger.c:3094`), and it does a
`bms_union()` — a `palloc` plus copy — into the per-tuple context on **every
row** (`execUtils.c:1444`):

```c
ret = bms_union(ExecGetUpdatedCols(relinfo, estate),
                ExecGetExtraUpdatedCols(relinfo, estate));
```

Both inputs are constant for the whole statement: `ExecGetUpdatedCols()` returns
`perminfo->updatedCols`, and `ExecGetExtraUpdatedCols()` already caches into
`ri_extraUpdatedCols` behind a `ri_extraUpdatedCols_valid` flag. Only the union
is recomputed per row. `ExecARUpdateTriggers()` (`trigger.c:3234`) pays it a
second time per row when an AFTER trigger is also present.

Caching it in `ResultRelInfo` (an `ri_AllUpdatedCols` + validity flag,
mirroring the existing `ri_extraUpdatedCols` pattern, allocated in
`es_query_cxt`) removes a per-row allocation for a statement-constant value.
Small — ~0.35% of in-query CPU — but safe, local, and free. It would matter more
for partitioned tables, where `ExecGetUpdatedCols()` can additionally call
`execute_attr_map_cols()` and allocate again.

### 4.3 Not worth touching

* **The trigger function itself** (1–3% of trigger cost, ≤0.12% of backend CPU).
  Micro-optimizing the `memcmp` or the four `TRIGGER_FIRED_*` guard checks is
  pointless; even at 870-byte tuples the comparison is invisible in the profile.
* **`ExecFetchSlotHeapTuple`** materializing NEW (2–4% of trigger cost) — real,
  but small, and hard to avoid since the trigger API is `HeapTuple`-based.

---

## 5. When the trigger is actually worth it

Set-based UPDATEs benefit substantially — the 10k-row batches above ran **4.3×
faster** (narrow) and **2.6× faster** (wide) when everything was suppressed,
with 76–94% less WAL.

Single-row OLTP updates benefit far less, because per-statement costs
(parse/plan, round-trip, commit) dominate and the trigger's own overhead eats
much of the saving. Clean single-row throughput, median of 3 runs with a
`VACUUM FULL` before each so bloat cannot skew the comparison
(`results/tps_clean.txt`):

| workload | no trigger | trigger | delta |
|---|---|---|---|
| narrow, redundant | 8,938 | 9,996 | **+11.8%** |
| narrow, changing | 9,210 | 8,697 | −5.6% |
| wide, redundant | 9,095 | 9,802 | **+7.8%** |
| wide, changing | 9,069 | 8,881 | −2.1% |
| indexed, redundant | 8,939 | 9,978 | **+11.6%** |
| indexed, changing | 7,236 | 7,013 | −3.1% |

That bias is worth spelling out, because the profiled runs in
`results/profiled_tps.txt` do *not* control for it: `_notrig` tables accumulate
bloat within a phase because their updates actually apply, while suppressed
`_trig` tables stay pristine. In those runs the indexed-table comparison came
out at −10.9%, the opposite sign from the clean +11.6% above. Cost
*attribution* — the subject of this report — is not sensitive to it: the 63–76%
`heap_lock_tuple` share reproduces across all eight workloads.

It is also worth knowing that **PostgreSQL already avoids the index work on
redundant updates by itself**, which is why the indexed table does not benefit
more than the others. If the new values equal the old ones then no indexed
column has changed, so the update qualifies as HOT and skips index
maintenance. Measured on a table with indexes on the updated columns
(`results/hot_check.txt`):

| update | n_tup_upd | n_tup_hot_upd | HOT |
|---|---|---|---|
| redundant (indexed values unchanged) | 10,000 | 10,000 | **100%** |
| changing (indexed values change) | 10,000 | 0 | 0% |

This holds only when the page has room for the new row version. An earlier
version of this test ran `VACUUM FULL` first, which packs pages to 100%
fillfactor and leaves nowhere on-page for the new version; it reported 0% HOT
in *both* cases and was simply measuring the absence of free space. That
invalid run is kept as `results/hot_check_invalid.txt` as a caution.

---

## 6. Acting on §4.1: the `suppress_redundant_updates` reloption

§4.1 argued the feature is mis-sited as a BEFORE ROW trigger. That is now
implemented as a table storage parameter, in the commit
"Add suppress_redundant_updates storage parameter".

`ExecUpdateAct()` already holds the stored row — `oldSlot`, fetched anyway so
`ExecGetUpdateNewTuple()` can build the new row from the unchanged columns —
and the fully prepared new row. The same comparison the trigger performs
therefore costs a `memcmp` of two tuples already in hand, and it happens
*before* `table_tuple_update()`, so a skipped update takes no row lock.

```sql
ALTER TABLE t SET (suppress_redundant_updates = on);
```

### Result: the lock, the WAL and the XID all disappear

Same 10,000-row batches, same server, three variants side by side
(`results/patch_wal.txt`):

| case | WAL records | WAL bytes | buffers dirtied | exec time |
|---|---|---|---|---|
| narrow, stock | 29,905 | 2,213,678 | 684 | 45.5 ms |
| narrow, trigger | 10,000 | 540,000 | 202 | 12.5 ms |
| **narrow, reloption** | **0** | **0** | **1** | **5.2 ms** |
| wide, stock | 25,899 | 8,318,740 | 10,061 | 77.9 ms |
| wide, trigger | 10,000 | 540,000 | 1,110 | 27.4 ms |
| **wide, reloption** | **0** | **0** | **2** | **18.2 ms** |

A fully suppressed batch now writes **no WAL at all** and dirties nothing, so
the `full_page_writes` problem in §3 disappears with it. The transaction also
stays read-only — `txid_current_if_assigned()` returns NULL under the
reloption and non-NULL under the trigger, confirming no XID is burned.

### Throughput, single-row updates

Median of 3, `VACUUM FULL` before each rep, prepared protocol
(`results/patch_tps.txt`):

| workload | stock | trigger | reloption |
|---|---|---|---|
| narrow, redundant | 9,517 | 9,810 (+3.1%) | **10,829 (+13.8%)** |
| wide, redundant | 9,226 | 9,621 (+4.3%) | **10,021 (+8.6%)** |
| narrow, changing | 8,896 | 8,382 (−5.8%) | **8,739 (−1.8%)** |

The last row matters as much as the first two: when nothing can be suppressed,
the reloption costs ~2% instead of the trigger's ~6%, because the only thing it
adds is the `memcmp` — no lock, no trigger invocation, no per-row `bms_union`.

Treat the percentages as indicative rather than precise. This 4 vCPU container
shows roughly ±5% run to run, and the stock and trigger baselines moved that
much between runs; the reloption's own absolute figure was stable across runs
(10,971 then 10,829 on the narrow redundant workload). The WAL and buffer
numbers above are exact — they are counters, not timings.

### Concurrency: the first version of this was wrong

Suppressing an update means `table_tuple_update()` is never called, and the
first version dropped that call's concurrency checks along with it. The
comparison runs against `oldSlot`, fetched with `SnapshotAny` before anything
has established that it is still the live version, so a row another
transaction had already updated could compare equal and be skipped. Under
REPEATABLE READ that swallowed a serialization failure outright:

| isolation | reloption off | reloption on (first version) |
|---|---|---|
| REPEATABLE READ | `ERROR: could not serialize access due to concurrent update` | no error, silently skipped |
| READ COMMITTED | row re-evaluated, update applied | same (fresh snapshot, so no staleness) |

An application retrying on serialization errors would have lost the update
with no indication. Two restrictions fix it, neither of which costs anything
measurable:

* Suppression is confined to READ COMMITTED. There the statement takes a fresh
  snapshot, so `oldSlot` is the version the statement is entitled to act on.
  An isolation level using a transaction snapshot can only discover the
  conflict by attempting the update, so it always attempts it.
* The old tuple must carry `HEAP_XMAX_INVALID`, which is set only once xmax is
  known invalid and therefore proves nobody has updated, deleted or locked
  this version. Anything else falls through to the normal path.

`heap_update()` sets `HEAP_XMAX_INVALID` on every new row version, so a row
becomes eligible again as soon as it has been updated once — the guard does
not accumulate misses.

`src/test/isolation/specs/suppress-redundant-updates.spec` asserts that a
suppressing table and a plain table behave identically across both isolation
levels when a concurrent transaction updates the same row.

### What is still different, and the floor on fixing it

After the above, the only remaining behavioural difference is that a skipped
row takes **no row lock**, so a no-op `UPDATE` no longer blocks a concurrent
writer. That cannot be given back cheaply: PostgreSQL stores row locks in the
tuple header (`xmax`), so there is no lock without a page write, and no page
write without a WAL record — and with `full_page_writes = on`, possibly an
8 KB full page image. Any variant that genuinely serializes pays approximately
the floor the trigger already pays.

There is still room above that floor. The lock is only 63–76% of the trigger's
cost; the rest is trigger invocation, the per-row `bms_union` and materializing
a `HeapTuple` for the trigger API. A "compare, then lock, then skip the write"
mode should beat the trigger by a few percent with identical semantics — but
it must lock *first* and compare against the locked version, or it inherits
exactly the staleness bug described above. The correct place for that is inside
`heap_update()`, after `HeapTupleSatisfiesUpdate()` has validated the row and
while the buffer lock is already held. That is not implemented here.

If the goal is a mutex rather than an update, `SELECT ... FOR NO KEY UPDATE`
costs the same lock and says so, and `pg_advisory_xact_lock()` is pure shared
memory — no page write and no WAL at all.

`flamegraphs/patched_reloption_redundant.svg` shows the result: the
`ExecBRUpdateTriggers` tower is simply gone.

### Semantics, stated plainly

A skipped row is not counted in the command tag, produces no `RETURNING`
output, and fires no AFTER row triggers — matching a BEFORE trigger that
returns NULL. Two things are genuinely different and are why this is opt-in
and defaults to off:

* **No row lock is taken.** A no-op `UPDATE` no longer serializes against a
  concurrent update of the same row. Anyone using `UPDATE ... SET x = x` as a
  mutex must not enable this. Concurrency *checks* are preserved — see below —
  it is only the lock that is gone.
* **MERGE is not covered.** Its `UPDATE` action has separate row accounting
  and restart-on-conflict logic; it always applies the row. Supporting it is
  possible but wanted its own testing rather than being tacked on.

The check is deliberately not repeated when `ExecUpdateAct()` loops back to
`lreplace` after a failed cross-partition move, since the row may have been
concurrently updated by then and `oldSlot` would be stale.

### Testing

`make installcheck` against the patched server fails only tests that an
unpatched server built from the same tree in this container also fails — i.e.
the patch introduces no new failures. (Those are environmental, not related to
this work; the exact set varies slightly run to run.)

`src/test/regress/sql/update.sql` gains coverage for the command tag, row
versions being untouched, `RETURNING`, AFTER-trigger suppression, NULL
handling, and turning the option back off.
`src/test/isolation/specs/suppress-redundant-updates.spec` covers the
concurrency semantics against a plain table.

---

## 7. Files

* `harness/` — scripts to reproduce everything; see `harness/README.md`.
* `results/cost_attribution.txt` — the tables in §2, generated.
* `results/wal_report.txt` — the WAL accounting in §3.
* `results/wal_report_fpw_on.txt` — the same with `full_page_writes = on`.
* `results/tps_clean.txt` — unbiased throughput (§5).
* `results/hot_check.txt` — the HOT measurement (§5);
  `results/hot_check_invalid.txt` is the flawed earlier run.
* `results/patch_tps.txt`, `results/patch_wal.txt` — the reloption results (§6).
* `flamegraphs/*.svg` — per-workload flamegraphs (open in a browser; they zoom).
* `flamegraphs/diff_*.svg` — differential flamegraphs, **red = time added by
  attaching the trigger**, blue = time removed. The clearest single view: the
  added mass is almost entirely `ExecBRUpdateTriggers → GetTupleForTrigger →
  heap_lock_tuple`, and the removed mass is `heap_update` and its index work.
