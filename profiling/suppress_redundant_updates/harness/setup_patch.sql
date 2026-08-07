-- Three variants of the same table:
--   _plain     : stock behaviour, redundant updates are applied
--   _trigger   : suppress_redundant_updates_trigger() attached
--   _reloption : new suppress_redundant_updates storage parameter
DROP TABLE IF EXISTS t_narrow_plain, t_narrow_trigger, t_narrow_reloption,
                     t_wide_plain, t_wide_trigger, t_wide_reloption;

CREATE TABLE t_narrow_plain (id int primary key, a int, b int, c text);
INSERT INTO t_narrow_plain SELECT g, g, g, 'val' || g FROM generate_series(1, 100000) g;
CREATE TABLE t_narrow_trigger   (LIKE t_narrow_plain INCLUDING ALL);
CREATE TABLE t_narrow_reloption (LIKE t_narrow_plain INCLUDING ALL);
INSERT INTO t_narrow_trigger   SELECT * FROM t_narrow_plain;
INSERT INTO t_narrow_reloption SELECT * FROM t_narrow_plain;

CREATE TABLE t_wide_plain (id int primary key, a int, b int,
  c01 text, c02 text, c03 text, c04 text, c05 text, c06 text, c07 text, c08 text,
  c09 text, c10 text, c11 text, c12 text, c13 text, c14 text, c15 text, c16 text,
  c17 text, c18 text, c19 text, c20 text, c21 text, c22 text, c23 text, c24 text,
  c25 text, c26 text, c27 text, c28 text, c29 text, c30 text,
  n01 int, n02 int, n03 int, n04 int, n05 int, n06 int, n07 int, n08 int,
  n09 int, n10 int, n11 int, n12 int, n13 int, n14 int, n15 int, n16 int,
  n17 int, n18 int, n19 int, n20 int, n21 int, n22 int, n23 int, n24 int,
  n25 int, n26 int, n27 int, n28 int, n29 int, n30 int);
INSERT INTO t_wide_plain
SELECT g, g, g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  'text value number ' || g, 'text value number ' || g, 'text value number ' || g,
  g, g, g, g, g, g, g, g, g, g, g, g, g, g, g,
  g, g, g, g, g, g, g, g, g, g, g, g, g, g, g
FROM generate_series(1, 100000) g;
CREATE TABLE t_wide_trigger   (LIKE t_wide_plain INCLUDING ALL);
CREATE TABLE t_wide_reloption (LIKE t_wide_plain INCLUDING ALL);
INSERT INTO t_wide_trigger   SELECT * FROM t_wide_plain;
INSERT INTO t_wide_reloption SELECT * FROM t_wide_plain;

CREATE TRIGGER z_suppress BEFORE UPDATE ON t_narrow_trigger
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();
CREATE TRIGGER z_suppress BEFORE UPDATE ON t_wide_trigger
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();

ALTER TABLE t_narrow_reloption SET (suppress_redundant_updates = on);
ALTER TABLE t_wide_reloption   SET (suppress_redundant_updates = on);

VACUUM ANALYZE;
