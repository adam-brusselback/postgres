--
-- REFRESH MATERIALIZED VIEW ... WHERE ...: privileges and session state
--
-- These cases cover the security boundary of the WHERE clause and the
-- session-level matview maintenance flag.
--
-- Where the correct outcome is that the statement is rejected, it is wrapped in
-- a block reporting the SQLSTATE rather than the message text, so a reworded
-- error does not churn the expected file.
--
-- Each case covered a live defect when it was written, and the expected output
-- describes what the command should do, so each one failed until its defect was
-- fixed.  Where the pre-fix behaviour says what the case is for, the comment on
-- the case records it.
--

--
-- Test 1: The predicate must not run with the matview owner's privileges
--
-- Reported by Zsolt Parragi: a caller holding only MAINTAIN could get their
-- own function run with the matview owner's privileges.  The fix allows a
-- MAINTAIN caller only when every function in the predicate
-- is leakproof and requiring ownership otherwise.  This is Zsolt's repro.
--
-- RefreshMatViewByOid() switches to the owner before analyzing or executing
-- anything, so functions named in a caller-supplied predicate run as the
-- owner.  A caller holding only MAINTAIN must not be able to reach objects it
-- has no privileges on.
--

CREATE ROLE regress_matview_owner;
CREATE ROLE regress_matview_maint;

CREATE TABLE matview_priv_target (note text);
CREATE MATERIALIZED VIEW matview_priv_mv AS SELECT 1 AS id;
CREATE UNIQUE INDEX ON matview_priv_mv (id);

ALTER TABLE matview_priv_target OWNER TO regress_matview_owner;
ALTER MATERIALIZED VIEW matview_priv_mv OWNER TO regress_matview_owner;

CREATE SCHEMA matview_priv_atk AUTHORIZATION regress_matview_maint;
-- SELECT as well as MAINTAIN, so that the leakproof rule is the only thing
-- left that can refuse this: a predicate naming a column the caller may not
-- read is refused for that reason instead (Test 6, case 58), and without the
-- grant this test would pass on the wrong refusal.
GRANT MAINTAIN, SELECT ON matview_priv_mv TO regress_matview_maint;

SET ROLE regress_matview_maint;

GRANT USAGE ON SCHEMA matview_priv_atk TO regress_matview_owner;

-- The write is done by a volatile function, wrapped in a stable one so that
-- the volatility check in transformRefreshWhereClause() does not reject it.
CREATE FUNCTION matview_priv_atk.do_write() RETURNS void
  LANGUAGE plpgsql VOLATILE AS $$
BEGIN
  INSERT INTO public.matview_priv_target
    VALUES ('written as ' || pg_catalog.current_user());
END $$;

CREATE FUNCTION matview_priv_atk.pred(int) RETURNS boolean
  LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM matview_priv_atk.do_write();
  RETURN true;
END $$;

-- The caller cannot write to the table directly.
INSERT INTO public.matview_priv_target VALUES ('direct write');

-- A predicate naming a function the caller could not usefully run itself must
-- be refused.  42501 is insufficient_privilege.
DO $$
BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY matview_priv_mv'
          ' WHERE matview_priv_atk.pred(id)';
  RAISE NOTICE 'refresh was allowed';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'refresh was rejected, SQLSTATE %', SQLSTATE;
END $$;

RESET ROLE;

-- Must be empty.  Before the fix this held one row per predicate evaluation,
-- three of them: the row-locking SELECT, the new_data CTE and the anti-join
-- DELETE each ran the caller's function with the owner's privileges.
SELECT note, count(*) AS predicate_evaluations
  FROM matview_priv_target GROUP BY note;

DROP FUNCTION matview_priv_atk.pred(int);
DROP FUNCTION matview_priv_atk.do_write();
DROP SCHEMA matview_priv_atk;
DROP MATERIALIZED VIEW matview_priv_mv;
DROP TABLE matview_priv_target;
DROP ROLE regress_matview_maint;
DROP ROLE regress_matview_owner;

--
-- Test 2: The predicate must not run inside the matview maintenance window
--
-- Related to Zsolt Parragi's report above but distinct from it, and not
-- covered by the leakproof rule: the predicate runs not only as the owner but
-- with matview write
-- protection switched off, which is exposure the full and concurrent refresh
-- paths do not have, since the statements they run inside that window contain
-- no user-supplied expressions.
--
-- OpenMatViewIncrementalMaintenance() is called before the SPI statements that
-- evaluate the predicate, so a predicate function is exempt from the "cannot
-- change materialized view" check, and that exemption was global rather than
-- scoped to the matview being refreshed.
--
-- Everything here is owned by the role running the test, so that no ACL
-- failure can mask the behaviour under test.
--

CREATE TABLE matview_mw_base (id int primary key, v text);
INSERT INTO matview_mw_base VALUES (1, 'a');
CREATE MATERIALIZED VIEW matview_mw_driver AS SELECT id, v FROM matview_mw_base;
CREATE UNIQUE INDEX ON matview_mw_driver (id);

CREATE TABLE matview_mw_vbase (id int primary key, v text);
INSERT INTO matview_mw_vbase VALUES (1, 'a'), (2, 'b');
CREATE MATERIALIZED VIEW matview_mw_victim AS SELECT id, v FROM matview_mw_vbase;
CREATE UNIQUE INDEX ON matview_mw_victim (id);

CREATE FUNCTION matview_mw_write() RETURNS void
  LANGUAGE plpgsql VOLATILE AS $$
BEGIN
  DELETE FROM public.matview_mw_victim;
  INSERT INTO public.matview_mw_victim VALUES (99, 'injected');
END $$;

CREATE FUNCTION matview_mw_pred(int) RETURNS boolean
  LANGUAGE plpgsql STABLE AS $$
BEGIN
  PERFORM public.matview_mw_write();
  RETURN true;
END $$;

-- Called outside a refresh, the write is correctly refused.
SELECT public.matview_mw_write();

