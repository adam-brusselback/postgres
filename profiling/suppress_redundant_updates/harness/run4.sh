#!/bin/bash
# Phase 4: WAL accounting with full_page_writes ON (production default).
# A suppressed UPDATE still dirties the heap page via heap_lock_tuple, so the
# first touch of a page after a checkpoint can still emit a full-page image.
set -u

BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
PGBIN=/home/user/pgbuild/bin
PGDATA=$BASE/pgdata
OUT=$BASE/results
export PGPORT=55432 PGHOST=/tmp PGDATABASE=bench HOME=/home/ubuntu
PGRUN="setpriv --reuid=1000 --regid=1000 --clear-groups"
log() { echo "[$(date +%T)] $*"; }

log "enabling full_page_writes"
$PGRUN $PGBIN/psql -U postgres -d bench -c "ALTER SYSTEM SET full_page_writes = on" >/dev/null 2>&1
$PGRUN $PGBIN/pg_ctl -D "$PGDATA" -w restart -l "$OUT/server.log" >/dev/null 2>&1
sleep 2
$PGRUN $PGBIN/psql -U postgres -d bench -tAc "show full_page_writes"

$PGRUN $PGBIN/psql -U postgres -d bench -f "$BASE/bench/wal.sql" > "$OUT/wal_report_fpw_on.txt" 2>&1
log "wal_report_fpw_on.txt written"

log "restoring full_page_writes = off"
$PGRUN $PGBIN/psql -U postgres -d bench -c "ALTER SYSTEM SET full_page_writes = off" >/dev/null 2>&1
$PGRUN $PGBIN/pg_ctl -D "$PGDATA" -w restart -l "$OUT/server.log" >/dev/null 2>&1
sleep 2
log "PHASE4 DONE"
