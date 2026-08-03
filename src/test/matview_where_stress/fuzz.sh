#!/bin/sh
#
# Concurrent correctness fuzzer for REFRESH MATERIALIZED VIEW ... WHERE ...
#
#   ./fuzz.sh [PORT] [DB] [MODE ...]   modes: p2 p3 serial nest   (default: all)
#
# The safety oracle in safety/ is single-session, so it cannot see any bug that
# needs two sessions to be a bug.  Calibration measured exactly that: it catches
# A4 and B4 and misses M1, M2, M3 and M6 (PLAN.md 1.1c).  This is the instrument
# for those four, and each mode is built around the guarantee it tests rather
# than around the code that currently delivers it.
#
#   p2      P2, deterministic lock order over EXISTING rows.
#           N sessions refresh the same rows through two predicates that plan
#           differently -- an index scan ascending and a sequential scan over
#           rows inserted in descending order, alternated across the sessions.
#           Without a common order, adjacent sessions take the same locks in
#           opposite orders.  Signal: deadlock.
#
#   p3      P3, deterministic lock order over INSERTED rows.
#           Same shape, but the rows are absent from the matview so the refresh
#           INSERTs rather than UPDATEs, and the conflict is between two
#           speculative insertions of the same key.  Signal: deadlock.
#
#   nest    A refresh whose view definition issues another REFRESH ... WHERE,
#           run concurrently with a separate backend committing DDL so the
#           invalidations arrive on their own.  B14's class, which nothing else
#           covers.  CALIBRATED: catches C2 in 5 runs of 5, 49-50 of 100 -- i.e.
#           essentially every refresh in the querytree arm.  Signal: an error
#           naming the inner matview, a dead backend, or either matview
#           disagreeing with itself.
#
#   serial  Overlapping refreshes serialize (what A3's FOR UPDATE is for).
#           A writer drives the base monotonically upward while N sessions
#           refresh the same scope.  If the refreshes serialize, each one takes
#           its snapshot after the previous commits, so the matview's total over
#           the scope can only ever rise.  If they do not, two can compute from
#           different snapshots and the older one can commit last -- a lost
#           update, seen as the total going DOWN.  Signal: any decrease.
#
# There is a half of P1 that serial structurally cannot reach, and it is worth
# knowing rather than discovering later.  serial only ever UPDATEs, so every key
# it touches already exists in the matview and every overlapping refresh is made
# to wait on the locking SELECT.  A key the matview does not hold yet locks
# nothing, so a refresh creating one runs unordered beside a wider refresh over
# the same scope -- and a prune that reads the matview at a different moment
# than it computed its rows will delete it.
#
# An insert-driven mode for that was written and measured against a build with
# the bug deliberately present.  It reported a clean run: the window is
# microseconds wide and the violation needs two commits inside it, so chance
# does not land there.  It was deleted rather than kept as a detector that has
# been watched not to detect.  The gate is deterministic instead --
# injection_points/specs/matview-where-prune-gap.spec.
#
# Why a decrease and not a final comparison: after the writers stop, any further
# refresh repairs the matview, so a converge-at-the-end check cannot see this
# class at all.  The violation is only visible while it is happening, which is
# the same reason P1 needs a reader rather than an end-state assertion.
#
# CALIBRATION, most recent (calibrate-fuzz.sh, ITER=25 REFRESHERS=4).  Every
# mutation is applied to matview.c, the tree rebuilt, and the whole fuzzer run
# against it:
#
#   M1  CAUGHT   p2 + nest   72 of 100 deadlocked
#   M2  CAUGHT   p3          25 of 50 deadlocked
#   M3  CAUGHT   serial      32 lost updates
#   M6  CAUGHT   serial      27 lost updates
#   C2  CAUGHT   nest        50 of 100 executed the inner matview's plan
#   A4  CAUGHT   all four    100 of 100 refreshes failed
#   B4  MISSED   --          see below
#   pristine     QUIET
#
# B4's miss is a fixture limitation and not a hole to fix here.  It duplicates
# NULL-keyed rows, and this fixture is `id int PRIMARY KEY` with a unique index
# on id, so the mutation has nothing to act on.  Data shapes with NULL keys and
# multiple unique indexes belong to the differential corpus (23 of them), which
# is where they are.  This instrument's job is concurrency.
#
# Probabilistic, and honest about it: absence of a failure over N iterations is
# not proof.  It is a correctness gate -- it fails when the matview is wrong and
# not when it is merely built differently -- which is the property that matters.
set -u

