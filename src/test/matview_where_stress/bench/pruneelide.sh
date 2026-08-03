#!/bin/sh
#
# What is the prune elision worth, on the implementation rather than on a model?
#
#   ./pruneelide.sh [rounds] [n]        default: 6 rounds, 40 refreshes each
#
# SPECIALIZE.md 3b sizes it from bench/mutability.sql, which hand-writes the
# statement forms and times them against a plain-heap clone -- RESULTS.md R6,
# 13-19% faster at scope >= 1000.  That is a model of the saving, taken before
# the code could emit it.  This measures the code.
#
# The two arms, and why they need no rebuild
# ------------------------------------------
# The elision is gated on the lock level: it is available under the bare form's
# ExclusiveLock, where no other session can write the matview, and not under
# CONCURRENTLY's RowExclusiveLock, where a row can be committed into the scope
# between the pre-lock's count and the DELETE it stands in for.  Both spellings
# otherwise reach the same algorithm, the same generated SQL and the same plan
# -- convergence, SPECIALIZE.md 4 -- so on one client, with no contention, the
# only thing between them is the guard.
#
#   bare    REFRESH MATERIALIZED VIEW mv WHERE ...                elides
#   conc    REFRESH MATERIALIZED VIEW CONCURRENTLY mv WHERE ...   does not
#
# So both arms sit inside one build, one boot and one clone, which is the rule
# this directory keeps relearning -- and the lock levels themselves cost nothing
# to compare at one client, because neither ever waits.
#
# THE CONTROL IS NOT OPTIONAL.  A difference between two spellings is not
# evidence about the elision unless the difference disappears when the elision
# does.  Run it again under `mutations.py N3`, which turns the guard off and
# changes nothing else: bare and conc must then read the same.  Without that,
# any constant difference between the two forms -- and there is no reason to
# assume there is none -- is read as the optimisation.
#
# Protocol, inherited from bench/predparam.sh and for its reasons:
#
#   No VACUUM between timed blocks (RESULTS.md X11).  Settle once, before the
#   first block, and not again.
#   Arms alternate and the order rotates each round.
#   Round 1 is discarded.
#   Session setup is measured and subtracted.
#   synchronous_commit off; every refresh here is its own transaction, and a
#   WAL flush per refresh lands on the denominator of every ratio.
#
# The cell is the favourable end and says so: the scope is re-refreshed without
# the base being mutated, which is a drain catching up on a scope it is already
# level with.  Nothing is ever orphaned, so the elision fires on every bare
# refresh.  A scope with real churn pays the same prune it always did on the
# refreshes where something did leave.
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

T=/tmp/pruneelide.$$
mkdir -p "$T"; chmod 777 "$T"
trap 'rm -rf "$T"' EXIT

run() { su "$RUNAS" -c "PGOPTIONS='$PGOPTIONS' $PSQL $*"; }

echo "pruneelide: label=$LABEL pred=$PRED span=$SPAN groups=$GROUPS scale=$SCALE optimized=$OPT"
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
CREATE INDEX ON pe_mv(cust);
VACUUM ANALYZE pe_ord;
VACUUM ANALYZE pe_mv;
SQL

# One statement file per arm.  Both walk the same keys in the same order, so
# the comparison carries no data-distribution difference.  The predicate is a
# range on the arbiter key: key-only, which the count rule is gated on.
awk -v n="$N" -v span="$SPAN" -v scale="$SCALE" -v opt="$OPT" \
    -v pred="$PRED" -v groups="$GROUPS" '
function predicate(i,   k) {
  if (pred == "nonkey") return sprintf("cust = %d", i % groups);
  k = 1 + i * int((scale - span) / n);
  return sprintf("id BETWEEN %d AND %d", k, k + span - 1);
}
BEGIN {
  printf "SET matview_partial_refresh_optimized = %s;\n", opt > "'"$T"'/bare.sql";
  printf "SET matview_partial_refresh_optimized = %s;\n", opt > "'"$T"'/conc.sql";
  for (i = 0; i < n; i++) {
    printf "REFRESH MATERIALIZED VIEW pe_mv WHERE %s;\n",
           predicate(i)                                 > "'"$T"'/bare.sql";
    printf "REFRESH MATERIALIZED VIEW CONCURRENTLY pe_mv WHERE %s;\n",
           predicate(i)                                 > "'"$T"'/conc.sql";
  }
}'
echo "SELECT 1;" > "$T/empty.sql"
sed -n '2p' "$T/bare.sql" | sed 's/^/  bare: /'
sed -n '2p' "$T/conc.sql" | sed 's/^/  conc: /'
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
  if [ $(( r % 2 )) -eq 1 ]; then ORDER="bare conc"; else ORDER="conc bare"; fi
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
awk -v label="$LABEL" -v span="$SPAN" -v pred="$PRED" '
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
    split("conc bare", o, " ");
    for (i = 1; i <= 2; i++) { a = o[i]; if (!(a in n)) continue;
      md[a] = median(a);
      printf "  %-5s %10.1f %10.1f %10d %10d %6d\n",
             a, md[a], s[a]/n[a], lo[a], hi[a], n[a];
      m[a] = s[a]/n[a] }
    if (("conc" in m) && ("bare" in m)) {
      printf "\n  %s %s/span=%s -- bare against conc, three statistics:\n", label, pred, span;
      printf "    median  %+8.1f us  %6.1f%%   <- quote this one\n",
             md["conc"] - md["bare"], 100 * (md["conc"] - md["bare"]) / md["conc"];
      printf "    mean    %+8.1f us  %6.1f%%\n",
             m["conc"] - m["bare"], 100 * (m["conc"] - m["bare"]) / m["conc"];
      printf "    minima  %+8.1f us  %6.1f%%\n",
             lo["conc"] - lo["bare"], 100 * (lo["conc"] - lo["bare"]) / lo["conc"];
      printf "  A mean over this many bands is not robust to one excursion and\n";
      printf "  this cell produces them; RESULTS.md R12 is the precedent.\n";
    }
  }' "$T/results"
