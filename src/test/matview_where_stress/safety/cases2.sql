INSERT INTO probe_case VALUES

-- ---- 18 and 19 again, with the predicate that actually covers the change ----
(24,'corr_inner_fixed','correlated subquery, INNER mutated, CORRECT scope','SAFE',
 $$CREATE TABLE p(id int primary key, nm text);
   CREATE TABLE c(id int primary key, pid int, amt int);
   INSERT INTO p SELECT g, 'p'||g FROM generate_series(1,100) g;
   INSERT INTO c SELECT g, (g%100)+1, g FROM generate_series(1,400) g;$$,
 $$SELECT p.id, p.nm, (SELECT count(*) FROM c WHERE c.pid = p.id) AS n FROM p$$, '(id)',
 $$INSERT INTO c VALUES (9999, 50, 1)$$, $$id = 50$$),

(25,'dim_change_fixed','dimension mutated, CORRECT scope via subquery','SAFE',
 $$CREATE TABLE d(id int primary key, nm text);
   CREATE TABLE f(id int primary key, did int, v int);
   INSERT INTO d SELECT g, 'd'||g FROM generate_series(1,20) g;
   INSERT INTO f SELECT g, (g%20)+1, g FROM generate_series(1,300) g;$$,
 $$SELECT f.id, f.v, d.nm FROM f JOIN d ON d.id = f.did$$, '(id)',
 $$UPDATE d SET nm = 'RENAMED' WHERE id = 5$$,
 $$id IN (SELECT id FROM f WHERE did = 5)$$),

-- ---- conjunction / disjunction with a window ----
(26,'win_part_and','PARTITION BY g, pred = g AND a non-partition column','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, '(id)',
 $$UPDATE b SET score = 99999 WHERE id = 55$$, $$g = (55 % 10) AND score > 500$$),

(27,'win_part_or','PARTITION BY g, pred = g OR g (whole partitions)','SAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, '(id)',
 $$UPDATE b SET score = 99999 WHERE id = 55$$, $$g = (55 % 10) OR g = 3$$),

(28,'win_part_expr','PARTITION BY g, pred is an EXPRESSION over g only','SAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, '(id)',
 $$UPDATE b SET score = 99999 WHERE id = 55$$, $$g % 5 = ((55 % 10) % 5)$$),

