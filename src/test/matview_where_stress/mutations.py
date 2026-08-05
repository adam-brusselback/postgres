#!/usr/bin/env python3
"""Re-introduce known bugs into matview.c, one at a time.

    ./mutations.py B4            apply
    ./mutations.py pristine      restore
    ./mutations.py --list        show the corpus
    ./mutations.py --check       verify every mutation still applies
    ./mutations.py --overlay=B4  apply on top of the working tree, not HEAD

Pristine is defined as `git show HEAD:src/backend/commands/matview.c`, not as a
copy kept somewhere.  A copy is a thing that can drift from what it claims to be
without anyone noticing, which is the failure mode this whole directory keeps
running into.

Every mutation must be an *undo of a fix that was actually made*, not an
invented defect.  The point is to measure whether a detector finds the bugs we
already know were real -- a detector nobody has watched catch anything is the
same defect as a test that cannot fail, one level up.  See PLAN.md 1.1c.

Each entry names the issue it reverts and states what the detector would have to
observe to notice, because those are not the same for all of them: some corrupt
the matview in a single session, and some only misbehave when two sessions
overlap.  A single-session oracle can only ever see the first kind.
"""
import subprocess
import sys

TARGET = 'src/backend/commands/matview.c'

# (issue, needs, description, [(old, new) or (old, new, occurrences), ...])
#
#   needs='data'    observable by one session: the matview contents end up wrong
#   needs='concur'  observable only with two overlapping sessions
#   needs='inject'  a quoting escape; observable by matview_where_inject
MUTATIONS = {
    # NB: this stopped applying when the row comparison landed, because that
    # inserted a WHERE ... IS DISTINCT FROM between the UPDATE SET and the else,
    # and nothing noticed -- a mutation that cannot be applied is a detector
    # that has never fired, one level up from a test that cannot fail.  The
    # occurrence counts below exist so the same drift is loud next time.
    'A4': ('A4', 'data',
           'drop ON CONFLICT from the upsert (scope drift)', [
               ('"  ON CONFLICT (%s) DO ",', '"  /*%s*/ ",', 1),
               ('\t\t\t\tappendStringInfo(&buf,\n'
                '\t\t\t\t\t\t\t\t "UPDATE SET %s WHERE (%s) IS DISTINCT FROM (%s) ",\n'
                '\t\t\t\t\t\t\t\t set_clause.data, mv_cols.data, excluded_cols.data);\n'
                '\t\t\telse\n'
                '\t\t\t\tappendStringInfoString(&buf, "NOTHING ");',
                '\t\t\t\tappendStringInfo(&buf,\n'
                '\t\t\t\t\t\t\t\t "/*%s %s %s*/ ",\n'
                '\t\t\t\t\t\t\t\t set_clause.data, mv_cols.data, excluded_cols.data);\n'
                '\t\t\telse\n'
                '\t\t\t\tappendStringInfoString(&buf, " ");', 1),
           ]),

    'B4': ('B4', 'data',
           'anti-join ignores the arbiter index NULL handling '
           '(duplicates NULL-keyed rows)', [
               ('anti_join_op = indexStruct->indnullsnotdistinct ?\n'
                '\t\t\t\t"IS NOT DISTINCT FROM" : "=";',
                'anti_join_op = "IS NOT DISTINCT FROM";', 1),
           ]),

    # The other half of B4's fix.  B4 forces IS NOT DISTINCT FROM everywhere and
    # duplicates NULL-keyed rows; this forces plain equality everywhere and
    # DELETES them -- on an index declared NULLS NOT DISTINCT the upsert matches
    # a NULL-keyed row and updates it, while the anti-join's "nd.k = mv.k"
    # evaluates to NULL, so NOT EXISTS holds and the prune removes the row the
    # upsert just wrote.  Silent data loss, every refresh.
    #
    # Not invented: TimescaleDB shipped exactly this in their continuous
    # aggregate refresh and fixed it in #8151 ("Treat null equal to null for
    # merged CAgg refresh"), a one-line change from "=" to IS NOT DISTINCT FROM
    # in the same anti-join position.  Their prune is DELETE ... WHERE <scope>
    # AND NOT EXISTS (<new data>), the same statement shape as ours.
    #
    # VERIFIED BENIGN on this architecture, which is the interesting part.
    # Applied to a NULLS NOT DISTINCT matview with a NULL-keyed row in scope,
    # the row is updated (150 -> 1099) and survives; the corpus reports 0/48
    # divergences on the case added to catch it.  The upsert and the prune are
    # ONE statement over ONE snapshot, so the DELETE cannot remove a row the
    # upsert already modified in the same command -- the upsert wins.
    #
    # TimescaleDB's MERGE and DELETE are separate statements: the MERGE commits
    # its update, then the DELETE re-reads the row and removes it.  Same
    # operator, opposite outcome, and the only difference is statement fusion.
    # Worth stating on-list: fusing the upsert and the prune is not merely
    # fewer scans, it closes a data-loss class that a mature implementation of
    # this same algorithm shipped.
    #
    # The asymmetry with B4 follows: forcing IS NOT DISTINCT FROM *is* a real
    # bug, because there the two halves disagree -- a NULLS DISTINCT index lets
    # the upsert insert a duplicate NULL row while the anti-join declines to
    # clean it up.  The operator only matters when upsert and prune disagree.
    'B4b': ('B4', 'benign',
            'anti-join always uses plain equality '
            '(benign here -- see above; TimescaleDB #8151)', [
                ('anti_join_op = indexStruct->indnullsnotdistinct ?\n'
                 '\t\t\t\t"IS NOT DISTINCT FROM" : "=";',
                 'anti_join_op = "=";', 1),
            ]),

    # The row comparison must stay null-safe.  IS DISTINCT FROM looks like an
    # obvious candidate for "optimize to <>", and the anti-join a few lines away
    # really does pick = when the arbiter index allows it, which makes the idea
    # look sanctioned.  It is not: if a non-key column is NULL on either side,
    # (a,b) <> (c,d) is NULL rather than true, the WHERE is not satisfied, and
    # the row is silently left stale -- no error, no divergence in the row
    # count, just a matview that disagrees with its query forever.
    #
    # Nor can it be gated the way the anti-join is.  A matview column never
    # carries attnotnull, even when every source column is NOT NULL and even for
    # one derived from a primary key, so there is no catalog fact to prove
    # non-nullness from.
    #
    'B7': ('-', 'data',
           'row comparison uses <> instead of IS DISTINCT FROM '
           '(NULL-valued rows silently never update)', [
               ('"UPDATE SET %s WHERE (%s) IS DISTINCT FROM (%s) ",',
                '"UPDATE SET %s WHERE (%s) <> (%s) ",', 1),
           ]),

    # B7's neighbour, and the one that says whether B7's gate is measuring
    # anything.  O1 stops the comparison being emitted at all: every matched row
    # is rewritten, which is what the code did before 03cb4f0 and is still
    # correct, so nothing about the matview's *contents* changes.
    #
    # That is exactly why it belongs here.  A test that only reads values back
    # cannot tell the comparison from its absence, and would pass unchanged on a
    # tree where it had silently stopped being emitted.
    'O1': ('-', 'perf',
           'the row comparison is never emitted (optimisation silently off)', [
               ('\t\t\t\tappendStringInfo(&buf,\n'
                '\t\t\t\t\t\t\t\t "UPDATE SET %s WHERE (%s) IS DISTINCT FROM (%s) ",\n'
                '\t\t\t\t\t\t\t\t set_clause.data, mv_cols.data, excluded_cols.data);',
                '\t\t\t\tappendStringInfo(&buf, "UPDATE SET %s ",\t/* O1 */\n'
                '\t\t\t\t\t\t\t\t set_clause.data);'),
           ]),

    # O2 was DELETED with the developer GUC it mutated, and the reason it is not
    # simply repointed is worth keeping.
    #
    # It dropped `optimized` from the plan-cache key, which was the only input
    # to that key that changed the generated SQL without changing the matview's
    # contents -- so it needed matview_where_cache Test 6 to read ctids back.
    # The GUC is gone and the row comparison is unconditional, so there is no
    # such input left.  What remains of the rule -- that the key must look at
    # what the plans were built from -- is C7's, and C7's gate reads values
    # rather than row versions because a confused predicate refreshes the wrong
    # rows outright.

    # B6 was DELETED, not repointed, and the reason is worth keeping.
    #
    # It dropped the primary-key preference in the arbiter search, and
    # calibrate-all.sh found nothing could catch it.  That turned out to be
    # correct rather than a gap: a materialized view cannot have a primary key
    # at all -- ALTER ... ADD CONSTRAINT rejects matviews -- so indisprimary is
    # never true on an index one owns, and the preference could not change any
    # outcome.  Both copies of it are gone from matview.c, so there is nothing
    # left for this mutation to edit.
    #
    # What that search still does is reject unusable indexes via
    # is_usable_unique_index(), and THAT is live and has no test -- see
    # ISSUES.md B29.  A mutation for it belongs here once a test exists; adding
    # one now would only put a known-UNCAUGHT row in the matrix.

    # A5 and M1 are the same edit.  A5 is the issue; M1 was the name it went by
    # in the B17 mutation matrix.  Keeping both names avoids a rename in the
    # calibration table, but they are one mutation and should be reported once.
    # Not a bug that shipped -- it is the guard for matview_where_cache.
    #
    # Tests 1 to 3 in that file assert that a cached plan is thrown away when
    # the relation it names is renamed or replaced.  For a long stretch they
    # asserted nothing at all: every refresh in them was the bare form, and
    # commit 0607847 had swapped the bare form onto refresh_by_match_merge(),
    # which caches nothing.  They passed because there was no cache in the way.
    # Having fixed that, the question is whether they can now FAIL, and this is
    # how that gets answered: drop the relcache callback and the stale entry
    # survives the rename.  If matview_where_cache stays green with C1 applied,
    # the file is still not a guard and the fix did not finish the job.
    # The guard for B14's second fix, and for fuzz.sh's nest mode.
    #
    # A nested partial refresh must not touch the session cache: matview_cache_
    # sweep() would free the plans the ENCLOSING refresh is still executing from,
    # and dynahash hands the removed element straight back to the nested call.
    # Restoring `use_cache = true` reinstates exactly that.
    #
    # C1's sibling, and it exists because C1 alone leaves the newer guard with no
    # mutation that has ever broken it.  matview_where_cache Test 5 should fail
    # with this applied, and so should fuzz.sh's nest mode -- Test 5 manufactures
    # the invalidation with an ALTER TABLE, nest gets it from other backends
    # committing, and a guard that survived only one of those is worth knowing
    # about.
    'C2': ('B14', 'cache',
           'let a nested refresh share the session plan cache '
           '(reopens the use-after-free)', [
               ('\tuse_cache = (matview_maintenance_depth == 0);',
                '\tuse_cache = true;\t\t\t/* C2 */', 1),
           ]),

    'C1': ('-', 'cache',
           'never invalidate the partial-refresh plan cache', [
               ('\tCacheRegisterRelcacheCallback(InvalidateMatViewCache, (Datum) 0);',
                '\t/* C1: callback not registered */'),
           ]),

    # The guard for matview-where-prune-gap.
    #
    # On the Query-tree path the source is evaluated into a tuplestore by a
    # separate executor run, so the DML that reads it has to run under the SAME
    # snapshot the evaluation used -- otherwise the prune compares a matview read
    # at one instant against source rows computed at another, and deletes
    # whatever appeared in between.  Passing InvalidSnapshot makes SPI take a
    # fresh one, which is exactly that gap.
    #
    # The spec's header claims it was verified against a build with the bug
    # present.  This is that claim made re-runnable rather than remembered.
    # 3.7's siblings for C1.  The source plansource is a third saved object on
    # the entry and needs its own mutations, or the mechanism ships with nothing
    # ever seen to break it -- CACHE.md step D, with B23 as the precedent.
    #
    # C3 is the dangerous one.  The entry is keyed on the arbiter index, the
    # deparsed predicate and the argument types, and a mismatch rebuilds the two
    # SPI plans.  Leave the source plansource behind and the next refresh
    # evaluates the *previous* predicate's source query while the DML around it
    # is built for the new one: wrong rows, silently, from a cache that looks
    # like it is working.
    'C3': ('-', 'data',
           'the source plansource survives a cache-key mismatch '
           '(a changed predicate reuses the old source query)', [
               ('\t\t\tif (cacheEntry->sourcePlan)\n'
                '\t\t\t\tDropCachedPlan(cacheEntry->sourcePlan);\n', ''),
               ('\t\tcacheEntry->refreshPlan = NULL;\n'
                '\t\tcacheEntry->sourcePlan = NULL;\n',
                '\t\tcacheEntry->refreshPlan = NULL;\n'),
           ]),

    # C4 is perf-only and calibrates the reuse probe rather than being a
    # correctness bug: rebuilding the source plan every refresh is what the code
    # did before 3.7 and is still correct.  Same shape as O1 -- an optimisation
    # that silently stops applying, invisible to anything reading the matview's
    # contents.  It drops before rebuilding rather than simply not storing, so
    # it is a lifetime change and not a leak; a mutation that also leaked would
    # be caught for the wrong reason.
    'C4': ('-', 'perf',
           'the source plan is rebuilt on every refresh (3.7 silently off)', [
               ('\t\t\tif (cacheEntry->sourcePlan == NULL)\n\t\t\t{',
                '\t\t\tif (cacheEntry->sourcePlan != NULL)\n'
                '\t\t\t{\n'
                '\t\t\t\tDropCachedPlan(cacheEntry->sourcePlan);\n'
                '\t\t\t\tcacheEntry->sourcePlan = NULL;\n'
                '\t\t\t}\n'
                '\t\t\tif (cacheEntry->sourcePlan == NULL)\n\t\t\t{'),
           ]),

    # C5, like C4, is perf-only: leaving the predicate's constants as constants
    # is what the code did before and is still correct in every observable way.
    # The refresh acts on exactly the same rows; the only difference is that a
    # caller varying the literal misses the plan cache on every call, which is
    # 250 us a refresh and most of a scope-1 one.
    #
    # It switches the eligibility test off rather than the call site, so every
    # function stays reachable and the compiler has nothing to say about it --
    # and so the "before" arm of the measurement differs from the "after" arm in
    # this one decision and nothing else, which is what C4 exists to provide for
    # the source plan and is why R34 could be read inside one configuration.
    'C5': ('-', 'perf',
           'predicate constants stay constants (the plan cache misses again)', [
               ('refresh_const_is_paramizable(Const *con)\n{\n',
                'refresh_const_is_paramizable(Const *con)\n{\n\treturn false;\n', 1),
           ]),

    # C6 is the other half of C5, and the two are not interchangeable.
    #
    # C5 turns the parameterisation OFF, which is what the code did before and
    # is still correct: the right rows are refreshed, just after re-planning
    # every call.  So C5 is what matview_where_source_plan part 3 goes red
    # against, and matview_where Test 19 stays green under it -- correctly,
    # because there is nothing wrong to see.
    #
    # C6 leaves it on and breaks the BINDING.  lcons prepends where lappend
    # appends, so the collected Consts land in the reverse of the order their
    # paramids were handed out in, and "WHERE a = 1 AND b = 2" binds a=2, b=1.
    # That refreshes a real row with a valid plan and reports success; the only
    # evidence is that it is the wrong row.  This is the failure the shared
    # cache entry makes possible and the one Test 19 exists for.
    #
    # A predicate with a single constant is unaffected, which is the point: the
    # detector has to be a case that carries two, and most of the suite does
    # not.
    'C6': ('-', 'data',
           'predicate constants bind in reverse order (wrong rows refreshed)', [
               ('\t\tctx->consts = lappend(ctx->consts, con);',
                '\t\tctx->consts = lcons(con, ctx->consts);', 1),
           ]),

    # The predicate stops being part of the cache key, so the second of two
    # different predicates on one matview executes the first one's plans.  That
    # is B1's failure mode -- "the refresh reports success and acts on rows its
    # predicate does not name" -- reached through the key rather than through a
    # rename, and it is the property the key exists for at all.
    #
    # Deliberately the whole term rather than a subtle weakening: the question
    # this calibrates is whether ANY instrument in the tree notices the key
    # ignoring the predicate, and a weakening that only some predicates trip
    # would not answer it.
    'C7': ('-', 'data',
           'the plan cache key ignores the predicate '
           '(a second, different predicate reuses the first one\'s plans)', [
               ('\t\tcacheEntry->qual != NULL &&\n'
                '\t\tequal(cacheEntry->qual, qual) &&\n', '', 1),
           ]),

    # C8 is C7's near miss rather than its whole-term removal, and it exists
    # because the two fail differently.  Comparing only the top node accepts any
    # two predicates with the same shape at the root -- "id = $1" against
    # "grp = $1" is one OpExpr against another, equal in everything _equalOpExpr
    # looks at except the args it is no longer told to descend into.  A
    # comparison that walked no deeper would pass every gate C7 fails and still
    # refresh the wrong rows, so the detector has to be shown to catch it too.
    'C8': ('-', 'data',
           'the cache key compares only the predicate\'s top node '
           '(same-shaped predicates on different columns share plans)', [
               ('\t\tequal(cacheEntry->qual, qual) &&\n',
                '\t\tnodeTag(cacheEntry->qual) == nodeTag(qual) &&\n', 1),
           ]),

    # The measurement's off arm, and perf-only: deparsing on every refresh and
    # throwing the string away is exactly what the code did before the elision,
    # and every answer it gives is still right.  Same shape as C4, N3 and O1 --
    # an optimisation switched off with nothing else touched, so the two arms
    # differ by the one thing being measured.
    #
    # It reproduces the cost rather than the old code: the old code's string was
    # then read by a strcmp that the tree comparison replaces.  So this measures
    # the deparse alone and not (deparse + strcmp - equal), which is the right
    # thing to measure -- the deparse is what was removed -- and worth stating
    # because it makes the arm a lower bound on the saving by whatever the two
    # comparisons differ by.
    #
    # It sits immediately before the cache-key comparison, which is where the
    # string it produces used to be consumed.  That position is load-bearing and
    # was wrong once: the first version put it beside the lock-level check at
    # the top of the function, which is BEFORE profile.py starts MVP_TOTAL, so
    # the instrument could not see the one thing the arm exists to add.  Both
    # arms then measured the same work and read 8.2% apart on build noise alone
    # (RESULTS.md X19).  Anywhere inside the timed region measures the same
    # quantity -- a deparse costs what it costs -- but only inside.
    'C9': ('-', 'perf',
           'the predicate is deparsed on every refresh again '
           '(the elision silently off)', [
               ('\tif (found &&\n'
                '\t\tcacheEntry->uniqueIndexOid == uniqueIndexOid &&',
                '\tpfree(deparseRefreshWhereClause(matviewOid, qual));\n'
                '\tif (found &&\n'
                '\t\tcacheEntry->uniqueIndexOid == uniqueIndexOid &&',
                1),
           ]),

    # The leak, as distinct from C3's crash.  C3 keeps the old plansource *and*
    # keeps using it, which segfaults; this forgets it instead -- the pointer is
    # cleared, so nothing stale is ever dereferenced and the plansource simply
    # stays in CacheMemoryContext until the backend exits.
    #
    # That is the failure a test suite cannot see.  Every result is correct,
    # every gate is green, and the only symptom is a backend that grows for as
    # long as it keeps refreshing -- which for a drain process is forever.  It is
    # the calibration for leakcheck.sh, and leakcheck.sh is the only instrument
    # here that can catch it.
    #
    # Both drop sites, because they leak on different paths: the key-mismatch
    # rebuild leaks one per predicate switch, and the nested-refresh teardown
    # leaks one per nested refresh, on the success and error paths alike.
    # L3's slip one level over, on the context the cache key moved into when it
    # became a node tree (R48).  Building a fresh context instead of reusing the
    # entry's own orphans the previous one on every cache-key mismatch: its
    # contents are unreachable, nothing ever deletes it, and every answer the
    # refresh gives is still correct.
    #
    # Reached by the key CHANGING, not by refreshing -- so leakcheck's `churn`
    # mode is the detector and `steady` must stay quiet, which is what says the
    # two modes are measuring different paths rather than the same one twice.
    'L5': ('-', 'leak',
           'the cache key\'s memory context is rebuilt instead of reset '
           '(leaks one per predicate switch; every result still correct)', [
               ('\t\t\t\tif (cacheEntry->metacxt == NULL)\n'
                '\t\t\t\t\tcacheEntry->metacxt =\n'
                '\t\t\t\t\t\tAllocSetContextCreate(CacheMemoryContext,',
                '\t\t\t\t{\n'
                '\t\t\t\t\tcacheEntry->metacxt =\n'
                '\t\t\t\t\t\tAllocSetContextCreate(CacheMemoryContext,', 1),
               ('\t\t\t\t\t\t\t\t\t\t\t  ALLOCSET_SMALL_SIZES);\n',
                '\t\t\t\t\t\t\t\t\t\t\t  ALLOCSET_SMALL_SIZES);\n\t\t\t}\n', 1),
           ]),

    'L3': ('-', 'leak',
           'the source plansource is forgotten instead of dropped '
           '(leaks one per rebuild; every result still correct)', [
               ('\t\t\tif (cacheEntry->sourcePlan)\n'
                '\t\t\t\tDropCachedPlan(cacheEntry->sourcePlan);\n', ''),
               # The two nested-teardown sites sit at different indentation --
               # success path inside PG_TRY, error path inside PG_CATCH -- so
               # they are two edits, not one with a count of two.  The count
               # check caught that; a single pattern would have silently
               # mutated one path and left the other correct, which is B23.
               ('\t\t\tDropCachedPlan(cacheEntry->sourcePlan);\n'
                '\t\t\tcacheEntry->sourcePlan = NULL;\n',
                '\t\t\tcacheEntry->sourcePlan = NULL;\n', 2),
           ]),

    # L3's sibling, and the reason there are two: there are three drop sites and
    # they are reached by different events.  L3 covers the key-mismatch rebuild
    # and the nested teardown; this one covers matview_cache_sweep(), which is
    # the only thing that reclaims the plans of a matview that has since been
    # DROPped.  A mutation hitting one says nothing about the others, and
    # leakcheck.sh's `dropmv` mode exists for exactly this site.
    #
    # Same shape as L3 and the same reason it is invisible to everything else:
    # the entry is gone, so nothing stale is dereferenced and every result stays
    # correct.  The plansource just stays in CacheMemoryContext, one per dropped
    # matview, for the life of the backend.
    'L4': ('-', 'leak',
           'the sweep forgets the source plansource instead of dropping it '
           '(leaks one per dropped matview)', [
               ('\t\tif (entry->sourcePlan)\n'
                '\t\t\tDropCachedPlan(entry->sourcePlan);\n', ''),
           ]),

    # NB: this stopped applying when the prune guard landed and gave the DML
    # call site a third argument -- B23 again, and the occurrence count is what
    # said so.  Anchored on the snapshot argument alone now, which is the only
    # thing the mutation changes; it is unique because the lock call site sits
    # at a different indentation.
    'S1': ('-', 'concur',
           'run the fused DML under a fresh snapshot, not the one the source '
           'was evaluated under (reopens the prune gap)', [
               ('\t\t\t\t\t\t\t\t\t snapshot, false) < 0)',
                '\t\t\t\t\t\t\t\t\t InvalidSnapshot, false) < 0)', 1),
           ]),

    # N1-N4 are DELETED with the prune elision they mutated.  The elision was
    # sound only while the matview was held at ExclusiveLock, and requiring
    # CONCURRENTLY for a predicate took that lock away.  The cases they
    # calibrated are still in matview_where Test 17, because what those assert
    # -- a row that leaves the scope is deleted -- outlives any particular
    # guard; there is simply no guard left to mutate.

    # The guard for matview_where_privs Test 3.
    #
    # Reverts the leakproof gate from an allowlist to the denylist it used to
    # be: flag known-bad functions, let every unrecognised node type through.
    # With this applied a caller holding only MAINTAIN can put a subquery in
    # the predicate, have it read any relation the matview owner can read, and
    # learn the value by observing which row the refresh touched.
    # Re-anchored, and the previous version would not have compiled: it named
    # leakproof_checker and contains_non_leakproof_walker, neither of which
    # exists.  Nothing noticed, because the check only verified that the anchor
    # matched -- applying a mutation and building it are separate steps, and
    # --check does the first.  B23 one level further out.
    'P1': ('-', 'privs',
           'leakproof gate flags bad functions instead of allowing known-safe '
           'nodes (sublinks and domain casts escape)', [
               ('\tswitch (nodeTag(node))\n\t{\n\t\t\t/*\n\t\t\t * These cannot call a function or read a relation themselves,\n\t\t\t * though something below them might, so keep walking.\n\t\t\t */',
                '\tif (check_functions_in_node(node, non_leakproof_checker, context))\n'
                '\t\treturn true;\n'
                '\treturn expression_tree_walker(node, contain_non_leakproof_walker, context);\n'
                '\t/* P1: original denylist reinstated; the switch below is dead */\n'
                + '\tswitch (nodeTag(node))\n\t{\n\t\t\t/*\n\t\t\t * These cannot call a function or read a relation themselves,\n\t\t\t * though something below them might, so keep walking.\n\t\t\t */'),
           ]),

    'M1': ('A5', 'concur',
           'drop ORDER BY from the row-locking SELECT (deadlock)', [
               ('"SELECT 1 FROM %s " MATVIEW_ALIAS " WHERE (%s) ORDER BY %s "\n'
                '\t\t\t\t\t\t\t "FOR NO KEY UPDATE"',
                '"SELECT 1 FROM %s " MATVIEW_ALIAS " WHERE (%s) /*%s*/ "\n'
                '\t\t\t\t\t\t\t "FOR NO KEY UPDATE"', 1),
           ]),

    # The pre-lock weakened to a mode that does not conflict with itself.
    #
    # M3 removes the statement; this leaves it in place and takes the wrong
    # mode.  FOR KEY SHARE conflicts only with the key-exclusive modes, so two
    # refreshes over overlapping scopes stop ordering against each other and the
    # second can evaluate its source from a snapshot taken before the first
    # commits -- M3's lost update, reached by an edit that still reads like a
    # locking statement.
    #
    # Plausible as an accident precisely because 63f516f argued for taking the
    # weakest sufficient mode.  One step further is wrong, and the argument does
    # not say where to stop unless something measures it.
    'L1': ('A3', 'concur',
           'weaken the pre-lock to FOR KEY SHARE (no longer conflicts with '
           'itself, so overlapping refreshes stop serializing)', [
               ('"FOR NO KEY UPDATE"', '"FOR KEY SHARE"', 1),
           ]),

    # The control for L1: 63f516f undone, the pre-lock back at FOR UPDATE.
    #
    # Expected to be caught by NOTHING, and here to keep that answer measured
    # rather than assumed.  FOR UPDATE is strictly stronger, so every guarantee
    # still holds; the change was made to stop escalating the tuple lock
    # recorded in xmax, and on a relation no other session can lock there is
    # nothing a session can observe through SQL that distinguishes the two.
    #
    # So an instrument that fires here is asserting the mechanism rather than
    # the guarantee, which is the defect that got the pg_stat_statements block
    # deleted.  Same role as the `benign` rows, arrived at deliberately: this
    # one exists to check the gates that DO catch L1 are not over-fitted.
    'L2': ('-', 'benign',
           'pre-lock takes FOR UPDATE again (strictly stronger; expected to be '
           'invisible -- the control for L1)', [
               ('"FOR NO KEY UPDATE"', '"FOR UPDATE"', 1),
           ]),

    # The ordering this drops used to live in the MATERIALIZED CTE's text, as
    # "ORDER BY %s" appended to the new_data subquery.  With the text path gone
    # the source rows come from a Query tree, and the same ordering is the sort
    # clause on that tree -- built from the arbiter index's key columns a few
    # lines above.  Same property, same detectors, different line.
    'M2': ('P3', 'concur',
           'drop the source ordering (lock order for INSERTed rows)', [
               ('\tsourceQuery->sortClause = sortlist;',
                '\tsourceQuery->sortClause = NIL;\t/* M2 */'),
           ]),

    'M3': ('A3', 'concur',
           'remove the row-locking statement entirely (serialization)', [
               ('"SELECT 1 FROM %s " MATVIEW_ALIAS " WHERE (%s) ORDER BY %s "\n'
                '\t\t\t\t\t\t\t "FOR NO KEY UPDATE"',
                '"SELECT 1 FROM %s " MATVIEW_ALIAS " WHERE (%s) AND false /*%s*/"\n'
                '\t\t\t\t\t\t\t ""', 1),
           ]),

    # Kept for the record: verified behaviourally benign.  The planner does not
    # actually re-evaluate in a way that diverges, so this is NOT a P1
    # violation and a detector missing it is not a gap.  Do not put it back on
    # the "must find" list without re-establishing that it can fail.
    # M4 is DELETED, not broken.  It flipped the new_data CTE from MATERIALIZED
    # to NOT MATERIALIZED -- a planner hint that the source rows be computed
    # once -- and calibration recorded it MISSED and verified benign.  The CTE
    # is gone: the source rows are a tuplestore, materialised because they were
    # physically written before the statement ran, not because the planner was
    # asked nicely.  There is no hint left to flip and the guarantee it probed
    # is now structural, which is strictly stronger than what M4 tested.

    'M6': ('A3', 'concur',
           'lock after doing the work instead of before', [
               ('\t\tif (matview_execute_spi_plan(cacheEntry->lockPlan, params,\n'
                '\t\t\t\t\t\t\t\t\t InvalidSnapshot, false) < 0)\n'
                '\t\t\telog(ERROR, "SPI_execute_plan failed during lock acquisition");\n\n',
                ''),
               ('\t\t\tPopActiveSnapshot();\n\t\t}',
                '\t\t\tPopActiveSnapshot();\n'
                '\n'
                '\t\t\t/* M6: the lock, moved to after the work it was meant to guard */\n'
                '\t\t\tif (matview_execute_spi_plan(cacheEntry->lockPlan, params,\n'
                '\t\t\t\t\t\t\t\t\t\t InvalidSnapshot, false) < 0)\n'
                '\t\t\t\telog(ERROR, "SPI_execute_plan failed during lock acquisition");\n'
                '\t\t}'),
           ]),

    # The Q mutations are a different kind, and the rule above -- every
    # mutation is the undo of a fix that was actually made -- does not cover
    # them.  Nothing here was ever broken: the quoting calls have been correct
    # since the feature was written.
    #
    # They are admitted anyway, because the detector they calibrate exists for
    # a defect that has not happened yet.  matview_where_inject guards the
    # quoting through a rewrite that deletes the SQL it quotes into, and the
    # plausible way to break it is for one of these calls to be dropped or
    # forgotten during that rewrite.  A detector for a future regression cannot
    # be calibrated against a past one, and the alternative -- ship it
    # uncalibrated -- is the thing this directory keeps being burned by.
    #
    # What is NOT allowed is inventing a defect to make a detector look good.
    # The distinction: each Q below is an edit someone could actually make by
    # accident while doing the work that is planned.  If a mutation would not
    # survive being described out loud as "and this is how it would happen",
    # it does not belong here.
    'Q1': ('-', 'inject',
           'stop quoting the matview name on the direct-modification path', [
               ('\t\t\tmatview_name = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t\t  RelationGetRelationName(matviewRel));',
                '\t\t\tmatview_name = psprintf("%s.%s",\n'
                '\t\t\t\t\t\t\t\t\tget_namespace_name(RelationGetNamespace(matviewRel)),\n'
                '\t\t\t\t\t\t\t\t\tRelationGetRelationName(matviewRel));'),
           ]),

    # Q2 is DELETED.  It dropped the matview-name quoting in
    # refresh_by_match_merge(), which a predicate reached only while diff/merge
    # served one.  The call site is still there for the full concurrent
    # refresh, but nothing in this feature's suite reaches it, so the mutation
    # would sit in the matrix as permanently UNCAUGHT -- which reads as a gap
    # in the tests rather than as what it is, a mutation of somebody else's
    # code.

    'Q3': ('-', 'inject',
           'stop quoting arbiter column names on the direct-modification path', [
               ('\t\t\tquoted = quote_identifier(NameStr(attr->attname));',
                '\t\t\tquoted = pstrdup(NameStr(attr->attname));', 2),
           ]),
}

