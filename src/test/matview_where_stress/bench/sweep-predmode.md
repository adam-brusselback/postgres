## Sweep `pp2-literal`

Extracted by `bench/extract.sh`.  Build and coverage first: a number here is
only comparable to another number taken on the same build, and only complete if
the shape census reads 1:3:3.

### Provenance

- rows: 40  (2026-08-03 02:08:20.003505+00 to 2026-08-03 02:58:25.108123+00)
- assertions: off
- pg_version: PostgreSQL 20devel on x86_64-pc-linux-gnu, compiled by gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0, 64-bit
- scale: 100000  groups: 1000  clients: 1  sync: off  perxact: 1

### Shape census

 predshape | rows | workloads |  spans   
-----------+------+-----------+----------
 array     |   17 |         6 | 1,10,100
 key       |    6 |         6 | 1
 range     |   17 |         6 | 1,10,100
(3 rows)


### `pp2-literal` against `pp2-param`

Joined on (workload, predshape, span), which is the grouping the header
explains and the one that has already been got wrong once.  pct_faster is
`pp2-param` against `pp2-literal`: positive means `pp2-param` is faster.

The absolute saving is the column to read when the effect is a FIXED cost
-- a plan built once instead of every call is the same number of
microseconds whether the refresh takes one millisecond or sixty, so the
percentage only says how cheap the refresh was.

  workload  | shape | span | scope_rows |  a_ms  |  b_ms  | pct_faster | saving_us 
------------+-------+------+------------+--------+--------+------------+-----------
 aggregate  | array |    1 |          1 |  0.803 |  0.591 |       26.4 |       212
 aggregate  | array |   10 |         10 |  1.303 |  1.071 |       17.8 |       232
 aggregate  | array |  100 |        100 |  5.081 |  4.694 |        7.6 |       387
 aggregate  | key   |    1 |          1 |  0.781 |  0.543 |       30.5 |       238
 aggregate  | range |    1 |          1 |  0.854 |  0.702 |       17.8 |       152
 aggregate  | range |   10 |         10 |  1.225 |  0.940 |       23.3 |       285
 aggregate  | range |  100 |        100 |  4.155 |  3.781 |        9.0 |       374
 expensive  | array |    1 |          1 |  0.808 |  0.475 |       41.2 |       333
 expensive  | array |   10 |         10 |  1.144 |  0.759 |       33.7 |       385
 expensive  | array |  100 |        100 |  4.000 |  3.160 |       21.0 |       840
 expensive  | key   |    1 |          1 |  0.777 |  0.425 |       45.3 |       352
 expensive  | range |    1 |          1 |  0.817 |  0.736 |        9.9 |        81
 expensive  | range |   10 |         10 |  1.109 |  0.997 |       10.1 |       112
 expensive  | range |  100 |        100 |  2.896 |  2.705 |        6.6 |       191
 join_agg   | array |    1 |          1 |  1.034 |  0.638 |       38.3 |       396
 join_agg   | array |   10 |         10 |  2.234 |  1.780 |       20.3 |       454
 join_agg   | array |  100 |        100 | 12.480 | 11.950 |        4.2 |       530
 join_agg   | key   |    1 |          1 |  0.921 |  0.584 |       36.6 |       337
 join_agg   | range |    1 |          1 |  1.089 |  0.926 |       15.0 |       163
 join_agg   | range |   10 |         10 |  2.159 |  1.758 |       18.6 |       401
 join_agg   | range |  100 |        100 | 11.362 | 11.322 |        0.4 |        40
 nonkey     | array |    1 |        100 |  1.969 |  1.620 |       17.7 |       349
 nonkey     | array |   10 |       1000 |  6.446 |  6.288 |        2.5 |       158
 nonkey     | array |  100 |      10000 | 53.908 | 53.729 |        0.3 |       179
 nonkey     | key   |    1 |        100 |  1.973 |  1.662 |       15.8 |       311
 nonkey     | range |    1 |        100 |  1.580 |  1.474 |        6.7 |       106
 nonkey     | range |   10 |       1000 |  6.089 |  5.872 |        3.6 |       217
 nonkey     | range |  100 |      10000 | 48.362 | 47.736 |        1.3 |       626
 projection | array |    1 |          1 |  0.715 |  0.454 |       36.5 |       261
 projection | array |   10 |         10 |  0.870 |  0.588 |       32.4 |       282
 projection | array |  100 |        100 |  2.563 |  2.117 |       17.4 |       446
 projection | key   |    1 |          1 |  0.647 |  0.420 |       35.1 |       227
 projection | range |    1 |          1 |  0.704 |  0.652 |        7.4 |        52
 projection | range |   10 |         10 |  0.823 |  0.684 |       16.9 |       139
 projection | range |  100 |        100 |  1.348 |  1.185 |       12.1 |       163
 timerange  | array |    1 |        200 |  2.237 |  2.289 |       -2.3 |       -52
 timerange  | array |   10 |       2000 | 14.216 | 14.831 |       -4.3 |      -615
 timerange  | key   |    1 |        200 |  2.305 |  2.537 |      -10.1 |      -232
 timerange  | range |    1 |        200 |  2.317 |  2.075 |       10.4 |       242
 timerange  | range |   10 |       2000 | 14.276 | 14.327 |       -0.4 |       -51
(40 rows)


### Summary by shape

Percentages are averaged over CELLS, not weighted by microseconds.  The
saving is reported as a range rather than a mean for the same reason:
these workloads refresh in 0.6 to 60 ms, so a mean over them describes no
workload in particular.  Pooling absolute microseconds across scales is
what produced the bogus band in the p21c sweep.  If the saving really is a
fixed cost, the spread between min and max is the evidence for it.

 shape | cells | avg_pct | worst | best | min_saving_us | max_saving_us 
-------+-------+---------+-------+------+---------------+---------------
 array |    17 |    18.3 |  -4.3 | 41.2 |          -615 |           840
 key   |     6 |    25.5 | -10.1 | 45.3 |          -232 |           352
 range |    17 |     9.9 |  -0.4 | 23.3 |           -51 |           626
(3 rows)


### Any cell where the second run is SLOWER

Printed even when empty, because "no regressions" has to be something the
reader can see rather than something absent from a table.

 workload  | shape | span | scope_rows |  a_ms  |  b_ms  | pct_faster 
-----------+-------+------+------------+--------+--------+------------
 timerange | array |    1 |        200 |  2.237 |  2.289 |       -2.3
 timerange | array |   10 |       2000 | 14.216 | 14.831 |       -4.3
 timerange | key   |    1 |        200 |  2.305 |  2.537 |      -10.1
 timerange | range |   10 |       2000 | 14.276 | 14.327 |       -0.4
(4 rows)

