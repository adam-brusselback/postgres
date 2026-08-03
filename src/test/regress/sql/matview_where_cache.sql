--
-- REFRESH MATERIALIZED VIEW ... WHERE ... : session plan cache
--
-- refresh_by_direct_modification() caches the two SPI plans it builds (the
-- row-locking SELECT and the fused upsert/delete CTE) in a session-level hash
-- table keyed on the matview OID.  An entry is reused when the arbiter index
-- OID and the deparsed WHERE clause text both match.
--
-- These tests all depend on cache state accumulated over the session, so they
-- live in their own file to keep that state predictable, and they must run in
-- the order written.
--
-- What is load-bearing is that every case reaches
-- refresh_by_direct_modification(), the one path that caches anything -- and
-- what selects it has changed twice.  It is now the number of unique indexes:
-- a predicate on a matview with one takes direct modification whichever way the
-- command is spelled.  Every matview below has exactly one, so all of them
-- qualify.  Tests 1 to 5 say CONCURRENTLY because that is how they were
-- written; it no longer decides anything, and Test 6 does not bother.
--
-- It did decide once, and how that went wrong is the reason for this
-- paragraph.  These tests predate commit 0607847, which swapped which spelling
-- took which path, and they were not updated with it -- so for a while every
-- one of them ran against refresh_by_match_merge(), which caches no plans.
-- They asserted that a cached plan is invalidated correctly, against a code
-- path with no cache in it, and they passed, because there was nothing there
-- to break.  A test that cannot fail is not a guard.
--
-- None of the cases in this file were reported on -hackers; the plan cache had
-- not come up in the thread "[Patch] Add WHERE clause support to REFRESH
-- MATERIALIZED VIEW" at all.  They were found by reviewing the cache against
-- the plancache contract.
--
-- Every case here covered a live defect when it was written.  The expected
-- output has always described what the command should do, so each failed until
-- its defect was fixed; all of them are now fixed and the file is green.  Where
-- the pre-fix behaviour is worth knowing -- because it says what the test is
-- for -- the comment on the case says what used to happen.
--
-- Disposition: Tests 1 to 3 -- DELETE if the plan cache goes away.  All three
-- exist only because plans are cached across statements and revalidated by
-- re-analyzing a raw parse tree; drop the cache and they assert nothing.  If the
-- cache stays and gains proper invalidation, keep them as guards for it.
--
-- Disposition: Test 4 -- keep.  It asserts that a refresh acts on the rows its
-- predicate identifies, which holds however the plan is or is not cached.
--

--
-- Test 1: Renaming the materialized view
--
-- SPI_keepplan() saves the plan together with its raw parse tree.  When the
-- plan is invalidated it is re-analyzed from that raw tree, which resolves the
-- relation by name.  Renaming the matview does not change its OID, so the
-- cache entry is still considered valid, but the SQL inside it is not.
--

CREATE TABLE mv_c_base (id int primary key, v text);
INSERT INTO mv_c_base VALUES (1, 'one'), (2, 'two');

CREATE MATERIALIZED VIEW mv_c AS SELECT id, v FROM mv_c_base;
CREATE UNIQUE INDEX ON mv_c(id);

-- Warm the cache for this matview and this predicate.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c WHERE id = 1;

ALTER MATERIALIZED VIEW mv_c RENAME TO mv_c_renamed;
UPDATE mv_c_base SET v = 'one-updated' WHERE id = 1;

-- Must succeed and pick up the new value.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c_renamed WHERE id = 1;
SELECT * FROM mv_c_renamed ORDER BY id;

--
-- Test 2: Another relation taking over the old name
--
-- Worse than an error: once something else occupies the name the cached plan
-- referred to, re-analysis silently resolves to that other relation.
--

CREATE TABLE mv_c_decoy_base (id int primary key, v text);
INSERT INTO mv_c_decoy_base VALUES (1, 'decoy-one'), (2, 'decoy-two');

-- This matview now owns the name "mv_c" that the cached plan refers to.
CREATE MATERIALIZED VIEW mv_c AS SELECT id, v FROM mv_c_decoy_base;
CREATE UNIQUE INDEX ON mv_c(id);

-- Refresh the *original* matview, by its current name.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c_renamed WHERE id = 1;

-- The matview that was named is the one that moved.
SELECT * FROM mv_c_renamed ORDER BY id;

