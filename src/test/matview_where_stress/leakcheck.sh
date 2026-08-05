#!/bin/sh
#
# Does the source-plan cache leak?
#
#   ./leakcheck.sh [MODE ...]     default: all of them
#
# Modes, each aimed at one lifetime path added by PLAN.md 3.7:
#
#   steady   the same predicate over and over -- the reuse path.  One
#            plansource, forever.
#   churn    two predicates alternating on one matview.  Each swap is a
#            cache-key mismatch, so the entry rebuilds and the *old* plansource
#            has to be dropped.  This is the path C3 mutates.
#   nested   a refresh whose view definition refreshes a second matview.
#            **This mode currently proves less than it looks like it does, and
#            says so rather than reporting a clean bill.**  The nested refresh
#            never reaches the source-plan build: it dies earlier, at the
#            row-locking SELECT, with "cannot lock rows in materialized view".
#            B5 scoped the maintenance exemption to the matview being refreshed,
#            so a nested refresh of a *different* one cannot take its row locks
#            -- which is why matview_where_cache Test 5 wraps the nested call in
#            EXCEPTION WHEN OTHERS.  The teardown in refresh_by_direct_
#            modification() that drops a private plansource is therefore
#            defensive, not live, and L3 does not make this mode leak.  Kept
#            because the day a nested refresh can complete, this is the mode
#            that has to catch it -- and because "the drop is unreachable" is
#            worth knowing before someone deletes it as dead code.
#   dropmv   matviews created, refreshed and dropped.  Their plans are reclaimed
#            by matview_cache_sweep() and by nothing else.
#
# Why counting contexts and not bytes
# -----------------------------------
# plancache puts every CachedPlanSource in its own memory context, so a leaked
# plansource is a *context that never goes away* -- pg_backend_memory_contexts
# counts them directly.  Bytes are noisy (the planner's own arenas move around);
# a count that climbs with the refresh count is unambiguous, and it says how
# many were leaked rather than how much.
#
# What each mode is, and what proved it
# -------------------------------------
# There are three drop sites and they are reached by different events, so a
# mutation hitting one says nothing about the others.  Every mode below is
# either calibrated against the site it covers or labelled as not being a
# detector -- "it printed ok" is not evidence, which is the mistake that put
# `nested` in this file reporting a clean bill while observing nothing.
#
#   churn    DETECTOR, calibrated TWICE and re-calibrated once.  Under L3
#            (key-mismatch drop removed): +800 plansources, one per refresh,
#            the body issuing two.  Under L5 (the cache key's context rebuilt
#            instead of reset): +800 keys, and `steady` stays at +0, which is
#            what says the leak is reached by the key CHANGING rather than by
#            refreshing.
#
#            The earlier calibration recorded here was +400/400 and had gone
#            stale without a word: the mode used to alternate `id = 1` with
#            `id = 2`, and once the predicate's constants became parameters
#            both deparsed to `id = $1`, every refresh hit, and the mismatch
#            path was never taken.  Re-running L3 against it read +0.  That is
#            what a recorded number is worth once the code under it has moved.
#   dropmv   DETECTOR, calibrated.  Under L4 (sweep drop removed): +200 over
#            200, one per dropped matview.  L3 leaves it at +0, so the modes
#            are specific rather than all firing at once.
#   steady   CONTROL, not a detector, and it cannot be made into one by
#            removing a drop: the reuse path allocates one plansource and never
#            frees it, so there is no drop site on it.  It must read +0 under
#            every mutation; anything else is a false positive here.
#   nested   NOT LIVE -- see above.  Reports +0 under L3 and L4 both, because
#            the nested refresh never reaches the source-plan build.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-5610}
DB=${DB:-postgres}
PREFIX=${PREFIX:-/home/user/pgsql-opt}
RUNAS=${RUNAS:-pgtest}
WARM=${WARM:-50}
RUNS=${RUNS:-400}
PSQL="$PREFIX/bin/psql -p $PORT -d $DB -qtAX"

# Every case runs on the Query-tree path, because that is the only one with a
# source plansource at all.  There is no longer a GUC that can route around it.
GUCS=""

