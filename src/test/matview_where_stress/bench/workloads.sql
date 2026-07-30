-- Representative workloads for REFRESH MATERIALIZED VIEW ... WHERE ...
--
-- Eight, drawn from USE-CASES.md, chosen so each isolates a DIFFERENT cost
-- driver rather than a different business domain.  Adding a ninth is only worth
-- it if it isolates something none of these do.
--
--   w1 projection     cheapest possible shape; isolates fixed cost
--   w2 aggregate      GROUP BY, predicate on the grouping key
--   w3 join_agg       join + GROUP BY; the shape the on-list benchmark used
--   w4 window         rank() OVER (PARTITION BY); push-down through WindowAgg,
--                     and blast radius forces partition-sized scope
--   w5 expensive      5-way-ish join + to_tsvector + GIN; per-row cost and
--                     index maintenance dominate, not the refresh machinery
--   w6 nonkey         predicate on an indexed NON-key column; the shape whose
--                     disjoint scopes should refresh in parallel
--   w7 timerange      range predicate over time buckets; large scope, bare form
--   w8 recursive      predicate may not push into the recursive term at all
--
-- :scale  = base table rows
-- :groups = distinct key values (so scope per key = scale/groups)

DROP TABLE IF EXISTS bench_workload;
CREATE TABLE bench_workload(
  ord      int,
  id       text PRIMARY KEY,
  isolates text,
  setup    text,   -- may use :scale and :groups
  viewsql  text,
  idx      text,   -- indexes on the matview, semicolon separated
  keycol   text,   -- what the predicate keys on
  keymax   text,   -- SQL expression for the largest legal key value
  pred1    text,   -- single key   (row trigger)
  predn    text,   -- array of n   (statement trigger / drain); uses :k and :span
  predr    text    -- range        (scheduled window);          uses :k and :span
);

INSERT INTO bench_workload VALUES
(1,'projection','fixed cost floor',
 $$CREATE TABLE ord(id bigint primary key, cust int, status text, updated timestamptz);
   INSERT INTO ord SELECT g, g % :groups, 'S'||(g%5), now() FROM generate_series(1,:scale) g;
   CREATE INDEX ON ord(cust);$$,
 $$SELECT id, cust, status FROM ord$$,
 $$CREATE UNIQUE INDEX ON mv(id); CREATE INDEX ON mv(cust)$$,
 'id', ':scale',
 $$id = :k$$, $$id = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$id BETWEEN :k AND :k + :span - 1$$),

(2,'aggregate','GROUP BY, predicate on the grouping key',
 $$CREATE TABLE ledger(id bigint primary key, acct int, amt numeric);
   INSERT INTO ledger SELECT g, g % :groups, (g%1000)::numeric FROM generate_series(1,:scale) g;
   CREATE INDEX ON ledger(acct);$$,
 $$SELECT acct, sum(amt) AS total, count(*) AS n, max(amt) AS mx FROM ledger GROUP BY acct$$,
 $$CREATE UNIQUE INDEX ON mv(acct)$$,
 'acct', ':groups',
 $$acct = :k$$, $$acct = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$acct BETWEEN :k AND :k + :span - 1$$),

(3,'join_agg','join + GROUP BY; the on-list benchmark shape',
 $$CREATE TABLE inv(id bigint primary key, cust int);
   CREATE TABLE line(id bigint primary key, inv_id bigint, qty int, price numeric, tax numeric);
   INSERT INTO inv SELECT g, g % 97 FROM generate_series(1,:groups) g;
   INSERT INTO line SELECT g, (g % :groups)+1, (g%9)+1, (g%50)+1, 0.2 FROM generate_series(1,:scale) g;
   CREATE INDEX ON line(inv_id);$$,
 $$SELECT i.id AS inv_id, i.cust, sum(l.qty*l.price) AS net,
          sum(l.qty*l.price*l.tax) AS tax, count(*) AS n
     FROM inv i JOIN line l ON l.inv_id = i.id GROUP BY i.id, i.cust$$,
 $$CREATE UNIQUE INDEX ON mv(inv_id); CREATE INDEX ON mv(cust)$$,
 'inv_id', ':groups',
 $$inv_id = :k$$, $$inv_id = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$inv_id BETWEEN :k AND :k + :span - 1$$),

