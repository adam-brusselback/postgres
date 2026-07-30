DELETE FROM probe_exh WHERE id IN ('proj_nonkey_union','distincton_total','proj_nonkey_new');
INSERT INTO probe_exh VALUES

-- identical to proj_nonkey except the driver names BOTH the old and new group
('11','proj_nonkey_union','projection, pred covers OLD ∪ NEW group','SAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%4, x FROM generate_series(1,12) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('g = %s OR g = %s',i%4,ng)
     FROM generate_series(1,12) i, generate_series(0,4) ng
   UNION ALL SELECT format('UPDATE b SET v=%s WHERE id=%s',v,i), format('g = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,99]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('g = %s',i%4)
     FROM generate_series(1,12) i$$),

-- the NEW-only predicate an AFTER UPDATE row trigger would naturally produce
('12','proj_nonkey_new','projection, pred names only the NEW group','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, v int);
   INSERT INTO b SELECT x, x%4, x FROM generate_series(1,12) x;$$,
 $$SELECT id, g, v FROM b$$, '(id)',
 $$SELECT format('UPDATE b SET g=%s WHERE id=%s',ng,i), format('g = %s',ng)
     FROM generate_series(1,12) i, generate_series(0,4) ng$$),

-- identical to distincton except the ORDER BY is a TOTAL order
('13','distincton_total','DISTINCT ON (k) with a total ORDER BY','SAFE',
 $$CREATE TABLE b(id int primary key, k int, ts int, v int);
   INSERT INTO b SELECT x, x%4, x, x*3 FROM generate_series(1,12) x;$$,
 $$SELECT DISTINCT ON (k) k, ts, v FROM b ORDER BY k, ts DESC, id$$, '(k)',
 $$SELECT format('UPDATE b SET ts=%s WHERE id=%s',v,i), format('k = %s',i%4)
     FROM generate_series(1,12) i, unnest(ARRAY[0,6,99]) v
   UNION ALL SELECT format('DELETE FROM b WHERE id=%s',i), format('k = %s',i%4)
     FROM generate_series(1,12) i
   UNION ALL SELECT format('UPDATE b SET k=%s WHERE id=%s',nk,i), format('k = %s OR k = %s',i%4,nk)
     FROM generate_series(1,12) i, generate_series(0,3) nk$$);
