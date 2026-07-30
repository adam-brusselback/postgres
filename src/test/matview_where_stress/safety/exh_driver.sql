DROP TABLE IF EXISTS exh_result;
CREATE TABLE exh_result(id text, shape text, expect text, form text,
                        total int, diverged int, verdict text,
                        first_mut text, first_pred text, first_diff bigint, errs int);

CREATE OR REPLACE FUNCTION run_exh(p_id text, p_form text) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  c probe_exh; m record; n bigint; conc text;
  tot int := 0; bad int := 0; nerr int := 0;
  fm text; fp text; fd bigint;
BEGIN
  SELECT * INTO c FROM public.probe_exh WHERE id = p_id;
  conc := CASE WHEN p_form = 'concurrently' THEN 'CONCURRENTLY ' ELSE '' END;

  FOR m IN EXECUTE 'SELECT * FROM (' || c.mutspace || ') s(mut, pred)' LOOP
    tot := tot + 1;
    BEGIN
      EXECUTE 'DROP SCHEMA IF EXISTS probe CASCADE';
      EXECUTE 'CREATE SCHEMA probe';
      EXECUTE 'SET search_path = probe, public';
      EXECUTE c.setup;
      EXECUTE 'CREATE MATERIALIZED VIEW probe.mv AS ' || c.viewsql;
      EXECUTE 'CREATE UNIQUE INDEX mv_u ON probe.mv ' || c.ukey;
      -- Created second, so it is second in RelationGetIndexList and the
      -- arbiter choice between the two is observable: a matview cannot have a
      -- PRIMARY KEY, so indisprimary is false for both and
      -- matview_pick_arbiter_index falls through to "first usable".  B6
      -- reverses that to last.
      IF c.ukey2 IS NOT NULL THEN
        EXECUTE 'CREATE UNIQUE INDEX mv_u2 ON probe.mv ' || c.ukey2;
      END IF;
      EXECUTE m.mut;
      EXECUTE 'REFRESH MATERIALIZED VIEW ' || conc || 'probe.mv WHERE ' || m.pred;
      EXECUTE 'CREATE TABLE probe.after AS SELECT * FROM probe.mv';
      EXECUTE 'REFRESH MATERIALIZED VIEW probe.mv';
      EXECUTE 'SELECT count(*) FROM ('
              ' (SELECT * FROM probe.after EXCEPT ALL SELECT * FROM probe.mv) UNION ALL '
              ' (SELECT * FROM probe.mv EXCEPT ALL SELECT * FROM probe.after)) d' INTO n;
      IF n > 0 THEN
        bad := bad + 1;
        IF fm IS NULL THEN fm := m.mut; fp := m.pred; fd := n; END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      nerr := nerr + 1;
      IF fm IS NULL THEN fm := m.mut; fp := m.pred || ' -> ' || SQLSTATE; fd := -1; END IF;
    END;
  END LOOP;

  EXECUTE 'SET search_path = public';
  INSERT INTO public.exh_result VALUES (c.id, c.shape, c.expect, p_form, tot, bad,
    CASE WHEN bad = 0 AND nerr = 0 THEN 'SAFE over the space' ELSE 'UNSAFE' END,
    fm, fp, fd, nerr);
  RETURN format('%s/%s diverged, %s errors', bad, tot, nerr);
END $fn$;
