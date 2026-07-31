#!/bin/sh
# How much of the row comparison's measured saving is the state of the heap?
#
#   ./heapstate.sh
#
# matview_partial_refresh_optimized adds
#
#   WHERE (mv.cols) IS DISTINCT FROM (EXCLUDED.cols)
#
# to the DO UPDATE, so at zero churn the optimized arm writes NOTHING and the
# un-optimized arm rewrites every row in scope.  That is the whole point of the
# optimization, and it is also a measurement hazard, because it means every
# write-cost variable in the system lands on exactly one side of the comparison:
#
#   free space in the FSM          only the writing arm allocates
#   pages dirtied since checkpoint only the writing arm emits full-page images
#   accumulated bloat              only the writing arm creates dead tuples
#   relation extension             only the writing arm extends
#
# None of those are constant.  A matview that bench_setup() has just built with
# CREATE TABLE AS is in the most expensive state available to the writing arm --
# no free space, nothing dirty -- and one that has been refreshed a few hundred
# times and vacuumed is in the cheapest.  So the same statements, the same data,
# the same binary and the same boot give answers between 54% and 82% depending
# on when in that trajectory the sample is taken.
#
# This measures the trajectory directly rather than picking a point on it.  Both
# arms are run refresh by refresh from a fresh bench_setup, with the heap size
# recorded alongside each timing, and then again with a VACUUM before every
# timed refresh.
#
# Measured (nonkey/span=100/scope=10000, matview 100000 rows, clean heap 5.0MB):
#
#   cycle    off us   off heap    on us   on heap
#       1     88928      5.5MB    34938     5.0MB
#       4     67836      7.0MB    29167     5.0MB
#       8     63134      8.9MB    26671     5.0MB
#      12     69393     10.8MB    27873     5.0MB
#      40     76249     23.6MB    24214     5.0MB
#
# The on arm's heap never moves: it writes nothing, ever.  The off arm adds
# ~0.5MB per refresh -- one dead tuple per row in scope -- and does not stop.
#
# So the off arm has two opposed transients and the reported saving depends on
# which one is sampled:
#
#   first 8 refreshes, no VACUUM      57.8%   heap 1.1-1.8x
#   refreshes 9-20                    62.8%   heap up to 2.9x
#   refreshes 21-40                   68.2%   heap up to 4.7x
#   VACUUM before each                55.2%   heap clean
#
# Sampling the dip is what modelcheck.sh's real_time() does -- three warm-ups
# then best of five, i.e. cycles 4 through 8 -- and it is where the 72-78%
# figures came from.  The steady-state answer for a matview being refreshed on
# a schedule is the last row: autovacuum holds the heap near clean, so 55% is
# the number that describes the command as deployed.
#
# projection/span=1000 is the same shape and harsher: 54.0% over the first eight
# refreshes against 25.3% with a VACUUM before each.
#
# Run this before quoting any figure that compares a writing arm with a
# non-writing one.  It is cheap and it is the difference between a claim and a
# claim with a protocol attached.
set -e

P=${PGBIN:-/home/user/pgsql-opt/bin}/psql
Q="$P -p ${PGPORT:-5610} -d ${PGDATABASE:-postgres} -X -q -At"
TMP=${TMPDIR:-/tmp}/heapstate_cell.sql

$Q -c "CREATE TABLE IF NOT EXISTS public.heapstate(
         run_at timestamptz DEFAULT now(), workload text, span int, arm text,
         cycle int, us numeric, heap_mb numeric, phase text,
         server_start timestamptz DEFAULT pg_postmaster_start_time())"
$Q -c "TRUNCATE public.heapstate"

