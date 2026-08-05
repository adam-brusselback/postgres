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
#       mutation space over a 12-row base table, 1636 in all.  There used to be
#       a second form; a predicate requires CONCURRENTLY now, so there is one.
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

# A psql from $PATH is not necessarily this tree's.  The system one connects
# happily to a server several majors newer and then differs in ways that read
# as server behaviour -- which is how this harness spent a run reporting a
# connection failure that was really the wrong client.  Check it once, loudly.
cli=$("$PSQL_BIN" --version | sed 's/.* //; s/[^0-9].*//')
srv=$("$PSQL_BIN" -p "$PORT" -d "$DB" -Atc 'SHOW server_version_num') || exit 2
[ "$cli" = "$((srv / 10000))" ] || {
    printf 'psql is %s, server is %s; set PSQL_BIN to this tree'\''s psql\n' \
        "$cli" "$((srv / 10000))" >&2
    exit 2
}

$PSQL -f "$DIR/cases.sql"
$PSQL -f "$DIR/cases2.sql"
$PSQL -f "$DIR/cases3.sql"
$PSQL -c 'DROP FUNCTION IF EXISTS run_probe(text,text)'
$PSQL -f "$DIR/setup_driver.sql"
$PSQL -c 'DELETE FROM probe_result'
for id in $("$PSQL_BIN" -p "$PORT" -d "$DB" -Atc 'SELECT id FROM probe_case ORDER BY ord'); do
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
    $PSQL -Atc "SELECT run_exh('$id','concurrently')" >/dev/null
done
echo '===== exhaustive: divergence over the full single-row mutation space ====='
"$PSQL_BIN" -p "$PORT" -d "$DB" -c \
  'SELECT id, expect, total, diverged, first_mut, first_pred
     FROM exh_result WHERE form = $$concurrently$$ ORDER BY id'
