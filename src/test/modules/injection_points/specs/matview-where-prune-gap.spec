# REFRESH MATERIALIZED VIEW ... WHERE ...: the prune must not delete a row that
# another refresh committed while this one was in flight
#
# A partial refresh decides which rows the view no longer produces by comparing
# the matview against the rows it just computed.  If those two are read at
# different points in time, anything that appeared in the matview in between is
# in one and not the other, and the prune deletes it.
#
# The defining query is evaluated in its own step, because a Query tree cannot
# be handed to SPI as a subquery, so there is a seam between computing the rows
# and applying them.  It is closed by running the DML under the snapshot the
# evaluation used, and this spec is what says so.
#
# It uses a key the matview has never held rather than a changed one.
# Overlapping refreshes are ordered by the locking SELECT, which takes FOR NO
# KEY UPDATE on the rows in scope, so a refresh that would change an existing
# row waits and cannot be in flight beside another over the same rows.  A key
# the matview does not hold yet locks nothing.  A refresh whose scope contains
# only such keys runs beside a wider refresh with nothing ordering the two,
# which is the only way to be inside the window at all.
#
# That is also why a probabilistic reproducer cannot stand in for this.  One was
# written and run against a build with the bug deliberately present, and it
# reported a clean run.  The window is microseconds wide and the violation needs
# two commits inside it.

setup
{
    CREATE EXTENSION injection_points;
    CREATE TABLE mvgap_base (id int PRIMARY KEY, tag text, v int);
    INSERT INTO mvgap_base VALUES (1, 'hot', 10), (2, 'hot', 20), (3, 'cold', 30);
    CREATE MATERIALIZED VIEW mvgap AS SELECT id, tag, v FROM mvgap_base;
    CREATE UNIQUE INDEX mvgap_id_idx ON mvgap(id);
    ANALYZE mvgap;
}

teardown
{
    DROP MATERIALIZED VIEW mvgap;
    DROP TABLE mvgap_base;
    DROP EXTENSION injection_points;
}

session s1
setup {
    SELECT injection_points_set_local();
    SELECT injection_points_attach('matview-where-source-materialized', 'wait');
}
# Parks with the source rows computed and the DML not yet run.  set_local keeps
# the wait in this backend, so s2's refresh below runs straight through.
step s1_wide { REFRESH MATERIALIZED VIEW CONCURRENTLY mvgap WHERE tag = 'hot'; }
# A no-op so the detach is not launched until the refresh has actually
# returned.  This is the sequencing guard basic.spec uses.
step s1_noop { }

session s2
# A key the matview has never held.  s2_narrow's locking SELECT therefore locks
# nothing and does not queue behind s1.
step s2_add    { INSERT INTO mvgap_base VALUES (9, 'hot', 90); }
step s2_narrow { REFRESH MATERIALIZED VIEW CONCURRENTLY mvgap WHERE id = 9; }
step s2_wake   { SELECT injection_points_wakeup('matview-where-source-materialized'); }
step s2_detach { SELECT injection_points_detach('matview-where-source-materialized'); }

session s3
step s3_state { SELECT id, tag, v FROM mvgap ORDER BY id; }

# s1 computes rows 1 and 2 and parks.  s2 adds row 9 to the base and refreshes
# it into the matview, both committing while s1 is stopped.  s1 then runs its
# upsert and prune.  Row 9 is inside s1's scope and is not among the rows s1
# computed, so a prune reading the matview as of now deletes it; a prune reading
# it as of when the rows were computed cannot see it at all.  s3_state is the
# difference: with the snapshot shared, row 9 survives.
permutation s1_wide s2_add s2_narrow s2_wake s1_noop s2_detach s3_state
