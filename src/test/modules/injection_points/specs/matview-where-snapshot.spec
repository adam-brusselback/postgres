# REFRESH MATERIALIZED VIEW ... WHERE ...: the gap between locking and reading
#
# A partial refresh locks before it reads:
#
#   1.  SELECT 1 FROM mv WHERE (predicate) ORDER BY key FOR NO KEY UPDATE
#   2.  the defining query under the predicate, collected into a tuplestore
#   3.  WITH upsert AS (INSERT INTO mv SELECT * FROM new_data ON CONFLICT ...),
#            pruned AS (DELETE ... WHERE NOT EXISTS (SELECT 1 FROM new_data ...))
#       SELECT ...
#
# where new_data is the tuplestore from step 2, registered as an ephemeral named
# relation.  Steps 2 and 3 run under one snapshot and read one set of source
# rows, so they cannot disagree about what the view produces.  Step 1 is a
# separate statement and does not, which is the seam this spec pins down.
#
# At READ COMMITTED a base-table change that commits between the lock and the
# read is invisible to the first and visible to the rest.  Two things could go
# wrong:
#
#   - a row that newly satisfies the predicate is upserted without ever having
#     been locked, so two overlapping refreshes do not serialize on it;
#   - a row that stops satisfying it was locked but is then pruned on the basis
#     of a later snapshot.
#
# The injection point is what makes this deterministic.  Without it the window
# is microseconds wide and nothing can be landed inside it reliably.

setup
{
    CREATE EXTENSION injection_points;
    CREATE TABLE mvsnap_base (id int PRIMARY KEY, grp int, v int);
    INSERT INTO mvsnap_base VALUES (1,1,10), (2,1,20), (3,1,30), (4,2,40);
    CREATE MATERIALIZED VIEW mvsnap AS SELECT id, grp, v FROM mvsnap_base;
    CREATE UNIQUE INDEX mvsnap_id_idx ON mvsnap(id);
    CREATE INDEX mvsnap_grp_idx ON mvsnap(grp);
    ANALYZE mvsnap;
}

teardown
{
    DROP MATERIALIZED VIEW mvsnap;
    DROP TABLE mvsnap_base;
    DROP EXTENSION injection_points;
}

session s1
setup {
    SELECT injection_points_set_local();
    SELECT injection_points_attach('matview-where-locked', 'wait');
}
# Parks after the row-locking SELECT and before the fused statement.
step s1_ref    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvsnap WHERE grp = 1; }
# A no-op so the detach is not launched until the refresh has actually
# returned.  This is the sequencing guard basic.spec uses.
step s1_noop   { }

session s2
# Lands between the two statements: row 4 moves INTO the refresh's scope, and
# row 3 moves OUT of it.  Neither was seen by the locking step.
step s2_move   { UPDATE mvsnap_base SET grp = 1 WHERE id = 4;
                 UPDATE mvsnap_base SET grp = 9 WHERE id = 3; }
step s2_wake   { SELECT injection_points_wakeup('matview-where-locked'); }
step s2_detach { SELECT injection_points_detach('matview-where-locked'); }

# Overlapping refresh, issued while s1 is parked.  This is what makes the spec a
# detector rather than a characterisation: it can only block if s1 is already
# holding the row locks by the time it reaches the injection point.  Move the
# locking SELECT after the fused statement, which is a plausible way to save a
# round trip, and this step stops waiting.  That is the window reopening.
session s2b
step s2b_ref   { REFRESH MATERIALIZED VIEW CONCURRENTLY mvsnap WHERE grp = 1; }

session s3
# What the matview holds afterwards, against what a full refresh would give.
step s3_state  { SELECT id, grp, v FROM mvsnap ORDER BY id; }
step s3_truth  { REFRESH MATERIALIZED VIEW mvsnap;
                 SELECT id, grp, v FROM mvsnap ORDER BY id; }

# s1 locks rows 1, 2 and 3 (grp = 1), then parks holding those locks, so s2b_ref
# must wait for them.  s2 moves row 4 into the scope and row 3 out of it and
# commits, so s1 reads its source under a newer snapshot than its locks were
# taken under.  s2_wake releases s1.
#
# s3_state records what that produces and s3_truth records what a full refresh
# gives.  The two need not agree, since a partial refresh only promises to make
# its own scope right, but whatever the answer is it is pinned here.
permutation s1_ref s2b_ref s2_move s2_wake s1_noop s2_detach s3_state s3_truth