(4,'window','push-down through WindowAgg; partition-sized scope',
 $$CREATE TABLE player(id bigint primary key, region int, score int);
   INSERT INTO player SELECT g, g % :groups, (g*7919)%1000000 FROM generate_series(1,:scale) g;
   CREATE INDEX ON player(region);$$,
 $$SELECT id, region, score,
          rank() OVER (PARTITION BY region ORDER BY score DESC, id) AS rnk FROM player$$,
 $$CREATE UNIQUE INDEX ON mv(id); CREATE INDEX ON mv(region)$$,
 'region', ':groups',
 $$region = :k$$, $$region = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$region BETWEEN :k AND :k + :span - 1$$),

(5,'expensive','per-row expression + GIN index maintenance dominate',
 $$CREATE TABLE brand(id int primary key, name text);
   CREATE TABLE product(id bigint primary key, brand int, name text, descr text);
   INSERT INTO brand SELECT g, 'brand '||g FROM generate_series(1,97) g;
   INSERT INTO product SELECT g, (g%97)+1, 'product '||g,
     'a description with words '||g||' and more filler text for the vector'
     FROM generate_series(1,:scale) g;$$,
 $$SELECT p.id, p.name, b.name AS brand,
          to_tsvector('english', p.name||' '||coalesce(p.descr,'')||' '||b.name) AS doc
     FROM product p JOIN brand b ON b.id = p.brand$$,
 $$CREATE UNIQUE INDEX ON mv(id); CREATE INDEX ON mv USING gin(doc)$$,
 'id', ':scale',
 $$id = :k$$, $$id = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$id BETWEEN :k AND :k + :span - 1$$),

(6,'nonkey','indexed NON-key predicate; disjoint scopes should run in parallel',
 $$CREATE TABLE ev(id bigint primary key, tenant int, amt numeric);
   INSERT INTO ev SELECT g, g % :groups, (g%500)::numeric FROM generate_series(1,:scale) g;
   CREATE INDEX ON ev(tenant);$$,
 $$SELECT id, tenant, amt FROM ev$$,
 $$CREATE UNIQUE INDEX ON mv(id); CREATE INDEX ON mv(tenant)$$,
 'tenant', ':groups',
 $$tenant = :k$$, $$tenant = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$tenant BETWEEN :k AND :k + :span - 1$$),

(7,'timerange','range predicate over time buckets; large scope, bare form',
 $$CREATE TABLE metric(id bigint primary key, series int, bucket int, val float8);
   INSERT INTO metric SELECT g, g % 500, g % :groups, (g%977)::float8 FROM generate_series(1,:scale) g;
   CREATE INDEX ON metric(bucket);$$,
 $$SELECT series, bucket, avg(val) AS a, max(val) AS m, count(*) AS n
     FROM metric GROUP BY series, bucket$$,
 $$CREATE UNIQUE INDEX ON mv(series,bucket); CREATE INDEX ON mv(bucket)$$,
 'bucket', ':groups',
 $$bucket = :k$$, $$bucket = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$bucket BETWEEN :k AND :k + :span - 1$$),

(8,'recursive','predicate may not push into the recursive term at all',
 $$CREATE TABLE edge(child int, parent int, primary key(child,parent));
   INSERT INTO edge SELECT g, g/2 FROM generate_series(2,:scale) g;
   CREATE INDEX ON edge(parent);$$,
 $$WITH RECURSIVE r AS (
      SELECT child, parent FROM edge
      UNION
      SELECT r.child, e.parent FROM r JOIN edge e ON e.child = r.parent)
    SELECT child, parent FROM r$$,
 $$CREATE UNIQUE INDEX ON mv(child,parent); CREATE INDEX ON mv(child)$$,
 'child', ':scale',
 $$child = :k$$, $$child = ANY(ARRAY(SELECT generate_series(:k, :k + :span - 1)))$$, $$child BETWEEN :k AND :k + :span - 1$$);
