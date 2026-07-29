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
REFRESH MATERIALIZED VIEW mv_c WHERE id = 1;

ALTER MATERIALIZED VIEW mv_c RENAME TO mv_c_renamed;
UPDATE mv_c_base SET v = 'one-updated' WHERE id = 1;

-- XXX BUG: the cached plan still names the pre-rename relation.
\set VERBOSITY terse
REFRESH MATERIALIZED VIEW mv_c_renamed WHERE id = 1;
\set VERBOSITY default

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
REFRESH MATERIALIZED VIEW mv_c_renamed WHERE id = 1;

-- XXX BUG: the refresh reported success but did nothing here.  Expected
-- (1, one-updated).
SELECT * FROM mv_c_renamed ORDER BY id;

-- XXX BUG: ... and wrote to this unrelated matview instead, with data drawn
-- from the other matview's base table.  Expected (1, decoy-one).
-- Note that no lock and no MAINTAIN privilege check was ever taken on mv_c.
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
REFRESH MATERIALIZED VIEW mv_c2 WHERE id = 1;

ALTER TABLE mv_c2_base RENAME TO mv_c2_base_old;
CREATE TABLE mv_c2_base (id int primary key, v text);
INSERT INTO mv_c2_base VALUES (1, 'decoy');

-- mv_c2 is still defined over mv_c2_base_old.
SELECT pg_get_viewdef('mv_c2'::pg_catalog.regclass);

REFRESH MATERIALIZED VIEW mv_c2 WHERE id = 1;

-- XXX BUG: filled from the decoy table.  Expected (1, real).
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
  EXECUTE 'REFRESH MATERIALIZED VIEW mv_c3 WHERE id = $1' USING 1::int;
END $$;

UPDATE mv_c3_base SET v = 'new-small' WHERE id = 1;
UPDATE mv_c3_base SET v = 'new-large' WHERE id = 4294967297;

-- Same deparsed predicate, but an int8 parameter.  4294967297 has 1 in its low
-- 32 bits, so a plan expecting int4 reads the argument as 1.
DO $$ BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW mv_c3 WHERE id = $1' USING 4294967297::bigint;
END $$;

-- XXX BUG: id = 1 was refreshed instead of id = 4294967297.  Expected
-- (1, orig-small) and (4294967297, new-large).
SELECT * FROM mv_c3 ORDER BY id;

-- The match/merge path builds its SQL fresh every time, so it is unaffected.
REFRESH MATERIALIZED VIEW mv_c3;
UPDATE mv_c3_base SET v = 'concurrent-large' WHERE id = 4294967297;
DO $$ BEGIN
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_c3 WHERE id = $1'
    USING 4294967297::bigint;
END $$;
SELECT * FROM mv_c3 ORDER BY id;

DROP MATERIALIZED VIEW mv_c3;
DROP TABLE mv_c3_base;
