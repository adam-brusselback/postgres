#!/bin/sh
#
# Close the measurement gaps SPECIALIZE.md section 5 lists, in one pass.
#
#   ./gaps.sh [label-prefix]
#
# Each block below exists because a whole axis of the design had never been
# measured, not because a number looked suspicious.  Every run so far in
# bench_result was --clients 1 --overlap disjoint --perxact 1 and skipped any
# scope at or above 90% of the matview, so three of the seven axes in
# SPECIALIZE.md section 1 have no data at all behind them.
#
# Run it on an otherwise idle machine.  These are latency measurements and a
# concurrent build will move them.
set -e

DIR=$(dirname "$0")
P=${1:-gaps}
COMMON="--time 8 --repeat 2 --mintxn 30"

echo "===== Gap 2: concurrency ====="
# The axis the row lock and its ORDER BY exist to serve, and the one where the
# cost/benefit is inverted: the lock costs most where it buys least.  'nonkey'
# is here because its whole premise is that disjoint scopes should run in
# parallel -- if that is false, it is false here.  Metric is throughput and the
# deadlock count, not latency: a configuration that deadlocks looks fast,
# because the aborted transactions never reach the average.
$DIR/run.sh --workloads projection,aggregate,nonkey \
            --shapes key,range --spans 1,10 --forms conc \
            --clients 1,4,16 --overlap disjoint,hot \
            --label "$P-concurrency" $COMMON

echo "===== Gap 4: the match/merge crossover ====="
# run.sh skips scopes at or above 90% of the matview, which is correct for
# measuring partial refresh and removes exactly the region where match/merge
# could win if it wins anywhere.  --maxscope 100 lifts it deliberately.  Spans
# chosen so scope lands near 10/25/50/75/90% for each workload: aggregate has
# one matview row per key, timerange has 200 series per bucket.
$DIR/run.sh --workloads aggregate --shapes range --spans 100,250,500,750,900 \
            --forms bare,conc --maxscope 100 \
            --label "$P-crossover" $COMMON
$DIR/run.sh --workloads timerange --shapes range --spans 10,25,50,75,90 \
            --forms bare,conc --maxscope 100 \
            --label "$P-crossover" $COMMON

echo "===== Gap 5: transaction context (D1 vs D2) ====="
# Every number in bench_result commits once per refresh, which is driver
# pattern D2 (queue drain).  D1 -- a statement trigger firing inside the
# writer's transaction -- pays no commit of its own.  The difference between
# these two labels is the commit's share of everything measured so far, and the
# 12x already attributed to commit cost says it is not small.
$DIR/run.sh --workloads projection,aggregate,nonkey \
            --shapes key,range --spans 1,10,100 --forms conc \
            --perxact 1  --label "$P-txn-d2" $COMMON
$DIR/run.sh --workloads projection,aggregate,nonkey \
            --shapes key,range --spans 1,10,100 --forms conc \
            --perxact 20 --label "$P-txn-d1" $COMMON

echo "===== finishing p3opt: the three workloads it never covered ====="
# p3opt compares the text/SPI path, the Query-tree path and the optimised
# Query-tree path on one binary.  It covers four of the eight workloads, and
# the three missing here are the ones with the largest scopes -- exactly where
# SPECIALIZE.md says the ranking inverts, so the existing four cannot stand in
# for them.  Same parameters as the original run, appended to the same label.
# 'recursive' stays out: its predicate cannot push into the recursive term, so
# every form evaluates the whole closure and measures that instead.
$DIR/run.sh --workloads window,timerange,expensive \
            --shapes key,array,range --spans 1,10,100 \
            --forms spi,querytree,qtopt --label p3opt $COMMON

echo "===== verifying every label before anything is read ====="
for l in "$P-concurrency" "$P-crossover" "$P-txn-d2" "$P-txn-d1" p3opt; do
  echo "--- $l"
  # Checks 1 and 6 are expected to fail for the targeted labels: these sweeps
  # deliberately cover a subset of workloads, and the crossover sweep exists to
  # measure the near-total scopes check 6 rejects.  Everything else must pass.
  ${BINDIR:-/home/user/pgsql-opt/bin}/psql -p "${PORT:-5610}" -d postgres -X \
    -f "$DIR/verify.sql" -v label="$l"
done

echo "===== GAPS DONE ====="