# A3 proper -- splitting the fused CTE into two statements -- is not here.
#
# It cannot be expressed as a string substitution: the fused statement would
# have to become two prepared plans and two SPI_execute_plan calls, which is a
# structural edit, not a swap.  It is also the mutation that most needs doing,
# because the fused CTE is the mechanism delivering P1 and A3 is the bug it
# fixes.  M3 and M6 approximate the same window from the locking side.
#
# Worth being explicit about why the split is what creates the hazard: within a
# single statement both references to new_data see one snapshot, so they cannot
# disagree.  Two statements under READ COMMITTED take two snapshots, and a
# concurrent base-table write landing between them is the A3 gap.  That is also
# why no single-session detector can see it.


def pristine():
    return subprocess.run(['git', 'show', 'HEAD:' + TARGET],
                          capture_output=True, text=True, check=True).stdout


def apply_edits(src, edits, name):
    """Apply one mutation's edits, insisting the code still looks as expected.

    An edit is (old, new) for a pattern that must occur exactly once, or
    (old, new, n) for one that must occur exactly n times and is replaced at
    every one of them.

    The count is checked, not assumed.  This used to be a plain replace(..., 1)
    against a pattern nobody had confirmed was unique, and two of them were not:
    B4's anti-join edit and Q3's column quoting each match two call sites, so
    each was mutating one of them and leaving the other correct.  A mutation
    that only half applies still produces a broken build and a plausible
    calibration number, and nothing anywhere says which half was measured.
    """
    for edit in edits:
        old, new = edit[0], edit[1]
        want = edit[2] if len(edit) > 2 else 1
        have = src.count(old)
        if have != want:
            sys.exit(f'{name}: expected {want} occurrence(s) of this pattern, '
                     f'found {have} -- the code has moved:\n  {old[:70]}...')
        src = src.replace(old, new)
    return src


