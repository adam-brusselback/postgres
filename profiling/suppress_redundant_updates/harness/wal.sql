\pset pager off
\echo ================================================================
\echo  WAL / buffer accounting for one batch of 10k UPDATEs
\echo  "redundant" = NEW is byte-identical to OLD
\echo ================================================================

VACUUM (ANALYZE) t_narrow_trig, t_narrow_notrig, t_wide_trig, t_wide_notrig;
CHECKPOINT;

\echo
\echo --- narrow, NO trigger, redundant update (baseline: full rewrite)
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
UPDATE t_narrow_notrig SET a = a, b = b WHERE id BETWEEN 1 AND 10000;
ROLLBACK;

\echo
\echo --- narrow, WITH suppress trigger, redundant update (all suppressed)
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
UPDATE t_narrow_trig SET a = a, b = b WHERE id BETWEEN 1 AND 10000;
ROLLBACK;

\echo
\echo --- narrow, NO trigger, changing update
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
UPDATE t_narrow_notrig SET a = a + 1, b = b + 1 WHERE id BETWEEN 1 AND 10000;
ROLLBACK;

\echo
\echo --- narrow, WITH suppress trigger, changing update (nothing suppressed)
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
UPDATE t_narrow_trig SET a = a + 1, b = b + 1 WHERE id BETWEEN 1 AND 10000;
ROLLBACK;

\echo
\echo --- wide, NO trigger, redundant update
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
UPDATE t_wide_notrig SET a = a, b = b WHERE id BETWEEN 1 AND 10000;
ROLLBACK;

\echo
\echo --- wide, WITH suppress trigger, redundant update (all suppressed)
BEGIN;
EXPLAIN (ANALYZE, WAL, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
UPDATE t_wide_trig SET a = a, b = b WHERE id BETWEEN 1 AND 10000;
ROLLBACK;
