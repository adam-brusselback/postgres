#!/bin/bash
# Generate pgbench workload scripts
D=$(dirname "$0")

for tbl in narrow wide; do
  for trig in trig notrig; do
    # redundant: NEW is byte-identical to OLD -> trigger suppresses
    cat > "$D/${tbl}_${trig}_redundant.sql" <<EOF
\set id random(1, 100000)
UPDATE t_${tbl}_${trig} SET a = a, b = b WHERE id = :id;
EOF
    # changing: NEW differs -> trigger cannot suppress, pure overhead
    cat > "$D/${tbl}_${trig}_changing.sql" <<EOF
\set id random(1, 100000)
UPDATE t_${tbl}_${trig} SET a = a + 1, b = b + 1 WHERE id = :id;
EOF
  done
done
echo "generated:"; ls "$D"/*.sql
