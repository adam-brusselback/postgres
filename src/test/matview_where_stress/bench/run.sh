#!/bin/sh
#
# Benchmark suite for REFRESH MATERIALIZED VIEW ... WHERE ...
#
#   ./run.sh [options]
#
# Sweeps eight representative workloads (see workloads.sql) across scale, scope,
# concurrency, refresh form and predicate shape.  Every result is normalised
# against a full rebuild of the same matview, so numbers taken on different
# machines or builds can still be compared to each other.
#
# Options (all have defaults; give a list to sweep it):
#   --workloads  projection,aggregate,...   default: all eight
#   --scales     100000,1000000             base table rows
#   --groups     1000                       distinct key values
#   --spans      1,10,100                   keys per refresh
#   --forms      conc,bare                  conc | bare | full
#   --shapes     key,array,range            predicate shape
#   --clients    1,4,16                     concurrent sessions
#   --overlap    disjoint,hot               disjoint scopes, or all fighting
#   --mutate     on|off                     change the base data first
#   --sync       on|off   default off       synchronous_commit for the run.
#                                           pgbench commits once per refresh, so with
#                                           sync on every measurement carries a WAL
#                                           flush -- ~1.7 ms here, which swamps a
#                                           scope-1 refresh.  Leave it off unless you
#                                           are deliberately measuring commit cost.
#   --time       10                         seconds per measurement
#   --repeat     3                          take the best of N
#   --label      <text>                     names this run in bench_result
#   --port/--db/--bindir
#
# Results land in the bench_result table.  Compare two runs with:
#   SELECT workload, span, clients, form, a.vs_full_per_row, b.vs_full_per_row
#     FROM bench_result a JOIN bench_result b USING (workload,span,clients,form)
#    WHERE a.run_label = 'before' AND b.run_label = 'after';
set -e

WORKLOADS=; SCALES=100000; GROUPS=1000; SPANS=1,10,100
FORMS=conc,bare; SHAPES=key; CLIENTS=1; OVERLAP=disjoint; MUTATE=off
SYNC=off
TIME=10; REPEAT=3; LABEL=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)
PORT=5610; DB=postgres; BINDIR=/home/user/pgsql-opt/bin

while [ $# -gt 0 ]; do
  case "$1" in
    --workloads) WORKLOADS=$2; shift 2;;  --scales)  SCALES=$2;  shift 2;;
    --groups)    GROUPS=$2;    shift 2;;  --spans)   SPANS=$2;   shift 2;;
    --forms)     FORMS=$2;     shift 2;;  --shapes)  SHAPES=$2;  shift 2;;
    --clients)   CLIENTS=$2;   shift 2;;  --overlap) OVERLAP=$2; shift 2;;
    --mutate)    MUTATE=$2;    shift 2;;  --time)    TIME=$2;    shift 2;;
    --sync)      SYNC=$2;      shift 2;;
    --repeat)    REPEAT=$2;    shift 2;;  --label)   LABEL=$2;   shift 2;;
    --port)      PORT=$2;      shift 2;;  --db)      DB=$2;      shift 2;;
    --bindir)    BINDIR=$2;    shift 2;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

DIR=$(dirname "$0")
PSQL="$BINDIR/psql -p $PORT -d $DB -q -X"
PGBENCH="$BINDIR/pgbench -p $PORT -d $DB"
TMP=${TMPDIR:-/tmp}/mvbench.$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
list() { echo "$1" | tr ',' ' '; }

$PSQL -f "$DIR/workloads.sql"
$PSQL -f "$DIR/harness.sql"
[ -n "$WORKLOADS" ] || WORKLOADS=$($PSQL -Atc 'SELECT string_agg(id, ",") FROM bench_workload ORDER BY 1' | tr -d ' ')
[ -n "$WORKLOADS" ] || WORKLOADS=$($PSQL -Atc "SELECT string_agg(id, ',' ORDER BY ord) FROM bench_workload")

VER=$($PSQL -Atc 'SELECT version()')
ASSERT=$($PSQL -Atc 'SHOW debug_assertions')
echo "run '$LABEL' :: assertions=$ASSERT  synchronous_commit=$SYNC"
[ "$ASSERT" = off ] || echo "  WARNING: assertions are ON; these numbers are not comparable with a -O2 run" >&2

