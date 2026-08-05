# REFRESH MATERIALIZED VIEW ... WHERE ... lock ordering across statements
#
# Vellaipandiyan asked on the thread whether overlapping refreshes could still
# deadlock around UPSERT conflicts.  They can, in one case, and this spec
# records it.
#
# A partial refresh locks the matview rows matching its predicate with
# "SELECT 1 FROM matview WHERE (predicate) ORDER BY key FOR NO KEY UPDATE" and
# holds those locks until the refreshing transaction ends.  The ORDER BY fixes
# the order within one statement.  It says nothing about the order of separate
# statements, so two transactions that issue several single-row refreshes in
# opposite orders still deadlock.  That is the permutation below, and it is
# what a trigger-driven maintenance scheme produces naturally.
#
# This spec records what happens rather than asserting a fix, so it passes.
# The documented guarantee is that overlapping partial refreshes serialize, and
# this permutation violates it, but no row-granularity locking can satisfy it
# here: the two transactions form a genuine cycle.  Honouring it would need a
# coarser lock, under which s2's first refresh would block immediately and this
# permutation could not be driven at all.  Until that is settled there is no
# correct output to assert.

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
step s1_ref1     { REFRESH MATERIALIZED VIEW CONCURRENTLY mvwd WHERE id = 1; }
step s1_ref2     { REFRESH MATERIALIZED VIEW CONCURRENTLY mvwd WHERE id = 2; }
step s1_commit   { COMMIT; }

session s2
setup            { BEGIN; }
step s2_ref2     { REFRESH MATERIALIZED VIEW CONCURRENTLY mvwd WHERE id = 2; }
step s2_ref1     { REFRESH MATERIALIZED VIEW CONCURRENTLY mvwd WHERE id = 1; }
step s2_commit   { COMMIT; }
step s2_final    { SELECT id, v FROM mvwd ORDER BY id; }

# s1 holds row 1 and wants row 2; s2 holds row 2 and wants row 1.
# XXX a partial refresh is documented as serializing against overlapping
# refreshes, so neither of these should abort.
permutation s1_ref1 s2_ref2 s1_ref2 s2_ref1 s1_commit s2_commit s2_final
