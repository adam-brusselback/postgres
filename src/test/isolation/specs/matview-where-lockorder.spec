# REFRESH MATERIALIZED VIEW ... WHERE ... row-lock ordering
#
# Reported on -hackers by Vellaipandiyan ("I wonder whether overlapping
# refreshes could still encounter deadlock scenarios around UPSERT conflicts"),
# and confirmed by Adam Brusselback: the row-locking SELECT had no ORDER BY, so
# two overlapping refreshes could lock the existing rows in different physical
# orders and deadlock.  The fix was a deterministic ORDER BY on the arbiter key.
#
# This spec asserts the ORDER BY is there, rather than trying to provoke the
# deadlock it prevents.  Provoking that needs two refreshes simultaneously
# mid-scan, which isolationtester cannot arrange -- it drives one step at a time.
#
# Instead we read the lock order off the heap.  A refresh blocked partway
# through its locking SELECT has already locked every row it reached, and a row
# locked FOR NO KEY UPDATE carries the locker's xid in xmax -- which any scan
# can see,
# committed or not.  So: pin one row in the middle of the predicate's range,
# send a refresh that covers rows on both sides of it, and read which side has a
# non-zero xmax.
#
# Rows are inserted with id descending, so the heap order of the in-scope rows is
# the reverse of their key order:
#
#   with ORDER BY id     rows 1-4 are locked, 6-10 are not
#   without ORDER BY     a heap-order scan locks 6-10, and 1-4 are not
#
# Reading xmax rather than probing with a conflicting lock is deliberate.  The
# obvious design -- a third session trying to refresh row 1 and row 10 to see
# which one waits -- cannot work: whichever probe succeeds holds a row that the
# blocked refresh still needs, so the permutation cannot be ordered to terminate
# in both the fixed and the broken case.  An observer that takes no conflicting
# lock has no such problem.  (SELECT ... FOR SHARE is not an option either way:
# "cannot lock rows in materialized view".)
#
# Verified as a detector, not assumed: with the ORDER BY removed from the
# locking SELECT in refresh_by_direct_modification(), the locked column inverts.
#
# Disposition: keep.  This is the only gate on the A5 fix.  The shell reproducer
# in src/test/matview_where_stress/ tests the same property probabilistically
# and goes away with that directory.

setup
{
    CREATE TABLE mvlo_base (id int PRIMARY KEY, tag text, v int);
    -- descending insert, so heap order is the reverse of key order
    INSERT INTO mvlo_base
      SELECT g, CASE WHEN g <= 10 THEN 'hot' ELSE 'cold' END, g
        FROM generate_series(20, 1, -1) g;
    CREATE MATERIALIZED VIEW mvlo AS SELECT id, tag, v FROM mvlo_base;
    CREATE UNIQUE INDEX mvlo_id_idx ON mvlo(id);
    -- deliberately no index on tag: the predicate must force a heap-order scan
    ANALYZE mvlo;
}

teardown
{
    DROP MATERIALIZED VIEW mvlo;
    DROP TABLE mvlo_base;
}

# Holds the row in the middle of the in-scope range, so the wide refresh stops
# there with part of its work done.
session pin
setup           { BEGIN; }
step pin_mid    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvlo WHERE id = 5; }
step pin_commit { COMMIT; }

# Covers ids 1..10, on both sides of the pinned row.  No index on tag, so the
# locking SELECT's order is whatever the implementation chooses.
session wide
setup            { BEGIN; }
step wide_ref    { REFRESH MATERIALIZED VIEW CONCURRENTLY mvlo WHERE tag = 'hot'; }
step wide_commit { COMMIT; }

# Takes no lock that anyone else wants, so it can never stall the permutation.
session obs
step obs_locked  { SELECT id, xmax <> '0'::xid AS locked
                     FROM mvlo WHERE tag = 'hot' ORDER BY id; }

# wide_ref blocks on the pinned row 5 with rows 1-4 locked.  obs_locked reads
# that off the heap.  Then the pin releases, wide_ref finishes, and both commit
# -- a sequence that terminates whichever direction the refresh locked in, which
# is why the observer must not hold anything.
permutation pin_mid wide_ref obs_locked pin_commit wide_commit
