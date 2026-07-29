#!/bin/sh
#
# Stress reproducer for the lock-ordering deadlock in
# refresh_by_direct_modification().  See README in this directory.
#
# Not part of any test schedule; run by hand against a throwaway cluster.

set -u

PORT=${1:-5432}
HOST=${2:-/tmp}
DB=${3:-postgres}

ITERATIONS=${ITERATIONS:-40}
ROWS=${ROWS:-100000}
HOT=${HOT:-5000}

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

PSQL="psql -X -q -p $PORT -h $HOST -d $DB"

echo "setting up ($ROWS rows, $HOT of them in scope) ..."
$PSQL -v ON_ERROR_STOP=1 <<SQL || exit 1
DROP MATERIALIZED VIEW IF EXISTS mvstress;
DROP TABLE IF EXISTS mvstress_base;

CREATE TABLE mvstress_base (id int PRIMARY KEY, tag text, v int);

-- Insert with id descending so that physical order is the reverse of key order.
-- A sequential scan then visits the in-scope rows in the opposite order from an
-- index scan on id.
INSERT INTO mvstress_base
  SELECT g, CASE WHEN g <= $HOT THEN 'hot' ELSE 'cold' END, g
    FROM generate_series($ROWS, 1, -1) g;

CREATE MATERIALIZED VIEW mvstress AS SELECT id, tag, v FROM mvstress_base;
CREATE UNIQUE INDEX mvstress_id_idx ON mvstress(id);
ANALYZE mvstress;
SQL

echo "plans (these must differ for the reproducer to work):"
$PSQL -c "EXPLAIN (COSTS OFF) SELECT 1 FROM mvstress mv WHERE (id <= $HOT);" \
      -c "EXPLAIN (COSTS OFF) SELECT 1 FROM mvstress mv WHERE (tag = 'hot');"

i=0
while [ "$i" -lt "$ITERATIONS" ]; do
    echo "REFRESH MATERIALIZED VIEW mvstress WHERE id <= $HOT;" >> "$WORKDIR/a.sql"
    echo "REFRESH MATERIALIZED VIEW mvstress WHERE tag = 'hot';" >> "$WORKDIR/b.sql"
    i=$((i + 1))
done

echo "running $ITERATIONS refreshes in each of 2 sessions ..."
$PSQL -f "$WORKDIR/a.sql" > "$WORKDIR/a.out" 2>&1 &
pid_a=$!
$PSQL -f "$WORKDIR/b.sql" > "$WORKDIR/b.out" 2>&1 &
pid_b=$!
wait $pid_a $pid_b

count_a=$(grep -c 'deadlock detected' "$WORKDIR/a.out" || true)
count_b=$(grep -c 'deadlock detected' "$WORKDIR/b.out" || true)
deadlocks=$((count_a + count_b))
total=$((ITERATIONS * 2))

$PSQL -c "DROP MATERIALIZED VIEW mvstress;" -c "DROP TABLE mvstress_base;"

if [ "$deadlocks" -gt 0 ]; then
    echo "FAIL: $deadlocks of $total refreshes aborted with a deadlock"
    grep -m1 -A5 'deadlock detected' "$WORKDIR/a.out" "$WORKDIR/b.out"
    exit 1
fi

echo "OK: no deadlocks in $total refreshes"
exit 0
