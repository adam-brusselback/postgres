#!/usr/bin/env python3
"""Add or remove per-phase timers in refresh_by_direct_modification().

    ./profile.py on       instrument matview.c
    ./profile.py off      restore it from HEAD
    ./profile.py --check  verify every pattern still matches; exits non-zero if not

The timers log one MVPROF line per 30 refreshes at LOG level, giving the
microseconds spent in each phase.  This is throwaway instrumentation, not a
feature: `off` restores the file from `git show HEAD:`, the same definition of
pristine mutations.py uses, so an instrumented tree cannot be committed by
accident and a forgotten `on` is one command from being undone.

Everything else here has been sized with it: the Tier 1/2 verdicts in PLAN.md
and the scope sweep behind 4.3.  perf is not installable on this kernel, and
the unattributed residual here is small enough that it has not been missed --
1.4 us of the text path and 4.3 us of the Query-tree path at scope 1.
"""
import subprocess
import sys

TARGET = 'src/backend/commands/matview.c'

PROLOGUE = '''#include "utils/tuplestore.h"
#include "portability/instr_time.h"

/* TEMPORARY per-phase profiling -- see src/test/matview_where_stress/profile.py */
static instr_time mvp_t[12];
static double mvp_us[12];
static int64 mvp_calls;
#define MVP_TOTAL 0
#define MVP_TRANSFORM 1
#define MVP_DEPARSE 2
#define MVP_ARBITER 3
#define MVP_SWEEP 4
#define MVP_PREPARE 5
#define MVP_SRCBUILD 6
#define MVP_SRCREWRITE 7
#define MVP_LOCKEXEC 8
#define MVP_DMLEXEC 9
#define MVP_SRCEXEC 10
#define MVP_SRCPLAN 11
#define MVP_START(i) INSTR_TIME_SET_CURRENT(mvp_t[i])
#define MVP_STOP(i) \\
  do { instr_time _e; INSTR_TIME_SET_CURRENT(_e); \\
       INSTR_TIME_SUBTRACT(_e, mvp_t[i]); \\
       mvp_us[i] += INSTR_TIME_GET_MICROSEC(_e); } while (0)
static const char *const mvp_name[12] = {
  "total", "transform", "deparse", "arbiter", "sweep",
  "prepare", "srcbuild", "srcrewrite", "lockexec", "dmlexec", "srcexec",
  "srcplan"
};
static void
mvp_report(void)
{
  StringInfoData b; int i;
  initStringInfo(&b);
  appendStringInfo(&b, "MVPROF calls=%lld", (long long) mvp_calls);
  for (i = 0; i < 12; i++)
    appendStringInfo(&b, " %s=%.1f", mvp_name[i], mvp_us[i]);
  elog(LOG, "%s", b.data);
  pfree(b.data);
  for (i = 0; i < 12; i++) mvp_us[i] = 0;
  mvp_calls = 0;
}'''

