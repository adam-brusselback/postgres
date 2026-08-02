#!/bin/sh
#
# Profile the two implementations against each other, properly.
#
#   ./profile.sh <workload> <shape> <span> [rounds] [seconds] [outdir]
#   ./profile.sh window range 100 3 15
#
# What went wrong the first time, which is why this exists
# --------------------------------------------------------
# The first profile of this comparison was taken by starting run.sh for one
# arm, recording, killing it, starting run.sh for the other arm, and recording
# again.  Four things were wrong with that and each is fixed here:
#
#   1. Each run.sh invocation calls bench_setup(), so the two arms were
#      measured against DIFFERENT fixture instances -- different physical
#      tables, different heap state, different bloat.  Here the fixture is
#      built ONCE, before either arm runs, and neither arm rebuilds it.
#
#   2. The arms were recorded minutes apart, so any machine drift in between
#      landed entirely on one of them.  R33 records 4.0 us of drift between
#      runs of the *same* arm, and the sweep's own lesson (see the timerange
#      retraction in sweep-p21c-O2.md) is that this harness's between-run
#      variance is large enough to invent effects.  Here the arms ALTERNATE
#      within one session and the order flips each round, so drift is
#      distributed rather than assigned.
#
#   3. One capture landed during fixture setup instead of the measurement --
#      it profiled a full rebuild and a DROP CASCADE, and reported 428 samples
#      where the other arm had 5934.  Nothing in the output said so; it had to
#      be noticed.  Here every capture is VALIDATED after the fact: a capture
#      whose samples are not dominated by refresh frames is discarded loudly
#      rather than folded into the result.
#
#   4. The recorder raced an `until` loop against a phase it could not see.
#      Here pgbench is started first, the script waits for an actually-active
#      REFRESH, and only then records -- and the record window is strictly
#      inside pgbench's run so it cannot spill past the end.
#
# settle() between arms is VACUUM (ANALYZE) + CHECKPOINT, the same protocol
# run.sh uses between combinations, because heap state moves this measurement
# more than the code does: R5 reads the same comparison as 54% or 82% depending
# only on whether the heap was settled.
set -eu

W=${1:-window}; SHAPE=${2:-range}; SPAN=${3:-100}
ROUNDS=${4:-3}; SECS=${5:-15}
OUT=${6:-/tmp/prof-$W-$SHAPE-$SPAN}

SCALE=${SCALE:-100000}; GROUPS=${GROUPS:-1000}
PORT=${PORT:-5610}; DB=${DB:-postgres}
BINDIR=${BINDIR:-/home/user/pgsql-opt/bin}
PERF=${PERF:-/usr/lib/linux-tools-6.8.0-136/perf}
FG=${FG:-/opt/FlameGraph}
FREQ=${FREQ:-299}

PSQL="su pgtest -c \"$BINDIR/psql -p $PORT -d $DB -X -q -Atc\""
psql_c() { su pgtest -c "$BINDIR/psql -p $PORT -d $DB -X -q -Atc \"$1\"" 2>/dev/null; }
psql_f() { su pgtest -c "$BINDIR/psql -p $PORT -d $DB -X -q -f $1" >/dev/null 2>&1; }

mkdir -p "$OUT"
DIR=$(cd "$(dirname "$0")" && pwd)

# ---- preflight.  Nothing below is worth doing if any of this is wrong. ----
echo "== preflight"
for tool in "$PERF" "$FG/stackcollapse-perf.pl" "$FG/flamegraph.pl"; do
    [ -x "$tool" ] || { echo "  MISSING: $tool" >&2; exit 1; }
done
stray=$(pgrep -c -f '[r]un\.sh --workloads' 2>/dev/null || true)
[ "${stray:-0}" -eq 0 ] || {
    echo "  a bench sweep is running; it would fight this for the bench schema" >&2
    exit 1; }
stray=$(pgrep -c -f '[p]gbench' 2>/dev/null || true)
[ "${stray:-0}" -eq 0 ] || { echo "  stray pgbench running" >&2; exit 1; }

ASSERT=$(psql_c 'SHOW debug_assertions')
[ -n "$ASSERT" ] || { echo "  server not answering on $PORT" >&2; exit 1; }
[ "$ASSERT" = off ] || echo "  WARNING: assertions ON; not comparable with -O2 numbers" >&2
echo "  server up, assertions=$ASSERT"
echo "  querytree default=$(psql_c 'SHOW matview_partial_refresh_querytree')"
echo "  build: $(psql_c "SELECT setting FROM pg_config() WHERE name='CONFIGURE'")"

# ---- fixture, built once and then left alone ----
echo "== fixture $W scale=$SCALE groups=$GROUPS"
psql_f "$DIR/workloads.sql"
psql_f "$DIR/harness.sql"
MVROWS=$(psql_c "SELECT bench_setup('$W', $SCALE, $GROUPS)")
echo "  mv_rows=$MVROWS"

PREDCOL=$(case $SHAPE in key) echo pred1;; array) echo predn;; range) echo predr;; esac)
PREDT=$(psql_c "SELECT $PREDCOL FROM bench_workload WHERE id='$W'")
ARRLIT="ARRAY["$(i=0; while [ $i -lt "$SPAN" ]; do
                   [ $i -gt 0 ] && printf ,; printf ':k+%s' "$i"; i=$((i+1)); done)"]"
PREDT=$(echo "$PREDT" | sed "s/:arraylit/$ARRLIT/g; s/:span/$SPAN/g")
SCOPE=$(psql_c "SET search_path=bench,public; SELECT bench_scope_rows(\$\$$(echo "$PREDT" | sed 's/:k/1/g')\$\$)")
echo "  predicate: $PREDT"
echo "  scope_rows=$SCOPE"

