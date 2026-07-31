#!/bin/sh
# Why did two runs of the same script disagree by 7 points?
#
# Suspicion: the comparison was never paired on the thing that varies most.
#
# orderby.sh, obsplit.sh and obconf.sh all do this, inside each repeat:
#
#   for each form:  mut_clone();  time the form
#
# so the four forms are measured on FOUR DIFFERENT CLONES.  mutability.sql's own
# header says between-clone spread reaches 11% on one form and 45% on another,
# because each clone is a fresh CTAS whose physical layout and ANALYZE sample
# decide the plan.  If that is right, a 3% form effect is being read off a
# measurement whose dominant term is which clone each form happened to land on,
# and calling the repeats "paired" was wrong: they are paired by loop index, not
# by table.
#
# Two experiments, on the two cells that disagreed:
#
#   A  one form, ten clones      -> how much is the clone worth on its own?
#   B  ten clones, all four      -> the form effect with the clone held constant
#      forms measured on EACH        (safe: at zero churn with the row comparison
#      clone, order rotated           on, none of the four forms writes a row --
#                                     asserted below rather than assumed)
#
# If A's spread swamps B's differences, the earlier numbers were measuring clones
# and the disagreement needs no further explanation.  If A is tight, the
# disagreement is something else and this rules the obvious answer out.
set -e

P=${PGBIN:-/home/user/pgsql-opt/bin}/psql
Q="$P -p ${PGPORT:-5610} -d ${PGDATABASE:-postgres} -X -q -At"

$Q -c "CREATE TABLE IF NOT EXISTS obroot(
         workload text, scope bigint, clone int, seq int,
         lock_ord bool, src_ord bool, us numeric,
         heap_before numeric, heap_after numeric, plan_sig text,
         server_start timestamptz DEFAULT pg_postmaster_start_time())" >/dev/null
$Q -c "TRUNCATE obroot" >/dev/null

# A signature of the DML's plan, so a plan flip between clones is visible rather
# than being reported as timing noise.
$Q -c "CREATE OR REPLACE FUNCTION ob_plan(p_pred text, p_src_ord bool)
       RETURNS text LANGUAGE plpgsql AS \$fn\$
       DECLARE j json; sig text;
       BEGIN
         EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) ' || ob_stmt(p_pred, p_src_ord)
           INTO j;
         SELECT string_agg(DISTINCT x, ',' ORDER BY x) INTO sig
           FROM regexp_matches(j::text, '\"Node Type\": \"([^\"]+)\"', 'g') AS m(a),
                LATERAL unnest(a) AS x;
         RETURN sig;
       END \$fn\$" >/dev/null

cell() {                        # workload span
  w=$1; span=$2
  $Q -c "SELECT bench_setup('$w', 100000, 1000)" >/dev/null
  pred=$($Q -c "SELECT replace(replace(predr,':k','1'),':span','$span')
                  FROM bench_workload WHERE id='$w'")
  scope=$($Q -c "SELECT count(*) FROM bench.mv WHERE $pred")
  $Q -c "SELECT mut_clone()" >/dev/null
  probe=$($Q -c "SELECT ob_time2(\$\$$pred\$\$, true, true, 3)")
  it=$($Q -c "SELECT GREATEST(8, LEAST(40, (1000000/GREATEST($probe,1))::int))")
  echo "--- $w scope=$scope iters=$it"

  c=1
  while [ $c -le 10 ]; do
    $Q -c "SELECT mut_clone()" >/dev/null
    # rotate which form goes first, so position within a clone is not signal
    case $((c % 4)) in
      0) combos="tt tf ft ff" ;; 1) combos="ff ft tf tt" ;;
      2) combos="tf tt ff ft" ;; 3) combos="ft ff tt tf" ;;
    esac
    n=1
    for k in $combos; do
      case $k in
        tt) lo=true;  so=true  ;; tf) lo=true;  so=false ;;
        ft) lo=false; so=true  ;; ff) lo=false; so=false ;;
      esac
      $Q -c "INSERT INTO obroot(workload,scope,clone,seq,lock_ord,src_ord,
                                heap_before,us,heap_after,plan_sig)
             SELECT '$w',$scope,$c,$n,$lo,$so,
                    round(pg_relation_size('bench.mvt')/1048576.0,2),
                    ob_time2(\$\$$pred\$\$, $lo, $so, $it),
                    round(pg_relation_size('bench.mvt')/1048576.0,2),
                    ob_plan(\$\$$pred\$\$, $so)" >/dev/null
      n=$((n + 1))
    done
    c=$((c + 1))
  done

  # The premise of measuring four forms on one clone: none of them writes a row.
  # Checked, not assumed -- if the heap grew, the later forms in each clone were
  # measured against a table the earlier ones changed and B is invalid.
  grew=$($Q -c "SELECT count(*) FROM obroot
                 WHERE workload='$w' AND heap_after > heap_before + 0.01")
  if [ "$grew" != "0" ]; then
    echo "  WARNING: heap grew in $grew of 40 measurements -- experiment B is not clean"
  else
    echo "  heap unchanged in all 40 measurements: forms do not interfere"
  fi
}

cell nonkey 10
cell window 10
echo "===== OBROOT DONE ====="
