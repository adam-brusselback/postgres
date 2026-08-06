/*-------------------------------------------------------------------------
 *
 * matview.c
 *	  materialized view support
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 *
 * IDENTIFICATION
 *	  src/backend/commands/matview.c
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "access/multixact.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_am.h"
#include "catalog/pg_opclass.h"
#include "catalog/pg_type.h"
#include "commands/matview.h"
#include "commands/repack.h"
#include "commands/tablecmds.h"
#include "commands/tablespace.h"
#include "executor/executor.h"
#include "executor/spi.h"
#include "executor/tstoreReceiver.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "optimizer/optimizer.h"
#include "parser/parse_clause.h"
#include "parser/parse_coerce.h"
#include "parser/parse_collate.h"
#include "parser/parse_expr.h"
#include "parser/parse_relation.h"
#include "rewrite/rewriteHandler.h"
#include "rewrite/rewriteManip.h"
#include "storage/lmgr.h"
#include "tcop/tcopprot.h"
#include "tcop/utility.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/injection_point.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/plancache.h"
#include "utils/queryenvironment.h"
#include "utils/regproc.h"
#include "utils/rel.h"
#include "utils/rls.h"
#include "utils/ruleutils.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"

/*
 * Why we refused a caller's predicate.  We record this as the check that
 * rejected it runs, so the error can name the actual reason: some of these
 * are missing SELECT privilege, others admit no fix short of owning the
 * matview.
 */
typedef enum RefreshQualVerdict
{
	REFRESH_QUAL_OK = 0,
	REFRESH_QUAL_OPAQUE,		/* a node that could reach a relation */
	REFRESH_QUAL_FUNCTION,		/* a function that is not leakproof */
	REFRESH_QUAL_NO_SELECT,		/* reads a relation the caller cannot */
	REFRESH_QUAL_RLS,			/* reads rows the caller sees through RLS */
	REFRESH_QUAL_SECURITY_INVOKER,	/* reads a security_invoker view */
	REFRESH_QUAL_MATVIEW_COLS,	/* reads matview columns the caller cannot */
} RefreshQualVerdict;

typedef struct RefreshQualContext
{
	Oid			callerId;		/* who issued the REFRESH */
	RefreshQualVerdict verdict; /* why we refused, once we have */
	Oid			relid;			/* relation named in the error, if any */
	Oid			funcid;			/* function named in the error, if any */
} RefreshQualContext;

typedef struct
{
	DestReceiver pub;			/* publicly-known function pointers */
	Oid			transientoid;	/* OID of new heap into which to store */
	/* These fields are filled by transientrel_startup: */
	Relation	transientrel;	/* relation to write to */
	CommandId	output_cid;		/* cmin to insert in output tuples */
	uint32		ti_options;		/* table_tuple_insert performance options */
	BulkInsertState bistate;	/* bulk insert state */
} DR_transientrel;

typedef struct MatViewPartialRefreshCache
{
	Oid			matviewOid;		/* hash key */

	/* what these plans were built for; all of it must match to reuse them */
	Oid			uniqueIndexOid; /* the index the upsert arbitrates on */
	Node	   *qual;			/* the predicate, compared with equal() */
	int			nargs;			/* number of external parameters */
	Oid		   *argtypes;		/* their types.  Not implied by qual: a caller
								 * may bind a parameter the predicate never
								 * names, and the statements declare them all */
	MemoryContext metacxt;		/* holds qual and argtypes; a node tree cannot
								 * be freed piecemeal */

	SPIPlanPtr	lockPlan;		/* SELECT ... FOR NO KEY UPDATE */
	SPIPlanPtr	dupPlan;		/* the duplicate-key check on the source */
	SPIPlanPtr	refreshPlan;	/* the fused upsert and prune */
	CachedPlanSource *sourcePlan;	/* the matview's own query */

	bool		invalid;		/* set by the relcache callback; the entry is
								 * dropped at the next refresh, not here */

} MatViewPartialRefreshCache;

static HTAB *MatViewRefreshCache = NULL;

/*
 * Matview maintenance state.  While a refresh is running we must let its own
 * generated statements modify the matview, but a partial refresh evaluates its
 * WHERE clause inside the same window.  A caller who does not own the matview
 * may only use leakproof functions there, which bounds what they can reach, but
 * the owner is under no such restriction and neither is confined to the matview
 * being refreshed.  So we remember which one that is, and grant the exemption
 * for no other.
 */
static int	matview_maintenance_depth = 0;
static Oid	matview_maintenance_relid = InvalidOid;

static void transientrel_startup(DestReceiver *self, int operation, TupleDesc typeinfo);
static bool transientrel_receive(TupleTableSlot *slot, DestReceiver *self);
static void transientrel_shutdown(DestReceiver *self);
static void transientrel_destroy(DestReceiver *self);
static uint64 refresh_matview_datafill(DestReceiver *dest, Query *query,
									   const char *queryString, bool is_create);
static void refresh_by_match_merge(Oid matviewOid, Oid tempOid, Oid relowner,
								   int save_sec_context);
static uint64 refresh_by_direct_modification(Oid matviewOid, Oid relowner,
											 Oid callerId,
											 int save_sec_context,
											 Query *dataQuery, Node *qual,
											 const char *queryString,
											 ParamListInfo params);
static void refresh_by_heap_swap(Oid matviewOid, Oid OIDNewHeap, char relpersistence);
static bool is_usable_unique_index(Relation indexRel);
static void OpenMatViewIncrementalMaintenance(Oid relid);
static void CloseMatViewIncrementalMaintenance(void);
static int	matview_execute_spi_plan(SPIPlanPtr plan, ParamListInfo params,
									 Snapshot snapshot, bool read_only);
static void InitMatViewCache(void);
static void InvalidateMatViewCache(Datum arg, Oid relid);
static void matview_cache_sweep(void);
static CachedPlanSource *matview_build_source_plansource(Query *sourceQuery,
														 const char *queryString);
static bool refresh_qual_needs_owner_walker(Node *node, void *context);
static bool refresh_query_reads_unreadable(Query *query,
										   RefreshQualContext *ctx);
static void refresh_qual_permission_error(Relation matviewRel,
										  RefreshQualContext *ctx);
static bool matview_argtypes_match(MatViewPartialRefreshCache *entry,
								   ParamListInfo params);

/*
 * SetMatViewPopulatedState
 *		Mark a materialized view as populated, or not.
 *
 * NOTE: caller must be holding an appropriate lock on the relation.
 */
void
SetMatViewPopulatedState(Relation relation, bool newstate)
{
	Relation	pgrel;
	HeapTuple	tuple;

	Assert(relation->rd_rel->relkind == RELKIND_MATVIEW);

	/*
	 * Nothing to do if the state already matches.  A partial refresh always
	 * passes true on an already populated matview, so without this it would
	 * send the invalidation described below on every call, discarding this
	 * backend's own cached refresh plans each time.
	 */
	if (relation->rd_rel->relispopulated == newstate)
		return;

	/*
	 * Update relation's pg_class entry.  Crucial side-effect: other backends
	 * (and this one too!) are sent SI message to make them rebuild relcache
	 * entries.
	 */
	pgrel = table_open(RelationRelationId, RowExclusiveLock);
	tuple = SearchSysCacheCopy1(RELOID,
								ObjectIdGetDatum(RelationGetRelid(relation)));
	if (!HeapTupleIsValid(tuple))
		elog(ERROR, "cache lookup failed for relation %u",
			 RelationGetRelid(relation));

	((Form_pg_class) GETSTRUCT(tuple))->relispopulated = newstate;

	CatalogTupleUpdate(pgrel, &tuple->t_self, tuple);

	heap_freetuple(tuple);
	table_close(pgrel, RowExclusiveLock);

	/*
	 * Advance command counter to make the updated pg_class row locally
	 * visible.
	 */
	CommandCounterIncrement();
}

/*
 * Resolve a $n in a partial refresh's WHERE clause.
 *
 * REFRESH takes no parameters of its own, so a caller who wants to bind one
 * issues the command through EXECUTE ... USING or SPI.  Those pass their
 * ParamListInfo down to us, and parse analysis of the WHERE clause needs this
 * hook to find the type of each $n in it; without it "WHERE id = $1" cannot be
 * analyzed at all.
 */

static Node *
refresh_paramref_hook(ParseState *pstate, ParamRef *pref)
{
	ParamListInfo params = (ParamListInfo) pstate->p_ref_hook_state;
	Param	   *param;

	param = makeNode(Param);
	param->paramkind = PARAM_EXTERN;
	param->paramid = pref->number;
	param->paramtype = UNKNOWNOID;
	param->paramtypmod = -1;
	param->paramcollid = InvalidOid;
	param->location = pref->location;

	if (params && pref->number > 0 && pref->number <= params->numParams)
	{
		Oid			ptype = params->params[pref->number - 1].ptype;

		if (OidIsValid(ptype))
			param->paramtype = ptype;
	}

	return (Node *) param;
}

/*
 * check_functions_in_node callback: true if this function is not leakproof.
 *
 * We save the OID of the first one we find, so the error can name it.  Few
 * functions are marked leakproof, and the one that stops a given expression is
 * often not the one the caller would guess, so a refusal that does not name it
 * leaves them nothing to act on.
 */

static bool
non_leakproof_checker(Oid func_id, void *context)
{
	RefreshQualContext *ctx = (RefreshQualContext *) context;

	if (get_func_leakproof(func_id))
		return false;

	ctx->funcid = func_id;
	return true;
}

/*
 * May the caller read relid, given the columns perminfo says are read of it?
 *
 * relid is whatever the predicate named: the matview itself, or a relation a
 * subquery in the predicate reads.  This is the SELECT half of
 * ExecCheckOneRelPerms() asked about the caller rather than about whoever is
 * running, and we follow it down to the corner cases: table-wide SELECT
 * settles it, a query naming no column needs SELECT on some column, a
 * whole-row reference needs it on every column, and anything else needs it on
 * each column read.
 */

static bool
refresh_caller_may_select(Oid relid, RTEPermissionInfo *perminfo, Oid callerId)
{
	int			col;

	if (pg_class_aclcheck(relid, callerId, ACL_SELECT) == ACLCHECK_OK)
		return true;

	/* no perminfo means nothing established the caller may read it */
	if (perminfo == NULL)
		return false;

	if (bms_is_empty(perminfo->selectedCols))
		return pg_attribute_aclcheck_all(relid, callerId, ACL_SELECT,
										 ACLMASK_ANY) == ACLCHECK_OK;

	col = -1;
	while ((col = bms_next_member(perminfo->selectedCols, col)) >= 0)
	{
		/* bit #s are offset by FirstLowInvalidHeapAttributeNumber */
		AttrNumber	attno = col + FirstLowInvalidHeapAttributeNumber;

		if (attno == InvalidAttrNumber)
		{
			/* whole-row reference, must have the privilege on all columns */
			if (pg_attribute_aclcheck_all(relid, callerId, ACL_SELECT,
										  ACLMASK_ALL) != ACLCHECK_OK)
				return false;
		}
		else if (pg_attribute_aclcheck(relid, attno, callerId,
									   ACL_SELECT) != ACLCHECK_OK)
			return false;
	}

	return true;
}

/*
 * Does this query level read something the caller could not read itself?
 *
 * We ask whether the caller could reach the same rows, not whether they hold
 * the same privilege, because row-level security separates the two.  Hence
 * check_enable_rls() for the caller rather than a test for the presence of a
 * policy: a caller with BYPASSRLS, or who owns the table, reaches the same rows
 * the owner does.
 */

