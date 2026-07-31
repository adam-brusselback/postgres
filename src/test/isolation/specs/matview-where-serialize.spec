# REFRESH MATERIALIZED VIEW ... WHERE ... concurrency model
#
# Asked for on -hackers by Dharin Shah ("I think it would help the patch to
# explicitly define the intended safety model") and by Vellaipandiyan ("It may
# also help to document the intended guarantees around overlapping partial
# refreshes and concurrent DML on base tables").  Adam Brusselback answered with
# a written-out set of guarantees; this spec is the executable form of the three
# that concern overlapping refreshes.  The prose itself has not landed in the
# docs yet, which remains an open review item.
#
# With a WHERE clause, CONCURRENTLY selects the direct-modification path, which
# takes only RowExclusiveLock and relies on a "SELECT ... FOR NO KEY UPDATE"
# over the rows matching the predicate to serialize against other partial
# refreshes.  FOR NO KEY UPDATE conflicts with itself, which is the whole of
# what that serialization needs; FOR UPDATE would additionally conflict with
# FOR KEY SHARE, which nothing takes on a matview.
# This spec pins down the three claims that follow from that design:
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
#
# Disposition: keep.  This is the executable form of the feature's concurrency
# contract, and it will need rewriting rather than deleting if the locking model
# changes.

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
step s1_ref1    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvw WHERE id = 1; }
step s1_commit  { COMMIT; }

session s2
setup           { BEGIN; }
# Overlaps s1's predicate: must wait for s1 to commit.
step s2_ref1    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvw WHERE id = 1; }
# Disjoint from s1's predicate: must not wait.
step s2_ref2    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvw WHERE id = 2; }
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
