#!/bin/sh
#
# What the deparse elision is worth (PLAN.md 3.8, RESULTS.md R14's successor).
#
#   ./deparse.sh cold  [SESSIONS]  the one deparse left, and that no others run
#   ./deparse.sh arms  [ROUNDS]    end to end, pristine against mutations.py C9
#
# Needs a tree built with `profile.py on`.  It refuses to run without it,
# because the failure mode otherwise is a clean run reporting nothing.
#
# The protocol, and why each piece is the way it is
# -------------------------------------------------
# Cell: scope 1, `projection`, warm.  The deparse is a fixed per-refresh cost,
# so scope 1 is where it is the largest share and the only place it is
# measurable at all -- R14 put it at 7.4% there and 0.0% by scope 100.  Nothing
# here should be read as a claim about a large-scope refresh.
#
# Two arms, and they are two BUILDS.  There is no GUC for this and there should
# not be one; the off arm is `mutations.py C9`, which deparses on every refresh
# and discards the string.  That is the cost the elision removes, with nothing
# else changed.  Cross-build comparison is the hazard this directory has been
# bitten by most (SPECIALIZE.md §6), so the rebuild happens INSIDE the
# alternation: every round rebuilds both arms, in an order that flips each
# round, on one container and one clone.  A build-order effect would then show
# up as round-to-round spread rather than as the result.
#
# `arms` is the measurement; `cold` is not a second opinion on it and must not
# be read as one.  The warm per-refresh deparse cost is deliberately not timed
# in isolation: the timer sits inside the cache-miss branch precisely so that a
# warm profile reads 0.00, which is the effect the change had.  What `cold`
# reports is the single deparse a fresh backend still pays, which is several
# times the warm one because pg_get_expr finds an empty syscache -- and
# reporting that as the saving is a mistake this script made once already.
#
# X16 is why the distinction is worth this much text: there, a sub-component
# number (20-69% of the pre-lock) was treated as a whole-refresh saving and did
# not survive being measured end to end.  So the end-to-end number is the claim
# and the component number is context.
#
# No VACUUM between timed refreshes (RESULTS.md X11): vac_update_relstats()
# updates pg_class in place, which implies a relcache invalidation, and that
# would drop the plan cache before every timed refresh -- turning the warm cell
# this is about into the cold one, where the deparse runs in both arms and the
# effect is zero by construction.
#
# Band 1 of each session is discarded: it carries the cold prepare, and on this
# change it carries the one deparse that still happens.
#
# synchronous_commit off, so a ~1 ms WAL flush per refresh does not sit in both
# arms' denominators and divide the effect away (R38's neighbour).
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
n=${2:-6}
[ -n "$mode" ] || { sed -n '2,9p' "$0"; exit 2; }

instrumented() {
    grep -q 'MVPROF' "$SRC/src/backend/commands/matview.c"
}

# Rebuild into a named arm.
#
# profile.py and mutations.py BOTH write the whole file from `git show HEAD:`,
# so running one after the other undoes the first -- silently, with a green
# build and a plausible number.  Instrument first, then overlay the mutation on
# top of the instrumented tree with --overlay, which is the mode that exists for
# exactly this.  The overlay still checks its occurrence count, so a drifted
# pattern is a hard error rather than an arm that quietly measures nothing.
build_arm() {
    (cd "$SRC" && ./src/test/matview_where_stress/profile.py on) > /dev/null
    instrumented || { echo "profile.py on left the tree uninstrumented" >&2; exit 1; }
    if [ "$1" = off ]; then
        (cd "$SRC" && ./src/test/matview_where_stress/mutations.py --overlay=C9) \
            > /dev/null
        grep -q 'pfree(deparseRefreshWhereClause' "$SRC/src/backend/commands/matview.c" \
            || { echo "C9 overlay did not take" >&2; exit 1; }
    fi
    "$DIR/rebuild.sh" --source > /tmp/deparse-build.log 2>&1 \
        || { tail -20 /tmp/deparse-build.log; echo "BUILD FAILED" >&2; exit 1; }
}

