-- Assert a run is fit to draw conclusions from, before anyone draws them.
--
--   psql -v label=p21b-O2 -f verify.sql
--
-- Every check here exists because it failed silently once.  A chart drawn from
-- an unverified run is worse than no chart: it looks exactly like a verified
-- one, and the reader has no way to tell which they are looking at.

\set ON_ERROR_STOP on
\pset footer off

WITH r AS (
  SELECT * FROM bench_result WHERE run_label = :'label'
),
checks AS (
  -- Every workload the suite defines either produced rows or was deliberately
  -- skipped.  'recursive' produced none in six consecutive runs and nothing
  -- said so; the sweep reported success each time.
  SELECT 1 AS ord, 'workloads present' AS "check",
         (SELECT count(*) FROM bench_workload)::text || ' defined, ' ||
         (SELECT count(DISTINCT workload) FROM r)::text || ' measured' AS detail,
         (SELECT count(DISTINCT workload) FROM r) =
         (SELECT count(*) FROM bench_workload) AS ok

  -- A form without its counterpart cannot be compared against anything.
  UNION ALL SELECT 2, 'both forms per combination',
         coalesce((SELECT string_agg(DISTINCT workload || '/' || predshape ||
                                     '/' || span, ', ')
                     FROM (SELECT workload, predshape, span
                             FROM r GROUP BY 1,2,3 HAVING count(*) <> 2) x),
                  'all paired'),
         NOT EXISTS (SELECT 1 FROM r GROUP BY workload, predshape, span
                      HAVING count(*) <> 2)

  -- Without a scope the result cannot be normalised, and an un-normalised
  -- result is not comparable with any other scope.
  UNION ALL SELECT 3, 'scope measured',
         (SELECT count(*) FROM r WHERE scope_rows IS NULL)::text || ' null',
         NOT EXISTS (SELECT 1 FROM r WHERE scope_rows IS NULL)

  UNION ALL SELECT 4, 'normalised cost present',
         (SELECT count(*) FROM r WHERE vs_full_per_row IS NULL)::text || ' null',
         NOT EXISTS (SELECT 1 FROM r WHERE vs_full_per_row IS NULL)

  -- A latency averaged over four refreshes is not a measurement.
  UNION ALL SELECT 5, 'enough samples',
         'min ' || coalesce((SELECT min(txns) FROM r)::text, 'unrecorded') ||
         ' refreshes per measurement',
         (SELECT coalesce(min(txns), 0) FROM r) >= 30

  -- A predicate selecting the whole matview is a full refresh with extra steps.
  UNION ALL SELECT 6, 'scopes are partial',
         'max ' || (SELECT round(max(100.0 * scope_rows / mv_rows), 1)
                      FROM r WHERE mv_rows > 0)::text || '% of the matview',
         (SELECT coalesce(max(100.0 * scope_rows / mv_rows), 0)
            FROM r WHERE mv_rows > 0) < 90

  -- A -O0 --enable-cassert number is not comparable with a -O2 one, not even
  -- as a ratio; both were tried here and several ratios moved by over 2x.
  UNION ALL SELECT 7, 'built for measurement',
         'assertions ' || coalesce((SELECT DISTINCT assertions FROM r), '?'),
         (SELECT count(*) FROM r WHERE assertions <> 'off') = 0

  -- A baseline of zero divides into every normalised number in the run.
  UNION ALL SELECT 8, 'baselines usable',
         (SELECT count(*) FROM r WHERE full_ms IS NULL OR full_ms <= 0)::text ||
         ' missing or zero',
         NOT EXISTS (SELECT 1 FROM r WHERE full_ms IS NULL OR full_ms <= 0)

  -- A concurrent run that deadlocks looks FASTER than one that does not: the
  -- aborted transactions never reach the latency average.  Recording zero and
  -- recording nothing are indistinguishable once the run is over, so the column
  -- has to be populated before the numbers are read.
  UNION ALL SELECT 9, 'failure counts recorded',
         (SELECT count(*) FROM r WHERE failed_txns IS NULL)::text || ' null',
         NOT EXISTS (SELECT 1 FROM r WHERE failed_txns IS NULL)

  -- Latency is per refresh only if the refreshes per transaction are known.
  UNION ALL SELECT 10, 'per-refresh normalisation known',
         'perxact ' || coalesce((SELECT string_agg(DISTINCT perxact::text, ',')
                                   FROM r), 'unrecorded'),
         NOT EXISTS (SELECT 1 FROM r WHERE perxact IS NULL)

  -- Not a pass/fail: a run that swept concurrency and found no deadlocks has
  -- said something, and a run that never left one client has not.  Stating
  -- which is which stops the first being read into the second.
  UNION ALL SELECT 11, 'concurrency exercised',
         CASE WHEN (SELECT max(clients) FROM r) > 1
              THEN 'clients up to ' || (SELECT max(clients) FROM r)::text ||
                   ', ' || (SELECT sum(deadlocks) FROM r)::text ||
                   ' deadlocks, ' || (SELECT sum(failed_txns) FROM r)::text ||
                   ' failed'
              ELSE 'single client only -- says nothing about overlap' END,
         true
)
SELECT CASE WHEN ok THEN 'pass' ELSE 'FAIL' END AS result,
       "check", detail
  FROM checks ORDER BY ord;

SELECT CASE
  WHEN (SELECT count(*) FROM bench_result WHERE run_label = :'label') = 0
    THEN 'NO ROWS for this label'
  ELSE (SELECT count(*)::text FROM bench_result WHERE run_label = :'label') ||
       ' measurements over ' ||
       (SELECT count(DISTINCT workload)::text FROM bench_result
         WHERE run_label = :'label') || ' workloads'
END AS summary;
