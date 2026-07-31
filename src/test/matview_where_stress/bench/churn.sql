-- Find the row comparison's real break-even against churn.
--
--   psql -v workload=aggregate -f churn.sql
--
-- SPECIALIZE.md gates the row comparison (matview_partial_refresh_optimized) on
-- scope, and admits scope is a proxy: the gate is "right by luck, not argument",
-- because the driver patterns correlate scope with churn (D1 small and
-- high-churn, D3 large and low-churn) rather than because scope is the quantity
-- that decides it.  The quantity that decides it is the fraction of rows in
-- scope whose values actually changed.  This measures that fraction directly.
--
-- Why the existing --mutate knob could not
-- ---------------------------------------
-- bench_mutation writes a column back to itself for seven of the eight
-- workloads:
--
--   aggregate   UPDATE bench.ledger SET amt = amt   WHERE acct = :k AND ...
--   join_agg    UPDATE bench.line   SET qty = qty   WHERE inv_id = :k
--
-- The base row gets a new tuple version, so the refresh does re-read it, but the
-- matview's computed output is bit-identical.  That is churn = 0 with extra
-- steps, and it is the only churn ever measured -- which is why the 27-53% quoted
-- for the row comparison is its best case rather than its expected one.
--
-- What is timed
-- -------------
-- Only the REFRESH.  The mutation runs before the timed region and is not
-- counted, unlike bench/run.sh where mutation and refresh share one pgbench
-- transaction.  That matters here: the mutations below are written for
-- controllability rather than speed (min(id) ... GROUP BY to touch exactly one
-- base row per matview row) and would otherwise dominate what they are meant to
-- vary.
--
-- Churn is a fraction of the MATVIEW rows in scope, not of base rows, because
-- that is what the row comparison sees.  For an aggregate that means touching
-- one base row per group; for a projection it means touching the row itself.
--
-- Two workloads cannot be controlled this way and are skipped rather than
-- reported wrong:
--
--   window     rank() OVER (PARTITION BY region) -- changing one player's score
--              can shift every later rank in the partition, so the achieved
--              churn is >= the requested churn by an amount the workload
--              decides.  It is swept, but the ACHIEVED churn is measured and
--              recorded rather than assumed.
--   recursive  one edge changes an unbounded part of the closure, and the
--              workload already measures nothing else useful.

\set ON_ERROR_STOP on
\pset footer off

CREATE TABLE IF NOT EXISTS public.churn_result(
  run_at       timestamptz DEFAULT now(),
  workload     text,
  span         int,
  scope_rows   bigint,
  churn_pct    int,       -- requested
  churn_actual numeric,   -- measured: matview rows that really changed
  optimized    bool,      -- matview_partial_refresh_optimized
  iters        int,
  us           numeric
);

-- How to change a controlled fraction of the matview rows in scope.  %1$s is
-- the predicate, %2$s the requested churn percentage.
CREATE TABLE IF NOT EXISTS public.bench_churn(id text PRIMARY KEY, sql text);
TRUNCATE public.bench_churn;
INSERT INTO public.bench_churn VALUES
 -- mv row == base row: touch the row itself.  status is a non-key mv column and
 -- the new value cannot collide with the generator's 'S'||(g%5).
 ('projection', $$UPDATE bench.ord SET status = 'C'||(id%7)
                   WHERE (%1$s) AND id %% 100 < %2$s$$),

 -- mv row == one group: touch exactly one base row per selected group, so the
 -- requested fraction of groups is the achieved fraction of matview rows.
 ('aggregate',  $$UPDATE bench.ledger SET amt = amt + 1 WHERE id IN (
                    SELECT min(id) FROM bench.ledger
                     WHERE (%1$s) AND acct %% 100 < %2$s GROUP BY acct)$$),

 ('join_agg',   $$UPDATE bench.line SET qty = qty + 1 WHERE id IN (
                    SELECT min(id) FROM bench.line
                     WHERE (%1$s) AND inv_id %% 100 < %2$s GROUP BY inv_id)$$),

 ('timerange',  $$UPDATE bench.metric SET val = val + 1 WHERE id IN (
                    SELECT min(id) FROM bench.metric
                     WHERE (%1$s) AND series %% 100 < %2$s
                     GROUP BY series, bucket)$$),

 -- mv row == base row, predicate on a non-key column.
 ('nonkey',     $$UPDATE bench.ev SET amt = amt + 1
                   WHERE (%1$s) AND id %% 100 < %2$s$$),

 -- doc is a tsvector over descr, and the mv carries a GIN index on it, so this
 -- is the workload where an avoided write saves the most index maintenance.
 ('expensive',  $$UPDATE bench.product SET descr = descr || ' x'
                   WHERE (%1$s) AND id %% 100 < %2$s$$),

 -- +1 rather than a large jump: a small delta usually preserves the ordering, so
 -- rank() churn stays close to the request.  Close, not equal -- hence
 -- churn_actual.
 ('window',     $$UPDATE bench.player SET score = score + 1
                   WHERE (%1$s) AND id %% 100 < %2$s$$);

-- Snapshot the matview so the achieved churn can be measured rather than
-- assumed.  A requested churn is an input; what the row comparison responds to
-- is what actually differs.
CREATE OR REPLACE FUNCTION public.churn_apply(p_workload text, p_pred text,
                                              p_pct int)
