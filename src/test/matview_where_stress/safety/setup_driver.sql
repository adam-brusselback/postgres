UPDATE probe_case SET ukey = '(' || ukey || ')' WHERE ukey NOT LIKE '(%';
UPDATE probe_case SET ukey = '(a,c,gr) NULLS NOT DISTINCT' WHERE id = 'groupingsets';

DROP TABLE IF EXISTS probe_result;
CREATE TABLE probe_result(
  ord int, id text, shape text, expect text,
  form text, verdict text, diffrows bigint, err text,
  leafrows bigint, baserows bigint, pushed text);

CREATE OR REPLACE FUNCTION run_probe(p_id text, p_form text) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  c probe_case; n bigint; conc text; leaf bigint; base bigint; j jsonb; v text;
  resid int := 0; resid2 int := 0;
BEGIN
  SELECT * INTO c FROM public.probe_case WHERE id = p_id;
  conc := CASE WHEN p_form = 'concurrently' THEN 'CONCURRENTLY ' ELSE '' END;
  EXECUTE 'DROP SCHEMA IF EXISTS probe CASCADE';
  EXECUTE 'CREATE SCHEMA probe';
  EXECUTE 'SET LOCAL search_path = probe, public';
  BEGIN
    EXECUTE c.setup;
    EXECUTE 'CREATE MATERIALIZED VIEW probe.mv AS ' || c.viewsql;
    EXECUTE 'CREATE UNIQUE INDEX mv_u ON probe.mv ' || c.ukey;
    EXECUTE 'ANALYZE probe.mv';

    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF, COSTS OFF, BUFFERS OFF) '
            'SELECT * FROM (' || c.viewsql || ') probe_v WHERE ' || c.pred INTO j;
    SELECT coalesce(round(sum((x->>'Actual Rows')::numeric * coalesce((x->>'Actual Loops')::numeric,1))),0) INTO leaf
      FROM jsonb_path_query(j->0->'Plan','strict $.** ? (exists(@."Relation Name"))') x
     WHERE x->>'Node Type' LIKE '%Scan%';
    EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON, TIMING OFF, COSTS OFF, BUFFERS OFF) '
            'SELECT * FROM (' || c.viewsql || ') probe_v' INTO j;
    SELECT coalesce(round(sum((x->>'Actual Rows')::numeric * coalesce((x->>'Actual Loops')::numeric,1))),0) INTO base
      FROM jsonb_path_query(j->0->'Plan','strict $.** ? (exists(@."Relation Name"))') x
     WHERE x->>'Node Type' LIKE '%Scan%';

    -- A predicate is FULLY pushed only if no conjunct survives as a Filter on a
    -- node above the base scans.  Any Filter on an Agg/WindowAgg/Limit/Unique/
    -- Subquery Scan node is a conjunct the planner refused to push down.
    EXECUTE 'EXPLAIN (FORMAT JSON, COSTS OFF) '
            'SELECT * FROM (' || c.viewsql || ') probe_v WHERE ' || c.pred INTO j;
    SELECT count(*) INTO resid
      FROM jsonb_path_query(j->0->'Plan', 'strict $.**') x
     WHERE jsonb_typeof(x) = 'object'
       AND (x ? 'Filter' OR x ? 'One-Time Filter')
       AND x->>'Node Type' NOT IN ('Seq Scan','Index Scan','Index Only Scan',
                                   'Bitmap Heap Scan','Tid Scan','Sample Scan',
                                   'Function Scan','Values Scan','Foreign Scan');
    SELECT count(*) INTO resid2
      FROM jsonb_path_query(j->0->'Plan', 'strict $.**') x
     WHERE jsonb_typeof(x) = 'object'
       AND x ? 'Filter'
       AND x->>'Node Type' = 'ZZZnever';
    SELECT count(*) INTO resid2
      FROM jsonb_path_query(j->0->'Plan', 'strict $.**') x
     WHERE jsonb_typeof(x) = 'object' AND x ? 'Parent Relationship'
       AND x->>'Parent Relationship' = 'InitPlan';

    EXECUTE c.mutate;
    EXECUTE 'REFRESH MATERIALIZED VIEW ' || conc || 'probe.mv WHERE ' || c.pred;
    EXECUTE 'CREATE TABLE probe.after AS SELECT * FROM probe.mv';
    EXECUTE 'REFRESH MATERIALIZED VIEW probe.mv';
    EXECUTE 'SELECT count(*) FROM ('
            ' (SELECT * FROM probe.after EXCEPT ALL SELECT * FROM probe.mv) UNION ALL '
            ' (SELECT * FROM probe.mv EXCEPT ALL SELECT * FROM probe.after)) d' INTO n;
    v := CASE WHEN n = 0 THEN 'SAFE' ELSE 'UNSAFE' END;
    INSERT INTO public.probe_result VALUES (c.ord, c.id, c.shape, c.expect, p_form,
      v, n, NULL, leaf, base,
      CASE WHEN resid > 0 THEN 'residual' WHEN resid2 > 0 THEN 'global-dep' ELSE 'pushed' END);
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    INSERT INTO public.probe_result VALUES (c.ord, c.id, c.shape, c.expect, p_form,
      'ERROR', NULL, SQLSTATE || ' ' || SQLERRM, leaf, base, NULL);
    RETURN 'ERROR';
  END;
END $fn$;
