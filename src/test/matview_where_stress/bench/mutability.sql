-- Size the mutability specialisations before implementing them.
--
--   psql -v workload=aggregate -f mutability.sql
--
-- SPECIALIZE.md puts append_only/no_delete first in the build order on the
-- grounds that they are the only specialisation that removes work from the
-- phase that is 87% of a large refresh -- and admits the saving has never been
-- measured.  This measures it with nothing implemented: the statement forms are
-- written out by hand, exactly as refresh_by_direct_modification() would emit
-- them, and timed against each other.
--
-- That ordering matters.  A reloption is user-visible surface that is hard to
-- withdraw, and getting it wrong is silent corruption rather than a slow query.
-- The saving has to be worth that before the declaration is designed, not after.
--
-- Four forms, so the saving is attributed rather than just observed:
--
--   A     fused upsert + prune, materialised CTE     optimized = off
--   Aopt  A, with the row comparison on the UPDATE    optimized = on  <-- baseline
--   B     A minus the prune                           no_delete
--   Bopt  Aopt minus the prune                        no_delete + row comparison
--   B2    B minus the CTE                             new_data is read once, so
--                                                     it need not be a tuplestore
--   C     B2 with DO NOTHING                          append_only
--
-- Aopt is the baseline, not A.  Measured against A at zero churn, DO NOTHING
-- looks enormous -- but the row comparison ALREADY skips every write at zero
-- churn, and it is already implemented.  Quoting C against A would credit
-- append_only with a saving the current code delivers on its own.  The
-- decision-relevant steps are Aopt->Bopt (what dropping the prune buys once the
-- comparison is on) and Bopt->C (what DO NOTHING buys on top of that).
--
-- The row-locking SELECT runs in all four.  SPECIALIZE.md 3e argues it must
-- never be specialised on any axis -- mutation M3 removed it and produced 45
-- lost updates -- so leaving it in every form keeps this comparison about the
-- DML and nothing else.  It also has to be in the denominator: a saving of S
-- microseconds is S/(lock+DML) of the refresh, not S/DML, and quoting the
-- second number would overstate every result here.
--
-- Everything targets bench.mvt, a plain heap cloned from bench.mv with the same
-- columns and the same indexes, because a matview rejects both direct DML and
-- SELECT ... FOR UPDATE outside matview-maintenance mode -- which is a
-- permission check in the rewriter, not a storage difference.  A matview is a
-- heap; the same statements against the same heap with the same indexes do the
-- same work.  Cloning the indexes is not optional: SPECIALIZE.md has the row
-- comparison worth 27-53% with a covering index and nothing at all without one,
-- so a clone missing them would measure a different question.

\set ON_ERROR_STOP on
\pset footer off

CREATE TABLE IF NOT EXISTS public.mut_result(
  run_at     timestamptz DEFAULT now(),
  workload   text,
  span       int,
  scope_rows bigint,
  mv_rows    bigint,
  form       text,      -- A | B | B2 | C
  iters      int,
  us         numeric    -- best of iters
);

