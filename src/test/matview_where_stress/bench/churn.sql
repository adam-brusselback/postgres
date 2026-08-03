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
-- Result
-- ------
-- nonkey/span=100/scope=10000.  Two protocols, because they disagree at one end
-- and the disagreement is the interesting part:
--
--   requested churn         0     5    25    50   100
--   this file             56.1  51.0  35.5  26.7   +7.0
--   arms alternated       54.0  41.7  27.3  17.8   -9.1
--   before the settling   68.5    --    --  18.2  -12.1
--
-- Monotonic decline in all three.  At full churn the row comparison should be a
-- net LOSS on principle -- it does every write the un-optimized path does, and
-- pays a row-wise IS DISTINCT FROM over every column to discover that it must --
-- and two of the three measurements agree, so the +7.0 is the outlier.  Where it
-- comes from is the limitation below.  Break-even is around 60-70%.
--
-- Why this file is the weaker of the two
-- --------------------------------------
-- It measures ONE arm per invocation, so the comparison is between two psql
-- processes that ran minutes apart against separately built data.  That was a
-- deliberate trade -- running both settings in one loop measured the second on a
-- table the first had bloated, and since the order was fixed the bias always
-- landed on the same setting -- but it swaps a bias for a variance, and at the
-- 100% end, where the true difference is a few percent, the variance wins.
--
-- Alternating the arms within one session controls both, and is what the numbers
-- in the second row above come from.  Use this file for the shape of the curve;
-- use an alternating harness for any cell where the two arms are close.
--
-- The 68.5% in the third row is what this file reported before the settling
-- block below existed: it was timing a matview bench_setup had just built, which
-- is the un-optimized arm's worst case and nobody else's.  See heapstate.sh.
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
  -- Which server incarnation measured this row.  The container running these
  -- benchmarks is restarted without warning, and a sweep that straddles a
  -- restart silently mixes two machines: an earlier comparison across a restart
  -- showed a uniform 3-38% "regression" that vanished when both arms were
  -- measured on one boot.  Recording it makes the mix detectable instead of
  -- something the reader has to remember to worry about.
  server_start timestamptz DEFAULT pg_postmaster_start_time(),
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
 -- mv row == base row: touch the row itself.  Appending rather than assigning
 -- because every mutation here is applied once per timed iteration, and an
 -- idempotent one would change nothing after the first -- the iterations would
 -- then be measuring churn 0 while claiming to measure the requested fraction.
 -- Every other mutation below is an increment for the same reason.
 ('projection', $$UPDATE bench.ord SET status = status || 'x'
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

\if :{?optimized}
\else
\echo 'usage: psql -v workload=<w> -v optimized=<true|false> -f churn.sql'
\quit
\endif

SELECT set_config('churn.workload', :'workload', false);
-- Passed through a GUC, not interpolated: psql does not substitute :vars
-- inside a dollar-quoted block, so the DO block below would see the literal
-- text and fail to parse.
SELECT set_config('churn.optimized', :'optimized', false);
SELECT set_config('churn.span', :'span', false);
SELECT set_config('churn.pct', :'pct', false);
\if :setup
SELECT bench_setup(:'workload', 100000, 1000);
\endif
-- Between cells, not just at setup.  Without it the arm that rewrites every
-- row in every cell arrives at the later cells far more bloated than the arm
-- that skips writes, and the gap is read as the optimization getting better
-- with churn when it is the table getting worse.  VACUUM cannot run inside the
-- DO block, which is why the cell loop was moved out here.
VACUUM (ANALYZE) bench.mv;
CHECKPOINT;

-- Resolve the cell and stash it, so the sampling loop below can live at file
-- level.  It has to: each timed refresh needs a VACUUM in front of it and
-- VACUUM cannot run inside a DO block.
--
-- Without that, the five samples run back to back and every one after the first
-- is measured on a heap the previous one bloated -- and only the un-optimized
-- arm bloats it, because only the un-optimized arm writes.  Sampling that way
-- reported 68.5% here where a VACUUM before each sample gives 54.0%.  Settling
-- the heap first (above) recovered 3 of those 11 points; the rest is this.
--
-- A GUC rather than a temp table because psql has no loop: the five
-- VACUUM/sample pairs are written out literally below and each one is its own
-- statement, so the cell has to be readable from any of them.
DO $prep$
DECLARE
  w bench_workload; span int; pred text; scope bigint; mvrows bigint;
  keymaxv bigint;
BEGIN
  -- Every one of these, up front.  churn_sample() reads them in its DECLARE
  -- section, which runs before its skip check, so a GUC that is merely unset on
  -- the skip path is an ERROR on the skip path rather than a skip.
  PERFORM set_config('churn.skip',  '1', false);
  PERFORM set_config('churn.pred',  '',  false);
  PERFORM set_config('churn.scope', '0', false);
  PERFORM set_config('churn.mv',    '0', false);

  SELECT * INTO w FROM bench_workload WHERE id = current_setting('churn.workload');
  IF NOT EXISTS (SELECT 1 FROM public.bench_churn WHERE id = w.id) THEN
    RAISE NOTICE 'skip %: churn cannot be controlled for this workload '
                 '(see header)', w.id;
    RETURN;
  END IF;
  EXECUTE 'SELECT (' || replace(replace(w.keymax, ':scale', '100000'),
                                ':groups', '1000') || ')::bigint' INTO keymaxv;
  SELECT count(*) INTO mvrows FROM bench.mv;
  span := current_setting('churn.span')::int;
  IF span >= keymaxv THEN RETURN; END IF;
  IF span = 1 THEN pred := replace(w.pred1, ':k', '1');
  ELSE pred := replace(replace(w.predr, ':k', '1'), ':span', span::text);
  END IF;
  BEGIN EXECUTE 'SELECT count(*) FROM bench.mv WHERE ' || pred INTO scope;
  EXCEPTION WHEN OTHERS THEN scope := NULL; END;
  IF scope IS NULL OR scope = 0 THEN RETURN; END IF;
  IF scope * 100 / GREATEST(mvrows, 1) >= 90 THEN RETURN; END IF;

  PERFORM set_config('churn.pred',  pred,          false);
  PERFORM set_config('churn.scope', scope::text,   false);
  PERFORM set_config('churn.mv',    mvrows::text,  false);
  PERFORM set_config('churn.skip',  '0',           false);
END $prep$;

-- Settle the heap before anything is timed.
--
-- bench_setup() builds the matview with CREATE TABLE AS, which leaves it with
-- no free space in the FSM and no page dirtied since the last checkpoint.  The
-- optimized=off arm is the only arm that writes, so it -- and only it -- then
-- pays relation extension and a full-page image per page on its first pass.
-- Both costs are one-offs that a matview being refreshed on a schedule does not
-- pay, and charging them to the un-optimized arm inflates every ratio here.
--
-- bench/heapstate.sh measures the size of it: on nonkey/span=100 the off arm
-- costs 88.9ms on the first refresh after bench_setup, 63.1ms by the eighth,
-- and 54.9ms once the heap is settled and vacuumed -- while the on arm sits at
-- 24-27ms throughout and its heap never grows at all.  Sampling the first eight
-- refreshes, which is what this file used to do, reported 68.5% at churn 0
-- where the settled answer is 54.0%.
--
-- Ten refreshes is past the knee on every cell measured.  They run at the
-- session default for the GUCs, deliberately: whichever arm this invocation is
-- about, it should meet a heap that the OTHER arm's write pattern did not
-- shape.
-- Reads the cell $prep$ resolved rather than resolving it again.  Deriving the
-- predicate here independently meant this block ran against whatever matview
-- bench.mv happened to hold: invoked with setup=false after a different
-- workload, it refreshed with a predicate naming a column that does not exist
-- and the file died before reaching the skip that would have handled it.
DO $settle$
DECLARE i int;
BEGIN
  IF current_setting('churn.skip') = '1' THEN RETURN; END IF;
  FOR i IN 1..10 LOOP
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE '
            || current_setting('churn.pred');
  END LOOP;
END $settle$;
VACUUM (ANALYZE) bench.mv;
CHECKPOINT;

-- One (mutate, refresh) sample.  Appends rather than returning, so the five
-- call sites below need no plumbing.
--
-- The mutation is re-applied inside every sample: the first refresh after a
-- mutation is the only one that sees the churn, so a sample that skipped it
-- would measure churn 0 while claiming the requested fraction.
DROP TABLE IF EXISTS churn_acc;
CREATE TEMP TABLE churn_acc(us numeric, actual numeric);

CREATE OR REPLACE FUNCTION public.churn_sample(p_warm bool DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  t0 timestamptz; act numeric;
  w    text := current_setting('churn.workload');
  pred text := current_setting('churn.pred');
  pct  int  := current_setting('churn.pct')::int;
  stmt text;
BEGIN
  IF current_setting('churn.skip') = '1' THEN RETURN; END IF;
  stmt := 'REFRESH MATERIALIZED VIEW CONCURRENTLY bench.mv WHERE ' || pred;

  -- BOTH GUCs.  use_optimized in matview.c is
  --     matview_partial_refresh_optimized
  -- so with querytree off the optimized flag changes nothing: both arms emit
  -- byte-identical SQL, the cache key matches so there is not even a replan,
  -- and the sweep reports a tidy ~0% across every churn level for an
  -- optimization it never enabled.  That is what this file did on its first
  -- clean run, and the answer looked entirely plausible.
  EXECUTE 'SET matview_partial_refresh_optimized = ' ||
          CASE WHEN current_setting('churn.optimized')::bool THEN 'on' ELSE 'off' END;

  act := public.churn_apply(w, pred, pct);
  t0 := clock_timestamp();
  EXECUTE stmt;
  IF NOT p_warm THEN
    INSERT INTO churn_acc
      VALUES (extract(epoch FROM clock_timestamp()-t0)*1000000, act);
  END IF;
END $fn$;

-- Warm the plan cache for this arm's statement text, and let the first
-- post-settle refresh absorb whatever the settling loop left behind.
SELECT public.churn_sample(true);
SELECT public.churn_sample(true);
SELECT public.churn_sample(true);

-- Five samples, each against a freshly vacuumed heap.  This is the arm's floor
-- rather than its average, which is the conservative choice: it is the
-- un-optimized arm that a dirty heap punishes, so anything less than a VACUUM
-- here flatters the optimization.
VACUUM (ANALYZE) bench.mv;
SELECT public.churn_sample();
VACUUM (ANALYZE) bench.mv;
SELECT public.churn_sample();
VACUUM (ANALYZE) bench.mv;
SELECT public.churn_sample();
VACUUM (ANALYZE) bench.mv;
SELECT public.churn_sample();
VACUUM (ANALYZE) bench.mv;
SELECT public.churn_sample();

INSERT INTO public.churn_result(workload, span, scope_rows, churn_pct,
                                churn_actual, optimized, iters, us)
SELECT current_setting('churn.workload'),
       current_setting('churn.span')::int,
       current_setting('churn.scope')::bigint,
       current_setting('churn.pct')::int,
       round(avg(actual), 1),
       current_setting('churn.optimized')::bool,
       count(*), round(min(us), 1)
  FROM churn_acc HAVING count(*) > 0;


RESET matview_partial_refresh_optimized;
