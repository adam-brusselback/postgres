#!/bin/sh
# What are the two ORDER BYs actually worth, and which one is worth anything?
#
#   ./orderby.sh
#
# SPECIALIZE.md used to say two things about them that did not sit together:
# that the pre-lock's ORDER BY is "free when the arbiter index matches the
# predicate column, 3.6x slower when not", and that dropping both is "small, and
# only in the aligned case, where the index already supplies the order".  If the
# elision fires only where the clause was already free, the saving is zero by
# construction.  "Small" had been asserted, never measured.
#
# Two clauses are at stake and they are NOT the same trade:
#
#   pre-lock   SELECT 1 FROM mv WHERE (pred) ORDER BY keys FOR NO KEY UPDATE
#              A deterministic lock order.  Two refreshes with overlapping
#              scopes that take rows in different orders deadlock.
#   source     the materialised CTE feeding the upsert, also ORDER BY keys, so
#              the DML applies in arbiter-key order.
#
# Measured on a plain-heap clone the way mutability.sql does, with the row
# comparison ON so that at zero churn neither arm writes and what is left is the
# ordering cost alone.  Equal sample counts for every form, fresh clone per
# form, form order rotated across repeats.
#
# Result 1 -- cost of KEEPING the pre-lock ORDER BY, as a share of the pre-lock:
#
#   workload            scope 100   scope 1000   scope 10000
#   nonkey     (mis)       20.0%       34.9%        56.0%
#   window     (mis)       45.5%       63.7%        69.2%
#   timerange  (mis)       45.3%(200)  63.8%(2000)    --
#   projection (aligned)    6.5%        3.7%        10.5%
#
# So it is not free when aligned -- 4-26%, mean 10% -- it is INVISIBLE, because
# the pre-lock is only 12-15% of a refresh.  And the misaligned penalty is
# 1.2-1.7x, not the 3.6x that was written down.
#
# Result 2 -- the two clauses pull opposite ways, which measuring them together
# hid.  Against a baseline of keeping both:
#
#   workload    scope    drop pre-lock   drop source   drop both
#   nonkey       1000        +3.3%          -2.3%        +3.5%
#   nonkey      10000        +9.4%          +5.9%       +10.6%
#   window       1000        +0.4%          -4.8%        +0.1%
#   window      10000        +4.6%          +1.8%        +4.3%
#   timerange    2000        +3.2%          -4.8%        -1.9%
#   projection  10000        +1.2%          -1.9%        -1.7%
#
# Dropping the SOURCE ordering is a regression below scope 10000: it hands
# INSERT ... ON CONFLICT its rows in random index order and index maintenance
# pays for it.  "Drop both ORDER BYs" was one saving and one regression partly
# cancelling.  The specialisation is "drop the pre-lock's", alone.
#
# And it is gated on the LOCK LEVEL, not on index alignment -- see SPECIALIZE.md
# section 4.  Under ExclusiveLock (the bare WHERE form) no second refresh can be
# running, so the ordering has no deadlock role; under RowExclusiveLock (the
# CONCURRENTLY form) the same elision is a deadlock generator.  The saving is
# available exactly where it cannot be taken without the lock.
#
set -e

P=${PGBIN:-/home/user/pgsql-opt/bin}/psql
Q="$P -p ${PGPORT:-5610} -d ${PGDATABASE:-postgres} -X -q -At"

$Q -c "CREATE TABLE IF NOT EXISTS obres(
         run_at timestamptz DEFAULT now(), workload text, aligned bool,
         span int, scope bigint, form text, iters int, us numeric,
         server_start timestamptz DEFAULT pg_postmaster_start_time())"
$Q -c "TRUNCATE obres"

