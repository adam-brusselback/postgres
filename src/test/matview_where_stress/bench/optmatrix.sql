-- Measure one optimisation candidate across the whole workload matrix.
--
--   psql -v workload=projection -f optmatrix.sql
--
-- Everything here runs inside one backend with no client round trip and no
-- commit, so it measures the refresh and not the transaction around it.  That
-- is the right frame for a candidate that changes what happens inside a
-- refresh; it is the wrong frame for deciding what a user experiences, which
-- is what bench/run.sh is for.
--
-- The predicate is bound as a parameter, not interpolated, because that is
-- what a trigger or a drain issues and it is the path bench/run.sh does not
-- measure.

\set ON_ERROR_STOP on
\pset footer off

CREATE TABLE IF NOT EXISTS public.opt_result(
  run_at     timestamptz DEFAULT now(),
  workload   text,
  predshape  text,
  span       int,
  scope_rows bigint,
  path       text,        -- always 'querytree' now; kept so rows taken
                          -- before the text path was deleted still compare
  variant    text,        -- what is being varied
  iters      int,
  us         numeric      -- best of iters, microseconds
);

-- Time one refresh, best of n, with the predicate bound rather than pasted.
CREATE OR REPLACE FUNCTION public.opt_time(pred text, n int) RETURNS numeric
LANGUAGE plpgsql AS $fn$
DECLARE
  t0 timestamptz; best numeric := NULL; us numeric; i int;
  stmt text := 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE ' || pred;
BEGIN
  EXECUTE stmt USING 1;                                  -- warm
  EXECUTE stmt USING 1;                                  -- and again: the plan
  EXECUTE stmt USING 1;                                  -- cache needs a few
  EXECUTE stmt USING 1;                                  -- goes before it will
  EXECUTE stmt USING 1;                                  -- consider a generic plan
  EXECUTE stmt USING 1;
  FOR i IN 1..n LOOP
    t0 := clock_timestamp();
    EXECUTE stmt USING i;
    us := extract(epoch FROM clock_timestamp() - t0) * 1000000;
    IF best IS NULL OR us < best THEN best := us; END IF;
  END LOOP;
  RETURN round(best, 1);
END $fn$;

SELECT set_config('opt.workload', :'workload', false);
SELECT bench_setup(:'workload', 100000, 1000);
VACUUM (ANALYZE) bench.mv;
CHECKPOINT;

DO $outer$
DECLARE
  w        bench_workload;
  shape    text; span int; pred text; arr text; scope bigint;
  mode     text; iters int; us numeric; mvrows bigint;
  keymaxv  bigint;
BEGIN
  SELECT * INTO w FROM bench_workload WHERE id = current_setting('opt.workload');
  EXECUTE 'SELECT (' || replace(replace(w.keymax, ':scale', '100000'),
                                 ':groups', '1000') || ')::bigint'
    INTO keymaxv;
  SELECT count(*) INTO mvrows FROM bench.mv;

  FOREACH shape IN ARRAY ARRAY['key','array','range'] LOOP
    FOREACH span IN ARRAY ARRAY[1,10,100] LOOP
      CONTINUE WHEN shape = 'key' AND span <> 1;
      CONTINUE WHEN span >= keymaxv;
      CONTINUE WHEN shape = 'array' AND span > 100;

      pred := CASE shape WHEN 'key' THEN w.pred1
                         WHEN 'array' THEN w.predn
                         ELSE w.predr END;
      -- :k becomes the bound $1; :span is a constant; :arraylit expands to a
      -- literal array, NOT ARRAY(SELECT generate_series(...)) -- that form is
      -- an InitPlan, which blocks equivalence-class propagation across a join
      -- and seq-scans the other side.  bench/run.sh avoids it deliberately and
      -- measuring it here would compare against a shape nothing else uses.
      SELECT 'ARRAY[' || string_agg('$1+' || g, ',') || ']'
        INTO arr FROM generate_series(0, span - 1) g;
      pred := replace(replace(replace(pred, ':arraylit', arr),
                              ':span', span::text), ':k', '$1');

      BEGIN
        EXECUTE 'SELECT count(*) FROM bench.mv WHERE ' ||
                replace(pred, '$1', '1') INTO scope;
      EXCEPTION WHEN OTHERS THEN scope := NULL;
      END;
      CONTINUE WHEN scope IS NULL OR scope = 0;
      CONTINUE WHEN scope * 100 / GREATEST(mvrows, 1) >= 90;

      FOREACH mode IN ARRAY ARRAY['auto','force_generic_plan'] LOOP
        EXECUTE 'SET plan_cache_mode = ' || mode;
        -- aim for ~200 ms of measurement, between 3 and 60 iterations
        iters := 20;
        us := public.opt_time(pred, 3);
        iters := GREATEST(3, LEAST(60, (200000 / GREATEST(us, 1))::int));
        us := public.opt_time(pred, iters);
        INSERT INTO public.opt_result(workload, predshape, span, scope_rows, path,
                               variant, iters, us)
          VALUES (w.id, shape, span, scope, 'querytree', mode, iters, us);
      END LOOP;
      RESET plan_cache_mode;
    END LOOP;
  END LOOP;
END $outer$;

RESET plan_cache_mode;