static bool
refresh_query_reads_unreadable(Query *query, RefreshQualContext *ctx)
{
	ListCell   *lc;

	foreach(lc, query->rtable)
	{
		RangeTblEntry *rte = lfirst_node(RangeTblEntry, lc);
		RTEPermissionInfo *perminfo;

		if (rte->rtekind != RTE_RELATION)
			continue;

		/*
		 * A security_invoker view is read with the privileges of whoever is
		 * running, which here is the owner, so SELECT on the view says
		 * nothing about whether the caller could have read what it selects
		 * from.  An ordinary view is fine: it is read with its own owner's
		 * privileges either way.
		 */
		if (rte->relkind == RELKIND_VIEW)
		{
			Relation	viewrel = relation_open(rte->relid, AccessShareLock);
			bool		invoker = RelationHasSecurityInvoker(viewrel);

			relation_close(viewrel, AccessShareLock);
			if (invoker)
			{
				ctx->verdict = REFRESH_QUAL_SECURITY_INVOKER;
				ctx->relid = rte->relid;
				return true;
			}
		}

		perminfo = rte->perminfoindex > 0 ?
			getRTEPermissionInfo(query->rteperminfos, rte) : NULL;

		if (!refresh_caller_may_select(rte->relid, perminfo, ctx->callerId))
		{
			ctx->verdict = REFRESH_QUAL_NO_SELECT;
			ctx->relid = rte->relid;
			return true;
		}

		if (check_enable_rls(rte->relid, ctx->callerId, true) == RLS_ENABLED)
		{
			ctx->verdict = REFRESH_QUAL_RLS;
			ctx->relid = rte->relid;
			return true;
		}
	}

	return false;
}

/*
 * May this caller use this predicate?
 *
 * We evaluate the predicate with the owner's privileges, so anything it
 * reaches, it reaches as the owner.  A subquery declares what it touches in its
 * range table, so we check those relations against the caller.  A function does
 * not, so leakproofness is the only handle we have on it.
 *
 * The node types we accept are an allowlist, not a denylist: anything we do not
 * recognize might reach a relation, so we refuse it.
 */

static bool
refresh_qual_needs_owner_walker(Node *node, void *context)
{
	RefreshQualContext *ctx = (RefreshQualContext *) context;

	if (node == NULL)
		return false;

	if (IsA(node, Query))
	{
		Query	   *query = (Query *) node;

		if (refresh_query_reads_unreadable(query, ctx))
			return true;
		return query_tree_walker(query, refresh_qual_needs_owner_walker,
								 context, 0);
	}

	switch (nodeTag(node))
	{
			/*
			 * These cannot call a function or read a relation themselves,
			 * though something below them might, so keep walking.
			 */
		case T_Var:
		case T_Const:
		case T_Param:
		case T_BoolExpr:
		case T_RelabelType:
		case T_CollateExpr:
		case T_CaseExpr:
		case T_CaseTestExpr:
		case T_ArrayExpr:
		case T_RowExpr:
		case T_CoalesceExpr:
		case T_MinMaxExpr:
		case T_NullTest:
		case T_BooleanTest:
		case T_FieldSelect:
		case T_NamedArgExpr:
		case T_SQLValueFunction:
		case T_List:
			break;

			/*
			 * Query structure rather than expressions.  These arrive once the
			 * walk has descended into a subquery, and none of them reaches a
			 * relation by itself: the relations a query level reads are its
			 * range table, which refresh_query_reads_unreadable() has already
			 * checked by the time any of these is visited.
			 */
		case T_TargetEntry:
		case T_FromExpr:
		case T_JoinExpr:
		case T_RangeTblRef:
		case T_SetOperationStmt:
		case T_CommonTableExpr:
		case T_SortGroupClause:
		case T_CaseWhen:
			break;

			/*
			 * We walk a sublink rather than refusing it.
			 * expression_tree_walker() visits its testexpr and then its
			 * subselect, and the Query branch above decides whether the caller
			 * may read what that names.  That covers every level below it too,
			 * since query_tree_walker() descends into subqueries, CTEs and
			 * further sublinks.
			 */
		case T_SubLink:
			break;

		case T_FuncExpr:
		case T_OpExpr:
		case T_DistinctExpr:
		case T_NullIfExpr:
		case T_ScalarArrayOpExpr:
		case T_CoerceViaIO:
		case T_ArrayCoerceExpr:
		case T_RowCompareExpr:
		case T_Aggref:
		case T_WindowFunc:
		case T_GroupingFunc:
			if (check_functions_in_node(node, non_leakproof_checker, context))
			{
				ctx->verdict = REFRESH_QUAL_FUNCTION;
				return true;
			}
			break;

		default:
			ctx->verdict = REFRESH_QUAL_OPAQUE;
			return true;
	}

	return expression_tree_walker(node, refresh_qual_needs_owner_walker,
								  context);
}

/*
 * Refuse a predicate the caller may not use, saying which of the reasons it is.
 */

static void
refresh_qual_permission_error(Relation matviewRel, RefreshQualContext *ctx)
{
	const char *relname = ctx->relid != InvalidOid ?
		get_rel_name(ctx->relid) : NULL;

	switch (ctx->verdict)
	{
		case REFRESH_QUAL_NO_SELECT:
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("permission denied for table %s", relname),
					 errdetail("The WHERE clause of REFRESH MATERIALIZED VIEW is evaluated with the privileges of the owner of materialized view \"%s\".",
							   RelationGetRelationName(matviewRel)),
					 errhint("Only the owner may use a WHERE clause that reads a relation the caller cannot read.")));
			break;

		case REFRESH_QUAL_RLS:
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("permission denied for table %s", relname),
					 errdetail("Row-level security applies to the caller on this table but not to the owner of materialized view \"%s\", with whose privileges the WHERE clause is evaluated.",
							   RelationGetRelationName(matviewRel)),
					 errhint("Only the owner may use a WHERE clause that reads a relation whose rows the caller sees through row-level security.")));
			break;

		case REFRESH_QUAL_SECURITY_INVOKER:
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("permission denied for view %s", relname),
					 errdetail("The view has the security_invoker option, so it is read with the privileges of the owner of materialized view \"%s\", with whose privileges the WHERE clause is evaluated.",
							   RelationGetRelationName(matviewRel)),
					 errhint("Only the owner may use a WHERE clause that reads a security_invoker view.")));
			break;

		case REFRESH_QUAL_MATVIEW_COLS:
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("permission denied for materialized view %s",
							RelationGetRelationName(matviewRel)),
					 errdetail("The WHERE clause reads columns of the materialized view."),
					 errhint("SELECT privilege is required on any column whose values are read by the WHERE clause.")));
			break;

		case REFRESH_QUAL_FUNCTION:
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("permission denied to use a non-leakproof expression in the WHERE clause of REFRESH MATERIALIZED VIEW"),
					 errdetail("Function %s is not leakproof, and the expression is evaluated with the privileges of the owner of materialized view \"%s\".",
							   format_procedure(ctx->funcid),
							   RelationGetRelationName(matviewRel)),
					 errhint("Only the owner may use a WHERE clause containing an expression that is not leakproof.")));
			break;

		case REFRESH_QUAL_OPAQUE:
		case REFRESH_QUAL_OK:
			ereport(ERROR,
					(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
					 errmsg("permission denied to use a non-leakproof expression in the WHERE clause of REFRESH MATERIALIZED VIEW"),
					 errdetail("The expression is evaluated with the privileges of the owner of materialized view \"%s\".",
							   RelationGetRelationName(matviewRel)),
					 errhint("Only the owner may use a WHERE clause containing an expression that is not leakproof.")));
			break;
	}
}


/*
 * Say where a parse-analysis error came from, and why a name may not have
 * resolved.
 *
 * We run under RestrictSearchPath(), so an object the caller did not
 * schema-qualify is simply not found, and the message says only that it does
 * not exist.  That is true and no help at all.  We limit the hint to the errors
 * a missing qualification actually produces, since on any other failure it
 * would point away from the cause.
 */
static void
refresh_where_clause_error_callback(void *arg)
{
	int			sqlerrcode = geterrcode();

	errcontext("WHERE clause of REFRESH MATERIALIZED VIEW");

	if (sqlerrcode == ERRCODE_UNDEFINED_TABLE ||
		sqlerrcode == ERRCODE_UNDEFINED_FUNCTION ||
		sqlerrcode == ERRCODE_UNDEFINED_OBJECT)
		errhint("The condition is analyzed with search_path set to \"pg_catalog, pg_temp\", so it must schema-qualify the objects it names.");
}

/*
 * Parse-analyse a partial refresh's WHERE clause against the matview, and
 * reject the expressions that cannot be allowed there.
 */

static Node *
transformRefreshWhereClause(Oid relid, Node *whereClause, ParamListInfo params,
							Oid callerId)
{
	ParseState *pstate = make_parsestate(NULL);
	Relation	rel = table_open(relid, NoLock);
	ParseNamespaceItem *nsitem;
	Node	   *result;
	ErrorContextCallback errcallback;

	pstate->p_paramref_hook = refresh_paramref_hook;
	pstate->p_ref_hook_state = (void *) params;

	nsitem = addRangeTableEntryForRelation(pstate, rel, AccessShareLock, NULL, false, true);
	addNSItemToQuery(pstate, nsitem, false, true, true);

	/*
	 * Only around the analysis: the rejections below say plainly what is
	 * wrong with the expression and need nothing added.
	 */
	errcallback.callback = refresh_where_clause_error_callback;
	errcallback.arg = NULL;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	result = transformExpr(pstate, whereClause, EXPR_KIND_WHERE);
	result = coerce_to_boolean(pstate, result, "WHERE");

	error_context_stack = errcallback.previous;

	assign_expr_collations(pstate, result);

	/*
	 * Nothing to check for the owner.  The predicate runs with the owner's
	 * privileges, which for them is no more than they already have.
	 */
	if (!object_ownercheck(RelationRelationId, relid, callerId))
	{
		RefreshQualContext qualctx;

		qualctx.callerId = callerId;
		qualctx.verdict = REFRESH_QUAL_OK;
		qualctx.relid = InvalidOid;
		qualctx.funcid = InvalidOid;

		/*
		 * REFRESH asks for MAINTAIN, which does not imply SELECT.  A predicate
		 * reads the matview's own columns and reports through the row count how
		 * many rows matched, so we require what reading those columns requires.
		 * That is the rule DELETE and UPDATE already apply to the columns their
		 * WHERE clause reads.
		 *
		 * As there, a predicate that reads no column asks for nothing extra.
		 * transformExpr() has marked exactly the columns the predicate reads,
		 * and if there are none the statement is no more a read of the matview
		 * than an unqualified DELETE is.
		 */
		if (!bms_is_empty(nsitem->p_perminfo->selectedCols) &&
			!refresh_caller_may_select(relid, nsitem->p_perminfo, callerId))
		{
			qualctx.verdict = REFRESH_QUAL_MATVIEW_COLS;
			refresh_qual_permission_error(rel, &qualctx);
		}

		if (refresh_qual_needs_owner_walker(result, &qualctx))
			refresh_qual_permission_error(rel, &qualctx);
	}

	if (contain_volatile_functions(result))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("WHERE clause in REFRESH MATERIALIZED VIEW cannot contain volatile functions")));

	if (pstate->p_hasAggs)
		ereport(ERROR,
				(errcode(ERRCODE_GROUPING_ERROR),
				 errmsg("WHERE clause in REFRESH MATERIALIZED VIEW cannot contain aggregates")));

	table_close(rel, NoLock);
	free_parsestate(pstate);

	return result;
}

/*
 * Names the SQL that refresh_by_direct_modification() generates gives to the
 * two relations it reads.  MATVIEW_ALIAS is also what we must deparse the
 * predicate against, so that the deparse and the statements agree; both halves
 * of the fused statement read MATVIEW_SOURCE_ENR_NAME, and both get the same
 * tuplestore, so they cannot disagree about which rows the view produces.
 */
