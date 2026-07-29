# REFRESH MATERIALIZED VIEW ... WHERE ... lock ordering
#
# Reported on -hackers by Vellaipandiyan: "I wonder whether overlapping
# refreshes could still encounter deadlock scenarios around UPSERT conflicts."
# Adam Brusselback confirmed that the locking SELECT had no ORDER BY, so "two
# overlapping refreshes could lock the existing rows in different physical orders
# and deadlock", and said the next patch would give it "a deterministic ORDER BY
# on the unique key columns".  That ORDER BY is not in the tree yet, and would
# not resolve the permutation below in any case -- see the note further down.
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
# Unlike the regression tests for this feature, this spec records what happens
# today rather than asserting a fix, and so it passes.  That is deliberate: the
# stated contract is that overlapping partial refreshes serialize, and the
# permutation below violates it, but no row-granularity locking scheme can
# satisfy it here -- the two transactions form a genuine cycle.  Honouring the
# contract needs a coarser lock, under which s2's first refresh would block
# immediately and this permutation could not be driven at all.  Until that design
# question is settled there is no correct output to assert, so the expected file
# below is a characterisation, and the XXX marks the contract violation.
#
# Disposition: REPLACE or DELETE once the locking model is settled.  If
# overlapping refreshes are made to serialize properly, this permutation stops
# being drivable and the spec should be rewritten around whatever the new model
# guarantees.  If deadlock is accepted as normal for row-level locking, the
# behaviour belongs in the documentation and this spec can go.
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
# XXX a partial refresh is documented as serializing against overlapping
# refreshes, so neither of these should abort.
permutation s1_ref1 s2_ref2 s1_ref2 s2_ref1 s1_commit s2_commit s2_final
