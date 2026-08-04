# REFRESH MATERIALIZED VIEW ... WHERE ... -- which spelling admits a second
# refresh
#
# Raised on -hackers by Vellaipandiyan: "With WHERE refreshes, the
# non-CONCURRENT path appears more permissive for writers than CONCURRENTLY
# WHERE, which seems opposite to the expectation established by normal REFRESH
# MATERIALIZED VIEW semantics."  The two paths were swapped in answer to that,
# and this spec is what holds the answer.
#
# The only thing that writes a materialized view is a refresh -- direct DML on
# one is rejected -- so "does this form block writers" means "can a second
# refresh run while this one is in flight".  That is the question asked here,
# and it is asked by running the second refresh rather than by reading a lock
# level off pg_locks: an implementation that keeps other refreshes out by some
# other means satisfies the guarantee, and a test naming the mechanism would
# report it as a regression.
#
# The predicates are chosen DISJOINT throughout, which is the whole design of
# this file.  matview-where-serialize already covers overlapping refreshes
# waiting for each other, and that happens under both spellings, so an
# overlapping pair here would pass whatever the form did.  Disjoint is where
# the two forms differ: under CONCURRENTLY nothing orders them, so they run
# together; under the bare form the relation-level lock keeps the second one
# out however little it wants to touch.
#
# Three claims, and the second is the control for the first:
#
#   - a bare partial refresh keeps a disjoint CONCURRENTLY refresh waiting
#   - a CONCURRENTLY partial refresh does not
#   - neither keeps a reader waiting, while a FULL refresh does
#
# The last one is what says the bare partial form is not simply a full refresh
# wearing a predicate.  It gives up concurrent refreshes and keeps concurrent
# readers; a full refresh gives up both.
#
# A refresh holds its locks to the end of its transaction, so issuing one
# inside an explicit block is enough to hold it in flight for a step.
#
# At most one step is ever waiting at a time here, which is deliberate: three
# specs in this suite have needed an alternative expected file because two
# waiting steps complete in whichever order the scheduler picks, and a single
# waiter cannot race with anything.
#
# Verified as a detector rather than assumed: with the lock choice in
# ExecRefreshMatView() collapsed so that a partial refresh takes
# RowExclusiveLock whichever way it is spelled, permutation 1 goes red -- the
# disjoint refresh stops waiting and completes in the step that should have
# blocked.
#
# Disposition: keep.  It is the executable form of the answer given on the
# thread, and it states an outcome rather than a lock level, so a change to how
# the exclusion is achieved does not make it wrong.

setup
{
    CREATE TABLE mvperm_base (id int PRIMARY KEY, v text);
    INSERT INTO mvperm_base VALUES (1, 'one'), (2, 'two'), (3, 'three');
    CREATE MATERIALIZED VIEW mvperm AS SELECT id, v FROM mvperm_base;
    CREATE UNIQUE INDEX mvperm_id_idx ON mvperm(id);

    -- The same matview with a second unique index, which is what routes a
    -- partial refresh to diff/merge.  The extra column is unique in its own
    -- right so the index is satisfiable without constraining anything else.
    CREATE MATERIALIZED VIEW mvperm2 AS SELECT id, id * 100 AS u, v
                                          FROM mvperm_base;
    CREATE UNIQUE INDEX mvperm2_id_idx ON mvperm2(id);
    CREATE UNIQUE INDEX mvperm2_u_idx ON mvperm2(u);
}

teardown
{
    DROP MATERIALIZED VIEW mvperm;
    DROP MATERIALIZED VIEW mvperm2;
    DROP TABLE mvperm_base;
}

session s1
setup             { BEGIN; }
step s1_bare      { REFRESH MATERIALIZED VIEW mvperm WHERE id = 1; }
step s1_conc      { REFRESH MATERIALIZED VIEW CONCURRENTLY mvperm WHERE id = 1; }
step s1_full      { REFRESH MATERIALIZED VIEW mvperm; }
step s1_bare2     { REFRESH MATERIALIZED VIEW mvperm2 WHERE id = 1; }
step s1_commit    { COMMIT; }

session s2
setup             { BEGIN; }
# Disjoint from every predicate s1 uses: nothing about the rows can order these.
step s2_conc      { REFRESH MATERIALIZED VIEW CONCURRENTLY mvperm WHERE id = 3; }
step s2_read      { SELECT id, v FROM mvperm ORDER BY id; }
step s2_bare2     { REFRESH MATERIALIZED VIEW mvperm2 WHERE id = 3; }
step s2_read2     { SELECT id, u, v FROM mvperm2 ORDER BY id; }
step s2_commit    { COMMIT; }

# 1. The bare form is the exclusive one: a disjoint refresh waits for it, and a
#    reader does not.
permutation s1_bare s2_read s2_conc s1_commit s2_commit

# 2. The control.  Same two steps, one spelling apart, and now the disjoint
#    refresh completes without waiting.  Without this permutation the file
#    asserts that something blocks rather than that the spelling decides it.
permutation s1_conc s2_read s2_conc s1_commit s2_commit

# 3. A full refresh gives up the readers too, which the partial forms do not.
permutation s1_full s2_read s1_commit s2_commit

# 4. The path a multi-unique-index matview is steered to.  CONCURRENTLY is
#    refused there -- the upsert cannot delete before it inserts, and the lock
#    is chosen from the spelling before that is known -- so the bare form is the
#    only way to refresh one partially, and it has to behave like the bare form
#    everywhere else: a second refresh waits, a reader does not.
permutation s1_bare2 s2_read2 s2_bare2 s1_commit s2_commit