#define MATVIEW_SOURCE_ENR_NAME	"new_data"
#define MATVIEW_ALIAS			"mv"

/*
 * Render an analyzed WHERE clause back to text, for the statements SPI builds.
 *
 * We must name the matview the way those statements do, which is
 * MATVIEW_ALIAS.  pg_get_expr() would use the matview's own name instead, and
 * that only works while the predicate is simple enough that ruleutils never
 * qualifies anything.  Once a second relation is in scope, which any subquery
 * does, it qualifies the matview's Vars with a name the statement never
 * defines and the refresh fails with "missing FROM-clause entry".
 */

static char *
deparseRefreshWhereClause(Oid relid, Node *whereClause)
{
	List	   *dpcontext = deparse_context_for(MATVIEW_ALIAS, relid);

	return deparse_expression(whereClause, dpcontext, false, false);
}

/*
 * Working state for parameterizeRefreshWhereClause().
 */
typedef struct RefreshParamizeContext
{
	int			nextparam;		/* paramid last handed out */
	List	   *consts;			/* the Consts replaced, in paramid order */
} RefreshParamizeContext;

/*
 * May this Const become a Param?
 *
 * The deparsed clause renders a Param as "$n" with no type information, so the
 * type must travel beside it in the argtypes array given to SPI_prepare.  A
 * constant with no type to declare cannot make that trip.
 */

static bool
refresh_const_is_paramizable(Const *con)
{
	if (!OidIsValid(con->consttype) || con->consttype == UNKNOWNOID)
		return false;

	if (get_typtype(con->consttype) == TYPTYPE_PSEUDO)
		return false;

	return true;
}

/*
 * Mutator for parameterizeRefreshWhereClause().
 */

static Node *
paramize_refresh_consts_mutator(Node *node, void *context)
{
	RefreshParamizeContext *ctx = (RefreshParamizeContext *) context;

	if (node == NULL)
		return NULL;

	if (IsA(node, Const))
	{
		Const	   *con = (Const *) node;
		Param	   *param;

		if (!refresh_const_is_paramizable(con))
			return node;

		param = makeNode(Param);
		param->paramkind = PARAM_EXTERN;
		param->paramid = ++ctx->nextparam;
		param->paramtype = con->consttype;
		param->paramtypmod = con->consttypmod;
		param->paramcollid = con->constcollid;
		param->location = con->location;

		ctx->consts = lappend(ctx->consts, con);

		return (Node *) param;
	}

	return expression_tree_mutator(node, paramize_refresh_consts_mutator, context);
}

/*
 * Replace the constants in an analyzed WHERE clause with parameters, extending
 * *params with their values.
 *
 * The plan cache is keyed on the predicate, so without this a caller who
 * varies a literal from call to call misses the cache every time and pays for
 * parse analysis and planning on each refresh.
 */
static Node *
parameterizeRefreshWhereClause(Node *qual, ParamListInfo *params)
{
	RefreshParamizeContext ctx;
	ParamListInfo base = *params;
	ParamListInfo newparams;
	Node	   *newqual;
	ListCell   *lc;
	int			i;

	if (base != NULL && (base->paramFetch != NULL || base->paramCompile != NULL))
		return qual;

	ctx.nextparam = base ? base->numParams : 0;
	ctx.consts = NIL;

	newqual = paramize_refresh_consts_mutator(qual, &ctx);

	if (ctx.consts == NIL)
		return qual;

	newparams = makeParamList(ctx.nextparam);

	i = 0;
	if (base != NULL)
	{
		for (; i < base->numParams; i++)
			newparams->params[i] = base->params[i];
	}

	foreach(lc, ctx.consts)
	{
		Const	   *con = (Const *) lfirst(lc);
		ParamExternData *prm = &newparams->params[i++];

		prm->value = con->constvalue;
		prm->isnull = con->constisnull;

		/*
		 * PARAM_FLAG_CONST tells the planner this value cannot change for the
		 * life of the plan, which lets eval_const_expressions() substitute it
		 * as a Const.  Without it the planner must treat the Param as opaque,
		 * and a custom plan would be worse than the one the literal got.
		 */
		prm->pflags = PARAM_FLAG_CONST;
		prm->ptype = con->consttype;
	}
	Assert(i == ctx.nextparam);

	*params = newparams;
	return newqual;
}

/*
 * Execute a prepared SPI plan, optionally under a caller-supplied snapshot.
 */

static int
matview_execute_spi_plan(SPIPlanPtr plan, ParamListInfo params,
						 Snapshot snapshot, bool read_only)
{
	Datum	   *argvalues = NULL;
	char	   *nulls = NULL;
	int			res;

	if (params && params->numParams > 0)
	{
		int			i;

		argvalues = (Datum *) palloc(params->numParams * sizeof(Datum));
		nulls = (char *) palloc(params->numParams * sizeof(char));

		for (i = 0; i < params->numParams; i++)
		{
			ParamExternData *prm = &params->params[i];

			argvalues[i] = prm->value;
			nulls[i] = prm->isnull ? 'n' : ' ';
		}
	}

	if (snapshot == InvalidSnapshot)
		res = SPI_execute_plan(plan, argvalues, nulls, read_only, 0);
	else
		res = SPI_execute_snapshot(plan, argvalues, nulls,
								   snapshot, InvalidSnapshot,
								   read_only, false, 0);

	if (argvalues != NULL)
		pfree(argvalues);
	if (nulls != NULL)
		pfree(nulls);

	return res;
}

/*
 * ExecRefreshMatView -- execute a REFRESH MATERIALIZED VIEW command
 *
 * This is the entry point for REFRESH MATERIALIZED VIEW.  Four spellings reach
 * it:
 *
 * - no options: full rebuild via heap swap.
 * - CONCURRENTLY: full refresh, computed into a temporary table and applied as
 *   a diff, so that readers are not blocked.
 * - CONCURRENTLY with a WHERE clause: partial refresh, which modifies in place
 *   only the rows the clause selects.  The grammar requires CONCURRENTLY here.
 * - WITH NO DATA: effectively like a TRUNCATE.
 *
 * The statement node's skipData field shows whether WITH NO DATA was used.
 */
ObjectAddress
ExecRefreshMatView(RefreshMatViewStmt *stmt, const char *queryString,
				   ParamListInfo params, QueryCompletion *qc)
{
	Oid			matviewOid;
	LOCKMODE	lockmode;

	/*
	 * Determine strength of lock needed.  A partial refresh takes only
	 * RowExclusiveLock, because it modifies rows in place and relies on the row
	 * locks it takes over its own scope to serialize against another one.  Two
	 * refreshes over scopes that do not overlap therefore run in parallel.
	 */
	if (stmt->whereClause)
		lockmode = RowExclusiveLock;
	else if (stmt->concurrent)
		lockmode = ExclusiveLock;
	else
		lockmode = AccessExclusiveLock;

	/*
	 * Get a lock until end of transaction.
	 */
	matviewOid = RangeVarGetRelidExtended(stmt->relation,
										  lockmode, 0,
										  RangeVarCallbackMaintainsTable,
										  NULL);

	return RefreshMatViewByOid(matviewOid, false, stmt->skipData,
							   stmt->concurrent, stmt->whereClause,
							   queryString, params, qc);
}

/*
 * RefreshMatViewByOid -- refresh materialized view by OID
 *
 * This refreshes a materialized view using one of three strategies:
 *
 * 1. Full rebuild (no options).  Creates a new heap, populates it, and swaps
 * relfilenumbers under AccessExclusiveLock.  The OID of the original
 * materialized view is preserved, so we do not lose GRANT nor references to
 * this materialized view.
 *
 * 2. Full concurrent refresh (CONCURRENTLY).  Computes the new contents into a
 * temporary table, diffs that against the matview and applies the difference,
 * under ExclusiveLock.  Readers are not blocked; writers are.
 *
 * 3. Partial refresh (CONCURRENTLY with a WHERE clause).  Modifies in place
 * only the rows the clause selects, under RowExclusiveLock.  See
 * refresh_by_direct_modification().
 *
 * If skipData is true, this is effectively like a TRUNCATE; otherwise it is
 * like a TRUNCATE followed by an INSERT using the SELECT statement associated
 * with the materialized view.
 *
 * For full rebuild, indexes are rebuilt too, via REINDEX.  Since we are
 * effectively bulk-loading the new heap, it's better to create the indexes
 * afterwards than to fill them incrementally while we load.
 *
 * The matview's "populated" state is changed based on whether the contents
 * reflect the result set of the materialized view's query.
 *
 * This is also used to populate the materialized view created by CREATE
 * MATERIALIZED VIEW command.
 */
