--
-- REFRESH MATERIALIZED VIEW ... WHERE ...
--

-- Setup
CREATE TABLE mv_base_a (id int primary key, val text);
INSERT INTO mv_base_a VALUES (1, 'One'), (2, 'Two'), (3, 'Three');

CREATE MATERIALIZED VIEW mv_test_a AS SELECT * FROM mv_base_a;
CREATE UNIQUE INDEX ON mv_test_a(id);

--
-- Test 1: Syntax and Error handling
--

-- 1.1 WITH NO DATA + WHERE -> Error
REFRESH MATERIALIZED VIEW mv_test_a WITH NO DATA WHERE id = 1;

-- 1.2 Unpopulated + WHERE -> Error
CREATE MATERIALIZED VIEW mv_unpop AS SELECT * FROM mv_base_a WITH NO DATA;
REFRESH MATERIALIZED VIEW mv_unpop WHERE id = 1;
DROP MATERIALIZED VIEW mv_unpop;

-- 1.3 Volatile functions -> Error
REFRESH MATERIALIZED VIEW mv_test_a WHERE random() > 0.5;

-- 1.4 Aggregates -> Error
REFRESH MATERIALIZED VIEW mv_test_a WHERE count(*) > 0;

--
-- Test 2: Non-concurrent Partial Refresh
--

-- Modify base data
UPDATE mv_base_a SET val = 'One Updated' WHERE id = 1;
UPDATE mv_base_a SET val = 'Two Updated' WHERE id = 2;

-- Refresh only id=1
REFRESH MATERIALIZED VIEW mv_test_a WHERE id = 1;

-- Verify: id=1 should be updated, id=2 should remain stale
SELECT * FROM mv_test_a ORDER BY id;

-- Refresh id=2
REFRESH MATERIALIZED VIEW mv_test_a WHERE id = 2;
SELECT * FROM mv_test_a ORDER BY id;

--
-- Test 3: Concurrent Partial Refresh
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
REFRESH MATERIALIZED VIEW mv_invoices WHERE id = 1;

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
REFRESH MATERIALIZED VIEW mv_active_items WHERE id = 1;
SELECT * FROM mv_active_items ORDER BY id;

-- Case B: Refresh to add row 2 (which is now active)
REFRESH MATERIALIZED VIEW mv_active_items WHERE id = 2;
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
-- Test 7: Scope Drift
-- A row drifts into the predicate's scope and collides on the unique key with
-- an existing row the predicate does not match.  Both refresh paths resolve
-- this in place via ON CONFLICT instead of raising a unique violation.
--

CREATE TABLE mv_drift_base (id int primary key, category_id int);
INSERT INTO mv_drift_base VALUES (1, 100), (2, 200);

CREATE MATERIALIZED VIEW mv_drift AS SELECT * FROM mv_drift_base;
-- Unique index on id, not category_id, so a category change can collide on id.
CREATE UNIQUE INDEX ON mv_drift(id);

