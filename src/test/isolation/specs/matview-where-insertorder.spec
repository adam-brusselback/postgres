# REFRESH MATERIALIZED VIEW ... WHERE ... lock ordering over INSERTED rows
#
# P2's cousin.  matview-where-lockorder covers rows the matview already holds,
# where the refresh takes a row lock and the order is visible as xmax.  This
# covers rows it does not hold yet, where the refresh INSERTs and the conflict
# is between two speculative insertions of the same key.  Two refreshes that
# insert an overlapping set of new keys in opposite orders deadlock, exactly as
# they would over existing rows.
#
# The observable has to be different, because the rows are not there to carry an
# xmax.  What is there is the blocking relationship: a refresh that hits a key
# another transaction has speculatively inserted waits on that transaction, and
# pg_blocking_pids() names it.  So pin the two ENDS of the range in two separate
# sessions, one key each, and ask which one the wide refresh stopped on.  That
# answers "which end did it start from", which is the order.
#
#   with ORDER BY on new_data   wide reaches key 1 first  -> blocked by pin_lo
#   without it                  a heap-order scan starts at key 10 -> pin_hi
#
# The base rows are inserted with id descending, so heap order is the reverse of
# key order and the two answers differ.  The matview deliberately does not hold
# the hot range at the start -- see the setup -- so every hot key is an INSERT
# and not an UPDATE, which is what makes this P3 rather than a second P2 test.
#
# This asserts the property (the insertion order is deterministic and ascending,
# whoever is doing the inserting) rather than the mechanism.  An implementation
# that acquires the locks separately and in order, then inserts in any order,
# still passes -- which is the case that `matview_where` Test 16 gets wrong, and
# the reason Test 16 is marked REPLACE.
#
# Verified as a detector, not assumed: with the ORDER BY removed from new_data
# in refresh_by_direct_modification(), blocked_by flips from pin_lo to pin_hi.
#
# Disposition: keep.  This and matview-where-lockorder are the two gates on the
# lock-ordering guarantees; fuzz.sh tests the same property probabilistically
# and goes away with that directory.

setup
{
    CREATE TABLE mvp3_base (id int PRIMARY KEY, tag text, v int);
    -- descending insert, so heap order is the reverse of key order
    INSERT INTO mvp3_base
      SELECT g, CASE WHEN g <= 10 THEN 'hot' ELSE 'cold' END, g
        FROM generate_series(20, 1, -1) g;
    CREATE MATERIALIZED VIEW mvp3 AS SELECT id, tag, v FROM mvp3_base;
    CREATE UNIQUE INDEX mvp3_id_idx ON mvp3(id);
    -- deliberately no index on tag: the predicate must force a heap-order scan

    -- Empty the hot range out of the matview while leaving it in the base, so
    -- that a refresh over the hot rows has to INSERT all ten of them.
    DELETE FROM mvp3_base WHERE tag = 'hot';
    REFRESH MATERIALIZED VIEW mvp3;
    INSERT INTO mvp3_base
      SELECT g, 'hot', g FROM generate_series(10, 1, -1) g;
    ANALYZE mvp3_base; ANALYZE mvp3;
}

teardown
{
    DROP MATERIALIZED VIEW mvp3;
    DROP TABLE mvp3_base;
}

# The low end of the range.  Inserts key 1 and holds it uncommitted.
session pin_lo
setup            { BEGIN; SET application_name = 'mvp3_pin_lo'; }
step lo_ins      { REFRESH MATERIALIZED VIEW CONCURRENTLY mvp3 WHERE id = 1; }
step lo_commit   { COMMIT; }

# The high end.  Inserts key 10 and holds it uncommitted.
session pin_hi
setup            { BEGIN; SET application_name = 'mvp3_pin_hi'; }
step hi_ins      { REFRESH MATERIALIZED VIEW CONCURRENTLY mvp3 WHERE id = 10; }
step hi_commit   { COMMIT; }

# Covers ids 1..10, so it must insert both pinned keys and the eight between
# them.  It stops on whichever end it reaches first.
session wide
setup            { SET application_name = 'mvp3_wide'; }
step wide_ins    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvp3 WHERE tag = 'hot'; }

# Takes no lock anyone wants, so it cannot stall the permutation.
session obs
step obs_blocker { SELECT b.application_name AS blocked_by
                     FROM pg_stat_activity a
                     CROSS JOIN LATERAL unnest(pg_blocking_pids(a.pid)) AS bp
                     JOIN pg_stat_activity b ON b.pid = bp
                    WHERE a.application_name = 'mvp3_wide'; }

# wide_ins blocks on one end or the other; obs_blocker names which.  Releasing
# both pins lets it finish, in either direction, so the permutation terminates
# whichever order the implementation chose.
permutation lo_ins hi_ins wide_ins obs_blocker lo_commit hi_commit
