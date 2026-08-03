#!/bin/sh
#
# Does parameterising the predicate cost plan quality on a skewed column?
#
#   ./predskew.sh [rounds] [n]        default: 5 rounds, 100 refreshes each
#
# Every workload in workloads.sql has uniformly distributed keys, so every cell
# in every sweep measures the case where a generic plan and a value-specific one
# are the same plan.  That is the case parameterisation cannot lose.
#
# The case it can lose is the standard prepared-statement one: a column where
# one key selects a large fraction of the table and another selects a handful.
# Before parameterisation two such refreshes never shared anything -- the cache
# is keyed on the deparsed predicate, so "tenant = 1" and "tenant = 500" were
# different statements and each was planned afresh with its own literal in
# view.  Afterwards they are one statement with different values, they share one
# plansource, and plancache decides between a plan built for whichever values
# arrived and a generic one built blind.
#
# The reasoning says this is safe: PARAM_FLAG_CONST lets eval_const_expressions
# fold the values back in, so a custom plan is exactly the plan the literal got,
# and choose_custom_plan() compares costs and should stay on custom when the
# generic estimate is bad.  Reasoning is what RESULTS.md X1 and X2 were, so
# measure it.
#
# The shape of the measurement is the hazard stated directly:
#
#   rare_cold    a fresh session refreshes the RARE key repeatedly
#   rare_warm    a session refreshes the COMMON key first, letting plancache
#                settle on whatever that shape deserves, and only then
#                refreshes the rare key
#
# If a plan chosen for the common key is being reused for the rare one,
# rare_warm is slower than rare_cold.  Under mutations.py C5 -- parameterisation
# off -- the two must be indistinguishable, because the two predicates cannot
# share a plan at all.  Run it both ways; one number alone says nothing.
#
# Fresh sessions matter here and nowhere else in this directory: the plansource
# lives in the session, so warm and cold have to be different backends or the
# second inherits the first's decision.
#
# The row comparison is ON throughout, so a common-key refresh reads 10,000 rows
# and writes none of them.  Without it the warm-up rewrites the scope on every
# pass and the timed phase measures the bloat that left rather than the plan.
#
set -e

ROUNDS=${1:-5}
N=${2:-100}
PORT=${PORT:-5610}
DB=${DB:-postgres}
BINDIR=${BINDIR:-/home/user/pgsql-opt/bin}
SCALE=${SCALE:-100000}
COMMON_ROWS=${COMMON_ROWS:-10000}   # rows under the common key
WARM=${WARM:-12}                    # common-key refreshes before the timed run

PGOPTIONS="-c synchronous_commit=off"; export PGOPTIONS
PSQL="$BINDIR/psql -p $PORT -d $DB -q -X -v ON_ERROR_STOP=1"

T=/tmp/predskew.$$
mkdir -p "$T"; chmod 777 "$T"
trap 'rm -rf "$T"' EXIT

echo "predskew: scale=$SCALE common=$COMMON_ROWS rounds=$ROUNDS n=$N"
$PSQL -Atc "SHOW debug_assertions" | sed 's/^/  assertions=/'

cat > "$T/setup.sql" <<SQL
DROP MATERIALIZED VIEW IF EXISTS skew_mv;
DROP TABLE IF EXISTS skew_base;
CREATE TABLE skew_base(id bigint primary key, tenant int, amt numeric);
-- tenant 1 holds COMMON_ROWS rows; every other tenant holds about ten.
INSERT INTO skew_base
SELECT g,
       CASE WHEN g <= $COMMON_ROWS THEN 1
            ELSE 2 + ((g - $COMMON_ROWS) % 9000) END,
       (g % 500)::numeric
  FROM generate_series(1, $SCALE) g;
CREATE INDEX ON skew_base(tenant);
CREATE MATERIALIZED VIEW skew_mv AS SELECT id, tenant, amt FROM skew_base;
CREATE UNIQUE INDEX ON skew_mv(id);
CREATE INDEX ON skew_mv(tenant);
VACUUM (ANALYZE) skew_base;
VACUUM (ANALYZE) skew_mv;
CHECKPOINT;
SQL
$PSQL -f "$T/setup.sql"