-- ---- scope drift ----
(29,'drift_out','row leaves the predicate scope (grouping key changes)','SAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%10, x FROM generate_series(1,200) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$UPDATE b SET g = 99 WHERE id = 55$$, $$g = 5$$),

(30,'drift_in','row enters the predicate scope','SAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%10, x FROM generate_series(1,200) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$UPDATE b SET g = 5 WHERE id = 56$$, $$g = 5$$),

(31,'drift_filtered','view has its own WHERE; row falls out of the view','SAFE',
 $$CREATE TABLE b(id int primary key, g int, active bool);
   INSERT INTO b SELECT x, x%10, true FROM generate_series(1,200) x;$$,
 $$SELECT id, g FROM b WHERE active$$, '(id)',
 $$UPDATE b SET active = false WHERE id = 55$$, $$g = 5$$),

(32,'delete_in_scope','base row deleted inside the scope','SAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%10, x FROM generate_series(1,200) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$DELETE FROM b WHERE id = 55$$, $$g = 5$$),

-- ---- more shapes ----
(33,'distinct_plain','DISTINCT (not ON), pred on a selected column','SAFE',
 $$CREATE TABLE b(id int primary key, g int, x int);
   INSERT INTO b SELECT s, s%10, s%4 FROM generate_series(1,200) s;$$,
 $$SELECT DISTINCT g, x FROM b$$, '(g,x)',
 $$UPDATE b SET x = 3 WHERE id = 55$$, $$g = 5$$),

(34,'having','GROUP BY + HAVING, pred on the grouping key','SAFE',
 $$CREATE TABLE b(id int primary key, g int, amt numeric);
   INSERT INTO b SELECT s, s%20, s FROM generate_series(1,400) s;$$,
 $$SELECT g, sum(amt) AS total FROM b GROUP BY g HAVING sum(amt) > 100$$, '(g)',
 $$UPDATE b SET amt = -100000 WHERE id = 43$$, $$g = (43 % 20)$$),

(35,'ordered_agg','array_agg(... ORDER BY ...), pred on the grouping key','SAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT s, s%12, s FROM generate_series(1,200) s;$$,
 $$SELECT g, array_agg(v ORDER BY v) AS vs FROM b GROUP BY g$$, '(g)',
 $$UPDATE b SET v = -1 WHERE id = 50$$, $$g = (50 % 12)$$),

(36,'leftjoin_null','LEFT JOIN, pred on the NULLABLE side','UNSAFE',
 $$CREATE TABLE l(id int primary key, rid int);
   CREATE TABLE r(id int primary key, nm text);
   INSERT INTO r SELECT g, 'r'||g FROM generate_series(1,10) g;
   INSERT INTO l SELECT g, CASE WHEN g%3=0 THEN (g%10)+1 END FROM generate_series(1,100) g;$$,
 $$SELECT l.id, r.nm FROM l LEFT JOIN r ON r.id = l.rid$$, '(id)',
 $$UPDATE r SET nm = 'X' WHERE id = 4$$, $$nm = 'r4'$$),

(37,'coalesce_key','pred on a COALESCE of two base columns','SAFE',
 $$CREATE TABLE b(id int primary key, a int, c int, v int);
   INSERT INTO b SELECT s, CASE WHEN s%2=0 THEN s%10 END, s%7, s FROM generate_series(1,200) s;$$,
 $$SELECT id, coalesce(a, c) AS k, v FROM b$$, '(id)',
 $$UPDATE b SET v = 1234 WHERE id = 40$$, $$k = coalesce(NULLIF(40 % 2, 1) * 0 + (40 % 10), NULL)$$),

(38,'nested_agg','aggregate over a subquery aggregate, pred on outer key','SAFE',
 $$CREATE TABLE b(id int primary key, g int, h int, amt numeric);
   INSERT INTO b SELECT s, s%6, s%9, s FROM generate_series(1,300) s;$$,
 $$SELECT g, sum(sub) AS total FROM (
     SELECT g, h, sum(amt) AS sub FROM b GROUP BY g, h) s GROUP BY g$$, '(g)',
 $$UPDATE b SET amt = 7777 WHERE id = 100$$, $$g = (100 % 6)$$),

(39,'lateral','LATERAL top-1 per parent, pred on the parent key','SAFE',
 $$CREATE TABLE p(id int primary key);
   CREATE TABLE c(id int primary key, pid int, ts int, v int);
   INSERT INTO p SELECT generate_series(1,50);
   INSERT INTO c SELECT s, (s%50)+1, s, s*2 FROM generate_series(1,400) s;$$,
 $$SELECT p.id, x.v FROM p LEFT JOIN LATERAL
     (SELECT v FROM c WHERE c.pid = p.id ORDER BY ts DESC LIMIT 1) x ON true$$, '(id)',
 $$UPDATE c SET v = 9999 WHERE id = 400$$, $$id = ((400 % 50) + 1)$$),

(40,'window_frame','SUM OVER (ORDER BY .. ROWS 1 PRECEDING) no partition','UNSAFE',
 $$CREATE TABLE b(id int primary key, v int);
   INSERT INTO b SELECT s, s FROM generate_series(1,100) s;$$,
 $$SELECT id, v, sum(v) OVER (ORDER BY id ROWS BETWEEN 1 PRECEDING AND 1 FOLLOWING) AS w FROM b$$, '(id)',
 $$UPDATE b SET v = 5000 WHERE id = 50$$, $$id = 50$$)
;
