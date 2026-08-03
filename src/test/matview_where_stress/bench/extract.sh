#!/bin/sh
#
# Dump one labelled bench_result run to a markdown table on stdout.
#
#   ./extract.sh <run_label>              one run, cell by cell
#   ./extract.sh <label_a> <label_b>      two runs, compared cell by cell
#
# PORT and DB come from the environment (default 5610 / postgres).
#
# Why this exists
# ---------------
# bench_result is not durable.  The container this work runs in is reclaimed
# after a period of inactivity and restarts from a snapshot, which rewinds the
# cluster along with everything else -- the Jul 30 rows survive because they
# predate the snapshot, not because the database is out of scope.  Seven
# reclamations have now happened, two of them mid-sweep, and each one took every
# row written since.
#
# So a sweep is not finished when run.sh exits.  It is finished when its numbers
# are in git and pushed.  This script is the step between the two, and it exists
# as a script rather than as a psql invocation typed each time because the
# grouping is easy to get wrong in a way that still prints a plausible table --
# see below.
#
# The grouping, which has already been got wrong once
# ---------------------------------------------------
# There is more than one row per (workload, span, form): one per PREDICATE
# SHAPE.  Aggregating without predshape in the GROUP BY silently compares, say,
# spi-on-array against querytree-on-key -- different predicates, different scope
# row counts, and a percentage that means nothing.  It does not error and the
# table looks fine.  predshape is therefore in the GROUP BY here, always, and
# the shape census prints above the numbers so a reader can see the sweep's
# actual coverage before reading any of it.
#
# Coverage matters because run.sh:157 skips every span but 1 for the `key`
# shape (`id = :k` has no meaningful span above 1), so a run left on the default
# --shapes key carries span-1 cells ONLY.  A 1:3:3 key:array:range census is a
# full sweep; anything else is not, whatever the numbers say.
set -eu

LABEL=${1:-}
LABEL_B=${2:-}
PORT=${PORT:-5610}
DB=${DB:-postgres}
BINDIR=${BINDIR:-/home/user/pgsql-opt/bin}

[ -n "$LABEL" ] || { echo "usage: $0 <label_a> [label_b]" >&2; exit 2; }

q() { su pgtest -c "$BINDIR/psql -p $PORT -d $DB -X -q $*"; }

exists=$(q "-Atc \"SELECT count(*) FROM bench_result WHERE run_label='$LABEL'\"")
[ "$exists" -gt 0 ] 2>/dev/null || {
    echo "no rows for run_label='$LABEL'" >&2; exit 1; }

cat <<HDR
## Sweep \`$LABEL\`

