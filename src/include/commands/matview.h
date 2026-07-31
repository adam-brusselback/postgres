/*-------------------------------------------------------------------------
 *
 * matview.h
 *	  prototypes for matview.c.
 *
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/include/commands/matview.h
 *
 *-------------------------------------------------------------------------
 */
#ifndef MATVIEW_H
#define MATVIEW_H

#include "catalog/objectaddress.h"
#include "nodes/params.h"
#include "nodes/parsenodes.h"
#include "tcop/dest.h"
#include "utils/relcache.h"


/*
 * Build a partial refresh's source rows from the view's Query tree instead of
 * from its deparsed SQL text.  Scaffolding: it exists so that the two
 * implementations can be compared against each other at run time while the
 * rewrite is in progress, and goes away with the text path.
 */
extern PGDLLIMPORT bool matview_partial_refresh_querytree;

/*
 * Apply the Phase 3 optimisations.  Only meaningful with the above; like it,
 * this exists so both can run in one binary and be measured against each
 * other, and goes away when the optimisations are no longer optional.
 */
extern PGDLLIMPORT bool matview_partial_refresh_optimized;

extern void SetMatViewPopulatedState(Relation relation, bool newstate);

extern ObjectAddress ExecRefreshMatView(RefreshMatViewStmt *stmt, const char *queryString,
										ParamListInfo params, QueryCompletion *qc);

extern ObjectAddress RefreshMatViewByOid(Oid matviewOid, bool is_create, bool skipData,
										 bool concurrent, Node *whereClause,
										 const char *queryString, ParamListInfo params,
										 QueryCompletion *qc);

extern DestReceiver *CreateTransientRelDestReceiver(Oid transientoid);

extern bool MatViewIncrementalMaintenanceIsEnabled(Oid relid);

#endif							/* MATVIEW_H */