# The pre-lock, with the ORDER BY optional.
$Q -c "CREATE OR REPLACE FUNCTION ob_lock(p_pred text, p_order bool)
       RETURNS text LANGUAGE plpgsql AS \$fn\$
       DECLARE mvoid oid := 'bench.mvt'::regclass; idx pg_index; keycols text;
       BEGIN
         SELECT * INTO idx FROM pg_index
          WHERE indrelid = mvoid AND indisunique AND indisvalid
          ORDER BY indisprimary DESC, indexrelid LIMIT 1;
         SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord) INTO keycols
           FROM unnest(idx.indkey[0:idx.indnkeyatts-1]) WITH ORDINALITY k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = mvoid AND a.attnum = k.attnum;
         RETURN format('SELECT 1 FROM bench.mvt mv WHERE (%s)%s FOR NO KEY UPDATE',
                       p_pred,
                       CASE WHEN p_order THEN ' ORDER BY ' || keycols ELSE '' END);
       END \$fn\$" >/dev/null

# The fused statement, row comparison on, with the source ORDER BY optional.
$Q -c "CREATE OR REPLACE FUNCTION ob_stmt(p_pred text, p_order bool)
       RETURNS text LANGUAGE plpgsql AS \$fn\$
       DECLARE
         mvoid oid := 'bench.mvt'::regclass; idx pg_index; viewsql text;
         keycols text; setclause text; mvcols text; exccols text;
         joinclause text; antiop text; conflict text; ord text;
       BEGIN
         SELECT * INTO idx FROM pg_index
          WHERE indrelid = mvoid AND indisunique AND indisvalid
          ORDER BY indisprimary DESC, indexrelid LIMIT 1;
         antiop := CASE WHEN idx.indnullsnotdistinct
                        THEN 'IS NOT DISTINCT FROM' ELSE '=' END;
         viewsql := rtrim(btrim(pg_get_viewdef('bench.mv'::regclass)), ';');
         SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord),
                string_agg('nd.' || quote_ident(a.attname) || ' ' || antiop ||
                           ' mv.' || quote_ident(a.attname), ' AND ' ORDER BY k.ord)
           INTO keycols, joinclause
           FROM unnest(idx.indkey[0:idx.indnkeyatts-1]) WITH ORDINALITY k(attnum, ord)
           JOIN pg_attribute a ON a.attrelid = mvoid AND a.attnum = k.attnum;
         SELECT string_agg(quote_ident(a.attname) || ' = EXCLUDED.' ||
                           quote_ident(a.attname), ', ' ORDER BY a.attnum),
                string_agg('mvt.' || quote_ident(a.attname), ', ' ORDER BY a.attnum),
                string_agg('EXCLUDED.' || quote_ident(a.attname), ', ' ORDER BY a.attnum)
           INTO setclause, mvcols, exccols
           FROM pg_attribute a
          WHERE a.attrelid = mvoid AND a.attnum > 0 AND NOT a.attisdropped
            AND NOT (a.attnum = ANY (idx.indkey[0:idx.indnkeyatts-1]));
         conflict := CASE WHEN setclause IS NULL THEN 'NOTHING'
                     ELSE format('UPDATE SET %s WHERE (%s) IS DISTINCT FROM (%s)',
                                 setclause, mvcols, exccols) END;
         ord := CASE WHEN p_order THEN ' ORDER BY ' || keycols ELSE '' END;
         RETURN format('WITH new_data AS MATERIALIZED ( '
                       '  SELECT * FROM (%s) mv WHERE (%s)%s '
                       '), upsert AS ( '
                       '  INSERT INTO bench.mvt SELECT * FROM new_data '
                       '  ON CONFLICT (%s) DO %s RETURNING 1 ) '
                       ', pruned AS ( DELETE FROM bench.mvt mv WHERE (%s) '
                       '   AND NOT EXISTS ( SELECT 1 FROM new_data nd WHERE %s ) '
                       '   RETURNING 1 ) '
                       'SELECT (SELECT pg_catalog.count(*) FROM upsert) '
                       '     + (SELECT pg_catalog.count(*) FROM pruned)',
                       viewsql, p_pred, ord, keycols, conflict, p_pred, joinclause);
       END \$fn\$" >/dev/null

