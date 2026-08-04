--
-- REFRESH MATERIALIZED VIEW ... WHERE ... : session plan cache
--
-- refresh_by_direct_modification() caches the two SPI plans it builds (the
-- row-locking SELECT and the fused upsert/delete CTE) in a session-level hash
-- table keyed on the matview OID.  An entry is reused when the arbiter index
-- OID, the predicate and the parameter types all match.
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
-- qualify.  They say CONCURRENTLY because that is how they were written; it no
-- longer decides anything.
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
UPDATE mv_c4_base SET v = 102 WHERE id = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 2;
SELECT * FROM mv_c4 ORDER BY id;

-- And again on the same warmed entry, so this asserts more than the first call
-- after a cold cache.
UPDATE mv_c4_base SET v = 103 WHERE id = 3;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 3;
SELECT * FROM mv_c4 ORDER BY id;

-- Before the fix this reported "cannot change materialized view mv_c4_inner"
-- from a refresh of mv_c4: the enclosing refresh had picked up the nested one's
-- plan out of the reused entry.
UPDATE mv_c4_base SET v = 104 WHERE id = 4;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 4;
SELECT * FROM mv_c4 ORDER BY id;

UPDATE mv_c4_base SET v = 105 WHERE id = 5;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c4 WHERE id = 5;
SELECT * FROM mv_c4 ORDER BY id;

-- The nested refresh never committed anything, and must not have: it failed at
-- the locking step every time.
SELECT * FROM mv_c4_inner ORDER BY id;

DROP MATERIALIZED VIEW mv_c4;
DROP MATERIALIZED VIEW mv_c4_inner;
DROP FUNCTION mv_c4_nested(int);
DROP TABLE mv_c4_base;
DROP TABLE mv_c4_inner_base;

--
-- Test 6: The predicate itself is part of the cache key
--
-- Tests 1 to 4 all cover ways the key can be right and the plans still wrong --
-- a rename underneath it, a parameter type it cannot see.  None of them covers
-- the key simply not looking at the predicate, and that is the thing it is for:
-- two different predicates on one matview must not share plans.
--
-- Found by mutation, not by reading: dropping the predicate from the comparison
-- outright left every gate in the tree green, because nothing anywhere
-- refreshed one matview through two different predicates in one session.
--
-- The two predicates are chosen so a confusion is not merely visible but
-- inverted.  Both carry a single int4 constant, so the argument types match and
-- the key's other terms cannot do this one's job; and grp = 3 names rows 1 and
-- 2 while the warmed plan, id = $1 executed with 3, names row 3.  So the wrong
-- answer refreshes exactly the rows the right one leaves alone, which no
-- rounding of "it did nothing" can produce.
--
-- No DDL may run between the two refreshes.  InvalidateMatViewCache() ignores
-- the relid it is passed and marks every entry, so any relcache invalidation
-- the session receives discards the entry this case exists to reuse -- and then
-- the plans are rebuilt correctly by accident, the case goes green, and it
-- detects nothing.  A refresh of the matview is not such an event, which is
-- worth stating because it is the obvious guess and it is wrong: verified under
-- C7, the entry survived a refresh that rewrote every row in scope.  That
-- agrees with B16 -- SetMatViewPopulatedState() early-returns when the state
-- already matches, so a partial refresh emits no invalidation of its own.
--
-- Verified as a detector: under C7 rows 1 and 2 keep their pre-update values
-- and row 3 is the one that moves.
--
-- Disposition: keep.  It asserts that a refresh acts on the rows its own
-- predicate names, which holds however the plans are or are not cached, and
-- says nothing about how the key is built.
--

CREATE TABLE mv_c6_base (id int primary key, grp int, v text);
INSERT INTO mv_c6_base VALUES (1, 3, 'a'), (2, 3, 'b'), (3, 9, 'c');

