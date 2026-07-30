#!/bin/sh
# Does splitting the fused CTE into two statements reopen A3's consistency gap?
#
# The gap being tested is NOT the original one (DELETE then INSERT).  It is the
# one the fusion closes: the fused CTE computes new_data ONCE, while two
# statements each take their own snapshot at READ COMMITTED, so a base-table
# change committed between them is seen by the second and not the first.
PSQL="/home/user/pgsql-opt/bin/psql -p 5610 -d postgres -q -X"
S=/tmp/pgt/a3sync; rm -f $S.*; 

$PSQL -c "DROP SCHEMA IF EXISTS a3 CASCADE; CREATE SCHEMA a3;
  CREATE TABLE a3.base(id int primary key, v int);
  INSERT INTO a3.base VALUES (1,10),(2,20),(3,30);
  CREATE TABLE a3.mv(id int primary key, v int);
  INSERT INTO a3.mv SELECT * FROM a3.base;
  -- row 3 is deleted from the base: the refresh should prune it from mv
  DELETE FROM a3.base WHERE id = 3;" >/dev/null

run_split() {
  ( $PSQL <<EOF
BEGIN;
SELECT 1 FROM a3.mv WHERE id BETWEEN 1 AND 3 ORDER BY id FOR UPDATE;
INSERT INTO a3.mv SELECT id, v FROM a3.base WHERE id BETWEEN 1 AND 3
  ON CONFLICT (id) DO UPDATE SET v = excluded.v;
SELECT pg_sleep(2);
DELETE FROM a3.mv mv WHERE mv.id BETWEEN 1 AND 3
  AND NOT EXISTS (SELECT 1 FROM a3.base b WHERE b.id = mv.id);
COMMIT;
EOF
  ) >/dev/null 2>&1 &
  sleep 1
  # concurrent writer re-adds row 3 between the two statements
  $PSQL -c "INSERT INTO a3.base VALUES (3, 999);" >/dev/null
  wait
}

run_fused() {
  $PSQL -c "DELETE FROM a3.base WHERE id = 3; UPDATE a3.mv SET v = 30 WHERE id = 3;
            INSERT INTO a3.mv VALUES (3,30) ON CONFLICT (id) DO UPDATE SET v = 30;" >/dev/null
  ( $PSQL <<EOF
BEGIN;
SELECT 1 FROM a3.mv WHERE id BETWEEN 1 AND 3 ORDER BY id FOR UPDATE;
SELECT pg_sleep(2);
WITH new_data AS (SELECT id, v FROM a3.base WHERE id BETWEEN 1 AND 3 ORDER BY id),
     upsert AS (INSERT INTO a3.mv SELECT * FROM new_data
                ON CONFLICT (id) DO UPDATE SET v = excluded.v RETURNING 1),
     pruned AS (DELETE FROM a3.mv mv WHERE mv.id BETWEEN 1 AND 3
                AND NOT EXISTS (SELECT 1 FROM new_data nd WHERE nd.id = mv.id) RETURNING 1)
SELECT (SELECT count(*) FROM upsert) + (SELECT count(*) FROM pruned);
COMMIT;
EOF
  ) >/dev/null 2>&1 &
  sleep 1
  $PSQL -c "INSERT INTO a3.base VALUES (3, 999);" >/dev/null
  wait
}

echo "=== TWO STATEMENTS (upsert; then prune) ==="
run_split
$PSQL -c "SELECT 'mv' AS rel, id, v FROM a3.mv ORDER BY id;
          SELECT 'correct (base)' AS rel, id, v FROM a3.base ORDER BY id;"

echo "=== FUSED CTE (new_data computed once) ==="
$PSQL -c "TRUNCATE a3.mv; TRUNCATE a3.base;
  INSERT INTO a3.base VALUES (1,10),(2,20),(3,30);
  INSERT INTO a3.mv SELECT * FROM a3.base;
  DELETE FROM a3.base WHERE id = 3;" >/dev/null
run_fused
$PSQL -c "SELECT 'mv' AS rel, id, v FROM a3.mv ORDER BY id;
          SELECT 'correct (base)' AS rel, id, v FROM a3.base ORDER BY id;"
