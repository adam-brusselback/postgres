DELETE FROM probe_exh WHERE ord::int >= 14;
INSERT INTO probe_exh VALUES
('14','except_key','EXCEPT, pred on the key (planner refuses push-down)','SAFE',
 $$CREATE TABLE a1(id int primary key); CREATE TABLE a2(id int primary key);
   INSERT INTO a1 SELECT generate_series(1,12);
   INSERT INTO a2 SELECT generate_series(7,16);$$,
 $$SELECT id FROM a1 EXCEPT SELECT id FROM a2$$, '(id)',
 $$SELECT format('DELETE FROM a2 WHERE id=%s',i), format('id = %s',i)
     FROM generate_series(1,16) i
   UNION ALL SELECT format('INSERT INTO a2 VALUES (%s) ON CONFLICT DO NOTHING',i), format('id = %s',i)
     FROM generate_series(1,16) i
   UNION ALL SELECT format('DELETE FROM a1 WHERE id=%s',i), format('id = %s',i)
     FROM generate_series(1,16) i
   UNION ALL SELECT format('INSERT INTO a1 VALUES (%s) ON CONFLICT DO NOTHING',i), format('id = %s',i)
     FROM generate_series(1,16) i$$),

('15','having','GROUP BY + HAVING, pred on the grouping key','SAFE',
 $$CREATE TABLE b(id int primary key, g int, amt int);
   INSERT INTO b SELECT x, x%4, x*10 FROM generate_series(1,12) x;$$,
 $$SELECT g, sum(amt) AS total FROM b GROUP BY g HAVING sum(amt) > 100$$, '(g)',
 $$SELECT format('UPDATE b SET amt=%s WHERE id=%s',v,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[-1000,0,50,500]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('g = %s',i%4)
     FROM generate_series(1,12) i$$),

('16','share_of_total','share of a GLOBAL total (uncorrelated sub-select)','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, amt int);
   INSERT INTO b SELECT x, x%4, x*10 FROM generate_series(1,12) x;$$,
 $$SELECT g, sum(amt) AS total,
          round(sum(amt)::numeric / (SELECT sum(amt) FROM b), 4) AS share
     FROM b GROUP BY g$$, '(g)',
 $$SELECT format('UPDATE b SET amt=%s WHERE id=%s',v,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,50,500]) v$$),

('17','drift_out','pred on a NON-key column, arbiter is the key','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%4, x FROM generate_series(1,12) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, generate_series(0,4) ng$$),

('18','pred_on_key','pred on the ARBITER KEY: drift is impossible','SAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%4, x FROM generate_series(1,12) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('id = %s',i)
     FROM generate_series(1,12) i, generate_series(0,4) ng
   UNION ALL SELECT format('UPDATE b SET v=%s WHERE id=%s',v,i), format('id = %s',i)
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('id = %s',i)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('INSERT INTO b VALUES (%s,1,1)',100+i), format('id = %s',100+i)
     FROM generate_series(1,12) i$$),

-- Added after the 1.1c calibration run showed the oracle MISSING B4.
--
-- The miss was not a weak detector, it was a gap in the corpus: every other
-- case here starts `id int primary key`, so no shape in the space had a
-- NULLable unique key, and B4 is a bug that can only happen when one does.
-- ON CONFLICT against a NULLS DISTINCT index never arbitrates a NULL key, so
-- the upsert always inserts; whether the anti-join then removes the old row
-- decides whether it duplicates.  That makes this the shape where "the upsert
-- and the prune agree about which rows the view produces" -- P1 -- is
-- decidable in a single session, which is rare and worth having.
--
-- `matview_where` Test 11 covers the same bug statically.  Until this case
-- existed the fuzzer could not have replaced it, which is the kind of thing
-- the calibration is meant to reveal before, not after, deleting a test.
('19','nullable_key','projection with a NULLable unique key (the B4 shape)','SAFE',
 $$CREATE TABLE b(id int primary key, k int, v int);
   INSERT INTO b SELECT x, CASE WHEN x % 5 = 0 THEN NULL ELSE x % 4 END, x*10
     FROM generate_series(1,12) x;$$,
 $$SELECT k, sum(v) AS total FROM b GROUP BY k$$, '(k)',
 $$SELECT format('UPDATE b SET v=%s WHERE id=%s',v,i),
          CASE WHEN i%5 = 0 THEN 'k IS NULL' ELSE format('k = %s',i%4) END
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v
   UNION ALL SELECT format('UPDATE b SET k=NULL WHERE id=%s',i),
                   format('k = %s OR k IS NULL',i%4)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE b SET k=%s WHERE id=%s',nk,i),
                   format('k = %s OR k = %s OR k IS NULL',i%4,nk)
     FROM generate_series(1,12) i, generate_series(0,3) nk
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i),
                   format('k = %s OR k IS NULL',i%4)
     FROM generate_series(1,12) i$$),