CREATE MATERIALIZED VIEW mv_c6 AS SELECT id, grp, v FROM mv_c6_base;
CREATE UNIQUE INDEX ON mv_c6(id);

-- Warm the entry with a predicate on the key column.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c6 WHERE id = 1;

UPDATE mv_c6_base SET v = v || '-new';

-- A different predicate, on a different column, with the same argument types.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c6 WHERE grp = 3;

-- Rows 1 and 2 are the ones grp = 3 names, so they are the ones that refresh;
-- row 3 keeps its stale value.
SELECT * FROM mv_c6 ORDER BY id;

DROP MATERIALIZED VIEW mv_c6;
DROP TABLE mv_c6_base;

--
-- Test 7: Cached plans whose text names a renamed object are not reused
--
-- The key is the predicate's parse tree, and a tree names a function by OID, so
-- renaming that function leaves the tree equal() to the cached one and the
-- entry is reused.  The two SPI statements built from it are still text, and
-- that text spells the old name.  plancache invalidates them -- it registers a
-- syscache callback on pg_proc, which this cache does not -- and re-analyses
-- the text, binding the old name to whatever holds it now.
--
-- The result is that the source query and the DML disagree about which rows the
-- predicate selects: the source runs from the tree, the pre-lock and the prune
-- from the stale text.  The prune then deletes rows that are in scope according
-- to the text and absent from new_data according to the tree.
--
-- Found by asking whether ISSUES.md B2 was still reachable once the view
-- definition stopped being text.  It was, by a route B2 did not describe, and
-- the deparse elision is what opened it: while the deparsed predicate was the
-- cache key, a rename changed the key and forced a rebuild.  Keying on the tree
-- removed that protection along with the deparse.
--
-- Seen to fail two ways before the fix.  With a replacement function holding
-- the old name, row 3 was deleted from the matview while the base still
-- produced it and the predicate never named it -- silent data loss.  With no
-- replacement, the refresh raised "function public.mv_c7_pred(integer) does not
-- exist" from a statement the caller never wrote.
--
-- The fix is ri_FetchPreparedPlan()'s: let plancache be the detector, and
-- rebuild the text ourselves when it says the plan is stale.
--
-- Disposition: keep.  It asserts that a refresh acts on the rows its predicate
-- names, which holds however the plans are or are not cached.
--

CREATE TABLE mv_c7_base (id int primary key, v int);
INSERT INTO mv_c7_base SELECT g, 0 FROM generate_series(1, 5) g;

CREATE MATERIALIZED VIEW mv_c7 AS SELECT id, v FROM mv_c7_base;
CREATE UNIQUE INDEX ON mv_c7(id);

CREATE FUNCTION mv_c7_pred(int) RETURNS boolean LANGUAGE sql STABLE
  AS 'SELECT $1 <= 2';

UPDATE mv_c7_base SET v = 1;

-- Warm the entry.  Schema-qualified because REFRESH runs under a restricted
-- search_path.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c7 WHERE public.mv_c7_pred(id);
SELECT * FROM mv_c7 ORDER BY id;

-- Rename the predicate's function and give a different one the old name.  This
-- emits no relcache invalidation, so the cache entry survives -- which is what
-- makes the case reach the stale text rather than a rebuilt plan.
ALTER FUNCTION mv_c7_pred(int) RENAME TO mv_c7_pred2;
CREATE FUNCTION mv_c7_pred(int) RETURNS boolean LANGUAGE sql STABLE
  AS 'SELECT $1 = 3';

UPDATE mv_c7_base SET v = 2;

-- The same function as the warm call, under its new name.  Rows 1 and 2 must
-- move; row 3 must be left alone and must still be there.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c7 WHERE public.mv_c7_pred2(id);
SELECT * FROM mv_c7 ORDER BY id;

DROP MATERIALIZED VIEW mv_c7;
DROP TABLE mv_c7_base;
DROP FUNCTION mv_c7_pred(int);
DROP FUNCTION mv_c7_pred2(int);
