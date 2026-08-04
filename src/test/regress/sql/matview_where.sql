--
-- REFRESH MATERIALIZED VIEW ... WHERE ...
--
-- Tests 10 and up were added while reviewing the patch against the -hackers
-- thread "[Patch] Add WHERE clause support to REFRESH MATERIALIZED VIEW".  Each
-- one says whether it came from that thread or was found separately, so that
-- review items can be checked off against it.
--
-- A test covering an unfixed defect has expected output describing what the
-- command should do, so it fails until the defect is fixed, and an XXX comment
-- names the behaviour seen today.  There are none left in this file.
--
-- Each also carries a Disposition line saying whether it is worth keeping in the
-- tree once the defect is fixed, or is scaffolding to delete then.  Grep for
-- "Disposition:" across these files to review that at once.
--

-- Setup
CREATE TABLE mv_base_a (id int primary key, val text);
INSERT INTO mv_base_a VALUES (1, 'One'), (2, 'Two'), (3, 'Three');

CREATE MATERIALIZED VIEW mv_test_a AS SELECT * FROM mv_base_a;
CREATE UNIQUE INDEX ON mv_test_a(id);

--
-- Test 1: Syntax and Error handling
--

-- 1.1 WHERE without CONCURRENTLY -> Error.  A partial refresh modifies rows in
-- place, which is what CONCURRENTLY selects; the bare form replaces the
-- matview's contents wholesale and has no way to restrict that to a scope.
REFRESH MATERIALIZED VIEW mv_test_a WHERE id = 1;

-- 1.2 WITH NO DATA + WHERE -> Error
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WITH NO DATA WHERE id = 1;

-- 1.3 Unpopulated + WHERE -> Error
CREATE MATERIALIZED VIEW mv_unpop AS SELECT * FROM mv_base_a WITH NO DATA;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_unpop WHERE id = 1;
DROP MATERIALIZED VIEW mv_unpop;

-- 1.4 Volatile functions -> Error
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WHERE random() > 0.5;

-- 1.5 Aggregates -> Error
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WHERE count(*) > 0;

--
-- Test 2: only the rows the predicate names are refreshed
--

-- Modify base data
UPDATE mv_base_a SET val = 'One Updated' WHERE id = 1;
UPDATE mv_base_a SET val = 'Two Updated' WHERE id = 2;

-- Refresh only id=1
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WHERE id = 1;

-- Verify: id=1 should be updated, id=2 should remain stale
SELECT * FROM mv_test_a ORDER BY id;

-- Refresh id=2
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WHERE id = 2;
SELECT * FROM mv_test_a ORDER BY id;

--
-- Test 3: a later refresh of the same rows picks up the newer values
--
-- The pair used to be the two spellings, before a WHERE clause required
-- CONCURRENTLY.  Kept as a second round rather than deleted: it is the only
-- case that refreshes a scope twice from one session with different data both
-- times, which is what a cached plan serving a stale answer would break.
--

-- Modify base data
UPDATE mv_base_a SET val = 'One Concurrent' WHERE id = 1;
UPDATE mv_base_a SET val = 'Two Concurrent' WHERE id = 2;

-- Refresh only id=1
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WHERE id = 1;

-- Verify: id=1 updated, id=2 stale
SELECT * FROM mv_test_a ORDER BY id;

-- Refresh id=2
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_test_a WHERE id = 2;
SELECT * FROM mv_test_a ORDER BY id;

-- Cleanup Test 2/3
DROP MATERIALIZED VIEW mv_test_a;
DROP TABLE mv_base_a;

--
-- Test 4: Join View (Invoice style)
--

CREATE TABLE invoices (id int primary key, total numeric);
CREATE TABLE invoice_items (inv_id int references invoices(id), amount numeric);

INSERT INTO invoices VALUES (1, 0), (2, 0);
INSERT INTO invoice_items VALUES (1, 100), (1, 50), (2, 200);

CREATE MATERIALIZED VIEW mv_invoices AS
  SELECT i.id, sum(ii.amount) as computed_total
  FROM invoices i
  JOIN invoice_items ii ON i.id = ii.inv_id
  GROUP BY i.id;

CREATE UNIQUE INDEX ON mv_invoices(id);

SELECT * FROM mv_invoices ORDER BY id;

-- Modify items for invoice 1
INSERT INTO invoice_items VALUES (1, 25);
-- Modify items for invoice 2
INSERT INTO invoice_items VALUES (2, 50);

-- Refresh only invoice 1
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_invoices WHERE id = 1;

-- Verify: Invoice 1 updated (175), Invoice 2 stale (200)
SELECT * FROM mv_invoices ORDER BY id;

-- Refresh invoice 2 concurrently
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_invoices WHERE id = 2;
-- Verify: Invoice 2 updated (250)
SELECT * FROM mv_invoices ORDER BY id;

DROP MATERIALIZED VIEW mv_invoices;
DROP TABLE invoice_items;
DROP TABLE invoices;