SELECT count(*) AS victim_rows_before FROM matview_mw_victim;

-- Reached through a predicate, the same write must still be refused.  42809 is
-- wrong_object_type, which is what "cannot change materialized view" carries.
DO $$
BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY matview_mw_driver'
          ' WHERE public.matview_mw_pred(id)';
  RAISE NOTICE 'refresh was allowed';
EXCEPTION WHEN others THEN
  RAISE NOTICE 'refresh was rejected, SQLSTATE %', SQLSTATE;
END $$;

-- Must be the two original rows, not the one the predicate tried to insert.
SELECT * FROM matview_mw_victim ORDER BY id;

DROP FUNCTION matview_mw_pred(int);
DROP FUNCTION matview_mw_write();
DROP MATERIALIZED VIEW matview_mw_victim;
DROP TABLE matview_mw_vbase;
DROP MATERIALIZED VIEW matview_mw_driver;
DROP TABLE matview_mw_base;

--
-- Test 3: The leakproof gate must be an allowlist, not a denylist
--
-- Found by auditing the gate added for Zsolt Parragi's report above.  That
-- gate refuses a predicate whose functions
-- are not all leakproof, but it was written as a walker that flagged known-bad
-- FUNCTIONS and let through every node type it did not recognise.
--
-- Leakproofness is the wrong question for a subquery rather than a question
-- answered wrongly.  It constrains what a function may reveal about its
-- arguments; it says nothing about which RELATIONS an expression may read.  A
-- sublink reads relations as the matview owner, so a caller holding only
-- MAINTAIN could read anything the owner could, and then learn the value by
-- observing which row the refresh touched.  Every sublink form reached it,
-- and so did a cast to a domain whose CHECK constraint calls a non-leakproof
-- function, because that function never appears in the expression tree.
--
-- The gate is now modelled on contain_leaked_vars_walker() in clauses.c, which
-- solves the same problem for row-level security: an explicit list of node
-- types that cannot reach a relation, and everything else refused.  Since
-- then it also descends into the query levels it finds and asks about the
-- relations in their range tables (Test 6), which is what lets a subquery
-- through when the caller could have run it themselves.  These six all still
-- fail: five read mvlp.secret, which the caller cannot; the sixth reaches no
-- relation and is refused because generate_series() is not leakproof.
--

CREATE ROLE regress_mvlp_owner;
CREATE ROLE regress_mvlp_maint;
CREATE SCHEMA mvlp AUTHORIZATION regress_mvlp_owner;
GRANT USAGE ON SCHEMA mvlp TO regress_mvlp_maint;

SET ROLE regress_mvlp_owner;
CREATE TABLE mvlp.base (id int PRIMARY KEY, v text);
INSERT INTO mvlp.base VALUES (1, 'a'), (2, 'b');
-- The caller has no privileges on this at all.
CREATE TABLE mvlp.secret (val int);
INSERT INTO mvlp.secret VALUES (2);
CREATE MATERIALIZED VIEW mvlp.mv AS SELECT id, v FROM mvlp.base;
CREATE UNIQUE INDEX ON mvlp.mv (id);
GRANT MAINTAIN, SELECT ON mvlp.mv TO regress_mvlp_maint;
CREATE FUNCTION mvlp.peek(int) RETURNS bool LANGUAGE sql STABLE AS
  $$SELECT $1 <= (SELECT val FROM mvlp.secret)$$;
CREATE DOMAIN mvlp.dom AS int CHECK (mvlp.peek(VALUE));
RESET ROLE;

SET ROLE regress_mvlp_maint;

-- Control: the caller genuinely cannot read the table.
SELECT * FROM mvlp.secret;

-- Control: a predicate over the matview's own columns is still allowed.
REFRESH MATERIALIZED VIEW CONCURRENTLY mvlp.mv WHERE id = 1;

-- Each of these ran the subquery as the owner before the fix.  42501 is
-- insufficient_privilege.
DO $$
DECLARE
  stmt text;
  probes text[] := ARRAY[
    'WHERE id = (SELECT val FROM mvlp.secret)',
    'WHERE EXISTS (SELECT 1 FROM mvlp.secret WHERE val = id)',
    'WHERE id = ANY (SELECT val FROM mvlp.secret)',
    'WHERE CASE WHEN id > 0 THEN id = (SELECT val FROM mvlp.secret) ELSE false END',
    'WHERE id IN (SELECT generate_series(1, 2))',
    'WHERE id = (1::mvlp.dom)::int'];
  p text;
BEGIN
  FOREACH p IN ARRAY probes LOOP
    BEGIN
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mvlp.mv ' || p;
      RAISE NOTICE 'ALLOWED (must not be): %', p;
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'refused: %', p;
    END;
  END LOOP;
END $$;

RESET ROLE;

-- The owner may still use all of them: for the owner the predicate runs with
-- the privileges it already has, so there is nothing to escalate.
SET ROLE regress_mvlp_owner;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvlp.mv WHERE id = (SELECT val FROM mvlp.secret);
REFRESH MATERIALIZED VIEW CONCURRENTLY mvlp.mv WHERE id = (1::mvlp.dom)::int;
RESET ROLE;

DROP MATERIALIZED VIEW mvlp.mv;
DROP DOMAIN mvlp.dom;
DROP FUNCTION mvlp.peek(int);
DROP TABLE mvlp.secret;
DROP TABLE mvlp.base;
DROP SCHEMA mvlp;
DROP ROLE regress_mvlp_maint;
DROP ROLE regress_mvlp_owner;

--
-- Test 4: matview_maintenance_depth must not leak when a refresh fails
--
-- Reported by Zsolt Parragi: an error during a refresh removed the matview
-- modification restrictions for the rest of the session.  The cause was a
-- missing PG_TRY around the
-- OpenMatViewIncrementalMaintenance()/Close pair in the direct-modification
-- path (the match/merge site already handles it)", with "Will fix".  This is
-- Zsolt's repro, extended to show that the exemption is not scoped to the
-- matview being refreshed.
--
-- refresh_by_direct_modification() had no PG_TRY between
-- OpenMatViewIncrementalMaintenance() and its matching Close, so an error in
-- between skipped the Close and left the counter above zero, disabling the
-- "cannot change materialized view" check for the remainder of the session.
-- It has one now, and this is what says so.
--

