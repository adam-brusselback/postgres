# REFRESH MATERIALIZED VIEW ... WHERE ... — use case catalogue

Branch-local. Not part of the patch; delete this directory before posting to
-hackers. Intended to feed the documentation and the design discussion.

Scope figures ("rows selected") and matview sizes are typical field values, not
measurements — they are here to place each case against the measured cost
regimes below. Timings **are** measured, on a debug build (`-O0
--enable-cassert`); treat ratios as transferable and absolute ms as not.

---

## The cost model everything below is placed against

Measured on a 100k-row matview, minimum of 3 runs:

| path | fixed cost | marginal cost | notes |
|---|---|---|---|
| upsert + prune (`CONCURRENTLY`) | ~1.0 ms | ~0.088 ms/row | parallel across disjoint rows |
| delete + insert (proposed bare form) | ~0.9 ms | ~0.022 ms/row | serialized on ExclusiveLock |
| diff/merge (bare form today) | ~9–12 ms | ~0.026 ms/row | temp tables + ANALYZE + diff |
| full rebuild | — | ~3.5 µs/row | scale-invariant baseline |

Derived rules:

- **A partial refresh costs roughly what rebuilding `scope × 11` rows would.**
  So it pays while scope is below ~1/11 of the matview; above ~10%, rebuild.
- Cost depends on **rows selected**, not matview size — verified across 10k,
  100k and 1M (35.4 / 34.3 / 35.5 ms at scope 1000).
- Crossover between the two partial forms is ~500 rows.

Four measured traps, in descending severity:

| trap | penalty | why |
|---|---|---|
| predicate column unindexed on **either** side | up to **324×** | predicate is applied to the matview *and* to the view query; both need an index |
| predicate on an **aggregate output** (`WHERE total > x`) | **126×** | cannot push below `GroupAggregate`; O(base table) even matching 0 rows |
| queue table in a subquery with **stale statistics** | **12×** | planner misestimates a high-churn queue and picks a hash join + seq scan |
| **literal** predicate that varies per call | **4.2×** | plan cache is keyed on deparsed text; every distinct literal is a miss |

All four are avoided by: index the predicate columns on both sides, predicate on
grouping keys, and pass id sets as an **array parameter**.

---

## The rule that outranks all of the above: blast radius

**The predicate must cover every row whose output changed, not merely the rows
whose input changed.** Where those two sets differ, a partial refresh silently
leaves the matview self-inconsistent. It is not a bug in the feature — the
refresh does exactly what it was asked — but it is the easiest way to corrupt a
matview with this command, and nothing warns you.

Measured on a `rank() OVER (PARTITION BY region ORDER BY score DESC)` matview:
one player's score is raised, then only that player is refreshed.

```
=== the matview now says two players share rank 1 ===
 player_id | score  | rnk
        43 | 999999 |   1
     46963 |  99997 |   1     <- should be 2
     16593 |  99967 |   2     <- should be 3
=== what a correct (full) refresh gives ===
        43 | 999999 |   1
     46963 |  99997 |   2
     16593 |  99967 |   3
```

Affected view shapes, and the scope each one actually requires:

| view contains | one input row changes … | refresh by |
|---|---|---|
| `rank`/`row_number`/`dense_rank` | every row in the same window partition | the `PARTITION BY` key |
| running totals, `SUM() OVER` | every row after it in frame order | the partition key |
| `percentile`, `NTILE`, `cume_dist` | every row in the partition | the partition key |
| `ORDER BY … LIMIT` (top-N) | the entrant **and** whoever it evicted | cannot be expressed; rebuild |
| recursive closure | an arbitrary subtree | not derivable from transition tables |
| `GROUP BY` only | just that group | the grouping key — the safe case |

Push-down follows the same structure, and was measured separately:

- through `GROUP BY`, on **grouping keys** → `Index Cond`
- through `WINDOW`, on **`PARTITION BY` keys** → `Bitmap Index Scan`
- through `LIMIT` → **never**; `Subquery Scan` + `Filter` over the whole result
- on an aggregate or window **output** → never