--
-- Test 5: Rows entering/leaving view scope
--

CREATE TABLE items (id int, status text, val int);
INSERT INTO items VALUES (1, 'active', 10), (2, 'inactive', 20);

CREATE MATERIALIZED VIEW mv_active_items AS
  SELECT * FROM items WHERE status = 'active';

CREATE UNIQUE INDEX ON mv_active_items(id);

SELECT * FROM mv_active_items ORDER BY id;

-- Case A: Row changes status active -> inactive (should be removed)
UPDATE items SET status = 'inactive' WHERE id = 1;
-- Also update row 2 to active (should be added)
UPDATE items SET status = 'active' WHERE id = 2;

-- Refresh partial WHERE id=1
-- Should remove id=1 because it no longer matches view definition
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_active_items WHERE id = 1;
SELECT * FROM mv_active_items ORDER BY id;

-- Case B: Refresh to add row 2 (which is now active)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_active_items WHERE id = 2;
SELECT * FROM mv_active_items ORDER BY id;

-- Cleanup
DROP MATERIALIZED VIEW mv_active_items;
DROP TABLE items;

--
-- Test 6: Order of Operations (Value Swap)
-- Addressed specific worry: "The order of tuple processing matters"
--

CREATE TABLE mv_swap_base (id int primary key, code text);
INSERT INTO mv_swap_base VALUES (1, 'A'), (2, 'B');

CREATE MATERIALIZED VIEW mv_swap AS SELECT * FROM mv_swap_base;
CREATE UNIQUE INDEX ON mv_swap(code); -- Unique Index is on code, not ID

SELECT * FROM mv_swap ORDER BY id;

-- Perform a swap in the base table
-- 1 becomes B, 2 becomes A
BEGIN;
UPDATE mv_swap_base SET code = 'TEMP' WHERE id = 1;
UPDATE mv_swap_base SET code = 'A' WHERE id = 2;
UPDATE mv_swap_base SET code = 'B' WHERE id = 1;
COMMIT;

-- Refresh both rows concurrently.
-- If the implementation inserts (1, 'B') before deleting (2, 'B'), this will fail.
-- It relies on the implementation correctly handling the Delete/Lock set before the Insert/Upsert.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_swap WHERE id IN (1, 2);

SELECT * FROM mv_swap ORDER BY id;

DROP MATERIALIZED VIEW mv_swap;
DROP TABLE mv_swap_base;

--
-- Test 7: Scope Drift / Constraint Violation
-- Addressed specific worry: "If WHERE predicate would be different... UK violation couldn't be solved"
--

CREATE TABLE mv_drift_base (id int primary key, category_id int);
INSERT INTO mv_drift_base VALUES (1, 100), (2, 200);

CREATE MATERIALIZED VIEW mv_drift AS SELECT * FROM mv_drift_base;
-- KEY FIX: Index on ID, not Category.
-- We want to test that the Refresh logic detects ID conflicts when rows drift into scope,
-- not that Postgres enforces unique indexes on non-unique data.
CREATE UNIQUE INDEX ON mv_drift(id);

-- Update Row 1 to collide with Row 2's category
UPDATE mv_drift_base SET category_id = 200 WHERE id = 1;

-- Refresh using the NEW category value as the filter.
-- The View still contains (1, 100).
-- The Filter "category_id = 200" sees the NEW row (1, 200) in the base table.
-- The Filter "category_id = 200" does NOT see the OLD row (1, 100) in the View,
-- so nothing deletes it and the fresh row collides with it on 'id'.
-- Both refresh forms now resolve that collision in place instead of failing.
\set VERBOSITY terse
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_drift WHERE category_id = 200;
\set VERBOSITY default
SELECT * FROM mv_drift ORDER BY id;

-- Correct usage: Scope must include BOTH the Old location (100) and New location (200)
-- so the system sees the update as an update (or delete+insert).
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_drift WHERE category_id IN (100, 200);

SELECT * FROM mv_drift ORDER BY id;

DROP MATERIALIZED VIEW mv_drift;
DROP TABLE mv_drift_base;

--
-- Test 8: Multiple Unique Keys
-- Addressed specific worry: "what if we have multiple UKs?"
--
-- A partial refresh applies its changes with ON CONFLICT against a single
-- arbiter index, so a row set that needs a delete before an insert to satisfy a
-- *second* unique index cannot be applied that way.  No choice of arbiter
-- avoids it: whichever unique index arbitrates, a swap collides on the other
-- one.  A WHERE clause is therefore refused outright on a matview carrying more
-- than one unique index, rather than failing partway through on whichever
-- change it cannot express.
--
-- Disposition: keep.  It pins the precondition in both directions -- the
-- refusal, and the same command succeeding once the extra index is gone -- and
-- it is the case that would notice if a future statement shape (a scoped delete
-- before the insert, say) let the upsert express this after all, at which point
-- the restriction can be lifted without breaking anyone.
--