def variants():
    """Every file content this script is capable of having written."""
    base = pristine()
    out = {base}
    for name, (_, _, _, edits) in MUTATIONS.items():
        try:
            out.add(apply_edits(base, edits, name))
        except SystemExit:
            pass                # a rotted pattern is reported when applied
    return out


def refuse_if_uncommitted():
    """Do not overwrite work that is not in HEAD and is not ours.

    Defining pristine as HEAD is what keeps this honest, and it has a sharp
    edge: every apply and every restore overwrites the file wholesale, so an
    uncommitted edit to matview.c is destroyed by the next restore without a
    word.  That happened -- two Assert()s were written, a mutation was tested
    against the contract file, the restore afterwards deleted them, and the
    suites that ran green afterwards were green because there was nothing left
    to check.  Silent, and indistinguishable from success.

    The check cannot be "is the file dirty", because mid-run it always is: the
    harnesses apply a mutation and then restore.  It is "is the dirt something
    this script wrote".  Anything else is someone's work in progress.
    """
    try:
        current = open(TARGET).read()
    except FileNotFoundError:
        return
    if current not in variants():
        sys.exit(f'{TARGET} has uncommitted changes that are not one of this '
                 "script's mutations,\nand every mutation here overwrites it "
                 'from HEAD.  Commit them first, or pass --force to discard '
                 'them.')