PORT=${1:-5610}
DB=${2:-postgres}
shift 2 2>/dev/null || true
MODES=${*:-p2 p3 serial nest}

: "${PSQL_BIN:=psql}"
ITER=${ITER:-40}
ROWS=${ROWS:-40000}
HOT=${HOT:-3000}
REFRESHERS=${REFRESHERS:-4}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
PGOPTIONS="-c client_min_messages=warning"; export PGOPTIONS
PSQL="$PSQL_BIN -X -q -p $PORT -d $DB"

fail=0
say() { printf '%s\n' "$*"; }

# ---------------------------------------------------------------- setup ----
# Physical order is the reverse of key order, so a sequential scan and an index
# scan on id visit the in-scope rows in opposite orders.  That is what makes the
# two predicates below take their locks in different orders when nothing forces
# a common one.
# Exit 2, not 1, when the fixture itself fails to build.  A detector that
# cannot tell "the bug fired" from "the setup broke" reports both as a catch,
# which is how a leftover procedure from an earlier run turned every mutation
# into a CAUGHT and pristine into a false positive.
setup() {
    $PSQL -v ON_ERROR_STOP=1 >/dev/null <<SQL || exit 2
DROP MATERIALIZED VIEW IF EXISTS fz_mv;
DROP TABLE IF EXISTS fz_base, fz_viol, fz_stop, fz_stat;
DROP PROCEDURE IF EXISTS fz_write();
DROP PROCEDURE IF EXISTS fz_watch();
CREATE TABLE fz_base (id int PRIMARY KEY, tag text, v bigint);
INSERT INTO fz_base
  SELECT g, CASE WHEN g <= $HOT THEN 'hot' ELSE 'cold' END, g
    FROM generate_series($ROWS, 1, -1) g;
CREATE MATERIALIZED VIEW fz_mv AS SELECT id, tag, v FROM fz_base;
CREATE UNIQUE INDEX fz_mv_id ON fz_mv(id);
ANALYZE fz_base; ANALYZE fz_mv;
SQL
}

# Both predicates select exactly the rows id <= HOT.  They must plan
# differently or the reproducer proves nothing, so check rather than assume.
check_plans() {
    a=$($PSQL -Atc "EXPLAIN (COSTS OFF) SELECT 1 FROM fz_mv mv WHERE (id <= $HOT)" | head -1)
    b=$($PSQL -Atc "EXPLAIN (COSTS OFF) SELECT 1 FROM fz_mv mv WHERE (tag = 'hot')" | head -1)
    if [ "$a" = "$b" ]; then
        say "  WARNING: both predicates plan as '$a'; this mode cannot deadlock"
        return 1
    fi
    say "  plans differ: '$a' vs '$b'"
    return 0
}

deadlocks_in() { grep -c 'deadlock detected' "$1" 2>/dev/null || true; }

# Errors that are NOT deadlocks.
#
# p2 and p3 counted deadlocks, and deadlocks only.  A mutation that stops every
# refresh from running at all therefore reported a clean pass: measured with A4
# applied, which drops ON CONFLICT so each refresh dies of a unique violation --
# 40 of 40 failed, the transactions rolled back, the matview was consequently
# still correct, and the run said "ok: no deadlocks" and "matview matches its
# definition" and exited 0.  Two green assertions, zero refreshes.
#
# Deadlocks stay counted separately because for p2 and p3 they are the SIGNAL,
# not a failure of the harness.
# NB the anchor.  psql -f prefixes every message with "psql:FILE:LINE: ", so a
# '^ERROR:' pattern matches output from -c and silently never matches output
# from -f.  That bug is not hypothetical: it is what made the nest mode below
# report nine consecutive clean runs against a build with the guard removed,
# and the negative calibration written on the strength of those runs was wrong.
# Match both forms, and only the ERROR line, so DETAIL and CONTEXT are not
# counted as separate failures.
other_errors_in() {
    grep -E '(^|: )ERROR:' "$1" 2>/dev/null | grep -vc 'deadlock detected' || true
}

# A backend that died takes its output with it, so "no deadlocks" from a file
# that ends early is not a pass.
crashed_in() {
    grep -cE 'server closed the connection|terminating connection due to|server process .* was terminated' \
         "$1" 2>/dev/null || true
}