CREATE TABLE mv_multi_base (id int primary key, email text, uname text);
INSERT INTO mv_multi_base VALUES (1, 'a@example.com', 'ua'),
                                 (2, 'b@example.com', 'ub');

CREATE MATERIALIZED VIEW mv_multi AS
  SELECT id, email, uname FROM mv_multi_base;
CREATE UNIQUE INDEX ON mv_multi(email);
CREATE UNIQUE INDEX ON mv_multi(uname);

-- Swap the two email addresses.  Both the old and the new row set satisfy every
-- unique index, so nothing about the data is wrong; it is the upsert that
-- cannot get from one to the other.
UPDATE mv_multi_base SET email = CASE id WHEN 1 THEN 'b@example.com'
                                         ELSE 'a@example.com' END;

-- Refused, because of the second unique index.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_multi WHERE id IN (1, 2);

-- The matview is untouched by the refusal: it still holds the pre-swap rows.
SELECT * FROM mv_multi ORDER BY id;

-- A full refresh has no such limit, and applies the swap.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_multi;
SELECT * FROM mv_multi ORDER BY id;

-- Drop the second unique index and a partial refresh takes it -- and still
-- applies a swap, because with only the arbiter left there is nothing to
-- collide with: the upsert matches each row by the very column being swapped
-- and updates it in place.  The collision needs a unique index that is NOT the
-- arbiter, which needs a second one.  So the restriction above is specific
-- rather than a blanket refusal of predicates on this matview, and the answer
-- to the question this case was written for is that a change touching several
-- unique keys at once is applied correctly whenever it can be applied at all.
DROP INDEX mv_multi_uname_idx;
UPDATE mv_multi_base SET email = CASE id WHEN 1 THEN 'a@example.com'
                                         ELSE 'b@example.com' END;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_multi WHERE id IN (1, 2);
SELECT * FROM mv_multi ORDER BY id;

DROP MATERIALIZED VIEW mv_multi;
DROP TABLE mv_multi_base;

--
-- Test 9: Trigger-based Automatic Maintenance
-- Use Case: Automating the partial refresh via triggers using Arrays.
--

CREATE TABLE mv_trigger_base (id int primary key, val text);
CREATE MATERIALIZED VIEW mv_trigger_view AS SELECT * FROM mv_trigger_base;
CREATE UNIQUE INDEX ON mv_trigger_view(id);

-- Create a maintainer function
CREATE OR REPLACE FUNCTION maintain_mv_trigger_view() RETURNS TRIGGER AS $$
BEGIN
    IF (TG_OP IN ('INSERT', 'UPDATE')) THEN
        EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_trigger_view WHERE id = ANY($1);'
            USING (SELECT array_agg(id) FROM new_table);
    END IF;

    IF (TG_OP IN ('DELETE')) THEN
        EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_trigger_view WHERE id = ANY($1);'
            USING (SELECT array_agg(id) FROM old_table);
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql VOLATILE;

-- Trigger for Insert
CREATE TRIGGER t_refresh_mv_ins
    AFTER INSERT ON mv_trigger_base
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
EXECUTE FUNCTION maintain_mv_trigger_view();

-- Trigger for Update
CREATE TRIGGER t_refresh_mv_upd
    AFTER UPDATE ON mv_trigger_base
    REFERENCING NEW TABLE AS new_table
    FOR EACH STATEMENT
EXECUTE FUNCTION maintain_mv_trigger_view();

-- Trigger for Delete
CREATE TRIGGER t_refresh_mv_del
    AFTER DELETE ON mv_trigger_base
    REFERENCING OLD TABLE AS old_table
    FOR EACH STATEMENT
EXECUTE FUNCTION maintain_mv_trigger_view();

-- 1. Test Insert
INSERT INTO mv_trigger_base VALUES (1, 'Auto-Insert'), (2, 'Auto-Insert');
SELECT * FROM mv_trigger_view ORDER BY id;

-- 2. Test Update
UPDATE mv_trigger_base SET val = 'Auto-Update' WHERE id = 1;
SELECT * FROM mv_trigger_view ORDER BY id;

-- 3. Test Delete
DELETE FROM mv_trigger_base WHERE id = 2;
SELECT * FROM mv_trigger_view ORDER BY id;

-- 4. Verify Transaction Isolation
-- Ensure that if the main transaction rolls back, the Refresh also rolls back
BEGIN;
INSERT INTO mv_trigger_base VALUES (99, 'Rollback');
SELECT * FROM mv_trigger_view WHERE id = 99; -- Should see it
ROLLBACK;
SELECT * FROM mv_trigger_view WHERE id = 99; -- Should NOT see it

-- Cleanup
DROP MATERIALIZED VIEW mv_trigger_view;
DROP TABLE mv_trigger_base;
DROP FUNCTION maintain_mv_trigger_view();