CREATE TABLE mv_leak_base (id int, code int, v text);
INSERT INTO mv_leak_base VALUES (1, 100, 'a'), (2, 200, 'b'), (3, 300, 'c');

CREATE MATERIALIZED VIEW mv_leak AS SELECT id, code, v FROM mv_leak_base;
CREATE UNIQUE INDEX ON mv_leak (code);

-- Control: direct DML is refused, as it must be.
DELETE FROM mv_leak WHERE id = 1;
SELECT count(*) AS rows_before FROM mv_leak;

-- Make two source rows collide on the arbiter index so the refresh CTE fails.
-- Failing here is correct; what matters is the state left behind.
UPDATE mv_leak_base SET code = 999 WHERE id IN (1, 2);
\set VERBOSITY terse
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_leak WHERE id <= 2;
\set VERBOSITY default

-- Both of these must still be refused, and the contents must be unchanged.
-- Before the fix the maintenance exemption outlived the refresh and both
-- succeeded.
DELETE FROM mv_leak WHERE id = 1;
INSERT INTO mv_leak (id, code, v) VALUES (42, 4242, 'injected');
SELECT * FROM mv_leak ORDER BY id;

-- Nor was the exemption scoped to mv_leak: every matview in the session became
-- writable, including one with no unique index at all.  This must fail.
CREATE MATERIALIZED VIEW mv_leak_other AS SELECT id, v FROM mv_leak_base;
DELETE FROM mv_leak_other;
SELECT count(*) AS other_rows_after_delete FROM mv_leak_other;

DROP MATERIALIZED VIEW mv_leak_other;
DROP MATERIALIZED VIEW mv_leak;
DROP TABLE mv_leak_base;

--
-- Test 5: a subquery in the predicate, for a caller who is not the owner
--
-- A subquery used to be refused outright, as a consequence of Test 1's rule rather than a separate decision:
-- the leakproof gate walks the predicate over an allowed list of node tags and
-- refuses everything else (Test 3), and SubLink was not on that list.
--
-- That was recorded here because of what it cost.  Naming the correct scope
-- for a change to a dimension table requires asking the fact table which rows
-- joined to it, which is a subquery, and that is the pattern the
-- documentation's blast-radius warning tells people to write.  So the
-- documented correct usage was available to the owner and to nobody else.
--
-- Refusing was the safe default and it was not obviously wrong.  The subquery
-- runs as the owner, so a caller who cannot read the table it names would
-- otherwise learn which of its rows intersect the matview.  But it was
-- indiscriminate: it refused the subquery whether or not the caller could have
-- run it themselves.  The rule is now the narrower one, and the note this test
-- used to carry said what that would look like: "the first two would start
-- succeeding and the last must not".  That is what it now checks.
--
-- Test 6 covers the rule exhaustively.  This one is the worked example of the
-- use case, with the tables named after what they are.
--

--
-- The rule, once, in one place.  A caller who does not own the matview may use
-- a predicate that reads a relation only if reading it tells them nothing they
-- could not have read directly: they must hold SELECT on the columns it reads,
-- of the matview as much as of anything a subquery names, and must not be
-- reaching the rows through row-level security or a security_invoker view that
-- the owner is not reaching them through.  Functions are separate and unchanged
-- (Test 1): a predicate that is not leakproof is owner-only however readable
-- its tables are, because the escalation there is running the caller's code as
-- the owner rather than reading the owner's rows.
--

CREATE ROLE regress_mvsq_owner;
CREATE ROLE regress_mvsq_maint;
CREATE SCHEMA mvsq;
GRANT USAGE ON SCHEMA mvsq TO regress_mvsq_owner, regress_mvsq_maint;

CREATE TABLE mvsq.fact (id int PRIMARY KEY, did int);
CREATE TABLE mvsq.dim (id int PRIMARY KEY, nm text);
CREATE TABLE mvsq.secret (id int, s text);
INSERT INTO mvsq.dim VALUES (1, 'one'), (2, 'two');
INSERT INTO mvsq.fact SELECT g, (g % 2) + 1 FROM generate_series(1, 4) g;
INSERT INTO mvsq.secret VALUES (1, 'x');

CREATE MATERIALIZED VIEW mvsq.mv AS
  SELECT f.id, f.did, d.nm FROM mvsq.fact f JOIN mvsq.dim d ON d.id = f.did;
CREATE UNIQUE INDEX ON mvsq.mv (id);

ALTER TABLE mvsq.fact OWNER TO regress_mvsq_owner;
ALTER TABLE mvsq.dim OWNER TO regress_mvsq_owner;
ALTER TABLE mvsq.secret OWNER TO regress_mvsq_owner;
ALTER MATERIALIZED VIEW mvsq.mv OWNER TO regress_mvsq_owner;
GRANT MAINTAIN, SELECT ON mvsq.mv TO regress_mvsq_maint;
-- The maintainer may read the fact and dimension tables, and not the secret.
GRANT SELECT ON mvsq.fact, mvsq.dim TO regress_mvsq_maint;

UPDATE mvsq.dim SET nm = 'ONE' WHERE id = 1;

-- Control: a plain column predicate is available to MAINTAIN, as Test 1 says.
SET ROLE regress_mvsq_maint;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv WHERE id = 3;

-- Allowed: the maintainer has SELECT on every table the subquery names and
-- could have run it themselves.
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE id IN (SELECT f.id FROM mvsq.fact f WHERE f.did = 1);

