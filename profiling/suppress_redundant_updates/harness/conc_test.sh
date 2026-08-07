#!/bin/bash
# Does a suppressed UPDATE still detect a concurrent committed update?
# Compares reloption off (= stock behaviour) against reloption on.
BASE=/tmp/claude-0/-home-user-postgres/3270ba05-7bc8-5226-9a93-a3534b405d6f/scratchpad
PGB=/home/user/pgbuild-patched/bin
export HOME=/home/ubuntu
PSQL="setpriv --reuid=1000 --regid=1000 --clear-groups $PGB/psql -p 55433 -h /tmp -U postgres -d bench -X -q"

$PSQL -c "DROP TABLE IF EXISTS ct_off, ct_on" >/dev/null 2>&1
$PSQL -c "CREATE TABLE ct_off (id int primary key, x int)" >/dev/null
$PSQL -c "CREATE TABLE ct_on  (id int primary key, x int)" >/dev/null
$PSQL -c "ALTER TABLE ct_on SET (suppress_redundant_updates = on)" >/dev/null

for tbl in ct_off ct_on; do
  for iso in "REPEATABLE READ" "READ COMMITTED"; do
    $PSQL -c "TRUNCATE $tbl; INSERT INTO $tbl VALUES (1, 1)" >/dev/null

    # Session A: take a snapshot, wait, then issue a redundant UPDATE
    ( $PSQL <<EOF
BEGIN ISOLATION LEVEL $iso;
SELECT count(*) FROM $tbl;
SELECT pg_sleep(3);
\echo 'A: issuing UPDATE $tbl SET x = 1 (row was x=1 at A snapshot)'
UPDATE $tbl SET x = 1 WHERE id = 1;
COMMIT;
EOF
    ) > "$BASE/results_patch/conc_${tbl}_${iso// /_}.txt" 2>&1 &
    apid=$!

    sleep 1
    # Session B: change the row and commit while A is asleep
    $PSQL -c "UPDATE $tbl SET x = 2 WHERE id = 1" >/dev/null 2>&1
    wait $apid

    final=$($PSQL -tAc "SELECT x FROM $tbl WHERE id = 1")
    echo "=== table=$tbl  isolation=$iso"
    grep -E "ERROR|UPDATE|A:" "$BASE/results_patch/conc_${tbl}_${iso// /_}.txt" | sed 's/^/    /'
    echo "    final x = $final"
  done
done
