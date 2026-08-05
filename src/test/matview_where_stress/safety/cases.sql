-- Differential safety oracle for REFRESH MATERIALIZED VIEW ... WHERE ...
--
-- For each (view shape, predicate, mutation) triple:
--   1. build base data, create the matview (fully populated == correct)
--   2. mutate the base data
--   3. partial refresh with the predicate a driver would naturally produce
--   4. snapshot the matview
--   5. full refresh  == ground truth
--   6. symmetric difference of (4) and (5)
--
-- A non-empty difference is a proof of UNSAFETY (a concrete counterexample).
-- An empty difference over the mutation space is evidence of safety, not proof.

DROP TABLE IF EXISTS probe_case;
CREATE TABLE probe_case (
  ord      int,
  id       text PRIMARY KEY,
  shape    text,
  expect   text,          -- what the analysis predicts
  setup    text,
  viewsql  text,
  ukey     text,
  mutate   text,
  pred     text           -- the scope a natural driver would refresh
);

INSERT INTO probe_case VALUES

-- ===================== predicted SAFE =====================
(1,'proj','plain projection, pred on PK','SAFE',
 $$CREATE TABLE b(id int primary key, v int, grp int);
   INSERT INTO b SELECT g, g*10, g%7 FROM generate_series(1,200) g;$$,
 $$SELECT id, v, grp FROM b$$, 'id',
 $$UPDATE b SET v = 999 WHERE id = 42$$, $$id = 42$$),

(2,'groupby','GROUP BY, pred on grouping key','SAFE',
 $$CREATE TABLE b(id int primary key, grp int, amt numeric);
   INSERT INTO b SELECT g, g%20, g FROM generate_series(1,400) g;$$,
 $$SELECT grp, sum(amt) AS total, count(*) AS n FROM b GROUP BY grp$$, 'grp',
 $$UPDATE b SET amt = 100000 WHERE id = 43$$, $$grp = (43 % 20)$$),

(3,'join_group','join + GROUP BY, pred on grouping key','SAFE',
 $$CREATE TABLE h(id int primary key, cust int);
   CREATE TABLE l(id int primary key, hid int, amt numeric);
   INSERT INTO h SELECT g, g%13 FROM generate_series(1,100) g;
   INSERT INTO l SELECT g, (g%100)+1, g FROM generate_series(1,500) g;$$,
 $$SELECT h.id AS hid, h.cust, sum(l.amt) AS total
     FROM h JOIN l ON l.hid = h.id GROUP BY h.id, h.cust$$, 'hid',
 $$UPDATE l SET amt = 50000 WHERE id = 137$$, $$hid = ((137 % 100) + 1)$$),

(4,'win_part','rank() OVER (PARTITION BY g), pred on g','SAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, 'id',
 $$UPDATE b SET score = 99999 WHERE id = 55$$, $$g = (55 % 10)$$),

(5,'distincton','DISTINCT ON (k), pred on k','SAFE',
 $$CREATE TABLE b(id int primary key, k int, ts int, v int);
   INSERT INTO b SELECT x, x%25, x, x*3 FROM generate_series(1,300) x;$$,
 $$SELECT DISTINCT ON (k) k, ts, v FROM b ORDER BY k, ts DESC$$, 'k',
 $$UPDATE b SET ts = 100000 WHERE id = 7$$, $$k = (7 % 25)$$),

(6,'unionall','UNION ALL, pred on the shared key','SAFE',
 $$CREATE TABLE b1(id int primary key, v int);
   CREATE TABLE b2(id int primary key, v int);
   INSERT INTO b1 SELECT g, g FROM generate_series(1,100) g;
   INSERT INTO b2 SELECT g, g*2 FROM generate_series(101,200) g;$$,
 $$SELECT id, v, 1 AS src FROM b1 UNION ALL SELECT id, v, 2 FROM b2$$, 'id',
 $$UPDATE b1 SET v = 777 WHERE id = 30$$, $$id = 30$$),

