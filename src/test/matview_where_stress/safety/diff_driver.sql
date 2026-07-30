-- Differential mode: run the same mutation two ways and diff the results.
--
-- PLAN.md 1.1 asks for this as old-implementation against new-implementation,
-- and calls it the single thing that makes the Query-tree rewrite tractable:
-- any divergence is a rewrite bug, localised to one mutation, with no need to
-- reason about whether the old behaviour was correct.
--
-- The new implementation does not exist yet, so this cannot be instantiated
-- that way today.  What it CAN be instantiated as is the pair that already
-- exists -- the bare form (match/merge) against CONCURRENTLY (direct
-- modification) -- which are two genuinely different implementations of one
-- contract, and which the contract file states must agree (Promise 7).
--
-- That matters for more than symmetry.  A harness built now and verified now
-- is a harness that works on the first day of Phase 2; a harness written
-- against an implementation that does not exist yet is a harness nobody has
-- seen catch anything, which is the defect this directory keeps finding.  When
-- the Query-tree path lands, the two form strings below become the two GUC
-- settings and nothing else here changes.
--
-- Note what this sees that the oracle does not.  The oracle compares each form
-- against a FULL refresh, so a bug present in both forms, or one that makes a
-- form fail outright, shows up as two independent results that have to be read
-- side by side.  This compares the forms to each other directly, so
-- "these two disagree" is one number.

DROP TABLE IF EXISTS diff_result;
CREATE TABLE diff_result(id text, shape text, a text, b text,
                         total int, diverged int, errs_a int, errs_b int,
                         first_mut text, first_pred text, first_diff bigint);

CREATE OR REPLACE FUNCTION run_diff(p_id text, p_a text, p_b text) RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
  c probe_exh; m record; n bigint;
  conc_a text; conc_b text;
  tot int := 0; bad int := 0; ea int := 0; eb int := 0;
  fm text; fp text; fd bigint;
BEGIN
  SELECT * INTO c FROM public.probe_exh WHERE id = p_id;
  conc_a := CASE WHEN p_a = 'concurrently' THEN 'CONCURRENTLY ' ELSE '' END;
  conc_b := CASE WHEN p_b = 'concurrently' THEN 'CONCURRENTLY ' ELSE '' END;

  FOR m IN EXECUTE 'SELECT * FROM (' || c.mutspace || ') s(mut, pred)' LOOP
    tot := tot + 1;
    BEGIN
      EXECUTE 'DROP SCHEMA IF EXISTS probe CASCADE';
      EXECUTE 'CREATE SCHEMA probe';
      EXECUTE 'SET search_path = probe, public';
      EXECUTE c.setup;

      -- Two matviews over identical input, so the only difference between them
      -- is which implementation refreshed them.
      EXECUTE 'CREATE MATERIALIZED VIEW probe.mv_a AS ' || c.viewsql;
      EXECUTE 'CREATE MATERIALIZED VIEW probe.mv_b AS ' || c.viewsql;
      EXECUTE 'CREATE UNIQUE INDEX mv_a_u ON probe.mv_a ' || c.ukey;
      EXECUTE 'CREATE UNIQUE INDEX mv_b_u ON probe.mv_b ' || c.ukey;
      IF c.ukey2 IS NOT NULL THEN
        EXECUTE 'CREATE UNIQUE INDEX mv_a_u2 ON probe.mv_a ' || c.ukey2;
        EXECUTE 'CREATE UNIQUE INDEX mv_b_u2 ON probe.mv_b ' || c.ukey2;
      END IF;

      EXECUTE m.mut;

      -- Each side is allowed to fail on its own without taking the comparison
      -- with it: a form that errors where the other succeeds is a divergence
      -- worth recording, not a reason to lose the row.  B6 is exactly that
      -- shape -- direct modification collides on a non-arbiter index where
      -- match/merge does not.
      BEGIN
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || conc_a || 'probe.mv_a WHERE ' || m.pred;
      EXCEPTION WHEN OTHERS THEN ea := ea + 1;
      END;
      BEGIN
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || conc_b || 'probe.mv_b WHERE ' || m.pred;
      EXCEPTION WHEN OTHERS THEN eb := eb + 1;
      END;

      EXECUTE 'SELECT count(*) FROM ('
              ' (SELECT * FROM probe.mv_a EXCEPT ALL SELECT * FROM probe.mv_b) UNION ALL '
              ' (SELECT * FROM probe.mv_b EXCEPT ALL SELECT * FROM probe.mv_a)) d' INTO n;
      IF n > 0 THEN
        bad := bad + 1;
        IF fm IS NULL THEN fm := m.mut; fp := m.pred; fd := n; END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      -- Setup itself failed; not a divergence, and not silently ignored.
      IF fm IS NULL THEN fm := m.mut; fp := m.pred || ' -> setup ' || SQLSTATE; fd := -1; END IF;
    END;
  END LOOP;

  EXECUTE 'SET search_path = public';
  INSERT INTO public.diff_result VALUES (c.id, c.shape, p_a, p_b, tot, bad, ea, eb, fm, fp, fd);
  RETURN format('%s/%s differ, errs %s/%s', bad, tot, ea, eb);
END $fn$;