ObjectAddress
RefreshMatViewByOid(Oid matviewOid, bool is_create, bool skipData,
					bool concurrent, Node *whereClause,
					const char *queryString, ParamListInfo params,
					QueryCompletion *qc)
{
	Relation	matviewRel;
	RewriteRule *rule;
	List	   *actions;
	Query	   *dataQuery;
	Oid			relowner;
	uint64		processed = 0;
	Oid			save_userid;
	int			save_sec_context;
	int			save_nestlevel;
	ObjectAddress address;
	Node	   *qual = NULL;
	int			nUniqueIndexes = 0;

	matviewRel = table_open(matviewOid, NoLock);
	relowner = matviewRel->rd_rel->relowner;

	/*
	 * Switch to the owner's userid, so that any functions are run as that
	 * user.  Also lock down security-restricted operations and arrange to
	 * make GUC variable changes local to this command.
	 */
	GetUserIdAndSecContext(&save_userid, &save_sec_context);
	SetUserIdAndSecContext(relowner,
						   save_sec_context | SECURITY_RESTRICTED_OPERATION);
	save_nestlevel = NewGUCNestLevel();
	RestrictSearchPath();

	/* Make sure it is a materialized view. */
	if (matviewRel->rd_rel->relkind != RELKIND_MATVIEW)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("\"%s\" is not a materialized view",
						RelationGetRelationName(matviewRel))));

	/* Check that conflicting options have not been specified. */
	if (concurrent && !RelationIsPopulated(matviewRel))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("CONCURRENTLY cannot be used when the materialized view is not populated")));

	if (whereClause && !RelationIsPopulated(matviewRel))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("WHERE clause cannot be used when the materialized view is not populated")));

	if (concurrent && skipData)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("%s options %s and %s cannot be used together",
						"REFRESH", "CONCURRENTLY", "WITH NO DATA")));

	/*
	 * Check that everything is correct for a refresh. Problems at this point
	 * are internal errors, so elog is sufficient.
	 */
	if (matviewRel->rd_rel->relhasrules == false ||
		matviewRel->rd_rules->numLocks < 1)
		elog(ERROR,
			 "materialized view \"%s\" is missing rewrite information",
			 RelationGetRelationName(matviewRel));

	if (matviewRel->rd_rules->numLocks > 1)
		elog(ERROR,
			 "materialized view \"%s\" has too many rules",
			 RelationGetRelationName(matviewRel));

	rule = matviewRel->rd_rules->rules[0];
	if (rule->event != CMD_SELECT || !(rule->isInstead))
		elog(ERROR,
			 "the rule for materialized view \"%s\" is not a SELECT INSTEAD OF rule",
			 RelationGetRelationName(matviewRel));

	actions = rule->actions;
	if (list_length(actions) != 1)
		elog(ERROR,
			 "the rule for materialized view \"%s\" is not a single action",
			 RelationGetRelationName(matviewRel));

	if (whereClause)
	{
		qual = transformRefreshWhereClause(matviewOid, whereClause, params,
										   save_userid);

		/*
		 * Substitute here, before anything reads the predicate.  The source
		 * query, the plan cache key and both generated statements all come
		 * from this tree, and they must not disagree about it.
		 */
		qual = parameterizeRefreshWhereClause(qual, &params);
	}

	/*
	 * The grammar rejects a predicate without CONCURRENTLY, and the checks
	 * below rely on it: the unique-index count that a partial refresh needs is
	 * only taken under "concurrent".
	 */
	Assert(!qual || concurrent);

	/*
	 * Check that there is a unique index with no WHERE clause on one or more
	 * columns of the materialized view if CONCURRENTLY is specified.
	 *
	 * Count them too: a partial refresh requires there to be exactly one, for
	 * the reason given at the check below.
	 */
	if (concurrent)
	{
		List	   *indexoidlist = RelationGetIndexList(matviewRel);
		ListCell   *indexoidscan;
		bool		hasUniqueIndex = false;

		Assert(!is_create);

		foreach(indexoidscan, indexoidlist)
		{
			Oid			indexoid = lfirst_oid(indexoidscan);
			Relation	indexRel;
			Form_pg_index indexStruct;

			indexRel = index_open(indexoid, AccessShareLock);
			indexStruct = indexRel->rd_index;

			/* Count every unique index the upsert would have to satisfy. */
			if (indexStruct->indisunique && indexStruct->indisvalid &&
				indexStruct->indimmediate)
				nUniqueIndexes++;

			if (!hasUniqueIndex)
				hasUniqueIndex = is_usable_unique_index(indexRel);
			index_close(indexRel, AccessShareLock);
		}

		list_free(indexoidlist);

		if (!hasUniqueIndex)
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("cannot refresh materialized view \"%s\" concurrently",
							quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),
													   RelationGetRelationName(matviewRel))),
					 errhint("Create a unique index with no WHERE clause on one or more columns of the materialized view.")));

		/*
		 * A partial refresh applies its changes with ON CONFLICT against one
		 * arbiter index, a row at a time, and each row must satisfy every
		 * unique index as we write it.  Two rows exchanging their values on a
		 * second unique index would need one deleted before the other is
		 * inserted, which ON CONFLICT cannot do, and no choice of arbiter
		 * helps: whichever index arbitrates, the exchange collides on the
		 * other.  A full refresh is unaffected, since it rewrites the whole
		 * matview and never reconciles a new row against one it is not
		 * replacing.
		 */
		if (qual && nUniqueIndexes > 1)
			ereport(ERROR,
					(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
					 errmsg("cannot refresh materialized view \"%s\" with a WHERE clause",
							quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),
													   RelationGetRelationName(matviewRel))),
					 errdetail("A partial refresh applies its changes against a single unique index, and the materialized view has more than one."),
					 errhint("Refresh the materialized view without a WHERE clause.")));
	}

	/*
	 * The stored query was rewritten at the time of the MV definition, but
	 * has not been scribbled on by the planner.
	 */
	dataQuery = linitial_node(Query, actions);

	/*
	 * Check for active uses of the relation in the current transaction, such
	 * as open scans.
	 *
	 * NB: We count on this to protect us against problems with refreshing the
	 * data using TABLE_INSERT_FROZEN.
	 */
	CheckTableNotInUse(matviewRel,
					   is_create ? "CREATE MATERIALIZED VIEW" :
					   "REFRESH MATERIALIZED VIEW");

	/*
	 * Tentatively mark the matview as populated or not (this will roll back
	 * if we fail later).
	 */
	SetMatViewPopulatedState(matviewRel, !skipData);

	/*
	 * STRATEGY 1: PARTIAL REFRESH.
	 *
	 * A predicate selects direct modification, which is the only algorithm
	 * that can apply a change without rewriting rows the predicate does not
	 * name.  We measured diff/merge against it across scopes from a small
	 * fraction of the matview up to nearly all of it, and it was slower at
	 * every point, with the margin widening as the scope grew.
	 *
	 * (WITH NO DATA is rejected together with a WHERE clause long before
	 * here, so !skipData is belt and braces.)
	 */
	if (qual && !skipData)
	{
		processed = refresh_by_direct_modification(matviewOid, relowner,
												   save_userid, save_sec_context,
												   dataQuery, qual, queryString,
												   params);
	}

	/*
	 * STRATEGY 2: FULL CONCURRENT REFRESH
	 */
	else if (concurrent)
	{
		Oid			tableSpace;
		char		relpersistence;
		Oid			OIDNewHeap;
		int			old_depth = matview_maintenance_depth;
		Oid			old_relid = matview_maintenance_relid;

		tableSpace = GetDefaultTablespace(RELPERSISTENCE_TEMP, false);
		relpersistence = RELPERSISTENCE_TEMP;

		/*
		 * Create the transient table that will receive the regenerated data.
		 * Lock it against access by any other process until commit (by which
		 * time it will be gone).
		 */
		OIDNewHeap = make_new_heap(matviewOid, tableSpace,
								   matviewRel->rd_rel->relam,
								   relpersistence, ExclusiveLock);
		Assert(CheckRelationOidLockedByMe(OIDNewHeap, AccessExclusiveLock, false));

		/* Generate the data, if wanted. */
		if (!skipData)
		{
			DestReceiver *dest;

			dest = CreateTransientRelDestReceiver(OIDNewHeap);
			processed = refresh_matview_datafill(dest, dataQuery, queryString, is_create);
		}

		PG_TRY();
		{
			refresh_by_match_merge(matviewOid, OIDNewHeap, relowner,
								   save_sec_context);
		}
		PG_CATCH();
		{
			matview_maintenance_depth = old_depth;
			matview_maintenance_relid = old_relid;
			PG_RE_THROW();
		}
		PG_END_TRY();

		Assert(matview_maintenance_depth == old_depth);
	}

	/*
	 * STRATEGY 3: FULL REBUILD
	 */
	else
	{
		Oid			tableSpace;
		char		relpersistence;
		Oid			OIDNewHeap;

		tableSpace = matviewRel->rd_rel->reltablespace;
		relpersistence = matviewRel->rd_rel->relpersistence;

		OIDNewHeap = make_new_heap(matviewOid, tableSpace,
								   matviewRel->rd_rel->relam,
								   relpersistence, AccessExclusiveLock);

		if (!skipData)
		{
			DestReceiver *dest;

			dest = CreateTransientRelDestReceiver(OIDNewHeap);
			processed = refresh_matview_datafill(dest, dataQuery, queryString, is_create);
		}

		refresh_by_heap_swap(matviewOid, OIDNewHeap, relpersistence);

		/*
		 * Inform cumulative stats system about our activity: basically, we
		 * truncated the matview and inserted some new data.  (The concurrent
		 * code path above doesn't need to worry about this because the
		 * inserts and deletes it issues get counted by lower-level code.)
		 */
		pgstat_count_truncate(matviewRel);
		if (!skipData)
			pgstat_count_heap_insert(matviewRel, processed);
	}

	table_close(matviewRel, NoLock);

	/* Roll back any GUC changes */
	AtEOXact_GUC(false, save_nestlevel);

	/* Restore userid and security context */
	SetUserIdAndSecContext(save_userid, save_sec_context);

	ObjectAddressSet(address, RelationRelationId, matviewOid);

	/*
	 * Save the rowcount so that pg_stat_statements can track the total number
	 * of rows processed by REFRESH MATERIALIZED VIEW command. Note that we
	 * still don't display the rowcount in the command completion tag output,
	 * i.e., the display_rowcount flag of CMDTAG_REFRESH_MATERIALIZED_VIEW
	 * command tag is left false in cmdtaglist.h. Otherwise, the change of
	 * completion tag output might break applications using it.
	 *
	 * When called from CREATE MATERIALIZED VIEW command, the rowcount is
	 * displayed with the command tag CMDTAG_SELECT.
	 */
	if (qc)
		SetQueryCompletion(qc,
						   is_create ? CMDTAG_SELECT : CMDTAG_REFRESH_MATERIALIZED_VIEW,
						   processed);

	return address;
}

/*
 * refresh_matview_datafill
 *
 * Execute the given query, sending result rows to "dest" (which will
 * insert them into the target matview).
 *
 * Returns number of rows inserted.
 */
static uint64
refresh_matview_datafill(DestReceiver *dest, Query *query,
						 const char *queryString, bool is_create)
{
	List	   *rewritten;
	PlannedStmt *plan;
	QueryDesc  *queryDesc;
	Query	   *copied_query;
	uint64		processed;

	/* Lock and rewrite, using a copy to preserve the original query. */
	copied_query = copyObject(query);
	AcquireRewriteLocks(copied_query, true, false);
	rewritten = QueryRewrite(copied_query);

	/* SELECT should never rewrite to more or less than one SELECT query */
	if (list_length(rewritten) != 1)
		elog(ERROR, "unexpected rewrite result for %s",
			 is_create ? "CREATE MATERIALIZED VIEW " : "REFRESH MATERIALIZED VIEW");
	query = (Query *) linitial(rewritten);

	/* Check for user-requested abort. */
	CHECK_FOR_INTERRUPTS();

	/* Plan the query which will generate data for the refresh. */
	plan = pg_plan_query(query, queryString, CURSOR_OPT_PARALLEL_OK, NULL, NULL);

	/*
	 * Use a snapshot with an updated command ID to ensure this query sees
	 * results of any previously executed queries.  (This could only matter if
	 * the planner executed an allegedly-stable function that changed the
	 * database contents, but let's do it anyway to be safe.)
	 */
	PushCopiedSnapshot(GetActiveSnapshot());
	UpdateActiveSnapshotCommandId();

	/* Create a QueryDesc, redirecting output to our tuple receiver */
	queryDesc = CreateQueryDesc(plan, queryString,
								GetActiveSnapshot(), InvalidSnapshot,
								dest, NULL, NULL, 0);

	/* call ExecutorStart to prepare the plan for execution */
	ExecutorStart(queryDesc, 0);

	/* run the plan */
	ExecutorRun(queryDesc, ForwardScanDirection, 0);

	processed = queryDesc->estate->es_processed;

	/* and clean up */
	ExecutorFinish(queryDesc);
	ExecutorEnd(queryDesc);

	FreeQueryDesc(queryDesc);

	PopActiveSnapshot();

	return processed;
}

DestReceiver *
CreateTransientRelDestReceiver(Oid transientoid)
{
	DR_transientrel *self = palloc0_object(DR_transientrel);

	self->pub.receiveSlot = transientrel_receive;
	self->pub.rStartup = transientrel_startup;
	self->pub.rShutdown = transientrel_shutdown;
	self->pub.rDestroy = transientrel_destroy;
	self->pub.mydest = DestTransientRel;
	self->transientoid = transientoid;

	return (DestReceiver *) self;
}

/*
 * transientrel_startup --- executor startup
 */
static void
transientrel_startup(DestReceiver *self, int operation, TupleDesc typeinfo)
{
	DR_transientrel *myState = (DR_transientrel *) self;
	Relation	transientrel;

	transientrel = table_open(myState->transientoid, NoLock);

	/*
	 * Fill private fields of myState for use by later routines
	 */
	myState->transientrel = transientrel;
	myState->output_cid = GetCurrentCommandId(true);
	myState->ti_options = TABLE_INSERT_SKIP_FSM | TABLE_INSERT_FROZEN;
	myState->bistate = GetBulkInsertState();

	/*
	 * Valid smgr_targblock implies something already wrote to the relation.
	 * This may be harmless, but this function hasn't planned for it.
	 */
	Assert(RelationGetTargetBlock(transientrel) == InvalidBlockNumber);
}

/*
 * transientrel_receive --- receive one tuple
 */