setup() {
    su "$RUNAS" -c "$PSQL" <<SQL
DROP MATERIALIZED VIEW IF EXISTS dp_mv;
DROP TABLE IF EXISTS dp_ord;
CREATE TABLE dp_ord(id bigint primary key, cust int, status text,
                    updated timestamptz);
INSERT INTO dp_ord
  SELECT g, g % $GROUPS, 'S' || (g % 5), now()
    FROM generate_series(1, $SCALE) g;
CREATE INDEX ON dp_ord(cust);
CREATE MATERIALIZED VIEW dp_mv AS SELECT id, cust, status FROM dp_ord;
CREATE UNIQUE INDEX ON dp_mv(id);
CREATE INDEX ON dp_mv(cust);
VACUUM ANALYZE dp_ord;
VACUUM ANALYZE dp_mv;
SQL
}

# One session: $REFRESHES committed refreshes of one scope-1 predicate.  One
# statement per line and autocommit, because R7 puts one-refresh-per-transaction
# 3.5-3.7x from all-in-one at scope 1 and a DO loop would measure the other cell.
#
# No SET of matview_partial_refresh_optimized: the row comparison has been the
# default since R45 and forcing it either way would be a second change inside
# one measurement.
session() {
    {
        echo "SET synchronous_commit = off;"
        i=0
        while [ "$i" -lt "$REFRESHES" ]; do
            echo "REFRESH MATERIALIZED VIEW dp_mv WHERE id = 1;"
            i=$((i + 1))
        done
    } | su "$RUNAS" -c "$PSQL"
}

# Per-band per-refresh microseconds for the whole refresh and the deparse.
harvest() {
    su "$RUNAS" -c "tail -c +$1 '$SERVERLOG'" \
      | grep -o 'MVPROF .*' \
      | awk '
        {
          calls=0; total=0; deparse=0; prepare=0
          for (i = 1; i <= NF; i++) {
            split($i, kv, "=")
            if (kv[1] == "calls")   calls   = kv[2]
            if (kv[1] == "total")   total   = kv[2]
            if (kv[1] == "deparse") deparse = kv[2]
            if (kv[1] == "prepare") prepare = kv[2]
          }
          if (calls == 0) next
          nb++
          printf "%d %.3f %.3f %.3f\n", nb, total/calls, deparse/calls, prepare/calls
        }'
}

logsize() { su "$RUNAS" -c "wc -c < '$SERVERLOG'"; }

# Median as well as mean, and the minima.  RESULTS.md X14: when the three
# disagree the cell is under-sampled, and that disagreement is the first thing
# to read rather than the headline.
stats() {
    awk '{ v[n++] = $1; s += $1 }
         END {
           if (n == 0) { print "no samples"; exit }
           for (i = 0; i < n; i++)
             for (j = i + 1; j < n; j++)
               if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
           mean = s / n
           med = (n % 2) ? v[(n-1)/2] : (v[n/2 - 1] + v[n/2]) / 2
           for (i = 0; i < n; i++) { d = v[i] - mean; ss += d * d }
           sd = (n > 1) ? sqrt(ss / (n - 1)) : 0
           printf "n=%d median=%.2f mean=%.2f sd=%.2f (%.1f%%) min=%.2f max=%.2f\n",
                  n, med, mean, sd, 100 * sd / mean, v[0], v[n-1]
         }'
}