So for a windowed view the partition key is the only safe *and* fast predicate,
and the two properties coincide. That is a good rule of thumb generally: **if the
predicate does not push down, it is usually also the wrong scope.**

---

## Canonical driver patterns

### D1 — Statement-level trigger, synchronous (the default choice)

Fires once per statement, rolls the affected keys into one array. Measured
3–5× cheaper than one refresh per row at 10–100 ids, and the array form is
immune to the stale-statistics and push-down traps.

```sql
CREATE FUNCTION invoice_lines_refresh() RETURNS trigger
  LANGUAGE plpgsql AS $$
DECLARE ids bigint[];
BEGIN
  -- union of both transition tables so UPDATE moving a line between invoices
  -- refreshes the old header as well as the new one
  SELECT array_agg(DISTINCT invoice_id) INTO ids
    FROM (SELECT invoice_id FROM new_rows
          UNION SELECT invoice_id FROM old_rows) s;
  IF ids IS NOT NULL THEN
    EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY invoice_totals'
            ' WHERE invoice_id = ANY($1)' USING ids;
  END IF;
  RETURN NULL;
END $$;

CREATE TRIGGER t_ins AFTER INSERT ON invoice_lines
  REFERENCING NEW TABLE AS new_rows OLD TABLE AS old_rows
  FOR EACH STATEMENT EXECUTE FUNCTION invoice_lines_refresh();
-- repeat for UPDATE (both tables) and DELETE (old only)
```

Needs one trigger per table the view reads. Note the `EXECUTE ... USING` — a
literal predicate costs 4.2×.

### D2 — Queue table + drain, asynchronous

Decouples the refresh from the writing transaction. Right whenever the consumer
tolerates lag, and the only workable choice when the refresh is expensive or the
write path is latency-critical.

```sql
CREATE UNLOGGED TABLE mv_dirty (key bigint PRIMARY KEY);

-- writers only stamp the key; cheap, never blocks on the matview
CREATE FUNCTION mark_dirty() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO mv_dirty
    SELECT DISTINCT invoice_id FROM new_rows
    ON CONFLICT DO NOTHING;
  PERFORM pg_notify('mv_dirty', '');
  RETURN NULL;
END $$;

-- drain: claim a batch, refresh it, delete what was claimed
CREATE FUNCTION drain(batch int DEFAULT 200) RETURNS int
  LANGUAGE plpgsql AS $$
DECLARE ids bigint[];
BEGIN
  WITH claimed AS (
    SELECT key FROM mv_dirty ORDER BY key
      FOR UPDATE SKIP LOCKED LIMIT batch
  ), gone AS (
    DELETE FROM mv_dirty d USING claimed c WHERE d.key = c.key
    RETURNING d.key
  )
  SELECT array_agg(key) INTO ids FROM gone;

  IF ids IS NULL THEN RETURN 0; END IF;
  EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY invoice_totals'
          ' WHERE invoice_id = ANY($1)' USING ids;
  RETURN array_length(ids, 1);
END $$;
```

Three things this gets right, each of which is a measured trap otherwise:

- **`array_agg` then `= ANY($1)`**, rather than
  `WHERE invoice_id IN (SELECT key FROM mv_dirty)`. The subquery form is 12×
  slower when the queue's statistics are stale — which for a queue table is the
  normal state — and cannot push down at all through an aggregating view.
- **Claim-and-delete in the same statement** as the refresh's transaction, so a
  rollback puts the keys back. Deleting after the refresh commits loses work on
  crash; deleting before risks dropping keys on rollback.
- **`SKIP LOCKED`** so multiple drainers don't serialize. With the upsert form
  the refreshes themselves run in parallel over disjoint keys.

Batch size: keep it under the ~500-row crossover to stay on the upsert form.

### D3 — Scheduled window, asynchronous

```sql
-- nightly, and again for the current period on demand
REFRESH MATERIALIZED VIEW daily_sales
  WHERE day >= current_date - 2 AND day < current_date + 1;
```

