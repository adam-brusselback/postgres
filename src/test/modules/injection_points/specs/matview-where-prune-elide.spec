# REFRESH MATERIALIZED VIEW ... WHERE ... -- the prune may only be skipped when
# it provably cannot delete
#
# The fused statement's DELETE carries a guard so that a refresh where nothing
# in scope can be orphaned does not scan the scope a second time.  Two counts
# decide it: how many matview rows the pre-lock matched (n_locked), and how many
# rows the source produced (n_source).  If every source row is accounted for by
# a row already in scope or by one the upsert has just inserted, nothing in
# scope is orphaned.  SPECIALIZE.md 3b has that argument and the predicate-shape
# gate it needs; matview_where Test 20 is its single-session detector.
#
# What Test 20 structurally cannot see is that n_locked is measured under an
# EARLIER SNAPSHOT than the DELETE it stands in for.  The pre-lock takes its
# own; the source evaluation and the DML then take another, and they have to be
# in that order -- a refresh that queued behind another would otherwise evaluate
# its source from before that one committed and write the stale values back over
# it, which is mutation M3's lost update.  The lock stops the rows it matched
# from changing.  It does not stop new ones appearing: a refresh over a key the
# matview does not hold yet locks nothing, so it does not queue behind us and
# can commit a row into our scope inside that window.  Neither count has seen
# that row, so the accounting balances while the row is orphaned -- 3b's failure
# mode arriving from concurrency instead of from predicate shape, and just as
# silent.
#
# So the guard needs a third condition, and it is not about the predicate at
# all: no other session may be able to write the matview.  ExclusiveLock is
# where that is true, and the bare WHERE form takes it deliberately for exactly
# this class of reason (SPECIALIZE.md 4).  Under CONCURRENTLY's
# RowExclusiveLock the elision is simply not available.
#
# Both permutations were run against a build without that condition.  The first
# left row 3 in the matview -- in scope, in the matview, produced by nothing --
# and is the reason the condition exists.
#
# Disposition: keep while the prune is elided at all.  The property is data
# loss, not scaffolding; the injection point is scaffolding, and lives only
# where the seam does.

setup
{
    CREATE EXTENSION injection_points;
    CREATE TABLE mvelide_base (id int PRIMARY KEY, v int);
    INSERT INTO mvelide_base VALUES (1, 10), (2, 20);
    CREATE MATERIALIZED VIEW mvelide AS SELECT id, v FROM mvelide_base;
    CREATE UNIQUE INDEX mvelide_id_idx ON mvelide(id);
    -- Row 3 exists in the base and has never been refreshed into the matview,
    -- so s1's locking SELECT below matches rows 1 and 2 and nothing else, and
    -- a refresh of row 3 alone locks nothing.
    INSERT INTO mvelide_base VALUES (3, 30);
    ANALYZE mvelide;
}

teardown
{
    DROP MATERIALIZED VIEW mvelide;
    DROP TABLE mvelide_base;
    DROP EXTENSION injection_points;
}

session s1
setup {
    SELECT injection_points_set_local();
    SELECT injection_points_attach('matview-where-locked', 'wait');
}
# Both park after the row-locking SELECT and before the snapshot the source and
# the DML share.  n_locked is already decided at that point: 2.  The predicate
# is on the arbiter key in both, because the count comparison is gated on that
# and a predicate on any other column would disable the guard and leave the
# permutation testing nothing.
step s1_conc { REFRESH MATERIALIZED VIEW CONCURRENTLY mvelide WHERE id <= 3; }
step s1_bare { REFRESH MATERIALIZED VIEW mvelide WHERE id <= 3; }
# A no-op so the detach is not launched until the refresh has returned -- the
# same sequencing guard basic.spec uses.
step s1_noop { }

session s2
# Row 3 arrives in the matview, inside s1's scope and after s1 counted it.
step s2_add    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvelide WHERE id = 3; }
# And then stops being produced, so it is genuinely orphaned rather than merely
# unseen: s1's source will yield rows 1 and 2, and row 3 must go.
step s2_drop   { DELETE FROM mvelide_base WHERE id = 3; }

session s3
# The wake lives here rather than in s2 because s2 is blocked for the whole of
# the second permutation, which is the point of that permutation.
step s3_wake   { SELECT injection_points_wakeup('matview-where-locked'); }
step s3_detach { SELECT injection_points_detach('matview-where-locked'); }
step s3_state  { SELECT id, v FROM mvelide ORDER BY id; }

# s1 locks rows 1 and 2 and parks.  s2 refreshes row 3 into the matview and then
# deletes it from the base, both committing while s1 is stopped.  s1 then
# evaluates its source -- rows 1 and 2 -- and runs the fused statement.  Both
# source rows conflict with rows already there, so nothing is inserted, and
# n_locked + n_inserted = 2 + 0 equals n_source = 2: the counts say nothing can
# be orphaned, and they are wrong.  Row 3 must not survive.
permutation s1_conc s2_add s2_drop s3_wake s1_noop s3_detach s3_state

# The same window under the bare form, which holds ExclusiveLock: s2 cannot get
# in at all, and that is what makes the elision safe there rather than merely
# unobserved.  s2_add waits for s1 to commit and is then a no-op.  s1 itself
# elides -- n_locked 2, n_source 3, one insert -- and the answer is still right,
# which is the case the optimisation exists for.
#
# It is a characterisation and not a detector of the guard: a broken guard
# passes it, because the interleaving it would need cannot happen here.  What it
# does detect is the precondition going away -- weaken the bare form's lock and
# s2_add stops waiting.
permutation s1_bare s2_add s3_wake s1_noop s3_detach s3_state
