--
-- REFRESH MATERIALIZED VIEW ... WHERE ... : SQL injection
--
-- A partial refresh builds SQL text and runs it.  Everything interpolated into
-- that text is attacker-influenced in the sense that matters: object names are
-- chosen by whoever created the matview, and the predicate is chosen by whoever
-- issues the REFRESH.  Neither is a string the server may take on trust, and
-- each reaches the statement by a different route -- identifiers through
-- quote_identifier(), the predicate through a deparse of its parse tree, the
-- view body through pg_get_viewdef().
--
-- Which generator a case reaches is decided by the matview, not by how the
-- REFRESH is spelled -- and the three forms every case runs under are not the
-- same thing as the generator:
--
--   direct     refresh_by_direct_modification(), taken by a predicate on a
--              matview with at most one unique index, either spelling.  It
--              builds its own SQL text: from the view's SQL under the `spi`
--              form, and from its Query tree under `querytree`.
--   diff/merge the transient-heap fill in ExecRefreshMatView(), which splices
--              the view body and the predicate into
--              "INSERT INTO <t> SELECT * FROM (<view>) _mv_q WHERE <qual>",
--              and then refresh_by_match_merge(), which splices the predicate
--              a second time and every column name besides.  Taken by a
--              predicate on a matview with more than one unique index.
--
-- The `bare` form used to select diff/merge, and this header used to say so.
-- Routing then moved onto the unique-index count, and since Tests 1 to 8 all
-- use a matview with one unique index, all three of their forms go to direct
-- modification and none of them reaches refresh_by_match_merge() at all.  No
-- test changed and nothing went red; it was found by measuring, with Q2.  That
-- is what Test 9 exists to reach, and it does it with a second unique index
-- rather than a different spelling.
--
-- Nothing here should be able to fail.  That is the point: these are the tests
-- that stay green while the generated SQL is removed, and each one names the
-- escape it would take if a quoting call were dropped or a new string were
-- concatenated in without one.  A refresh that generates no SQL at all cannot
-- fail them, which is the argument for the rewrite stated as a test rather
-- than as a claim.
--
-- Disposition: keep.  When the GUC goes, drop 'querytree' from the form arrays
-- and the SET/SHOW pair that pins and checks it; the cases themselves outlive
-- all three implementations -- an identifier-quoting regression is exactly what
-- a later refactor reintroduces -- and the bare path keeps generating SQL after
-- the concurrent one stops.
--
-- Found here, not on the -hackers thread.

CREATE SCHEMA mvinj;
SET search_path = mvinj, public;

-- Pin the session default.  Every case below selects its implementation
-- explicitly, so nothing here depends on this value -- but the leak check after
-- Test 1 prints it, and that has to read the same whether the suite was started
-- with the GUC defaulted on or off.
SET matview_partial_refresh_querytree = off;

-- The canary.  Nothing any test does may change this table; every case that
-- could escape the generated SQL is written so that a successful escape would
-- write to it.  Checked once at the end, so a failure cannot be missed by a
-- test that forgets to look.
CREATE TABLE victim (note text);
INSERT INTO victim VALUES ('untouched');

--
-- Run one case under each implementation.
--
-- The base is mutated afresh before every form, and the matview read back
-- after every form, because otherwise this proves much less than it looks like
-- it does: the first form leaves the matview correct, and a later form that
-- silently refreshed nothing would read back the first form's answer and pass.
-- The mutation carries the iteration number into the data, so each form has to
-- produce a value only it could have produced.
--
--   %1$s   a fresh value, 901 then 902 then 903
--   %2$s   the iteration, 1 then 2 then 3
--
CREATE FUNCTION refresh_forms(mv text, pred text, mutate text, readback text)
RETURNS TABLE(form text, contents text) LANGUAGE plpgsql AS $$
DECLARE
  forms text[] := ARRAY['bare', 'spi', 'querytree'];
  i     int;