--
-- Test 10: Unique index with INCLUDE columns
--
-- Reported on -hackers by Dharin Shah (repro test_include_bug.sql): the
-- ON CONFLICT target was built from indnatts, so INCLUDE columns landed in it
-- and the generated statement failed with "there is no unique or exclusion
-- constraint matching the ON CONFLICT specification".  Fixed by using
-- indnkeyatts; this is the regression guard, and it passes.
--
-- Disposition: keep.  Nothing else exercises an index with INCLUDE columns on
-- this path, and the cost is two refreshes.
--

CREATE TABLE mv_incl_base (id int primary key, extra text, v text);
INSERT INTO mv_incl_base VALUES (1, 'x', 'one'), (2, 'y', 'two');

CREATE MATERIALIZED VIEW mv_incl AS SELECT id, extra, v FROM mv_incl_base;
CREATE UNIQUE INDEX ON mv_incl(id) INCLUDE (extra);

-- Change both a plain column and the INCLUDE column, so that the DO UPDATE SET
-- list has to cover the INCLUDE column while the conflict target must not.
UPDATE mv_incl_base SET extra = 'x2', v = 'one-updated' WHERE id = 1;

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_incl WHERE id = 1;
SELECT * FROM mv_incl ORDER BY id;

-- Again for a second row, so a fix that happened to suit the first one shows.
UPDATE mv_incl_base SET extra = 'y2', v = 'two-updated' WHERE id = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_incl WHERE id = 2;
SELECT * FROM mv_incl ORDER BY id;

DROP MATERIALIZED VIEW mv_incl;
DROP TABLE mv_incl_base;

--
-- Test 11: NULL values in the unique key column
--
-- Not yet reported on -hackers; found while writing these tests.
--
-- The direct-modification path resolves conflicts with ON CONFLICT, which
-- arbitrates via the unique index.  A NULLS DISTINCT index never reports a
-- conflict for a NULL key, so every row is inserted afresh.  The anti-join
-- that removes stale rows uses IS NOT DISTINCT FROM, which *does* treat two
-- NULLs as equal, so the pre-existing row is never removed.  The two halves
-- disagree, and rows accumulate.
--
-- Disposition: keep.  "A refresh that changes nothing changes nothing" is an
-- invariant worth asserting permanently, whichever way the disagreement is
-- resolved -- by matching the index's NULL semantics in the anti-join, or by
-- requiring NOT NULL or NULLS NOT DISTINCT key columns.
--

CREATE TABLE mv_null_base (id int, v text);
INSERT INTO mv_null_base VALUES (NULL, 'x'), (1, 'a');

CREATE MATERIALIZED VIEW mv_null AS SELECT id, v FROM mv_null_base;
CREATE UNIQUE INDEX ON mv_null(id);

SELECT count(*) AS rows_initial FROM mv_null;

-- The base table is not modified, so each of these must be a no-op.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null WHERE id IS NULL;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null WHERE id IS NULL;

-- Must still be 2, and is: the anti-join now takes its NULL handling from the
-- arbiter index (B4), so the upsert and the anti-join agree that the
-- NULL-keyed row is unchanged.  Before that fix this returned 4 -- one
-- duplicate per refresh -- which is what the rest of this test is shaped
-- around.
SELECT count(*) AS rows_after_two_noop_refreshes FROM mv_null;

-- And again, so a repair that only held for the first refresh would show.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null WHERE id IS NULL;
SELECT count(*) AS rows_after_concurrent_refresh FROM mv_null;

-- With NULLS NOT DISTINCT the upsert does arbitrate on NULL, which agrees
-- with the anti-join, and the refresh behaves correctly.
CREATE MATERIALIZED VIEW mv_null_nnd AS SELECT id, v FROM mv_null_base;
CREATE UNIQUE INDEX ON mv_null_nnd(id) NULLS NOT DISTINCT;

SELECT count(*) AS rows_initial FROM mv_null_nnd;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null_nnd WHERE id IS NULL;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null_nnd WHERE id IS NULL;
SELECT count(*) AS rows_after_two_noop_refreshes FROM mv_null_nnd;

DROP MATERIALIZED VIEW mv_null_nnd;
DROP MATERIALIZED VIEW mv_null;
DROP TABLE mv_null_base;

--
-- Test 12: Scope drift
--
-- Reported on -hackers by Adam Brusselback, who wrote that the refresh should
-- resolve this "by using an INSERT ... ON CONFLICT DO UPDATE step (or DO
-- NOTHING if there are no non-key columns) against the arbiter index".  It
-- does.
--
-- Disposition: keep.  A row drifting into the predicate's scope while a stale
-- copy of it sits outside is what the arbiter index exists to reconcile, and
-- getting it wrong is a duplicate key violation rather than a wrong answer, so
-- it fails loudly and is worth pinning.
--

CREATE TABLE mv_drift2_base (id int primary key, category_id int);
INSERT INTO mv_drift2_base VALUES (1, 100), (2, 200);

CREATE MATERIALIZED VIEW mv_drift2 AS SELECT id, category_id FROM mv_drift2_base;
CREATE UNIQUE INDEX ON mv_drift2(id);