-- Reproduce the DML that refresh_by_direct_modification() would build, in the
-- four mutability variants.  Derived from the live catalog the same way the C
-- code derives it -- arbiter from the unique index, SET list from the non-key
-- attributes, anti-join operator from indnullsnotdistinct -- so a change to the
-- matview's shape moves this in step with the implementation instead of
-- silently describing an older one.
CREATE OR REPLACE FUNCTION public.mut_stmt(p_form text, p_pred text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  mvoid     oid := 'bench.mvt'::regclass;
  idx       pg_index;
  viewsql   text;
  keycols   text;
  setclause text;
  mvcols    text;
  exccols   text;
  joinclause text;
  antiop    text;
  do_prune  bool;
  use_cte   bool;
  conflict  text;
  src       text;
  body      text;
BEGIN
  SELECT * INTO idx FROM pg_index
   WHERE indrelid = mvoid AND indisunique AND indisvalid
   ORDER BY indisprimary DESC, indexrelid LIMIT 1;
  IF idx IS NULL THEN RAISE EXCEPTION 'bench.mvt has no usable unique index'; END IF;

  antiop := CASE WHEN idx.indnullsnotdistinct THEN 'IS NOT DISTINCT FROM' ELSE '=' END;
  viewsql := rtrim(btrim(pg_get_viewdef('bench.mv'::regclass)), ';');

  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord),
         string_agg('nd.' || quote_ident(a.attname) || ' ' || antiop ||
                    ' mv.' || quote_ident(a.attname), ' AND ' ORDER BY k.ord)
    INTO keycols, joinclause
    FROM unnest(idx.indkey[0:idx.indnkeyatts-1]) WITH ORDINALITY k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = mvoid AND a.attnum = k.attnum;

  SELECT string_agg(quote_ident(a.attname) || ' = EXCLUDED.' ||
                    quote_ident(a.attname), ', ' ORDER BY a.attnum),
         -- The ON CONFLICT DO UPDATE ... WHERE refers to the target table by
         -- its implicit alias, which is the relation's unqualified name -- what
         -- matview.c calls matview_alias.  Here the target is bench.mvt.
         string_agg('mvt.' || quote_ident(a.attname), ', ' ORDER BY a.attnum),
         string_agg('EXCLUDED.' || quote_ident(a.attname), ', ' ORDER BY a.attnum)
    INTO setclause, mvcols, exccols
    FROM pg_attribute a
   WHERE a.attrelid = mvoid AND a.attnum > 0 AND NOT a.attisdropped
     AND NOT (a.attnum = ANY (idx.indkey[0:idx.indnkeyatts-1]));

  -- Every column is a key column, so there is nothing for DO UPDATE to set and
  -- refresh_by_direct_modification() emits DO NOTHING (has_non_key_cols false).
  -- Several forms then collapse onto each other, which is an answer about that
  -- matview shape, not a case to skip.

  do_prune := p_form IN ('A', 'Aopt');
  use_cte  := p_form IN ('A', 'Aopt', 'B', 'Bopt');

  conflict := CASE
    WHEN setclause IS NULL          THEN 'NOTHING'
    WHEN p_form = 'C'               THEN 'NOTHING'
    WHEN p_form IN ('Aopt','Bopt')  THEN
      -- what matview_partial_refresh_optimized = on emits today
      format('UPDATE SET %s WHERE (%s) IS DISTINCT FROM (%s)',
             setclause, mvcols, exccols)
    ELSE format('UPDATE SET %s', setclause)
  END;

  IF p_form NOT IN ('A','Aopt','B','Bopt','B2','C') THEN
    RAISE EXCEPTION 'unknown form: %', p_form;
  END IF;

  IF use_cte THEN
    src := format('WITH new_data AS MATERIALIZED ( '
                  '  SELECT * FROM (%s) mv WHERE (%s) ORDER BY %s '
                  '), upsert AS ( '
                  '  INSERT INTO bench.mvt SELECT * FROM new_data '
                  '  ON CONFLICT (%s) DO %s RETURNING 1 ) ',
                  viewsql, p_pred, keycols, keycols, conflict);
    IF do_prune THEN
      body := src || format(
        ', pruned AS ( DELETE FROM bench.mvt mv WHERE (%s) AND NOT EXISTS ( '
        '  SELECT 1 FROM new_data nd WHERE %s ) RETURNING 1 ) '
        'SELECT (SELECT pg_catalog.count(*) FROM upsert) '
        '     + (SELECT pg_catalog.count(*) FROM pruned)', p_pred, joinclause);
    ELSE
      body := src || 'SELECT (SELECT pg_catalog.count(*) FROM upsert)';
    END IF;
  ELSE
    body := format('INSERT INTO bench.mvt SELECT * FROM (%s) mv WHERE (%s) '
                   'ORDER BY %s ON CONFLICT (%s) DO %s',
                   viewsql, p_pred, keycols, keycols, conflict);
  END IF;

  RETURN body;
END $fn$;

-- The locking SELECT, identical in every form.  See the header.
CREATE OR REPLACE FUNCTION public.mut_lock(p_pred text)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE mvoid oid := 'bench.mvt'::regclass; idx pg_index; keycols text;
BEGIN
  SELECT * INTO idx FROM pg_index
   WHERE indrelid = mvoid AND indisunique AND indisvalid
   ORDER BY indisprimary DESC, indexrelid LIMIT 1;
  SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY k.ord) INTO keycols
    FROM unnest(idx.indkey[0:idx.indnkeyatts-1]) WITH ORDINALITY k(attnum, ord)
    JOIN pg_attribute a ON a.attrelid = mvoid AND a.attnum = k.attnum;
  RETURN format('SELECT 1 FROM bench.mvt mv WHERE (%s) ORDER BY %s FOR UPDATE',
                p_pred, keycols);
END $fn$;

-- Clone bench.mv into the plain heap bench.mvt, indexes and all.
--
-- Rebuilt before every form so each one starts from the same rows with the same
-- physical layout.  Without that, form A's prune and upsert leave dead tuples
-- that form B then reads through, and the later form looks worse for a reason
-- that has nothing to do with the statement being measured.
CREATE OR REPLACE FUNCTION public.mut_clone() RETURNS void
LANGUAGE plpgsql AS $fn$
DECLARE d text; n int := 0;
BEGIN
  DROP TABLE IF EXISTS bench.mvt;
  CREATE TABLE bench.mvt AS SELECT * FROM bench.mv;
  FOR d IN SELECT pg_get_indexdef(indexrelid) FROM pg_index
            WHERE indrelid = 'bench.mv'::regclass AND indisvalid
  LOOP
    n := n + 1;
    -- pg_get_indexdef qualifies the table but not the index name, so the table
    -- is redirected and the index renamed to something that cannot collide.
    d := replace(d, ' ON bench.mv ', ' ON bench.mvt ');
    d := regexp_replace(d, '^CREATE( UNIQUE)? INDEX \S+',
                        'CREATE\1 INDEX mvt_i' || n);
    EXECUTE d;
  END LOOP;
  IF n = 0 THEN
    RAISE EXCEPTION 'bench.mv has no indexes to clone; the comparison would '
                    'measure a different question (see header)';
  END IF;
  ANALYZE bench.mvt;
