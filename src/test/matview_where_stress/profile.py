#!/usr/bin/env python3
"""Add or remove per-phase timers in refresh_by_direct_modification().

    ./profile.py on     instrument matview.c
    ./profile.py off    restore it from HEAD

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
static instr_time mvp_t[11];
static double mvp_us[11];
static int64 mvp_calls;
#define MVP_TOTAL 0
#define MVP_TRANSFORM 1
#define MVP_DEPARSE 2
#define MVP_ARBITER 3
#define MVP_SWEEP 4
#define MVP_PREPARE 5
#define MVP_SRCBUILD 6
#define MVP_SRCPLAN 7
#define MVP_LOCKEXEC 8
#define MVP_DMLEXEC 9
#define MVP_SRCEXEC 10
#define MVP_START(i) INSTR_TIME_SET_CURRENT(mvp_t[i])
#define MVP_STOP(i) \\
  do { instr_time _e; INSTR_TIME_SET_CURRENT(_e); \\
       INSTR_TIME_SUBTRACT(_e, mvp_t[i]); \\
       mvp_us[i] += INSTR_TIME_GET_MICROSEC(_e); } while (0)
static const char *const mvp_name[11] = {
  "total", "transform", "deparse", "arbiter", "sweep",
  "prepare", "srcbuild", "srcplan", "lockexec", "dmlexec", "srcexec"
};
static void
mvp_report(void)
{
  StringInfoData b; int i;
  initStringInfo(&b);
  appendStringInfo(&b, "MVPROF calls=%lld", (long long) mvp_calls);
  for (i = 0; i < 11; i++)
    appendStringInfo(&b, " %s=%.1f", mvp_name[i], mvp_us[i]);
  elog(LOG, "%s", b.data);
  pfree(b.data);
  for (i = 0; i < 11; i++) mvp_us[i] = 0;
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

    ("""	matview_cache_sweep();

	cacheEntry = (MatViewPartialRefreshCache *) hash_search(MatViewRefreshCache,""",
     """	MVP_STOP(MVP_ARBITER);
	MVP_START(MVP_SWEEP);
	matview_cache_sweep();
	MVP_STOP(MVP_SWEEP);

	cacheEntry = (MatViewPartialRefreshCache *) hash_search(MatViewRefreshCache,"""),

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

    ("""	AcquireRewriteLocks(sourceQuery, true, false);
	rewritten = QueryRewrite(sourceQuery);""",
     """	MVP_START(MVP_SRCPLAN);
	AcquireRewriteLocks(sourceQuery, true, false);
	rewritten = QueryRewrite(sourceQuery);"""),

    ("""	plan = pg_plan_query(sourceQuery, NULL, CURSOR_OPT_PARALLEL_OK, params,
						 NULL);""",
     """	plan = pg_plan_query(sourceQuery, NULL, CURSOR_OPT_PARALLEL_OK, params,
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
    if mode not in ('on', 'off'):
        sys.exit(__doc__)

    src = subprocess.run(['git', 'show', 'HEAD:' + TARGET],
                         capture_output=True, text=True, check=True).stdout

    if mode == 'on':
        for old, new in EDITS:
            if old not in src:
                sys.exit(f'pattern not found, the code has moved:\n  {old[:70]}...')
            src = src.replace(old, new, 1)

    with open(TARGET, 'w') as f:
        f.write(src)
    print(f'{TARGET}: profiling {mode}')


if __name__ == '__main__':
    main()
