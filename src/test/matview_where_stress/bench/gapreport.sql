-- What the gap sweeps found, in the order SPECIALIZE.md section 5 lists them.
--
--   psql -v prefix=gaps -f gapreport.sql
--
-- Read verify.sql for each label first.  Everything below assumes the runs it
-- reads are fit to draw conclusions from; it does not re-establish that.

\set ON_ERROR_STOP on
\pset footer off

\echo
\echo ===== Gap 1: mutability =====
\echo Aopt is what the tree does today (the row comparison, already implemented).
\echo A declaration is only worth its user-visible surface if it beats Aopt.
WITH p AS (
  SELECT workload, span, scope_rows AS scope,
         max(us) FILTER (WHERE form = 'A')    AS a,
         max(us) FILTER (WHERE form = 'Aopt') AS aopt,
         max(us) FILTER (WHERE form = 'Bopt') AS bopt,
         max(us) FILTER (WHERE form = 'C')    AS c
    FROM mut_result GROUP BY 1, 2, 3)
SELECT workload, span, scope,
       round(100.0 * (1 - aopt / nullif(a, 0)), 1)    AS "row cmp %",
       round(100.0 * (1 - bopt / nullif(aopt, 0)), 1) AS "no_delete %",
       round(100.0 * (1 - c / nullif(bopt, 0)), 1)    AS "append_only %",
       round(100.0 * (1 - c / nullif(aopt, 0)), 1)    AS "both vs today %",
       round(aopt - c)                                AS "abs us saved"
  FROM p ORDER BY workload, span;

\echo
\echo -- Does the mutability saving grow or shrink with scope?  SPECIALIZE.md
\echo -- assumed it grows, because the prune sits inside the phase that is 87%
\echo -- of a large refresh.  This is the check on that claim.
WITH p AS (
  SELECT workload, span,
         max(us) FILTER (WHERE form = 'Aopt') AS aopt,
         max(us) FILTER (WHERE form = 'C')    AS c
    FROM mut_result GROUP BY 1, 2)
SELECT span, count(*) AS workloads,
       round(avg(100.0 * (1 - c / nullif(aopt, 0))), 1) AS "avg both vs today %"
  FROM p GROUP BY span ORDER BY span;

\echo
\echo ===== Gap 3: churn =====
\echo Where the row comparison stops paying, measured against achieved churn
\echo rather than against scope.
SELECT workload, span, scope_rows AS scope, churn_pct AS "req %",
       max(churn_actual) AS "actual %",
       max(us) FILTER (WHERE NOT optimized) AS "off us",
       max(us) FILTER (WHERE optimized)     AS "on us",
       round(100.0 * (1 - max(us) FILTER (WHERE optimized)
                        / nullif(max(us) FILTER (WHERE NOT optimized), 0)), 1)
         AS "row cmp %"
  FROM churn_result
 GROUP BY workload, span, scope_rows, churn_pct
 ORDER BY workload, span, churn_pct;

\echo
\echo ===== Gap 2: concurrency =====
\echo Throughput and deadlocks, not latency: a configuration that deadlocks
\echo looks fast because the aborted transactions never reach the average.
SELECT workload, predshape, span, clients, overlap,
       round(tps, 1) AS tps,
       round(tps / nullif(min(tps) FILTER (WHERE clients = 1)
                            OVER (PARTITION BY workload, predshape, span, overlap), 0), 2)
         AS "tps vs c=1",
       failed_txns AS failed, deadlocks, ser_failures AS ser
  FROM bench_result
 WHERE run_label = :'prefix' || '-concurrency'
 ORDER BY workload, predshape, span, overlap, clients;

\echo
\echo ===== Gap 4: the match/merge crossover =====
\echo Negative "conc vs bare" means match/merge (bare) won at that scope.
SELECT workload, span, scope_rows AS scope,
       round(100.0 * scope_rows / nullif(mv_rows, 0), 1) AS "scope %",
       round(max(latency_ms) FILTER (WHERE form = 'bare'), 2) AS "bare ms",
       round(max(latency_ms) FILTER (WHERE form = 'conc'), 2) AS "conc ms",
       round(100.0 * (1 - max(latency_ms) FILTER (WHERE form = 'conc')
                        / nullif(max(latency_ms) FILTER (WHERE form = 'bare'), 0)), 1)
         AS "conc vs bare %"
  FROM bench_result
 WHERE run_label = :'prefix' || '-crossover'
 GROUP BY workload, span, scope_rows, mv_rows
 ORDER BY workload, "scope %";

\echo
\echo ===== Gap 5: transaction context (D1 vs D2) =====
\echo The commit's share of what every earlier measurement reported.
SELECT d2.workload, d2.predshape, d2.span, d2.scope_rows AS scope,
       round(d2.latency_ms, 3) AS "d2 ms (commit each)",
       round(d1.latency_ms, 3) AS "d1 ms (amortised)",
       round(100.0 * (1 - d1.latency_ms / nullif(d2.latency_ms, 0)), 1)
         AS "commit share %"
  FROM bench_result d2
  JOIN bench_result d1
    ON (d1.workload, d1.predshape, d1.span, d1.form, d1.clients)
     = (d2.workload, d2.predshape, d2.span, d2.form, d2.clients)
   AND d1.run_label = :'prefix' || '-txn-d1'
 WHERE d2.run_label = :'prefix' || '-txn-d2'
 ORDER BY 1, 2, 3;