static bool
transientrel_receive(TupleTableSlot *slot, DestReceiver *self)
{
	DR_transientrel *myState = (DR_transientrel *) self;

	/*
	 * Note that the input slot might not be of the type of the target
	 * relation. That's supported by table_tuple_insert(), but slightly less
	 * efficient than inserting with the right slot - but the alternative
	 * would be to copy into a slot of the right type, which would not be
	 * cheap either. This also doesn't allow accessing per-AM data (say a
	 * tuple's xmin), but since we don't do that here...
	 */

	table_tuple_insert(myState->transientrel,
					   slot,
					   myState->output_cid,
					   myState->ti_options,
					   myState->bistate);

	/* We know this is a newly created relation, so there are no indexes */

	return true;
}

/*
 * transientrel_shutdown --- executor end
 */
static void
transientrel_shutdown(DestReceiver *self)
{
	DR_transientrel *myState = (DR_transientrel *) self;

	FreeBulkInsertState(myState->bistate);

	table_finish_bulk_insert(myState->transientrel, myState->ti_options);

	/* close transientrel, but keep lock until commit */
	table_close(myState->transientrel, NoLock);
	myState->transientrel = NULL;
}

/*
 * transientrel_destroy --- release DestReceiver object
 */
static void
transientrel_destroy(DestReceiver *self)
{
	pfree(self);
}

/*
 * Were these plans prepared for the same parameter types the caller now has?
 */

static bool
matview_argtypes_match(MatViewPartialRefreshCache *entry, ParamListInfo params)
{
	int			n = params ? params->numParams : 0;
	int			i;

	if (entry->nargs != n)
		return false;
	for (i = 0; i < n; i++)
	{
		if (entry->argtypes[i] != params->params[i].ptype)
			return false;
	}
	return true;
}

/*
 * Relcache callback: mark every cached entry stale.
 *
 * We only set a flag here.  A callback runs at points where an enclosing
 * refresh may be executing a plan out of one of these entries, so freeing now
 * would pull the ground out from under it; matview_cache_sweep() does the
 * freeing at a point where that cannot be true.  This is the rule plancache.c
 * and ri_triggers.c both follow.
 *
 * We ignore relid and mark everything, since an entry's plans can name any
 * relation the view definition reaches, not just the matview itself.
 */
static void
InvalidateMatViewCache(Datum arg, Oid relid)
{
	HASH_SEQ_STATUS status;
	MatViewPartialRefreshCache *entry;

	if (MatViewRefreshCache == NULL)
		return;

	hash_seq_init(&status, MatViewRefreshCache);
	while ((entry = (MatViewPartialRefreshCache *) hash_seq_search(&status)) != NULL)
		entry->invalid = true;
}

/*
 * Free the entries InvalidateMatViewCache() marked, before any plan is taken.
 *
 * We sweep every stale entry rather than only the caller's own, so that the
 * plans of matviews since dropped are reclaimed too.
 */
static void
matview_cache_sweep(void)
{
	HASH_SEQ_STATUS status;
	MatViewPartialRefreshCache *entry;

	if (MatViewRefreshCache == NULL)
		return;

	hash_seq_init(&status, MatViewRefreshCache);
	while ((entry = (MatViewPartialRefreshCache *) hash_seq_search(&status)) != NULL)
	{
		if (!entry->invalid)
			continue;

		if (entry->lockPlan)
			SPI_freeplan(entry->lockPlan);
		if (entry->dupPlan)
			SPI_freeplan(entry->dupPlan);
		if (entry->refreshPlan)
			SPI_freeplan(entry->refreshPlan);
		if (entry->sourcePlan)
			DropCachedPlan(entry->sourcePlan);
		if (entry->metacxt)
			MemoryContextDelete(entry->metacxt);

		if (hash_search(MatViewRefreshCache, &entry->matviewOid,
						HASH_REMOVE, NULL) == NULL)
			elog(ERROR, "hash table corrupted");
	}
}

/*
 * Create the session's partial-refresh plan cache and register the callback
 * that marks its entries stale.
 */
