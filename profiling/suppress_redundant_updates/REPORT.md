# Profiling `suppress_redundant_updates_trigger`

CPU profile of `suppress_redundant_updates_trigger()` across several UPDATE
workloads, with flamegraphs, to find optimization opportunities.

**Headline:** the comparison the trigger exists to perform is essentially free —
**1–3% of the trigger's own cost**. Almost everything else is the generic
BEFORE-ROW-trigger machinery wrapped around it, and **63–76% of the cost is a
single thing**: the mandatory `heap_lock_tuple()` on the old tuple, taken
*before* we can possibly know the update will be suppressed.

So there is essentially nothing to win inside `trigfuncs.c`. The wins are in
the machinery, and the biggest one is structural.

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
does not turn a no-op UPDATE into a read-only transaction.

And when it *cannot* suppress, it adds 10,000 lock records — **+26% WAL
records and +3.8% execution time** on top of the plain UPDATE.

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
much of the saving. It is also worth knowing that **PostgreSQL already handles
redundant updates fairly well without the trigger**: if the new values equal the
old ones, no indexed column has actually changed, so the update stays
HOT-eligible and skips index maintenance on its own. That removes much of the
benefit people expect on indexed tables.

Throughput deltas from the profiled runs are reported in
`results/profiled_tps.txt`, but they carry `perf` overhead and — more
importantly — a bias: `_notrig` tables accumulate bloat within a phase because
their updates actually apply, while suppressed `_trig` tables stay pristine.
`harness/run3.sh` re-measures throughput with a `VACUUM FULL` before every
repetition to remove that bias; see `results/tps_clean.txt`.

Cost *attribution* — the subject of this report — is not sensitive to that bias:
the 63–76% `heap_lock_tuple` share reproduces across all eight workloads.

---

## 6. Files

* `harness/` — scripts to reproduce everything; see `harness/README.md`.
* `results/cost_attribution.txt` — the tables in §2, generated.
* `results/wal_report.txt` — the WAL accounting in §3.
* `flamegraphs/*.svg` — per-workload flamegraphs (open in a browser; they zoom).
* `flamegraphs/diff_*.svg` — differential flamegraphs, **red = time added by
  attaching the trigger**, blue = time removed. The clearest single view: the
  added mass is almost entirely `ExecBRUpdateTriggers → GetTupleForTrigger →
  heap_lock_tuple`, and the removed mass is `heap_update` and its index work.
