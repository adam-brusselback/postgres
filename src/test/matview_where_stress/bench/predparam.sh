#!/bin/sh
#
# What does parameterising the predicate's constants buy, and what does the
# EXECUTE wrapper cost?
#
#   ./predparam.sh [rounds] [n]        default: 4 rounds, 300 refreshes each
#
# PLAN.md 3.2 sizes the plan-cache miss at 8x -- 546 us for a varying literal
# against 67 us for a bound parameter -- and RESULTS.md R15 records it.  Both
# figures come from one protocol, and R36's end-to-end recheck read 1.81x on a
# single unalternated pgbench pair and could not be reconciled with it.  This
# script exists to settle the size on the build in front of it, and to separate
# two things the `--predmode param` axis in run.sh necessarily conflates.
#
# REFRESH takes no parameters directly, so binding one means going through
# EXECUTE ... USING in a DO block.  That wrapper is not free: a DO block is
# parsed, plpgsql compiles an anonymous function, and EXECUTE parses the
# statement text again.  run.sh's param arm pays all of it and its literal arm
# pays none, so the axis measures (parameterisation - wrapper) and reports it as
# parameterisation.  Four arms separate them:
#
#   lit     bare REFRESH, k varies        today: the cache key is the deparsed
#                                         predicate text, so every k misses
#   wrap    DO/EXECUTE, k interpolated    still misses; the difference from lit
#                                         is the wrapper alone
#   param   DO/EXECUTE, $1 bound          hits: pg_get_expr renders the Param as
#                                         "$1" and the key is the same for
#                                         every k
#   const   bare REFRESH, k = 1 fixed     hits, and is the number 3.2 quotes at
#                                         72 us -- but it re-refreshes one hot
#                                         row 300 times, so it carries a data
#                                         locality advantage the others do not.
#                                         Read it as a floor, not as the target
#
# So:  wrap - lit    = the wrapper's cost
#      param - wrap  = what parameterising the constant is worth, cleanly
#      param - lit   = what run.sh --predmode reports
#
# Protocol notes, each of which this directory has been bitten by:
#
#   No VACUUM between timed blocks.  vac_update_relstats() updates pg_class in
#   place, which implies a relcache invalidation, so vacuuming before a timed
#   block drops the plan cache before the block -- converting the warm cell into
#   the cold one on a measurement that is entirely about the plan cache.
#   RESULTS.md X11.  Settle once, before the first block, and not again.
#
#   Arms alternate and the order rotates each round, so position within the run
#   cannot be read as an effect of the arm.
#
#   Round 1 of each arm is discarded: it carries the cold prepare.
#
#   Session setup is measured and subtracted.  What remains still includes the
#   client round trip and one commit per refresh, identically in every arm, so
#   the DIFFERENCES are clean while the absolutes are end-to-end rather than
#   the in-backend figures 3.2 quotes.
#
#   synchronous_commit off, which is run.sh's default and for its reason: every
#   statement here is its own transaction, so with it on each refresh carries a
#   WAL flush of about a millisecond.  The flush is identical in all four arms,
#   so it leaves the differences alone -- but it lands on the denominator of
#   every ratio, and the first run of this script reported 1.26x for an effect
#   that is 2.0x without it.  Set SYNC=on deliberately if the commit is what is
#   being measured.
#
set -e

ROUNDS=${1:-4}
N=${2:-300}
PORT=${PORT:-5610}
DB=${DB:-postgres}
BINDIR=${BINDIR:-/home/user/pgsql-opt/bin}
SYNC=${SYNC:-off}
PCM=${PCM:-auto}
PGOPTIONS="-c synchronous_commit=$SYNC -c plan_cache_mode=$PCM"; export PGOPTIONS
PSQL="$BINDIR/psql -p $PORT -d $DB -q -X -v ON_ERROR_STOP=1"

T=/tmp/predparam.$$
mkdir -p "$T"
chmod 777 "$T"
trap 'rm -rf "$T"' EXIT

MV=${MV:-bench.mv}
KEYCOL=${KEYCOL:-id}
KEYMAX=${KEYMAX:-100000}
SHAPE=${SHAPE:-key}
SPAN=${SPAN:-1}

echo "predparam: $MV shape=$SHAPE span=$SPAN plan_cache_mode=$PCM"
echo "           rounds=$ROUNDS n=$N port=$PORT"
$PSQL -Atc "SELECT version()"
$PSQL -Atc "SHOW debug_assertions" | sed 's/^/  assertions=/'
$PSQL -Atc "SHOW synchronous_commit" | sed 's/^/  synchronous_commit=/'

# Build one statement file per arm.  Keys are drawn from a fixed arithmetic
# sequence rather than at random: every arm must touch the same rows in the same
# order, or the comparison carries a data-distribution difference as well.
#
# The three shapes are workloads.sql's, spelled the same way, so a figure here
# can be set beside a run.sh cell.  In the param arm the key becomes $1 and
# everything derived from it stays an expression over $1 -- ARRAY[$1+0,$1+1,...]
# rather than a bound array -- which is what a caller who binds one value and
# builds the rest around it writes, and what run.sh's param mode produces.
awk -v n="$N" -v mv="$MV" -v kc="$KEYCOL" -v km="$KEYMAX" \
    -v shape="$SHAPE" -v span="$SPAN" '