-- Allowed, correlated form of the same thing.  This is the shape the
-- documentation recommends for a dimension-table change, and the one that was
-- available to the owner alone.
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE EXISTS (SELECT 1 FROM mvsq.fact f WHERE f.id = mvsq.mv.id AND f.did = 1);

-- Refused: the maintainer cannot read mvsq.secret, so the rows the refresh
-- touched would tell them which of its rows exist.
SELECT count(*) FROM mvsq.secret;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE id IN (SELECT s.id FROM mvsq.secret s);
RESET ROLE;

-- The owner may use all three, including the one over mvsq.secret.
SET ROLE regress_mvsq_owner;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE id IN (SELECT s.id FROM mvsq.secret s);
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE EXISTS (SELECT 1 FROM mvsq.fact f WHERE f.id = mvsq.mv.id AND f.did = 1);
RESET ROLE;

-- The dimension change reached the two rows that join to it, and no others:
-- what the maintainer's own correlated refresh above was for.
SELECT id, did, nm FROM mvsq.mv ORDER BY id;

DROP MATERIALIZED VIEW mvsq.mv;
DROP TABLE mvsq.secret;
DROP TABLE mvsq.fact;
DROP TABLE mvsq.dim;
DROP SCHEMA mvsq;
DROP ROLE regress_mvsq_owner;
DROP ROLE regress_mvsq_maint;

--
-- Test 6: the rule, case by case
--
-- Test 5 is the use case; this is the boundary.  Every case here is a way a
-- predicate can reach a relation, asked twice: once against a table the caller
-- may read, where it must be allowed, and once against one they may not, where
-- it must be refused.  The pairing is the point.  A gate that refuses
-- everything passes the second half of this test and fails the first, and the
-- version of this feature that shipped before the rule was narrowed would have
-- done exactly that.
--
-- The routes are not decoration.  The check walks the parsed predicate and
-- inspects the range table of every query level it finds, so each of these is a
-- different way for a relation to appear in a range table: a sublink, a
-- FROM-clause subquery, a CTE, a set-operation arm, a LATERAL item and a
-- recursive term.  Each was tried against a table the caller cannot read
-- before it was written down here.
--
-- This is the cheapest check in the file to break.  The allowed list of node
-- tags in refresh_qual_needs_owner_walker() gains a tag, or a query level stops
-- being visited, and one of these silently starts succeeding.
--

CREATE ROLE regress_mvg_owner;
CREATE ROLE regress_mvg_maint;
CREATE ROLE regress_mvg_bypass BYPASSRLS;
CREATE ROLE regress_mvg_super SUPERUSER;
CREATE SCHEMA mvg;
GRANT USAGE ON SCHEMA mvg
  TO regress_mvg_owner, regress_mvg_maint, regress_mvg_bypass, regress_mvg_super;

-- open: the maintainer may read it.  closed: they may not.  cols: they may
-- read two of its three columns.  theirs: they own it, and the matview's owner
-- may read it.
CREATE TABLE mvg.open   (id int PRIMARY KEY, gid int, who name);
CREATE TABLE mvg.closed (id int PRIMARY KEY, s text);
CREATE TABLE mvg.cols   (id int PRIMARY KEY, ok int, hidden int);
CREATE TABLE mvg.theirs (id int PRIMARY KEY, gid int);
INSERT INTO mvg.open SELECT g, (g % 2) + 1,
       CASE WHEN g <= 2 THEN 'regress_mvg_maint' ELSE 'other' END
  FROM generate_series(1, 4) g;
INSERT INTO mvg.closed VALUES (1, 'x');
INSERT INTO mvg.cols   SELECT g, g, g * 100 FROM generate_series(1, 4) g;
INSERT INTO mvg.theirs SELECT g, (g % 2) + 1 FROM generate_series(1, 4) g;

CREATE MATERIALIZED VIEW mvg.mv AS SELECT id, gid, who FROM mvg.open;
CREATE UNIQUE INDEX ON mvg.mv (id);

-- Two views over the closed table.  An ordinary view is read with its own
-- owner's privileges whoever runs it, so the caller learns nothing from the
-- refresh they could not learn by selecting from the view; a security_invoker
-- view is read as whoever runs it, which here is the matview's owner.
CREATE VIEW mvg.v_plain   AS SELECT id FROM mvg.closed;
CREATE VIEW mvg.v_invoker WITH (security_invoker = true) AS SELECT id FROM mvg.closed;

-- A function that reads the closed table, to check that a function cannot be
-- used to get at what a subquery may not.
CREATE FUNCTION mvg.read_closed() RETURNS SETOF int LANGUAGE sql STABLE
  AS $$SELECT id FROM mvg.closed$$;

ALTER TABLE mvg.open   OWNER TO regress_mvg_owner;
ALTER TABLE mvg.closed OWNER TO regress_mvg_owner;
ALTER TABLE mvg.cols   OWNER TO regress_mvg_owner;
ALTER TABLE mvg.theirs OWNER TO regress_mvg_maint;
ALTER VIEW  mvg.v_plain   OWNER TO regress_mvg_owner;
ALTER VIEW  mvg.v_invoker OWNER TO regress_mvg_owner;
ALTER FUNCTION mvg.read_closed() OWNER TO regress_mvg_owner;
ALTER MATERIALIZED VIEW mvg.mv OWNER TO regress_mvg_owner;

GRANT MAINTAIN, SELECT ON mvg.mv TO regress_mvg_maint, regress_mvg_bypass;
GRANT SELECT ON mvg.open TO regress_mvg_maint, regress_mvg_bypass;
GRANT SELECT (id, ok) ON mvg.cols TO regress_mvg_maint;
GRANT SELECT ON mvg.v_plain, mvg.v_invoker TO regress_mvg_maint;
GRANT SELECT ON mvg.theirs TO regress_mvg_owner;