for w in $(list "$WORKLOADS"); do
 for scale in $(list "$SCALES"); do
  MVROWS=$($PSQL -Atc "SELECT bench_setup('$w', $scale, $GROUPS)")
  FULL=$($PSQL -Atc "SET search_path=bench,public; SELECT bench_baseline(3)")
  ISO=$($PSQL -Atc "SELECT isolates FROM bench_workload WHERE id='$w'")
  KEYMAXE=$($PSQL -Atc "SELECT keymax FROM bench_workload WHERE id='$w'")
  KEYMAX=$(echo "$KEYMAXE" | sed "s/:scale/$scale/; s/:groups/$GROUPS/")
  echo "== $w  scale=$scale  mv_rows=$MVROWS  full=${FULL}ms  ($ISO)"

  for shape in $(list "$SHAPES"); do
   PREDCOL=$(case $shape in key) echo pred1;; array) echo predn;; range) echo predr;; esac)
   PREDT=$($PSQL -Atc "SELECT $PREDCOL FROM bench_workload WHERE id='$w'")
   for span in $(list "$SPANS"); do
    [ "$shape" = key ] && [ "$span" != 1 ] && continue
    SCOPE=$($PSQL -Atc "SET search_path=bench,public;
       SELECT bench_scope_rows(\$\$$(echo "$PREDT" | sed "s/:k/1/g; s/:span/$span/g")\$\$)")
    for form in $(list "$FORMS"); do
     CONC=$([ "$form" = conc ] && echo 'CONCURRENTLY ' || echo '')
     for nc in $(list "$CLIENTS"); do
      for ov in $(list "$OVERLAP"); do
       S="$TMP/s.bench"
       {
         echo "SET synchronous_commit = $SYNC;"
         if [ "$ov" = disjoint ]; then
           echo "\\set slice greatest(1, :keymax / :nclients)"
           echo "\\set k (:client_id * :slice) + random(1, greatest(1, :slice - :span))"
         else
           echo "\\set k random(1, greatest(1, 10 - :span))"
         fi
         if [ "$MUTATE" = on ]; then
           $PSQL -Atc "SELECT sql FROM bench_mutation WHERE id='$w'" | sed 's/$/;/'
         fi
         echo "REFRESH MATERIALIZED VIEW ${CONC}bench.mv WHERE $PREDT;"
       } | sed "s/:span/$span/g" > "$S"

       BEST_TPS=0; BEST_LAT=
       i=0; while [ $i -lt "$REPEAT" ]; do
         i=$((i+1))
         OUT=$($PGBENCH -n -f "$S" -c "$nc" -j "$(( nc < 4 ? nc : 4 ))" -T "$TIME" \
                 -D keymax="$KEYMAX" -D nclients="$nc" 2>&1) || {
                   echo "   pgbench failed for $w/$shape/$span/$form/$nc/$ov" >&2
                   echo "$OUT" | tail -3 >&2; break; }
         T=$(echo "$OUT" | sed -n 's/^tps = \([0-9.]*\).*/\1/p' | head -1)
         L=$(echo "$OUT" | sed -n 's/^latency average = \([0-9.]*\).*/\1/p' | head -1)
         [ -n "$T" ] || continue
         if [ "$(echo "$T > $BEST_TPS" | bc -l 2>/dev/null || echo 1)" = 1 ]; then
           BEST_TPS=$T; BEST_LAT=$L
         fi
       done
       [ "$BEST_TPS" = 0 ] && continue

       $PSQL -c "INSERT INTO bench_result(run_label,pg_version,assertions,workload,isolates,
                   scale,groups,mv_rows,form,predshape,span,scope_rows,clients,overlap,mutate,sync,
                   tps,latency_ms,full_ms,us_per_scope_row,vs_full_per_row)
                 SELECT '$LABEL','$VER','$ASSERT','$w',\$\$$ISO\$\$,
                   $scale,$GROUPS,$MVROWS,'$form','$shape',$span,
                   NULLIF($SCOPE,0),$nc,'$ov',$([ "$MUTATE" = on ] && echo true || echo false),'$SYNC',
                   $BEST_TPS, $BEST_LAT, $FULL,
                   round(($BEST_LAT * 1000.0) / NULLIF($SCOPE,0), 3),
                   round((($BEST_LAT * 1000.0) / NULLIF($SCOPE,0))
                         / NULLIF(($FULL * 1000.0) / NULLIF($MVROWS,0), 0), 2)" >/dev/null
       printf '   %-10s %-6s span=%-5s scope=%-7s %-4s c=%-3s %-8s  %8.1f tps  %7.2f ms\n' \
         "$w" "$shape" "$span" "$SCOPE" "$form" "$nc" "$ov" "$BEST_TPS" "$BEST_LAT"
      done
     done
    done
   done
  done
 done
done

echo
$BINDIR/psql -p "$PORT" -d "$DB" -f "$DIR/report.sql" -v label="'$LABEL'"
