# REFRESH MATERIALIZED VIEW ... WHERE ... -- the gap between locking and refreshing
#
# A partial refresh is two SPI statements, not one:
#
#   1.  SELECT 1 FROM mv WHERE (predicate) ORDER BY key FOR UPDATE
#   2.  WITH new_data AS MATERIALIZED (SELECT ... WHERE (predicate) ORDER BY key),
#            upsert AS (INSERT ... ON CONFLICT ... ),
#            pruned AS (DELETE ... WHERE NOT EXISTS (SELECT FROM new_data))
#       SELECT ...
#
# At READ COMMITTED each takes its own snapshot, so a base-table change that
# commits between them is invisible to the locking step and visible to the
# refreshing step.  Two things could go wrong:
#
#   - a row that newly satisfies the predicate is upserted without ever having
#     been locked, so two overlapping refreshes do not serialize on it;
#   - a row that stops satisfying it was locked but is then pruned on the basis
#     of a later snapshot.
#
# Fusing the upsert and the prune into one statement (the A3 fix) closes the gap
# *within* step 2 -- both arms read one materialised new_data, so they cannot
# disagree about which rows exist.  It says nothing about the gap between step 1
# and step 2, which is what this spec pins down.
#
# Splitting the fused CTE back into two statements reopens a gap of the same
# family; that is demonstrated in matview_where_stress/safety/a3-split-gap.sh,
# and it is why the CTE cannot be split for speed.  This spec is the in-tree
# version of that concern, driven through the real command rather than
# hand-written SQL.
#
# The injection point is what makes it deterministic: without it the window
# between the two statements is microseconds wide and nothing can be reliably
# landed inside it.
#
# Disposition: keep.  It is the only gate on the two-statement structure of a
# partial refresh, and any attempt to restructure that for performance should
# have to answer to it.

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
# Parks after the row-locking SELECT and before the fused CTE.
step s1_ref    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvsnap WHERE grp = 1; }
# A no-op so the detach is not launched until the refresh has actually returned
# -- the same sequencing guard basic.spec uses.
step s1_noop   { }

session s2
# Lands between the two statements: row 4 moves INTO the refresh's scope, and
# row 3 moves OUT of it.  Neither was seen by the locking step.
step s2_move   { UPDATE mvsnap_base SET grp = 1 WHERE id = 4;
                 UPDATE mvsnap_base SET grp = 9 WHERE id = 3; }
step s2_wake   { SELECT injection_points_wakeup('matview-where-locked'); }
step s2_detach { SELECT injection_points_detach('matview-where-locked'); }

session s3
# What the matview holds afterwards, against what a full refresh would give.
step s3_state  { SELECT id, grp, v FROM mvsnap ORDER BY id; }
step s3_truth  { REFRESH MATERIALIZED VIEW mvsnap;
                 SELECT id, grp, v FROM mvsnap ORDER BY id; }

# s1 locks rows 1,2,3 (grp = 1), then parks.  s2 moves row 4 in and row 3 out
# and commits.  s1's CTE then runs under a newer snapshot than its locks were
# taken under.  s3_state records what that produces; s3_truth records what is
# correct.  The two need not agree -- a partial refresh only promises to make
# its own scope right -- but whatever the answer is, it is now pinned, and a
# change to the two-statement structure has to change this file to land.
permutation s1_ref s2_move s2_wake s1_noop s2_detach s3_state s3_truth
