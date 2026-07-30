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
#           Two sessions refresh the same rows through predicates that plan
#           differently -- an index scan ascending and a sequential scan over
#           rows inserted in descending order.  Without a common order the two
#           take the same locks in opposite orders.  Signal: deadlock.
#
#   p3      P3, deterministic lock order over INSERTED rows.
#           Same shape, but the rows are absent from the matview so the refresh
#           INSERTs rather than UPDATEs, and the conflict is between two
#           speculative insertions of the same key.  Signal: deadlock.
#
#   serial  Overlapping refreshes serialize (what A3's FOR UPDATE is for).
#           A writer drives the base monotonically upward while two sessions
#           refresh the same scope.  If the refreshes serialize, each one takes
#           its snapshot after the previous commits, so the matview's total over
#           the scope can only ever rise.  If they do not, two can compute from
#           different snapshots and the older one can commit last -- a lost
#           update, seen as the total going DOWN.  Signal: any decrease.
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
SPIN=${SPIN:-300}

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
DROP TABLE IF EXISTS fz_base, fz_viol;
DROP PROCEDURE IF EXISTS fz_write(int);
DROP PROCEDURE IF EXISTS fz_watch(int);
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
mode_p2() {
    say "== p2: lock order over existing rows ($ITER refreshes x 2 sessions)"
    setup
    check_plans || { say "  SKIP"; return 0; }

    : > "$WORKDIR/a.sql"; : > "$WORKDIR/b.sql"
    i=0
    while [ "$i" -lt "$ITER" ]; do
        echo "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE id <= $HOT;" >> "$WORKDIR/a.sql"
        echo "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE tag = 'hot';" >> "$WORKDIR/b.sql"
        i=$((i + 1))
    done

    $PSQL -f "$WORKDIR/a.sql" > "$WORKDIR/a.out" 2>&1 &
    pa=$!
    $PSQL -f "$WORKDIR/b.sql" > "$WORKDIR/b.out" 2>&1 &
    pb=$!
    wait $pa $pb

    d=$(( $(deadlocks_in "$WORKDIR/a.out") + $(deadlocks_in "$WORKDIR/b.out") ))
    if [ "$d" -gt 0 ]; then
        say "  FAIL: $d of $((ITER * 2)) refreshes deadlocked"
        fail=1
    else
        say "  ok: no deadlocks in $((ITER * 2)) refreshes"
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
    say "== serial: overlapping refreshes serialize ($SPIN polls)"
    setup

    $PSQL -v ON_ERROR_STOP=1 >/dev/null <<SQL || exit 2
CREATE TABLE fz_viol(t timestamptz, prev bigint, cur bigint);

-- Drives the scope monotonically upward.  COMMIT per iteration so each refresh
-- has a distinct, newer state to observe.
CREATE OR REPLACE PROCEDURE fz_write(n int) LANGUAGE plpgsql AS \$\$
BEGIN
  FOR i IN 1..n LOOP
    UPDATE fz_base SET v = v + 1 WHERE id <= $HOT;
    COMMIT;
  END LOOP;
END \$\$;

-- COMMIT before each read, or the whole loop runs on one snapshot and sees
-- nothing move.  A decrease means an older snapshot committed after a newer
-- one: the refreshes did not serialize.
CREATE OR REPLACE PROCEDURE fz_watch(n int) LANGUAGE plpgsql AS \$\$
DECLARE last bigint := -1; cur bigint;
BEGIN
  FOR i IN 1..n LOOP
    COMMIT;
    SELECT coalesce(sum(v), 0) INTO cur FROM fz_mv WHERE id <= $HOT;
    IF cur < last THEN
      INSERT INTO fz_viol VALUES (clock_timestamp(), last, cur);
    END IF;
    last := cur;
  END LOOP;
END \$\$;
SQL

    : > "$WORKDIR/r.sql"
    i=0
    while [ "$i" -lt "$ITER" ]; do
        echo "REFRESH MATERIALIZED VIEW CONCURRENTLY fz_mv WHERE id <= $HOT;" >> "$WORKDIR/r.sql"
        i=$((i + 1))
    done

    $PSQL -c "CALL fz_write($ITER);"  > "$WORKDIR/w.out"  2>&1 &  pw=$!
    $PSQL -c "CALL fz_watch($SPIN);"  > "$WORKDIR/m.out"  2>&1 &  pm=$!
    $PSQL -f "$WORKDIR/r.sql"         > "$WORKDIR/r1.out" 2>&1 &  p1=$!
    $PSQL -f "$WORKDIR/r.sql"         > "$WORKDIR/r2.out" 2>&1 &  p2=$!
    wait $pw $pm $p1 $p2

    v=$($PSQL -Atc "SELECT count(*) FROM fz_viol")
    d=$(( $(deadlocks_in "$WORKDIR/r1.out") + $(deadlocks_in "$WORKDIR/r2.out") ))

    if [ "${v:-0}" -gt 0 ]; then
        say "  FAIL: $v lost updates (matview total went backwards)"
        $PSQL -c "SELECT prev, cur, prev - cur AS lost FROM fz_viol LIMIT 3"
        fail=1
    elif [ "$d" -gt 0 ]; then
        say "  FAIL: $d refreshes deadlocked"
        fail=1
    else
        say "  ok: no lost updates over $SPIN polls"
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