settle() {
    su pgtest -c "$BINDIR/psql -p $PORT -d $DB -X -q -Atc \"SELECT 'VACUUM (ANALYZE) '||schemaname||'.'||quote_ident(relname)||';' FROM pg_stat_user_tables WHERE schemaname='bench'\"" 2>/dev/null \
      | su pgtest -c "$BINDIR/psql -p $PORT -d $DB -X -q -f -" >/dev/null 2>&1 || true
    psql_c "VACUUM (ANALYZE) bench.mv" >/dev/null 2>&1 || true
    psql_c "CHECKPOINT" >/dev/null 2>&1 || true
}

script_for() {   # $1 = arm
    qt=$([ "$1" = querytree ] && echo on || echo off)
    cat > "$OUT/$1.bench" <<EOS
SET synchronous_commit = off;
SET matview_partial_refresh_querytree = $qt;
SET matview_partial_refresh_optimized = off;
\\set k random(1, greatest(1, 100 - $SPAN))
REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE $PREDT;
EOS
    chmod 644 "$OUT/$1.bench"
}
script_for spi
script_for querytree

# ---- one capture: start load, wait for it to be real, record inside it ----
capture() {   # $1 = arm, $2 = round
    arm=$1; rnd=$2; data="$OUT/$arm.r$rnd.data"
    settle
    su pgtest -c "$BINDIR/pgbench -p $PORT -d $DB -n -c 1 -T $((SECS + 12)) -f $OUT/$arm.bench" \
        > "$OUT/$arm.r$rnd.pgbench" 2>&1 &
    pgb=$!

    # Wait for an actually-active REFRESH rather than assuming one.
    pid=; tries=0
    while [ $tries -lt 60 ]; do
        tries=$((tries + 1))
        pid=$(psql_c "SELECT pid FROM pg_stat_activity WHERE state='active' AND backend_type='client backend' AND query LIKE 'REFRESH%' LIMIT 1")
        [ -n "$pid" ] && break
        sleep 0.5
    done
    [ -n "$pid" ] || { echo "  round $rnd $arm: no REFRESH backend appeared" >&2
                       kill $pgb 2>/dev/null || true; return 1; }

    "$PERF" record -F "$FREQ" -g --call-graph dwarf -p "$pid" -o "$data" \
        -- sleep "$SECS" >/dev/null 2>&1 || true
    kill $pgb 2>/dev/null || true; wait $pgb 2>/dev/null || true

    # Validate: did this capture actually profile refreshes?
    "$PERF" script -i "$data" 2>/dev/null | "$FG/stackcollapse-perf.pl" > "$data.folded" 2>/dev/null
    tot=$(awk '{s+=$NF} END{print s+0}' "$data.folded")
    ref=$(grep -F 'refresh_by_direct_modification' "$data.folded" 2>/dev/null | awk '{s+=$NF} END{print s+0}')
    [ "$tot" -gt 0 ] 2>/dev/null || { echo "  round $rnd $arm: EMPTY capture, discarded" >&2; return 1; }
    pct=$((100 * ref / tot))
    if [ "$pct" -lt 50 ]; then
        echo "  round $rnd $arm: only ${pct}% under refresh_by_direct_modification -- DISCARDED (profiled setup or teardown, not the refresh)" >&2
        return 1
    fi
    echo "  round $rnd $arm: ok, ${pct}% in refresh, $(grep -c . "$data.folded") stacks"
    cat "$data.folded" >> "$OUT/$arm.folded.raw"
    return 0
}

: > "$OUT/spi.folded.raw"; : > "$OUT/querytree.folded.raw"
echo "== capture: $ROUNDS rounds x ${SECS}s per arm, alternating"
r=0
while [ $r -lt "$ROUNDS" ]; do
    r=$((r + 1))
    # Flip the order every round so neither arm is always first after settle().
    if [ $((r % 2)) -eq 1 ]; then a1=spi; a2=querytree; else a1=querytree; a2=spi; fi
    capture "$a1" "$r" || true
    capture "$a2" "$r" || true
done

# ---- sum duplicate stacks, render ----
for arm in spi querytree; do
    awk '{c=$NF; $NF=""; sub(/ $/,""); t[$0]+=c} END{for(k in t) print k, t[k]}' \
        "$OUT/$arm.folded.raw" > "$OUT/$arm.folded"
    n=$(awk '{s+=$NF} END{printf "%d", s/1000000}' "$OUT/$arm.folded")
    "$FG/flamegraph.pl" --title "REFRESH ... WHERE - $arm ($W $SHAPE span $SPAN, scope $SCOPE)" \
        --subtitle "-O2 assertions off; $ROUNDS x ${SECS}s alternating; ~${n}ms CPU" \
        --width 1400 "$OUT/$arm.folded" > "$OUT/$arm.svg" 2>/dev/null
done
"$FG/difffolded.pl" -n "$OUT/spi.folded" "$OUT/querytree.folded" > "$OUT/diff.folded" 2>/dev/null
"$FG/flamegraph.pl" --title "Query-tree vs text: differential (red = more in Query-tree)" \
    --subtitle "$W $SHAPE span $SPAN scope $SCOPE; normalised; alternated $ROUNDS rounds" \
    --width 1400 "$OUT/diff.folded" > "$OUT/diff.svg" 2>/dev/null

echo "== done -> $OUT"
ls -la "$OUT"/*.svg