static void
InitMatViewCache(void)
{
	HASHCTL		ctl;

	memset(&ctl, 0, sizeof(ctl));
	ctl.keysize = sizeof(Oid);
	ctl.entrysize = sizeof(MatViewPartialRefreshCache);
	ctl.hcxt = CacheMemoryContext;

	MatViewRefreshCache = hash_create("MatView Partial Refresh Cache",
									  16,
									  &ctl,
									  HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	CacheRegisterRelcacheCallback(InvalidateMatViewCache, (Datum) 0);
}

/*
 * Build the query that produces a partial refresh's source rows: the matview's
 * own defining query, wrapped in a subquery so the predicate filters its
 * output, ordered by the arbiter key.
 */

static Query *
matview_build_source_query(Relation matviewRel, Query *dataQuery, Node *qual,
						   int nkeyatts, const int16 *keyattnums)
{
	ParseState *pstate = make_parsestate(NULL);
	ParseNamespaceItem *nsitem;
	Query	   *sourceQuery = makeNode(Query);
	Node	   *sourceQual = copyObject(qual);
	List	   *sortlist = NIL;
	int			i;

	nsitem = addRangeTableEntryForSubquery(pstate,
										   copyObject(dataQuery),
										   makeAlias(RelationGetRelationName(matviewRel),
													 NIL),
										   false,
										   true);
	addNSItemToQuery(pstate, nsitem, true, false, true);

	Assert(nsitem->p_rtindex == 1);

	sourceQuery->commandType = CMD_SELECT;
	sourceQuery->canSetTag = true;

	sourceQuery->targetList = expandNSItemAttrs(pstate, nsitem, 0, false, -1);

	for (i = 0; i < nkeyatts; i++)
	{
		int			attnum = keyattnums[i];
		TargetEntry *tle = list_nth_node(TargetEntry, sourceQuery->targetList,
										 attnum - 1);
		SortBy	   *sortby = makeNode(SortBy);

		Assert(attnum > 0 && tle->resno == attnum);

		sortby->node = (Node *) tle->expr;
		sortby->sortby_dir = SORTBY_DEFAULT;
		sortby->sortby_nulls = SORTBY_NULLS_DEFAULT;
		sortby->useOp = NIL;
		sortby->location = -1;

		sortlist = addTargetToSortList(pstate, tle, sortlist,
									   sourceQuery->targetList, sortby);
	}

	sourceQuery->rtable = pstate->p_rtable;
	sourceQuery->rteperminfos = pstate->p_rteperminfos;
	sourceQuery->jointree = makeFromExpr(pstate->p_joinlist, sourceQual);
	sourceQuery->sortClause = sortlist;

	sourceQuery->hasSubLinks = checkExprHasSubLink(sourceQual);

	free_parsestate(pstate);

	return sourceQuery;
}

/*
 * Wrap the source query in a CachedPlanSource, so that plancache revalidates it
 * and it survives across refreshes.
 *
 * queryString is the REFRESH statement the caller issued.  We have no SQL text
 * for the source query itself, since we build it as a Query tree, and
 * CreateCachedPlan() requires a string: it keeps it as the plansource's
 * identifier and prints it in error contexts.  The statement that asked for the
 * work is the honest answer there, and it is what refresh_matview_datafill()
 * already hands the planner on the full-refresh path.
 */

static CachedPlanSource *
matview_build_source_plansource(Query *sourceQuery, const char *queryString)
{
	CachedPlanSource *plansource;
	List	   *querytree_list;

	plansource = CreateCachedPlanForQuery(sourceQuery,
										  queryString,
										  CreateCommandTag((Node *) sourceQuery));

	AcquireRewriteLocks(sourceQuery, true, false);

	querytree_list = pg_rewrite_query(sourceQuery);

	if (list_length(querytree_list) != 1)
		elog(ERROR, "unexpected rewrite result for REFRESH MATERIALIZED VIEW");

	CompleteCachedPlan(plansource,
					   querytree_list,
					   NULL,
					   NULL,
					   0,
					   NULL,
					   NULL,
					   CURSOR_OPT_PARALLEL_OK,
					   false);

	return plansource;
}

/*
 * Run the source query under the given snapshot, collecting its rows into the
 * tuplestore the fused statement reads.  Returns the number of rows collected.
 *
 * This is the sequence the full refresh uses in refresh_matview_datafill().
 * The only difference is where we put the rows.
 */

static double
matview_materialize_source(CachedPlanSource *plansource, ParamListInfo params,
						   Snapshot snapshot, Tuplestorestate *tupstore)
{
	CachedPlan *cplan;
	PlannedStmt *plan;
	QueryDesc  *queryDesc;
	DestReceiver *dest;
	ResourceOwner owner;
	double		processed;
	const CachedPlan *generic_before;
	int64		custom_before;

	CHECK_FOR_INTERRUPTS();

	owner = plansource->is_saved ? CurrentResourceOwner : NULL;

	generic_before = plansource->gplan;
	custom_before = plansource->num_custom_plans;

	cplan = GetCachedPlan(plansource, params, owner, NULL);

	if (plansource->gplan != generic_before ||
		plansource->num_custom_plans > custom_before)
		INJECTION_POINT("matview-where-source-planned", NULL);

	plan = linitial_node(PlannedStmt, cplan->stmt_list);

	dest = CreateDestReceiver(DestTuplestore);
	SetTuplestoreDestReceiverParams(dest, tupstore, CurrentMemoryContext,
									false, NULL, NULL);

	queryDesc = CreateQueryDesc(plan, "REFRESH MATERIALIZED VIEW",
								snapshot, InvalidSnapshot,
								dest, params, NULL, 0);

	ExecutorStart(queryDesc, 0);
	ExecutorRun(queryDesc, ForwardScanDirection, 0);
	processed = (double) queryDesc->estate->es_processed;
	ExecutorFinish(queryDesc);
	ExecutorEnd(queryDesc);
	FreeQueryDesc(queryDesc);

	dest->rDestroy(dest);

	ReleaseCachedPlan(cplan, owner);

	return processed;
}

/*
 * refresh_by_direct_modification
 *
 * Refresh the rows of a materialized view that a WHERE clause selects, leaving
 * the rest alone, while allowing concurrent reads and concurrent refreshes of
 * scopes that do not overlap.
 *
 * We hold RowExclusiveLock on the matview, so we serialize against another
 * partial refresh only where the two touch the same rows.  The work is four
 * steps:
 *
 * 1. Lock the matview rows the predicate selects, with SELECT ... FOR NO KEY
 *    UPDATE ordered by the arbiter index's key columns.  Two overlapping
 *    refreshes then take their row locks in the same order and queue rather
 *    than deadlock.  We hold these locks until the transaction ends.
 *
 * 2. Take the snapshot the rest of the work runs under.  We do this after the
 *    lock rather than before it: a refresh that queued behind another must not
 *    evaluate its source from before that one committed, or it would write
 *    stale values back over it.
 *
 * 3. Evaluate the matview's defining query under the predicate, collecting the
 *    rows into a tuplestore that we register as an ephemeral named relation.
 *
 * 4. Apply them with one statement that upserts those rows against the arbiter
 *    index and deletes the rows in scope the source did not produce.  Both
 *    halves read the same tuplestore under the same snapshot, so they cannot
 *    disagree about what the view produces.  The upsert leaves alone any row
 *    whose values did not change.
 *
 * This needs exactly one unique index for the upsert to arbitrate on, which
 * the caller has already checked.  A source producing two rows with the same
 * key cannot be applied a row at a time, so we reject that between steps 3
 * and 4.
 *
 * The plans for steps 1 and 4, and the plansource for step 3, are cached for
 * the session and keyed on the arbiter index, the predicate and the parameter
 * types.
 */
static uint64
refresh_by_direct_modification(Oid matviewOid, Oid relowner, Oid callerId,
							   int save_sec_context, Query *dataQuery,
							   Node *qual, const char *queryString,
							   ParamListInfo params)
{
	Relation	matviewRel;
	Oid			uniqueIndexOid = InvalidOid;
	List	   *indexoidlist;
	ListCell   *lc;
	MatViewPartialRefreshCache *cacheEntry;
	MatViewPartialRefreshCache localEntry;
	bool		use_cache;
	bool		found;
	uint64		result_processed = 0;
	int			old_depth;
	Oid			old_relid;
	int			nkeyatts = 0;
	int16	   *keyattnums = NULL;
	Tuplestorestate *sourceStore = NULL;

	matviewRel = table_open(matviewOid, NoLock);

	indexoidlist = RelationGetIndexList(matviewRel);
	foreach(lc, indexoidlist)
	{
		Oid			indexoid = lfirst_oid(lc);
		Relation	indexRel;
		bool		usable;

		indexRel = index_open(indexoid, AccessShareLock);
		usable = is_usable_unique_index(indexRel);
		index_close(indexRel, AccessShareLock);

		if (usable)
		{
			uniqueIndexOid = indexoid;
			break;
		}
	}
	list_free(indexoidlist);

	if (!OidIsValid(uniqueIndexOid))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("cannot perform partial refresh on materialized view \"%s\"",
						RelationGetRelationName(matviewRel)),
				 errdetail("Partial refresh requires a usable unique index to perform an UPSERT operation.")));

	/*
	 * We use the session cache only at the outermost level.  A predicate
	 * function or the view definition may issue another partial refresh, and
	 * that nested call would sweep the entry we are still executing from.  So
	 * a nested refresh prepares private plans and touches neither the hash
	 * table nor its entries.
	 */
	use_cache = (matview_maintenance_depth == 0);

	if (use_cache)
	{
		if (!MatViewRefreshCache)
			InitMatViewCache();

		matview_cache_sweep();

		cacheEntry = (MatViewPartialRefreshCache *)
			hash_search(MatViewRefreshCache, &matviewOid, HASH_ENTER, &found);

		if (!found)
			cacheEntry->metacxt = NULL;
	}
	else
	{
		memset(&localEntry, 0, sizeof(localEntry));
		localEntry.matviewOid = matviewOid;
		cacheEntry = &localEntry;
		found = false;
	}

	/*
	 * Same predicate means an equal() tree: the plans were built by deparsing
	 * this tree, so two trees that compare equal deparse to the same
	 * statement.  argtypes is still checked, since a caller may bind a
	 * parameter the predicate never names.
	 *
	 * The plans must also still be valid, and that is not belt and braces.  A
	 * qual tree names a function or operator by OID, so renaming one leaves the
	 * tree equal() to the cached one while the statements built from it still
	 * spell the old name.  plancache invalidates those statements and
	 * re-analyzes their text, binding the old name to whatever holds it now, a
	 * different object or none at all.  The tree would then drive the source
	 * while the stale text drives the pre-lock and the prune, over different
	 * rows.  So we ask plancache whether its plan is still good and rebuild
	 * from a fresh deparse when it is not, which is what
	 * ri_FetchPreparedPlan() does and for the same reason.
	 */
	if (found &&
		cacheEntry->uniqueIndexOid == uniqueIndexOid &&
		cacheEntry->qual != NULL &&
		equal(cacheEntry->qual, qual) &&
		cacheEntry->nargs == (params ? params->numParams : 0) &&
		matview_argtypes_match(cacheEntry, params) &&
		cacheEntry->lockPlan != NULL &&
		cacheEntry->dupPlan != NULL &&
		cacheEntry->refreshPlan != NULL &&
		SPI_plan_is_valid(cacheEntry->lockPlan) &&
		SPI_plan_is_valid(cacheEntry->dupPlan) &&
		SPI_plan_is_valid(cacheEntry->refreshPlan))
	{
	}
	else
	{
		if (found)
		{
			if (cacheEntry->lockPlan)
				SPI_freeplan(cacheEntry->lockPlan);
			if (cacheEntry->dupPlan)
				SPI_freeplan(cacheEntry->dupPlan);
			if (cacheEntry->refreshPlan)
				SPI_freeplan(cacheEntry->refreshPlan);
			if (cacheEntry->sourcePlan)
				DropCachedPlan(cacheEntry->sourcePlan);
			if (cacheEntry->metacxt)
				MemoryContextReset(cacheEntry->metacxt);
		}

		cacheEntry->lockPlan = NULL;
		cacheEntry->dupPlan = NULL;
		cacheEntry->refreshPlan = NULL;
		cacheEntry->sourcePlan = NULL;
		cacheEntry->qual = NULL;
		cacheEntry->nargs = 0;
		cacheEntry->argtypes = NULL;
		cacheEntry->invalid = false;
	}

	old_depth = matview_maintenance_depth;
	old_relid = matview_maintenance_relid;
	OpenMatViewIncrementalMaintenance(matviewOid);

	PG_TRY();
	{
		SPI_connect();

		{
			Relation	indexRel = index_open(uniqueIndexOid, AccessShareLock);
			Form_pg_index indexStruct = indexRel->rd_index;
			EphemeralNamedRelation enr;
			int			i;

			nkeyatts = indexStruct->indnkeyatts;
			keyattnums = (int16 *) palloc(nkeyatts * sizeof(int16));
			for (i = 0; i < nkeyatts; i++)
				keyattnums[i] = indexStruct->indkey.values[i];
			index_close(indexRel, AccessShareLock);

			sourceStore = tuplestore_begin_heap(false, false, work_mem);

			enr = (EphemeralNamedRelation) palloc0(sizeof(EphemeralNamedRelationData));
			enr->md.name = MATVIEW_SOURCE_ENR_NAME;
			enr->md.reliddesc = InvalidOid;
			enr->md.tupdesc = CreateTupleDescCopy(RelationGetDescr(matviewRel));
			enr->md.enrtype = ENR_NAMED_TUPLESTORE;

			/*
			 * A row estimate for new_data, which is empty at this point, since
			 * we fill the tuplestore after the pre-lock below.  We cannot
			 * supply the true count and cannot correct this later: parse
			 * analysis copies the value into the range table entry, so
			 * SPI_prepare captures it and it travels inside the cached plan,
			 * which then serves refreshes whose scopes differ by orders of
			 * magnitude.  The matview's own row count is the right order of
			 * magnitude and errs high, which is the safe direction, since an
			 * overestimate biases the prune's anti-join towards a hash join.
			 */
			enr->md.enrtuples = Max(matviewRel->rd_rel->reltuples, 0);
			enr->reldata = sourceStore;

			if (SPI_register_relation(enr) != SPI_OK_REL_REGISTER)
				elog(ERROR, "could not register source rows for partial refresh");
		}

		/* Prepare plans if we don't have valid cached ones. */
		if (cacheEntry->lockPlan == NULL || cacheEntry->dupPlan == NULL ||
			cacheEntry->refreshPlan == NULL)
		{
			StringInfoData buf;
			char	   *matview_name;
			char	   *whereClauseStr;
			Oid		   *argtypes = NULL;
			int			nargs = 0;
			Relation	indexRel;
			Form_pg_index indexStruct;
			TupleDesc	tupdesc = matviewRel->rd_att;
			StringInfoData conflict_cols;
			StringInfoData notnull_cols;
			StringInfoData set_clause;
			StringInfoData mv_cols;
			StringInfoData excluded_cols;
			bool		first_distinct = true;
			StringInfoData join_clause;
			const char *anti_join_op;
			bool		first;
			bool		has_non_key_cols = false;
			int			i;
			MemoryContext oldcxt;

			matview_name = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),
													  RelationGetRelationName(matviewRel));

			whereClauseStr = deparseRefreshWhereClause(matviewOid, qual);

			if (params && params->numParams > 0)
			{
				nargs = params->numParams;
				argtypes = (Oid *) palloc(nargs * sizeof(Oid));
				for (i = 0; i < nargs; i++)
					argtypes[i] = params->params[i].ptype;
			}

			indexRel = index_open(uniqueIndexOid, AccessShareLock);
			indexStruct = indexRel->rd_index;

			/*
			 * The anti-join decides which matview rows the query still
			 * produces and ON CONFLICT decides which ones the upsert can
			 * match.  The two must agree about NULLs, or a row is "still
			 * present" to one and "brand new" to the other, and we duplicate
			 * it.  So we follow whatever the arbiter index does.
			 */
			anti_join_op = indexStruct->indnullsnotdistinct ?
				"IS NOT DISTINCT FROM" : "=";

			initStringInfo(&conflict_cols);
			initStringInfo(&notnull_cols);
			initStringInfo(&mv_cols);
			initStringInfo(&excluded_cols);
			initStringInfo(&set_clause);
			initStringInfo(&join_clause);

			first = true;
			for (i = 0; i < indexStruct->indnkeyatts; i++)
			{
				int			attnum = indexStruct->indkey.values[i];
				Form_pg_attribute attr = TupleDescAttr(tupdesc, attnum - 1);
				const char *quoted;

				quoted = quote_identifier(NameStr(attr->attname));

				if (!first)
				{
					appendStringInfoString(&conflict_cols, ", ");
					appendStringInfoString(&notnull_cols, " AND ");
					appendStringInfoString(&join_clause, " AND ");
				}
				first = false;

				appendStringInfoString(&conflict_cols, quoted);
				appendStringInfo(&notnull_cols, "%s IS NOT NULL", quoted);
				appendStringInfo(&join_clause, "nd.%s %s " MATVIEW_ALIAS ".%s",
								 quoted, anti_join_op, quoted);
			}

			first = true;
			for (i = 0; i < tupdesc->natts; i++)
			{
				Form_pg_attribute attr = TupleDescAttr(tupdesc, i);
				const char *quoted;
				bool		is_key = false;
				int			j;

				if (attr->attisdropped)
					continue;

				for (j = 0; j < indexStruct->indnkeyatts; j++)
				{
					if (indexStruct->indkey.values[j] == (i + 1))
					{
						is_key = true;
						break;
					}
				}

				if (is_key)
					continue;

				if (!first)
					appendStringInfoString(&set_clause, ", ");
				first = false;
				has_non_key_cols = true;

				quoted = quote_identifier(NameStr(attr->attname));
				appendStringInfo(&set_clause, "%s = EXCLUDED.%s", quoted, quoted);

				if (!first_distinct)
				{
					appendStringInfoString(&mv_cols, ", ");
					appendStringInfoString(&excluded_cols, ", ");
				}
				first_distinct = false;
				appendStringInfo(&mv_cols, MATVIEW_ALIAS ".%s", quoted);
				appendStringInfo(&excluded_cols, "EXCLUDED.%s", quoted);
			}

			index_close(indexRel, AccessShareLock);

			Assert(conflict_cols.len > 0);
			Assert(join_clause.len > 0);

			initStringInfo(&buf);

			/*
			 * We fix the lock order here, so that two refreshes whose
			 * predicates overlap cannot take the same rows in opposite orders
			 * and deadlock.
			 */
			appendStringInfo(&buf,
							 "SELECT 1 FROM %s " MATVIEW_ALIAS " WHERE (%s) ORDER BY %s "
							 "FOR NO KEY UPDATE",
							 matview_name, whereClauseStr, conflict_cols.data);

			cacheEntry->lockPlan = SPI_prepare(buf.data, nargs, argtypes);
			if (cacheEntry->lockPlan == NULL)
				elog(ERROR, "SPI_prepare failed for lock acquisition: %s", buf.data);
			if (use_cache)
				SPI_keepplan(cacheEntry->lockPlan);

			resetStringInfo(&buf);

			/*
			 * We apply the source rows one at a time against the arbiter
			 * index, so we cannot represent two source rows sharing a key
			 * value: the second would silently overwrite the first and leave
			 * the matview with fewer rows than the query produces.
			 * refresh_by_match_merge() has its own version of this check for
			 * the same reason, and a partial refresh never reaches it.
			 *
			 * We group rather than self-join, since the source is a tuplestore
			 * and has no ctid to tell two equal rows apart.  Which rows
			 * conflict is the index's question, not GROUP BY's: for an
			 * ordinary unique index a NULL key never conflicts, so those rows
			 * are filtered out first, and for NULLS NOT DISTINCT they do,
			 * which is what grouping already does.
			 */
			appendStringInfo(&buf,
							 "SELECT CAST(ROW(%s) AS pg_catalog.text) FROM "
							 MATVIEW_SOURCE_ENR_NAME, conflict_cols.data);
			if (!indexStruct->indnullsnotdistinct)
				appendStringInfo(&buf, " WHERE %s", notnull_cols.data);
			appendStringInfo(&buf,
							 " GROUP BY %s HAVING pg_catalog.count(*) > 1 LIMIT 1",
							 conflict_cols.data);

			cacheEntry->dupPlan = SPI_prepare(buf.data, 0, NULL);
			if (cacheEntry->dupPlan == NULL)
				elog(ERROR, "SPI_prepare failed for duplicate check: %s", buf.data);
			if (use_cache)
				SPI_keepplan(cacheEntry->dupPlan);

			resetStringInfo(&buf);

			appendStringInfoString(&buf, "WITH ");

			appendStringInfo(&buf,
							 "upsert AS ( "
							 "  INSERT INTO %s AS " MATVIEW_ALIAS
							 "  SELECT * FROM new_data "
							 "  ON CONFLICT (%s) DO ",
							 matview_name, conflict_cols.data);

			if (has_non_key_cols)
				appendStringInfo(&buf,
								 "UPDATE SET %s WHERE (%s) IS DISTINCT FROM (%s) ",
								 set_clause.data, mv_cols.data, excluded_cols.data);
			else
				appendStringInfoString(&buf, "NOTHING ");

			/*
			 * Both halves RETURN a row apiece, so the statement's own result is
			 * the number of rows it wrote, which is what the command reports.
			 */
			appendStringInfo(&buf,
							 "  RETURNING 1 "
							 "), "
							 "pruned AS ( "
							 "  DELETE FROM %s " MATVIEW_ALIAS " WHERE (%s) AND NOT EXISTS ( "
							 "    SELECT 1 FROM new_data nd WHERE %s"
							 "  ) RETURNING 1 "
							 ") "
							 "SELECT (SELECT pg_catalog.count(*) FROM upsert) "
							 "     + (SELECT pg_catalog.count(*) FROM pruned)",
							 matview_name, whereClauseStr, join_clause.data);

			cacheEntry->refreshPlan = SPI_prepare(buf.data, nargs, argtypes);
			if (cacheEntry->refreshPlan == NULL)
				elog(ERROR, "SPI_prepare failed for refresh CTE: %s", buf.data);
			if (use_cache)
				SPI_keepplan(cacheEntry->refreshPlan);

			if (use_cache)
			{
				if (cacheEntry->metacxt == NULL)
					cacheEntry->metacxt =
						AllocSetContextCreate(CacheMemoryContext,
											  "MatView Partial Refresh Cache Key",
											  ALLOCSET_SMALL_SIZES);

				oldcxt = MemoryContextSwitchTo(cacheEntry->metacxt);
				cacheEntry->uniqueIndexOid = uniqueIndexOid;
				cacheEntry->qual = copyObject(qual);
				cacheEntry->nargs = nargs;
				if (nargs > 0)
				{
					cacheEntry->argtypes = (Oid *) palloc(nargs * sizeof(Oid));
					memcpy(cacheEntry->argtypes, argtypes, nargs * sizeof(Oid));
				}
				else
					cacheEntry->argtypes = NULL;
				MemoryContextSwitchTo(oldcxt);
			}

			pfree(whereClauseStr);
			pfree(matview_name);
			pfree(buf.data);
			pfree(conflict_cols.data);
			pfree(notnull_cols.data);
			pfree(set_clause.data);
			pfree(mv_cols.data);
			pfree(excluded_cols.data);
			pfree(join_clause.data);
			if (argtypes != NULL)
				pfree(argtypes);
		}

		/*
		 * We lock the matview rows in scope before evaluating the source, and
		 * take the snapshot the source runs under only afterwards.  The order
		 * matters: a refresh that queued behind another must not evaluate its
		 * source from before that one committed, or it writes stale values
		 * back over it.
		 */
		if (matview_execute_spi_plan(cacheEntry->lockPlan, params,
									 InvalidSnapshot, false) < 0)
			elog(ERROR, "SPI_execute_plan failed during lock acquisition");

		INJECTION_POINT("matview-where-locked", NULL);

		{
			Query	   *sourceQuery;
			Snapshot	snapshot;

			CommandCounterIncrement();
			PushCopiedSnapshot(GetTransactionSnapshot());
			snapshot = GetActiveSnapshot();

			if (cacheEntry->sourcePlan == NULL)
			{
				sourceQuery = matview_build_source_query(matviewRel, dataQuery,
														 qual, nkeyatts,
														 keyattnums);
				cacheEntry->sourcePlan =
					matview_build_source_plansource(sourceQuery, queryString);
				if (use_cache)
					SaveCachedPlan(cacheEntry->sourcePlan);
			}

			matview_materialize_source(cacheEntry->sourcePlan, params, snapshot,
									   sourceStore);

			INJECTION_POINT("matview-where-source-materialized", NULL);

			/*
			 * Refuse before writing anything if we cannot apply the source one
			 * row at a time.
			 *
			 * We name the duplicated key only for a caller who owns the
			 * matview.  refresh_by_match_merge() prints the offending row
			 * unconditionally, on the stated grounds that only the owner can
			 * run REFRESH, which has not been true since MAINTAIN was added.
			 * A partial refresh is the path a MAINTAIN-only caller is most
			 * likely to be on, and the key comes out of a matview they may
			 * hold no privilege to read.
			 */
			if (matview_execute_spi_plan(cacheEntry->dupPlan, NULL,
										 snapshot, true) < 0)
				elog(ERROR, "SPI_execute_plan failed during duplicate check");

			if (SPI_processed > 0)
			{
				char	   *dupkey = NULL;

				if (object_ownercheck(RelationRelationId, matviewOid, callerId))
					dupkey = SPI_getvalue(SPI_tuptable->vals[0],
										  SPI_tuptable->tupdesc, 1);

				ereport(ERROR,
						(errcode(ERRCODE_CARDINALITY_VIOLATION),
						 errmsg("new data for materialized view \"%s\" contains duplicate rows",
								RelationGetRelationName(matviewRel)),
						 dupkey != NULL
						 ? errdetail("Key: %s", dupkey)
						 : errdetail("More than one row of the new data has the same key as another for the unique index a partial refresh applies its changes against."),
						 errhint("A partial refresh applies its changes one row at a time, so the new data must not contain two rows with the same key.")));
			}

			if (matview_execute_spi_plan(cacheEntry->refreshPlan, params,
										 snapshot, false) < 0)
				elog(ERROR, "SPI_execute_plan failed during refresh");

			PopActiveSnapshot();
		}

		if (SPI_processed == 1 && SPI_tuptable != NULL &&
			SPI_tuptable->numvals == 1)
		{
			bool		isnull;
			Datum		d = SPI_getbinval(SPI_tuptable->vals[0],
										  SPI_tuptable->tupdesc, 1, &isnull);

			if (!isnull)
				result_processed = (uint64) DatumGetInt64(d);
		}

		if (sourceStore != NULL)
			tuplestore_end(sourceStore);

		if (!use_cache && cacheEntry->sourcePlan != NULL)
		{
			DropCachedPlan(cacheEntry->sourcePlan);
			cacheEntry->sourcePlan = NULL;
		}

		SPI_finish();
	}
	PG_CATCH();
	{
		matview_maintenance_depth = old_depth;
		matview_maintenance_relid = old_relid;

		if (!use_cache && cacheEntry->sourcePlan != NULL)
		{
			DropCachedPlan(cacheEntry->sourcePlan);
			cacheEntry->sourcePlan = NULL;
		}
		PG_RE_THROW();
	}
	PG_END_TRY();

	CloseMatViewIncrementalMaintenance();
	Assert(matview_maintenance_depth == old_depth);
	table_close(matviewRel, NoLock);

	return result_processed;
}

