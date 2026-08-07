#!/bin/bash
# Phase 3: clean throughput numbers only (no perf attached).
# VACUUM FULL before every run so accumulated bloat from earlier workloads
# cannot skew the trig-vs-notrig comparison. 3 reps, median reported.
set -u

BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
PGBIN=/home/user/pgbuild/bin
PGDATA=$BASE/pgdata
OUT=$BASE/results
D=$BASE/bench

DURATION=${DURATION:-25}
REPS=${REPS:-3}

export PGPORT=55432 PGHOST=/tmp PGDATABASE=bench HOME=/home/ubuntu
PGRUN="setpriv --reuid=1000 --regid=1000 --clear-groups"
log() { echo "[$(date +%T)] $*"; }

$PGRUN $PGBIN/pg_ctl -D "$PGDATA" -l "$OUT/server.log" -w start >/dev/null 2>&1
sleep 1

# name -> tables to reset
declare -A TBL=(
  [narrow_notrig_redundant]="t_narrow_notrig" [narrow_trig_redundant]="t_narrow_trig"
  [narrow_notrig_changing]="t_narrow_notrig"  [narrow_trig_changing]="t_narrow_trig"
  [wide_notrig_redundant]="t_wide_notrig"     [wide_trig_redundant]="t_wide_trig"
  [wide_notrig_changing]="t_wide_notrig"      [wide_trig_changing]="t_wide_trig"
  [idx_notrig_redundant]="t_idx_notrig"       [idx_trig_redundant]="t_idx_trig"
  [idx_notrig_changing]="t_idx_notrig"        [idx_trig_changing]="t_idx_trig"
)

: > "$OUT/tps_clean.txt"
for w in narrow_notrig_redundant narrow_trig_redundant \
         narrow_notrig_changing  narrow_trig_changing \
         wide_notrig_redundant   wide_trig_redundant \
         wide_notrig_changing    wide_trig_changing \
         idx_notrig_redundant    idx_trig_redundant \
         idx_notrig_changing     idx_trig_changing ; do
  tbl=${TBL[$w]}
  vals=()
  for r in $(seq 1 $REPS); do
    # full physical reset so every rep starts from an identical, unbloated table
    $PGRUN $PGBIN/psql -U postgres -d bench -c "VACUUM FULL $tbl" >/dev/null 2>&1
    $PGRUN $PGBIN/psql -U postgres -d bench -c "ANALYZE $tbl" >/dev/null 2>&1
    $PGRUN $PGBIN/psql -U postgres -d bench -c "CHECKPOINT" >/dev/null 2>&1
    $PGRUN $PGBIN/pgbench -n -M prepared -c1 -T 5 -f "$D/$w.sql" -U postgres bench >/dev/null 2>&1
    out=$($PGRUN $PGBIN/pgbench -n -M prepared -c1 -j1 -T $DURATION -f "$D/$w.sql" -U postgres bench 2>&1)
    t=$(grep -E '^tps' <<<"$out" | head -1 | awk '{print $3}')
    vals+=("$t")
    log "  $w rep$r tps=$t"
  done
  med=$(printf '%s\n' "${vals[@]}" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
  echo "$w $med" >> "$OUT/tps_clean.txt"
  log "$w MEDIAN=$med"
done

log "PHASE3 DONE"
column -t "$OUT/tps_clean.txt"