-- Row 1 drifts from category 100 into category 200.  The predicate only sees
-- the new location, so the stale row at the old location is not deleted.
UPDATE mv_drift2_base SET category_id = 200 WHERE id = 1;

-- The upsert absorbs the collision: it matches the stale row by its key,
-- whatever the predicate column says, and overwrites it in place.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_drift2 WHERE category_id = 200;
SELECT * FROM mv_drift2 ORDER BY id;

-- The same drift a second time, to a category no row has held.
UPDATE mv_drift2_base SET category_id = 300 WHERE id = 1;
-- The VERBOSITY guard keeps any failure's diff to a single line: the CONTEXT of
-- a failure here is the whole generated statement, which is long and carries
-- names that are not stable across runs.
\set VERBOSITY terse
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_drift2 WHERE category_id = 300;
\set VERBOSITY default
SELECT * FROM mv_drift2 ORDER BY id;

DROP MATERIALIZED VIEW mv_drift2;
DROP TABLE mv_drift2_base;

--
-- Test 13: What the predicate can reference
--
-- The subquery half was reported on -hackers by Dharin Shah, who noted that
-- the script claimed "Subqueries -> Error" while the expected output showed
-- none, and that nothing in transformRefreshWhereClause() forbids them.  The
-- comment has been removed; a schema-qualified subquery is allowed, and this
-- is the regression guard for that.
--
-- The unqualified half is not reported on -hackers.  REFRESH switches to the
-- matview's owner and calls RestrictSearchPath(), so the predicate is analyzed
-- with search_path set to "pg_catalog, pg_temp" and cannot see objects the
-- caller sees unqualified.  Unlike the other defects in this file, this one
-- records current behaviour rather than asserting a fix: restricting the path
-- is what makes the owner-privilege model tractable, so what should happen here
-- depends on how the privilege question is settled.
--
-- Disposition: keep both halves.  B9 is settled: the restricted search path
-- stays, because the predicate runs as the matview owner and a caller-supplied
-- search_path plus owner-context execution is the CVE-2018-1058 shape.  So the
-- schema-qualification requirement is real behaviour worth asserting, not a
-- record of something about to change.  The bare "relation does not exist" that
-- used to be all a caller got now carries an error context and, for the errors a
-- missing qualification actually produces, a hint naming the restricted
-- search_path -- which is what the expected output below pins.  Note that a
-- Query-tree implementation may make this moot by letting the predicate run as
-- the invoker; if so, this becomes an assertion of the new behaviour.
--

CREATE TABLE mv_sp_base (id int primary key, v text);
INSERT INTO mv_sp_base VALUES (1, 'one'), (2, 'two');
CREATE MATERIALIZED VIEW mv_sp AS SELECT id, v FROM mv_sp_base;
CREATE UNIQUE INDEX ON mv_sp(id);

CREATE TABLE mv_sp_ids (id int);
INSERT INTO mv_sp_ids VALUES (1);

SHOW search_path;

-- An unqualified reference fails even though "public" is in search_path.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sp WHERE id IN (SELECT id FROM mv_sp_ids);

-- Schema-qualifying it works.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sp WHERE id IN (SELECT s.id FROM public.mv_sp_ids s);
SELECT * FROM mv_sp ORDER BY id;

-- A CORRELATED subquery, which is the case the uncorrelated one above cannot
-- reach.  The predicate is deparsed back to text for the statements SPI builds,
-- and ruleutils only qualifies a Var once something else is in scope -- which a
-- subquery referring back to the matview is the first thing to do.  If the
-- deparse names the matview differently from the way those statements do, this
-- is where it shows up, as "missing FROM-clause entry".  Both halves of the
-- statement carry the predicate, so both would fail.
UPDATE mv_sp_base SET v = 'ONE' WHERE id = 1;
UPDATE mv_sp_base SET v = 'TWO' WHERE id = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sp
  WHERE EXISTS (SELECT 1 FROM public.mv_sp_ids s WHERE s.id = mv_sp.id);
-- id 1 is in mv_sp_ids and id 2 is not, so only id 1 moves.
SELECT * FROM mv_sp ORDER BY id;

-- And the other direction, so a predicate that selected everything would show.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_sp
  WHERE NOT EXISTS (SELECT 1 FROM public.mv_sp_ids s WHERE s.id = mv_sp.id);
SELECT * FROM mv_sp ORDER BY id;

DROP TABLE mv_sp_ids;
DROP MATERIALIZED VIEW mv_sp;
DROP TABLE mv_sp_base;