-- Case 19 covers a NULLable key of one column.  This is the composite form,
-- which is a different shape and not implied by it: the arbiter is (a, bcol)
-- with only bcol NULLable, so ON CONFLICT has to arbitrate a partly-NULL key
-- and the anti-join has to compare two columns, one of which can be NULL.
-- Getting the single-column case right does not make this one right -- the
-- comparison is per-column and the operator choice applies to all of them.
('21','nullable_composite','composite unique key with a NULLable member','SAFE',
 $$CREATE TABLE b(id int primary key, a int, bcol int, v int);
   INSERT INTO b SELECT x, x%3,
                        CASE WHEN x % 5 = 0 THEN NULL ELSE x%4 END, x*10
     FROM generate_series(1,12) x;$$,
 $$SELECT a, bcol, sum(v) AS total FROM b GROUP BY a, bcol$$, '(a, bcol)',
 $$SELECT format('UPDATE b SET v=%s WHERE id=%s',v,i),
          format('a = %s AND %s',i%3,
                 CASE WHEN i%5 = 0 THEN 'bcol IS NULL'
                      ELSE format('bcol = %s',i%4) END)
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i),
          format('a = %s AND %s',i%3,
                 CASE WHEN i%5 = 0 THEN 'bcol IS NULL'
                      ELSE format('bcol = %s',i%4) END)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE b SET bcol=NULL WHERE id=%s',i),
          format('a = %s AND (bcol IS NULL OR bcol = %s)',i%3,i%4)
     FROM generate_series(1,12) i$$);

-- Case 20 declares a second unique index, so it carries nine values where the
-- cases above carry eight.  A multi-row VALUES list has to be uniform, so it
-- gets its own statement rather than nine NULLs added to everything else.
INSERT INTO probe_exh VALUES

-- Two unique indexes, so the arbiter choice is decidable.  This is the shape
-- B6 needs and the corpus could not express until probe_exh grew a ukey2.
--
-- (id) is created first and is the one the upsert should arbitrate on.  (code)
-- is unique too, so choosing it instead is not a syntax error -- it is a
-- silently different upsert.  The mutation space moves `code` while the
-- predicate names `id`: with the right arbiter the row is updated in place,
-- and with the wrong one the new code is absent from the matview, so ON
-- CONFLICT finds nothing to arbitrate and INSERTs a second row with the same
-- id.  That collides with the (id) index inside the same statement, because
-- the prune's DELETE is not visible to the upsert's INSERT.
--
-- So B6 surfaces as errors rather than as divergence, which is exactly why the
-- comparison vector in calibrate.sh has to carry `errs` as well as `diverged`.
('20','two_ukeys','two unique indexes; the arbiter choice decides correctness','SAFE',
 $$CREATE TABLE b(id int primary key, code int, v int);
   INSERT INTO b SELECT x, 100+x, x*10 FROM generate_series(1,12) x;$$,
 $$SELECT id, code, v FROM b$$, '(id)',
 $$SELECT format('UPDATE b SET v=%s WHERE id=%s',v,i), format('id = %s',i)
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v
   UNION ALL SELECT format('UPDATE b SET code=%s WHERE id=%s',200+i,i),
                   format('id = %s',i)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('id = %s',i)
     FROM generate_series(1,12) i$$,
 '(code)');