RARE=$($PSQL -Atc "SELECT tenant FROM skew_base GROUP BY tenant
                    HAVING count(*) < 50 ORDER BY tenant LIMIT 1")
NCOMMON=$($PSQL -Atc "SELECT count(*) FROM skew_base WHERE tenant = 1")
NRARE=$($PSQL -Atc "SELECT count(*) FROM skew_base WHERE tenant = $RARE")
echo "  common key tenant=1 -> $NCOMMON rows;  rare key tenant=$RARE -> $NRARE rows"

# Timed phase: N refreshes of the rare key, nothing else.
{ echo "SET matview_partial_refresh_optimized = on;"
  i=0; while [ $i -lt "$N" ]; do
    echo "REFRESH MATERIALIZED VIEW CONCURRENTLY skew_mv WHERE tenant = $RARE;"
    i=$((i+1)); done; } > "$T/rare.sql"

# Warm phase, prepended: the common key first, so plancache settles on the shape
# that key deserves before the rare one is ever asked for.
{ echo "SET matview_partial_refresh_optimized = on;"
  i=0; while [ $i -lt "$WARM" ]; do
    echo "REFRESH MATERIALIZED VIEW CONCURRENTLY skew_mv WHERE tenant = 1;"
    i=$((i+1)); done; } > "$T/warmup.sql"
cat "$T/warmup.sql" "$T/rare.sql" > "$T/warm.sql"

echo "SELECT 1;" > "$T/empty.sql"
ms() { date +%s%N; }

SETUP=0
i=0; while [ $i -lt 5 ]; do
  s=$(ms); $PSQL -f "$T/empty.sql" >/dev/null; e=$(ms)
  d=$(( (e - s) / 1000 )); [ "$SETUP" = 0 ] && SETUP=$d
  [ "$d" -lt "$SETUP" ] && SETUP=$d; i=$((i+1)); done

# The warm arm's own warm-up has to come off its clock, so time it separately
# in a session that then exits -- and measure the cost of WARM common-key
# refreshes on their own, to subtract.
WARMCOST=0
i=0; while [ $i -lt 3 ]; do
  s=$(ms); $PSQL -f "$T/warmup.sql" >/dev/null; e=$(ms)
  d=$(( (e - s) / 1000 - SETUP ))
  [ "$WARMCOST" = 0 ] && WARMCOST=$d
  [ "$d" -lt "$WARMCOST" ] && WARMCOST=$d
  i=$((i+1)); done
echo "  session setup ${SETUP} us;  warm-up block ${WARMCOST} us (min of 3), both subtracted"

: > "$T/results"
r=1
while [ $r -le "$ROUNDS" ]; do
  # Alternate which arm goes first so position is not confounded with the arm.
  if [ $((r % 2)) -eq 1 ]; then ORDER="cold warm"; else ORDER="warm cold"; fi
  for arm in $ORDER; do
    case "$arm" in
      cold) f="$T/rare.sql"; sub=$SETUP ;;
      warm) f="$T/warm.sql"; sub=$((SETUP + WARMCOST)) ;;
    esac
    s=$(ms); $PSQL -f "$f" >/dev/null; e=$(ms)
    us=$(( ((e - s) / 1000 - sub) / N ))
    printf '%s %s %s\n' "$r" "$arm" "$us" >> "$T/results"
    printf '  round %s  %-4s %7s us per rare-key refresh\n' "$r" "$arm" "$us"
  done
  r=$((r+1))
done

echo
awk '$1 > 1 { s[$2] += $3; n[$2]++ }
     END {
       for (a in s) m[a] = s[a]/n[a];
       printf "  rare key alone   %8.1f us\n", m["cold"];
       printf "  rare key after the common key %8.1f us\n", m["warm"];
       if (m["cold"] > 0)
         printf "  warm/cold = %.2fx   (>1 means the common key%s plan is being reused)\n",
                m["warm"] / m["cold"], "'"'"'s";
     }' "$T/results"
