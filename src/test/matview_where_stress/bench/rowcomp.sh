#!/bin/sh
#
# Where does the row comparison start paying, and does it need a covering index?
#
#   ./rowcomp.sh [rounds] [n]        default: 6 rounds, 40 refreshes each
#   SPAN=100 COVER=off ./rowcomp.sh 12 300
#
# The comparison -- WHERE (mv.cols) IS DISTINCT FROM (EXCLUDED.cols) on the
# upsert's DO UPDATE -- is reachable today only through a DEVELOPER_OPTIONS GUC
# that boots false, so no user gets any of it.  Replacing that GUC with a
# decision the server makes needs two things this script measures: the scope at
# which the comparison starts paying, and whether "no index over a written
# column" is the veto SPECIALIZE.md 1 says it is.
#
#   cmp     matview_partial_refresh_optimized = on   (skip unchanged rows)
#   plain   matview_partial_refresh_optimized = off  (rewrite every matched row)
#
# Arms alternate across whole SESSIONS, not within one, and that is not a
# stylistic choice: the flag is part of the plan cache key, so flipping it
# mid-session rebuilds the plans and every band would carry a cold prepare.
# Each block is its own psql invocation with the SET at the top.
#
# THE CELL IS THE FAVOURABLE END AND SAYS SO.  Nothing is mutated between
# refreshes, so the comparison arm writes nothing and the plain arm rewrites the
# whole scope every time.  That is a drain catching up on a scope it is already
# level with -- real, and the maximum.  The other direction is the churn curve,
# which already exists (bench/churn.sql): the comparison degrades to about zero
# by 100% churn, break-even 60-70%.
#
# And the denominator is the fragile half, which is why the heap is settled once
# before the first block and not touched again: at zero churn only the plain arm
# writes, so free space, full-page images, extension and bloat all land on one
# side of the ratio.  A VACUUM between timed blocks would hand the writing arm a
# fresh heap every time and inflate the result.
#
# Protocol otherwise as bench/predparam.sh: no VACUUM between timed blocks,
# order rotated each round, round 1 discarded, session setup subtracted,
# synchronous_commit off.  Quote the median; this cell produces excursions.
set -e

ROUNDS=${1:-6}
N=${2:-40}
PORT=${PORT:-5610}
DB=${DB:-postgres}
BINDIR=${BINDIR:-/home/user/pgsql-opt/bin}
RUNAS=${RUNAS:-pgtest}
SYNC=${SYNC:-off}
SCALE=${SCALE:-100000}
SPAN=${SPAN:-1000}
OPT=${OPT:-on}
LABEL=${LABEL:-pristine}
# COVER=off drops the index over a written column.  The comparison is measured
# at "no effect at all" there, and that claim is what a static veto would rest
# on, so it needs checking on the code in front of us rather than quoting.
COVER=${COVER:-on}
# CHURN is the percentage of the scope whose values really change before each
# timed refresh.  0 is the favourable end and was the only point the first
# version of this script measured -- one point, not a curve, and the point at
# which the comparison never fails.  The changed rows are the low ids of the
# scope, so the fraction is exact rather than sampled.
CHURN=${CHURN:-0}
# key    -- "id BETWEEN k AND k+SPAN-1", on the arbiter key.  Both elisions fire
#           for the bare arm: the predicate is key-only, so the prune is skipped,
#           and the pre-lock's ORDER BY goes with the lock level.  R10 says the
#           ordering is free here anyway -- the index scan already yields key
#           order and there is no Sort -- so this cell should read the prune
#           elision alone (R42) and is the check on that.
# nonkey -- "cust = k", on an indexed column that is NOT the arbiter key.  The
#           prune elision is gated on the predicate reading key columns only, so
#           it does NOT fire, and the difference between the two spellings is the
#           ORDER BY alone.  This is also R10's misaligned cell, where ordering
#           by the arbiter key hands LockRows the heap in random order.
PRED=${PRED:-key}
GROUPS=${GROUPS:-100}

PSQL="$BINDIR/psql -p $PORT -d $DB -q -X -v ON_ERROR_STOP=1"
export PGOPTIONS="-c synchronous_commit=$SYNC"