-- ... and this one, which merely took over the name, is untouched.  Before the
-- fix the refresh wrote here instead, having taken no lock and no MAINTAIN
-- privilege check on it.
SELECT * FROM mv_c ORDER BY id;

DROP MATERIALIZED VIEW mv_c;
DROP TABLE mv_c_decoy_base;
DROP MATERIALIZED VIEW mv_c_renamed;
DROP TABLE mv_c_base;

--
-- Test 3: Renaming a base table
--
-- The cached refresh plan embeds pg_get_viewdef() output, so the same
-- re-analysis hazard applies to every relation the view definition names.
--

CREATE TABLE mv_c2_base (id int primary key, v text);
INSERT INTO mv_c2_base VALUES (1, 'real');

CREATE MATERIALIZED VIEW mv_c2 AS SELECT id, v FROM mv_c2_base;
CREATE UNIQUE INDEX ON mv_c2(id);

-- Warm the cache.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c2 WHERE id = 1;

ALTER TABLE mv_c2_base RENAME TO mv_c2_base_old;
CREATE TABLE mv_c2_base (id int primary key, v text);
INSERT INTO mv_c2_base VALUES (1, 'decoy');

-- mv_c2 is still defined over mv_c2_base_old.
SELECT pg_get_viewdef('mv_c2'::pg_catalog.regclass);

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c2 WHERE id = 1;

-- Filled from the table the view definition names, not from the one that took
-- over its name.
SELECT * FROM mv_c2 ORDER BY id;

DROP MATERIALIZED VIEW mv_c2;
DROP TABLE mv_c2_base;
DROP TABLE mv_c2_base_old;

--
-- Test 4: Parameter types are not part of the cache key
--
-- pg_get_expr() renders an external parameter as "$1" with no type
-- information, so predicates that differ only in parameter type deparse
-- identically and share a cache entry.  The saved plan keeps the argument
-- types it was first prepared with.
--

CREATE TABLE mv_c3_base (id bigint primary key, v text);
INSERT INTO mv_c3_base VALUES (1, 'orig-small'), (4294967297, 'orig-large');

CREATE MATERIALIZED VIEW mv_c3 AS SELECT id, v FROM mv_c3_base;
CREATE UNIQUE INDEX ON mv_c3(id);

SELECT * FROM mv_c3 ORDER BY id;

-- Warm the cache with an int4 parameter.
DO $$ BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c3 WHERE id = $1' USING 1::int;
END $$;

UPDATE mv_c3_base SET v = 'new-small' WHERE id = 1;
UPDATE mv_c3_base SET v = 'new-large' WHERE id = 4294967297;

-- Same deparsed predicate, but an int8 parameter.  4294967297 has 1 in its low
-- 32 bits, so a plan expecting int4 reads the argument as 1.
DO $$ BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c3 WHERE id = $1' USING 4294967297::bigint;
END $$;

-- id = 4294967297 is the row that moved; id = 1 is untouched.  Before the fix
-- the int8 argument was read through a plan expecting int4 and the low 32 bits
-- selected row 1.
SELECT * FROM mv_c3 ORDER BY id;

-- Reset to a known state with a full refresh, which takes neither the partial
-- path nor its cache, then confirm the fix holds for a second call on the same
-- warmed entry rather than only for the first one after it.
REFRESH MATERIALIZED VIEW mv_c3;
UPDATE mv_c3_base SET v = 'concurrent-large' WHERE id = 4294967297;
DO $$ BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c3 WHERE id = $1'
    USING 4294967297::bigint;
END $$;
SELECT * FROM mv_c3 ORDER BY id;

DROP MATERIALIZED VIEW mv_c3;
DROP TABLE mv_c3_base;