Requires an index on `day` on **both** `daily_sales` and the underlying fact
table. Uses the bare (serialized) form: one refresher, large scope.

---

## The catalogue

Legend for **Form**: **U** = `CONCURRENTLY` (upsert, parallel, small scope);
**S** = bare (serialized, larger scope); **F** = full rebuild.

### Financial

**1. Account balance roll-up** — sync, D1, form **U**
Scope 1–50 accounts · matview 10k–10M rows
```sql
CREATE MATERIALIZED VIEW account_balance AS
  SELECT account_id, sum(amount) AS balance, max(posted_at) AS last_posted
    FROM ledger_entry GROUP BY account_id;
CREATE UNIQUE INDEX ON account_balance (account_id);
REFRESH MATERIALIZED VIEW CONCURRENTLY account_balance
  WHERE account_id = ANY($1);
```
Usually must be synchronous — the next transaction reads the balance to decide
whether to allow a debit. Predicate is the grouping key, so it pushes down.
Ledger tables are append-only, which means the roll-up is a good candidate for
being maintained by triggers rather than refreshed at all; use this when the
aggregate is more complex than a running sum.

**2. Invoice header roll-up** — sync, D1, form **U**
Scope 1–20 invoices · matview 100k–100M rows
```sql
CREATE MATERIALIZED VIEW invoice_totals AS
  SELECT i.invoice_id, i.customer_id,
         sum(l.qty * l.unit_price) AS net,
         sum(l.qty * l.unit_price * l.tax_rate) AS tax,
         count(*) AS line_count
    FROM invoice i JOIN invoice_line l USING (invoice_id)
   GROUP BY i.invoice_id, i.customer_id;
CREATE UNIQUE INDEX ON invoice_totals (invoice_id);
```
Triggers on **both** `invoice` and `invoice_line`. The line trigger must union
`old_rows` and `new_rows` (D1) or moving a line between invoices leaves the old
header stale. This is the shape the on-list benchmark used.

**3. AR aging buckets** — mixed, D1 + D3, forms **U** and **F**
Scope 1–100 customers (sync) / whole matview (nightly) · matview 10k–1M rows
```sql
-- bucket depends on current_date, so every row goes stale at midnight
REFRESH MATERIALIZED VIEW ar_aging CONCURRENTLY WHERE customer_id = ANY($1);
REFRESH MATERIALIZED VIEW ar_aging;   -- nightly, unconditional
```
Worth calling out as a category: **any view whose definition reads the clock
goes stale everywhere at once**, and no predicate can express that. Partial
refresh handles the payment events; only a full rebuild handles the date roll.

**4. Trial balance by period** — async, D3, form **S**
Scope one period (1k–100k rows) · matview 100k–10M rows
Predicate on `period`, indexed both sides. Scope is often >10% of the matview
for the current period, in which case rebuild instead.

### Inventory and commerce

**5. On-hand by SKU / location** — sync, D1, form **U**
Scope 1–200 (sku, loc) pairs · matview 100k–10M rows
```sql
CREATE MATERIALIZED VIEW on_hand AS
  SELECT sku_id, location_id, sum(qty) AS qty
    FROM stock_movement GROUP BY sku_id, location_id;
CREATE UNIQUE INDEX ON on_hand (sku_id, location_id);
REFRESH MATERIALIZED VIEW CONCURRENTLY on_hand
  WHERE (sku_id, location_id) IN (SELECT * FROM unnest($1::int[], $2::int[]));
```
Composite key. Note the two-column predicate still pushes down, but confirm with
`EXPLAIN` — a row-constructor `IN` over `unnest` is less reliably pushed than a
single-column `= ANY`; if it isn't, refresh by `sku_id = ANY($1)` and accept the
wider scope.

