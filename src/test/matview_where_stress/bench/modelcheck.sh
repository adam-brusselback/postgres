#!/bin/sh
# Does mutability.sql's model agree with the real command?
#
# mutability.sql hand-writes the statement forms refresh_by_direct_modification()
# would emit and times them against a plain-heap clone.  That is the only way to
# size forms the code cannot produce yet (no-prune, no-CTE, DO NOTHING), but it
# is a model, and a model that disagrees with the thing is worse than no model.
#
# Exactly one pair of its forms has a real-command counterpart:
#
#   A     fused CTE, plain DO UPDATE            <-> querytree=on optimized=off
#   Aopt  fused CTE, + the row comparison       <-> querytree=on optimized=on
#
# The absolute times differ by construction -- the real optimized path feeds the
# DML from a tuplestore where the model feeds it from a materialised CTE -- so
# what is compared is the RATIO.  Both isolate the row comparison with the
# source mechanism held constant, so the ratios should agree if the model is
# faithful.
#
# Result, over 40 cells across six workloads, two scales and four spans:
#
#   scope >= 1000   10 cells   mean |delta| 2.7 points, worst 4.6   -- faithful
#   scope 100-999   12 cells   mean |delta| 11.0,       worst 26.9
#   scope < 100     18 cells   mean |delta| 23.6,       worst 68.2  -- unusable
#
# The last bucket is not the model being wrong so much as nothing being
# measurable: mean real 0.9% against mean model -3.6%, on absolute times of a
# few hundred microseconds.  Both are noise.  So mutability.sql's numbers may be
# quoted at scope >= 1000 and must not be quoted at scope 1, which is
# unfortunate, because the scope-1 figures were the ones that made the mutability
# specialisations look largest.
#
# VACUUM between arms, not just at setup: the off arm rewrites every row and the
# on arm skips them, so without it the second arm is measured on a table the
# first bloated.  That artefact previously turned a real churn curve into a
# fictional one.
#
# What the agreement does NOT establish
# -------------------------------------
# Both sides of this comparison measure a heap that was built moments earlier and
# never updated -- bench_setup() for the real arm, mut_clone() for the model.
# That state is the writing arm's worst case (no free space in the FSM, no page
# dirtied since the last checkpoint) and only the writing arm feels it, so both
# ratios are inflated by the same mechanism.  They agree because they share it.
#
# bench/heapstate.sh measures the size of the shared bias: on nonkey/span=100 the
# real command reads 72-75% straight after a bench_setup and 54% once the heap has
# settled.  So a cell agreeing here means the model reproduces the command in the
# regime this script samples; it does not mean that regime is the one to quote.
# For steady-state figures use churn.sql, which settles the heap before timing.
set -e

P=/home/user/pgsql-opt/bin/psql
Q="$P -p 5610 -d postgres -X -q -At"

$Q -c "CREATE TABLE IF NOT EXISTS mutver(
         workload text, scale bigint, span int, scope bigint,
         real_off numeric, real_on numeric, real_pct numeric,
         model_a numeric, model_aopt numeric, model_pct numeric,
         server_start timestamptz DEFAULT pg_postmaster_start_time())" >/dev/null
$Q -c "TRUNCATE mutver" >/dev/null

# Time the real command, best of 5 after 3 warm-ups, at a given GUC setting.
# A function rather than an inline DO block: each psql -c is its own session, so
# a value stashed with set_config in one is not visible to the next.
$Q -c "CREATE OR REPLACE FUNCTION real_time(p_opt text, p_pred text)
       RETURNS numeric LANGUAGE plpgsql AS \$fn\$
       DECLARE t0 timestamptz; best numeric; us numeric; i int;
               stmt text := 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE ' || p_pred;
       BEGIN
         EXECUTE 'SET matview_partial_refresh_optimized = ' || p_opt;
         FOR i IN 1..3 LOOP EXECUTE stmt; END LOOP;
         FOR i IN 1..5 LOOP
           t0 := clock_timestamp();
           EXECUTE stmt;
           us := extract(epoch FROM clock_timestamp()-t0)*1e6;
           IF best IS NULL OR us < best THEN best := us; END IF;
         END LOOP;
         RETURN round(best);
       END \$fn\$" >/dev/null

for w in projection aggregate join_agg nonkey expensive window; do
  for scale in 10000 100000; do
    $Q -c "SELECT bench_setup('$w', $scale, 1000)" >/dev/null
    keymax=$($Q -c "SELECT (replace(replace(keymax,':scale','$scale'),
                              ':groups','1000'))::bigint
                      FROM bench_workload WHERE id='$w'")
    for span in 1 10 100 1000; do
      [ "$span" -ge "$keymax" ] && continue
      if [ "$span" = 1 ]; then
        pred=$($Q -c "SELECT replace(pred1,':k','1') FROM bench_workload WHERE id='$w'")
      else
        pred=$($Q -c "SELECT replace(replace(predr,':k','1'),':span','$span')
                        FROM bench_workload WHERE id='$w'")
      fi
      scope=$($Q -c "SELECT count(*) FROM bench.mv WHERE $pred" 2>/dev/null || echo 0)
      [ "$scope" = 0 ] && continue
      mv=$($Q -c "SELECT count(*) FROM bench.mv")
      [ $(( scope * 100 / mv )) -ge 90 ] && continue

      $Q -c "VACUUM (ANALYZE) bench.mv" >/dev/null
      roff=$($Q -c "SELECT real_time('off', \$\$$pred\$\$)")
      $Q -c "VACUUM (ANALYZE) bench.mv" >/dev/null
      ron=$($Q -c "SELECT real_time('on', \$\$$pred\$\$)")

      $Q -c "SELECT mut_clone()" >/dev/null
      ma=$($Q -c "SELECT mut_time('A', \$\$$pred\$\$, 5)")
      $Q -c "SELECT mut_clone()" >/dev/null
      mo=$($Q -c "SELECT mut_time('Aopt', \$\$$pred\$\$, 5)")

      # Both times go in as numerics.  Interpolating whole numbers into
      # 1 - a/b gives integer division, which silently yields exactly 1.0 or
      # 0.0 -- a column that reads 100.0 or 0.0 in every row and looks like an
      # emphatic result rather than a broken one.
      $Q -c "INSERT INTO mutver(workload,scale,span,scope,
                  real_off,real_on,real_pct,model_a,model_aopt,model_pct)
             VALUES ('$w',$scale,$span,$scope,$roff,$ron,
                     round(100.0*(1-$ron::numeric/NULLIF($roff,0)),1),
                     $ma,$mo,round(100.0*(1-$mo/NULLIF($ma,0)),1))" >/dev/null
      echo "  $w scale=$scale span=$span scope=$scope  real=${roff}->${ron}  model=${ma}->${mo}"
    done
  done
done
echo "===== MUTVER DONE ====="
