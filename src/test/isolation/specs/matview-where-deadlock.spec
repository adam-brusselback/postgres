# REFRESH MATERIALIZED VIEW ... WHERE ... lock ordering
#
# The non-concurrent partial refresh locks the matview rows matching its
# predicate with "SELECT 1 FROM matview WHERE (predicate) FOR UPDATE", and those
# locks are held until the refreshing transaction ends.  Nothing establishes a
# global order in which rows are locked, so two transactions that touch the same
# rows in different orders deadlock.
#
# This spec covers the deterministic case: two transactions each issuing several
# single-row partial refreshes in opposite orders, which is what a trigger-driven
# maintenance scheme produces naturally.
#
# XXX There is a second, non-deterministic variant that this spec cannot cover:
# a *single* refresh statement locks rows in whatever order its plan happens to
# produce, so two overlapping refreshes with different predicates (and therefore
# different plans) deadlock against each other without any help.  See
# src/test/matview_where_stress/.  Note that adding ORDER BY to the row-locking
# SELECT fixes only that variant, not the one below -- ordering within one
# statement says nothing about the order of separate statements.

setup
{
    CREATE TABLE mvwd_base (id int PRIMARY KEY, v text);
    INSERT INTO mvwd_base VALUES (1, 'one'), (2, 'two');
    CREATE MATERIALIZED VIEW mvwd AS SELECT id, v FROM mvwd_base;
    CREATE UNIQUE INDEX mvwd_id_idx ON mvwd(id);
}

teardown
{
    DROP MATERIALIZED VIEW mvwd;
    DROP TABLE mvwd_base;
}

session s1
setup            { BEGIN; }
step s1_ref1     { REFRESH MATERIALIZED VIEW mvwd WHERE id = 1; }
step s1_ref2     { REFRESH MATERIALIZED VIEW mvwd WHERE id = 2; }
step s1_commit   { COMMIT; }

session s2
setup            { BEGIN; }
step s2_ref2     { REFRESH MATERIALIZED VIEW mvwd WHERE id = 2; }
step s2_ref1     { REFRESH MATERIALIZED VIEW mvwd WHERE id = 1; }
step s2_commit   { COMMIT; }
step s2_final    { SELECT id, v FROM mvwd ORDER BY id; }

# s1 holds row 1 and wants row 2; s2 holds row 2 and wants row 1.
# XXX BUG: deadlock.  A partial refresh is documented as serializing against
# overlapping refreshes, so this should wait rather than abort.
permutation s1_ref1 s2_ref2 s1_ref2 s2_ref1 s1_commit s2_commit s2_final
