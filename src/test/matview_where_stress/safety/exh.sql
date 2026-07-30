DROP TABLE IF EXISTS probe_exh;
CREATE TABLE probe_exh(ord int, id text primary key, shape text, expect text,
                       setup text, viewsql text, ukey text, mutspace text);

-- N = 12 base rows, 4 groups.  The mutation space below is EXHAUSTIVE over
-- single-row changes drawn from a 5-value domain: every row x every new value,
-- every row deleted, every row moved to every group, plus inserts.
INSERT INTO probe_exh VALUES

('1','win_part','rank() OVER (PARTITION BY g), pred on g','SAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%4, (x*37)%5*250 FROM generate_series(1,12) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$,
 '(id)',
 $$SELECT format('UPDATE b SET score=%s WHERE id=%s',v,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,250,500,750,1000]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('g = %s',i%4)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('g = %s OR g = %s',i%4,ng)
     FROM generate_series(1,12) i, generate_series(0,3) ng
   UNION ALL SELECT format('INSERT INTO b VALUES (%s,%s,%s)',100+i,i%4,v), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,500,1000]) v$$),

('2','win_rowkey','rank() OVER (PARTITION BY g), pred on the row key','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%4, (x*37)%5*250 FROM generate_series(1,12) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$,
 '(id)',
 $$SELECT format('UPDATE b SET score=%s WHERE id=%s',v,i), format('id = %s',i)
     FROM generate_series(1,12) i, unnest(ARRAY[0,250,500,750,1000]) v$$),

('3','win_part_and','rank(), pred = partition key AND a value column','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%4, (x*37)%5*250 FROM generate_series(1,12) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$,
 '(id)',
 $$SELECT format('UPDATE b SET score=%s WHERE id=%s',v,i), format('g = %s AND score > 400',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,250,500,750,1000]) v$$),

('4','groupby','GROUP BY, pred on the grouping key','SAFE',
 $$CREATE TABLE b(id int primary key, g int, amt int);
   INSERT INTO b SELECT x, x%4, x*10 FROM generate_series(1,12) x;$$,
 $$SELECT g, sum(amt) AS total, count(*) AS n, max(amt) AS mx FROM b GROUP BY g$$,
 '(g)',
 $$SELECT format('UPDATE b SET amt=%s WHERE id=%s',v,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,50,100,500]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('g = %s',i%4)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('g = %s OR g = %s',i%4,ng)
     FROM generate_series(1,12) i, generate_series(0,3) ng
   UNION ALL SELECT format('INSERT INTO b VALUES (%s,%s,%s)',100+i,i%4,v), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,500]) v$$),

('5','agg_output','GROUP BY, pred on the AGGREGATE OUTPUT','?',
 $$CREATE TABLE b(id int primary key, g int, amt int);
   INSERT INTO b SELECT x, x%4, x*10 FROM generate_series(1,12) x;$$,
 $$SELECT g, sum(amt) AS total FROM b GROUP BY g$$,
 '(g)',
 $$SELECT format('UPDATE b SET amt=%s WHERE id=%s',v,i), 'total > 200'
     FROM generate_series(1,12) i, unnest(ARRAY[0,50,100,500]) v$$),

('6','proj_nonkey','plain projection, pred on a NON-key column','?',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%4, x FROM generate_series(1,12) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, generate_series(0,4) ng
   UNION ALL SELECT format('UPDATE b SET v=%s WHERE id=%s',v,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('g = %s',i%4)
     FROM generate_series(1,12) i$$),

-- NONDET, not SAFE.  The ORDER BY is a PARTIAL order: ties on ts within a k
-- group are broken arbitrarily, so partial and full refresh may legitimately
-- pick different rows and the difference is not a defect.  It diverges on
-- exactly one mutation of 96 -- UPDATE b SET ts=6 WHERE id=10, which ties id=10
-- with id=6 at (k=2, ts=6).  Case 13 distincton_total is this same view with
-- id appended to the ORDER BY, and diverges zero times; that pair is the
-- control showing the divergence is the partial order and nothing else.
-- This is the B15 hazard: a non-deterministic view definition diverges between
-- refresh forms.  It was labelled SAFE, and the gate list in checkall.sh
-- happened to name distincton_total and not distincton, so the one shape that
-- diverges was the one shape nothing checked.
('7','distincton','DISTINCT ON (k), pred on k','NONDET',
 $$CREATE TABLE b(id int primary key, k int, ts int, v int);
   INSERT INTO b SELECT x, x%4, x, x*3 FROM generate_series(1,12) x;$$,
 $$SELECT DISTINCT ON (k) k, ts, v FROM b ORDER BY k, ts DESC$$, '(k)',
 $$SELECT format('UPDATE b SET ts=%s WHERE id=%s',v,i), format('k = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,6,99]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('k = %s',i%4)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE b SET k=%s WHERE id=%s',nk,i), format('k = %s OR k = %s',i%4,nk)
     FROM generate_series(1,12) i, generate_series(0,3) nk$$),

('8','topn','ORDER BY ... LIMIT 4','UNSAFE',
 $$CREATE TABLE b(id int primary key, score int);
   INSERT INTO b SELECT x, (x*37)%13 FROM generate_series(1,12) x;$$,
 $$SELECT id, score FROM b ORDER BY score DESC, id LIMIT 4$$, '(id)',
 $$SELECT format('UPDATE b SET score=%s WHERE id=%s',v,i), format('id = %s',i)
     FROM generate_series(1,12) i, unnest(ARRAY[0,5,99]) v$$),

('9','selfjoin_parent','self-join on parent, pred on the row key','UNSAFE',
 $$CREATE TABLE t(id int primary key, parent int, v int);
   INSERT INTO t SELECT g, CASE WHEN g>1 THEN g/2 END, g FROM generate_series(1,12) g;$$,
 $$SELECT t.id, t.v, pt.v AS parent_v FROM t LEFT JOIN t pt ON pt.id = t.parent$$, '(id)',
 $$SELECT format('UPDATE t SET v=%s WHERE id=%s',v,i), format('id = %s',i)
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v$$),

('10','join_group','join + GROUP BY, pred on the grouping key','SAFE',
 $$CREATE TABLE h(id int primary key, cust int);
   CREATE TABLE l(id int primary key, hid int, amt int);
   INSERT INTO h SELECT g, g%3 FROM generate_series(1,6) g;
   INSERT INTO l SELECT g, (g%6)+1, g*10 FROM generate_series(1,12) g;$$,
 $$SELECT h.id AS hid, h.cust, sum(l.amt) AS total
     FROM h JOIN l ON l.hid = h.id GROUP BY h.id, h.cust$$, '(hid)',
 $$SELECT format('UPDATE l SET amt=%s WHERE id=%s',v,i), format('hid = %s',(i%6)+1)
     FROM generate_series(1,12) i, unnest(ARRAY[0,999]) v
   UNION ALL SELECT format('DELETE FROM l WHERE id=%s',i), format('hid = %s',(i%6)+1)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE l SET hid=%s WHERE id=%s',nh,i),
                   format('hid = %s OR hid = %s',(i%6)+1,nh)
     FROM generate_series(1,12) i, generate_series(1,6) nh$$);