**6. Search / denormalisation vector table** — async, D2, form **U**
Scope 1–1000 products · matview 100k–50M rows
```sql
CREATE MATERIALIZED VIEW product_search AS
  SELECT p.product_id, p.name, b.name AS brand, c.path AS category,
         to_tsvector('english',
           p.name || ' ' || coalesce(p.description,'') || ' ' || b.name) AS doc,
         pr.price, s.in_stock
    FROM product p
    JOIN brand b USING (brand_id)
    JOIN category c USING (category_id)
    LEFT JOIN price pr ON pr.product_id = p.product_id AND pr.current
    LEFT JOIN stock_summary s USING (product_id);
CREATE UNIQUE INDEX ON product_search (product_id);
CREATE INDEX ON product_search USING gin (doc);
```
The archetype for D2: search tolerates seconds of lag, the view is expensive
(joins plus `to_tsvector`), and writes come from five different tables. Put a
`mark_dirty` trigger on each and let one drainer do the work — that also
coalesces the common case where one product is touched repeatedly.

Two specifics for this shape. The GIN index makes each refreshed row markedly
more expensive than the timings above, which are for a plain btree matview, so
keep batches small and measure. And an unrelated change to a shared parent —
renaming a brand — dirties every product under it; that is a range, not a key
list, and belongs on form **S** or a rebuild.

**7. Price / promotion effective view** — async, D2 or D3, form **S**
Scope 1 product to 100k (a promotion) · matview 1M–100M rows
The scope distribution is bimodal: single-product edits, and campaign
activations touching a large fraction. Route by size — refresh by key list under
~500, by predicate above, rebuild above ~10%.

**8. Order status projection** — sync, D1, form **U**
Scope 1 order · matview 1M–1B rows
Scope-1 refresh is ~1 ms and independent of matview size, which is the whole
point; at 1B rows a full rebuild is hours.

### Analytics

**9. Daily / hourly rollup fact** — async, D3, form **S**
Scope one day (0.1% of a 3-year matview) · matview 1k–10M rows
Only the current and previous period are volatile; refresh those on a schedule
and never touch history. The cheapest well-shaped case in the catalogue.

**10. Dashboard KPI table** — async, D3, form **F**
Scope = all · matview 10–10k rows
**Do not use this feature.** Scope is 100% of the matview, so a rebuild is
strictly cheaper. Listed because it is the most common thing people reach for
partial refresh to solve.

**11. Cohort / funnel** — async, D2, form **S**
Scope one cohort (1k–100k) · matview 100k–10M rows

### Graph and hierarchy

**12. Transitive closure / group membership** — async, D2, form **U** or **S**
Scope: unbounded in principle · matview 100k–10M rows
```sql
CREATE MATERIALIZED VIEW group_closure AS
  WITH RECURSIVE r AS (
    SELECT member_id, group_id FROM membership
    UNION
    SELECT r.member_id, m.group_id FROM r JOIN membership m ON m.member_id = r.group_id
  ) SELECT * FROM r;
CREATE UNIQUE INDEX ON group_closure (member_id, group_id);
```
The hard case, and the one from the thread. A single edge change can invalidate
an arbitrary subtree, so the affected key set is not knowable from the trigger's
transition tables without walking the graph. **Check whether the predicate
pushes into the recursive term at all** — if it does not, every "partial"
refresh is a full recomputation and the feature buys nothing. Where it doesn't
push down, D2 with debouncing and a periodic rebuild is the honest answer, which
is what Nico described.

### Multi-tenant and security

**13. Per-tenant aggregate** — mixed, D1 or D3, form **U** or **S**
Scope one tenant, 0.01%–10% of the matview · matview 1M–100M rows
```sql
REFRESH MATERIALIZED VIEW CONCURRENTLY tenant_summary WHERE tenant_id = $1;
```
Non-key predicate: **needs an index on `tenant_id` on the matview and on every
base table**, or you pay the 324×. Tenants are naturally disjoint, so this is
the case where the upsert form's parallelism earns the most — many tenants
refreshing at once never collide.

**14. Effective permissions / ACL flattening** — sync, D1, form **U**
Scope 1–1000 principals · matview 100k–10M rows
Synchronous by necessity: a stale permission row is a security bug. Note the
predicate runs with the matview owner's privileges, so keep it to plain column
comparisons — anything non-leakproof now requires ownership.

