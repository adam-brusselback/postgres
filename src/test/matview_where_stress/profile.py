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

    ("""		qual = transformRefreshWhereClause(matviewOid, whereClause, params,
										   save_userid);
		qual_str = deparseRefreshWhereClause(matviewOid, qual);""",
     """		MVP_START(MVP_TRANSFORM);
		qual = transformRefreshWhereClause(matviewOid, whereClause, params,
										   save_userid);
		MVP_STOP(MVP_TRANSFORM);
		MVP_START(MVP_DEPARSE);
		qual_str = deparseRefreshWhereClause(matviewOid, qual);
		MVP_STOP(MVP_DEPARSE);"""),

    ("""	/* Find a usable unique index, preferring the primary key. */
	indexoidlist = RelationGetIndexList(matviewRel);""",
     """	MVP_START(MVP_TOTAL);
	mvp_calls++;
	MVP_START(MVP_ARBITER);
	/* Find a usable unique index, preferring the primary key. */
	indexoidlist = RelationGetIndexList(matviewRel);"""),

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

    ("""		pfree(join_clause.data);
		if (argtypes != NULL)
			pfree(argtypes);
	}""",
     """		pfree(join_clause.data);
		if (argtypes != NULL)
			pfree(argtypes);
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

    ("""		sourceQuery = matview_build_source_query(matviewRel, dataQuery, qual,
												 nkeyatts, keyattnums);
		matview_materialize_source(sourceQuery, params, snapshot, sourceStore);""",
     """		MVP_START(MVP_SRCBUILD);
		sourceQuery = matview_build_source_query(matviewRel, dataQuery, qual,
												 nkeyatts, keyattnums);
		MVP_STOP(MVP_SRCBUILD);
		matview_materialize_source(sourceQuery, params, snapshot, sourceStore);"""),

    # R27: the 12.20 us was ONE line covering rewrite AND plan, and the saving
    # 3.7 can recover is bounded by the plan half alone.  Timed separately.
    ("""	AcquireRewriteLocks(sourceQuery, true, false);
	rewritten = QueryRewrite(sourceQuery);""",
     """	MVP_START(MVP_SRCREWRITE);
	AcquireRewriteLocks(sourceQuery, true, false);
	rewritten = QueryRewrite(sourceQuery);"""),

    ("""	CHECK_FOR_INTERRUPTS();

	plan = pg_plan_query(sourceQuery, NULL, CURSOR_OPT_PARALLEL_OK, params,
						 NULL);""",
     """	MVP_STOP(MVP_SRCREWRITE);
	CHECK_FOR_INTERRUPTS();

	MVP_START(MVP_SRCPLAN);
	plan = pg_plan_query(sourceQuery, NULL, CURSOR_OPT_PARALLEL_OK, params,
						 NULL);
	MVP_STOP(MVP_SRCPLAN);
	MVP_START(MVP_SRCEXEC);"""),

    ("""	dest->rDestroy(dest);

	return processed;""",
     """	dest->rDestroy(dest);

	MVP_STOP(MVP_SRCEXEC);
	return processed;"""),

    ("""		if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,
									 snapshot, false) < 0)
			elog(ERROR, "SPI_execute_plan failed during refresh");""",
     """		MVP_START(MVP_DMLEXEC);
		if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,
									 snapshot, false) < 0)
			elog(ERROR, "SPI_execute_plan failed during refresh");
		MVP_STOP(MVP_DMLEXEC);"""),

    ("""	else if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,
									  InvalidSnapshot, false) < 0)
		elog(ERROR, "SPI_execute_plan failed during refresh");""",
     """	else
	{
		MVP_START(MVP_DMLEXEC);
		if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,
									 InvalidSnapshot, false) < 0)
			elog(ERROR, "SPI_execute_plan failed during refresh");
		MVP_STOP(MVP_DMLEXEC);
	}"""),

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