-- Report the verdict rather than let the message through, so that one line of
-- output covers one case.  A refusal is reported with its message: the
-- messages name which of the reasons it was, and a case moving between them is
-- as much a change as a case moving between allowed and refused.  The context
-- tells a refusal by the check apart from one raised by running the generated
-- SQL, which happens for its own reasons and would otherwise read the same.
CREATE FUNCTION mvg.try(who text, label text, pred text) RETURNS text
  LANGUAGE plpgsql AS $$
DECLARE ctx text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', who);
  BEGIN
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mvg.mv WHERE ' || pred;
    RESET ROLE;
    RETURN format('%-32s allowed', label);
  EXCEPTION WHEN others THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS ctx = PG_EXCEPTION_CONTEXT;
    RETURN format('%-32s %s: %s', label,
                  CASE WHEN ctx LIKE '%mvg.mv mv%' THEN 'refused when run'
                       ELSE 'refused' END,
                  SQLERRM);
  END;
END $$;

--
-- 6a: the routes, over a table the caller may read.  All allowed.
--
SELECT mvg.try('regress_mvg_maint', '1  plain column',
  $$id = 1$$);
SELECT mvg.try('regress_mvg_maint', '2  sublink',
  $$id IN (SELECT o.id FROM mvg.open o WHERE o.gid = 1)$$);
SELECT mvg.try('regress_mvg_maint', '3  correlated sublink',
  $$EXISTS (SELECT 1 FROM mvg.open o WHERE o.id = mvg.mv.id)$$);
SELECT mvg.try('regress_mvg_maint', '4  NOT EXISTS',
  $$NOT EXISTS (SELECT 1 FROM mvg.open o WHERE o.id = mvg.mv.id AND o.gid = 9)$$);
SELECT mvg.try('regress_mvg_maint', '5  FROM-clause subquery',
  $$id IN (SELECT x.id FROM (SELECT o.id FROM mvg.open o) x)$$);
SELECT mvg.try('regress_mvg_maint', '6  CTE',
  $$id IN (WITH c AS (SELECT o.id FROM mvg.open o) SELECT c.id FROM c)$$);
SELECT mvg.try('regress_mvg_maint', '7  recursive CTE',
  $$id IN (WITH RECURSIVE c(n) AS (SELECT o.id FROM mvg.open o WHERE o.id = 1
                                   UNION ALL SELECT n FROM c WHERE n < 0)
           SELECT n FROM c)$$);
SELECT mvg.try('regress_mvg_maint', '8  UNION arm',
  $$id IN (SELECT o.id FROM mvg.open o UNION SELECT o2.id FROM mvg.open o2)$$);
SELECT mvg.try('regress_mvg_maint', '9  EXCEPT arm',
  $$id IN (SELECT o.id FROM mvg.open o
           EXCEPT SELECT o2.id FROM mvg.open o2 WHERE o2.id > 99)$$);
SELECT mvg.try('regress_mvg_maint', '10 LATERAL',
  $$id IN (SELECT l.id FROM mvg.open o,
             LATERAL (SELECT o2.id FROM mvg.open o2 WHERE o2.id = o.id) l)$$);
SELECT mvg.try('regress_mvg_maint', '11 ARRAY sublink',
  $$id = ANY (ARRAY(SELECT o.id FROM mvg.open o))$$);
SELECT mvg.try('regress_mvg_maint', '12 scalar subquery in CASE',
  $$id = CASE WHEN true
              THEN (SELECT o.id FROM mvg.open o ORDER BY o.id LIMIT 1)
              ELSE 0 END$$);
SELECT mvg.try('regress_mvg_maint', '13 row-comparison sublink',
  $$(id, id) = (SELECT o.id, o.id FROM mvg.open o ORDER BY o.id LIMIT 1)$$);
SELECT mvg.try('regress_mvg_maint', '14 DISTINCT ON, ORDER BY',
  $$id IN (SELECT DISTINCT ON (o.id) o.id FROM mvg.open o ORDER BY o.id)$$);
SELECT mvg.try('regress_mvg_maint', '15 sublink under a sublink',
  $$id IN (SELECT o.id FROM mvg.open o
           WHERE o.id = ANY (ARRAY(SELECT o2.id FROM mvg.open o2)))$$);
SELECT mvg.try('regress_mvg_maint', '16 the matview itself',
  $$id IN (SELECT m.id FROM mvg.mv m WHERE m.gid = 1)$$);
SELECT mvg.try('regress_mvg_maint', '17 an ordinary view',
  $$id IN (SELECT v.id FROM mvg.v_plain v)$$);
SELECT mvg.try('regress_mvg_maint', '18 columns they may read',
  $$id IN (SELECT c.id FROM mvg.cols c WHERE c.ok > 0)$$);
SELECT mvg.try('regress_mvg_maint', '19 no column named',
  $$id IN (SELECT 1 FROM mvg.cols c)$$);
SELECT mvg.try('regress_mvg_maint', '20 a table they own',
  $$id IN (SELECT t.id FROM mvg.theirs t)$$);

--
-- 6a-2: where the readable-table rule stops and Test 1's function rule starts.
--
-- These read nothing the caller could not read, and are refused anyway.  An
-- aggregate and a window function are functions, and count(), min() and
-- row_number() are not marked leakproof, and almost nothing is, so the rule
-- that a non-owner's predicate must be leakproof catches them.  That rule is
-- unchanged and deliberate: what it prevents is not reading the owner's rows
-- but running the caller's code as the owner, which a readable range table
-- says nothing about.
--
-- Recorded because the line is a surprising place for it to fall and because
-- these are the cases to revisit first if it is ever moved.  Anyone marking
-- more functions leakproof upstream will flip them, which is the correct
-- outcome and should be visible here rather than silent.
--
SELECT mvg.try('regress_mvg_maint', '21 an aggregate in HAVING',
  $$id IN (SELECT o.id FROM mvg.open o GROUP BY o.id HAVING count(*) > 0)$$);
SELECT mvg.try('regress_mvg_maint', '22 an aggregate in a target list',
  $$id = (SELECT min(o.id) FROM mvg.open o)$$);
