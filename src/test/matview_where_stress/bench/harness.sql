-- Result store and setup machinery for the partial-refresh benchmark suite.

CREATE TABLE IF NOT EXISTS bench_result(
  run_label   text,
  run_at      timestamptz DEFAULT now(),
  pg_version  text,
  assertions  text,        -- a -O0 --enable-cassert number is not comparable
                           -- with a -O2 one; record it or the run is worthless
  workload    text,
  isolates    text,
  scale       bigint,
  groups      int,
  mv_rows     bigint,
  form        text,        -- conc | bare | full
  predshape   text,        -- key | array | range
  span        int,         -- keys per refresh
  scope_rows  bigint,      -- matview rows the predicate selects
  clients     int,
  overlap     text,        -- disjoint | hot
  mutate      bool,
  sync        text,        -- pgbench commits per refresh; with sync on that WAL
                           -- flush swamps a small refresh
  tps         numeric,
  latency_ms  numeric,
  full_ms     numeric,     -- full-refresh baseline for this (workload, scale)
  us_per_scope_row numeric,
  vs_full_per_row  numeric -- the normalised figure: how many times a full
                           -- rebuild's per-row cost this refresh costs
);

-- How each workload's base data is mutated, when --mutate is on.  Uses :k.
DROP TABLE IF EXISTS bench_mutation;
CREATE TABLE bench_mutation(id text PRIMARY KEY, sql text);
INSERT INTO bench_mutation VALUES
 ('projection', $$UPDATE bench.ord    SET status = 'S'||(:k%5) WHERE id = :k$$),
 ('aggregate',  $$UPDATE bench.ledger SET amt = amt WHERE acct = :k AND id % 97 = 0$$),
 ('join_agg',   $$UPDATE bench.line   SET qty = qty WHERE inv_id = :k$$),
 ('window',     $$UPDATE bench.player SET score = score WHERE region = :k AND id % 97 = 0$$),
 ('expensive',  $$UPDATE bench.product SET descr = descr WHERE id = :k$$),
 ('nonkey',     $$UPDATE bench.ev     SET amt = amt WHERE tenant = :k AND id % 97 = 0$$),
 ('timerange',  $$UPDATE bench.metric SET val = val WHERE bucket = :k AND id % 97 = 0$$),
 ('recursive',  $$UPDATE bench.edge   SET parent = parent WHERE child = :k$$);

-- Build one workload's schema at a given scale, and return the matview row count.
CREATE OR REPLACE FUNCTION bench_setup(p_id text, p_scale bigint, p_groups int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE w bench_workload; n bigint; stmt text; analyze_stmt text;
BEGIN
  SELECT * INTO w FROM public.bench_workload WHERE id = p_id;
  IF w IS NULL THEN RAISE EXCEPTION 'no such workload: %', p_id; END IF;

  EXECUTE 'DROP SCHEMA IF EXISTS bench CASCADE';
  EXECUTE 'CREATE SCHEMA bench';
  EXECUTE 'SET LOCAL search_path = bench, public';

  stmt := replace(replace(w.setup, ':scale', p_scale::text), ':groups', p_groups::text);
  EXECUTE stmt;

  -- Analyze what the setup just built, before anything is planned against it.
  --
  -- Without this the matview is created from a plan made against tables with no
  -- statistics at all, and one workload does not merely plan badly, it fails to
  -- start: 'recursive' asks for a 64 GiB dedup hash table and dies in
  -- ExecInitNode with "out of memory ... request of size 68719476736".  It is
  -- the estimate that is wrong, not the data -- the closure is 1.47M rows and
  -- builds in a couple of seconds once the planner can see the table.
  --
  -- This only affects setup.  Measurements run after settle(), which vacuums
  -- and analyzes everything, so numbers taken before this existed are still
  -- comparable with numbers taken after.
  FOR analyze_stmt IN
    SELECT 'ANALYZE ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname)
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'bench' AND c.relkind IN ('r', 'p')
  LOOP
    EXECUTE analyze_stmt;
  END LOOP;

  EXECUTE 'CREATE MATERIALIZED VIEW bench.mv AS ' || w.viewsql;
  EXECUTE replace(w.idx, ' mv(', ' bench.mv(');
  EXECUTE 'ANALYZE bench.mv';
  EXECUTE 'SELECT count(*) FROM bench.mv' INTO n;
  RETURN n;
END $fn$;

-- Full-refresh baseline, minimum of k.  Everything else is normalised to this.
-- Baselines are cached per (workload, scale, groups): measuring one repeatedly
-- drifts upward (149 -> 245 ms over 8 consecutive full refreshes), and every
-- normalised result divides by it, so it is measured once on a settled instance
-- and reused for the whole run.
CREATE TABLE IF NOT EXISTS bench_baseline_cache(
  workload text, scale bigint, groups int, full_ms numeric,
  PRIMARY KEY (workload, scale, groups));

CREATE OR REPLACE FUNCTION bench_baseline(k int DEFAULT 3)
RETURNS numeric LANGUAGE plpgsql AS $fn$
DECLARE t0 timestamptz; i int; best numeric := NULL; ms numeric;
BEGIN
  REFRESH MATERIALIZED VIEW bench.mv;                    -- warm
  FOR i IN 1..k LOOP
    t0 := clock_timestamp();
    REFRESH MATERIALIZED VIEW bench.mv;
    ms := extract(epoch FROM clock_timestamp() - t0) * 1000;
    IF best IS NULL OR ms < best THEN best := ms; END IF;
  END LOOP;
  RETURN round(best, 3);
END $fn$;

-- How many matview rows a given predicate actually selects, so results can be
-- expressed per row-selected rather than per call.
CREATE OR REPLACE FUNCTION bench_scope_rows(pred text) RETURNS bigint
LANGUAGE plpgsql AS $fn$
DECLARE n bigint;
BEGIN
  EXECUTE 'SELECT count(*) FROM bench.mv WHERE ' || pred INTO n;
  RETURN n;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END $fn$;