T=/tmp/rowcomp.$$
mkdir -p "$T"; chmod 777 "$T"
trap 'rm -rf "$T"' EXIT

run() { su "$RUNAS" -c "PGOPTIONS='$PGOPTIONS' $PSQL $*"; }

echo "rowcomp: label=$LABEL cover=$COVER churn=$CHURN% pred=$PRED span=$SPAN groups=$GROUPS scale=$SCALE optimized=$OPT"
echo "            rounds=$ROUNDS n=$N sync=$SYNC"
run -Atc "'SELECT setting FROM pg_config() WHERE name = '\''CONFIGURE'\''" 2>/dev/null || true
run -Atc "'SHOW debug_assertions'" | sed 's/^/  assertions=/'

# The fixture: a matview with a second index, so an avoided write costs index
# maintenance and an avoided scan is not the only thing in the ratio.
su "$RUNAS" -c "PGOPTIONS='$PGOPTIONS' $PSQL" <<SQL
DROP MATERIALIZED VIEW IF EXISTS pe_mv;
DROP TABLE IF EXISTS pe_ord;
CREATE TABLE pe_ord(id bigint primary key, cust int, status text);
INSERT INTO pe_ord
  SELECT g, g % $GROUPS, 'S' || (g % 5) FROM generate_series(1, $SCALE) g;
CREATE MATERIALIZED VIEW pe_mv AS SELECT id, cust, status FROM pe_ord;
CREATE UNIQUE INDEX ON pe_mv(id);
$([ "${COVER:-on}" = on ] && echo 'CREATE INDEX ON pe_mv(cust);')
VACUUM ANALYZE pe_ord;
VACUUM ANALYZE pe_mv;
SQL

# One statement file per arm.  Both walk the same keys in the same order, so
# the comparison carries no data-distribution difference.  The predicate is a
# range on the arbiter key: key-only, which the count rule is gated on.
awk -v n="$N" -v nrefresh="$N" -v span="$SPAN" -v scale="$SCALE" -v opt="$OPT" \
    -v pred="$PRED" -v groups="$GROUPS" -v churn="$CHURN" '
