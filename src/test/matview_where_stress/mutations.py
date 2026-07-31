#!/usr/bin/env python3
"""Re-introduce known bugs into matview.c, one at a time.

    ./mutations.py B4          apply
    ./mutations.py pristine    restore
    ./mutations.py --list      show the corpus

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
    'A4': ('A4', 'data',
           'drop ON CONFLICT from the upsert (scope drift)', [
               ('"  ON CONFLICT (%s) DO ",', '"  /*%s*/ ",'),
               ('\t\t\tappendStringInfo(&buf, "UPDATE SET %s ", set_clause.data);\n'
                '\t\telse\n'
                '\t\t\tappendStringInfoString(&buf, "NOTHING ");',
                '\t\t\tappendStringInfo(&buf, "/*%s*/ ", set_clause.data);\n'
                '\t\telse\n'
                '\t\t\tappendStringInfoString(&buf, " ");'),
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
    # Only the 'groupingsets' case can observe it: it is the one shape in the
    # corpus whose arbiter index is NULLS NOT DISTINCT, and GROUPING SETS is
    # what puts real NULLs in its key columns.
    'B4b': ('B4', 'data',
            'anti-join always uses plain equality '
            '(deletes NULL-keyed rows -- TimescaleDB #8151)', [
                ('anti_join_op = indexStruct->indnullsnotdistinct ?\n'
                 '\t\t\t"IS NOT DISTINCT FROM" : "=";',
                 'anti_join_op = "=";', 2),
            ]),

    'B6': ('B6', 'data',
           'arbitrate on the wrong unique index (drop the primary-key '
           'preference)', [
               ('\t\t\tif (is_pk)\n'
                '\t\t\t{\n'
                '\t\t\t\tuniqueIndexOid = indexoid;\n'
                '\t\t\t\tbreak;\n'
                '\t\t\t}\n'
                '\t\t\tif (!OidIsValid(uniqueIndexOid))\n'
                '\t\t\t\tuniqueIndexOid = indexoid;',
                '\t\t\tuniqueIndexOid = indexoid;\t/* no PK preference */'),
           ]),

    # A5 and M1 are the same edit.  A5 is the issue; M1 was the name it went by
    # in the B17 mutation matrix.  Keeping both names avoids a rename in the
    # calibration table, but they are one mutation and should be reported once.
    'M1': ('A5', 'concur',
           'drop ORDER BY from the row-locking SELECT (deadlock)', [
               ('"SELECT 1 FROM %s mv WHERE (%s) ORDER BY %s FOR UPDATE"',
                '"SELECT 1 FROM %s mv WHERE (%s) /*%s*/ FOR UPDATE"'),
           ]),

    'M2': ('P3', 'concur',
           'drop ORDER BY from new_data (lock order for INSERTed rows)', [
               ('"  SELECT * FROM (%s) %s WHERE (%s) ORDER BY %s "',
                '"  SELECT * FROM (%s) %s WHERE (%s) /*%s*/ "'),
           ]),

    'M3': ('A3', 'concur',
           'remove the row-locking statement entirely (serialization)', [
               ('"SELECT 1 FROM %s mv WHERE (%s) ORDER BY %s FOR UPDATE"',
                '"SELECT 1 FROM %s mv WHERE (%s) AND false /*%s*/"'),
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