BEGIN
  FOR i IN 1 .. array_length(forms, 1) LOOP
    EXECUTE format(mutate, 900 + i, i);
    IF forms[i] = 'bare' THEN
      EXECUTE format('REFRESH MATERIALIZED VIEW %s WHERE %s', mv, pred);
    ELSE
      EXECUTE format('SET LOCAL matview_partial_refresh_querytree = %s',
                     CASE forms[i] WHEN 'querytree' THEN 'on' ELSE 'off' END);
      EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s WHERE %s',
                     mv, pred);
    END IF;
    form := forms[i];
    EXECUTE readback INTO contents;
    RETURN NEXT;
  END LOOP;
END $$;

--
-- Test 1: a matview whose name closes the identifier and starts a new statement
--
-- The name reaches the generated SQL through quote_qualified_identifier() for
-- the INSERT and DELETE targets and quote_identifier() for the subquery alias.
-- Drop either call and the embedded quote closes the identifier, the semicolon
-- ends the statement, and the trailing comment swallows the rest.
--
CREATE TABLE inj1_base (id int PRIMARY KEY, v int);
INSERT INTO inj1_base SELECT g, g * 10 FROM generate_series(1, 5) g;
CREATE MATERIALIZED VIEW "mv1"";INSERT INTO victim VALUES('pwned-name');--"
  AS SELECT id, v FROM inj1_base;
CREATE UNIQUE INDEX ON "mv1"";INSERT INTO victim VALUES('pwned-name');--" (id);

SELECT * FROM refresh_forms(
  $i$"mv1"";INSERT INTO victim VALUES('pwned-name');--"$i$,
  $p$id <= 2$p$,
  $m$UPDATE inj1_base SET v = %s WHERE id <= 2$m$,
  $r$SELECT string_agg(id || '=' || v, ' ' ORDER BY id)
       FROM "mv1"";INSERT INTO victim VALUES('pwned-name');--"$r$);

-- SET LOCAL inside the function must not have escaped it.
SHOW matview_partial_refresh_querytree;

--
-- Test 2: a column name that does the same
--
-- Column names are interpolated in more places than the relation name: the
-- ON CONFLICT target list, the DO UPDATE SET list, the anti-join condition and
-- the ORDER BY on the concurrent path, and the ROW(...) comparison on the bare
-- one.  A hostile name in the arbiter key reaches all of them.
--
CREATE TABLE inj2_base ("k"";INSERT INTO victim VALUES('pwned-col');--" int
                          PRIMARY KEY,
                        "v ""odd"" name" int);
INSERT INTO inj2_base SELECT g, g * 10 FROM generate_series(1, 5) g;
CREATE MATERIALIZED VIEW inj2_mv AS SELECT * FROM inj2_base;
CREATE UNIQUE INDEX ON inj2_mv ("k"";INSERT INTO victim VALUES('pwned-col');--");

SELECT * FROM refresh_forms(
  $i$inj2_mv$i$,
  $p$"k"";INSERT INTO victim VALUES('pwned-col');--" <= 2$p$,
  $m$UPDATE inj2_base SET "v ""odd"" name" = %s
      WHERE "k"";INSERT INTO victim VALUES('pwned-col');--" <= 2$m$,
  $r$SELECT string_agg(k || '=' || v, ' ' ORDER BY k)
       FROM (SELECT "k"";INSERT INTO victim VALUES('pwned-col');--" AS k,
                    "v ""odd"" name" AS v FROM inj2_mv) s$r$);