--
-- Test 14: the row comparison and NULL
--
-- The upsert's DO UPDATE carries WHERE (mv cols) IS DISTINCT FROM (EXCLUDED
-- cols), so a row whose values did not change is not rewritten.  IS DISTINCT
-- FROM rather than <> is the whole point: `<>` yields NULL when either side is
-- NULL, the WHERE is then not true, and a row moving to or from NULL is
-- silently left at its old value.
--
-- Nothing tested that.  The comparison ran in other cases, but their data has
-- no NULLs, and the two operators agree on every non-NULL row, so mutation B7
-- (`IS DISTINCT FROM` -> `<>`) passed the entire suite.
--
-- Both directions are needed and they fail differently: NULL -> value leaves the
-- old NULL, value -> NULL leaves the old value.  A test doing only one of them
-- catches only one of them.
--
CREATE TABLE mv_null_base (id int PRIMARY KEY, v int);
INSERT INTO mv_null_base VALUES (1, NULL), (2, 20), (3, NULL), (4, 40);
CREATE MATERIALIZED VIEW mv_null AS SELECT id, v FROM mv_null_base;
CREATE UNIQUE INDEX ON mv_null(id);

-- NULL -> value.  Under `<>` the comparison is NULL, the row is not updated,
-- and id 1 stays NULL.
UPDATE mv_null_base SET v = 11 WHERE id = 1;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null WHERE id = 1;
SELECT id, v FROM mv_null ORDER BY id;

-- value -> NULL.  Same comparison, other direction: id 2 stays 20.
UPDATE mv_null_base SET v = NULL WHERE id = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null WHERE id = 2;
SELECT id, v FROM mv_null ORDER BY id;

-- NULL -> NULL really is a no-op, so the row comparison is doing its job rather
-- than being bypassed: this must change nothing, and would also pass if the
-- comparison were absent.  It is here so the two cases above cannot be read as
-- "the optimization is simply off".
UPDATE mv_null_base SET v = NULL WHERE id = 3;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_null WHERE id = 3;
SELECT id, v FROM mv_null ORDER BY id;


DROP MATERIALIZED VIEW mv_null;
DROP TABLE mv_null_base;

--
-- Test 15: an unchanged row is not rewritten
--
-- Found here, not on the -hackers thread.
--
-- Test 14 reads values back, which is what a NULL bug corrupts.  It cannot see
-- the comparison being absent: without it every matched row is rewritten, which
-- is what the code did before 03cb4f0 and is still correct, so the values are
-- right either way.  Measured rather than supposed -- mutation O1, the
-- comparison never emitted, was UNCAUGHT by every instrument in the tree.
--
-- What the optimisation is for is not visible in the contents at all, so this
-- reads the heap instead.  An UPDATE writes a new tuple at a new location, so
-- a row that kept its ctid across the refresh is a row the refresh did not
-- write.  That is a statement about what the command did rather than about how
-- the SQL was spelled, so an implementation that skips the write some other way
-- passes it.  Taking a row lock does not move a tuple, so rows the refresh
-- locked and then left alone still read as unchanged.
--
-- Verified as a detector rather than assumed: under O1 every row comes back f.
--
-- Disposition: keep.  Not rewriting a row nothing changed about is the
-- feature's promise about write amplification -- it is what makes re-refreshing
-- an already-current scope cheap, and it is the reason a drain can be run
-- often.
--

CREATE TABLE mv_rowver_base (id int primary key, v int, note text);
INSERT INTO mv_rowver_base SELECT g, g * 10, 'n' || g FROM generate_series(1, 5) g;

CREATE MATERIALIZED VIEW mv_rowver AS SELECT id, v, note FROM mv_rowver_base;
CREATE UNIQUE INDEX ON mv_rowver(id);

CREATE TEMP TABLE mv_rowver_was AS SELECT id, ctid AS was FROM mv_rowver;

-- Row 3 is the only one that now differs from what the matview holds.
UPDATE mv_rowver_base SET v = 999 WHERE id = 3;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_rowver WHERE id BETWEEN 1 AND 5;

-- Only row 3 may have been written.
SELECT w.id, (w.was = m.ctid) AS same_row_version
  FROM mv_rowver_was w JOIN mv_rowver m USING (id) ORDER BY w.id;

-- ...and it must actually have been.  Skipping too much is the other way to
-- fail this and looks identical in the column above.
SELECT id, v, note FROM mv_rowver ORDER BY id;

DROP TABLE mv_rowver_was;
DROP MATERIALIZED VIEW mv_rowver;
DROP TABLE mv_rowver_base;


--
-- Test 16: the predicate's constants become parameters, and the values still
--          reach the right rows
--
-- The plan cache is keyed on the deparsed predicate, so "WHERE id = 1" and
-- "WHERE id = 2" were two different statements and a caller refreshing one row
-- at a time missed on every call.  The predicate's constants are now replaced
-- with parameters before the deparse, which makes those two the same statement
-- with different values -- worth about 250 us a refresh, most of a scope-1
-- refresh's cost.
--
-- That is only a win if the values go where the constants went.  Two refreshes
-- of the same shape now share one cached plan, so a bug that bound the first
-- refresh's values on the second would refresh the wrong rows and report
-- success: the plan is valid SQL and the rows it touches are perfectly good
-- rows, just not the ones asked for.  Nothing in the matview's contents says
-- which refresh wrote them.
--
-- So this drives the second refresh with the SAME constants in the OTHER order.
-- (1, 2) and (2, 1) are both real keys, both are selected by a predicate that
-- deparses identically, and each must pick up only its own row.
--
-- Disposition: keep.  "A refresh acts on the rows its predicate names" is the
-- feature's first promise and does not depend on how the predicate is stored.
--