END $fn$;

-- Time lock + DML, best of n.  Runs in the caller's transaction and does not
-- commit, so this is refresh cost and not commit cost -- the 12x that
-- bench/run.sh carries per refresh would drown the difference being measured.
CREATE OR REPLACE FUNCTION public.mut_time(p_form text, p_pred text, n int)
RETURNS numeric LANGUAGE plpgsql AS $fn$
DECLARE
  lock_stmt text := public.mut_lock(p_pred);
  dml_stmt  text := public.mut_stmt(p_form, p_pred);
  t0 timestamptz; best numeric := NULL; us numeric; i int;
BEGIN
  FOR i IN 1..3 LOOP                       -- warm the plans before counting
    EXECUTE lock_stmt; EXECUTE dml_stmt;
  END LOOP;
  FOR i IN 1..n LOOP
    t0 := clock_timestamp();
    EXECUTE lock_stmt;
    EXECUTE dml_stmt;
    us := extract(epoch FROM clock_timestamp() - t0) * 1000000;
    IF best IS NULL OR us < best THEN best := us; END IF;
  END LOOP;
  RETURN round(best, 1);
END $fn$;

SELECT set_config('mut.workload', :'workload', false);
SELECT bench_setup(:'workload', 100000, 1000);
VACUUM (ANALYZE) bench.mv;
CHECKPOINT;

DO $outer$
DECLARE
  w bench_workload; span int; pred text; arr text; scope bigint; mvrows bigint;
  keymaxv bigint; form text; iters int; us numeric; diverged bigint;
BEGIN
  SELECT * INTO w FROM bench_workload WHERE id = current_setting('mut.workload');
  EXECUTE 'SELECT (' || replace(replace(w.keymax, ':scale', '100000'),
                                ':groups', '1000') || ')::bigint' INTO keymaxv;
  SELECT count(*) INTO mvrows FROM bench.mv;

  -- Scope is the axis the fixed costs are measured against: SPECIALIZE.md has
  -- the fused DML at 52% of a scope-1 refresh and 87% of a large one, so a
  -- saving inside the DML can only be read against where it sits on that curve.
  FOREACH span IN ARRAY ARRAY[1, 10, 100, 1000] LOOP
    CONTINUE WHEN span >= keymaxv;

    IF span = 1 THEN
      pred := replace(w.pred1, ':k', '1');
    ELSE
      pred := replace(replace(w.predr, ':k', '1'), ':span', span::text);
    END IF;

    BEGIN
      EXECUTE 'SELECT count(*) FROM bench.mv WHERE ' || pred INTO scope;
    EXCEPTION WHEN OTHERS THEN scope := NULL;
    END;
    CONTINUE WHEN scope IS NULL OR scope = 0;
    -- Same guard bench/run.sh uses: a predicate selecting nearly everything is
    -- a full refresh wearing a WHERE clause.
    CONTINUE WHEN scope * 100 / GREATEST(mvrows, 1) >= 90;

    FOREACH form IN ARRAY ARRAY['A','Aopt','B','Bopt','B2','C'] LOOP
      PERFORM public.mut_clone();       -- same rows, same layout, every form

      -- A timing is only worth reading if the statement it timed did the right
      -- thing.  Every form must leave the heap agreeing with the matview; a
      -- form that diverges is a different statement than the one named in the
      -- header, and its microseconds describe that other statement.  This is
      -- the same rule verify.sql enforces for bench/run.sh, applied before the
      -- number is recorded rather than after it is charted.
      PERFORM public.mut_time(form, pred, 1);
      SELECT count(*) INTO diverged FROM (
        (SELECT * FROM bench.mv EXCEPT ALL SELECT * FROM bench.mvt)
        UNION ALL
        (SELECT * FROM bench.mvt EXCEPT ALL SELECT * FROM bench.mv)) d;
      IF diverged <> 0 THEN
        RAISE EXCEPTION 'form % on %/span=% left % rows differing from the '
                        'matview; it is not the statement it claims to be',
                        form, w.id, span, diverged;
      END IF;

      PERFORM public.mut_clone();
      us := public.mut_time(form, pred, 3);
      -- ~1s of measurement, never fewer than 8 samples.  At a 200ms
      -- budget the slow cells got three, and three samples of a 60ms
      -- statement produced apparent 31% SPEEDUPS from adding work.
      iters := GREATEST(8, LEAST(60, (1000000 / GREATEST(us, 1))::int));
      us := public.mut_time(form, pred, iters);
      INSERT INTO public.mut_result(workload, span, scope_rows, mv_rows,
                                    form, iters, us)
        VALUES (w.id, span, scope, mvrows, form, iters, us);
    END LOOP;
  END LOOP;
END $outer$;
