#!/bin/sh
#
# The 3.7 measurement: does caching the source plan close the deficit, and by
# how much.
#
#   ./srcplan.sh floor [REPEATS]   R30 -- the noise floor of THIS protocol
#   ./srcplan.sh arms  [ROUNDS]    R31 -- querytree off against on
#
# Needs a tree built with `profile.py on`.  It refuses to run without it,
# because the failure mode otherwise is a clean run reporting nothing.
#
# The protocol, and why each piece is the way it is (CACHE.md §6)
# --------------------------------------------------------------
# Cell: constant literal, scope 1, warm, on `projection` -- R26's cell.  A
# constant literal deparses identically every call so the entry is hit, and
# `params` is NULL so choose_custom_plan() returns false immediately and the
# plan is generic unconditionally.  A *varying* literal misses by design and is
# the path bench/run.sh takes, which is why run.sh cannot produce this cell.
#
# Arms are querytree off against on, NOT qtopt.  The reason given was that the
# row comparison measured 18.5% slower at scope 1 and would hand the arm that
# has to close a gap a handicap unrelated to 3.7 -- and that FIGURE is retracted
# (RESULTS.md R45: +2.2% faster there, and it is the default now).  The rule it
# supported is not: bundling any second change into a measurement makes a
# measurable effect unmeasurable, whichever way the second one points.
#
# No VACUUM between timed refreshes.  vac_update_relstats() updates pg_class in
# place, which routes through CacheInvalidateHeapTupleInplace(); a VACUUM before
# each timed refresh would drop the plan cache before each timed refresh, turning
# the warm cell into the cold one -- where the Query-tree arm already wins for an
# unrelated reason.  The measurement would then report success whether or not
# 3.7 worked.
#
# Arms alternate across whole sessions rather than within one.  Flipping the GUC
# mid-session changes the cache key and forces a rebuild, so every band would
# carry a cold refresh and the warm cell would never be measured.
#
# Band 1 of each session is discarded: it carries the cold prepare.
set -eu

DIR=$(cd "$(dirname "$0")/.." && pwd)
SRC=$(cd "$DIR/../../.." && pwd)
PORT=${PORT:-5610}
DB=${DB:-postgres}
PREFIX=${PREFIX:-/home/user/pgsql-opt}
RUNAS=${RUNAS:-pgtest}
SERVERLOG=${SERVERLOG:-/home/pgtest/pg-opt.log}
SCALE=${SCALE:-100000}
GROUPS=${GROUPS:-1000}
REFRESHES=${REFRESHES:-300}
BAND=30                     # profile.py reports every 30 calls
PSQL="$PREFIX/bin/psql -p $PORT -d $DB -q -X"

mode=${1:-}
n=${2:-8}
[ -n "$mode" ] || { sed -n '2,12p' "$0"; exit 2; }

# A cheap first check that the tree is instrumented.  It is NOT sufficient --
# the binary can be stale while the source looks right -- so the real check is
# that samples actually arrive, asserted after the first session below.
if ! grep -q 'MVPROF' "$SRC/src/backend/commands/matview.c"; then
    echo "matview.c is not instrumented; run: ./profile.py on && ./rebuild.sh --source" >&2
    exit 1
fi

setup() {
    su "$RUNAS" -c "$PSQL" <<SQL
DROP MATERIALIZED VIEW IF EXISTS sp_mv;
DROP TABLE IF EXISTS sp_ord;
CREATE TABLE sp_ord(id bigint primary key, cust int, status text,
                    updated timestamptz);
INSERT INTO sp_ord
  SELECT g, g % $GROUPS, 'S' || (g % 5), now()
    FROM generate_series(1, $SCALE) g;
CREATE INDEX ON sp_ord(cust);
CREATE MATERIALIZED VIEW sp_mv AS SELECT id, cust, status FROM sp_ord;
CREATE UNIQUE INDEX ON sp_mv(id);
CREATE INDEX ON sp_mv(cust);
VACUUM ANALYZE sp_ord;
VACUUM ANALYZE sp_mv;
SQL
}

# One session: $REFRESHES refreshes of one scope-1 constant-literal predicate.
# No VACUUM anywhere inside.  The arm used to select the implementation; there
# is only one now, and R33/R34's arms were always the cache being off or on
# (mutations.py C4) rather than this.
session() {
    arm=$1
    {
        echo "SET matview_partial_refresh_optimized = off;"
        # One statement per line, autocommit: R26's protocol is 300 *committed*
        # refreshes, and R7 puts one-per-transaction 3.5-3.7x from all-in-one at
        # scope 1.  A DO loop would silently measure the other cell.  The GUCs
        # are session-level so they survive the commits.
        i=0
        while [ "$i" -lt "$REFRESHES" ]; do
            echo "REFRESH MATERIALIZED VIEW sp_mv WHERE id = 1;"
            i=$((i + 1))
        done
    } | su "$RUNAS" -c "$PSQL"
}

