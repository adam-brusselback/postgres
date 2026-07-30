#!/bin/sh
# Differential safety oracle for REFRESH MATERIALIZED VIEW ... WHERE ...
#
#   ./run.sh [PORT] [DB]
#
# Two harnesses share one oracle:
#
#   single-shot (cases*.sql + setup_driver.sql)
#       ~40 (view, predicate, mutation) triples, each run once.  Cheap, and
#       carries the planner-signal measurement (residual qual / InitPlan).
#
#   exhaustive (exh*.sql + exh_driver.sql)
#       22 (view, predicate) pairs, each run against its complete single-row
#       mutation space over a 12-row base table.  1636 per form, 3272 total.
#
# The oracle is the same in both: mutate, partial refresh, snapshot, full
# refresh, symmetric difference.  A non-empty difference is a counterexample.
# An empty one is evidence, not proof -- see SAFETY.md.
set -e
PORT=${1:-5599}
DB=${2:-postgres}
DIR=$(dirname "$0")
: "${PSQL_BIN:=psql}"
PGOPTIONS="-c client_min_messages=warning"; export PGOPTIONS
PSQL="$PSQL_BIN -p $PORT -d $DB -q"

$PSQL -f "$DIR/cases.sql"
$PSQL -f "$DIR/cases2.sql"
$PSQL -f "$DIR/cases3.sql"
$PSQL -c 'DROP FUNCTION IF EXISTS run_probe(text,text)'
$PSQL -f "$DIR/setup_driver.sql"
$PSQL -c 'DELETE FROM probe_result'
for id in $("$PSQL_BIN" -p "$PORT" -d "$DB" -Atc 'SELECT id FROM probe_case ORDER BY ord'); do
    $PSQL -Atc "SELECT run_probe('$id','bare')" >/dev/null
    $PSQL -Atc "SELECT run_probe('$id','concurrently')" >/dev/null
done
echo '===== single-shot: planner signal vs measured outcome ====='
"$PSQL_BIN" -p "$PORT" -d "$DB" -f "$DIR/xtab.sql"
"$PSQL_BIN" -p "$PORT" -d "$DB" -f "$DIR/report.sql"

$PSQL -f "$DIR/exh.sql"
$PSQL -f "$DIR/exh2.sql"
$PSQL -f "$DIR/exh3.sql"
$PSQL -c 'DROP FUNCTION IF EXISTS run_exh(text,text)'
$PSQL -f "$DIR/exh_driver.sql"
for id in $("$PSQL_BIN" -p "$PORT" -d "$DB" -Atc 'SELECT id FROM probe_exh ORDER BY ord::int'); do
    $PSQL -Atc "SELECT run_exh('$id','bare')" >/dev/null
    $PSQL -Atc "SELECT run_exh('$id','concurrently')" >/dev/null
done
echo '===== exhaustive: divergence over the full single-row mutation space ====='
"$PSQL_BIN" -p "$PORT" -d "$DB" -c \
  'SELECT id, expect, total, diverged, first_mut, first_pred
     FROM exh_result WHERE form = $$bare$$ ORDER BY id'