# Counted inside the session under test: a plansource leaked by one backend is
# invisible to every other one.
#
# The third column is the cache entry's own metadata context, added when the
# plan-cache key became the qual TREE rather than its deparsed text (R48).  A
# node tree cannot be pfree'd, so the entry got a context to hold it, and a
# context is a lifetime -- which means it is a thing that can be leaked, by
# exactly the same slip L3 makes one level over.  Counting only plansources
# would have been blind to it: this file's own reason for existing is that
# "every result is correct and the backend grows forever" has no other detector.
COUNT="SELECT count(*) FILTER (WHERE name = 'CachedPlanSource')
         || ' ' || count(*) FILTER (WHERE name = 'CachedPlan')
         || ' ' || count(*) FILTER (WHERE name = 'MatView Partial Refresh Cache Key')
    FROM pg_backend_memory_contexts;"

run_mode() {
    mode=$1
    case "$mode" in
    steady)
        body="REFRESH MATERIALIZED VIEW lk_mv WHERE id = 1;"
        setup="CREATE TABLE lk_base(id int primary key, v int);
               INSERT INTO lk_base SELECT g, g FROM generate_series(1,50) g;
               CREATE MATERIALIZED VIEW lk_mv AS SELECT id, v FROM lk_base;
               CREATE UNIQUE INDEX ON lk_mv(id);"
        drop="DROP MATERIALIZED VIEW lk_mv; DROP TABLE lk_base;" ;;
    churn)
        # Two predicates on DIFFERENT COLUMNS, so every other refresh is a
        # cache-key mismatch and rebuilds the entry.
        #
        # It used to be `id = 1` against `id = 2`, and that stopped being a
        # mismatch when the predicate's constants started being replaced by
        # parameters: both now deparse to `id = $1` and compare equal, so the
        # entry is HIT every time and this mode had quietly stopped exercising
        # the path it is named after.  Nothing said so -- it kept printing ok,
        # which is what it prints when there is no leak and what it prints when
        # it is not looking.  Caught by re-running L3 against it, whose recorded
        # calibration here is +400 over 400 refreshes: it read +0.
        #
        # Different columns rather than different values is what survives
        # parameterisation, since the Var is what differs and no substitution
        # touches it.
        body="REFRESH MATERIALIZED VIEW lk_mv WHERE id = 1;
              REFRESH MATERIALIZED VIEW lk_mv WHERE v = 1;"
        setup="CREATE TABLE lk_base(id int primary key, v int);
               INSERT INTO lk_base SELECT g, g FROM generate_series(1,50) g;
               CREATE MATERIALIZED VIEW lk_mv AS SELECT id, v FROM lk_base;
               CREATE UNIQUE INDEX ON lk_mv(id);"
        drop="DROP MATERIALIZED VIEW lk_mv; DROP TABLE lk_base;" ;;
    nested)
        # The nested refresh goes through the outer matview's *definition*, not
        # its predicate.  Two things rule the predicate out, and both are
        # documented behaviour rather than accidents: an unqualified name does
        # not resolve under RestrictSearchPath() (B9), and a VOLATILE function
        # is rejected outright ("WHERE clause ... cannot contain volatile
        # functions").  The view body has neither restriction, and it is
        # evaluated inside the same maintenance window -- which is how
        # matview_where_cache Test 5 drives the same path.
        body="REFRESH MATERIALIZED VIEW lk_mv WHERE id = 1;"
        setup="CREATE TABLE lk_inner_base(id int primary key, v int);
               INSERT INTO lk_inner_base SELECT g, g FROM generate_series(1,20) g;
               CREATE MATERIALIZED VIEW lk_inner AS
                 SELECT id, v FROM lk_inner_base;
               CREATE UNIQUE INDEX ON lk_inner(id);
               CREATE FUNCTION public.lk_touch(x int) RETURNS int
                 LANGUAGE plpgsql VOLATILE AS \$\$
               BEGIN
                 BEGIN
                   REFRESH MATERIALIZED VIEW public.lk_inner WHERE id = 1;
                 EXCEPTION WHEN OTHERS THEN NULL;
                 END;
                 RETURN x;
               END \$\$;
               CREATE TABLE lk_base(id int primary key, v int);
               INSERT INTO lk_base SELECT g, g FROM generate_series(1,50) g;
               CREATE MATERIALIZED VIEW lk_mv AS
                 SELECT id, public.lk_touch(v) AS v FROM lk_base;
               CREATE UNIQUE INDEX ON lk_mv(id);"
        drop="DROP MATERIALIZED VIEW lk_mv; DROP TABLE lk_base;
              DROP MATERIALIZED VIEW lk_inner; DROP TABLE lk_inner_base;
              DROP FUNCTION public.lk_touch(int);" ;;
    dropmv)
        body="CREATE MATERIALIZED VIEW lk_tmp AS SELECT id, v FROM lk_base;
              CREATE UNIQUE INDEX ON lk_tmp(id);
              REFRESH MATERIALIZED VIEW lk_tmp WHERE id = 1;
              DROP MATERIALIZED VIEW lk_tmp;"
        setup="CREATE TABLE lk_base(id int primary key, v int);
               INSERT INTO lk_base SELECT g, g FROM generate_series(1,50) g;"
        drop="DROP TABLE lk_base;" ;;
    *)  echo "unknown mode $mode" >&2; return 1 ;;
    esac

    {
        echo "$GUCS"
        echo "$setup"
        i=0; while [ "$i" -lt "$WARM" ]; do echo "$body"; i=$((i + 1)); done
        printf 'SELECT %s;\n' "'MARK_BEFORE'"
        echo "$COUNT"
        i=0; while [ "$i" -lt "$RUNS" ]; do echo "$body"; i=$((i + 1)); done
        printf 'SELECT %s;\n' "'MARK_AFTER'"
        echo "$COUNT"
        echo "$drop"
    } | su "$RUNAS" -c "$PSQL" 2>&1 \
      | awk -v mode="$mode" -v runs="$RUNS" '
          /^MARK_BEFORE$/ { want = "b"; next }
          /^MARK_AFTER$/  { want = "a"; next }
          want == "b" && NF { split($0, x, " "); bs = x[1]; bp = x[2]; bk = x[3]; want = "" }
          want == "a" && NF { split($0, x, " "); as = x[1]; ap = x[2]; ak = x[3]; want = "" }
          END {
            if (bs == "" || as == "") {
              printf "  %-7s NO SAMPLES -- markers never arrived; not reporting\n", mode
              exit 1
            }
            ds = as - bs; dp = ap - bp; dk = ak - bk
            status = (ds > 0 || dp > 0 || dk > 0) ? "LEAK" : "ok"
            printf "  %-7s plansources %s -> %s (%+d)   plans %s -> %s (%+d)   keys %s -> %s (%+d)   over %d refreshes   %s\n",
                   mode, bs, as, ds, bp, ap, dp, bk, ak, dk, runs, status
          }'
}

if [ "${1:-}" = "--selftest" ]; then
    cat <<'TXT'
Calibration, run by hand because it needs a rebuild between the two halves:

    ./mutations.py L3 && ./rebuild.sh --source && ./leakcheck.sh churn nested
      -> must report LEAK in the PLANSOURCES column, climbing by roughly one
         per refresh

    ./mutations.py L5 && ./rebuild.sh --source && ./leakcheck.sh churn
      -> must report LEAK in the KEYS column, one per cache-key mismatch, and
         `steady` must stay ok: a key that never changes is never rebuilt, so
         the leak is reached by the swap and not by the refresh

    ./mutations.py pristine && ./rebuild.sh --source && ./leakcheck.sh
      -> must report ok everywhere

A detector that has only ever been seen saying "ok" is not evidence.
TXT
    exit 0
fi

modes=${*:-"steady churn nested dropmv"}
echo "== leakcheck: $WARM warm-up then $RUNS refreshes per mode, counting"
echo "   plancache contexts in the session under test"
for m in $modes; do run_mode "$m"; done
