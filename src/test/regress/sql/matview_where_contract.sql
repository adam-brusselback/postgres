--
-- REFRESH MATERIALIZED VIEW ... WHERE ... -- the contract
--
-- What the feature promises, stated once, in one place, as assertions that
-- name no part of how it is implemented.
--
-- The rest of the suite is organised by defect: each test is tied to a thread
-- item or an issue number and says what went wrong and when.  That is the right
-- shape for review and the wrong shape for a rewrite, because it answers "is
-- this bug still fixed" rather than "does this still do what it promises".
-- This file answers the second question.  It is the acceptance criterion for
-- replacing the SPI/string implementation with Query trees: if the promises
-- below still hold afterwards, the rewrite preserved the feature, whatever it
-- did to the machinery.
--
-- Rules for anything added here:
--
--   * No plan shapes, no statement text, no lock levels, no physical order.
--     If it would have to change because the implementation changed, it does
--     not belong in this file -- it belongs in the defect-oriented tests, with
--     a Disposition line saying so.
--   * Every promise gets a check that fails when the promise is broken.  A
--     check that passes both ways is worse than nothing; three of those were
--     found in this suite already.
--
-- Two promises are not expressible in a single session and live as isolation
-- specs.  They are listed here so the contract can be read in one place:
--
--   readers never block                matview-where-serialize
--   overlapping refreshes serialize,   matview-where-serialize
--     disjoint ones do not
--   deterministic lock order,          matview-where-lockorder     (existing rows)
--     so overlapping refreshes         matview-where-insertorder   (inserted rows)
--     cannot deadlock
--
-- Disposition: keep, and keep it first.  This is the file a reviewer should be
-- able to read to learn what the feature does.
--

CREATE TABLE ct_base (id int PRIMARY KEY, grp int, val int);
INSERT INTO ct_base SELECT g, g % 4, g * 10 FROM generate_series(1, 12) g;

CREATE MATERIALIZED VIEW ct_mv AS SELECT id, grp, val FROM ct_base;
CREATE UNIQUE INDEX ON ct_mv(id);

--
-- Promise 1: a refresh makes its scope match what a full refresh would make it.
--
-- Stated as a comparison against the view query itself, so it holds for any
-- implementation that produces the right rows by any means.
--
UPDATE ct_base SET val = val + 1 WHERE id <= 6;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_mv WHERE id <= 6;

SELECT count(*) AS p1_bare_in_scope_differs_from_view
  FROM ((SELECT id, grp, val FROM ct_mv WHERE id <= 6)
        EXCEPT ALL
        (SELECT id, grp, val FROM ct_base WHERE id <= 6)) d;

UPDATE ct_base SET val = val + 1 WHERE id <= 6;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_mv WHERE id <= 6;

SELECT count(*) AS p1_conc_in_scope_differs_from_view
  FROM ((SELECT id, grp, val FROM ct_mv WHERE id <= 6)
        EXCEPT ALL
        (SELECT id, grp, val FROM ct_base WHERE id <= 6)) d;

--
-- Promise 2: rows outside the scope are untouched.
--
-- The base rows 7..12 were changed by neither UPDATE above, so the check is
-- that the matview still holds what it held -- but stating it that way would
-- pass even if the refresh had rewritten them identically.  Change the base
-- outside the scope instead, refresh inside it, and require the matview to
-- still show the OLD values: that fails if the refresh touched anything it
-- should not have.
--
UPDATE ct_base SET val = 999 WHERE id > 6;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_mv WHERE id <= 6;

SELECT count(*) AS p2_out_of_scope_rows_changed
  FROM ct_mv WHERE id > 6 AND val = 999;

-- and the in-scope half is still correct after that refresh
SELECT count(*) AS p2_in_scope_wrong
  FROM ((SELECT id, grp, val FROM ct_mv WHERE id <= 6)
        EXCEPT ALL
        (SELECT id, grp, val FROM ct_base WHERE id <= 6)) d;

--
-- Promise 3: a row that leaves the scope is deleted.
--
-- Deliberate and documented (B15): the predicate names a region of the
-- matview, and a refresh makes that region match the view.  A row that no
-- longer satisfies the view definition is therefore removed, not left behind.
--
CREATE TABLE ct_act (id int PRIMARY KEY, state text, val int);
INSERT INTO ct_act VALUES (1, 'on', 10), (2, 'on', 20), (3, 'off', 30);

CREATE MATERIALIZED VIEW ct_act_mv AS
  SELECT id, state, val FROM ct_act WHERE state = 'on';
CREATE UNIQUE INDEX ON ct_act_mv(id);

SELECT count(*) AS p3_initial FROM ct_act_mv;

UPDATE ct_act SET state = 'off' WHERE id = 1;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_act_mv WHERE id = 1;

