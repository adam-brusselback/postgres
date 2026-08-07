#!/bin/bash
# Profile suppress_redundant_updates_trigger across several update workloads.
set -u

BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
PGBIN=/home/user/pgbuild/bin
PGDATA=$BASE/pgdata
PERF=/usr/lib/linux-tools-6.8.0-106/perf
FG=$BASE/FlameGraph
OUT=$BASE/results
D=$BASE/bench

DURATION=${DURATION:-40}     # pgbench run seconds
PROFILE=${PROFILE:-30}       # perf record seconds
WARMUP=${WARMUP:-6}

mkdir -p "$OUT"
export PGPORT=55432
export PGHOST=/tmp
export PGDATABASE=bench
export HOME=/home/ubuntu

# postgres refuses to run as root; drop to uid 1000 for all server/client work.
# perf itself stays root so it can attach to the unprivileged backend.
PGRUN="setpriv --reuid=1000 --regid=1000 --clear-groups"

log() { echo "[$(date +%T)] $*"; }

##############################################################################
# 1. init cluster
##############################################################################
if [ ! -f "$PGDATA/PG_VERSION" ]; then
  log "initdb"
  $PGRUN $PGBIN/initdb -D "$PGDATA" -U postgres --no-sync >"$OUT/initdb.log" 2>&1 || exit 1
  cat >> "$PGDATA/postgresql.conf" <<EOF
port = 55432
unix_socket_directories = '/tmp'
listen_addresses = ''
shared_buffers = 1GB
work_mem = 16MB
maintenance_work_mem = 256MB
max_wal_size = 8GB
min_wal_size = 2GB
checkpoint_timeout = 30min
fsync = off
synchronous_commit = off
full_page_writes = off
autovacuum = off
track_activities = on
EOF
fi

$PGRUN $PGBIN/pg_ctl -D "$PGDATA" -l "$OUT/server.log" -w start >/dev/null 2>&1
sleep 1
$PGRUN $PGBIN/psql -U postgres -d postgres -c "SELECT 1" >/dev/null 2>&1 || { log "server failed"; tail -20 "$OUT/server.log"; exit 1; }
log "server up"

##############################################################################
# 2. load data
##############################################################################
if ! $PGRUN $PGBIN/psql -U postgres -d bench -tAc "select 1 from pg_class where relname='t_wide_trig'" 2>/dev/null | grep -q 1; then
  log "creating database + tables (this takes a minute)"
  $PGRUN $PGBIN/psql -U postgres -d postgres -c "DROP DATABASE IF EXISTS bench" >/dev/null 2>&1
  $PGRUN $PGBIN/psql -U postgres -d postgres -c "CREATE DATABASE bench" >/dev/null 2>&1
  $PGRUN $PGBIN/psql -U postgres -d bench -f "$D/setup.sql" >"$OUT/setup.log" 2>&1 || { log "setup failed"; tail -20 "$OUT/setup.log"; exit 1; }
fi
log "data ready"
$PGRUN $PGBIN/psql -U postgres -d bench -tAc \
  "select relname||' '||pg_size_pretty(pg_relation_size(oid)) from pg_class where relname like 't_%' and relkind='r' order by 1" \
  > "$OUT/table_sizes.txt"

##############################################################################
# 3. run each workload under perf
##############################################################################
run_workload() {
  local name=$1
  local script=$D/$name.sql

  log "--- $name : warmup"
  $PGRUN $PGBIN/pgbench -n -c1 -T $WARMUP -f "$script" -U postgres bench >/dev/null 2>&1

  # Reset the changing-workload tables so every run starts from the same state
  $PGRUN $PGBIN/psql -U postgres -d bench -c "VACUUM (ANALYZE) t_narrow_trig, t_narrow_notrig, t_wide_trig, t_wide_notrig" >/dev/null 2>&1
  $PGRUN $PGBIN/psql -U postgres -d bench -c "CHECKPOINT" >/dev/null 2>&1

  log "--- $name : measuring ${DURATION}s"
  $PGRUN $PGBIN/pgbench -n -c1 -j1 -T $DURATION -P 10 -f "$script" -U postgres bench > "$OUT/$name.pgbench" 2>&1 &
  local pgb=$!

  sleep 4
  local bepid
  bepid=$($PGRUN $PGBIN/psql -U postgres -d bench -tAc \
    "select pid from pg_stat_activity where application_name='pgbench' and backend_type='client backend' limit 1")
  if [ -z "$bepid" ]; then log "!! could not find backend pid for $name"; wait $pgb; return 1; fi
  log "--- $name : backend pid $bepid, perf record ${PROFILE}s"

  $PERF record -F 999 --call-graph fp -p "$bepid" -o "$OUT/$name.data" -- sleep $PROFILE >"$OUT/$name.perf.log" 2>&1

  wait $pgb
  local tps
  tps=$(grep -E '^tps' "$OUT/$name.pgbench" | head -1 | awk '{print $3}')
  log "--- $name : tps=$tps"
  echo "$name $tps" >> "$OUT/tps_summary.txt"
}

rm -f "$OUT/tps_summary.txt"
for w in narrow_notrig_redundant narrow_trig_redundant \
         narrow_notrig_changing  narrow_trig_changing \
         wide_notrig_redundant   wide_trig_redundant \
         wide_notrig_changing    wide_trig_changing ; do
  run_workload "$w"
done

##############################################################################
# 4. flamegraphs
##############################################################################
log "generating flamegraphs"
for f in "$OUT"/*.data; do
  n=$(basename "$f" .data)
  $PERF script -i "$f" > "$OUT/$n.script" 2>/dev/null
  "$FG/stackcollapse-perf.pl" "$OUT/$n.script" > "$OUT/$n.folded" 2>/dev/null
  "$FG/flamegraph.pl" --title "$n" --width 1400 --colors hot \
      "$OUT/$n.folded" > "$OUT/$n.svg" 2>/dev/null
  log "  $n.svg  ($(wc -l < "$OUT/$n.folded") stacks)"
done

log "DONE"
cat "$OUT/tps_summary.txt"
