#!/usr/bin/env python3
"""Re-introduce known bugs into matview.c, one at a time.

    ./mutations.py B4          apply
    ./mutations.py pristine    restore
    ./mutations.py --list      show the corpus
    ./mutations.py --check     verify every mutation still applies

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
               ('\t\t\tappendStringInfo(&buf, "UPDATE SET %s ", set_clause.data);\n'
                '\t\t\tif (use_optimized)\n'
                '\t\t\t\tappendStringInfo(&buf, "WHERE (%s) IS DISTINCT FROM (%s) ",\n'
                '\t\t\t\t\t\t\t\t mv_cols.data, excluded_cols.data);\n'
                '\t\t}\n'
                '\t\telse\n'
                '\t\t\tappendStringInfoString(&buf, "NOTHING ");',
                '\t\t\tappendStringInfo(&buf, "/*%s*/ ", set_clause.data);\n'
                '\t\t\tif (use_optimized)\n'
                '\t\t\t\tappendStringInfo(&buf, "/*%s %s*/ ",\n'
                '\t\t\t\t\t\t\t\t mv_cols.data, excluded_cols.data);\n'
                '\t\t}\n'
                '\t\telse\n'
                '\t\t\tappendStringInfoString(&buf, " ");', 1),
           ]),

    'B4': ('B4', 'data',
           'anti-join ignores the arbiter index NULL handling '
           '(duplicates NULL-keyed rows)', [
               ('anti_join_op = indexStruct->indnullsnotdistinct ?\n'
                '\t\t\t"IS NOT DISTINCT FROM" : "=";',
                'anti_join_op = "IS NOT DISTINCT FROM";', 2),
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
                 '\t\t\t"IS NOT DISTINCT FROM" : "=";',
                 'anti_join_op = "=";', 2),
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
    # Needs the optimized GUC on to be reachable at all, which needs querytree
    # on too -- see the note on use_optimized.
    'B7': ('-', 'data',
           'row comparison uses <> instead of IS DISTINCT FROM '
           '(NULL-valued rows silently never update)', [
               ('appendStringInfo(&buf, "WHERE (%s) IS DISTINCT FROM (%s) ",',
                'appendStringInfo(&buf, "WHERE (%s) <> (%s) ",', 1),
           ]),

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
    'S1': ('-', 'concur',
           'run the fused DML under a fresh snapshot, not the one the source '
           'was evaluated under (reopens the prune gap)', [
               ('\t\tif (matview_execute_spi_plan(cacheEntry->refreshPlan, params,\n'
                '\t\t\t\t\t\t\t\t\t snapshot, false) < 0)',
                '\t\tif (matview_execute_spi_plan(cacheEntry->refreshPlan, params,\n'
                '\t\t\t\t\t\t\t\t\t InvalidSnapshot, false) < 0)'),
           ]),

    # The guard for matview_where_privs Test 3.
    #
    # Reverts the leakproof gate from an allowlist to the denylist it used to
    # be: flag known-bad functions, let every unrecognised node type through.
    # With this applied a caller holding only MAINTAIN can put a subquery in
    # the predicate, have it read any relation the matview owner can read, and
    # learn the value by observing which row the refresh touched.
    'P1': ('-', 'privs',
           'leakproof gate flags bad functions instead of allowing known-safe '
           'nodes (sublinks and domain casts escape)', [
               ('\tswitch (nodeTag(node))\n\t{\n\t\t/*\n\t\t * These cannot call a function or read a relation themselves, though\n\t\t * something below them might, so keep walking.\n\t\t */',
                '\tif (check_functions_in_node(node, leakproof_checker, context))\n'
                '\t\treturn true;\n'
                '\treturn expression_tree_walker(node, contains_non_leakproof_walker, context);\n'
                '\t/* P1: original denylist reinstated; the switch below is dead */\n'
                '\tswitch (nodeTag(node))\n\t{\n\t\t/*\n\t\t * These cannot call a function or read a relation themselves, though\n\t\t * something below them might, so keep walking.\n\t\t */'),
           ]),

    'M1': ('A5', 'concur',
           'drop ORDER BY from the row-locking SELECT (deadlock)', [
               ('"SELECT 1 FROM %s mv WHERE (%s) ORDER BY %s "\n'
                '\t\t\t\t\t\t "FOR NO KEY UPDATE"',
                '"SELECT 1 FROM %s mv WHERE (%s) /*%s*/ "\n'
                '\t\t\t\t\t\t "FOR NO KEY UPDATE"', 1),
           ]),

    'M2': ('P3', 'concur',
           'drop ORDER BY from new_data (lock order for INSERTed rows)', [
               ('"  SELECT * FROM (%s) %s WHERE (%s) ORDER BY %s "',
                '"  SELECT * FROM (%s) %s WHERE (%s) /*%s*/ "'),
           ]),

    'M3': ('A3', 'concur',
           'remove the row-locking statement entirely (serialization)', [
               ('"SELECT 1 FROM %s mv WHERE (%s) ORDER BY %s "\n'
                '\t\t\t\t\t\t "FOR NO KEY UPDATE"',
                '"SELECT 1 FROM %s mv WHERE (%s) AND false /*%s*/"\n'
                '\t\t\t\t\t\t ""', 1),
           ]),

    # Kept for the record: verified behaviourally benign.  The planner does not
    # actually re-evaluate in a way that diverges, so this is NOT a P1
    # violation and a detector missing it is not a gap.  Do not put it back on
    # the "must find" list without re-establishing that it can fail.
    'M4': ('-', 'benign',
           'un-MATERIALIZE new_data (verified benign -- see ISSUES.md B17)', [
               ('"WITH new_data AS MATERIALIZED ( "',
                '"WITH new_data AS NOT MATERIALIZED ( "'),
           ]),

    'M6': ('A3', 'concur',
           'lock after doing the work instead of before', [
               ('\tif (matview_execute_spi_plan(cacheEntry->lockPlan, params,\n'
                '\t\t\t\t\t\t\t\t InvalidSnapshot, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during lock acquisition");\n\n',
                ''),
               ('\telse if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,\n'
                '\t\t\t\t\t\t\t\t\t  InvalidSnapshot, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during refresh");',
                '\telse if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,\n'
                '\t\t\t\t\t\t\t\t\t  InvalidSnapshot, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during refresh");\n\n'
                '\tif (matview_execute_spi_plan(cacheEntry->lockPlan, params,\n'
                '\t\t\t\t\t\t\t\t InvalidSnapshot, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during lock acquisition");'),
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
               ('\t\tmatview_name = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),\n'
                '\t\t\t\t\t\t\t\t\t\t\t\t  RelationGetRelationName(matviewRel));',
                '\t\tmatview_name = psprintf("%s.%s",\n'
                '\t\t\t\t\t\t\t\tget_namespace_name(RelationGetNamespace(matviewRel)),\n'
                '\t\t\t\t\t\t\t\tRelationGetRelationName(matviewRel));'),
           ]),

    'Q2': ('-', 'inject',
           'stop quoting the matview name on the match/merge path', [
               ('\tmatviewname = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),\n'
                '\t\t\t\t\t\t\t\t\t\t\t RelationGetRelationName(matviewRel));',
                '\tmatviewname = psprintf("%s.%s",\n'
                '\t\t\t\t\t\t   get_namespace_name(RelationGetNamespace(matviewRel)),\n'
                '\t\t\t\t\t\t   RelationGetRelationName(matviewRel));'),
           ]),

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
