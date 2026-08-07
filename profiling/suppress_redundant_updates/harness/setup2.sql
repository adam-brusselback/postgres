-- Indexed-column table: a real update must maintain 3 secondary indexes,
-- so it cannot be a HOT update. This is where suppression should pay off most.
DROP TABLE IF EXISTS t_idx_trig, t_idx_notrig;

CREATE TABLE t_idx_trig (id int primary key, a int, b int, c text, d text);
INSERT INTO t_idx_trig SELECT g, g, g, 'val' || g, 'other' || g FROM generate_series(1, 100000) g;
CREATE INDEX ON t_idx_trig (a);
CREATE INDEX ON t_idx_trig (b);
CREATE INDEX ON t_idx_trig (c);

CREATE TABLE t_idx_notrig (LIKE t_idx_trig INCLUDING ALL);
INSERT INTO t_idx_notrig SELECT * FROM t_idx_trig;

CREATE TRIGGER z_suppress BEFORE UPDATE ON t_idx_trig
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();

VACUUM ANALYZE t_idx_trig, t_idx_notrig;