case "$mode" in
cold)
    # The one deparse that still happens, and the check that no others do.
    #
    # Every session here is a fresh backend, so band 1 carries exactly one cache
    # miss and therefore exactly one deparse.  That call is the expensive one:
    # pg_get_expr resolves operator and attribute names, and in a fresh backend
    # none of them are in the syscache yet.
    #
    # It is NOT the saving, and the gap is big enough to mislead -- a first
    # version of this mode reported it as the saving and would have claimed
    # several times the truth.  The warm per-refresh cost is not separately
    # timed on purpose: the timer sits inside the miss branch so that a warm
    # profile reads 0.00, which is the whole of what the change did.  The warm
    # cost is the `arms` difference, measured end to end rather than attributed.
    build_arm on
    echo "== setup: projection, scale=$SCALE groups=$GROUPS, scope 1"
    setup > /dev/null
    echo "== cold: $n fresh backends, pristine"
    : > /tmp/deparse-cold.raw; : > /tmp/deparse-warm.raw
    i=1
    while [ "$i" -le "$n" ]; do
        start=$(( $(logsize) + 1 ))
        session > /dev/null
        harvest "$start" | awk -v b="$BAND" '
            NR == 1 { print $3 * b >> "/tmp/deparse-cold.raw" }
            NR  > 1 { print $3     >> "/tmp/deparse-warm.raw" }'
        i=$((i + 1))
    done
    [ -s /tmp/deparse-cold.raw ] || {
        echo "NO SAMPLES -- the build is not instrumented, or MVPROF is not" >&2
        echo "reaching $SERVERLOG.  Refusing to report a cost of nothing." >&2
        exit 1; }
    echo "-- the single cold deparse in a fresh backend, us:"
    stats < /tmp/deparse-cold.raw
    echo "-- deparse per refresh in every WARM band, us (must be 0.00):"
    stats < /tmp/deparse-warm.raw
    ;;
arms)
    echo "== arms: $n rounds, C9 (deparse every refresh) against pristine"
    echo "   both arms rebuilt every round, order flipped each round"
    : > /tmp/deparse-off.raw; : > /tmp/deparse-on.raw
    build_arm on
    echo "== setup: projection, scale=$SCALE groups=$GROUPS, scope 1"
    setup > /dev/null
    i=1
    while [ "$i" -le "$n" ]; do
        # Rotate the order so build position cannot be read as the effect.
        if [ $((i % 2)) -eq 1 ]; then order="off on"; else order="on off"; fi
        for arm in $order; do
            build_arm "$arm"
            start=$(( $(logsize) + 1 ))
            session > /dev/null
            harvest "$start" | awk 'NR > 1 { print $2 }' >> "/tmp/deparse-$arm.raw"
        done
        echo "   round $i done"
        i=$((i + 1))
    done
    echo "-- OFF (C9: deparsed on every refresh), whole refresh us:"
    stats < /tmp/deparse-off.raw
    echo "-- ON  (pristine: deparsed only on a miss), whole refresh us:"
    stats < /tmp/deparse-on.raw
    awk 'FNR==NR { o[n1++] = $1; next } { p[n2++] = $1 }
         END {
           if (n1 == 0 || n2 == 0) { print "no samples"; exit }
           for (i = 0; i < n1; i++)
             for (j = i+1; j < n1; j++) if (o[j] < o[i]) { t=o[i]; o[i]=o[j]; o[j]=t }
           for (i = 0; i < n2; i++)
             for (j = i+1; j < n2; j++) if (p[j] < p[i]) { t=p[i]; p[i]=p[j]; p[j]=t }
           om = (n1 % 2) ? o[(n1-1)/2] : (o[n1/2-1] + o[n1/2]) / 2
           pm = (n2 % 2) ? p[(n2-1)/2] : (p[n2/2-1] + p[n2/2]) / 2
           for (i = 0; i < n1; i++) os += o[i]
           for (i = 0; i < n2; i++) ps += p[i]
           printf "-- saving: median %.2f us (%.1f%%), mean %.2f us (%.1f%%), minima %.2f us (%.1f%%)\n",
                  om - pm, 100 * (om - pm) / om,
                  os/n1 - ps/n2, 100 * (os/n1 - ps/n2) / (os/n1),
                  o[0] - p[0], 100 * (o[0] - p[0]) / o[0]
         }' /tmp/deparse-off.raw /tmp/deparse-on.raw
    ;;
*)
    echo "unknown mode $mode" >&2; exit 2 ;;
esac

# Leave the tree as it was found.  An instrumented or mutated tree that outlives
# the run is how a later measurement gets taken on the wrong binary.
#
# profile.py off restores the whole file from HEAD, so it undoes the overlay as
# well; mutations.py pristine afterwards would refuse on an instrumented tree
# and is not needed.
(cd "$SRC" && ./src/test/matview_where_stress/profile.py off) > /dev/null
echo "== tree restored to pristine (rebuild before running anything else)"
