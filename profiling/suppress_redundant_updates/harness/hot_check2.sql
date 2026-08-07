-- Corrected HOT test.  The previous version ran VACUUM FULL first, which packs
-- pages to 100% fillfactor; HOT requires free space on the *same* page for the
-- new tuple version, so nothing could be HOT regardless of which columns
-- changed.  Give the pages headroom so the question can actually be answered:
-- does an UPDATE whose indexed column VALUES are unchanged qualify as HOT?
\pset pager off

DROP TABLE IF EXISTS sru_hot;
CREATE TABLE sru_hot (id int primary key, a int, b int, c text) WITH (fillfactor = 50);
INSERT INTO sru_hot SELECT g, g, g, 'val' || g FROM generate_series(1, 20000) g;
CREATE INDEX ON sru_hot (a);
CREATE INDEX ON sru_hot (b);
VACUUM ANALYZE sru_hot;

SELECT pg_stat_reset_single_table_counters('sru_hot'::regclass);
\echo '=== redundant UPDATE (indexed values unchanged):'
UPDATE sru_hot SET a = a, b = b WHERE id BETWEEN 1 AND 10000;
SELECT pg_stat_force_next_flush();
SELECT n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd,0), 1) AS pct_hot
FROM pg_stat_user_tables WHERE relname = 'sru_hot';

SELECT pg_stat_reset_single_table_counters('sru_hot'::regclass);
\echo '=== changing UPDATE (indexed values change):'
UPDATE sru_hot SET a = a + 1, b = b + 1 WHERE id BETWEEN 10001 AND 20000;
SELECT pg_stat_force_next_flush();
SELECT n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / nullif(n_tup_upd,0), 1) AS pct_hot
FROM pg_stat_user_tables WHERE relname = 'sru_hot';

DROP TABLE sru_hot;