(7,'corr_outer','correlated scalar subquery, OUTER row mutated','SAFE',
 $$CREATE TABLE p(id int primary key, nm text);
   CREATE TABLE c(id int primary key, pid int, amt int);
   INSERT INTO p SELECT g, 'p'||g FROM generate_series(1,100) g;
   INSERT INTO c SELECT g, (g%100)+1, g FROM generate_series(1,400) g;$$,
 $$SELECT p.id, p.nm, (SELECT count(*) FROM c WHERE c.pid = p.id) AS n FROM p$$, 'id',
 $$UPDATE p SET nm = 'changed' WHERE id = 9$$, $$id = 9$$),

(8,'selfjoin_own','self-join, own tuple mutated','SAFE',
 $$CREATE TABLE t(id int primary key, parent int, v int);
   INSERT INTO t SELECT g, CASE WHEN g>1 THEN g/2 END, g FROM generate_series(1,200) g;$$,
 $$SELECT t.id, t.v, pt.v AS parent_v FROM t LEFT JOIN t pt ON pt.id = t.parent$$, 'id',
 $$UPDATE t SET v = 5555 WHERE id = 150$$, $$id = 150$$),

(9,'agg_output','GROUP BY, pred on the AGGREGATE OUTPUT','SAFE',
 $$CREATE TABLE b(id int primary key, grp int, amt numeric);
   INSERT INTO b SELECT g, g%20, g FROM generate_series(1,400) g;$$,
 $$SELECT grp, sum(amt) AS total FROM b GROUP BY grp$$, 'grp',
 $$UPDATE b SET amt = 100000 WHERE id = 43$$, $$total > 3000$$),

(10,'except_key','EXCEPT, pred on the key','SAFE',
 $$CREATE TABLE a1(id int primary key);
   CREATE TABLE a2(id int primary key);
   INSERT INTO a1 SELECT generate_series(1,200);
   INSERT INTO a2 SELECT generate_series(150,300);$$,
 $$SELECT id FROM a1 EXCEPT SELECT id FROM a2$$, 'id',
 $$DELETE FROM a2 WHERE id = 160$$, $$id = 160$$),

(11,'win_two_same','two windows, both PARTITION BY g, pred on g','SAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%8, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score,
          rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk,
          avg(score) OVER (PARTITION BY g) AS gavg FROM b$$, 'id',
 $$UPDATE b SET score = 88888 WHERE id = 33$$, $$g = (33 % 8)$$),

-- ===================== predicted UNSAFE =====================
(12,'win_rowkey','rank() OVER (PARTITION BY g), pred on the ROW key','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, 'id',
 $$UPDATE b SET score = 99999 WHERE id = 55$$, $$id = 55$$),