def check_all():
    """Verify every mutation still matches the code it is meant to break.

    A mutation whose pattern has drifted cannot be applied, and a mutation that
    cannot be applied is a detector that has never fired -- the same defect as a
    test that cannot fail, one level up.  This has already happened twice: A4
    stopped matching when the row comparison inserted a WHERE clause between the
    UPDATE SET and its else, and M1/M3 stopped matching when the pre-lock became
    FOR NO KEY UPDATE.  Neither was noticed until something went looking for it.

    Run this after any edit to matview.c.
    """
    src = pristine()
    bad = set()
    for name, (issue, needs, desc, edits) in sorted(MUTATIONS.items()):
        for edit in edits:
            old = edit[0]
            want = edit[2] if len(edit) > 2 else 1
            got = src.count(old)
            if got != want:
                bad.add(name)
                print(f'FAIL {name}: expected {want} occurrence(s), found '
                      f'{got} -- {old[:60]}...')
    print(f'{len(MUTATIONS) - len(bad)}/{len(MUTATIONS)} mutations still apply')
    return 1 if bad else 0


def main():
    args = [a for a in sys.argv[1:] if a != '--force']
    force = '--force' in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    name = args[0]

    if name == '--list':
        for k, (issue, needs, desc, _) in sorted(MUTATIONS.items()):
            print(f'{k:9} {issue:4} {needs:7} {desc}')
        return

    if name == '--check':
        sys.exit(check_all())

    # --overlay applies a mutation to the file AS IT STANDS instead of to HEAD,
    # which is the only way a mutation and profile.py's instrumentation can be
    # in one binary: both of those write the whole file from `git show HEAD:`,
    # so applying either one undoes the other, silently and with a green build.
    #
    # It exists for the measurement harnesses, where the off arm has to be
    # "instrumented, with the optimisation switched off" -- bench/deparse.sh is
    # the caller.  The edits and their occurrence counts are the same ones
    # --check verifies, so a pattern that has drifted is still loud here.
    #
    # It does not call refuse_if_uncommitted(), and that is the point rather
    # than an oversight: the file it is handed is deliberately not one of the
    # variants.  Nothing is lost that was not already at risk -- restoring still
    # goes through HEAD, exactly as before -- but an overlaid tree is not a tree
    # to commit from, so say so on the way out.
    if name == '--overlay':
        sys.exit('--overlay needs a mutation name')
    overlay = name.startswith('--overlay=')
    if overlay:
        name = name[len('--overlay='):]
        if name not in MUTATIONS:
            sys.exit(f'unknown mutation {name}; try --list')
        issue, needs, desc, edits = MUTATIONS[name]
        with open(TARGET) as f:
            src = apply_edits(f.read(), edits, name)
        with open(TARGET, 'w') as f:
            f.write(src)
        print(f'{name} overlaid on the working tree ({issue}, needs {needs}): '
              f'{desc}')
        return

    if not force:
        refuse_if_uncommitted()

    src = pristine()

    if name != 'pristine':
        if name not in MUTATIONS:
            sys.exit(f'unknown mutation {name}; try --list')
        issue, needs, desc, edits = MUTATIONS[name]
        src = apply_edits(src, edits, name)

    with open(TARGET, 'w') as f:
        f.write(src)

    if name == 'pristine':
        print('pristine restored')
    else:
        print(f'{name} applied ({issue}, needs {needs}): {desc}')


if __name__ == '__main__':
    main()