SELECT mvg.try('regress_mvg_maint', '23 a window function',
  $$id IN (SELECT w.id FROM (SELECT o.id, row_number() OVER () FROM mvg.open o) w)$$);

-- The whole message for one of them, which mvg.try() cannot show: it reports
-- SQLERRM, and what makes this refusal usable is the DETAIL.  "Not leakproof"
-- is not a property anyone can read off the expression they wrote, since
-- almost nothing is marked leakproof, so the refusal has to name the function it
-- stopped at or the caller is left guessing which part of the condition was
-- the problem.
SET ROLE regress_mvg_maint;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvg.mv
  WHERE id = (SELECT min(o.id) FROM mvg.open o);
RESET ROLE;

--
-- 6b: the same routes, over a table the caller may not read.  All refused,
-- and each names mvg.closed rather than blaming a function.
--
SELECT mvg.try('regress_mvg_maint', '24 sublink',
  $$id IN (SELECT c.id FROM mvg.closed c)$$);
SELECT mvg.try('regress_mvg_maint', '25 correlated sublink',
  $$EXISTS (SELECT 1 FROM mvg.closed c WHERE c.id = mvg.mv.id)$$);
SELECT mvg.try('regress_mvg_maint', '26 NOT EXISTS',
  $$NOT EXISTS (SELECT 1 FROM mvg.closed c WHERE c.id = mvg.mv.id)$$);
SELECT mvg.try('regress_mvg_maint', '27 FROM-clause subquery',
  $$id IN (SELECT x.id FROM (SELECT c.id FROM mvg.closed c) x)$$);
SELECT mvg.try('regress_mvg_maint', '28 CTE',
  $$id IN (WITH c AS (SELECT cl.id FROM mvg.closed cl) SELECT c.id FROM c)$$);
SELECT mvg.try('regress_mvg_maint', '29 recursive CTE',
  $$id IN (WITH RECURSIVE c(n) AS (SELECT cl.id FROM mvg.closed cl
                                   UNION ALL SELECT n FROM c WHERE n < 0)
           SELECT n FROM c)$$);
SELECT mvg.try('regress_mvg_maint', '30 UNION arm',
  $$id IN (SELECT o.id FROM mvg.open o UNION SELECT c.id FROM mvg.closed c)$$);
SELECT mvg.try('regress_mvg_maint', '31 EXCEPT arm',
  $$id IN (SELECT o.id FROM mvg.open o EXCEPT SELECT c.id FROM mvg.closed c)$$);
SELECT mvg.try('regress_mvg_maint', '32 LATERAL',
  $$id IN (SELECT l.id FROM mvg.open o,
             LATERAL (SELECT c.id FROM mvg.closed c WHERE c.id = o.id) l)$$);
SELECT mvg.try('regress_mvg_maint', '33 ARRAY sublink',
  $$id = ANY (ARRAY(SELECT c.id FROM mvg.closed c))$$);
SELECT mvg.try('regress_mvg_maint', '34 scalar subquery in CASE',
  $$id = CASE WHEN true THEN (SELECT c.id FROM mvg.closed c LIMIT 1) ELSE 0 END$$);
SELECT mvg.try('regress_mvg_maint', '35 row-comparison sublink',
  $$(id, id) = (SELECT c.id, c.id FROM mvg.closed c LIMIT 1)$$);
SELECT mvg.try('regress_mvg_maint', '36 subquery in a target list',
  $$id IN (SELECT (SELECT c.id FROM mvg.closed c LIMIT 1))$$);
SELECT mvg.try('regress_mvg_maint', '37 DISTINCT ON, ORDER BY',
  $$id IN (SELECT DISTINCT ON (c.id) c.id FROM mvg.closed c ORDER BY c.id)$$);
SELECT mvg.try('regress_mvg_maint', '38 sublink under a sublink',
  $$id IN (SELECT o.id FROM mvg.open o
           WHERE o.id = ANY (ARRAY(SELECT c.id FROM mvg.closed c)))$$);
SELECT mvg.try('regress_mvg_maint', '39 join, one side closed',
  $$id IN (SELECT o.id FROM mvg.open o JOIN mvg.closed c ON c.id = o.id)$$);
SELECT mvg.try('regress_mvg_maint', '40 a column they may not read',
  $$id IN (SELECT c.id FROM mvg.cols c WHERE c.hidden > 0)$$);
SELECT mvg.try('regress_mvg_maint', '41 a whole-row reference',
  $$id IN (SELECT 1 FROM mvg.cols c WHERE c::text <> '')$$);
-- The counterpart to case 19, and the one the row count says the most from:
-- naming no column is not the same as reading nothing, so it takes what
-- SELECT count(*) takes, which is SELECT on some column.
SELECT mvg.try('regress_mvg_maint', '42 no column named',
  $$id IN (SELECT 1 FROM mvg.closed c)$$);
SELECT mvg.try('regress_mvg_maint', '43 a security_invoker view',
  $$id IN (SELECT v.id FROM mvg.v_invoker v)$$);

-- A function is refused whatever it reads, so it cannot be the way round 6b.
-- These say so, and say it with the function's own message.
SELECT mvg.try('regress_mvg_maint', '44 a function, in FROM',
  $$id IN (SELECT r FROM mvg.read_closed() r)$$);
SELECT mvg.try('regress_mvg_maint', '45 a function, in an expression',
  $$id IN (SELECT mvg.read_closed())$$);

--
-- 6c: the owner is asked nothing.  All allowed, including the ones 6b refused.
--
SELECT mvg.try('regress_mvg_owner', '46 owner, closed table',
  $$id IN (SELECT c.id FROM mvg.closed c)$$);
SELECT mvg.try('regress_mvg_owner', '47 owner, security_invoker view',
  $$id IN (SELECT v.id FROM mvg.v_invoker v)$$);
SELECT mvg.try('regress_mvg_owner', '48 owner, a function',
  $$id IN (SELECT mvg.read_closed())$$);