### Time series

**15. Latest reading per device** — async, D2 micro-batch, form **U**
Scope 100–10k devices per batch · matview 10k–10M rows
Ingest is continuous, so batch on an interval rather than per statement. Batch
size is the tuning knob: stay under ~500 for the upsert form, or accept the
serialized form and larger batches.

### Observability and telemetry

**16. Metric downsampling (raw → 1m → 1h)** — async, D3, form **S**
Scope one time bucket, 100–100k rows · matview 1M–1B rows
```sql
CREATE MATERIALIZED VIEW metric_1h AS
  SELECT series_id, date_trunc('hour', ts) AS bucket,
         avg(value) AS avg, max(value) AS max, count(*) AS n
    FROM metric_raw GROUP BY series_id, date_trunc('hour', ts);
CREATE UNIQUE INDEX ON metric_1h (series_id, bucket);
CREATE INDEX ON metric_1h (bucket);
REFRESH MATERIALIZED VIEW metric_1h
  WHERE bucket >= date_trunc('hour', now()) - interval '3 hours';
```
The distinctive property is **late-arriving data reopening closed buckets**. An
agent that was network-partitioned for an hour writes points into buckets you
already finalised. Either keep a trailing window wide enough to cover your worst
lateness (above), or have ingest record which buckets it touched and drive from
that (D2 keyed by `(series_id, bucket)`). A trailing window that is too narrow
loses data silently.

**17. SLO error budget** — async, D3, form **S**
Scope one service × window · matview 1k–100k rows
Rolling windows mean the denominator moves continuously — same class as AR
aging: every row goes stale as the clock advances, so schedule a rebuild
regardless of what partial refresh does.

**18. Service dependency / call graph** — async, D2, form **S**
Scope one service's edges · matview 10k–1M rows

### Gaming

**19. Leaderboard with rank** — async, D2, form **S** — **the blast radius case**
Scope one region/season partition, 1k–1M rows · matview 100k–100M rows
```sql
CREATE MATERIALIZED VIEW leaderboard AS
  SELECT player_id, season_id, region, score,
         rank() OVER (PARTITION BY season_id, region ORDER BY score DESC) AS rnk
    FROM player_score;
CREATE UNIQUE INDEX ON leaderboard (player_id, season_id);
CREATE INDEX ON leaderboard (season_id, region);

-- CORRECT: refresh the whole window partition
REFRESH MATERIALIZED VIEW leaderboard WHERE season_id = $1 AND region = $2;
-- WRONG: leaves every other player's rank stale, silently
REFRESH MATERIALIZED VIEW CONCURRENTLY leaderboard WHERE player_id = $1;
```
Refreshing by player is what everyone will try first and it corrupts the view.
Because the partition is the required scope, and a busy region's partition is
large, this often wants the serialized form or an outright rebuild — partial
refresh buys much less here than it appears to.

**20. Player progression / achievements** — sync, D1, form **U**
Scope 1 player · matview 1M–500M rows
Plain `GROUP BY player_id`, no window — the safe shape, and a good contrast with
the leaderboard sitting next to it in the same schema.

**21. Matchmaking rating** — async, D2, form **U**
Scope both players in a match · matview 1M–100M rows

### Healthcare and life sciences

**22. Patient summary / FHIR flattening** — sync, D1, form **U**
Scope 1 patient · matview 100k–100M rows
```sql
CREATE MATERIALIZED VIEW patient_summary AS
  SELECT p.patient_id, p.mrn,
         (SELECT count(*) FROM problem WHERE patient_id = p.patient_id AND active) AS active_problems,
         (SELECT max(taken_at) FROM vital WHERE patient_id = p.patient_id) AS last_vital,
         (SELECT array_agg(DISTINCT code) FROM allergy WHERE patient_id = p.patient_id) AS allergies
    FROM patient p;
CREATE UNIQUE INDEX ON patient_summary (patient_id);
```
Clinically must be synchronous — a stale allergy list is a safety issue, and the
same argument as the ACL case. Triggers on every contributing table. Correlated
subqueries per column mean push-down has to be verified with `EXPLAIN` rather
than assumed.