-- id 1 has left the view's scope, so it must be gone; id 2 must remain.
SELECT id FROM ct_act_mv ORDER BY id;

--
-- Promise 4: a row that enters the scope is added.
--
UPDATE ct_act SET state = 'on' WHERE id = 3;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_act_mv WHERE id = 3;

SELECT id FROM ct_act_mv ORDER BY id;

--
-- Promise 5 -- the command reports the number of rows it changed -- is not
-- here, and the reason is worth recording rather than quietly working around.
--
-- It was written here first.  It passed, and it could not have done anything
-- else: pg_regress does not echo command tags, so the rowcount never reached
-- the output and three REFRESH statements with three different answers all
-- produced an identical blank.  A check that cannot fail is exactly what the
-- rules at the top of this file forbid, and it took running it to notice --
-- reading it, it looks like a test.
--
-- The rowcount is only observable through pg_stat_statements, so the promise
-- lives with the rows-tracking cases in contrib/pg_stat_statements/sql/
-- utility.sql, which already cover both forms.  That is a different file from
-- the structural block in the same test, which asserts generated SQL text and
-- is to be deleted at the start of Phase 2.
--

--
-- Promise 6: a refresh that changes nothing changes nothing.
--
-- Weaker than it sounds, and the reason it is here: it is the check that
-- caught B4, where a NULLable unique key made every refresh duplicate the
-- NULL-keyed rows.  Repeating a no-op refresh is the cheapest way to catch a
-- whole class of upsert/anti-join disagreements.
--
CREATE TABLE ct_null (id int, val text);
INSERT INTO ct_null VALUES (NULL, 'x'), (1, 'a'), (NULL, 'y');
CREATE MATERIALIZED VIEW ct_null_mv AS SELECT id, val FROM ct_null;
CREATE UNIQUE INDEX ON ct_null_mv(id);

-- Count after EACH form, not once at the end.  Written the other way first --
-- three refreshes then one count -- and it passed with the bug present: the
-- two CONCURRENTLY refreshes took the matview from 3 rows to 7, and the bare
-- refresh that followed compares whole rows, so it repaired the damage before
-- anything looked.  A check placed after a repair step measures the repair.
SELECT count(*) AS p6_before FROM ct_null_mv;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_null_mv WHERE id IS NULL;
REFRESH MATERIALIZED VIEW CONCURRENTLY ct_null_mv WHERE id IS NULL;

SELECT count(*) AS p6_after_two_concurrent_noops FROM ct_null_mv;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_null_mv WHERE id IS NULL;

SELECT count(*) AS p6_after_bare_noop FROM ct_null_mv;

--
-- Promise 7: both forms agree.
--
-- The bare form and CONCURRENTLY select different maintenance strategies, and
-- which one is which changed once already (A8).  What must not change is that
-- they produce the same rows from the same input.
--
CREATE TABLE ct_agree (id int PRIMARY KEY, grp int, val int);
INSERT INTO ct_agree SELECT g, g % 3, g FROM generate_series(1, 9) g;

CREATE MATERIALIZED VIEW ct_agree_a AS
  SELECT grp, sum(val) AS total FROM ct_agree GROUP BY grp;
CREATE UNIQUE INDEX ON ct_agree_a(grp);
CREATE MATERIALIZED VIEW ct_agree_b AS
  SELECT grp, sum(val) AS total FROM ct_agree GROUP BY grp;
CREATE UNIQUE INDEX ON ct_agree_b(grp);

UPDATE ct_agree SET val = val * 2 WHERE grp = 1;

REFRESH MATERIALIZED VIEW CONCURRENTLY ct_agree_a WHERE grp = 1;
REFRESH MATERIALIZED VIEW CONCURRENTLY ct_agree_b WHERE grp = 1;

SELECT count(*) AS p7_forms_disagree
  FROM ((SELECT grp, total FROM ct_agree_a)
        EXCEPT ALL
        (SELECT grp, total FROM ct_agree_b)) d;

-- and both agree with a full refresh
REFRESH MATERIALIZED VIEW ct_agree_a;

SELECT count(*) AS p7_partial_differs_from_full
  FROM ((SELECT grp, total FROM ct_agree_a)
        EXCEPT ALL
        (SELECT grp, total FROM ct_agree_b)) d;

--
-- Cleanup
--
DROP MATERIALIZED VIEW ct_agree_a, ct_agree_b;
DROP TABLE ct_agree;
DROP MATERIALIZED VIEW ct_null_mv;
DROP TABLE ct_null;
DROP MATERIALIZED VIEW ct_act_mv;
DROP TABLE ct_act;
DROP MATERIALIZED VIEW ct_mv;
DROP TABLE ct_base;