CREATE TABLE mv_pp_base (a int, b int, v text, tag text, primary key (a, b));
INSERT INTO mv_pp_base VALUES (1, 2, 'v12', 'cold'), (2, 1, 'v21', 'cold'),
                              (3, 3, 'v33', 'cold'), (4, 4, 'v44', 'hot');

CREATE MATERIALIZED VIEW mv_pp AS SELECT a, b, v, tag FROM mv_pp_base;
CREATE UNIQUE INDEX ON mv_pp (a, b);

UPDATE mv_pp_base SET v = 'V12' WHERE a = 1 AND b = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_pp WHERE a = 1 AND b = 2;

-- Same predicate shape, same two constants, swapped.  Under a plan that reused
-- the first refresh's values this refreshes (1,2) again and leaves (2,1) stale.
UPDATE mv_pp_base SET v = 'V21' WHERE a = 2 AND b = 1;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_pp WHERE a = 2 AND b = 1;

-- (3,3) has never been in scope and must still hold its original value, which
-- is what says the refreshes were partial rather than accidentally total.
SELECT a, b, v FROM mv_pp ORDER BY a, b;

-- A text constant, because a parameter carries its collation where a literal
-- gets one assigned at parse time, and the two must agree -- B19 is the same
-- seam from the other side, where an unassigned collation made "tag = 'hot'"
-- fail outright.  Two refreshes again, sharing one deparsed predicate and
-- differing only in the values, so binding the wrong one refreshes the wrong
-- row.  The tag values themselves do not change, or the row would leave its
-- own predicate's scope and be pruned, which is a different behaviour and not
-- the one under test.
UPDATE mv_pp_base SET v = 'T33' WHERE a = 3;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_pp WHERE tag = 'cold' AND a = 3;
UPDATE mv_pp_base SET v = 'T44' WHERE a = 4;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_pp WHERE tag = 'hot' AND a = 4;
SELECT a, b, v, tag FROM mv_pp ORDER BY a, b;

-- A caller-supplied parameter and a constant in one predicate: $1 keeps its
-- number and the constant is appended after it, so a refresh that renumbered
-- either would bind them to each other's positions.
DO $$
BEGIN
  UPDATE mv_pp_base SET v = 'W12' WHERE a = 1 AND b = 2;
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_pp WHERE a = $1 AND b = 2' USING 1;
END $$;
SELECT a, b, v FROM mv_pp ORDER BY a, b;

DROP MATERIALIZED VIEW mv_pp;
DROP TABLE mv_pp_base;

--
-- Test 17: a row that leaves the scope is deleted, in the shapes where a
-- cheaper implementation would stop deleting it
--
-- The prune scans the scope a second time to find rows the defining query no
-- longer produces.  An implementation that wanted to skip that scan would have
-- to decide, without doing it, that nothing in scope can be orphaned -- and the
-- cheap accounting for that is unsound.  It would compare how many matview rows
-- the pre-lock matched and how many rows the source produced, and skip the
-- prune when every source row is accounted for by a row already in scope or one
-- the upsert has just inserted.
--
-- That assumes a source row conflicting with an existing matview row conflicts
-- with one IN SCOPE.  A predicate reading a non-key column breaks it: ON
-- CONFLICT arbitrates on the key and knows nothing about the predicate, so the
-- upsert can match a row the pre-lock never counted -- and a genuinely orphaned
-- row elsewhere in the scope cancels the discrepancy exactly.  The failure is a
-- silently missing DELETE rather than a slow refresh.
--
-- Such a guard was built, measured and removed: it was sound only while the
-- matview was held at ExclusiveLock, since the counts are taken under an
-- earlier snapshot than the DELETE they stand in for, and a partial refresh
-- takes RowExclusiveLock.  These cases are what is left of it, and they are
-- worth more than it was.
--
-- Disposition: keep.  These are not tests of an optimisation, they are tests of
-- the promise an optimisation is allowed to keep -- "a row that leaves the
-- scope is deleted" -- in the cases where a cheaper implementation would stop
-- keeping it.  They outlive any particular guard.
--

-- 17a: the counterexample.  One row leaves the scope and one enters it, so
-- locked, source and inserted balance while a row is orphaned all the same.
CREATE TABLE mv_nd_base (k int PRIMARY KEY, status text);
INSERT INTO mv_nd_base VALUES (1, 'A'), (2, 'B');

CREATE MATERIALIZED VIEW mv_nd AS SELECT k, status FROM mv_nd_base;
CREATE UNIQUE INDEX ON mv_nd (k);