SELECT mvg.try('regress_mvg_owner', '49 owner, an aggregate',
  $$id = (SELECT min(o.id) FROM mvg.open o)$$);
SELECT mvg.try('regress_mvg_super', '50 superuser, closed table',
  $$id IN (SELECT c.id FROM mvg.closed c)$$);

--
-- 6d: row-level security.  The predicate runs as the owner, who is exempt from
-- the policies on their own table unless they are FORCEd, so a caller who is
-- subject to them would learn from the refresh about rows the policies exist to
-- hide.  The test is therefore whether the policies apply to the caller, not
-- whether any policy exists.
--
ALTER TABLE mvg.open ENABLE ROW LEVEL SECURITY;
CREATE POLICY mine ON mvg.open USING (who = current_user);

-- What the two of them see, so that the refusal below has something to be
-- about: the maintainer is shown two of the four rows, the owner all four.
SET ROLE regress_mvg_maint;
SELECT count(*) AS maint_sees FROM mvg.open;
SET ROLE regress_mvg_owner;
SELECT count(*) AS owner_sees FROM mvg.open;
RESET ROLE;

SELECT mvg.try('regress_mvg_maint',  '51 subject to a policy',
  $$id IN (SELECT o.id FROM mvg.open o)$$);
SELECT mvg.try('regress_mvg_bypass', '52 BYPASSRLS',
  $$id IN (SELECT o.id FROM mvg.open o)$$);
SELECT mvg.try('regress_mvg_super',  '53 superuser',
  $$id IN (SELECT o.id FROM mvg.open o)$$);
SELECT mvg.try('regress_mvg_owner',  '54 the table owner',
  $$id IN (SELECT o.id FROM mvg.open o)$$);

-- FORCEd, the owner is subject too, but they are still the matview's owner,
-- and the caller is still the one the answer would be leaked to.
ALTER TABLE mvg.open FORCE ROW LEVEL SECURITY;
SELECT mvg.try('regress_mvg_maint',  '55 FORCE, subject to a policy',
  $$id IN (SELECT o.id FROM mvg.open o)$$);
SELECT mvg.try('regress_mvg_owner',  '56 FORCE, the table owner',
  $$id IN (SELECT o.id FROM mvg.open o)$$);
ALTER TABLE mvg.open NO FORCE ROW LEVEL SECURITY;

-- Enabled on a table the caller owns, they are exempt from it themselves, so
-- there is nothing the refresh could tell them that they could not read.
ALTER TABLE mvg.theirs ENABLE ROW LEVEL SECURITY;
SELECT mvg.try('regress_mvg_maint',  '57 RLS on a table they own',
  $$id IN (SELECT t.id FROM mvg.theirs t)$$);
ALTER TABLE mvg.open DISABLE ROW LEVEL SECURITY;
ALTER TABLE mvg.theirs DISABLE ROW LEVEL SECURITY;

--
-- 6e: the matview's own columns.  MAINTAIN is what REFRESH asks for and does
-- not imply SELECT, so a caller holding only MAINTAIN could otherwise name a
-- column they cannot read and learn from the row count how many rows match.
-- The rule is the one DELETE and UPDATE state for the columns their WHERE
-- clause reads.
--
CREATE MATERIALIZED VIEW mvg.mv2 AS SELECT id, gid, who FROM mvg.open;
CREATE UNIQUE INDEX ON mvg.mv2 (id);
ALTER MATERIALIZED VIEW mvg.mv2 OWNER TO regress_mvg_owner;
GRANT MAINTAIN ON mvg.mv2 TO regress_mvg_maint;

CREATE FUNCTION mvg.try2(who text, label text, pred text) RETURNS text
  LANGUAGE plpgsql AS $$
DECLARE ctx text;
BEGIN
  EXECUTE format('SET LOCAL ROLE %I', who);
  BEGIN
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mvg.mv2 WHERE ' || pred;
    RESET ROLE;
    RETURN format('%-32s allowed', label);
  EXCEPTION WHEN others THEN
    RESET ROLE;
    GET STACKED DIAGNOSTICS ctx = PG_EXCEPTION_CONTEXT;
    RETURN format('%-32s %s: %s', label,
                  CASE WHEN ctx LIKE '%mvg.mv2 mv%' THEN 'refused when run'
                       ELSE 'refused' END,
                  SQLERRM);
  END;
END $$;

SELECT mvg.try2('regress_mvg_maint', '58 MAINTAIN, no SELECT',   $$id = 1$$);
-- A predicate that reads no column asks for nothing extra, as an unqualified
-- DELETE does not.
SELECT mvg.try2('regress_mvg_maint', '59 no column read',        $$true$$);
GRANT SELECT (id) ON mvg.mv2 TO regress_mvg_maint;
SELECT mvg.try2('regress_mvg_maint', '60 SELECT on that column', $$id = 1$$);
SELECT mvg.try2('regress_mvg_maint', '61 SELECT on another',     $$who = 'other'$$);
SELECT mvg.try2('regress_mvg_maint', '62 in a sublink',
  $$who IN (SELECT o.who FROM mvg.open o)$$);
SELECT mvg.try2('regress_mvg_maint', '63 a whole-row reference', $$mv2::text <> ''$$);
SELECT mvg.try2('regress_mvg_owner', '64 the owner, no grants',  $$who = 'other'$$);
GRANT SELECT ON mvg.mv2 TO regress_mvg_maint;
SELECT mvg.try2('regress_mvg_maint', '65 table-wide SELECT',     $$who = 'other'$$);