function pred(kexpr,   i, s) {
  if (shape == "key")   return sprintf("%s = %s", kc, kexpr);
  if (shape == "range") return sprintf("%s BETWEEN %s AND (%s) + %d", kc, kexpr, kexpr, span - 1);
  s = "";
  for (i = 0; i < span; i++) s = s (i ? "," : "") "(" kexpr ") + " i;
  return sprintf("%s = ANY(ARRAY[%s])", kc, s);
}
BEGIN {
  q = sprintf("%c", 39);
  step = int(km / n); if (step < 1) step = 1;
  for (i = 0; i < n; i++) {
    k = 1 + (i * step) % km;
    stmt = sprintf("REFRESH MATERIALIZED VIEW CONCURRENTLY %s WHERE ", mv);
    printf "%s%s;\n", stmt, pred(k)                            > "'"$T"'/lit.sql";
    printf "DO $pp$ BEGIN EXECUTE %s%s%s%s; END $pp$;\n",
           q, stmt, pred(k), q                                 > "'"$T"'/wrap.sql";
    printf "DO $pp$ BEGIN EXECUTE %s%s%s%s USING %d; END $pp$;\n",
           q, stmt, pred("$1"), q, k                           > "'"$T"'/param.sql";
    printf "%s%s;\n", stmt, pred(1)                            > "'"$T"'/const.sql";
  }
}'
head -1 "$T/lit.sql"   | sed 's/^/  lit  : /'
head -1 "$T/param.sql" | sed 's/^/  param: /'
echo "SELECT 1;" > "$T/empty.sql"

# Reclaim what earlier work left, once, before anything is timed.
$PSQL -c "VACUUM (ANALYZE) $MV" >/dev/null
$PSQL -c "CHECKPOINT" >/dev/null

ms() { date +%s%N; }

# Session setup, measured rather than assumed: it is charged to whichever arm
# runs, and at n=300 a 10 ms connect is 33 us per refresh -- the size of the
# effect being measured.
SETUP=0
i=0; while [ $i -lt 5 ]; do
  s=$(ms); $PSQL -f "$T/empty.sql" >/dev/null; e=$(ms)
  d=$(( (e - s) / 1000 ))
  [ "$SETUP" = 0 ] && SETUP=$d
  [ "$d" -lt "$SETUP" ] && SETUP=$d
  i=$((i+1))
done
echo "  session setup: ${SETUP} us (min of 5), subtracted from every block"

: > "$T/results"

r=1
while [ $r -le "$ROUNDS" ]; do
  # rotate the order so position in the run is not confounded with the arm
  case $(( r % 4 )) in
    1) ORDER="lit wrap param const" ;;
    2) ORDER="wrap param const lit" ;;
    3) ORDER="param const lit wrap" ;;
    0) ORDER="const lit wrap param" ;;
  esac
  for arm in $ORDER; do
    s=$(ms)
    $PSQL -f "$T/$arm.sql" >/dev/null
    e=$(ms)
    us=$(( ((e - s) / 1000 - SETUP) / N ))
    printf '%s %s %s\n' "$r" "$arm" "$us" >> "$T/results"
    printf '  round %s  %-6s %6s us/refresh\n' "$r" "$arm" "$us"
  done
  r=$((r+1))
done

echo
echo "per refresh, us -- round 1 discarded (cold prepare)"
awk '$1 > 1 { s[$2] += $3; n[$2]++; if (!($2 in lo) || $3 < lo[$2]) lo[$2] = $3;
              if ($3 > hi[$2]) hi[$2] = $3 }
     END {
       printf "  %-6s %8s %8s %8s %6s\n", "arm", "mean", "min", "max", "n";
       split("lit wrap param const", o, " ");
       for (i = 1; i <= 4; i++) { a = o[i]; if (!(a in n)) continue;
         printf "  %-6s %8.1f %8d %8d %6d\n", a, s[a]/n[a], lo[a], hi[a], n[a];
         m[a] = s[a]/n[a] }
       printf "\n";
       if (("lit" in m) && ("wrap" in m))
         printf "  wrapper cost        wrap - lit   = %+8.1f us\n", m["wrap"] - m["lit"];
       if (("wrap" in m) && ("param" in m))
         printf "  parameterisation    param - wrap = %+8.1f us   (%.2fx)\n",
                m["param"] - m["wrap"], m["wrap"] / m["param"];
       if (("lit" in m) && ("param" in m))
         printf "  what --predmode sees  param - lit = %+8.1f us   (%.2fx)\n",
                m["param"] - m["lit"], m["lit"] / m["param"];
       if (("lit" in m) && ("const" in m))
         printf "  hit floor, one hot row  const/lit = %.2fx\n", m["lit"] / m["const"];
     }' "$T/results"