**23. Lab latest-value panel** — sync, D1, form **U**
Scope 1 patient × analyte set · matview 1M–1B rows

**24. Clinical quality measure** (numerator/denominator per measure per patient)
— async, D3, form **S** · scope one measure, 10k–1M · matview 1M–100M
Measure definitions change with reporting periods, which invalidates everything
for that measure — a rebuild per measure, not a partial refresh.

**25. Genomic variant annotation** — async, D2, form **U**
Scope 1–1000 variants · matview 10M–10B rows
The best size ratio in the catalogue: annotating a handful of variants against a
multi-billion-row matview, where a rebuild is hours and a partial refresh is
milliseconds. Exactly what "cost tracks rows selected, not matview size" is
worth.

### Telecom and networking

**26. CDR rollup per subscriber per period** — async, D2 or D3, form **U**/**S**
Scope 1–100k subscribers · matview 10M–1B rows

**27. NetFlow aggregation by src/dst pair** — async, D3, form **S**
Scope one time bucket · matview 1M–100M rows
Ingest rate is the constraint; batch on an interval, never per statement.

**28. Network reachability / BGP RIB summary** — async, D2, form **S**
Scope arbitrary subtree · matview 100k–10M rows
Recursive, so blast radius is unbounded — same treatment as transitive closure.

### Geospatial

**29. Region containment aggregate** — async, D2, form **U**
Scope 1–100 regions · matview 10k–10M rows
```sql
CREATE MATERIALIZED VIEW region_stats AS
  SELECT r.region_id, count(*) AS n, sum(o.value) AS total
    FROM region r JOIN observation o ON ST_Contains(r.geom, o.geom)
   GROUP BY r.region_id;
CREATE UNIQUE INDEX ON region_stats (region_id);
REFRESH MATERIALIZED VIEW CONCURRENTLY region_stats WHERE region_id = ANY($1);
```
Refresh by `region_id`, never by a spatial predicate on the matview — the
grouping key is what pushes down. The hard part is the trigger: an observation
moving needs the regions containing both its old and new position, which is a
spatial query in the trigger, not a column read.

**30. Vector tile precomputation** — async, D2, form **U**
Scope tiles touched by an edit, 1–1000 · matview 100k–100M rows
A single edit to a large polygon dirties every tile it intersects across zoom
levels — derive the tile list in the trigger, then refresh by tile key.

### ML and search infrastructure

**31. Online feature store table** — async, D2 micro-batch, form **U**
Scope 100–10k entities · matview 1M–1B rows
Freshness SLO is the design constraint; batch to hit it rather than to hit a
throughput number.

**32. Embedding table with HNSW index** — async, D2, form **U**
Scope 1–100 rows · matview 100k–100M rows
**Index maintenance dominates**, not the refresh. My timings are for a btree-only
matview; an HNSW or GIN index makes each refreshed row far more expensive, so the
~500-row crossover does not transfer and batches want to be much smaller. Measure
before choosing a batch size. Also note the upsert form updates in place, which
for a vector index means a delete plus insert in the index regardless.

### Content and social

**33. Comment / reaction counts** — sync, D1, form **U**
Scope 1 post · matview 1M–1B rows

**34. Feed fan-out** — **anti-case**
Scope: one post by a user with N followers dirties N rows · matview 100M–100B
Write amplification makes this the wrong tool: a celebrity post dirties tens of
millions of feed rows in one statement. Fan-out on read, or a dedicated fan-out
service. Listed because it looks superficially like case 33.

**35. Trending / ranking table** — **anti-case**, see blast radius
Scores are relative, so any change reorders everything. Rebuild on a schedule.

### Industrial, energy, logistics

**36. OEE / line performance rollup** — async, D3, form **S**
Scope one line-shift · matview 100k–10M rows

**37. Bill-of-materials rolled-up cost** — async, D2, form **S**
Scope all ancestors of the changed part · matview 100k–10M rows
Recursive **and** blast-radius: a raw-material price change propagates up through
every assembly containing it. The affected set is an ancestor closure that the
trigger must compute; refreshing only the changed part is silently wrong.

**38. Smart meter (AMI) interval aggregation** — async, D3, form **S**
Scope one interval, 100k–10M readings · matview 10M–10B rows
Late and revised readings are routine, so the same trailing-window problem as
metric downsampling — and here revisions arrive days later.

**39. Grid outage impact** — async, D2, form **S**
Scope downstream subtree of a switch · matview 100k–10M rows · recursive

**40. Shipment tracking projection** — sync, D1, form **U**
Scope 1 shipment · matview 10M–1B rows

### Public sector and education

**41. Election tabulation** — async, D3, form **S** — blast radius via percentages
Scope one precinct's contests · matview 10k–1M rows
Vote *counts* are per-precinct and partition cleanly; *percentages and margins*
are relative to a contest total, so any precinct reporting changes every
candidate's share in that contest. Refresh by contest, not by precinct.

**42. Degree audit / requirement satisfaction** — sync, D1, form **U**
Scope 1 student · matview 100k–10M rows
Requirement rules are recursive per student but the blast radius stays inside one
student, which makes it a safe case despite looking like a graph problem.

**43. Transit schedule derivation (GTFS)** — async, D3, form **F** or **S**
Scope one service calendar · matview 1M–100M rows
Published as versioned feeds, so a feed change replaces nearly everything —
usually a rebuild.

### Security and compliance

**44. Entitlement snapshot** — sync, D1, form **U**
Scope 1 principal · matview 100k–10M rows · see also case 14

**45. SIEM correlation / detection state** — async, D2, form **S**
Scope one entity's window · matview 1M–1B rows

**46. Data lineage graph** — async, D2, form **S** · recursive, unbounded blast
radius

### Other

**47. Blockchain address balances from UTXO** — async, D2, form **U**
Scope addresses in a block, 1k–100k · matview 100M–1B rows
Block-driven batching is natural, and reorgs mean the driver needs to re-refresh
addresses from orphaned blocks — a rollback path most queue designs lack.

**48. Astronomical cross-match catalogue** — async, D3, form **S**
Scope one sky region / survey epoch · matview 100M–100B rows

**49. Travel availability calendar** — sync, D1, form **U**
Scope one property × date range · matview 10M–1B rows

**50. Ad frequency capping counters** — **anti-case**
Scope 1 (user, campaign) · write rate 10k+/s
Too hot for any refresh mechanism; a plain counter table with an upsert, or a
counter store outside the database. Listed because it is a rollup by shape and
will be proposed.

### Cases the feature does not serve

Along with the anti-cases above: 34 (feed fan-out, write amplification), 35
(trending, blast radius), 50 (frequency capping, write rate).

**51. Incremental backfill of a new matview** — **not supported**
`WITH NO DATA` plus `WHERE` is rejected, and `WHERE` requires a populated
matview, so a large matview cannot be built in chunks. Worth deciding whether
that is a deliberate restriction or a gap.

**52. Wide row with one high-velocity column** (Kirk's case from the thread)
Scope 1 · matview any size
Refreshing rewrites the whole row including the expensive computed columns.
Split the volatile column into its own small matview or table and join at query
time — the advice given on-list, and still right.

**53. Anything whose definition reads the clock** — see AR aging (case 3) and
the SLO error budget (case 17). No predicate can express "every row aged by one
day"; only a rebuild handles the date roll.

---

## Selection rule

1. Is the predicate on a **grouping key**, indexed on **both** the matview and
   the base tables? If not, fix that first — nothing else matters by comparison.
2. Rows selected **> ~10% of the matview** → full rebuild.
3. Rows selected **> ~500** → bare form.
4. Otherwise → `CONCURRENTLY`, driven by a statement-level trigger (sync) or a
   queue and drainer (async), always passing keys as an **array parameter**.