UPDATE mv_nd_base SET status = 'B' WHERE k = 1;   -- leaves the scope
UPDATE mv_nd_base SET status = 'A' WHERE k = 2;   -- enters it

-- n_locked = 1 (the matview's (1,'A')), n_source = 1 (the base's (2,'A')),
-- n_inserted = 0 (k=2 conflicts with the matview's (2,'B')).  1 + 0 = 1, and
-- k=1 must still be deleted.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd WHERE status = 'A';
SELECT k, status FROM mv_nd ORDER BY k;

-- 17b: the same cancellation with a predicate that DOES name a key column, so
-- the gate cannot be "does the predicate mention the key".
CREATE TABLE mv_nd5_base (k int PRIMARY KEY, status text, v text);
INSERT INTO mv_nd5_base VALUES (1, 'A', 'p'), (2, 'B', 'q');

CREATE MATERIALIZED VIEW mv_nd5 AS SELECT k, status, v FROM mv_nd5_base;
CREATE UNIQUE INDEX ON mv_nd5 (k);

UPDATE mv_nd5_base SET status = 'B' WHERE k = 1;
UPDATE mv_nd5_base SET status = 'A' WHERE k = 2;

REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd5 WHERE k <= 2 AND status = 'A';
SELECT k, status, v FROM mv_nd5 ORDER BY k;

-- 17c: a key-only predicate, both directions.  The first refresh is the case
-- the elision exists for -- every source row matches a row already in scope --
-- and the second is the same statement when a row really has gone.
CREATE TABLE mv_nd2_base (k int PRIMARY KEY, v text);
INSERT INTO mv_nd2_base VALUES (1, 'a'), (2, 'b'), (3, 'c');

CREATE MATERIALIZED VIEW mv_nd2 AS SELECT k, v FROM mv_nd2_base;
CREATE UNIQUE INDEX ON mv_nd2 (k);

UPDATE mv_nd2_base SET v = 'A' WHERE k = 1;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd2 WHERE k <= 2;
SELECT k, v FROM mv_nd2 ORDER BY k;

DELETE FROM mv_nd2_base WHERE k = 2;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd2 WHERE k <= 2;
SELECT k, v FROM mv_nd2 ORDER BY k;

-- 17d: nothing in scope at all.  The matview holds no row the predicate
-- selects, so the DELETE cannot match -- the upsert's own insert is not
-- visible to it -- and the row still has to arrive.
INSERT INTO mv_nd2_base VALUES (2, 'B');
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd2 WHERE k = 2;
SELECT k, v FROM mv_nd2 ORDER BY k;

-- 17e: a composite key with the predicate covering only its leading column.
-- Still key-only, and the counts still have to notice the row that went.
CREATE TABLE mv_nd4_base (a int, b int, v text, PRIMARY KEY (a, b));
INSERT INTO mv_nd4_base VALUES (1, 1, 'x'), (1, 2, 'y'), (2, 1, 'z');

CREATE MATERIALIZED VIEW mv_nd4 AS SELECT a, b, v FROM mv_nd4_base;
CREATE UNIQUE INDEX ON mv_nd4 (a, b);

DELETE FROM mv_nd4_base WHERE a = 1 AND b = 2;
UPDATE mv_nd4_base SET v = 'X' WHERE a = 1 AND b = 1;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd4 WHERE a = 1;
SELECT a, b, v FROM mv_nd4 ORDER BY a, b;

-- 17f: every column is a key column, so the upsert is ON CONFLICT DO NOTHING
-- and a conflicting row returns nothing at all.  The count still has to come
-- out right, because what it counts is the inserts and an insert is returned on
-- either branch.  This is also the only case that exercises the RETURNING
-- clause on the DO NOTHING arm.
CREATE TABLE mv_nd6_base (a int, b int, PRIMARY KEY (a, b));
INSERT INTO mv_nd6_base VALUES (1, 1), (1, 2), (2, 1);

CREATE MATERIALIZED VIEW mv_nd6 AS SELECT a, b FROM mv_nd6_base;
CREATE UNIQUE INDEX ON mv_nd6 (a, b);

-- one row leaves and one arrives, so n_locked 2 + n_inserted 1 <> n_source 2
DELETE FROM mv_nd6_base WHERE a = 1 AND b = 2;
INSERT INTO mv_nd6_base VALUES (1, 3);
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_nd6 WHERE a = 1;
SELECT a, b FROM mv_nd6 ORDER BY a, b;

DROP MATERIALIZED VIEW mv_nd6;
DROP TABLE mv_nd6_base;
DROP MATERIALIZED VIEW mv_nd4;
DROP TABLE mv_nd4_base;
DROP MATERIALIZED VIEW mv_nd2;
DROP TABLE mv_nd2_base;
DROP MATERIALIZED VIEW mv_nd5;
DROP TABLE mv_nd5_base;
DROP MATERIALIZED VIEW mv_nd;
DROP TABLE mv_nd_base;