# Time one form, best of n, after warm-ups.  p_full selects lock-only vs
# lock+DML; the lock always runs in the full form because dropping it is a
# separate question that 3e answers with 45 lost updates.
$Q -c "CREATE OR REPLACE FUNCTION ob_time(p_pred text, p_order bool,
                                          p_full bool, n int)
       RETURNS numeric LANGUAGE plpgsql AS \$fn\$
       DECLARE lk text := ob_lock(p_pred, p_order);
               dm text := ob_stmt(p_pred, p_order);
               t0 timestamptz; best numeric := NULL; us numeric; i int;
       BEGIN
         FOR i IN 1..3 LOOP
           EXECUTE lk; IF p_full THEN EXECUTE dm; END IF;
         END LOOP;
         FOR i IN 1..n LOOP
           t0 := clock_timestamp();
           EXECUTE lk;
           IF p_full THEN EXECUTE dm; END IF;
           us := extract(epoch FROM clock_timestamp()-t0)*1e6;
           IF best IS NULL OR us < best THEN best := us; END IF;
         END LOOP;
         RETURN round(best,1);
       END \$fn\$" >/dev/null

cell() {                        # workload aligned span
  w=$1; al=$2; span=$3
  if [ "$span" = 1 ]; then
    pred=$($Q -c "SELECT replace(pred1,':k','1') FROM bench_workload WHERE id='$w'")
  else
    pred=$($Q -c "SELECT replace(replace(predr,':k','1'),':span','$span')
                    FROM bench_workload WHERE id='$w'")
  fi
  scope=$($Q -c "SELECT count(*) FROM bench.mv WHERE $pred" 2>/dev/null || echo 0)
  [ "$scope" = 0 ] && return
  mv=$($Q -c "SELECT count(*) FROM bench.mv")
  [ $(( scope * 100 / mv )) -ge 90 ] && return

  # One budget for the whole cell, from the slowest form (full + ORDER BY).
  $Q -c "SELECT mut_clone()" >/dev/null
  probe=$($Q -c "SELECT ob_time(\$\$$pred\$\$, true, true, 3)")
  it=$($Q -c "SELECT GREATEST(8, LEAST(60, (1000000/GREATEST($probe,1))::int))")

  for rep in 1 2 3; do
    if [ $((rep % 2)) -eq 1 ]; then ords="true false"; else ords="false true"; fi
    for ord in $ords; do
      for full in false true; do
        case "$ord$full" in
          truefalse)  form=lock_ord   ;; falsefalse) form=lock_noord ;;
          truetrue)   form=full_ord   ;; falsetrue)  form=full_noord ;;
        esac
        $Q -c "SELECT mut_clone()" >/dev/null
        $Q -c "INSERT INTO obres(workload,aligned,span,scope,form,iters,us)
               SELECT '$w',$al,$span,$scope,'$form',$it,
                      ob_time(\$\$$pred\$\$, $ord, $full, $it)" >/dev/null
      done
    done
  done
  echo "  $w span=$span scope=$scope iters=$it"
}

run() {                         # workload aligned spans...
  w=$1; al=$2; shift 2
  $Q -c "SELECT bench_setup('$w', 100000, 1000)" >/dev/null
  for s in "$@"; do cell "$w" "$al" "$s"; done
}

run projection true  1 10 100 1000 10000
run expensive  true  1 10 100 1000
run aggregate  true  1 10 100
run nonkey     false 1 10 100
run window     false 1 10 100
run timerange  false 1 10 100
# ---- phase 2: the two clauses separately, on the cells where phase 1 was
# ---- largest, because measuring them together is what hid the cancellation.
$Q -c "CREATE TABLE IF NOT EXISTS obsplit(
         run_at timestamptz DEFAULT now(), workload text, aligned bool,
         scope bigint, lock_ord bool, src_ord bool, us numeric,
         server_start timestamptz DEFAULT pg_postmaster_start_time())" >/dev/null
$Q -c "TRUNCATE obsplit" >/dev/null