--
-- Test 3: a hostile string literal in the predicate
--
-- The predicate arrives as a parse tree and is rendered back to text with
-- pg_get_expr().  A literal containing a quote has to come back out re-escaped;
-- if it came back verbatim it would terminate the string and the rest of the
-- literal would be parsed as SQL.  The bare path renders it twice, into two
-- different statements.
--
-- The mutation touches every row while the predicate covers one, so a predicate
-- that failed to restrict would show up as 'ok' moving too.
--
CREATE TABLE inj3_base (tag text PRIMARY KEY, v int);
INSERT INTO inj3_base
  VALUES ('ok', 1), (''';INSERT INTO victim VALUES(''pwned-lit'');--', 2);
CREATE MATERIALIZED VIEW inj3_mv AS SELECT tag, v FROM inj3_base;
CREATE UNIQUE INDEX ON inj3_mv (tag);

SELECT * FROM refresh_forms(
  $i$inj3_mv$i$,
  $p$tag = ''';INSERT INTO victim VALUES(''pwned-lit'');--'$p$,
  $m$UPDATE inj3_base SET v = %s$m$,
  $r$SELECT string_agg(tag || '=' || v, ' | ' ORDER BY tag) FROM inj3_mv$r$);

--
-- Test 4: the same string arriving as a bound parameter
--
-- A different route entirely: the value never becomes text in the generated
-- statement.  Worth pinning separately, because a "simplification" that inlined
-- parameters into the SQL would pass Test 3 and fail here.
--
-- The bound value has to name a row that exists, and one that Test 3 did not
-- already refresh.  An earlier revision bound a tag matching nothing: all three
-- refreshes were no-ops, all three read back the value Test 3 had left behind,
-- and the case passed without executing anything it claimed to test.  The row
-- is new, so this covers the insert side of the upsert as well.
--
INSERT INTO inj3_base
  VALUES (''';INSERT INTO victim VALUES(''pwned-param'');--', 3);

CREATE FUNCTION refresh_forms_param(mv text, val text, mutate text,
                                    readback text)
RETURNS TABLE(form text, contents text) LANGUAGE plpgsql AS $$
DECLARE
  forms text[] := ARRAY['bare', 'spi', 'querytree'];
  i     int;
BEGIN
  FOR i IN 1 .. array_length(forms, 1) LOOP
    EXECUTE format(mutate, 900 + i, i);
    IF forms[i] = 'bare' THEN
      EXECUTE format('REFRESH MATERIALIZED VIEW %s WHERE tag = $1', mv)
        USING val;
    ELSE
      EXECUTE format('SET LOCAL matview_partial_refresh_querytree = %s',
                     CASE forms[i] WHEN 'querytree' THEN 'on' ELSE 'off' END);
      EXECUTE format('REFRESH MATERIALIZED VIEW CONCURRENTLY %s WHERE tag = $1',
                     mv) USING val;
    END IF;
    form := forms[i];
    EXECUTE readback INTO contents;
    RETURN NEXT;
  END LOOP;
END $$;

SELECT * FROM refresh_forms_param(
  $i$inj3_mv$i$,
  ''';INSERT INTO victim VALUES(''pwned-param'');--',
  $m$UPDATE inj3_base SET v = %s$m$,
  $r$SELECT string_agg(tag || '=' || v, ' | ' ORDER BY tag) FROM inj3_mv$r$);

--
-- Test 5: a schema name that closes the qualified identifier
--
-- quote_qualified_identifier() quotes both halves.  A hostile schema name tests
-- the half a test using only the relation name would miss -- and on the bare
-- path it is the schema of the matview being joined against, not just of the
-- insert target.
--
CREATE SCHEMA "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--";
CREATE TABLE "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".b
  (id int PRIMARY KEY, v int);
INSERT INTO "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".b
  SELECT g, g FROM generate_series(1, 3) g;
CREATE MATERIALIZED VIEW
  "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".mv AS
  SELECT id, v FROM "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".b;
CREATE UNIQUE INDEX ON
  "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".mv (id);

SELECT * FROM refresh_forms(
  $i$"s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".mv$i$,
  $p$id = 1$p$,
  $m$UPDATE "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".b
       SET v = %s WHERE id = 1$m$,
  $r$SELECT string_agg(id || '=' || v, ' ' ORDER BY id)
       FROM "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--".mv$r$);