Extracted by \`bench/extract.sh\`.  Build and coverage first: a number here is
only comparable to another number taken on the same build, and only complete if
the shape census reads 1:3:3.

HDR

echo '### Provenance'
echo
q "-Atc \"SELECT '- rows: '||count(*)||'  ('||min(run_at)||' to '||max(run_at)||')'
          ||E'\n- assertions: '||string_agg(DISTINCT assertions,',')
          ||E'\n- pg_version: '||string_agg(DISTINCT pg_version,',')
          ||E'\n- scale: '||string_agg(DISTINCT scale::text,',')
          ||'  groups: '||string_agg(DISTINCT groups::text,',')
          ||'  clients: '||string_agg(DISTINCT clients::text,',')
          ||'  sync: '||string_agg(DISTINCT sync,',')
          ||'  perxact: '||string_agg(DISTINCT perxact::text,',')
        FROM bench_result WHERE run_label='$LABEL'\""
echo
echo '### Shape census'
echo
q "-c \"SELECT predshape, count(*) AS rows, count(DISTINCT workload) AS workloads,
              string_agg(DISTINCT span::text, ',' ORDER BY span::text) AS spans
         FROM bench_result WHERE run_label='$LABEL'
        GROUP BY predshape ORDER BY predshape\""
echo
if [ -n "$LABEL_B" ]; then
  exists_b=$(q "-Atc \"SELECT count(*) FROM bench_result WHERE run_label='$LABEL_B'\"")
  [ "$exists_b" -gt 0 ] 2>/dev/null || {
      echo "no rows for run_label='$LABEL_B'" >&2; exit 1; }

  echo "### \`$LABEL\` against \`$LABEL_B\`"
  echo
  echo "Joined on (workload, predshape, span), which is the grouping the header"
  echo "explains and the one that has already been got wrong once.  pct_faster is"
  echo "\`$LABEL_B\` against \`$LABEL\`: positive means \`$LABEL_B\` is faster."
  echo
  echo "The absolute saving is the column to read when the effect is a FIXED cost"
  echo "-- a plan built once instead of every call is the same number of"
  echo "microseconds whether the refresh takes one millisecond or sixty, so the"
  echo "percentage only says how cheap the refresh was."
  echo
  q "-c \"SELECT a.workload, a.predshape AS shape, a.span, a.scope_rows,
                a.latency_ms AS a_ms, b.latency_ms AS b_ms,
                round(100.0*(a.latency_ms-b.latency_ms)/a.latency_ms, 1) AS pct_faster,
                round((a.latency_ms-b.latency_ms)*1000, 0) AS saving_us
           FROM bench_result a
           JOIN bench_result b
             ON (a.workload,a.predshape,a.span,a.form,a.clients)
              = (b.workload,b.predshape,b.span,b.form,b.clients)
          WHERE a.run_label='$LABEL' AND b.run_label='$LABEL_B' AND a.latency_ms > 0
          ORDER BY a.workload, a.predshape, a.span\""
  echo
  echo '### Summary by shape'
  echo
  echo 'Percentages are averaged over CELLS, not weighted by microseconds.  The'
  echo 'saving is reported as a range rather than a mean for the same reason:'
  echo 'these workloads refresh in 0.6 to 60 ms, so a mean over them describes no'
  echo 'workload in particular.  Pooling absolute microseconds across scales is'
  echo 'what produced the bogus band in the p21c sweep.  If the saving really is a'
  echo 'fixed cost, the spread between min and max is the evidence for it.'
  echo
  q "-c \"SELECT a.predshape AS shape, count(*) AS cells,
                round(avg(100.0*(a.latency_ms-b.latency_ms)/a.latency_ms),1) AS avg_pct,
                round(min(100.0*(a.latency_ms-b.latency_ms)/a.latency_ms),1) AS worst,
                round(max(100.0*(a.latency_ms-b.latency_ms)/a.latency_ms),1) AS best,
                round(min((a.latency_ms-b.latency_ms)*1000)) AS min_saving_us,
                round(max((a.latency_ms-b.latency_ms)*1000)) AS max_saving_us
           FROM bench_result a
           JOIN bench_result b
             ON (a.workload,a.predshape,a.span,a.form,a.clients)
              = (b.workload,b.predshape,b.span,b.form,b.clients)
          WHERE a.run_label='$LABEL' AND b.run_label='$LABEL_B' AND a.latency_ms > 0
          GROUP BY a.predshape ORDER BY a.predshape\""
  echo
  echo '### Any cell where the second run is SLOWER'
  echo
  echo 'Printed even when empty, because "no regressions" has to be something the'
  echo 'reader can see rather than something absent from a table.'
  echo
  q "-c \"SELECT a.workload, a.predshape AS shape, a.span, a.scope_rows,
                a.latency_ms AS a_ms, b.latency_ms AS b_ms,
                round(100.0*(a.latency_ms-b.latency_ms)/a.latency_ms, 1) AS pct_faster
           FROM bench_result a
           JOIN bench_result b
             ON (a.workload,a.predshape,a.span,a.form,a.clients)
              = (b.workload,b.predshape,b.span,b.form,b.clients)
          WHERE a.run_label='$LABEL' AND b.run_label='$LABEL_B'
            AND b.latency_ms >= a.latency_ms
          ORDER BY a.workload, a.predshape, a.span\""
else
  echo '### Cells'
  echo
  echo 'Grouped by (workload, predshape, span, form).  The form axis used to hold'
  echo 'the two implementations of direct modification; the text one is gone, so'
  echo 'it now holds conc, bare and opt -- lock level and the row comparison.'
  echo
  q "-c \"SELECT workload, predshape AS shape, span, scope_rows, form,
                latency_ms, tps, vs_full_per_row
           FROM bench_result WHERE run_label='$LABEL'
          ORDER BY workload, predshape, span, form\""
fi
