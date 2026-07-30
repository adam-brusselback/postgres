#!/bin/sh
#
# Differential mode over the exhaustive corpus.
#
#   ./rundiff.sh [PORT] [DB] [FORM_A] [FORM_B]
#
# Defaults to bare against concurrently, which are the two implementations that
# exist today.  When the Query-tree path lands behind its GUC, these two
# arguments become the two settings and nothing else changes -- which is the
# point of building and calibrating it now rather than on the first day of
# Phase 2.  See diff_driver.sql.
#
# Kept out of run.sh deliberately: calibrate.sh compares against a recorded
# vector of that script's output, and quietly adding rows to it would invalidate
# the baseline that the whole 1.1c calibration rests on.
set -eu

PORT=${1:-5610}
DB=${2:-postgres}
A=${3:-bare}
B=${4:-concurrently}
DIR=$(dirname "$0")
: "${PSQL_BIN:=psql}"
PGOPTIONS="-c client_min_messages=warning"; export PGOPTIONS
PSQL="$PSQL_BIN -p $PORT -d $DB -q"

# The corpus itself is defined by exh*.sql; load it so this can run standalone.
$PSQL -f "$DIR/exh.sql"
$PSQL -f "$DIR/exh2.sql"
$PSQL -f "$DIR/exh3.sql"
$PSQL -c 'DROP FUNCTION IF EXISTS run_diff(text,text,text)'
$PSQL -f "$DIR/diff_driver.sql"

for id in $("$PSQL_BIN" -p "$PORT" -d "$DB" -Atc \
            'SELECT id FROM probe_exh ORDER BY ord::int'); do
    $PSQL -Atc "SELECT run_diff('$id','$A','$B')" >/dev/null
done

echo "===== differential: $A vs $B, over the full mutation space ====="
"$PSQL_BIN" -p "$PORT" -d "$DB" -c \
  "SELECT id, total, diverged, errs_a, errs_b, first_mut, first_pred
     FROM diff_result ORDER BY id"
