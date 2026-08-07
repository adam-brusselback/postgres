-- Does a *redundant* UPDATE on a table with indexes on the updated columns
-- still qualify as a HOT update (i.e. skip index maintenance) WITHOUT the
-- suppress trigger?  If yes, PostgreSQL already avoids the index work on its
-- own, which explains why the trigger buys little on indexed tables.
\pset pager off

VACUUM FULL t_idx_notrig;
SELECT pg_stat_reset_single_table_counters('t_idx_notrig'::regclass);

\echo '=== redundant UPDATE (values unchanged), no trigger:'
UPDATE t_idx_notrig SET a = a, b = b, c = c WHERE id BETWEEN 1 AND 10000;
SELECT pg_stat_force_next_flush();
SELECT n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd,0), 1) AS pct_hot
FROM pg_stat_user_tables WHERE relname = 't_idx_notrig';

VACUUM FULL t_idx_notrig;
SELECT pg_stat_reset_single_table_counters('t_idx_notrig'::regclass);

\echo '=== changing UPDATE (indexed values change), no trigger:'
UPDATE t_idx_notrig SET a = a + 1, b = b + 1 WHERE id BETWEEN 1 AND 10000;
SELECT pg_stat_force_next_flush();
SELECT n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd,0), 1) AS pct_hot
FROM pg_stat_user_tables WHERE relname = 't_idx_notrig';