RETURNS numeric LANGUAGE plpgsql AS $fn$
DECLARE tmpl text; changed bigint; total bigint;
BEGIN
  SELECT sql INTO tmpl FROM public.bench_churn WHERE id = p_workload;
  IF tmpl IS NULL THEN RAISE EXCEPTION 'no churn mutation for %', p_workload; END IF;

  DROP TABLE IF EXISTS churn_before;
  EXECUTE 'CREATE TEMP TABLE churn_before AS SELECT * FROM bench.mv WHERE ' || p_pred;
  EXECUTE format(tmpl, p_pred, p_pct);

  -- What the refresh would have to write: rows the view now produces that
  -- differ from what the matview holds.  Computed from the view, not from a
  -- refreshed matview, so measuring it does not perform the work being timed.
  EXECUTE 'SELECT count(*) FROM ('
          '  (SELECT * FROM (' ||
              rtrim(btrim(pg_get_viewdef('bench.mv'::regclass)), ';') ||
          '   ) v WHERE ' || p_pred || ' EXCEPT ALL SELECT * FROM churn_before)'
          ') d' INTO changed;
  SELECT count(*) INTO total FROM churn_before;
  RETURN CASE WHEN total = 0 THEN NULL
              ELSE round(100.0 * changed / total, 1) END;
END $fn$;

-- Time one REFRESH, best of n, with the mutation already applied.
CREATE OR REPLACE FUNCTION public.churn_time(p_pred text, n int) RETURNS numeric
LANGUAGE plpgsql AS $fn$
DECLARE
  t0 timestamptz; best numeric := NULL; us numeric; i int;
  stmt text := 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE ' || p_pred;
BEGIN
  FOR i IN 1..3 LOOP EXECUTE stmt; END LOOP;   -- warm the plan cache
  FOR i IN 1..n LOOP
    t0 := clock_timestamp();
    EXECUTE stmt;
    us := extract(epoch FROM clock_timestamp() - t0) * 1000000;
    IF best IS NULL OR us < best THEN best := us; END IF;
  END LOOP;
  RETURN round(best, 1);
END $fn$;

SELECT set_config('churn.workload', :'workload', false);
SELECT bench_setup(:'workload', 100000, 1000);
VACUUM (ANALYZE) bench.mv;
CHECKPOINT;

DO $outer$
DECLARE
  w bench_workload; span int; pred text; scope bigint; mvrows bigint;
  keymaxv bigint; pct int; opt bool; iters int; us numeric; actual numeric;
BEGIN
  SELECT * INTO w FROM bench_workload WHERE id = current_setting('churn.workload');
  IF NOT EXISTS (SELECT 1 FROM public.bench_churn WHERE id = w.id) THEN
    RAISE NOTICE 'skip %: churn cannot be controlled for this workload '
                 '(see header)', w.id;
    RETURN;
  END IF;
  EXECUTE 'SELECT (' || replace(replace(w.keymax, ':scale', '100000'),
                                ':groups', '1000') || ')::bigint' INTO keymaxv;
  SELECT count(*) INTO mvrows FROM bench.mv;

  FOREACH span IN ARRAY ARRAY[1, 10, 100] LOOP
    CONTINUE WHEN span >= keymaxv;
    IF span = 1 THEN pred := replace(w.pred1, ':k', '1');
    ELSE pred := replace(replace(w.predr, ':k', '1'), ':span', span::text);
    END IF;

    BEGIN EXECUTE 'SELECT count(*) FROM bench.mv WHERE ' || pred INTO scope;
    EXCEPTION WHEN OTHERS THEN scope := NULL; END;
    CONTINUE WHEN scope IS NULL OR scope = 0;
    CONTINUE WHEN scope * 100 / GREATEST(mvrows, 1) >= 90;

    -- 0 is the case every existing measurement already covers, and it is the
    -- row comparison's best case; 100 is its worst.  The interesting question
    -- is where between them it stops paying.
    FOREACH pct IN ARRAY ARRAY[0, 1, 10, 50, 100] LOOP
      FOREACH opt IN ARRAY ARRAY[false, true] LOOP
        -- Rebuild the scope from the view so both settings meet the same data:
        -- the previous iteration's refresh already absorbed its own mutation.
        EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE ' || pred;
        actual := public.churn_apply(w.id, pred, pct);
        EXECUTE 'SET matview_partial_refresh_optimized = ' ||
                CASE WHEN opt THEN 'on' ELSE 'off' END;

        -- The first refresh after the mutation is the one that sees the churn;
        -- churn_time warms with three refreshes, which would absorb it.  So
        -- re-apply the mutation before each counted iteration instead.
        us := NULL;
        FOR iters IN 1..5 LOOP
          DECLARE t0 timestamptz; one numeric;
          BEGIN
            PERFORM public.churn_apply(w.id, pred, pct);
            t0 := clock_timestamp();
            EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE ' || pred;
            one := extract(epoch FROM clock_timestamp() - t0) * 1000000;
            IF us IS NULL OR one < us THEN us := one; END IF;
          END;
        END LOOP;

        INSERT INTO public.churn_result(workload, span, scope_rows, churn_pct,
                                        churn_actual, optimized, iters, us)
          VALUES (w.id, span, scope, pct, actual, opt, 5, round(us, 1));
      END LOOP;
    END LOOP;
    VACUUM (ANALYZE) bench.mv;
  END LOOP;
  RESET matview_partial_refresh_optimized;
END $outer$;

RESET matview_partial_refresh_optimized;
