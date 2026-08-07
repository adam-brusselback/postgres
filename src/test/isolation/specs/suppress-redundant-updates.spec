# Concurrency behaviour of the suppress_redundant_updates storage parameter.
#
# Suppressing an update means table_tuple_update() is never called, so the
# concurrency checks it performs must not be lost along with it.  A row that
# another transaction has updated must still produce a serialization failure
# under REPEATABLE READ, and must still be re-evaluated under READ COMMITTED,
# exactly as when the parameter is off.

setup
{
    CREATE TABLE sru (id int primary key, x int);
    CREATE TABLE ctl (id int primary key, x int) WITH (suppress_redundant_updates = on);
    INSERT INTO sru VALUES (1, 1);
    INSERT INTO ctl VALUES (1, 1);
}

teardown
{
    DROP TABLE sru, ctl;
}

# s1 takes its snapshot, then issues an update that is redundant with respect
# to the row it can see.
session s1
step s1_begin_rr	{ BEGIN ISOLATION LEVEL REPEATABLE READ; }
step s1_begin_rc	{ BEGIN ISOLATION LEVEL READ COMMITTED; }
step s1_snapshot	{ SELECT count(*) FROM sru; SELECT count(*) FROM ctl; }
step s1_upd_plain	{ UPDATE sru SET x = 1 WHERE id = 1; }
step s1_upd_supp	{ UPDATE ctl SET x = 1 WHERE id = 1; }
step s1_commit		{ COMMIT; }

# s2 changes the same row underneath s1 and commits.
session s2
step s2_upd_plain	{ UPDATE sru SET x = 2 WHERE id = 1; }
step s2_upd_supp	{ UPDATE ctl SET x = 2 WHERE id = 1; }

session s3
step s3_show		{ SELECT 'sru' AS t, x FROM sru WHERE id = 1
					  UNION ALL SELECT 'ctl', x FROM ctl WHERE id = 1 ORDER BY 1; }

# REPEATABLE READ: both the plain table and the suppressing one must report
# "could not serialize access due to concurrent update".
permutation s1_begin_rr s1_snapshot s2_upd_plain s1_upd_plain s1_commit s3_show
permutation s1_begin_rr s1_snapshot s2_upd_supp s1_upd_supp s1_commit s3_show

# READ COMMITTED: s1's statement takes a fresh snapshot, sees x=2, so the
# update is no longer redundant and must be applied on both tables.
permutation s1_begin_rc s1_snapshot s2_upd_plain s1_upd_plain s1_commit s3_show
permutation s1_begin_rc s1_snapshot s2_upd_supp s1_upd_supp s1_commit s3_show