--
-- Test 5: A nested partial refresh must not free the enclosing one's plans
--
-- The predicate and the view definition are both evaluated inside the outer
-- refresh's maintenance window, so a function in either can issue REFRESH
-- MATERIALIZED VIEW ... WHERE.  That nested call used to reach the same
-- session cache the enclosing refresh was executing from, and free out of it:
--
-- matview_cache_sweep() frees every entry the relcache callback marked stale,
-- and the callback marks all of them because it ignores its relid argument.
-- The sweep was placed before the entry lookup on the reasoning that "nothing
-- removes entries until the next refresh" -- but a nested refresh IS the next
-- refresh, and it runs while the enclosing one holds a pointer into its entry
-- and is executing a plan out of it.
--
-- Nothing protected against that.  SPI_freeplan() deletes the _SPI_plan's own
-- context, which holds the plancache_list that _SPI_execute_plan is walking, so
-- the CachedPlan refcount is not the relevant lifetime.  Observed on an
-- assertions build as the enclosing refresh executing the nested matview's plan
-- (what this test catches, because dynahash hands the removed element straight
-- back to the nested HASH_ENTER), as an error context printing a freed query
-- string, and as a SIGSEGV.
--
-- The nested refresh has to be of a *different* matview.  CheckTableNotInUse()
-- rejects one of the same matview -- "because it is being used by active
-- queries in this session" -- before any of this code runs, which is also why
-- the other free site in refresh_by_direct_modification(), the arbiter/
-- predicate mismatch branch, is not a second way in: it only ever frees plans
-- under the OID its own caller passed, and that OID cannot be an enclosing
-- refresh's.
--
-- The fix is upstream of the sweep: a refresh at maintenance depth > 0 prepares
-- private plans and touches neither the hash table nor the entries in it.
--

CREATE TABLE mv_c4_base (id int primary key, v int);
CREATE TABLE mv_c4_inner_base (id int primary key, v int);
INSERT INTO mv_c4_base SELECT g, g FROM generate_series(1, 5) g;
INSERT INTO mv_c4_inner_base SELECT g, g FROM generate_series(1, 5) g;

CREATE MATERIALIZED VIEW mv_c4_inner AS SELECT id, v FROM mv_c4_inner_base;
CREATE UNIQUE INDEX ON mv_c4_inner(id);

-- Called from the outer view definition, so it runs inside the outer refresh's
-- maintenance window.
--
-- The ALTER TABLE is what makes the sweep bite: it emits a relcache
-- invalidation, the callback marks every entry stale including the enclosing
-- refresh's, and the nested refresh's sweep then frees it.  The nested refresh
-- itself cannot succeed -- rows in a second matview cannot be locked while the
-- first is being maintained -- but it fails at the locking step, well after the
-- sweep has run.  Reaching the free site does not require the nested refresh to
-- work, only to start.  The trap keeps this test about the cache rather than
-- about that restriction.
--
-- Both names are schema-qualified, and that is load-bearing rather than
-- stylistic: REFRESH runs its query under RestrictSearchPath(), so an
-- unqualified name here does not resolve, the ALTER TABLE raises instead, the
-- trap swallows it and the nested refresh never runs at all.  Written that way
-- first, this test passed against the unfixed code.
CREATE FUNCTION mv_c4_nested(x int) RETURNS int LANGUAGE plpgsql VOLATILE AS $$
BEGIN
  BEGIN
    ALTER TABLE public.mv_c4_inner_base SET (autovacuum_enabled = true);
    REFRESH MATERIALIZED VIEW CONCURRENTLY public.mv_c4_inner WHERE id = 1;
  EXCEPTION WHEN OTHERS THEN
    NULL;
  END;
  RETURN x;
END $$;

CREATE MATERIALIZED VIEW mv_c4 AS SELECT id, mv_c4_nested(v) AS v FROM mv_c4_base;
CREATE UNIQUE INDEX ON mv_c4(id);

SELECT * FROM mv_c4 ORDER BY id;

-- Both refresh paths are exercised, but only one of them is the guard, and
-- saying which is the point of this comment.  Against the unfixed code the
-- Query-tree arm below fails deterministically and the classic arm passes: the
-- free happens on both, but the classic path hands SPI its plan pointer once
-- and never re-reads cacheEntry, so the freed plan keeps executing and the
-- damage surfaces as a garbage query_string or a crash -- neither of which can
-- be written into an expected file.  The classic arm is coverage of the nested
-- path, not a detector.  If the cache stops being reused across nested
-- refreshes, this test stops asserting anything and needs rebuilding, not
-- deleting.
--
-- Without the row comparison, so the upsert rewrites every matched row.
SET matview_partial_refresh_optimized = off;
UPDATE mv_c4_base SET v = 102 WHERE id = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 2;
SELECT * FROM mv_c4 ORDER BY id;

-- And again on the same warmed entry, so this asserts more than the first call
-- after a cold cache.
UPDATE mv_c4_base SET v = 103 WHERE id = 3;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 3;
SELECT * FROM mv_c4 ORDER BY id;

