-- Narrow table: 4 columns, ~40 byte tuples
DROP TABLE IF EXISTS t_narrow_trig, t_narrow_notrig, t_wide_trig, t_wide_notrig;

CREATE TABLE t_narrow_trig (id int primary key, a int, b int, c text);
INSERT INTO t_narrow_trig SELECT g, g, g, 'val' || g FROM generate_series(1, 100000) g;

CREATE TABLE t_narrow_notrig (LIKE t_narrow_trig INCLUDING ALL);
INSERT INTO t_narrow_notrig SELECT * FROM t_narrow_trig;

-- Wide table: 62 columns, exercises heap_form_tuple / memcmp width scaling
CREATE TABLE t_wide_trig (id int primary key, a int, b int,
  c01 text, c02 text, c03 text, c04 text, c05 text, c06 text, c07 text, c08 text,
  c09 text, c10 text, c11 text, c12 text, c13 text, c14 text, c15 text, c16 text,
  c17 text, c18 text, c19 text, c20 text, c21 text, c22 text, c23 text, c24 text,
  c25 text, c26 text, c27 text, c28 text, c29 text, c30 text,
  n01 int, n02 int, n03 int, n04 int, n05 int, n06 int, n07 int, n08 int,
  n09 int, n10 int, n11 int, n12 int, n13 int, n14 int, n15 int, n16 int,
  n17 int, n18 int, n19 int, n20 int, n21 int, n22 int, n23 int, n24 int,
  n25 int, n26 int, n27 int, n28 int, n29 int, n30 int);

INSERT INTO t_wide_trig
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

CREATE TABLE t_wide_notrig (LIKE t_wide_trig INCLUDING ALL);
INSERT INTO t_wide_notrig SELECT * FROM t_wide_trig;

CREATE TRIGGER z_suppress BEFORE UPDATE ON t_narrow_trig
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();
CREATE TRIGGER z_suppress BEFORE UPDATE ON t_wide_trig
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();

VACUUM ANALYZE;