--
-- 6f: which comparisons the leakproof rule actually leaves a non-owner
--
-- The reference page states this envelope, and a reader will plan around it,
-- so it is pinned here rather than left to be rediscovered.  Two separate
-- reasons a comparison lands outside it, and they want different fixes:
--
--   the operator itself is not marked leakproof: numeric, jsonb, enums,
--   arrays and row values, while the integer and floating-point types, text,
--   boolean, uuid and the date and time types are;
--
--   or a cast survives into the expression, because the check runs on the
--   parsed condition and not on a simplified one.  Simplifying first would
--   mean const-folding the caller's functions with the owner's privileges,
--   which is the thing being prevented, so this is deliberate, but it means
--   a quoted literal is accepted where the same value spelled as a cast is
--   not.
--
-- If any of these operators is ever marked leakproof upstream, the
-- corresponding case flips and the reference page has to move with it.  That is
-- what this case is for.  A silent divergence between the page and the code is
-- the thing it prevents.
--
CREATE TYPE mvg.stat AS ENUM ('open', 'closed');
CREATE TABLE mvg.types (id int PRIMARY KEY, n bigint, d float8, amt numeric,
                        st mvg.stat, tags text[], doc jsonb, s text);
INSERT INTO mvg.types
  VALUES (1, 1, 1.5, 10.5, 'open', ARRAY['a'], '{"k": 1}', 'x');
ALTER TABLE mvg.types OWNER TO regress_mvg_owner;
ALTER TYPE mvg.stat OWNER TO regress_mvg_owner;
GRANT SELECT ON mvg.types TO regress_mvg_maint;

SELECT mvg.try('regress_mvg_maint', '66 integer, bigint, float8',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.id = 1 AND t.n > 0 AND t.d > 1)$$);
SELECT mvg.try('regress_mvg_maint', '67 text',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.s = 'x')$$);
SELECT mvg.try('regress_mvg_maint', '68 numeric',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.amt > '1')$$);
SELECT mvg.try('regress_mvg_maint', '69 an enumerated type',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.st = 'open')$$);
SELECT mvg.try('regress_mvg_maint', '70 an array',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.tags = ARRAY['a'])$$);
SELECT mvg.try('regress_mvg_maint', '71 jsonb',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.doc = '{"k": 1}')$$);
-- the same value, quoted and cast
SELECT mvg.try('regress_mvg_maint', '72 a quoted literal',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.d > '1.0')$$);
SELECT mvg.try('regress_mvg_maint', '73 the same value, cast',
  $$id IN (SELECT t.id FROM mvg.types t WHERE t.d > 1.0::float8)$$);
-- a constant, not a call, so it is reached
SELECT mvg.try('regress_mvg_maint', '74 CURRENT_TIMESTAMP',
  $$id IN (SELECT t.id FROM mvg.types t WHERE CURRENT_TIMESTAMP > '2000-01-01')$$);
SELECT mvg.try('regress_mvg_maint', '75 now()',
  $$id IN (SELECT t.id FROM mvg.types t WHERE now() > '2000-01-01')$$);

DROP TABLE mvg.types;
DROP TYPE mvg.stat;
DROP MATERIALIZED VIEW mvg.mv2;
DROP MATERIALIZED VIEW mvg.mv;
DROP VIEW mvg.v_invoker;
DROP VIEW mvg.v_plain;
DROP FUNCTION mvg.read_closed();
DROP FUNCTION mvg.try2(text, text, text);
DROP FUNCTION mvg.try(text, text, text);
DROP TABLE mvg.theirs;
DROP TABLE mvg.cols;
DROP TABLE mvg.closed;
DROP TABLE mvg.open;
DROP SCHEMA mvg;
DROP ROLE regress_mvg_owner;
DROP ROLE regress_mvg_maint;
DROP ROLE regress_mvg_bypass;
DROP ROLE regress_mvg_super;

--
-- Test 7: the duplicate-key refusal names the key only for the owner
--
-- Found here.  refresh_by_match_merge()'s duplicate error prints the offending
-- row, and says why it may: "REFRESH MAT VIEW is only able to be run by the
-- owner of the mat view (or a superuser) and therefore there is no need to
-- check for access to data in the mat view."  That has not been true since
-- MAINTAIN was added, and a partial refresh is the path a MAINTAIN-only caller
-- is most likely to be on, so its own version of the error asks first.
--
-- Reaching the check without SELECT takes a predicate that reads no column of
-- the matview, since one that does is refused earlier by Test 6's column rule.
-- WHERE true is that predicate, and it is also the one a caller would reach
-- for if they were fishing.
--
-- The interesting half is the caller who gets no key.  Nothing else in the
-- suite covers an error message that has to be redacted.
--

CREATE ROLE regress_mvd_owner;
CREATE ROLE regress_mvd_maint;
CREATE SCHEMA mvd;
GRANT USAGE ON SCHEMA mvd TO regress_mvd_owner, regress_mvd_maint;

CREATE TABLE mvd.base (a text, b text);
INSERT INTO mvd.base VALUES ('visible', 'unreadable');
CREATE MATERIALIZED VIEW mvd.mv AS SELECT a, b FROM mvd.base;
CREATE UNIQUE INDEX ON mvd.mv (a);
ALTER TABLE mvd.base OWNER TO regress_mvd_owner;
ALTER MATERIALIZED VIEW mvd.mv OWNER TO regress_mvd_owner;
-- MAINTAIN and nothing else.  No SELECT on the matview or on the base table.
GRANT MAINTAIN ON mvd.mv TO regress_mvd_maint;

-- Make the source ambiguous.
INSERT INTO mvd.base VALUES ('visible', 'unreadable');

SET ROLE regress_mvd_maint;
-- Control: they cannot read either relation.
SELECT count(*) FROM mvd.mv;
SELECT count(*) FROM mvd.base;
-- Refused, and the key is withheld.
REFRESH MATERIALIZED VIEW CONCURRENTLY mvd.mv WHERE true;
RESET ROLE;

-- The owner gets the key, which is the point of reporting it at all.
SET ROLE regress_mvd_owner;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvd.mv WHERE true;
RESET ROLE;

DROP MATERIALIZED VIEW mvd.mv;
DROP TABLE mvd.base;
DROP SCHEMA mvd;
DROP ROLE regress_mvd_owner;
DROP ROLE regress_mvd_maint;