/*
 * refresh_by_match_merge
 *
 * Refresh a materialized view with transactional semantics, while allowing
 * concurrent reads.
 *
 * This is called after a new version of the data has been created in a
 * temporary table.  It performs a full outer join against the old version of
 * the data, producing "diff" results.  This join cannot work if there are any
 * duplicated rows in either the old or new versions, in the sense that every
 * column would compare as equal between the two rows.  It does work correctly
 * in the face of rows which have at least one NULL value, with all non-NULL
 * columns equal.  The behavior of NULLs on equality tests and on UNIQUE
 * indexes turns out to be quite convenient here; the tests we need to make
 * are consistent with default behavior.  If there is at least one UNIQUE
 * index on the materialized view, we have exactly the guarantee we need.
 *
 * The temporary table used to hold the diff results contains just the TID of
 * the old record (if matched) and the ROW from the new table as a single
 * column of complex record type (if matched).
 *
 * Once we have the diff table, we perform set-based DELETE and INSERT
 * operations against the materialized view, and discard both temporary
 * tables.
 *
 * Everything from the generation of the new data to applying the differences
 * takes place under cover of an ExclusiveLock, since it seems as though we
 * would want to prohibit not only concurrent REFRESH operations, but also
 * incremental maintenance.  It also doesn't seem reasonable or safe to allow
 * SELECT FOR UPDATE or SELECT FOR SHARE on rows being updated or deleted by
 * this command.
 */
