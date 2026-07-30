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

# (issue, needs, description, [(old, new), ...])
#
#   needs='data'    observable by one session: the matview contents end up wrong
#   needs='concur'  observable only with two overlapping sessions
MUTATIONS = {
    'A4': ('A4', 'data',
           'drop ON CONFLICT from the diff insert (scope drift)', [
               ('"  ON CONFLICT (%s) DO UPDATE SET %s "', '"  /*%s%s*/ "'),
               ('"  ON CONFLICT (%s) DO NOTHING "', '"  /*%s*/ "'),
           ]),

    'B4': ('B4', 'data',
           'anti-join ignores the arbiter index NULL handling '
           '(duplicates NULL-keyed rows)', [
               ('anti_join_op = indexStruct->indnullsnotdistinct ?\n'
                '\t\t\t"IS NOT DISTINCT FROM" : "=";',
                'anti_join_op = "IS NOT DISTINCT FROM";'),
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
               ('\tif (matview_execute_spi_plan(cacheEntry->lockPlan, params, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during lock acquisition");\n\n',
                ''),
               ('\tif (matview_execute_spi_plan(cacheEntry->refreshPlan, params, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during refresh");',
                '\tif (matview_execute_spi_plan(cacheEntry->refreshPlan, params, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during refresh");\n'
                '\tif (matview_execute_spi_plan(cacheEntry->lockPlan, params, false) < 0)\n'
                '\t\telog(ERROR, "SPI_execute_plan failed during lock acquisition");'),
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


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    name = sys.argv[1]

    if name == '--list':
        for k, (issue, needs, desc, _) in sorted(MUTATIONS.items()):
            print(f'{k:9} {issue:4} {needs:7} {desc}')
        return

    src = pristine()

    if name != 'pristine':
        if name not in MUTATIONS:
            sys.exit(f'unknown mutation {name}; try --list')
        issue, needs, desc, edits = MUTATIONS[name]
        for old, new in edits:
            if old not in src:
                sys.exit(f'{name}: pattern not found, the code has moved:\n'
                         f'  {old[:70]}...')
            src = src.replace(old, new, 1)

    with open(TARGET, 'w') as f:
        f.write(src)

    if name == 'pristine':
        print('pristine restored')
    else:
        print(f'{name} applied ({issue}, needs {needs}): {desc}')


if __name__ == '__main__':
    main()