(13,'runtotal','running SUM() OVER, pred on the row key','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, amt int);
   INSERT INTO b SELECT x, x%5, x FROM generate_series(1,200) x;$$,
 $$SELECT id, g, amt,
          sum(amt) OVER (PARTITION BY g ORDER BY id
                         ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running
     FROM b$$, 'id',
 $$UPDATE b SET amt = 10000 WHERE id = 20$$, $$id = 20$$),

(14,'topn','ORDER BY ... LIMIT (top-N), pred on the row key','UNSAFE',
 $$CREATE TABLE b(id int primary key, score int);
   INSERT INTO b SELECT x, (x*7919)%10000 FROM generate_series(1,500) x;$$,
 $$SELECT id, score FROM b ORDER BY score DESC, id LIMIT 20$$, 'id',
 $$UPDATE b SET score = 99999 WHERE id = 400$$, $$id = 400$$),

(15,'global_win','count(*) OVER () with no PARTITION BY','UNSAFE',
 $$CREATE TABLE b(id int primary key, v int);
   INSERT INTO b SELECT g, g FROM generate_series(1,200) g;$$,
 $$SELECT id, v, count(*) OVER () AS total_rows, sum(v) OVER () AS grand FROM b$$, 'id',
 $$INSERT INTO b VALUES (999, 1)$$, $$id = 999$$),

(16,'pct','percent_rank / ntile over the whole table','UNSAFE',
 $$CREATE TABLE b(id int primary key, score int);
   INSERT INTO b SELECT x, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, score, ntile(4) OVER (ORDER BY score, id) AS quartile FROM b$$, 'id',
 $$UPDATE b SET score = 0 WHERE id = 200$$, $$id = 200$$),

(17,'recursive','recursive closure, pred on member','UNSAFE',
 $$CREATE TABLE e(child int, parent int, primary key(child,parent));
   INSERT INTO e SELECT g, g/2 FROM generate_series(2,150) g;$$,
 $$WITH RECURSIVE r AS (
      SELECT child, parent FROM e
      UNION
      SELECT r.child, e.parent FROM r JOIN e ON e.child = r.parent)
    SELECT child, parent FROM r$$, 'child,parent',
 $$UPDATE e SET parent = 1 WHERE child = 4$$, $$child = 4$$),

(18,'corr_inner','correlated subquery, INNER table mutated','UNSAFE',
 $$CREATE TABLE p(id int primary key, nm text);
   CREATE TABLE c(id int primary key, pid int, amt int);
   INSERT INTO p SELECT g, 'p'||g FROM generate_series(1,100) g;
   INSERT INTO c SELECT g, (g%100)+1, g FROM generate_series(1,400) g;$$,
 $$SELECT p.id, p.nm, (SELECT count(*) FROM c WHERE c.pid = p.id) AS n FROM p$$, 'id',
 $$INSERT INTO c VALUES (9999, 50, 1)$$, $$id = 9999$$),

(19,'dim_change','join to a dimension, DIMENSION mutated','UNSAFE',
 $$CREATE TABLE d(id int primary key, nm text);
   CREATE TABLE f(id int primary key, did int, v int);
   INSERT INTO d SELECT g, 'd'||g FROM generate_series(1,20) g;
   INSERT INTO f SELECT g, (g%20)+1, g FROM generate_series(1,300) g;$$,
 $$SELECT f.id, f.v, d.nm FROM f JOIN d ON d.id = f.did$$, 'id',
 $$UPDATE d SET nm = 'RENAMED' WHERE id = 5$$, $$id = 5$$),

(20,'win_mixed','two windows partitioned differently, pred on one','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, h int, score int);
   INSERT INTO b SELECT x, x%6, x%4, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, h, score,
          rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rg,
          rank() OVER (PARTITION BY h ORDER BY score DESC, id) AS rh FROM b$$, 'id',
 $$UPDATE b SET score = 99999 WHERE id = 77$$, $$g = (77 % 6)$$),

(21,'lag','lag() within partition, pred on the row key','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%5, x FROM generate_series(1,200) x;$$,
 $$SELECT id, g, v, lag(v) OVER (PARTITION BY g ORDER BY id) AS prev_v FROM b$$, 'id',
 $$UPDATE b SET v = 4242 WHERE id = 100$$, $$id = 100$$),

(22,'share_of_total','share of a GLOBAL total (aggregate + join back)','UNSAFE',
 $$CREATE TABLE b(id int primary key, grp int, amt numeric);
   INSERT INTO b SELECT g, g%15, g FROM generate_series(1,300) g;$$,
 $$SELECT grp, sum(amt) AS total,
          sum(amt) / (SELECT sum(amt) FROM b) AS share
     FROM b GROUP BY grp$$, 'grp',
 $$UPDATE b SET amt = 500000 WHERE id = 100$$, $$grp = (100 % 15)$$),

(23,'groupingsets','GROUPING SETS, pred on a grouping column','UNSAFE',
 $$CREATE TABLE b(id int primary key, a int, c int, amt numeric);
   INSERT INTO b SELECT g, g%5, g%3, g FROM generate_series(1,200) g;$$,
 $$SELECT a, c, grouping(a,c) AS gr, sum(amt) AS total
     FROM b GROUP BY GROUPING SETS ((a,c),(a),())$$, 'a,c,gr',
 $$UPDATE b SET amt = 90000 WHERE id = 12$$, $$a = (12 % 5)$$)
;