$Q -c "CREATE OR REPLACE FUNCTION public.one_refresh(p_opt text, p_pred text)
       RETURNS numeric LANGUAGE plpgsql AS \$fn\$
       DECLARE t0 timestamptz;
               stmt text := 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE '
                            || p_pred;
       BEGIN
         EXECUTE 'SET matview_partial_refresh_querytree = on';
         EXECUTE 'SET matview_partial_refresh_optimized = ' || p_opt;
         t0 := clock_timestamp();
         EXECUTE stmt;
         RETURN round(extract(epoch FROM clock_timestamp()-t0)*1e6);
       END \$fn\$" >/dev/null

cell() {                        # workload span
  w=$1; span=$2
  for arm in off on; do
    # A fresh setup per arm, so each one starts from the same never-updated
    # heap.  Reusing one setup would leave the second arm measuring whatever
    # the first arm's write pattern shaped, which is the confound being mapped.
    $Q -c "SELECT bench_setup('$w', 100000, 1000)" >/dev/null
    pred=$($Q -c "SELECT replace(replace(predr,':k','1'),':span','$span')
                    FROM bench_workload WHERE id='$w'")
    # Separate -c calls: psql wraps multiple statements in one -c in an implicit
    # transaction, and VACUUM cannot run inside a transaction block.
    $Q -c "VACUUM (ANALYZE) bench.mv" >/dev/null
    $Q -c "CHECKPOINT" >/dev/null

    # Generated as one file so the whole arm runs in a single backend: the
    # querytree path caches its plan per session, and a per-statement psql -c
    # would pay a plan build on every sample.
    : > "$TMP"
    printf '\\set ON_ERROR_STOP on\n' >> "$TMP"
    c=1
    while [ $c -le 40 ]; do
      printf "INSERT INTO public.heapstate(workload,span,arm,cycle,us,heap_mb,phase)
              SELECT '%s',%s,'%s',%s, public.one_refresh('%s', \$\$%s\$\$),
                     round(pg_relation_size('bench.mv')/1048576.0,1),'novac';\n" \
             "$w" "$span" "$arm" "$c" "$arm" "$pred" >> "$TMP"
      c=$((c + 1))
    done
    c=1
    while [ $c -le 20 ]; do
      printf "VACUUM (ANALYZE) bench.mv;\n" >> "$TMP"
      printf "INSERT INTO public.heapstate(workload,span,arm,cycle,us,heap_mb,phase)
              SELECT '%s',%s,'%s',%s, public.one_refresh('%s', \$\$%s\$\$),
                     round(pg_relation_size('bench.mv')/1048576.0,1),'vac';\n" \
             "$w" "$span" "$arm" "$c" "$arm" "$pred" >> "$TMP"
      c=$((c + 1))
    done
    $Q -f "$TMP" >/dev/null
    echo "  done $w span=$span arm=$arm"
  done
}

cell nonkey     100
cell projection 1000

# Not $Q: that carries -At, which is right for capturing single values into
# shell variables and wrong for a table meant to be read.
$P -p ${PGPORT:-5610} -d ${PGDATABASE:-postgres} -X -q -P border=2 -c "
       SELECT workload, span,
              CASE WHEN phase='vac' THEN 'vacuum before each'
                   WHEN cycle <= 8  THEN 'no vacuum, 1-8'
                   WHEN cycle <= 20 THEN 'no vacuum, 9-20'
                   ELSE 'no vacuum, 21-40' END AS protocol,
              min(us)      FILTER (WHERE arm='off') AS off_us,
              min(us)      FILTER (WHERE arm='on')  AS on_us,
              round(100*(1 - min(us) FILTER (WHERE arm='on')
                           / min(us) FILTER (WHERE arm='off')),1) AS saving_pct,
              max(heap_mb) FILTER (WHERE arm='off') AS off_heap_mb,
              max(heap_mb) FILTER (WHERE arm='on')  AS on_heap_mb
         FROM public.heapstate GROUP BY 1,2,3
        ORDER BY 1, min(CASE WHEN phase='vac' THEN 4 ELSE (cycle+7)/8 END)"
echo "===== HEAPSTATE DONE ====="