-- Row 1 moves from category 100 into category 200 (Row 2's category).  The
-- predicate "category_id = 200" sees the new (1, 200) but not the stale
-- (1, 100) still present in the view.
UPDATE mv_drift_base SET category_id = 200 WHERE id = 1;

-- Concurrent (direct modification) path resolves the collision in place.
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_drift WHERE category_id = 200;
SELECT * FROM mv_drift ORDER BY id;

-- Recreate the stale state and exercise the non-concurrent (diff) path.
UPDATE mv_drift_base SET category_id = 100 WHERE id = 1;
REFRESH MATERIALIZED VIEW mv_drift;
UPDATE mv_drift_base SET category_id = 200 WHERE id = 1;
REFRESH MATERIALIZED VIEW mv_drift WHERE category_id = 200;
SELECT * FROM mv_drift ORDER BY id;

DROP MATERIALIZED VIEW mv_drift;
DROP TABLE mv_drift_base;

--
-- Test 8: Multiple Unique Keys
-- Addressed specific worry: "what if we have multiple UKs?"
--

CREATE TABLE mv_multi_uk (id int primary key, email text, username text);
INSERT INTO mv_multi_uk VALUES (1, 'a@example.com', 'user_a');

CREATE MATERIALIZED VIEW mv_multi AS SELECT * FROM mv_multi_uk;
CREATE UNIQUE INDEX ON mv_multi(email);
CREATE UNIQUE INDEX ON mv_multi(username);

-- Update all columns
UPDATE mv_multi_uk SET email = 'b@example.com', username = 'user_b' WHERE id = 1;

-- Refresh should succeed updating all unique indexes
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_multi WHERE id = 1;

SELECT * FROM mv_multi;

DROP MATERIALIZED VIEW mv_multi;
DROP TABLE mv_multi_uk;

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
        EXECUTE 'REFRESH MATERIALIZED VIEW mv_trigger_view WHERE id = ANY($1);'
            USING (SELECT array_agg(id) FROM new_table);
    END IF;

    IF (TG_OP IN ('DELETE')) THEN
        EXECUTE 'REFRESH MATERIALIZED VIEW mv_trigger_view WHERE id = ANY($1);'
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
-- Test 10: WHERE predicate privilege model
-- The predicate executes as the matview owner, so a non-owner holding only
-- MAINTAIN may use leakproof expressions but not non-leakproof functions or
-- subqueries.
--

CREATE ROLE regress_mvowner;
CREATE ROLE regress_mvmaint;

CREATE TABLE mv_priv_base (id int, amt numeric);
INSERT INTO mv_priv_base VALUES (1, 10.5), (2, 20.5), (3, 30.5);
CREATE MATERIALIZED VIEW mv_priv AS SELECT id, amt FROM mv_priv_base;
CREATE UNIQUE INDEX ON mv_priv(id);

ALTER TABLE mv_priv_base OWNER TO regress_mvowner;
ALTER MATERIALIZED VIEW mv_priv OWNER TO regress_mvowner;
GRANT MAINTAIN ON mv_priv TO regress_mvmaint;

CREATE FUNCTION mv_priv_stable(int) RETURNS bool LANGUAGE sql STABLE AS 'SELECT true';
ALTER FUNCTION mv_priv_stable(int) OWNER TO regress_mvowner;
CREATE DOMAIN mv_priv_dom AS int CHECK (public.mv_priv_stable(VALUE));

SET ROLE regress_mvmaint;
-- Leakproof predicate: allowed
REFRESH MATERIALIZED VIEW mv_priv WHERE id = 1;
-- Known limitation: numeric comparators are not marked leakproof, so this
-- safe predicate is currently rejected.  It should be allowed.
REFRESH MATERIALIZED VIEW mv_priv WHERE amt > 0;
-- Non-leakproof function: rejected
REFRESH MATERIALIZED VIEW mv_priv WHERE public.mv_priv_stable(id);
-- Subquery: rejected
REFRESH MATERIALIZED VIEW mv_priv WHERE id IN (SELECT id FROM public.mv_priv_base);
-- Domain whose CHECK hides a function call: rejected
REFRESH MATERIALIZED VIEW mv_priv WHERE (id::public.mv_priv_dom) = id;
RESET ROLE;

-- Owner may use a non-leakproof predicate
SET ROLE regress_mvowner;
REFRESH MATERIALIZED VIEW mv_priv WHERE public.mv_priv_stable(id);
RESET ROLE;

DROP MATERIALIZED VIEW mv_priv;
DROP DOMAIN mv_priv_dom;
DROP FUNCTION mv_priv_stable(int);
DROP TABLE mv_priv_base;
DROP ROLE regress_mvmaint;
DROP ROLE regress_mvowner;

--
-- Test 11: a failed partial refresh must not leave the matview writable
--

CREATE TABLE mv_leak_base (id int, code int, val text);
INSERT INTO mv_leak_base VALUES (1, 100, 'a'), (2, 200, 'b'), (3, 300, 'c');
CREATE MATERIALIZED VIEW mv_leak AS SELECT id, code, val FROM mv_leak_base;
CREATE UNIQUE INDEX ON mv_leak(code);

-- Drift two rows onto the same key so the refresh fails mid-flight
UPDATE mv_leak_base SET code = 999 WHERE id IN (1, 2);
\set VERBOSITY terse
REFRESH MATERIALIZED VIEW mv_leak WHERE id <= 2;
\set VERBOSITY default

-- Direct DML on the matview must still be rejected after the failure
DELETE FROM mv_leak WHERE id = 1;
INSERT INTO mv_leak VALUES (42, 4242, 'injected');
SELECT * FROM mv_leak ORDER BY id;

DROP MATERIALIZED VIEW mv_leak;
DROP TABLE mv_leak_base;
