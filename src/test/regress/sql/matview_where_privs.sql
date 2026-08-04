--
-- REFRESH MATERIALIZED VIEW ... WHERE ... : privileges and session state
--
-- These tests exercise the security boundary of the WHERE clause and the
-- session-level matview maintenance flag.  Each one says whether it came from
-- the -hackers thread "[Patch] Add WHERE clause support to REFRESH MATERIALIZED
-- VIEW" or was found separately, so that review items can be checked off
-- against it.
--
-- Every case covers a live defect.  The expected output describes what the
-- command should do, so they fail until the defect is fixed.  All of them are
-- now fixed; where the pre-fix behaviour says what the test is for, the comment
-- on the case records it.
--
-- Where the correct outcome is "the statement is rejected", the statement is
-- wrapped in a block that reports the SQLSTATE instead of letting the message
-- text through.  The fix that produces the rejection has not been written yet,
-- so its wording is not knowable here; the SQLSTATE that a correct rejection
-- must carry is.
--
-- Disposition: keep, all of them.  These are security regressions, and the
-- classes they cover -- a caller reaching objects through a predicate it could
-- not reach directly, a predicate modifying a matview, and an error leaving the
-- maintenance flag raised -- are all easy to reintroduce.  They should stay in
-- the tree after the fixes land.
--
-- One qualification, for Test 1 specifically.  It asserts the RULE -- a
-- non-leakproof predicate requires ownership -- rather than the property the
-- rule exists to deliver, which is that a predicate cannot read across a
-- privilege boundary.  The rule is needed because SPI runs the whole statement
-- under one userid, so the predicate necessarily runs as the owner.
--
-- If the Query-tree work lets the predicate be evaluated as the invoker, the
-- leak stops being possible instead of being forbidden, and the right expected
-- output for this test becomes "succeeds".  At that point the test does not
-- merely stop applying, it INVERTS: it would report a strictly better
-- implementation as a security regression.  Rewrite it then to assert that the
-- leak cannot happen rather than that the rejection does -- do not simply
-- regenerate the expected output, which would silently retire the check.
--
-- Test 4 used to leave the session unable to protect any matview from direct
-- DML, so nothing could follow it.  That was the defect it exists to catch;
-- with the flag restored on error, the ordering constraint is gone with it.
--

--
-- Test 1: The predicate must not run with the matview owner's privileges
--
-- Reported on -hackers by Zsolt Parragi: "The patch in its current form has a
-- security escalation bug, WHERE functions are executed with the privileges of
-- the owner, not the maintainer."  Acknowledged by Adam Brusselback, who
-- proposed allowing MAINTAIN callers only when every function in the predicate
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
GRANT MAINTAIN ON matview_priv_mv TO regress_matview_maint;

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
-- Not reported on -hackers.  Related to Zsolt Parragi's escalation report
-- above, but distinct from it and not covered by the leakproof gating proposed
-- in reply: the predicate runs not only as the owner but with matview write
-- protection switched off, which is exposure the full and concurrent refresh
-- paths do not have, since the statements they run inside that window contain
-- no user-supplied expressions.
--
-- OpenMatViewIncrementalMaintenance() is called before the SPI statements that
-- evaluate the predicate, so a predicate function is exempt from the "cannot
-- change materialized view" check -- and that exemption is global, not scoped
-- to the matview being refreshed.
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
-- Not reported on -hackers.  Found by auditing the gate added in reply to
-- Zsolt Parragi's report above: that gate refuses a predicate whose functions
-- are not all leakproof, but it was written as a walker that flagged known-bad
-- FUNCTIONS and let through every node type it did not recognise.
--
-- Leakproofness is the wrong question for a subquery rather than a question
-- answered wrongly.  It constrains what a function may reveal about its
-- arguments; it says nothing about which RELATIONS an expression may read.  A
-- sublink reads relations as the matview owner, so a caller holding only
-- MAINTAIN could read anything the owner could -- and then learn the value by
-- observing which row the refresh touched.  Every sublink spelling reached it,
-- and so did a cast to a domain whose CHECK constraint calls a non-leakproof
-- function, because that function never appears in the expression tree.
--
-- The gate is now modelled on contain_leaked_vars_walker() in clauses.c, which
-- solves the same problem for row-level security: an explicit list of node
-- types that cannot reach a relation, and everything else refused.
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
-- Reported on -hackers by Zsolt Parragi: "There's also another issue where an
-- error during refresh removes the modification restrictions."  Diagnosed by
-- Adam Brusselback as "a missing PG_TRY around the
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
-- Test 5: a subquery in the predicate is owner-only
--
-- Found here, not on the -hackers thread.  This is a consequence of Test 1's
-- rule rather than a separate decision, and it is recorded separately because
-- of what it costs: naming the correct scope for a change to a dimension table
-- requires asking the fact table which rows joined to it, which is a subquery,
-- and that is the pattern the documentation's blast-radius warning tells people
-- to write.  So the documented correct usage is available to the owner and to
-- nobody else.
--
-- The mechanism is that the leakproof gate walks the predicate over an allowed
-- list of node tags and refuses everything else (Test 3), and SubLink is not on
-- that list.  Refusing is the safe default and it is not obviously wrong: the
-- subquery runs as the owner, so a caller who cannot read the table it names
-- would otherwise learn which of its rows intersect the matview.  But it is
-- indiscriminate -- it refuses the subquery whether or not the caller could
-- have run it themselves.
--
-- Note also what the message says.  There is no function anywhere in these
-- predicates, and the hint still blames one.
--
-- Disposition: keep.  If the rule is ever narrowed to "the caller may read
-- everything the subquery reads", these cases are what says so: the first two
-- would start succeeding and the last must not.
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
GRANT MAINTAIN ON mvsq.mv TO regress_mvsq_maint;
-- The maintainer may read the fact and dimension tables, and not the secret.
GRANT SELECT ON mvsq.fact, mvsq.dim TO regress_mvsq_maint;

UPDATE mvsq.dim SET nm = 'ONE' WHERE id = 1;

-- Control: a plain column predicate is available to MAINTAIN, as Test 1 says.
SET ROLE regress_mvsq_maint;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv WHERE id = 3;

-- Refused, though the maintainer has SELECT on every table the subquery names
-- and could run it themselves.
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE id IN (SELECT f.id FROM mvsq.fact f WHERE f.did = 1);

-- Refused, correlated form of the same thing.
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE EXISTS (SELECT 1 FROM mvsq.fact f WHERE f.id = mvsq.mv.id AND f.did = 1);

-- Refused, and this one must stay refused however the rule is narrowed: the
-- maintainer cannot read mvsq.secret, so the answer would tell them which of
-- its rows exist.
SELECT count(*) FROM mvsq.secret;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE id IN (SELECT s.id FROM mvsq.secret s);
RESET ROLE;

-- The owner may use all three.
SET ROLE regress_mvsq_owner;
REFRESH MATERIALIZED VIEW CONCURRENTLY mvsq.mv
  WHERE EXISTS (SELECT 1 FROM mvsq.fact f WHERE f.id = mvsq.mv.id AND f.did = 1);
RESET ROLE;
SELECT id, did, nm FROM mvsq.mv ORDER BY id;

DROP MATERIALIZED VIEW mvsq.mv;
DROP TABLE mvsq.secret;
DROP TABLE mvsq.fact;
DROP TABLE mvsq.dim;
DROP SCHEMA mvsq;
DROP ROLE regress_mvsq_owner;
DROP ROLE regress_mvsq_maint;
