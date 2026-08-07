#!/bin/bash
# Phase 2: prepared protocol (-M prepared) so planning doesn't dilute the
# executor profile, plus an indexed table where a real update cannot be HOT.
set -u

BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
PGBIN=/home/user/pgbuild/bin
PGDATA=$BASE/pgdata
PERF=/usr/lib/linux-tools-6.8.0-106/perf
FG=$BASE/FlameGraph
OUT=$BASE/results
D=$BASE/bench

DURATION=${DURATION:-40}
PROFILE=${PROFILE:-30}
WARMUP=${WARMUP:-6}

export PGPORT=55432 PGHOST=/tmp PGDATABASE=bench HOME=/home/ubuntu
PGRUN="setpriv --reuid=1000 --regid=1000 --clear-groups"
log() { echo "[$(date +%T)] $*"; }

$PGRUN $PGBIN/pg_ctl -D "$PGDATA" -l "$OUT/server.log" -w start >/dev/null 2>&1
sleep 1

log "phase2 setup (indexed table)"
$PGRUN $PGBIN/psql -U postgres -d bench -f "$D/setup2.sql" >"$OUT/setup2.log" 2>&1 || {
  log "setup2 failed"; tail -20 "$OUT/setup2.log"; exit 1; }

for trig in trig notrig; do
  cat > "$D/idx_${trig}_redundant.sql" <<EOF
\set id random(1, 100000)
UPDATE t_idx_${trig} SET a = a, b = b, c = c WHERE id = :id;
EOF
  cat > "$D/idx_${trig}_changing.sql" <<EOF
\set id random(1, 100000)
UPDATE t_idx_${trig} SET a = a + 1, b = b + 1, c = c || '' WHERE id = :id;
EOF
done

# $1 = output name, $2 = pgbench script basename, $3 = vacuum target list
run_workload() {
  local name=$1 script=$D/$2.sql vac=$3
  log "--- $name : warmup"
  $PGRUN $PGBIN/pgbench -n -M prepared -c1 -T $WARMUP -f "$script" -U postgres bench >/dev/null 2>&1
  $PGRUN $PGBIN/psql -U postgres -d bench -c "VACUUM (ANALYZE) $vac" >/dev/null 2>&1
  $PGRUN $PGBIN/psql -U postgres -d bench -c "CHECKPOINT" >/dev/null 2>&1

  log "--- $name : measuring ${DURATION}s (prepared)"
  $PGRUN $PGBIN/pgbench -n -M prepared -c1 -j1 -T $DURATION -P 10 -f "$script" -U postgres bench > "$OUT/$name.pgbench" 2>&1 &
  local pgb=$!
  sleep 4
  local bepid
  bepid=$($PGRUN $PGBIN/psql -U postgres -d bench -tAc \
    "select pid from pg_stat_activity where application_name='pgbench' and backend_type='client backend' limit 1")
  [ -z "$bepid" ] && { log "!! no backend pid"; wait $pgb; return 1; }
  log "--- $name : backend pid $bepid, perf record ${PROFILE}s"
  $PERF record -F 999 --call-graph fp -p "$bepid" -o "$OUT/$name.data" -- sleep $PROFILE >"$OUT/$name.perf.log" 2>&1
  wait $pgb
  local tps
  tps=$(grep -E '^tps' "$OUT/$name.pgbench" | head -1 | awk '{print $3}')
  log "--- $name : tps=$tps"
  echo "$name $tps" >> "$OUT/tps_summary.txt"
}

NARROW="t_narrow_trig, t_narrow_notrig"
WIDE="t_wide_trig, t_wide_notrig"
IDX="t_idx_trig, t_idx_notrig"

run_workload narrow_notrig_redundant_prep narrow_notrig_redundant "$NARROW"
run_workload narrow_trig_redundant_prep   narrow_trig_redundant   "$NARROW"
run_workload narrow_notrig_changing_prep  narrow_notrig_changing  "$NARROW"
run_workload narrow_trig_changing_prep    narrow_trig_changing    "$NARROW"
run_workload wide_notrig_redundant_prep   wide_notrig_redundant   "$WIDE"
run_workload wide_trig_redundant_prep     wide_trig_redundant     "$WIDE"
run_workload idx_notrig_redundant_prep    idx_notrig_redundant    "$IDX"
run_workload idx_trig_redundant_prep      idx_trig_redundant      "$IDX"
run_workload idx_notrig_changing_prep     idx_notrig_changing     "$IDX"
run_workload idx_trig_changing_prep       idx_trig_changing       "$IDX"

log "generating phase2 flamegraphs"
for f in "$OUT"/*_prep.data; do
  n=$(basename "$f" .data)
  $PERF script -i "$f" > "$OUT/$n.script" 2>/dev/null
  "$FG/stackcollapse-perf.pl" "$OUT/$n.script" > "$OUT/$n.folded" 2>/dev/null
  "$FG/flamegraph.pl" --title "$n" --width 1400 --colors hot "$OUT/$n.folded" > "$OUT/$n.svg" 2>/dev/null
  log "  $n.svg ($(wc -l < "$OUT/$n.folded") stacks)"
done
log "PHASE2 DONE"
