\pset pager off
VACUUM (ANALYZE) t_narrow_plain, t_narrow_trigger, t_narrow_reloption,
                 t_wide_plain, t_wide_trigger, t_wide_reloption;
CHECKPOINT;
\echo '--- narrow PLAIN, redundant'
BEGIN; EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE t_narrow_plain SET a = a, b = b WHERE id BETWEEN 1 AND 10000; ROLLBACK;
\echo '--- narrow TRIGGER, redundant'
BEGIN; EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE t_narrow_trigger SET a = a, b = b WHERE id BETWEEN 1 AND 10000; ROLLBACK;
\echo '--- narrow RELOPTION, redundant'
BEGIN; EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE t_narrow_reloption SET a = a, b = b WHERE id BETWEEN 1 AND 10000; ROLLBACK;
\echo '--- wide PLAIN, redundant'
BEGIN; EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE t_wide_plain SET a = a, b = b WHERE id BETWEEN 1 AND 10000; ROLLBACK;
\echo '--- wide TRIGGER, redundant'
BEGIN; EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE t_wide_trigger SET a = a, b = b WHERE id BETWEEN 1 AND 10000; ROLLBACK;
\echo '--- wide RELOPTION, redundant'
BEGIN; EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF)
UPDATE t_wide_reloption SET a = a, b = b WHERE id BETWEEN 1 AND 10000; ROLLBACK;
\echo '--- does a suppressed UPDATE still consume an XID?'
BEGIN;
UPDATE t_narrow_reloption SET a = a, b = b WHERE id BETWEEN 1 AND 1000;
SELECT txid_current_if_assigned() IS NOT NULL AS xid_assigned_reloption;
ROLLBACK;
BEGIN;
UPDATE t_narrow_trigger SET a = a, b = b WHERE id BETWEEN 1 AND 1000;
SELECT txid_current_if_assigned() IS NOT NULL AS xid_assigned_trigger;
ROLLBACK;
