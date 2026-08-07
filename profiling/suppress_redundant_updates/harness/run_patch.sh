#!/bin/bash
# Compare stock / trigger / reloption on the patched server (port 55433).
set -u
BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
PGB=/home/user/pgbuild-patched/bin
PGDATA=$BASE/pgdata_patched
PERF=/usr/lib/linux-tools-6.8.0-106/perf
FG=$BASE/FlameGraph
OUT=$BASE/results_patch
D=$BASE/bench

DURATION=${DURATION:-20}
REPS=${REPS:-3}
mkdir -p "$OUT"; chown ubuntu:ubuntu "$OUT" 2>/dev/null
export PGPORT=55433 PGHOST=/tmp PGDATABASE=bench HOME=/home/ubuntu
PGRUN="setpriv --reuid=1000 --regid=1000 --clear-groups"
log() { echo "[$(date +%T)] $*"; }

$PGRUN $PGB/pg_ctl -D "$PGDATA" -l "$BASE/results/server_patched.log" -w start >/dev/null 2>&1
sleep 1

if ! $PGRUN $PGB/psql -U postgres -d bench -tAc "select 1 from pg_class where relname='t_wide_reloption'" 2>/dev/null | grep -q 1; then
  log "creating bench database on patched server"
  $PGRUN $PGB/psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS bench" >/dev/null 2>&1
  $PGRUN $PGB/psql -U postgres -d postgres -c "CREATE DATABASE bench" >/dev/null 2>&1
  $PGRUN $PGB/psql -U postgres -d bench -f "$D/setup_patch.sql" > "$OUT/setup.log" 2>&1 || {
    log "setup failed"; tail -20 "$OUT/setup.log"; exit 1; }
fi
log "data ready"

for v in plain trigger reloption; do
  for shape in narrow wide; do
    cat > "$D/p_${shape}_${v}_redundant.sql" <<EOF
\set id random(1, 100000)
UPDATE t_${shape}_${v} SET a = a, b = b WHERE id = :id;
EOF
    cat > "$D/p_${shape}_${v}_changing.sql" <<EOF
\set id random(1, 100000)
UPDATE t_${shape}_${v} SET a = a + 1, b = b + 1 WHERE id = :id;
EOF
  done
done

run() {  # name, table
  local name=$1 tbl=$2 vals=() t med
  for r in $(seq 1 $REPS); do
    $PGRUN $PGB/psql -U postgres -d bench -c "VACUUM FULL $tbl" >/dev/null 2>&1
    $PGRUN $PGB/psql -U postgres -d bench -c "ANALYZE $tbl" >/dev/null 2>&1
    $PGRUN $PGB/psql -U postgres -d bench -c "CHECKPOINT" >/dev/null 2>&1
    $PGRUN $PGB/pgbench -n -M prepared -c1 -T 4 -f "$D/$name.sql" -U postgres bench >/dev/null 2>&1
    t=$($PGRUN $PGB/pgbench -n -M prepared -c1 -j1 -T $DURATION -f "$D/$name.sql" -U postgres bench 2>&1 \
        | grep -E '^tps' | head -1 | awk '{print $3}')
    vals+=("$t"); log "  $name rep$r tps=$t"
  done
  med=$(printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  echo "$name $med" >> "$OUT/tps.txt"
  log "$name MEDIAN=$med"
}

: > "$OUT/tps.txt"
for shape in narrow wide; do
  for v in plain trigger reloption; do
    run "p_${shape}_${v}_redundant" "t_${shape}_${v}"
  done
done
for v in plain trigger reloption; do
  run "p_narrow_${v}_changing" "t_narrow_${v}"
done

log "WAL accounting"
$PGRUN $PGB/psql -U postgres -d bench -f "$D/wal_patch.sql" > "$OUT/wal.txt" 2>&1

log "profiling the reloption path"
$PGRUN $PGB/pgbench -n -M prepared -c1 -j1 -T 40 -f "$D/p_narrow_reloption_redundant.sql" -U postgres bench > "$OUT/prof.pgbench" 2>&1 &
pgb=$!
sleep 4
bepid=$($PGRUN $PGB/psql -U postgres -d bench -tAc "select pid from pg_stat_activity where application_name='pgbench' and backend_type='client backend' limit 1")
if [ -n "$bepid" ]; then
  $PERF record -F 999 --call-graph fp -p "$bepid" -o "$OUT/reloption.data" -- sleep 30 >/dev/null 2>&1
  wait $pgb
  $PERF script -i "$OUT/reloption.data" > "$OUT/reloption.script" 2>/dev/null
  "$FG/stackcollapse-perf.pl" "$OUT/reloption.script" > "$OUT/reloption.folded" 2>/dev/null
  "$FG/flamegraph.pl" --title "narrow redundant UPDATE with suppress_redundant_updates reloption" \
      --width 1400 --colors hot "$OUT/reloption.folded" > "$OUT/reloption.svg" 2>/dev/null
  log "reloption.svg written"
else
  wait $pgb
fi

log "PATCHBENCH DONE"
cat "$OUT/tps.txt"
