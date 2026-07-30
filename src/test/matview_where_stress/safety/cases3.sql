DELETE FROM probe_case WHERE ord >= 41;
UPDATE probe_case
   SET pred = $$id IN (SELECT id FROM probe.f WHERE did = 5)$$
 WHERE id = 'dim_change_fixed';

INSERT INTO probe_case VALUES
-- same view + same predicate as case 26, only the mutation differs
(41,'win_part_and_lo','PARTITION BY g, pred g AND score>500, score LOWERED','UNSAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, '(id)',
 $$UPDATE b SET score = 501 WHERE id = 55$$, $$g = (55 % 10) AND score > 500$$),

-- and the identical pair with the whole-partition predicate, for contrast
(42,'win_part_lo','PARTITION BY g, pred on g only, score LOWERED','SAFE',
 $$CREATE TABLE b(id int primary key, g int, score int);
   INSERT INTO b SELECT x, x%10, (x*7919)%1000 FROM generate_series(1,300) x;$$,
 $$SELECT id, g, score, rank() OVER (PARTITION BY g ORDER BY score DESC, id) AS rnk FROM b$$, '(id)',
 $$UPDATE b SET score = 1 WHERE id = 55$$, $$g = (55 % 10)$$);