# The matview must equal its own definition.  p2 and p3 counted deadlocks and
# NOTHING else, so a concurrency bug that corrupted rows without deadlocking was
# invisible to them -- the same shape as a test that cannot fail, one level up.
# Both modes leave the base and the matview in agreement when they finish (p2
# never writes the base; p3's last act before the race is to restore it), so
# this is a cheap end-state gate and not a new fixture.
#
# It is an end-state check and therefore blind to anything that repairs itself,
# which is why `serial` watches for a decrease instead.  Both are needed.
assert_matches() {
    n=$($PSQL -Atc "
      SELECT (SELECT count(*) FROM (SELECT id, tag, v FROM fz_base
                                    EXCEPT ALL
                                    SELECT id, tag, v FROM fz_mv) d)
           + (SELECT count(*) FROM (SELECT id, tag, v FROM fz_mv
                                    EXCEPT ALL
                                    SELECT id, tag, v FROM fz_base) d)")
    if [ "${n:-x}" != "0" ]; then
        say "  FAIL: matview disagrees with its definition in ${n:-?} rows"
        fail=1
        return 1
    fi
    say "  matview matches its definition"
    return 0
}

# ------------------------------------------------------------------- p2 ----
# More sessions, not more iterations.  Measured under M1: ITER=40 over two
# sessions found 4 deadlocks, ITER=150 over the same two found 1 -- the rate is
# per run, not per refresh, because two sessions settle into lockstep and stop
# overlapping in the way that deadlocks.  Adding sessions breaks the lockstep;
# lengthening the run does not.
mode_p2() {
    say "== p2: lock order over existing rows ($REFRESHERS sessions x $ITER)"
    setup
    check_plans || { say "  SKIP"; return 0; }

    : > "$WORKDIR/a.sql"; : > "$WORKDIR/b.sql"
    i=0
    while [ "$i" -lt "$ITER" ]; do
        echo "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE id <= $HOT;" >> "$WORKDIR/a.sql"
        echo "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE tag = 'hot';" >> "$WORKDIR/b.sql"
        i=$((i + 1))
    done

    # Alternate the two predicates across the sessions, so every adjacent pair
    # scans in opposite orders.
    pp=''
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        f=$([ $((j % 2)) -eq 1 ] && echo a || echo b)
        $PSQL -f "$WORKDIR/$f.sql" > "$WORKDIR/p2-$j.out" 2>&1 &
        pp="$pp $!"
        j=$((j + 1))
    done
    wait $pp

    d=0; e=0
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        d=$(( d + $(deadlocks_in "$WORKDIR/p2-$j.out") ))
        e=$(( e + $(other_errors_in "$WORKDIR/p2-$j.out") ))
        j=$((j + 1))
    done

    if [ "$e" -gt 0 ]; then
        say "  FAIL: $e of $((ITER * REFRESHERS)) refreshes failed (not a deadlock)"
        grep -hE '(^|: )ERROR:' "$WORKDIR"/p2-*.out 2>/dev/null | grep -v deadlock | head -2
        fail=1
    fi
    if [ "$d" -gt 0 ]; then
        say "  FAIL: $d of $((ITER * REFRESHERS)) refreshes deadlocked"
        fail=1
    else
        say "  ok: no deadlocks in $((ITER * REFRESHERS)) refreshes"
    fi
    assert_matches
}

# ------------------------------------------------------------------- p3 ----
# The rows have to be absent from the matview for the refresh to INSERT them,
# and they are back in the base by the time the refreshes run, so each iteration
# resets serially and then races the two sessions.
mode_p3() {
    say "== p3: lock order over inserted rows ($ITER rounds x 2 sessions)"
    setup
    check_plans || { say "  SKIP"; return 0; }

    d=0; e=0
    i=0
    while [ "$i" -lt "$ITER" ]; do
        $PSQL -v ON_ERROR_STOP=1 >/dev/null 2>&1 <<SQL
DELETE FROM fz_base WHERE id <= $HOT;
REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE id <= $HOT;
INSERT INTO fz_base
  SELECT g, 'hot', g FROM generate_series($HOT, 1, -1) g;
SQL
        $PSQL -c "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE id <= $HOT;" \
              > "$WORKDIR/pa.out" 2>&1 &
        pa=$!
        $PSQL -c "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE tag = 'hot';" \
              > "$WORKDIR/pb.out" 2>&1 &
        pb=$!
        wait $pa $pb
        d=$(( d + $(deadlocks_in "$WORKDIR/pa.out") + $(deadlocks_in "$WORKDIR/pb.out") ))
        e=$(( e + $(other_errors_in "$WORKDIR/pa.out") + $(other_errors_in "$WORKDIR/pb.out") ))
        i=$((i + 1))
    done

    if [ "$e" -gt 0 ]; then
        say "  FAIL: $e of $((ITER * 2)) refreshes failed (not a deadlock)"
        fail=1
    fi
    if [ "$d" -gt 0 ]; then
        say "  FAIL: $d of $((ITER * 2)) refreshes deadlocked"
        fail=1
    else
        say "  ok: no deadlocks in $((ITER * 2)) refreshes"
    fi
    assert_matches
}

# --------------------------------------------------------------- serial ----
mode_serial() {
    say "== serial: overlapping refreshes serialize ($REFRESHERS sessions x $ITER)"
    setup

    $PSQL -v ON_ERROR_STOP=1 >/dev/null <<SQL || exit 2
CREATE TABLE fz_viol(t timestamptz, prev bigint, cur bigint);
CREATE TABLE fz_stop(x bool);
CREATE TABLE fz_stat(polls bigint);

-- Both of these run until the refreshers are finished rather than for a fixed
-- count, and that is not a detail.  With a fixed count the writer ran out long
-- before the refreshes did, so most of the run raced over a base nobody was
-- changing -- where no lost update is possible even under a mutation that
-- guarantees them.  Measured: M6 detected in 1 run out of 4.  Driving the
-- writer for the whole window is what makes the detector a gate rather than a
-- coin flip.
CREATE OR REPLACE PROCEDURE fz_write() LANGUAGE plpgsql AS \$\$
BEGIN
  LOOP
    UPDATE fz_base SET v = v + 1 WHERE id <= $HOT;
    COMMIT;
    EXIT WHEN EXISTS (SELECT 1 FROM fz_stop);
  END LOOP;
END \$\$;

-- COMMIT before each read, or the whole loop runs on one snapshot and sees
-- nothing move.  A decrease means an older snapshot committed after a newer
-- one: the refreshes did not serialize.
CREATE OR REPLACE PROCEDURE fz_watch() LANGUAGE plpgsql AS \$\$
DECLARE last bigint := -1; cur bigint; n bigint := 0;
BEGIN
  LOOP
    COMMIT;
    SELECT coalesce(sum(v), 0) INTO cur FROM fz_mv WHERE id <= $HOT;
    IF cur < last THEN
      INSERT INTO fz_viol VALUES (clock_timestamp(), last, cur);
    END IF;
    last := cur;
    n := n + 1;
    EXIT WHEN EXISTS (SELECT 1 FROM fz_stop);
  END LOOP;
  INSERT INTO fz_stat VALUES (n);
END \$\$;
SQL

    : > "$WORKDIR/r.sql"
    i=0
    while [ "$i" -lt "$ITER" ]; do
        echo "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE id <= $HOT;" >> "$WORKDIR/r.sql"
        i=$((i + 1))
    done

    $PSQL -c "CALL fz_write();" > "$WORKDIR/w.out" 2>&1 &  pw=$!
    $PSQL -c "CALL fz_watch();" > "$WORKDIR/m.out" 2>&1 &  pm=$!

    rp=''
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        $PSQL -f "$WORKDIR/r.sql" > "$WORKDIR/r$j.out" 2>&1 &
        rp="$rp $!"
        j=$((j + 1))
    done
    wait $rp

    # Refreshers are done; release the writer and the watcher.
    $PSQL -c "INSERT INTO fz_stop VALUES (true)" >/dev/null 2>&1
    wait $pw $pm

    v=$($PSQL -Atc "SELECT count(*) FROM fz_viol")
    d=0; e=0
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        d=$(( d + $(deadlocks_in "$WORKDIR/r$j.out") ))
        e=$(( e + $(other_errors_in "$WORKDIR/r$j.out") ))
        j=$((j + 1))
    done
    if [ "$e" -gt 0 ]; then
        say "  FAIL: $e of $((ITER * REFRESHERS)) refreshes failed (not a deadlock)"
        grep -hE '(^|: )ERROR:' "$WORKDIR"/r*.out 2>/dev/null | grep -v deadlock | head -2
        fail=1
    fi

    if [ "${v:-0}" -gt 0 ]; then
        say "  FAIL: $v lost updates (matview total went backwards)"
        $PSQL -c "SELECT prev, cur, prev - cur AS lost FROM fz_viol LIMIT 3"
        fail=1
    elif [ "$d" -gt 0 ]; then
        say "  FAIL: $d refreshes deadlocked"
        fail=1
    else
        say "  ok: no lost updates ($($PSQL -Atc 'SELECT polls FROM fz_stat') polls)"
    fi
}


# ----------------------------------------------------------------- nest ----
# B14's class, under concurrency: a refresh whose own view definition issues
# another REFRESH ... WHERE.
#
# Why this mode exists.  ISSUES.md's note on B14 says the declared suite was
# green throughout, on an assertions build, while a nested partial refresh could
# execute another matview's plan -- "no test in it nests a refresh, so nothing
# could have caught this".  matview_where_cache Test 5 closed that for a single
# session.  This closes it for concurrent ones, and they are not the same test.
#
# What concurrency adds, specifically -- and the first version of this mode got
# it wrong, which is worth recording.  The draft assumed concurrent refreshes
# would supply the relcache invalidations that make the sweep bite, so no DDL
# was needed.  They do not: ISSUES.md B16 established that a partial refresh
# emits NO relcache invalidation, because SetMatViewPopulatedState() early-
# returns when the state already matches and an in-place pg_class update queues
# its invalidation for commit rather than delivering it mid-transaction.  Run
# that way the mode passed with the guard deliberately removed -- a detector
# watched not to detect, which is what this file's header says an earlier mode
# was deleted for.
#
# So there is an invalidator session, and it is what makes this a different test
# from Test 5 rather than a slower copy of it.  Test 5 issues its own ALTER
# TABLE from the refreshing backend, at a fixed point inside the nested call.
# Here the DDL commits in ANOTHER backend and is picked up wherever this one
# next calls AcceptInvalidationMessages() -- which LockRelationOid() does, so
# the nested refresh's own table_open() is one such point.  That is
# SPECIALIZE.md 7a's observation used as a weapon: holding a lock does not stop
# your own backend from processing queued invalidations.
#
# Both names inside the function are schema-qualified, and that is load-bearing
# rather than tidy.  REFRESH runs its query under RestrictSearchPath(), so an
# unqualified name does not resolve, the statement raises, the EXCEPTION block
# swallows it, and the nested refresh never runs at all.  That is exactly how
# the first version of Test 5 passed against the unfixed code -- RESULTS.md R23.
#
# CALIBRATION: catches mutations.py C2 -- the B14 guard removed, so a nested
# refresh shares the session cache and the use-after-free is live -- in 5 runs of
# 5, at 49-50 of 100, which is essentially every refresh in the querytree arm.
#
# An earlier version of this comment recorded the opposite, on nine consecutive
# clean runs against that same broken build, and concluded the mode could not
# gate B14's class.  That was wrong, and the cause was one character of grep:
# the wrong-plan counter was anchored '^ERROR:', psql prefixes every message
# from -f with "psql:FILE:LINE: ", and the pattern therefore could not match the
# output this mode produces.  The mode had been working the whole time.
#
# Worth stating plainly, because it is the fourth instrument in this directory
# to fail silently: a detector reporting zero is indistinguishable from a
# detector that cannot report.  The only defence is running it against a build
# where the bug is known to be present -- which is what calibrate-fuzz.sh is
# for, and what should have been done before writing any calibration down.
#
# Three signals, because the failure has three faces (RESULTS.md R22):
#   wrong plan   the outer refresh executes the INNER matview's plan and reports
#                "cannot change materialized view fz_nest_inner" -- an error
#                naming a matview the statement never mentioned
#   crash        a backend dies on freed memory
#   corruption   neither of the above, but the matview no longer matches its
#                own definition
# The nested refresh always fails legitimately -- rows in a second matview
# cannot be locked while the first is being maintained -- and that error is
# trapped, so on a correct build NO error should reach the client.
mode_nest() {
    say "== nest: concurrent refreshes whose view definition nests a refresh"
    say "        ($REFRESHERS sessions x $ITER)"

    $PSQL -v ON_ERROR_STOP=1 >/dev/null <<SQL || exit 2
DROP MATERIALIZED VIEW IF EXISTS public.fz_nest_mv;
DROP MATERIALIZED VIEW IF EXISTS public.fz_nest_inner;
DROP TABLE IF EXISTS public.fz_nest_base, public.fz_nest_ibase, public.fz_nest_stop CASCADE;
DROP PROCEDURE IF EXISTS public.fz_nest_churn();
DROP FUNCTION IF EXISTS public.fz_nest_f(int);

CREATE TABLE public.fz_nest_base (id int PRIMARY KEY, v bigint);
CREATE TABLE public.fz_nest_ibase (id int PRIMARY KEY, v bigint);
INSERT INTO public.fz_nest_base  SELECT g, g FROM generate_series(1, 200) g;
INSERT INTO public.fz_nest_ibase SELECT g, g FROM generate_series(1, 200) g;

CREATE MATERIALIZED VIEW public.fz_nest_inner AS
  SELECT id, v FROM public.fz_nest_ibase;
CREATE UNIQUE INDEX ON public.fz_nest_inner(id);

-- Defined as a no-op first, so creating the outer matview does not itself nest.
-- That leaves the inner matview with no cache entry when the nesting starts,
-- which is the state the reproducer needed.
CREATE FUNCTION public.fz_nest_f(x int) RETURNS int LANGUAGE plpgsql VOLATILE
AS \$\$ BEGIN RETURN x; END \$\$;

CREATE MATERIALIZED VIEW public.fz_nest_mv AS
  SELECT id, public.fz_nest_f(v::int) AS v FROM public.fz_nest_base;
CREATE UNIQUE INDEX ON public.fz_nest_mv(id);

CREATE OR REPLACE FUNCTION public.fz_nest_f(x int) RETURNS int LANGUAGE plpgsql
VOLATILE AS \$\$
BEGIN
  BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.fz_nest_inner WHERE id = 1;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN x;
END \$\$;

CREATE TABLE public.fz_nest_stop(x bool);

-- The invalidator.  ALTER TABLE ... SET is used rather than ANALYZE for the
-- reason B16 records: ANALYZE was measured NOT to be sufficient to mark an
-- entry stale, because its pg_class update is in-place and queues for commit.
-- This one commits each time, so the message is delivered to other backends.
CREATE OR REPLACE PROCEDURE public.fz_nest_churn() LANGUAGE plpgsql AS \$\$
DECLARE flip bool := true;
BEGIN
  LOOP
    EXECUTE format('ALTER TABLE public.fz_nest_ibase SET (autovacuum_enabled = %s)',
                   flip);
    flip := NOT flip;
    COMMIT;
    EXIT WHEN EXISTS (SELECT 1 FROM public.fz_nest_stop);
  END LOOP;
END \$\$;
SQL

    # Both GUC arms, and which one is the detector is not symmetric.  On the
    # TEXT path the freed plan keeps executing -- SPI is handed the pointer once
    # and cacheEntry is never re-read -- so the damage is a garbage query_string
    # or a crash, and on a -O2 build without CLOBBER_FREED_MEMORY the freed
    # bytes are usually still intact and nothing shows.  On the QUERY-TREE path
    # the enclosing refresh picks up the nested matview's plan out of the reused
    # element and says so, by name.  Run both; expect the second to be the one
    # that fires.  matview_where_cache Test 5 records the same asymmetry.
    #
    # This used to run two arms, one per implementation, and only the
    # Query-tree one could fire -- R30 caught C2 at 49-50 of 100 there and never
    # in the other.  The text implementation is gone, so the surviving arm is
    # the one that always did the detecting; the iteration count halves and the
    # detection does not.
    for arm in on; do
        : > "$WORKDIR/n-$arm.sql"
        i=0
        while [ "$i" -lt "$ITER" ]; do
            # Vary the scope so adjacent sessions do not settle into lockstep,
            # the same reason p2 adds sessions rather than iterations.
            echo "REFRESH MATERIALIZED VIEW CONCURRENTLY public.fz_nest_mv WHERE id <= $(( (i % 5) * 20 + 20 ));" \
                >> "$WORKDIR/n-$arm.sql"
            i=$((i + 1))
        done
    done

    $PSQL -c "CALL public.fz_nest_churn();" > "$WORKDIR/nc.out" 2>&1 &  pc=$!

    np=''
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        # Alternate the arms across sessions so both run under the same
        # invalidation traffic rather than in separate quieter windows.
        a=$([ $((j % 2)) -eq 1 ] && echo on || echo off)
        $PSQL -f "$WORKDIR/n-$a.sql" > "$WORKDIR/n$j.out" 2>&1 &
        np="$np $!"
        j=$((j + 1))
    done
    wait $np
    $PSQL -c "INSERT INTO public.fz_nest_stop VALUES (true)" >/dev/null 2>&1
    wait $pc

    errs=0; crash=0; wrongplan=0
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        errs=$((  errs  + $(grep -cE '(^|: )ERROR:' "$WORKDIR/n$j.out" 2>/dev/null || true) ))
        crash=$(( crash + $(crashed_in "$WORKDIR/n$j.out") ))
        # Anchor on the ERROR line.  A bare match counts the CONTEXT line too
        # and reports exactly double, which looks like a rate rather than a
        # miscount and would have been quoted as one.
        wrongplan=$(( wrongplan + $(grep -cE '(^|: )ERROR:.*fz_nest_inner' "$WORKDIR/n$j.out" 2>/dev/null || true) ))
        j=$((j + 1))
    done

    # The outer statement never names the inner matview, so seeing it in an
    # error from a refresh of fz_nest_mv means the outer executed the inner's
    # cached plan.  That is B14's first and worst symptom.
    if [ "$crash" -gt 0 ]; then
        say "  FAIL: $crash session(s) lost the connection -- backend died"
        fail=1
    elif [ "$wrongplan" -gt 0 ]; then
        say "  FAIL: $wrongplan of $((ITER * REFRESHERS)) refreshes executed the INNER matview's plan"
        grep -m2 -A1 -E '(^|: )ERROR:' "$WORKDIR"/n*.out 2>/dev/null | head -6
        fail=1
    elif [ "$errs" -gt 0 ]; then
        say "  FAIL: $errs unexpected error(s) reached the client"
        grep -m3 -E '(^|: )ERROR:' "$WORKDIR"/n*.out 2>/dev/null
        fail=1
    else
        say "  ok: no errors in $((ITER * REFRESHERS)) nested refreshes"
    fi

    n=$($PSQL -Atc "
      SELECT (SELECT count(*) FROM (SELECT id, v FROM public.fz_nest_base
                                    EXCEPT ALL
                                    SELECT id, v FROM public.fz_nest_mv) d)
           + (SELECT count(*) FROM (SELECT id, v FROM public.fz_nest_mv
                                    EXCEPT ALL
                                    SELECT id, v FROM public.fz_nest_base) d)")
    if [ "${n:-x}" != "0" ]; then
        say "  FAIL: outer matview disagrees with its definition in ${n:-?} rows"
        fail=1
    else
        say "  outer matview matches its definition"
    fi

    # The nested refresh can never succeed, so the inner matview must be
    # untouched.  If it moved, the guard let a nested refresh commit.
    m=$($PSQL -Atc "
      SELECT count(*) FROM (SELECT id, v FROM public.fz_nest_ibase
                            EXCEPT ALL
                            SELECT id, v FROM public.fz_nest_inner) d")
    if [ "${m:-x}" != "0" ]; then
        say "  FAIL: inner matview moved -- a nested refresh committed"
        fail=1
    fi
}

# ------------------------------------------------------------------ main ----
for m in $MODES; do
    case "$m" in
    p2)     mode_p2 ;;
    p3)     mode_p3 ;;
    serial) mode_serial ;;
    nest)   mode_nest ;;
    *)      say "unknown mode $m"; exit 2 ;;
    esac
done

$PSQL -c "DROP MATERIALIZED VIEW IF EXISTS fz_mv" \
      -c "DROP MATERIALIZED VIEW IF EXISTS public.fz_nest_mv" \
      -c "DROP MATERIALIZED VIEW IF EXISTS public.fz_nest_inner" \
      -c "DROP TABLE IF EXISTS fz_base, fz_viol" \
      -c "DROP TABLE IF EXISTS public.fz_nest_base, public.fz_nest_ibase, public.fz_nest_stop" \
      -c "DROP PROCEDURE IF EXISTS public.fz_nest_churn()" \
      -c "DROP FUNCTION IF EXISTS public.fz_nest_f(int)" >/dev/null 2>&1

[ "$fail" -eq 0 ] && say "PASS" || say "FAIL"
exit $fail