--
-- Test 6: view data that looks like the end of a statement
--
-- The view body is spliced into "SELECT * FROM (<view>) _mv_q WHERE <qual>" on
-- the bare path and into a CTE on the concurrent one.  If a deparse could end
-- in an unterminated line comment or an open block comment, everything the
-- wrapper appends after it -- the closing paren, the alias, the predicate --
-- would be commented out and the refresh would silently widen to the whole
-- view.  pg_get_viewdef() does not emit comments, so this passes; it is here
-- because that failure mode is silent rather than loud.
--
-- The mutation touches all three rows and the predicate covers one.  A widened
-- refresh shows up as rows 1 and 2 moving.
--
CREATE TABLE inj6_base (id int PRIMARY KEY, note text, v int);
INSERT INTO inj6_base VALUES (1, '-- not a comment', 10), (2, '/* nor this', 20),
                             (3, '''); INSERT INTO victim VALUES (''pwned-view''); --', 30);
CREATE MATERIALIZED VIEW inj6_mv AS SELECT id, note, v FROM inj6_base;
CREATE UNIQUE INDEX ON inj6_mv (id);

SELECT * FROM refresh_forms(
  $i$inj6_mv$i$,
  $p$id = 3$p$,
  $m$UPDATE inj6_base SET v = %s$m$,
  $r$SELECT string_agg(id || '=' || v, ' ' ORDER BY id) FROM inj6_mv$r$);

--
-- Test 7: real relations named after every name the generated statements use
--
-- Between them the three generators invent seven names: the CTEs new_data,
-- upsert and pruned, and the aliases mv, nd, _mv_q and newdata.  Each is a
-- perfectly legal table name, and a user who has one in the search path must be
-- unaffected -- each statement's own names have to win inside it and lose
-- outside it.
--
-- This is the case that can go wrong rather than merely look dangerous, and the
-- one where the implementations differ most: new_data is a CTE on one path and
-- an ephemeral named relation on the other, and name resolution reaches them by
-- different routes.  If either resolved to the user's table, the refresh would
-- upsert someone else's rows.
--
-- Each form deletes a different base row, so each has both an upsert and a
-- prune of its own to perform: bare drops id 3, spi id 4, querytree id 5.
--
CREATE TABLE new_data (id int, v int);
CREATE TABLE upsert   (id int, v int);
CREATE TABLE pruned   (id int, v int);
CREATE TABLE mv       (id int, v int);
CREATE TABLE nd       (id int, v int);
CREATE TABLE _mv_q    (id int, v int);
CREATE TABLE newdata  (id int, v int);
INSERT INTO new_data VALUES (-1, -1), (-2, -2);
INSERT INTO upsert   VALUES (-3, -3);
INSERT INTO pruned   VALUES (-4, -4);
INSERT INTO mv       VALUES (-5, -5);
INSERT INTO nd       VALUES (-6, -6);
INSERT INTO _mv_q    VALUES (-7, -7);
INSERT INTO newdata  VALUES (-8, -8);

CREATE TABLE inj7_base (id int PRIMARY KEY, v int);
INSERT INTO inj7_base SELECT g, g FROM generate_series(1, 6) g;
CREATE MATERIALIZED VIEW inj7_mv AS SELECT id, v FROM inj7_base;
CREATE UNIQUE INDEX ON inj7_mv (id);

SELECT * FROM refresh_forms(
  $i$inj7_mv$i$,
  $p$id <= 6$p$,
  $m$WITH d AS (DELETE FROM inj7_base WHERE id = 2 + %2$s RETURNING 1)
     UPDATE inj7_base SET v = %1$s WHERE id = 1$m$,
  $r$SELECT string_agg(id || '=' || v, ' ' ORDER BY id) FROM inj7_mv$r$);

-- No negative ids anywhere; none of the shadowed tables was read or written.
SELECT 'new_data' AS t, count(*) FROM new_data
UNION ALL SELECT 'upsert', count(*) FROM upsert
UNION ALL SELECT 'pruned', count(*) FROM pruned
UNION ALL SELECT 'mv',     count(*) FROM mv
UNION ALL SELECT 'nd',     count(*) FROM nd
UNION ALL SELECT '_mv_q',  count(*) FROM _mv_q
UNION ALL SELECT 'newdata', count(*) FROM newdata ORDER BY 1;

--
-- Test 8: columns named after the aliases and output columns the statements use
--
-- The concurrent anti-join is written "nd.<col> = mv.<col>", so a column
-- literally called mv or nd is qualified by a name that is also a table alias.
-- The bare path is worse: it selects "mv.ctid AS tid ... ORDER BY tid", so a
-- matview column called tid gives ORDER BY a name that matches both an output
-- column and an input column, and it joins against an alias called newdata.
-- All of them have to resolve the way the generator intended.
--
CREATE TABLE inj8_base (id int PRIMARY KEY, mv int, nd int, new_data int,
                        tid int, newdata int);
INSERT INTO inj8_base SELECT g, g, g, g, g, g FROM generate_series(1, 3) g;
CREATE MATERIALIZED VIEW inj8_mv AS
  SELECT id, mv, nd, new_data, tid, newdata FROM inj8_base;
CREATE UNIQUE INDEX ON inj8_mv (id, mv);

SELECT * FROM refresh_forms(
  $i$inj8_mv$i$,
  $p$mv = 2$p$,
  $m$UPDATE inj8_base SET nd = %s WHERE id = 2$m$,
  $r$SELECT string_agg(id || ':' || mv || ',' || nd || ',' || new_data
                       || ',' || tid || ',' || newdata, ' ' ORDER BY id)
       FROM inj8_mv$r$);

--
-- Test 9: a hostile name on the MATCH/MERGE path
--
-- Tests 1 to 8 all put their matview behind a single unique index, so routing
-- (`qual && !skipData && nUniqueIndexes <= 1`) sends every one of them to
-- refresh_by_direct_modification().  That leaves quote_qualified_identifier()
-- in refresh_by_match_merge() covered by nothing, and it is a separate call
-- site: mutation Q2 drops it and the whole file stays green, while Q1 and Q3 --
-- the same defect on the direct-modification path -- are both caught.  Found by
-- calibrate-all.sh; ISSUES.md B28.
--
-- Two unique indexes are what reaches the other path, and that is the only
-- structural difference from Test 1.  The bare form is used deliberately: with
-- more than one unique index BOTH spellings route to match/merge, so this does
-- not need refresh_forms()'s three-way sweep to get there.
--
-- Disposition: keep.  It is the only coverage of identifier quoting on the
-- match/merge path, and that path survives even if the direct-modification one
-- is rewritten.
--
CREATE TABLE inj9_base (id int PRIMARY KEY, alt int, v int);
INSERT INTO inj9_base SELECT g, g + 100, g * 10 FROM generate_series(1, 5) g;

CREATE MATERIALIZED VIEW "mv9"";INSERT INTO victim VALUES('pwned-merge');--"
  AS SELECT id, alt, v FROM inj9_base;
-- Two of them, so routing takes match/merge rather than direct modification.
CREATE UNIQUE INDEX ON "mv9"";INSERT INTO victim VALUES('pwned-merge');--" (id);
CREATE UNIQUE INDEX ON "mv9"";INSERT INTO victim VALUES('pwned-merge');--" (alt);

UPDATE inj9_base SET v = 999 WHERE id <= 2;
REFRESH MATERIALIZED VIEW "mv9"";INSERT INTO victim VALUES('pwned-merge');--"
  WHERE id <= 2;

SELECT string_agg(id || '=' || v, ' ' ORDER BY id)
  FROM "mv9"";INSERT INTO victim VALUES('pwned-merge');--";

DROP MATERIALIZED VIEW "mv9"";INSERT INTO victim VALUES('pwned-merge');--";
DROP TABLE inj9_base;

--
-- The canary, once, at the end.
--
SELECT note, count(*) FROM victim GROUP BY note ORDER BY note;

RESET search_path;
DROP SCHEMA "s"";INSERT INTO mvinj.victim VALUES('pwned-schema');--" CASCADE;
DROP SCHEMA mvinj CASCADE;