static void
refresh_by_match_merge(Oid matviewOid, Oid tempOid, Oid relowner,
					   int save_sec_context)
{
	StringInfoData querybuf;
	Relation	matviewRel;
	Relation	tempRel;
	char	   *matviewname;
	char	   *tempname;
	char	   *diffname;
	char	   *temprelname;
	char	   *diffrelname;
	char	   *nsp;
	TupleDesc	tupdesc;
	bool		foundUniqueIndex;
	List	   *indexoidlist;
	ListCell   *indexoidscan;
	int16		relnatts;
	Oid		   *opUsedForQual;

	initStringInfo(&querybuf);
	matviewRel = table_open(matviewOid, NoLock);
	matviewname = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(matviewRel)),
											 RelationGetRelationName(matviewRel));
	tempRel = table_open(tempOid, NoLock);

	/*
	 * Build qualified names of the temporary table and the diff table.  The
	 * only difference between them is the "_2" suffix on the diff table name.
	 */
	nsp = get_namespace_name(RelationGetNamespace(tempRel));
	temprelname = RelationGetRelationName(tempRel);
	diffrelname = psprintf("%s_2", temprelname);

	tempname = quote_qualified_identifier(nsp, temprelname);
	diffname = quote_qualified_identifier(nsp, diffrelname);

	relnatts = RelationGetNumberOfAttributes(matviewRel);

	/* Open SPI context. */
	SPI_connect();

	/* Analyze the temp table with the new contents. */
	appendStringInfo(&querybuf, "ANALYZE %s", tempname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_UTILITY)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	/*
	 * We need to ensure that there are not duplicate rows without NULLs in
	 * the new data set before we can count on the "diff" results.  Check for
	 * that in a way that allows showing the first duplicated row found.  Even
	 * after we pass this test, a unique index on the materialized view may
	 * find a duplicate key problem.
	 *
	 * Note: here and below, we use "tablename.*::tablerowtype" as a hack to
	 * keep ".*" from being expanded into multiple columns in a SELECT list.
	 * Compare ruleutils.c's get_variable().
	 */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "SELECT newdata.*::%s FROM %s newdata "
					 "WHERE newdata.* IS NOT NULL AND EXISTS "
					 "(SELECT 1 FROM %s newdata2 WHERE newdata2.* IS NOT NULL "
					 "AND newdata2.* OPERATOR(pg_catalog.*=) newdata.* "
					 "AND newdata2.ctid OPERATOR(pg_catalog.<>) "
					 "newdata.ctid)",
					 tempname, tempname, tempname);
	if (SPI_execute(querybuf.data, false, 1) != SPI_OK_SELECT)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);
	if (SPI_processed > 0)
	{
		/*
		 * Note that this ereport() is returning data to the user.  Generally,
		 * we would want to make sure that the user has been granted access to
		 * this data.  However, REFRESH MAT VIEW is only able to be run by the
		 * owner of the mat view (or a superuser) and therefore there is no
		 * need to check for access to data in the mat view.
		 */
		ereport(ERROR,
				(errcode(ERRCODE_CARDINALITY_VIOLATION),
				 errmsg("new data for materialized view \"%s\" contains duplicate rows without any null columns",
						RelationGetRelationName(matviewRel)),
				 errdetail("Row: %s",
						   SPI_getvalue(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1))));
	}

	/*
	 * Create the temporary "diff" table.
	 *
	 * Temporarily switch out of the SECURITY_RESTRICTED_OPERATION context,
	 * because you cannot create temp tables in SRO context.  For extra
	 * paranoia, add the composite type column only after switching back to
	 * SRO context.
	 */
	SetUserIdAndSecContext(relowner,
						   save_sec_context | SECURITY_LOCAL_USERID_CHANGE);
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "CREATE TEMP TABLE %s (tid pg_catalog.tid)",
					 diffname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_UTILITY)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);
	SetUserIdAndSecContext(relowner,
						   save_sec_context | SECURITY_RESTRICTED_OPERATION);
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "ALTER TABLE %s ADD COLUMN newdata %s",
					 diffname, tempname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_UTILITY)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	/* Start building the query for populating the diff table. */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "INSERT INTO %s "
					 "SELECT mv.ctid AS tid, newdata.*::%s AS newdata "
					 "FROM %s mv FULL JOIN %s newdata ON (",
					 diffname, tempname, matviewname, tempname);

	/*
	 * Get the list of index OIDs for the table from the relcache, and look up
	 * each one in the pg_index syscache.  We will test for equality on all
	 * columns present in all unique indexes which only reference columns and
	 * include all rows.
	 */
	tupdesc = matviewRel->rd_att;
	opUsedForQual = palloc0_array(Oid, relnatts);
	foundUniqueIndex = false;

	indexoidlist = RelationGetIndexList(matviewRel);

	foreach(indexoidscan, indexoidlist)
	{
		Oid			indexoid = lfirst_oid(indexoidscan);
		Relation	indexRel;

		indexRel = index_open(indexoid, RowExclusiveLock);
		if (is_usable_unique_index(indexRel))
		{
			Form_pg_index indexStruct = indexRel->rd_index;
			int			indnkeyatts = indexStruct->indnkeyatts;
			oidvector  *indclass;
			Datum		indclassDatum;
			int			i;

			/* Must get indclass the hard way. */
			indclassDatum = SysCacheGetAttrNotNull(INDEXRELID,
												   indexRel->rd_indextuple,
												   Anum_pg_index_indclass);
			indclass = (oidvector *) DatumGetPointer(indclassDatum);

			/* Add quals for all columns from this index. */
			for (i = 0; i < indnkeyatts; i++)
			{
				int			attnum = indexStruct->indkey.values[i];
				Oid			opclass = indclass->values[i];
				Form_pg_attribute attr = TupleDescAttr(tupdesc, attnum - 1);
				Oid			attrtype = attr->atttypid;
				HeapTuple	cla_ht;
				Form_pg_opclass cla_tup;
				Oid			opfamily;
				Oid			opcintype;
				Oid			op;
				const char *leftop;
				const char *rightop;

				/*
				 * Identify the equality operator associated with this index
				 * column.  First we need to look up the column's opclass.
				 */
				cla_ht = SearchSysCache1(CLAOID, ObjectIdGetDatum(opclass));
				if (!HeapTupleIsValid(cla_ht))
					elog(ERROR, "cache lookup failed for opclass %u", opclass);
				cla_tup = (Form_pg_opclass) GETSTRUCT(cla_ht);
				opfamily = cla_tup->opcfamily;
				opcintype = cla_tup->opcintype;
				ReleaseSysCache(cla_ht);

				op = get_opfamily_member_for_cmptype(opfamily, opcintype, opcintype, COMPARE_EQ);
				if (!OidIsValid(op))
					elog(ERROR, "missing equality operator for (%u,%u) in opfamily %u",
						 opcintype, opcintype, opfamily);

				/*
				 * If we find the same column with the same equality semantics
				 * in more than one index, we only need to emit the equality
				 * clause once.
				 *
				 * Since we only remember the last equality operator, this
				 * code could be fooled into emitting duplicate clauses given
				 * multiple indexes with several different opclasses ... but
				 * that's so unlikely it doesn't seem worth spending extra
				 * code to avoid.
				 */
				if (opUsedForQual[attnum - 1] == op)
					continue;
				opUsedForQual[attnum - 1] = op;

				/*
				 * Actually add the qual, ANDed with any others.
				 */
				if (foundUniqueIndex)
					appendStringInfoString(&querybuf, " AND ");

				leftop = quote_qualified_identifier("newdata",
													NameStr(attr->attname));
				rightop = quote_qualified_identifier("mv",
													 NameStr(attr->attname));

				generate_operator_clause(&querybuf,
										 leftop, attrtype,
										 op,
										 rightop, attrtype);

				foundUniqueIndex = true;
			}
		}

		/* Keep the locks, since we're about to run DML which needs them. */
		index_close(indexRel, NoLock);
	}

	list_free(indexoidlist);

	/*
	 * There must be at least one usable unique index on the matview.
	 *
	 * ExecRefreshMatView() checks that after taking the exclusive lock on the
	 * matview. So at least one unique index is guaranteed to exist here
	 * because the lock is still being held.  (One known exception is if a
	 * function called as part of refreshing the matview drops the index.
	 * That's a pretty silly thing to do.)
	 */
	if (!foundUniqueIndex)
		ereport(ERROR,
				errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				errmsg("could not find suitable unique index on materialized view \"%s\"",
					   RelationGetRelationName(matviewRel)));

	appendStringInfoString(&querybuf,
						   " AND newdata.* OPERATOR(pg_catalog.*=) mv.*) "
						   "WHERE newdata.* IS NULL OR mv.* IS NULL "
						   "ORDER BY tid");

	/* Populate the temporary "diff" table. */
	if (SPI_exec(querybuf.data, 0) != SPI_OK_INSERT)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	/*
	 * We have no further use for data from the "full-data" temp table, but we
	 * must keep it around because its type is referenced from the diff table.
	 */

	/* Analyze the diff table. */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf, "ANALYZE %s", diffname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_UTILITY)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	OpenMatViewIncrementalMaintenance(matviewOid);

	/* Deletes must come before inserts; do them first. */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "DELETE FROM %s mv WHERE ctid OPERATOR(pg_catalog.=) ANY "
					 "(SELECT diff.tid FROM %s diff "
					 "WHERE diff.tid IS NOT NULL "
					 "AND diff.newdata IS NULL)",
					 matviewname, diffname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_DELETE)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	/* Inserts go last. */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "INSERT INTO %s SELECT (diff.newdata).* "
					 "FROM %s diff WHERE tid IS NULL",
					 matviewname, diffname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_INSERT)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	/* We're done maintaining the materialized view. */
	CloseMatViewIncrementalMaintenance();
	table_close(tempRel, NoLock);
	table_close(matviewRel, NoLock);

	/* Clean up temp tables. */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf, "DROP TABLE %s, %s", diffname, tempname);
	if (SPI_exec(querybuf.data, 0) != SPI_OK_UTILITY)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);

	/* Close SPI context. */
	if (SPI_finish() != SPI_OK_FINISH)
		elog(ERROR, "SPI_finish failed");
}

/*
 * Swap the physical files of the target and transient tables, then rebuild
 * the target's indexes and throw away the transient table.  Security context
 * swapping is handled by the called function, so it is not needed here.
 */
static void
refresh_by_heap_swap(Oid matviewOid, Oid OIDNewHeap, char relpersistence)
{
	finish_heap_swap(matviewOid, OIDNewHeap, false, false, true, true,
					 true,		/* reindex */
					 RecentXmin, ReadNextMultiXactId(), relpersistence);
}

/*
 * Check whether the specified index is usable for refresh_by_match_merge
 *  or refresh_by_direct_modification.
 */
static bool
is_usable_unique_index(Relation indexRel)
{
	Form_pg_index indexStruct = indexRel->rd_index;

	/*
	 * Must be unique, valid, immediate, non-partial, and be defined over
	 * plain user columns (not expressions).
	 */
	if (indexStruct->indisunique &&
		indexStruct->indimmediate &&
		indexStruct->indisvalid &&
		RelationGetIndexPredicate(indexRel) == NIL &&
		indexStruct->indnatts > 0)
	{
		/*
		 * The point of groveling through the index columns individually is to
		 * reject both index expressions and system columns.  Currently,
		 * matviews couldn't have OID columns so there's no way to create an
		 * index on a system column; but maybe someday that wouldn't be true,
		 * so let's be safe.
		 */
		int			numatts = indexStruct->indnatts;
		int			i;

		for (i = 0; i < numatts; i++)
		{
			int			attnum = indexStruct->indkey.values[i];

			if (attnum <= 0)
				return false;
		}
		return true;
	}
	return false;
}

/*
 * This should be used to test whether the backend is in a context where it is
 * OK to allow DML statements to modify materialized views.  We only want to
 * allow that for internal code driven by the materialized view definition,
 * not for arbitrary user-supplied code.
 *
 * While the function names reflect the fact that their main intended use is
 * incremental maintenance of materialized views (in response to changes to
 * the data in referenced relations), they are currently used to allow:
 *
 * - REFRESH CONCURRENTLY without blocking concurrent reads.
 * - REFRESH CONCURRENTLY ... WHERE ... which modifies the matview in place.
 */
bool
MatViewIncrementalMaintenanceIsEnabled(Oid relid)
{
	if (matview_maintenance_depth <= 0)
		return false;

	/*
	 * Only the matview actually being refreshed is exempt.  Without this a
	 * function in a partial refresh's WHERE clause could modify any matview
	 * in the database, since it is evaluated inside this window.
	 */
	return (!OidIsValid(matview_maintenance_relid) ||
			matview_maintenance_relid == relid);
}

/*
 * Enter the window in which the given matview may be modified by DML.
 *
 * We record the matview only at the outermost level, so a nested refresh
 * cannot widen an enclosing one's exemption.
 */
static void
OpenMatViewIncrementalMaintenance(Oid relid)
{
	if (matview_maintenance_depth == 0)
		matview_maintenance_relid = relid;
	matview_maintenance_depth++;
}

static void
CloseMatViewIncrementalMaintenance(void)
{
	matview_maintenance_depth--;
	Assert(matview_maintenance_depth >= 0);
	if (matview_maintenance_depth == 0)
		matview_maintenance_relid = InvalidOid;
}
