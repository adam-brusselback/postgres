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
# Timing is psql's own \timing, summed over the rare-key statements only, and
# that is not a detail.  The first version of this script wall-clocked the whole
# warm arm and subtracted a separately measured warm-up block -- 374 ms of
# common-key refreshes against 28 ms of rare-key ones.  A ten percent swing in
# the block it subtracted landed as ~370 us per rare refresh, which is larger
# than the entire effect, and the warm arm duly read 160, 206, 407 and 796 us
# across four rounds with its minimum BELOW the cold arm's.  It reported 1.40x
# and meant nothing.  Timing the statements themselves removes the subtraction
# and the variance with it.
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

# Both arms are one psql script each, with \timing on and a marker before the
# rare-key block.  Only the statements after the marker are summed, so the
# warm-up costs whatever it costs and never enters the number.
#
# printf rather than echo, and it is not style: /bin/sh here is dash, whose echo
# expands backslash escapes with no -e asked for.  "echo '\timing on'" emitted a
# TAB followed by "iming on", psql reported a syntax error on line 1, and every
# arm came back "MISMATCH 0 of 100" -- which reads as an instrument that ran and
# found nothing rather than one that never started.  Same shape as the psql:FILE:
# prefix that made the fuzzer's wrong-plan counter unable to match (RESULTS.md
# X12).
mkscript() {
  out=$1; warm=$2
  { printf '%s\n' '\timing on'
    printf '%s\n' "SET matview_partial_refresh_optimized = on;"
    if [ "$warm" = yes ]; then
      i=0; while [ $i -lt "$WARM" ]; do
        printf '%s\n' "REFRESH MATERIALIZED VIEW CONCURRENTLY skew_mv WHERE tenant = 1;"
        i=$((i+1)); done
    fi
    printf '%s\n' '\echo RARE_BEGIN'
    i=0; while [ $i -lt "$N" ]; do
      printf '%s\n' "REFRESH MATERIALIZED VIEW CONCURRENTLY skew_mv WHERE tenant = $RARE;"
      i=$((i+1)); done
  } > "$out"
}
mkscript "$T/cold.sql" no
mkscript "$T/warm.sql" yes

# Sum the "Time: N ms" lines after the marker.  psql prints one per statement.
timed() {
  $PSQL -f "$1" 2>&1 |
    awk -v n="$N" '
      /^RARE_BEGIN$/ { on = 1; next }
      on && /^Time: / { gsub(/[^0-9.]/, "", $2); t += $2; c++ }
      END { if (c != n) { printf "MISMATCH %d of %d\n", c, n > "/dev/stderr"; exit 1 }
            printf "%d\n", (t * 1000) / n }'
}

: > "$T/results"
r=1
while [ $r -le "$ROUNDS" ]; do
  # Alternate which arm goes first so position is not confounded with the arm.
  if [ $((r % 2)) -eq 1 ]; then ORDER="cold warm"; else ORDER="warm cold"; fi
  for arm in $ORDER; do
    us=$(timed "$T/$arm.sql") || { echo "  round $r $arm: timing lines did not match" >&2; continue; }
    printf '%s %s %s\n' "$r" "$arm" "$us" >> "$T/results"
    printf '  round %s  %-4s %7s us per rare-key refresh\n' "$r" "$arm" "$us"
  done
  r=$((r+1))
done

echo
awk '$1 > 1 { s[$2] += $3; n[$2]++;
              if (!($2 in lo) || $3 < lo[$2]) lo[$2] = $3;
              if ($3 > hi[$2]) hi[$2] = $3 }
     END {
       for (a in s) m[a] = s[a]/n[a];
       printf "  %-34s %8s %8s %8s %5s\n", "", "mean", "min", "max", "n";
       printf "  %-34s %8.1f %8d %8d %5d\n", "rare key alone", m["cold"], lo["cold"], hi["cold"], n["cold"];
       printf "  %-34s %8.1f %8d %8d %5d\n", "rare key after the common key", m["warm"], lo["warm"], hi["warm"], n["warm"];
       if (m["cold"] > 0)
         printf "\n  warm/cold = %.2fx\n", m["warm"] / m["cold"];
       print "";
       print "  >1 means a plan chosen for the common key is being reused for the";
       print "  rare one.  Read it against the min/max spread, and against the same";
       print "  script run under mutations.py C5, where the two predicates cannot";
       print "  share a plan at all and the ratio must be 1.";
     }' "$T/results"