EDITS = [
    ('#include "utils/tuplestore.h"', PROLOGUE),

    # Two edits rather than one, because parameterizeRefreshWhereClause() landed
    # between the transform and the deparse in d20f396 and this pattern silently
    # stopped matching.  Anchored on each call separately now, so the next thing
    # inserted between them cannot take the pair down with it.  The
    # parameterisation itself is counted under neither: it is a walk of a
    # just-parsed tree, and giving it a timer would need a phase slot.
    ("""		qual = transformRefreshWhereClause(matviewOid, whereClause, params,
										   save_userid);""",
     """		MVP_START(MVP_TRANSFORM);
		qual = transformRefreshWhereClause(matviewOid, whereClause, params,
										   save_userid);
		MVP_STOP(MVP_TRANSFORM);"""),

    # The deparse moved inside the cache-miss branch, so this timer now reads
    # 0.0 on a warm refresh -- which is the whole of what the change did and is
    # what the profile has to be able to show.  Two consequences worth knowing
    # before reading a profile taken with it:
    #
    #   * DEPARSE is now NESTED INSIDE PREPARE, where it used to sit beside it.
    #     A cold band therefore counts those microseconds twice, once in each,
    #     and the phases no longer sum to the total on a miss.  They still do on
    #     a hit, where both read 0.
    #   * The match/merge path deparses too, and is deliberately NOT timed: it
    #     caches nothing, so it has no warm case to report and the timer would
    #     only muddle a profile of the path that does.
    ("""		whereClauseStr = deparseRefreshWhereClause(matviewOid, qual);""",
     """		MVP_START(MVP_DEPARSE);
		whereClauseStr = deparseRefreshWhereClause(matviewOid, qual);
		MVP_STOP(MVP_DEPARSE);"""),

    # The anchor used to be the one-line comment "preferring the primary key",
    # which went with the preference itself (ISSUES.md B26).  Anchored on the
    # call now, which is the thing being timed rather than the prose above it.
    ("""	indexoidlist = RelationGetIndexList(matviewRel);
	foreach(lc, indexoidlist)""",
     """	MVP_START(MVP_TOTAL);
	mvp_calls++;
	MVP_START(MVP_ARBITER);
	indexoidlist = RelationGetIndexList(matviewRel);
	foreach(lc, indexoidlist)"""),

    # The sweep moved inside "if (use_cache)" in 49a3528 (B14's fix), so ARBITER
    # has to stop BEFORE that branch -- a nested refresh takes the else arm and
    # would otherwise never stop the timer.
    ("""	use_cache = (matview_maintenance_depth == 0);""",
     """	MVP_STOP(MVP_ARBITER);
	use_cache = (matview_maintenance_depth == 0);"""),

    ("""		matview_cache_sweep();

		cacheEntry = (MatViewPartialRefreshCache *)
			hash_search(MatViewRefreshCache, &matviewOid, HASH_ENTER, &found);""",
     """		MVP_START(MVP_SWEEP);
		matview_cache_sweep();
		MVP_STOP(MVP_SWEEP);

		cacheEntry = (MatViewPartialRefreshCache *)
			hash_search(MatViewRefreshCache, &matviewOid, HASH_ENTER, &found);"""),

    ("""	/* Prepare plans if we don't have valid cached ones. */
	if (cacheEntry->lockPlan == NULL || cacheEntry->refreshPlan == NULL)
	{""",
     """	/* Prepare plans if we don't have valid cached ones. */
	if (cacheEntry->lockPlan == NULL || cacheEntry->refreshPlan == NULL)
	{
		MVP_START(MVP_PREPARE);"""),

    ("""		if (argtypes != NULL)
			pfree(argtypes);
		pfree(dml_argtypes);
	}""",
     """		if (argtypes != NULL)
			pfree(argtypes);
		pfree(dml_argtypes);
		MVP_STOP(MVP_PREPARE);
	}"""),

    ("""	if (matview_execute_spi_plan(cacheEntry->lockPlan, params,
								 InvalidSnapshot, false) < 0)
		elog(ERROR, "SPI_execute_plan failed during lock acquisition");""",
     """	MVP_START(MVP_LOCKEXEC);
	if (matview_execute_spi_plan(cacheEntry->lockPlan, params,
								 InvalidSnapshot, false) < 0)
		elog(ERROR, "SPI_execute_plan failed during lock acquisition");
	MVP_STOP(MVP_LOCKEXEC);"""),

    # SRCBUILD and SRCREWRITE are now inside the cache-miss branch, so on a warm
    # repeat they read 0 -- which is the point of 3.7 and is what the profile
    # has to be able to show.  Timing them outside the branch would charge every
    # refresh the cost of a miss and hide the saving entirely.
    ("""		if (cacheEntry->sourcePlan == NULL)
		{
			sourceQuery = matview_build_source_query(matviewRel, dataQuery,
													qual, nkeyatts,
													keyattnums);
			cacheEntry->sourcePlan =
				matview_build_source_plansource(sourceQuery);""",
     """		if (cacheEntry->sourcePlan == NULL)
		{
			MVP_START(MVP_SRCBUILD);
			sourceQuery = matview_build_source_query(matviewRel, dataQuery,
													qual, nkeyatts,
													keyattnums);
			MVP_STOP(MVP_SRCBUILD);
			MVP_START(MVP_SRCREWRITE);
			cacheEntry->sourcePlan =
				matview_build_source_plansource(sourceQuery);
			MVP_STOP(MVP_SRCREWRITE);"""),

    # R27 split the 12.20 us line into rewrite and plan, and 3.7 moved both
    # behind the cache.  SRCREWRITE is now the whole plansource construction and
    # is charged above, in the miss branch.  SRCPLAN is GetCachedPlan: the
    # planner on a miss, a validity check on a hit.  Reading the two together is
    # what says whether the cache is working.
    ("""	cplan = GetCachedPlan(plansource, params, owner, NULL);""",
     """	MVP_START(MVP_SRCPLAN);
	cplan = GetCachedPlan(plansource, params, owner, NULL);
	MVP_STOP(MVP_SRCPLAN);
	MVP_START(MVP_SRCEXEC);"""),

    ("""	ReleaseCachedPlan(cplan, owner);

	return processed;""",
     """	ReleaseCachedPlan(cplan, owner);

	MVP_STOP(MVP_SRCEXEC);
	return processed;"""),

    # The call site grew the prune guard's parameters, so this is anchored on the
    # two lines that bracket it rather than on the argument list.  Note what the
    # timer therefore includes: building the guard's ParamListInfo, which is a
    # handful of assignments, and the guard's own evaluation inside the
    # statement, which is where the saving shows up.
    ("""		if (matview_execute_spi_plan(cacheEntry->refreshPlan,""",
     """		MVP_START(MVP_DMLEXEC);
		if (matview_execute_spi_plan(cacheEntry->refreshPlan,"""),

    ("""			elog(ERROR, "SPI_execute_plan failed during refresh");""",
     """			elog(ERROR, "SPI_execute_plan failed during refresh");
		MVP_STOP(MVP_DMLEXEC);"""),

    # There used to be a second DMLEXEC edit here, for the text path's own
    # execution of the fused statement.  That path was deleted in 82f71d8 and
    # this edit has been unmatchable ever since -- it was one of the four --check
    # reported, and the only reason it was noticed is that --check reports every
    # miss rather than the first.  Removed rather than re-anchored: there is
    # nothing left for it to time.

    ("""	CloseMatViewIncrementalMaintenance();
	Assert(matview_maintenance_depth == old_depth);
	table_close(matviewRel, NoLock);

	return result_processed;""",
     """	CloseMatViewIncrementalMaintenance();
	Assert(matview_maintenance_depth == old_depth);
	table_close(matviewRel, NoLock);

	MVP_STOP(MVP_TOTAL);
	if (mvp_calls % 30 == 0)
		mvp_report();

	return result_processed;"""),
]


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ''
    if mode not in ('on', 'off', '--check'):
        sys.exit(__doc__)

    src = subprocess.run(['git', 'show', 'HEAD:' + TARGET],
                         capture_output=True, text=True, check=True).stdout

    # --check exists because this script rotted silently and nobody noticed.
    # 49a3528 moved matview_cache_sweep() inside "if (use_cache)"; 13 of the 14
    # patterns still matched, so `on` exited having instrumented nothing, and the
    # only symptom would have been a phase profile that never appeared.  This is
    # ISSUES.md B23 one file over -- there, the mutation corpus rotted against
    # the code it mutates and still produced plausible numbers.  Report every
    # miss rather than the first, so one run says how far the drift goes.
    if mode == '--check':
        missing = [(i, old) for i, (old, _) in enumerate(EDITS) if old not in src]
        for i, old in missing:
            print(f'  MISS  edit {i}: {old.strip().splitlines()[0][:66]}')
        print(f'{len(EDITS) - len(missing)}/{len(EDITS)} patterns apply '
              f'against HEAD:{TARGET}')
        sys.exit(1 if missing else 0)

    if mode == 'on':
        for old, new in EDITS:
            if old not in src:
                sys.exit(f'pattern not found, the code has moved:\n  {old[:70]}...'
                         f'\nrun ./profile.py --check to see every miss at once')
            src = src.replace(old, new, 1)

    with open(TARGET, 'w') as f:
        f.write(src)
    print(f'{TARGET}: profiling {mode}')


if __name__ == '__main__':
    main()
