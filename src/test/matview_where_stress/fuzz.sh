#!/bin/sh
#
# Concurrent correctness fuzzer for REFRESH MATERIALIZED VIEW ... WHERE ...
#
#   ./fuzz.sh [PORT] [DB] [MODE ...]      modes: p2 p3 serial   (default: all)
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
# Probabilistic, and honest about it: absence of a failure over N iterations is
# not proof.  It is a correctness gate -- it fails when the matview is wrong and
# not when it is merely built differently -- which is the property that matters.
set -u

PORT=${1:-5610}
DB=${2:-postgres}
shift 2 2>/dev/null || true
MODES=${*:-p2 p3 serial}

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

    d=0
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        d=$(( d + $(deadlocks_in "$WORKDIR/p2-$j.out") ))
        j=$((j + 1))
    done

    if [ "$d" -gt 0 ]; then
        say "  FAIL: $d of $((ITER * REFRESHERS)) refreshes deadlocked"
        fail=1
    else
        say "  ok: no deadlocks in $((ITER * REFRESHERS)) refreshes"
    fi
}

# ------------------------------------------------------------------- p3 ----
# The rows have to be absent from the matview for the refresh to INSERT them,
# and they are back in the base by the time the refreshes run, so each iteration
# resets serially and then races the two sessions.
mode_p3() {
    say "== p3: lock order over inserted rows ($ITER rounds x 2 sessions)"
    setup
    check_plans || { say "  SKIP"; return 0; }

    d=0
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
        i=$((i + 1))
    done

    if [ "$d" -gt 0 ]; then
        say "  FAIL: $d of $((ITER * 2)) refreshes deadlocked"
        fail=1
    else
        say "  ok: no deadlocks in $((ITER * 2)) refreshes"
    fi
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
    d=0
    j=1
    while [ "$j" -le "$REFRESHERS" ]; do
        d=$(( d + $(deadlocks_in "$WORKDIR/r$j.out") ))
        j=$((j + 1))
    done

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

# ------------------------------------------------------------------ main ----
for m in $MODES; do
    case "$m" in
    p2)     mode_p2 ;;
    p3)     mode_p3 ;;
    serial) mode_serial ;;
    *)      say "unknown mode $m"; exit 2 ;;
    esac
done

$PSQL -c "DROP MATERIALIZED VIEW IF EXISTS fz_mv" \
      -c "DROP TABLE IF EXISTS fz_base, fz_viol" >/dev/null 2>&1

[ "$fail" -eq 0 ] && say "PASS" || say "FAIL"
exit $fail