$Q -c "CREATE OR REPLACE FUNCTION ob_time2(p_pred text, p_lock_ord bool,
                                           p_src_ord bool, n int)
       RETURNS numeric LANGUAGE plpgsql AS \$fn\$
       DECLARE lk text := ob_lock(p_pred, p_lock_ord);
               dm text := ob_stmt(p_pred, p_src_ord);
               t0 timestamptz; best numeric := NULL; us numeric; i int;
       BEGIN
         FOR i IN 1..3 LOOP EXECUTE lk; EXECUTE dm; END LOOP;
         FOR i IN 1..n LOOP
           t0 := clock_timestamp();
           EXECUTE lk; EXECUTE dm;
           us := extract(epoch FROM clock_timestamp()-t0)*1e6;
           IF best IS NULL OR us < best THEN best := us; END IF;
         END LOOP;
         RETURN round(best,1);
       END \$fn\$" >/dev/null

split_cell() {                  # workload aligned span
  w=$1; al=$2; span=$3
  pred=$($Q -c "SELECT replace(replace(predr,':k','1'),':span','$span')
                  FROM bench_workload WHERE id='$w'")
  scope=$($Q -c "SELECT count(*) FROM bench.mv WHERE $pred")
  $Q -c "SELECT mut_clone()" >/dev/null
  probe=$($Q -c "SELECT ob_time2(\$\$$pred\$\$, true, true, 3)")
  it=$($Q -c "SELECT GREATEST(8, LEAST(40, (1000000/GREATEST($probe,1))::int))")
  for rep in 1 2 3; do
    # rotated, so a form's position in the run cannot become its signal
    case $rep in
      1) combos="tt tf ft ff" ;;
      2) combos="ff ft tf tt" ;;
      3) combos="tf tt ff ft" ;;
    esac
    for c in $combos; do
      case $c in
        tt) lo=true;  so=true  ;; tf) lo=true;  so=false ;;
        ft) lo=false; so=true  ;; ff) lo=false; so=false ;;
      esac
      $Q -c "SELECT mut_clone()" >/dev/null
      $Q -c "INSERT INTO obsplit(workload,aligned,scope,lock_ord,src_ord,us)
             SELECT '$w',$al,$scope,$lo,$so,
                    ob_time2(\$\$$pred\$\$, $lo, $so, $it)" >/dev/null
    done
  done
  echo "  split $w scope=$scope iters=$it"
}

for w in nonkey window; do
  $Q -c "SELECT bench_setup('$w', 100000, 1000)" >/dev/null
  split_cell "$w" false 100
  split_cell "$w" false 10
done
$Q -c "SELECT bench_setup('timerange', 100000, 1000)" >/dev/null
split_cell timerange false 10
$Q -c "SELECT bench_setup('projection', 100000, 1000)" >/dev/null
split_cell projection true 10000

$P -p ${PGPORT:-5610} -d ${PGDATABASE:-postgres} -X -q -P border=2 -c "
  WITH b AS (SELECT workload, aligned, scope, lock_ord, src_ord, min(us) us
               FROM obsplit GROUP BY 1,2,3,4,5),
  p AS (SELECT workload, aligned, scope,
          max(us) FILTER (WHERE lock_ord AND src_ord)         AS keep2,
          max(us) FILTER (WHERE lock_ord AND NOT src_ord)     AS nosrc,
          max(us) FILTER (WHERE NOT lock_ord AND src_ord)     AS nolock,
          max(us) FILTER (WHERE NOT lock_ord AND NOT src_ord) AS none2
        FROM b GROUP BY 1,2,3)
  SELECT CASE WHEN aligned THEN 'aligned' ELSE 'MISALIGNED' END AS shape,
         workload, scope, keep2 AS baseline_us,
         round(100*(1 - nolock/keep2),1) AS drop_prelock_ob,
         round(100*(1 - nosrc/keep2),1)  AS drop_source_ob,
         round(100*(1 - none2/keep2),1)  AS drop_both_ob
    FROM p ORDER BY aligned, workload, scope"
echo "===== ORDERBY DONE ====="