# Pull the MVPROF lines this run appended, and print per-refresh microseconds
# for the phases 3.7 moves, discarding the first band of each session.
harvest() {
    from=$1
    su "$RUNAS" -c "tail -c +$from '$SERVERLOG'" \
      | grep -o 'MVPROF .*' \
      | awk -v band="$BAND" '
        {
          calls=0; total=0; srcbuild=0; srcrewrite=0; srcplan=0
          for (i = 1; i <= NF; i++) {
            split($i, kv, "=")
            if (kv[1] == "calls")      calls = kv[2]
            if (kv[1] == "total")      total = kv[2]
            if (kv[1] == "srcbuild")   srcbuild = kv[2]
            if (kv[1] == "srcrewrite") srcrewrite = kv[2]
            if (kv[1] == "srcplan")    srcplan = kv[2]
          }
          if (calls == 0) next
          nb++
          printf "%d %.3f %.3f %.3f %.3f\n", nb, total/calls,
                 srcbuild/calls, srcrewrite/calls, srcplan/calls
        }'
}

logsize() { su "$RUNAS" -c "wc -c < '$SERVERLOG'"; }

stats() {
    awk '{ v[n++] = $1; s += $1 }
         END {
           if (n == 0) { print "no samples"; exit }
           mean = s / n
           for (i = 0; i < n; i++) { d = v[i] - mean; ss += d * d }
           sd = (n > 1) ? sqrt(ss / (n - 1)) : 0
           asort_min = v[0]; asort_max = v[0]
           for (i = 1; i < n; i++) {
             if (v[i] < asort_min) asort_min = v[i]
             if (v[i] > asort_max) asort_max = v[i]
           }
           printf "n=%d mean=%.2f sd=%.2f (%.1f%%) min=%.2f max=%.2f spread=%.1f%%\n",
                  n, mean, sd, 100 * sd / mean, asort_min, asort_max,
                  100 * (asort_max - asort_min) / mean
         }'
}

echo "== setup: projection, scale=$SCALE groups=$GROUPS, scope 1, constant literal"
setup > /dev/null

case "$mode" in
floor)
    echo "== R30: $n sessions of $REFRESHES refreshes, ALL querytree=off"
    echo "   the spread here is the floor; any bar below it is unmeasurable"
    : > /tmp/srcplan-floor.raw
    i=1
    while [ "$i" -le "$n" ]; do
        start=$(( $(logsize) + 1 ))
        session off > /dev/null
        harvest "$start" | awk -v s="$i" 'NR > 1 { print $2, s }' \
            >> /tmp/srcplan-floor.raw
        i=$((i + 1))
    done
    if [ ! -s /tmp/srcplan-floor.raw ]; then
        echo "NO SAMPLES -- the build is not instrumented, or MVPROF is not" >&2
        echo "reaching $SERVERLOG.  Refusing to report a floor of nothing." >&2
        exit 1
    fi
    echo "-- per-band per-refresh total (us), band 1 of each session discarded:"
    stats < /tmp/srcplan-floor.raw
    ;;
arms)
    echo "== R31: $n rounds, alternating querytree off / on, same clone"
    : > /tmp/srcplan-off.raw; : > /tmp/srcplan-on.raw
    i=1
    while [ "$i" -le "$n" ]; do
        for arm in off on; do
            start=$(( $(logsize) + 1 ))
            session "$arm" > /dev/null
            harvest "$start" | awk 'NR > 1 { print $2, $3, $4, $5 }' \
                >> "/tmp/srcplan-$arm.raw"
        done
        i=$((i + 1))
    done
    echo "-- querytree=off (text source path)"
    stats < /tmp/srcplan-off.raw
    echo "-- querytree=on  (Query-tree source, plan cached)"
    stats < /tmp/srcplan-on.raw
    echo "-- srcbuild / srcrewrite / srcplan per refresh, querytree=on:"
    awk '{ b += $2; r += $3; p += $4; n++ }
         END { if (n) printf "   srcbuild=%.2f srcrewrite=%.2f srcplan=%.2f (us)\n",
                             b/n, r/n, p/n }' /tmp/srcplan-on.raw
    ;;
*)
    echo "unknown mode $mode" >&2; exit 2 ;;
esac
