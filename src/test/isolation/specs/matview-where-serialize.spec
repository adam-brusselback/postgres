# REFRESH MATERIALIZED VIEW ... WHERE ... concurrency model
#
# The non-concurrent partial refresh takes only RowExclusiveLock, and relies on
# a "SELECT ... FOR UPDATE" over the rows matching the predicate to serialize
# against other partial refreshes.  This spec pins down the three claims that
# follow from that design:
#
#   - readers are never blocked;
#   - two refreshes whose predicates cover overlapping existing rows serialize;
#   - two refreshes over disjoint rows do not block each other.
#
# The row locks are held to the end of the refreshing transaction, so a refresh
# issued inside an explicit transaction block keeps them until COMMIT.
#
# All three claims hold today, so this spec passes; it is here to keep them from
# regressing while the rest of the feature is reworked.  The claim it does not
# cover is that overlapping refreshes never abort -- see
# matview-where-deadlock.spec.

setup
{
    CREATE TABLE mvw_base (id int PRIMARY KEY, v text);
    INSERT INTO mvw_base VALUES (1, 'one'), (2, 'two'), (3, 'three');
    CREATE MATERIALIZED VIEW mvw AS SELECT id, v FROM mvw_base;
    CREATE UNIQUE INDEX mvw_id_idx ON mvw(id);
}

teardown
{
    DROP MATERIALIZED VIEW mvw;
    DROP TABLE mvw_base;
}

session s1
setup           { BEGIN; }
step s1_change  { UPDATE mvw_base SET v = 'one-s1' WHERE id = 1; }
step s1_ref1    { REFRESH MATERIALIZED VIEW mvw WHERE id = 1; }
step s1_commit  { COMMIT; }

session s2
setup           { BEGIN; }
# Overlaps s1's predicate: must wait for s1 to commit.
step s2_ref1    { REFRESH MATERIALIZED VIEW mvw WHERE id = 1; }
# Disjoint from s1's predicate: must not wait.
step s2_ref2    { REFRESH MATERIALIZED VIEW mvw WHERE id = 2; }
# Plain reads must never block, even mid-refresh.
step s2_read    { SELECT id, v FROM mvw ORDER BY id; }
step s2_commit  { COMMIT; }
# Final state, once both transactions have ended.
step s2_final   { SELECT id, v FROM mvw ORDER BY id; }

# Readers and disjoint refreshes proceed while s1 holds its row locks.  s2_read
# runs mid-refresh and must see the pre-refresh value for id = 1.
permutation s1_change s1_ref1 s2_read s2_ref2 s2_commit s1_commit s2_final

# An overlapping refresh blocks until s1 commits, then sees s1's result.
permutation s1_change s1_ref1 s2_ref1 s1_commit s2_commit s2_final
