#!/bin/sh
#
# Dump one labelled bench_result run to a markdown table on stdout.
#
#   ./extract.sh <run_label> [port] [db]
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
PORT=${2:-5610}
DB=${3:-postgres}
BINDIR=${BINDIR:-/home/user/pgsql-opt/bin}

[ -n "$LABEL" ] || { echo "usage: $0 <run_label> [port] [db]" >&2; exit 2; }

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
echo '### spi against querytree'
echo
echo 'Grouped by (workload, predshape, span).  pct_faster is the querytree'
echo 'implementation against the text one: positive means querytree is faster.'
echo
q "-c \"SELECT workload, predshape AS shape, span, scope_rows,
              spi AS spi_ms, qt AS qt_ms,
              round(100.0*(1 - qt/spi), 1) AS pct_faster
         FROM (SELECT workload, predshape, span, scope_rows,
                      min(latency_ms) FILTER (WHERE form='spi')       AS spi,
                      min(latency_ms) FILTER (WHERE form='querytree') AS qt
                 FROM bench_result WHERE run_label='$LABEL'
                GROUP BY 1,2,3,4) s
        WHERE spi IS NOT NULL AND qt IS NOT NULL AND spi > 0
        ORDER BY workload, predshape, span\""
echo
echo '### Summary by shape'
echo
q "-c \"SELECT predshape AS shape, count(*) AS cells,
              round(avg(100.0*(1 - qt/spi)),1) AS avg_pct_faster,
              round(min(100.0*(1 - qt/spi)),1) AS worst,
              round(max(100.0*(1 - qt/spi)),1) AS best
         FROM (SELECT workload, predshape, span,
                      min(latency_ms) FILTER (WHERE form='spi')       AS spi,
                      min(latency_ms) FILTER (WHERE form='querytree') AS qt
                 FROM bench_result WHERE run_label='$LABEL'
                GROUP BY 1,2,3) s
        WHERE spi IS NOT NULL AND qt IS NOT NULL AND spi > 0
        GROUP BY predshape ORDER BY predshape\""
