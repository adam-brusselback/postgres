\pset footer off
\if :{?label}
\else
  \set label (SELECT run_label FROM bench_result ORDER BY run_at DESC LIMIT 1)
\endif

\echo '--- normalised cost: how many times a full rebuild'"'"'s per-row cost ---'
SELECT workload, form, predshape AS shape, span, scope_rows AS scope, clients AS c,
       overlap, round(latency_ms,2) AS ms,
       us_per_scope_row AS "us/row",
       vs_full_per_row AS "x rebuild"
  FROM bench_result WHERE run_label = :label
 ORDER BY workload, form, predshape, span, clients, overlap;

\echo ''
\echo '--- concurrency scaling: tps against 1 client, same everything else ---'
SELECT workload, form, span, overlap,
       max(tps) FILTER (WHERE clients = 1)  AS c1,
       max(tps) FILTER (WHERE clients = 4)  AS c4,
       max(tps) FILTER (WHERE clients = 16) AS c16,
       round(max(tps) FILTER (WHERE clients = 4)
             / NULLIF(max(tps) FILTER (WHERE clients = 1),0), 2) AS "4x?",
       round(max(tps) FILTER (WHERE clients = 16)
             / NULLIF(max(tps) FILTER (WHERE clients = 1),0), 2) AS "16x?"
  FROM bench_result WHERE run_label = :label
 GROUP BY workload, form, span, overlap
HAVING count(DISTINCT clients) > 1
 ORDER BY workload, form, span, overlap;

\echo ''
\echo '--- where partial refresh stops paying (x rebuild > mv_rows/scope_rows) ---'
SELECT workload, form, span, scope_rows, mv_rows,
       round(100.0*scope_rows/NULLIF(mv_rows,0),2) AS "scope %",
       vs_full_per_row AS "x rebuild",
       CASE WHEN vs_full_per_row IS NULL THEN '?'
            WHEN vs_full_per_row * scope_rows > mv_rows THEN 'REBUILD INSTEAD'
            ELSE 'partial wins' END AS verdict
  FROM bench_result WHERE run_label = :label AND scope_rows IS NOT NULL
 ORDER BY workload, form, span;