# Flips the sign of cust on the first churn% of the scope, so the value really
# does change on every refresh.  A no-op UPDATE would leave every comparison
# succeeding and measure churn 0 while claiming otherwise -- which is this
# suite recurring failure shape, so it is worth stating.  cust is indexed,
# so this pays the index maintenance a real change pays.
function churn_stmt(i,   k, n) {
  n = int(span * churn / 100); if (n < 1) n = 1;
  k = 1 + i * int((scale - span) / nrefresh);
  return sprintf("UPDATE pe_ord SET cust = -cust WHERE id BETWEEN %d AND %d;",
                 k, k + n - 1);
}
function predicate(i,   k) {
  if (pred == "nonkey") return sprintf("cust = %d", i % groups);
  k = 1 + i * int((scale - span) / nrefresh);
  return sprintf("id BETWEEN %d AND %d", k, k + span - 1);
}
BEGIN {
  printf "SET matview_partial_refresh_optimized = on;\n"  > "'"$T"'/cmp.sql";
  printf "SET matview_partial_refresh_optimized = off;\n" > "'"$T"'/plain.sql";
  for (i = 0; i < n; i++) {
    # The churn UPDATE sits INSIDE the timed block, identically in both arms, so
    # it cancels in the difference.  It is deliberately NOT subtracted: a large
    # separately measured block subtracted from a small measurement is how
    # predskew.sh once reported 1.40x from an arm whose minimum was below the
    # other arms.  So read the microseconds, and read the percentage knowing
    # its denominator carries the update as well as the refresh -- which makes
    # every churn > 0 percentage a LOWER bound on the effect.
    if (churn > 0) {
      printf "%s\n", churn_stmt(i)                     > "'"$T"'/cmp.sql";
      printf "%s\n", churn_stmt(i)                     > "'"$T"'/plain.sql";
    }
    printf "REFRESH MATERIALIZED VIEW pe_mv WHERE %s;\n",
           predicate(i)                                 > "'"$T"'/cmp.sql";
    printf "REFRESH MATERIALIZED VIEW pe_mv WHERE %s;\n",
           predicate(i)                                 > "'"$T"'/plain.sql";
  }
}'
echo "SELECT 1;" > "$T/empty.sql"
sed -n '2p' "$T/cmp.sql" | sed 's/^/  stmt: /'
chmod 644 "$T"/*.sql

# Settle once, before anything is timed, and not again.
run -c "'VACUUM (ANALYZE) pe_mv'" >/dev/null
run -c "'CHECKPOINT'" >/dev/null

ms() { date +%s%N; }

SETUP=0
i=0; while [ $i -lt 5 ]; do
  s=$(ms); run -f "$T/empty.sql" >/dev/null; e=$(ms)
  d=$(( (e - s) / 1000 ))
  [ "$SETUP" = 0 ] && SETUP=$d
  [ "$d" -lt "$SETUP" ] && SETUP=$d
  i=$((i+1))
done
echo "  session setup: ${SETUP} us (min of 5), subtracted from every block"

: > "$T/results"
r=1
while [ $r -le "$ROUNDS" ]; do
  if [ $(( r % 2 )) -eq 1 ]; then ORDER="cmp plain"; else ORDER="plain cmp"; fi
  for arm in $ORDER; do
    s=$(ms); run -f "$T/$arm.sql" >/dev/null; e=$(ms)
    us=$(( ((e - s) / 1000 - SETUP) / N ))
    printf '%s %s %s\n' "$r" "$arm" "$us" >> "$T/results"
    printf '  round %s  %-5s %8s us/refresh\n' "$r" "$arm" "$us"
  done
  r=$((r+1))
done

echo
echo "per refresh, us -- round 1 discarded"
awk -v churn="$CHURN" -v label="$LABEL" -v scope="$([ "$PRED" = nonkey ] && echo $((SCALE / GROUPS)) || echo $SPAN)" -v pred="$PRED" '
  $1 > 1 { s[$2] += $3; v[$2, n[$2]++] = $3;
           if (!($2 in lo) || $3 < lo[$2]) lo[$2] = $3;
           if ($3 > hi[$2]) hi[$2] = $3 }
  function median(a,   i, j, k, t, c, x) {
    c = n[a];
    for (i = 0; i < c; i++) x[i] = v[a, i];
    for (i = 1; i < c; i++) { t = x[i]; for (j = i - 1; j >= 0 && x[j] > t; j--) x[j+1] = x[j]; x[j+1] = t }
    return (c % 2) ? x[int(c/2)] : (x[c/2 - 1] + x[c/2]) / 2;
  }
  END {
    printf "  %-5s %10s %10s %10s %10s %6s\n", "arm", "median", "mean", "min", "max", "n";
    split("plain cmp", o, " ");
    for (i = 1; i <= 2; i++) { a = o[i]; if (!(a in n)) continue;
      md[a] = median(a);
      printf "  %-5s %10.1f %10.1f %10d %10d %6d\n",
             a, md[a], s[a]/n[a], lo[a], hi[a], n[a];
      m[a] = s[a]/n[a] }
    if (("plain" in m) && ("cmp" in m)) {
      printf "\n  %s %s/scope=%s/churn=%s%% -- row comparison against plain:\n", label, pred, scope, churn;
      printf "    median  %+8.1f us  %6.1f%%   <- quote this one\n",
             md["plain"] - md["cmp"], 100 * (md["plain"] - md["cmp"]) / md["plain"];
      printf "    mean    %+8.1f us  %6.1f%%\n",
             m["plain"] - m["cmp"], 100 * (m["plain"] - m["cmp"]) / m["plain"];
      printf "    minima  %+8.1f us  %6.1f%%\n",
             lo["plain"] - lo["cmp"], 100 * (lo["plain"] - lo["cmp"]) / lo["plain"];
      printf "  A mean over this many bands is not robust to one excursion and\n";
      printf "  this cell produces them; RESULTS.md R12 is the precedent.\n";
    }
  }' "$T/results"