-- And with it.  Before the fix this reported "cannot change materialized view
-- mv_c4_inner" from a refresh of mv_c4: the enclosing refresh had picked up the
-- nested one's plan out of the reused entry.
UPDATE mv_c4_base SET v = 104 WHERE id = 4;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 4;
SELECT * FROM mv_c4 ORDER BY id;

UPDATE mv_c4_base SET v = 105 WHERE id = 5;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 5;
SELECT * FROM mv_c4 ORDER BY id;

RESET matview_partial_refresh_optimized;

-- The nested refresh never committed anything, and must not have: it failed at
-- the locking step every time.
SELECT * FROM mv_c4_inner ORDER BY id;

DROP MATERIALIZED VIEW mv_c4;
DROP MATERIALIZED VIEW mv_c4_inner;
DROP FUNCTION mv_c4_nested(int);
DROP TABLE mv_c4_base;
DROP TABLE mv_c4_inner_base;

--
-- Test 6: What changes the generated statement is part of the cache key
--
-- The entry is reused when the arbiter index, the deparsed predicate and the
-- argument types all match.  None of those describes the statement the plans
-- were built from, and matview_partial_refresh_optimized changes it: it decides
-- whether the upsert carries the row comparison that lets it skip a row nothing
-- changed about.  So it is in the key.
--
-- Without them a plan prepared under one setting is reused under the other for
-- the rest of the session, and reused silently: the stale plan is still valid
-- SQL that refreshes exactly the right rows.  The only difference is which row
-- versions it writes, so nothing reading the matview's contents can see it.
-- This asks the heap instead.  Measured rather than supposed -- calibrate-all.sh
-- reported O2, the optimisation flag dropped from the key, UNCAUGHT by all four
-- instruments.
--
-- No DDL may run between the two refreshes.  InvalidateMatViewCache() ignores
-- the relid it is passed and marks every entry, so any relcache invalidation
-- the session receives discards the entry this case exists to reuse -- and then
-- the plan is rebuilt for the right reason by accident, the case goes green,
-- and it detects nothing.  Creating the snapshot table between the refreshes is
-- exactly that mistake, and is why it is filled first.
--
-- A refresh of the matview is not such an event, which is worth stating because
-- it is the obvious guess and it is wrong: verified under this mutation with
-- only DML and a SET in between, the entry survived a refresh that rewrote
-- every row in scope and the stale plan was still reused.  That agrees with
-- B16 -- SetMatViewPopulatedState() early-returns when the state already
-- matches, so a partial refresh emits no invalidation of its own.
--
-- Verified as a detector rather than assumed: under O2 all three rows come
-- back t.
--
-- Disposition: DELETE with the remaining developer GUC, as part of the Phase 4
-- removal -- unless the cache has by then acquired another input that changes
-- the generated SQL.  If it has, rewrite this around that instead of deleting
-- it: the rule outlives the flag that illustrates it.
--

SET matview_partial_refresh_optimized = on;

CREATE TABLE mv_c5_base (id int primary key, v int);
INSERT INTO mv_c5_base SELECT g, g * 10 FROM generate_series(1, 3) g;

CREATE MATERIALIZED VIEW mv_c5 AS SELECT id, v FROM mv_c5_base;
CREATE UNIQUE INDEX ON mv_c5(id);

-- Filled before either refresh: see above.
CREATE TEMP TABLE mv_c5_was AS SELECT id, ctid AS was FROM mv_c5;

-- Warm the entry.  Nothing has changed since the matview was built, so with the
-- optimisation on this refresh writes nothing.
REFRESH MATERIALIZED VIEW mv_c5 WHERE id BETWEEN 1 AND 3;

-- Same matview, same predicate, same argument types, same arbiter index.  Only
-- the statement the plans should be built from is different now.
SET matview_partial_refresh_optimized = off;

-- So this must build new plans, and they rewrite all three rows because the
-- DO UPDATE no longer has a comparison to skip on.  Reusing the warmed plan
-- writes nothing at all.
REFRESH MATERIALIZED VIEW mv_c5 WHERE id BETWEEN 1 AND 3;

SELECT w.id, (w.was = m.ctid) AS same_row_version
  FROM mv_c5_was w JOIN mv_c5 m USING (id) ORDER BY w.id;

DROP TABLE mv_c5_was;
DROP MATERIALIZED VIEW mv_c5;
DROP TABLE mv_c5_base;

RESET matview_partial_refresh_optimized;
