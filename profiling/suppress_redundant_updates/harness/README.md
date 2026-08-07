# Profiling harness for `suppress_redundant_updates_trigger`

Reproduces the CPU profile and flamegraphs in `../REPORT.md`.

## Requirements

* A PostgreSQL build with frame pointers and symbols:

  ```sh
  ./configure --prefix=$HOME/pgbuild --enable-debug \
      CFLAGS="-O2 -g -fno-omit-frame-pointer"
  make -j$(nproc) && make install
  ```

* `perf` (`linux-tools-*`) and Brendan Gregg's
  [FlameGraph](https://github.com/brendangregg/FlameGraph) checked out.
* `kernel.perf_event_paranoid <= 2` is enough — only user-space stacks are
  needed. If you profile a server running as another user, run `perf` as root.

The scripts hard-code a `BASE` directory, the `pgbuild` prefix and the perf
binary path at the top; edit those before running elsewhere. PostgreSQL will
not run as root, so they drop to uid 1000 via `setpriv` while `perf` stays
root in order to attach to the backend.

## Phases

| script | what it does |
|---|---|
| `setup.sql` | narrow (4-col) and wide (62-col) tables, `_trig` / `_notrig` pairs |
| `setup2.sql` | 5-col table with 3 secondary indexes, so real updates cannot be HOT |
| `mkscripts.sh` | generates the pgbench workload scripts |
| `run.sh` | phase 1 — 8 workloads under the **simple** query protocol, `perf record` each |
| `run2.sh` | phase 2 — 10 workloads under `-M prepared`, plus the indexed table |
| `run3.sh` | phase 3 — throughput only, `VACUUM FULL` between reps, median of 3 |
| `run4.sh` | phase 4 — WAL accounting with `full_page_writes = on` |
| `wal.sql` | `EXPLAIN (ANALYZE, WAL, BUFFERS)` for a 10k-row batch of each update kind |
| `diffgraphs.sh` | differential flamegraphs (trigger vs no trigger) |
| `analyze.sh` | per-workload self time + inclusive cost of key frames |
| `final_analysis.sh` | the consolidated tables used in the report |

Phases 1 and 2 attach `perf` to the backend, so their throughput numbers carry
profiling overhead and are not directly comparable to phase 3. Use phase 3 for
throughput and phases 1/2 for cost attribution.

## Workload naming

`<shape>_<trig|notrig>_<redundant|changing>[_prep]`

* **redundant** — `SET a = a, b = b`, NEW is byte-identical to OLD, so the
  trigger suppresses every row.
* **changing** — `SET a = a + 1, b = b + 1`, nothing can be suppressed, so the
  trigger is pure overhead.

## Caveat

`_notrig` tables accumulate bloat within a phase because their updates actually
apply, while suppressed `_trig` tables stay pristine. Phase 1/2 throughput is
therefore biased against `_notrig` in later workloads; phase 3 exists to remove
that bias with a `VACUUM FULL` before every repetition. Cost *attribution*
(which function burns the CPU) is not sensitive to this.
