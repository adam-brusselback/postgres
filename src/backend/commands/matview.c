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
#include "utils/rel.h"
#include "utils/ruleutils.h"
#include "utils/snapmgr.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"


/*
 * Does the upsert compare a matched row against its replacement before
 * rewriting it?  ON in the code that ships; this is the off-switch, kept only
 * so the two can still be measured against each other on one binary, and
 * deleted with the rest of the branch-local scaffolding.
 *
 * It defaults ON because it pays from one row upward.  Measured against the
 * plain upsert at zero churn, per refresh: +2.2% at scope 1, +15.1% at 25,
 * +29.0% at 100, +44.6% at 1000 and +70.1% at 10,000 (RESULTS.md R45).  Two
 * things that used to argue against it did not survive being re-measured: it
 * is not 18.5% slower at scope 1 -- all three statistics read positive over 23
 * bands -- and it does not need an index over a written column to be worth
 * having, since most of the saving is not writing a row version at all rather
 * than the index maintenance that follows one (X17).
 *
 * What it costs is a comparison bought for nothing when the row really did
 * change, which is why the saving shrinks with churn: R4 puts break-even at
 * 60-70% changed rows, and a scope where nearly everything changed pays a few
 * percent.  Deciding that per refresh needs churn history the cache does not
 * keep yet; the trade as it stands is a win from scope 1 in the common case
 * against a few percent in the least common one.
 */
bool		matview_partial_refresh_optimized = true;

/*
 * query_string for the source plansource.  CreateCachedPlan() requires one and
 * this path has no SQL text to give it -- the source is a Query tree.  It shows
 * up in error contexts, so it says what it is rather than being empty.
 */
#define MATVIEW_SOURCE_QUERY_STRING "REFRESH MATERIALIZED VIEW ... WHERE (source query)"

/*
 * Name the materialised source rows are registered under for the SQL that
 * upserts and prunes.  Both halves read it, and both read the same tuplestore,
 * which is what makes them agree about which rows the view produces (A3).
 */
#define MATVIEW_SOURCE_ENR_NAME	"new_data"

/*
 * Parameters the fused statement takes beyond the predicate's own, carrying
 * the prune guard: whether to skip the prune outright, how many matview rows
 * the pre-lock matched, and how many rows the source produced.  See
 * refresh_by_direct_modification().
 */
#define MATVIEW_PRUNE_GUARD_NARGS	3


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

/*
 * Session-level cache for Partial Refresh plans.
 * We cache the prepared SPI plans for both the row-locking and refresh steps
 * avoiding expensive calls (pg_get_viewdef) and parsing on every execution.
 */
typedef struct MatViewPartialRefreshCache
{
	Oid			matviewOid;		/* Hash Key */

	/* Validation fields */
	Oid			uniqueIndexOid; /* The unique index used for conflict
								 * resolution */
	Node	   *qual;			/* the predicate these plans were built from,
								 * compared with equal().  The tree rather than
								 * its deparsed text: deparsing costs 4.5-5.3 us
								 * (RESULTS.md R14) and the text was only ever
								 * read by the comparison, so keying on the tree
								 * removes it from every refresh that hits.
								 * equal() ignores parse locations, so the same
								 * predicate written at a different offset in the
								 * command still matches */
	int			nargs;			/* number of external parameters */
	Oid		   *argtypes;		/* their types.  Not implied by the qual: a
								 * caller may bind a parameter the predicate
								 * never names, and the generated statement
								 * declares every one of them */

	MemoryContext metacxt;		/* holds qual and argtypes, so the two are freed
								 * together and a node tree can be freed at all */

	bool		optimized;		/* was matview_partial_refresh_optimized set
								 * when these plans were built?  It changes the
								 * generated SQL, so a plan built one way is
								 * wrong for the other */

	/* The cached plans */
	SPIPlanPtr	lockPlan;		/* SELECT ... FOR NO KEY UPDATE */
	SPIPlanPtr	refreshPlan;	/* Fused CTE: Evaluate -> Upsert -> Delete */
	CachedPlanSource *sourcePlan;	/* the view's own query, on the Query-tree
									 * path only.  Rewriting and planning it is
									 * 16.2% of a warm scope-1 refresh; keeping
									 * it saved is what removes that.  NULL on
									 * the text path, where the source is
									 * spliced into the fused statement and
									 * planned as part of it */

	bool		invalid;		/* set by the relcache callback; the entry is
								 * dropped at the next partial refresh, not by
								 * the callback itself -- see
								 * InvalidateMatViewCache */
}			MatViewPartialRefreshCache;

static HTAB *MatViewRefreshCache = NULL;

/*
 * Matview maintenance state.  While a refresh is running we must let its own
 * generated statements modify the matview, but the WHERE clause of a partial
 * refresh can contain arbitrary user functions that run inside the same
 * window.  Remember which matview is being maintained so the exemption cannot
 * be used against any other one.
 */
static int	matview_maintenance_depth = 0;
static Oid	matview_maintenance_relid = InvalidOid;

static void transientrel_startup(DestReceiver *self, int operation, TupleDesc typeinfo);
static bool transientrel_receive(TupleTableSlot *slot, DestReceiver *self);
static void transientrel_shutdown(DestReceiver *self);
static void transientrel_destroy(DestReceiver *self);
static uint64 refresh_matview_datafill(DestReceiver *dest, Query *query,
									   const char *queryString, bool is_create);
static uint64 refresh_by_match_merge(Oid matviewOid, Oid tempOid, Oid relowner,
									 int save_sec_context, char *whereClauseStr,
									 ParamListInfo params);
static uint64 refresh_by_direct_modification(Oid matviewOid, Oid relowner,
											 int save_sec_context,
											 Query *dataQuery, Node *qual,
											 ParamListInfo params);
static void refresh_by_heap_swap(Oid matviewOid, Oid OIDNewHeap, char relpersistence);
static bool is_usable_unique_index(Relation indexRel);
static Oid	matview_pick_arbiter_index(Relation matviewRel);
static void matview_build_upsert_clause(Relation matviewRel, Oid arbiterOid,
										StringInfo conflict_cols,
										StringInfo set_clause,
										bool *has_non_key_cols,
										const char **anti_join_op);
static void OpenMatViewIncrementalMaintenance(Oid relid);
static void CloseMatViewIncrementalMaintenance(void);
static int	matview_execute_spi(const char *command, ParamListInfo params, bool read_only);
static int	matview_execute_spi_plan(SPIPlanPtr plan, ParamListInfo params,
									 Snapshot snapshot, bool read_only);
static char *get_matview_view_query(Oid matviewOid);
static void InitMatViewCache(void);
static void InvalidateMatViewCache(Datum arg, Oid relid);
static void matview_cache_sweep(void);
static CachedPlanSource *matview_build_source_plansource(Query *sourceQuery);
static bool refresh_where_clause_is_leakproof(Node *qual);
static bool refresh_qual_is_key_only(Node *qual, int nkeyatts,
									 const int16 *keyattnums);
static ParamListInfo matview_prune_guard_params(ParamListInfo params,
												bool serialized,
												bool qual_key_only,
												int64 n_locked,
												int64 n_source);
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
	Form_pg_class classForm;

	Assert(relation->rd_rel->relkind == RELKIND_MATVIEW);

	/*
	 * If the state matches, do nothing. This prevents cache invalidation
	 * storms when doing frequent partial refreshes via triggers.
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

	classForm = (Form_pg_class) GETSTRUCT(tuple);

	if (classForm->relispopulated != newstate)
	{
		classForm->relispopulated = newstate;
		CatalogTupleUpdate(pgrel, &tuple->t_self, tuple);
	}

	heap_freetuple(tuple);
	table_close(pgrel, RowExclusiveLock);

	/*
	 * Advance command counter to make the updated pg_class row locally
	 * visible.
	 */
	CommandCounterIncrement();
}

/*
 * Hook to allow parameters (e.g. $1) in the WHERE clause.
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
 * Transform the WHERE clause for REFRESH MATERIALIZED VIEW.
 */
/*
 * check_functions_in_node callback: is this function leakproof?
 */
static bool
leakproof_checker(Oid func_id, void *context)
{
	return !get_func_leakproof(func_id);
}

/*
 * Is this node something a non-owner may have evaluated with the matview
 * owner's privileges?
 *
 * This is an allowlist, and it has to be.  The previous version of this walker
 * flagged known-bad functions and let through every node type it did not
 * recognise, which meant a caller holding only MAINTAIN could read any table
 * the owner could:
 *
 *   REFRESH MATERIALIZED VIEW CONCURRENTLY mv WHERE id = (SELECT val FROM secret)
 *
 * The subquery runs as the owner, and the caller then reads back which row the
 * refresh touched -- an oracle that yields the value a row at a time.  Every
 * sublink spelling reached it (scalar, EXISTS, ANY, one buried in a CASE), and
 * so did a cast to a domain whose CHECK constraint calls a non-leakproof
 * function, because that function is not in the expression tree at all.
 *
 * Leakproofness is the wrong question for those nodes rather than a question
 * answered wrongly: it constrains what a FUNCTION may reveal about its
 * arguments, and says nothing about which RELATIONS an expression may read.  So
 * anything that can reach a relation, or reach a function that is not visible
 * here, is refused outright and the caller must own the matview.
 *
 * Modelled on contain_leaked_vars_walker() in clauses.c, which solves the same
 * problem for row-level security and defaults to unsafe for the same reason.
 */
static bool
contains_non_leakproof_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;

	switch (nodeTag(node))
	{
		/*
		 * These cannot call a function or read a relation themselves, though
		 * something below them might, so keep walking.
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

		/* These call functions; every one of them must be leakproof. */
		case T_FuncExpr:
		case T_OpExpr:
		case T_DistinctExpr:
		case T_NullIfExpr:
		case T_ScalarArrayOpExpr:
		case T_CoerceViaIO:
		case T_ArrayCoerceExpr:
		case T_RowCompareExpr:
			if (check_functions_in_node(node, leakproof_checker, context))
				return true;
			break;

		/*
		 * Everything else -- notably T_SubLink, which reads relations, and
		 * T_CoerceToDomain, whose CHECK constraints are not part of this tree.
		 */
		default:
			return true;
	}

	return expression_tree_walker(node, contains_non_leakproof_walker, context);
}

/*
 * True if the expression is one a non-owner may have evaluated as the owner.
 */
static bool
refresh_where_clause_is_leakproof(Node *qual)
{
	return !contains_non_leakproof_walker(qual, NULL);
}

static Node *
transformRefreshWhereClause(Oid relid, Node *whereClause, ParamListInfo params,
							Oid callerId)
{
	ParseState *pstate = make_parsestate(NULL);
	Relation	rel = table_open(relid, NoLock);
	ParseNamespaceItem *nsitem;
	Node	   *result;

	pstate->p_paramref_hook = refresh_paramref_hook;
	pstate->p_ref_hook_state = (void *) params;

	nsitem = addRangeTableEntryForRelation(pstate, rel, AccessShareLock, NULL, false, true);
	addNSItemToQuery(pstate, nsitem, false, true, true);

	result = transformExpr(pstate, whereClause, EXPR_KIND_WHERE);
	result = coerce_to_boolean(pstate, result, "WHERE");

	/*
	 * Finish the expression off the way transformStmt() would.  For a long
	 * time the only thing done with this tree was to deparse it, and a deparse
	 * does not look at collations, so an unresolved one was invisible: the
	 * text went back through the parser, which assigned them properly the
	 * second time round.  Anything that executes the tree directly needs them
	 * assigned here, or a predicate as ordinary as "tag = 'hot'" fails with
	 * "could not determine which collation to use".
	 */
	assign_expr_collations(pstate, result);

	/*
	 * The predicate is evaluated with the matview owner's privileges, so a
	 * caller who merely holds MAINTAIN could otherwise reach objects it has no
	 * rights on.  A leakproof predicate cannot leak the owner's data nor do
	 * anything the caller could not, so allow that for anyone who may refresh;
	 * anything else requires ownership.
	 */
	if (!refresh_where_clause_is_leakproof(result) &&
		!object_ownercheck(RelationRelationId, relid, callerId))
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_PRIVILEGE),
				 errmsg("permission denied to use a non-leakproof expression in the WHERE clause of REFRESH MATERIALIZED VIEW"),
				 errdetail("The expression is evaluated with the privileges of the owner of materialized view \"%s\".",
						   RelationGetRelationName(rel)),
				 errhint("Only the owner may use a WHERE clause containing functions that are not leakproof.")));

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

static char *
deparseRefreshWhereClause(Oid relid, Node *whereClause)
{
	return TextDatumGetCString(DirectFunctionCall2(pg_get_expr,
												   CStringGetTextDatum(nodeToString(whereClause)),
												   ObjectIdGetDatum(relid)));
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
 * The deparsed clause renders a Param as "$n" and nothing else -- no type, no
 * typmod (B3) -- so the type has to travel beside it in the argtypes array
 * SPI_prepare is given.  A constant with no type to declare therefore cannot
 * make the trip, and is left as a literal.
 */
static bool
refresh_const_is_paramizable(Const *con)
{
	/*
	 * UNKNOWNOID is the case this exists for.  Handing InvalidOid to
	 * SPI_prepare does not mean "unknown", it means "resolve it from context",
	 * and the context is the generated statement rather than the predicate the
	 * caller wrote.  Rare -- parse analysis resolves almost everything -- and
	 * one missed cache hit is a far better outcome than a parameter that binds
	 * to a different type than the literal had.
	 */
	if (!OidIsValid(con->consttype) || con->consttype == UNKNOWNOID)
		return false;

	/* A pseudo-type cannot be the declared type of a parameter either. */
	if (get_typtype(con->consttype) == TYPTYPE_PSEUDO)
		return false;

	return true;
}

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

	/*
	 * expression_tree_mutator() hands back a sub-Query untouched, so the
	 * subselect of a SubLink keeps its constants and a predicate written as a
	 * subquery still misses the cache when they vary.  That is a missed
	 * optimisation and not a wrong answer: only the matview's owner may write
	 * such a predicate at all (the leakproof check above), and reaching into a
	 * Query needs query_tree_mutator and a decision about what to do with the
	 * range table, neither of which this is the place for.
	 */
	return expression_tree_mutator(node, paramize_refresh_consts_mutator, context);
}

/*
 * Turn the predicate's constants into parameters, and extend the caller's
 * ParamListInfo with their values.
 *
 * The plan cache is keyed on the deparsed predicate (matview.c's cache entry,
 * and SPI's own plancache entries under it), so "WHERE id = 1" and
 * "WHERE id = 2" are two different statements and a caller refreshing one row
 * at a time misses on every call.  A caller who binds the value instead hits,
 * because pg_get_expr renders a Param as "$1" whatever it holds.  Both are
 * ordinary things to write and they measured 8x apart (RESULTS.md R15).
 *
 * So write the second one on the first one's behalf: replace each Const with a
 * Param of the same type, typmod and collation, and hand the value over in
 * `params`.  The predicate now deparses to a shape rather than a value, the
 * key is stable across values, and everything downstream -- the two SPI plans,
 * the source plansource, and the match/merge path's generated INSERT -- takes
 * the values through the parameter list it already had for a caller who bound
 * them.
 *
 * PARAM_FLAG_CONST is what keeps a custom plan as good as the literal plan it
 * replaces: it is the flag eval_const_expressions() looks for before folding
 * an external parameter back into the constant it came from.  Without it a
 * custom plan would be planned as blind as a generic one, which is the whole
 * cost and none of the benefit.  SPI sets the same flag on the parameters it
 * builds (_SPI_convert_params), so this matches what the path already did for
 * a caller-supplied parameter.
 *
 * Which plan gets used is then plancache's usual decision.  It is not this
 * function's to make and should not be forced: forcing generic was measured
 * across 94 comparisons at 21.7% slower net (RESULTS.md R1), and the cases
 * where a generic plan is wrong -- an array whose selectivity cannot be
 * estimated without seeing it -- are exactly the ones choose_custom_plan()
 * already gets right.
 *
 * Returns the rewritten clause, and replaces *params.  Both are unchanged when
 * there was nothing to do.
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

	/*
	 * A ParamListInfo that supplies its values through hooks may leave the
	 * array unpopulated, and its hooks would not survive being copied into a
	 * longer list of a different shape.  Nothing in the tree reaches REFRESH
	 * that way -- the extended protocol and SPI both hand over a plain, filled
	 * array -- but a wrong guess about a rare path is how a rare path becomes a
	 * wrong answer, so decline it and leave the constants alone.  The refresh
	 * is then exactly as fast as it was before, which is the right way to fail.
	 */
	if (base != NULL && (base->paramFetch != NULL || base->paramCompile != NULL))
		return qual;

	ctx.nextparam = base ? base->numParams : 0;
	ctx.consts = NIL;

	newqual = paramize_refresh_consts_mutator(qual, &ctx);

	/* A predicate with no constants -- "WHERE id = $1" already, say. */
	if (ctx.consts == NIL)
		return qual;

	newparams = makeParamList(ctx.nextparam);

	/*
	 * The caller's parameters keep their numbers: the predicate the caller
	 * wrote may name any of them, and the new ones are appended after.
	 */
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
		prm->pflags = PARAM_FLAG_CONST;
		prm->ptype = con->consttype;
	}
	Assert(i == ctx.nextparam);

	*params = newparams;
	return newqual;
}

/*
 * Helper to execute SPI commands with optional parameters.
 */
static int
matview_execute_spi(const char *command, ParamListInfo params, bool read_only)
{
	if (params && params->numParams > 0)
	{
		Oid		   *argtypes;
		Datum	   *argvalues;
		char	   *nulls;
		int			i;
		int			res;

		argtypes = (Oid *) palloc(params->numParams * sizeof(Oid));
		argvalues = (Datum *) palloc(params->numParams * sizeof(Datum));
		nulls = (char *) palloc(params->numParams * sizeof(char));

		for (i = 0; i < params->numParams; i++)
		{
			ParamExternData *prm = &params->params[i];

			argtypes[i] = prm->ptype;
			argvalues[i] = prm->value;
			nulls[i] = prm->isnull ? 'n' : ' ';
		}

		res = SPI_execute_with_args(command, params->numParams, argtypes,
									argvalues, nulls, read_only, 0);

		pfree(argtypes);
		pfree(argvalues);
		pfree(nulls);

		return res;
	}
	else
	{
		return SPI_exec(command, 0);
	}
}

/*
 * Helper to execute Prepared SPI Plans with optional parameters.
 *
 * Pass InvalidSnapshot to let SPI take its own snapshot, which is what a
 * statement standing on its own wants.  Pass one to run the statement under a
 * snapshot the caller has already used for something else that has to agree
 * with it.
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
 * This is the entry point for REFRESH MATERIALIZED VIEW.  It handles:
 *
 * - WITH NO DATA: effectively like a TRUNCATE.
 * - CONCURRENTLY: diff-based refresh allowing concurrent reads.
 * - WHERE clause: partial refresh of a subset of rows.
 * - Default: full rebuild via heap swap.
 *
 * The statement node's skipData field shows whether WITH NO DATA was used.
 */
ObjectAddress
ExecRefreshMatView(RefreshMatViewStmt *stmt, const char *queryString,
				   ParamListInfo params, QueryCompletion *qc)
{
	Oid			matviewOid;
	LOCKMODE	lockmode;

	/* Determine strength of lock needed. */
	/*
	 * Both spellings of a partial refresh run the same algorithm; what they
	 * choose is how much concurrency to permit, and the lock is the mechanism.
	 *
	 * CONCURRENTLY takes RowExclusiveLock, so refreshes over disjoint scopes
	 * run in parallel -- measured at 3.3-5.9x on four clients -- and overlapping
	 * ones are ordered by the row locks the refresh takes over its scope.
	 *
	 * The bare form takes ExclusiveLock, which makes a second concurrent
	 * refresh impossible.  That is not merely the conservative posture it looks
	 * like: it is a precondition.  The row-locking SELECT and the two ORDER BY
	 * clauses exist only to make overlapping refreshes safe against each other
	 * -- lost updates and lock-order deadlocks respectively -- so once the lock
	 * manager guarantees there is no second refresh, all three become
	 * removable.  This keeps CONCURRENTLY the more permissive spelling, as it
	 * is for a full refresh, while giving the bare form something to buy with
	 * the concurrency it gives up.
	 *
	 * Note the asymmetry with a user-declared "I have no overlapping
	 * refreshes": that would be an unverifiable promise whose violation is
	 * silent lost updates.  This is enforcement, not a declaration, which is
	 * what makes the specialisations sound.
	 */
	if (stmt->whereClause)
		lockmode = stmt->concurrent ? RowExclusiveLock : ExclusiveLock;
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
 * 1. Partial non-concurrent (WHERE clause, no CONCURRENTLY):
 * Directly modifies the matview in-place using a two-step approach
 * (SELECT ... FOR NO KEY UPDATE followed by a CTE upsert/delete).
 * Uses RowExclusiveLock, allowing concurrent reads and concurrent writes
 * to non-overlapping rows. Overlapping writes are serialized by row locks.
 *
 * 2. Concurrent (CONCURRENTLY, with or without WHERE clause):
 * Creates a temporary table with new data, computes a diff against
 * the existing matview, and applies changes. Uses ExclusiveLock,
 * allowing concurrent reads throughout the operation but blocking all
 * concurrent writes.
 *
 * 3. Full rebuild (default, no WHERE, no CONCURRENTLY):
 * Creates a new heap, populates it, and swaps relfilenumbers.
 * Uses AccessExclusiveLock, blocking all concurrent access.
 * The OID of the original materialized view is preserved, so we
 * do not lose GRANT nor references to this materialized view.
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
	char	   *qual_str = NULL;
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

	/* Check that CONCURRENTLY is not specified if not populated. */
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
		 * Every consumer of the predicate reads it from here down, so this is
		 * the one place the substitution has to happen: the source query
		 * executes this tree, the plan cache keys on it, and both generated
		 * statements are deparsed from it.  Rewriting it for one and not the
		 * others would leave them disagreeing about which rows are selected.
		 */
		qual = parameterizeRefreshWhereClause(qual, &params);
	}

	/*
	 * The deparse is deliberately NOT done here.  It costs 4.5-5.3 us
	 * (RESULTS.md R14) and only two consumers need it: the match/merge branch
	 * below, which interpolates it into three statements, and
	 * refresh_by_direct_modification(), which needs it only when it is building
	 * plans.  Doing it up front charged every refresh for something a warm one
	 * throws away, so each branch does its own.
	 */

	/*
	 * Check that there is a unique index with no WHERE clause on one or more
	 * columns of the materialized view if CONCURRENTLY is specified.
	 *
	 * Count the unique indexes as well, because more than one changes which
	 * algorithm a partial refresh can use.  Direct modification applies its
	 * changes with ON CONFLICT against a single arbiter index, one row at a
	 * time, and every row it writes must satisfy every unique index the moment
	 * it is written.  A change that needs a row deleted before another can be
	 * inserted -- two rows swapping their values on a unique index that is not
	 * the arbiter -- cannot be expressed that way, and no choice of arbiter
	 * helps: whichever index arbitrates, the swap collides on the other one.
	 * Diff/merge deletes before it inserts and has no such limit.
	 *
	 * With exactly one unique index the collision is impossible rather than
	 * unlikely, so the fast path is provably safe there, which is the
	 * overwhelming majority of matviews.  Partial and expression unique indexes
	 * are counted even though they cannot arbitrate, because a write still has
	 * to satisfy them.
	 */
	if (concurrent || qual)
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

			/* Anything unique and enforced constrains what the upsert writes. */
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
	 * STRATEGY 1: PARTIAL REFRESH, either spelling.
	 *
	 * A predicate always selects direct modification.  Diff/merge used to take
	 * the bare form, and measurement removed the reason: swept from 10% to 90%
	 * of the matview, on a per-key matview and on a 200-rows-per-key one,
	 * direct modification won at every point by 24-52%, and the margin widened
	 * with scope rather than closing.  There is no crossover to protect, so
	 * there is no second algorithm to keep on this path.
	 *
	 * The two spellings still differ, but now in lock level rather than
	 * algorithm -- see ExecRefreshMatView().
	 *
	 * The exception is a matview carrying more than one unique index, where
	 * the upsert cannot express a change that needs a delete before an insert;
	 * those fall through to diff/merge.  See the index scan above.
	 *
	 * (WITH NO DATA is rejected together with a WHERE clause long before here,
	 * so !skipData is belt and braces.)
	 */
	if (qual && !skipData && nUniqueIndexes <= 1)
	{
		processed = refresh_by_direct_modification(matviewOid, relowner,
												   save_sec_context, dataQuery,
												   qual, params);
	}

	/*
	 * STRATEGY 2: FULL CONCURRENT REFRESH, or a partial one on a matview with
	 * more than one unique index.
	 */
	else if (concurrent || qual)
	{
		Oid			tableSpace;
		char		relpersistence;
		Oid			OIDNewHeap;
		int			old_depth = matview_maintenance_depth;
		Oid			old_relid = matview_maintenance_relid;

		tableSpace = GetDefaultTablespace(RELPERSISTENCE_TEMP, false);
		relpersistence = RELPERSISTENCE_TEMP;

		/*
		 * This path builds three statements by interpolation and caches
		 * nothing, so it needs the predicate as text every time it runs.
		 */
		if (qual)
			qual_str = deparseRefreshWhereClause(matviewOid, qual);

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
			if (qual_str)
			{
				StringInfoData buf;
				char	   *view_sql = get_matview_view_query(matviewOid);
				char	   *transient_name;
				Relation	transientRel = table_open(OIDNewHeap, NoLock);

				transient_name = quote_qualified_identifier(get_namespace_name(RelationGetNamespace(transientRel)),
															RelationGetRelationName(transientRel));
				table_close(transientRel, NoLock);

				/*
				 * Init buffer before SPI connection to avoid double free
				 * issues on context destroy
				 */
				initStringInfo(&buf);
				appendStringInfo(&buf, "INSERT INTO %s SELECT * FROM (%s) _mv_q WHERE %s",
								 transient_name, view_sql, qual_str);

				SPI_connect();
				if (matview_execute_spi(buf.data, params, false) != SPI_OK_INSERT)
					elog(ERROR, "SPI_exec failed: %s", buf.data);
				processed = SPI_processed;
				SPI_finish();
				pfree(view_sql);
				pfree(transient_name);
				pfree(buf.data);
			}
			else
			{
				DestReceiver *dest;

				dest = CreateTransientRelDestReceiver(OIDNewHeap);
				processed = refresh_matview_datafill(dest, dataQuery, queryString, is_create);
			}
		}

		PG_TRY();
		{
			uint64		applied;

			applied = refresh_by_match_merge(matviewOid, OIDNewHeap, relowner,
											 save_sec_context, qual_str, params);
			if (qual_str)
				processed = applied;
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
 * get_matview_view_query
 *
 * Retrieve the SQL definition of a materialized view's underlying query.
 * Returns the query text with trailing semicolons and whitespace removed.
 */
static char *
get_matview_view_query(Oid matviewOid)
{
	char	   *view_sql;

	view_sql = TextDatumGetCString(DirectFunctionCall2(pg_get_viewdef,
													   ObjectIdGetDatum(matviewOid),
													   BoolGetDatum(false)));
	if (view_sql)
	{
		int			len = strlen(view_sql);

		while (len > 0 && (view_sql[len - 1] == ';' || isspace((unsigned char) view_sql[len - 1])))
			view_sql[--len] = '\0';
	}
	return view_sql;
}

/*
 * Do the cached plans' argument types still match what the caller is passing?
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
 * Relcache invalidation callback.
 *
 * The cached SQL names its relations, and a saved plan is re-analyzed from its
 * raw parse tree when invalidated -- so after a rename the text resolves to
 * whatever now holds that name.  Mark cached plans stale whenever anything they
 * could refer to changes.  relid == InvalidOid means "everything".
 *
 * Marking is all this may do.  Invalidation callbacks run at arbitrary points:
 * inside CommandCounterIncrement(), while acquiring a lock, and during
 * transaction abort -- including from within the very refresh that is executing
 * these plans, because that refresh writes to the matview and takes locks.
 * Freeing a plan there would pull a CachedPlan out from under the executor, and
 * removing the entry would leave refresh_by_direct_modification() holding a
 * pointer to memory dynahash has already put back on its freelist.  Throwing an
 * error is not allowed here either, since abort processing has nowhere to put
 * it.  matview_cache_sweep() does the freeing instead, at a point where nothing
 * can be using the plans.
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
 * Free the plans of every entry the callback marked stale, and drop the entries.
 *
 * Called at the start of a partial refresh, before any plan is taken or
 * executed, which is the property that makes the frees safe.  Sweeping every
 * entry rather than just this refresh's own is what reclaims the plans of
 * matviews that have since been dropped.
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
		if (entry->refreshPlan)
			SPI_freeplan(entry->refreshPlan);
		if (entry->sourcePlan)
			DropCachedPlan(entry->sourcePlan);
		if (entry->metacxt)
			MemoryContextDelete(entry->metacxt);

		/* dynahash permits removing the just-returned element mid-scan */
		if (hash_search(MatViewRefreshCache, &entry->matviewOid,
						HASH_REMOVE, NULL) == NULL)
			elog(ERROR, "hash table corrupted");
	}
}

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
 * matview_build_source_query
 *
 * Build the Query producing the rows the matview should hold inside the scope
 * of the predicate: the view's own query, filtered by the predicate, ordered
 * by the arbiter index's key columns.
 *
 * The predicate filters the OUTPUT of the view query, so the view query goes
 * into a subquery RTE and the predicate becomes the outer WHERE.  Attaching it
 * to dataQuery with AddQual() instead -- which is the obvious thing to reach
 * for, since the rewriter pushes quals into views that way -- would put it in
 * the view's own WHERE clause, evaluated before grouping, windowing and
 * DISTINCT.  That is a different answer for every matview that aggregates, and
 * for one over a window function it is not even a well-formed question.  The
 * text implementation wrapped the view in a subselect for the same reason.
 *
 * The predicate's Vars were resolved against the matview relation, so they
 * carry matview attribute numbers.  A matview's columns are its view query's
 * non-junk target entries in order, and a matview cannot have a dropped column
 * (ALTER MATERIALIZED VIEW ... DROP COLUMN is rejected), so those attribute
 * numbers already address the subquery's output columns.  Only the RTE they
 * point at has to be the right one, which is why the subquery is placed at
 * varno 1 like the matview it replaces.
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
										   false,	/* not LATERAL */
										   true);	/* in FROM clause */
	addNSItemToQuery(pstate, nsitem, true, false, true);

	/* The predicate's Vars say varno 1; this has to be what they mean. */
	Assert(nsitem->p_rtindex == 1);

	sourceQuery->commandType = CMD_SELECT;
	sourceQuery->canSetTag = true;

	/* SELECT *, which for this RTE is exactly the matview's columns. */
	sourceQuery->targetList = expandNSItemAttrs(pstate, nsitem, 0, false, -1);

	/*
	 * Order by the arbiter key.  Two overlapping refreshes have to insert the
	 * rows they both produce in the same order or they deadlock on each
	 * other's speculative insertions (A5/P3); the rows leave here in that
	 * order and stay in it, because what reads them back is a plain scan of
	 * the tuplestore they were written to.
	 */
	for (i = 0; i < nkeyatts; i++)
	{
		int			attnum = keyattnums[i];
		TargetEntry *tle = list_nth_node(TargetEntry, sourceQuery->targetList,
										 attnum - 1);
		SortBy	   *sortby = makeNode(SortBy);

		/* is_usable_unique_index() rejects expression and system columns */
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

	/*
	 * The predicate was analysed against a different ParseState, so this one
	 * has not seen whatever is in it.  Aggregates and window functions are
	 * rejected outright by transformRefreshWhereClause() and by
	 * EXPR_KIND_WHERE respectively, but a sub-SELECT is allowed and the
	 * rewriter must be told it is there.
	 */
	sourceQuery->hasSubLinks = checkExprHasSubLink(sourceQual);

	free_parsestate(pstate);

	return sourceQuery;
}

/*
 * matview_materialize_source
 *
 * Run the source query under the given snapshot and collect its rows into
 * tupstore.  Returns the number of rows collected.
 *
 * This is the same sequence the full refresh uses in
 * refresh_matview_datafill(); the difference is only where the rows go.
 */
/*
 * matview_build_source_plansource
 *
 * Wrap the source query in a CachedPlanSource, rewritten and completed but not
 * yet planned and not yet saved.  The caller owns it.
 *
 * CreateCachedPlanForQuery() is the entry point for a query that has already
 * been through parse analysis -- "used only for new-style SQL functions, where
 * we have a Query from the function's prosqlbody, but no source text".  That is
 * this case exactly, and functions.c is the pattern followed here.  Going
 * through plancache rather than stashing a PlannedStmt is what makes the plan
 * self-validating: plancache already registers eight callbacks, one relcache
 * and seven syscache, and decides staleness itself.
 *
 * It copies the tree into its own context first, so what it holds is the
 * *unrewritten* query -- which is what plancache wants, because on revalidation
 * it re-acquires the rewrite locks and re-rewrites from that copy itself.  So
 * the rewrite below must come after this call, and scribbles only on the
 * caller's tree, which is rebuilt on every cache miss anyway.
 */
static CachedPlanSource *
matview_build_source_plansource(Query *sourceQuery)
{
	CachedPlanSource *plansource;
	List	   *querytree_list;

	plansource = CreateCachedPlanForQuery(sourceQuery,
										  MATVIEW_SOURCE_QUERY_STRING,
										  CreateCommandTag((Node *) sourceQuery));

	AcquireRewriteLocks(sourceQuery, true, false);

	/*
	 * pg_rewrite_query() rather than QueryRewrite(): the same rewrite with the
	 * standard debug/stats wrapper around it, which is what plancache's own
	 * revalidation path calls.  Named because it is not quite a no-op -- it
	 * adds log_parser_stats reporting and the DEBUG dump of the result.
	 */
	querytree_list = pg_rewrite_query(sourceQuery);

	/* A SELECT should never rewrite to more or less than one SELECT. */
	if (list_length(querytree_list) != 1)
		elog(ERROR, "unexpected rewrite result for REFRESH MATERIALIZED VIEW");

	/*
	 * CURSOR_OPT_PARALLEL_OK has to reach the planner through here now, since
	 * this is what CompleteCachedPlan hands to pg_plan_queries.  Dropping it
	 * would silently disable parallel source evaluation: invisible at scope 1,
	 * material where the source scan is large.
	 */
	CompleteCachedPlan(plansource,
					   querytree_list,
					   NULL,	/* copy into the plansource's own context */
					   NULL,
					   0,
					   NULL,
					   NULL,
					   CURSOR_OPT_PARALLEL_OK,
					   false);

	return plansource;
}

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

	/*
	 * A saved plansource can and should be handed a ResourceOwner: it is what
	 * releases the plan's refcount if the executor throws between here and the
	 * ReleaseCachedPlan below.  An unsaved one cannot -- GetCachedPlan()
	 * rejects it outright -- so a nested refresh, whose plansource is private
	 * and dropped when it returns, passes NULL and accepts that its refcount
	 * dies with the plansource.
	 */
	owner = plansource->is_saved ? CurrentResourceOwner : NULL;

	generic_before = plansource->gplan;
	custom_before = plansource->num_custom_plans;

	cplan = GetCachedPlan(plansource, params, owner, NULL);

	/*
	 * Did plancache have to *build* a plan, or hand back one it already had?
	 *
	 * Not num_generic_plans, which is the obvious choice and is wrong: it is
	 * incremented in the `else` arm of GetCachedPlan's custom-or-not branch, so
	 * it counts every call that *returns* a generic plan, reused or freshly
	 * built.  A probe reading it can never see a hit -- the mirror image of a
	 * test that cannot fail.
	 *
	 * A new generic plan replaces plansource->gplan, so the pointer moving is
	 * the build.  num_custom_plans is a genuine build counter -- a custom plan
	 * is built every time by definition -- and covers the bound-parameter cell,
	 * where the first five plans are custom.
	 */
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
 * Working state for refresh_qual_is_key_only().
 */
typedef struct RefreshKeyOnlyContext
{
	int			nkeyatts;
	const int16 *keyattnums;
} RefreshKeyOnlyContext;

static bool
refresh_qual_key_only_walker(Node *node, void *context)
{
	RefreshKeyOnlyContext *ctx = (RefreshKeyOnlyContext *) context;

	if (node == NULL)
		return false;

	if (IsA(node, Var))
	{
		Var		   *var = (Var *) node;
		int			i;

		/*
		 * The predicate was analysed against the matview alone, so every Var in
		 * it is varno 1 at level 0.  Anything else means this walker is looking
		 * at a tree it does not understand, and the answer has to be no.
		 */
		if (var->varlevelsup != 0 || var->varno != 1 || var->varattno <= 0)
			return true;

		for (i = 0; i < ctx->nkeyatts; i++)
		{
			if (ctx->keyattnums[i] == var->varattno)
				return false;
		}

		/* A column of the matview that is not part of the arbiter key. */
		return true;
	}

	/*
	 * A sub-SELECT reads relations this walker has not looked at, and one
	 * correlated on a non-key column would decide the qual from something other
	 * than the key while showing no Var of its own at this level.  Decline.
	 */
	if (IsA(node, SubLink) || IsA(node, SubPlan) || IsA(node, AlternativeSubPlan))
		return true;

	return expression_tree_walker(node, refresh_qual_key_only_walker, context);
}

/*
 * refresh_qual_is_key_only
 *
 * True when the predicate reads nothing but the arbiter index's key columns.
 *
 * This is the gate on the prune elision in refresh_by_direct_modification(),
 * and it is the whole of what makes that elision sound.  Without it the
 * accounting the elision rests on -- every source row is either an existing
 * matview row the pre-lock counted or one the upsert has just inserted -- has a
 * hole: a matview row can carry the same key as a source row and not satisfy
 * the predicate, in which case the upsert matches it (ON CONFLICT arbitrates on
 * the key, not on the predicate) while the pre-lock never saw it.  The source
 * row is then neither locked nor inserted, and a genuinely orphaned row
 * elsewhere in the scope cancels the discrepancy exactly.  SPECIALIZE.md 3b has
 * the two-row case; it leaves the matview holding a row its own definition does
 * not produce, and reports success.
 *
 * When the qual reads only key columns that cannot happen: two rows with the
 * same key agree on the qual, so a matview row the upsert can conflict with is
 * necessarily a matview row the pre-lock locked.
 *
 * Volatile functions are rejected far upstream (transformRefreshWhereClause),
 * which matters here for the same reason: they would let two rows with the same
 * key disagree.
 */
static bool
refresh_qual_is_key_only(Node *qual, int nkeyatts, const int16 *keyattnums)
{
	RefreshKeyOnlyContext ctx;

	ctx.nkeyatts = nkeyatts;
	ctx.keyattnums = keyattnums;

	return !refresh_qual_key_only_walker(qual, &ctx);
}

/*
 * matview_prune_guard_params
 *
 * The predicate's parameters, followed by the three the fused statement's
 * prune guard reads.  Returned as a fresh list rather than by extending the
 * caller's: `params` is also what the pre-lock and the source query are
 * executed with, and neither of those declares these three.
 *
 * The guard is two sound rules, and the SQL expresses both as one expression
 * so that which one fires is decided by the values:
 *
 *   n_locked == 0            the matview holds nothing in scope, so the prune's
 *                            DELETE has nothing to match -- the upsert's own
 *                            inserts are not visible to it.  Passed as the
 *                            boolean.
 *
 *   n_locked + n_inserted    every source row is accounted for by a matview row
 *     == n_source            that was already in scope or by one just inserted,
 *                            so nothing in scope is orphaned.  Sound only when
 *                            the predicate reads key columns alone; when it
 *                            does not, -1 goes in as n_source, which no
 *                            non-negative left-hand side can equal.
 *
 * The second rule is unsound without that gate, and silently so: see
 * refresh_qual_is_key_only() and SPECIALIZE.md 3b.
 *
 * BOTH rules additionally need `serialized`, and that one is not about the
 * predicate at all.  n_locked is measured by the pre-lock, under an earlier
 * snapshot than the DELETE it stands in for -- the snapshot has to be taken
 * after the lock, or a refresh that queued behind another would evaluate its
 * source from before that one committed and write the stale values back over it
 * (SPECIALIZE.md 3e; fuzz.sh serial mode catches it as M3 and M6).  The lock
 * stops the rows it matched from changing; it does not stop new ones appearing.
 * A refresh over a key the matview does not hold yet locks nothing, so it does
 * not queue behind us and can commit a row into our scope inside that window --
 * a row neither count has seen, and the accounting then balances while that row
 * is orphaned.  Demonstrated, not argued: matview-where-prune-elide.spec leaves
 * a stale row without this condition and is green with it.
 *
 * ExclusiveLock is what closes it, because it is the level at which no other
 * session can write this matview at all: it conflicts with the
 * RowExclusiveLock a CONCURRENTLY partial refresh takes and with another bare
 * refresh's ExclusiveLock, while still admitting readers.  So the saving is
 * available exactly where the lock makes it safe -- which is SPECIALIZE.md 4's
 * argument for choosing that level deliberately, cashed in a second time.
 * Asked of the lock manager rather than derived from the statement's spelling:
 * the precondition is "nobody else can write this", and that is a fact about
 * the lock actually held.
 */
static ParamListInfo
matview_prune_guard_params(ParamListInfo params, bool serialized,
						   bool qual_key_only, int64 n_locked, int64 n_source)
{
	int			npred = params ? params->numParams : 0;
	ParamListInfo guarded = makeParamList(npred + MATVIEW_PRUNE_GUARD_NARGS);
	ParamExternData *prm;
	int			i;

	for (i = 0; i < npred; i++)
		guarded->params[i] = params->params[i];

	prm = &guarded->params[npred];
	prm->value = BoolGetDatum(serialized && n_locked == 0);
	prm->isnull = false;
	prm->pflags = PARAM_FLAG_CONST;
	prm->ptype = BOOLOID;

	prm = &guarded->params[npred + 1];
	prm->value = Int64GetDatum(n_locked);
	prm->isnull = false;
	prm->pflags = PARAM_FLAG_CONST;
	prm->ptype = INT8OID;

	prm = &guarded->params[npred + 2];
	prm->value = Int64GetDatum((serialized && qual_key_only) ? n_source : -1);
	prm->isnull = false;
	prm->pflags = PARAM_FLAG_CONST;
	prm->ptype = INT8OID;

	return guarded;
}

/*
 * refresh_by_direct_modification
 *
 * This modifies the materialized view in-place without creating a temporary
 * heap or swapping relfilenumbers.  It requires a usable unique index on the
 * matview for conflict resolution.
 *
 * Concurrency is handled in two steps, each executed as a separate SPI
 * statement:
 *
 * 1. Lock existing rows matching the WHERE clause via SELECT ... FOR NO KEY
 * UPDATE.
 *    This serializes concurrent partial refreshes that touch overlapping
 *    rows while allowing non-overlapping refreshes to proceed in parallel.
 *
 * 2. Execute a single CTE that evaluates the underlying query, upserts
 *    the results into the matview, and deletes rows that no longer match
 *    the predicate (via anti-join against the fresh query output).
 *
 * Step 2's source rows are the view evaluated from its Query tree into a
 * tuplestore, registered as an ephemeral named relation and read by the fused
 * statement.  The view's SQL text does not appear in the generated statement at
 * all, and with it goes every hazard that came from re-parsing deparsed SQL in
 * a different naming environment than the one it was written in.  An earlier
 * revision could instead inline the view as a MATERIALIZED CTE, selected by a
 * GUC so the two could be compared at run time; that path is gone.
 *
 * The prune carries a guard, so that the scan and the anti-join behind it are
 * skipped when they provably cannot delete anything -- the DELETE gets a
 * One-Time Filter and never reads the scope at all.  Two counts decide it, both
 * of them facts about this refresh rather than promises about the matview: how
 * many rows the pre-lock matched, and how many rows the source produced.  The
 * decision has to be made inside the statement, because how many rows the
 * upsert inserted is not known until it has run and the upsert and the prune
 * are one statement; a sub-select over the upsert CTE both supplies the count
 * and, by depending on it, orders the two.  See matview_prune_guard_params()
 * for the rules and refresh_qual_is_key_only() for what makes the second sound.
 *
 * Both halves of the fused statement then read one physically materialised
 * tuplestore rather than one materialised CTE, so they still cannot disagree
 * about which rows the view produces (A3).  The whole of step 2, evaluation
 * and DML alike, runs under one snapshot -- taken here rather than by SPI --
 * because otherwise the view would be evaluated at one point in time and the
 * rows it is compared against read at a later one, and a key inserted in
 * between by an overlapping refresh would be pruned as though the view had
 * stopped producing it.
 *
 * To avoid rebuilding the SQL and re-preparing the SPI plans on every call,
 * we cache both plans in a session-level hash table keyed by matview OID.
 *
 * Returns the number of rows processed by the refresh CTE.
 */
static uint64
refresh_by_direct_modification(Oid matviewOid, Oid relowner,
							   int save_sec_context, Query *dataQuery,
							   Node *qual, ParamListInfo params)
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
	bool		use_optimized = matview_partial_refresh_optimized;
	int			nkeyatts = 0;
	int16	   *keyattnums = NULL;
	Tuplestorestate *sourceStore = NULL;
	bool		qual_key_only = false;
	bool		serialized;
	int64		n_locked = 0;
	int64		n_source = 0;

	matviewRel = table_open(matviewOid, NoLock);

	/*
	 * Can any other session write this matview while we refresh it?  Only the
	 * prune guard cares, and it cares a great deal -- see
	 * matview_prune_guard_params().  Asked of the lock manager rather than
	 * derived from whether CONCURRENTLY was written, because what the guard
	 * needs is the fact rather than the spelling that chose it.
	 */
	serialized = CheckRelationLockedByMe(matviewRel, ExclusiveLock, true);

	/*
	 * Find the usable unique index.  There is at most one, so there is nothing
	 * to choose between: this function is reached only when the caller has
	 * established that the matview has no more than one index satisfying
	 * indisunique && indisvalid && indimmediate, and is_usable_unique_index()
	 * demands all three of those plus non-partial, indnatts > 0 and no
	 * expression or system columns.  Anything usable is therefore also
	 * counted, and at most one thing was counted.
	 */
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
	 * Look up or create a plan cache entry for this matview -- but only the
	 * outermost partial refresh uses the session cache at all.
	 *
	 * A nested one is reachable: the predicate and the view definition are both
	 * evaluated inside the maintenance window, so a function in either can
	 * issue REFRESH MATERIALIZED VIEW ... WHERE.  If such a call reached the
	 * code below, matview_cache_sweep() would free and remove the entry the
	 * enclosing refresh is still executing from.  The sweep's frees were
	 * deferred to here on the belief that "nothing removes entries until the
	 * next refresh" -- but a nested refresh IS the next refresh, and it sweeps
	 * every entry the callback marked, which is all of them.  Neither the
	 * CachedPlan refcount nor anything else protects against that:
	 * SPI_freeplan() deletes the _SPI_plan's own context, which holds the
	 * plancache_list that _SPI_execute_plan is iterating.  Reproduced on an
	 * assertions build as a refresh executing a different matview's plan, as a
	 * freed query_string printed by the error context, and as a SIGSEGV.
	 *
	 * The nested refresh must be of a different matview: CheckTableNotInUse()
	 * rejects one of the same matview well before this point, which is also why
	 * the mismatch branch below cannot reach an enclosing refresh's entry -- it
	 * only ever frees plans under the OID its own caller passed.
	 *
	 * So a nested refresh prepares private plans and touches neither the hash
	 * table nor the entries in it.  They are not SPI_keepplan'd, so SPI_finish()
	 * below reclaims them; nesting is rare enough that losing the cache there
	 * costs nothing, and the alternative -- sharing an entry with a caller that
	 * is mid-execution -- is what this is fixing.
	 */
	use_cache = (matview_maintenance_depth == 0);

	if (use_cache)
	{
		if (!MatViewRefreshCache)
			InitMatViewCache();

		/*
		 * Discard anything the relcache callback marked stale.  Do this before
		 * taking our own entry: the sweep removes entries, so a pointer taken
		 * first would not survive it.  Afterwards nothing removes entries --
		 * the callback only marks, and a nested refresh no longer sweeps -- so
		 * cacheEntry stays valid for the whole maintenance window even though
		 * invalidations keep arriving during it.
		 */
		matview_cache_sweep();

		cacheEntry = (MatViewPartialRefreshCache *)
			hash_search(MatViewRefreshCache, &matviewOid, HASH_ENTER, &found);

		/*
		 * HASH_ENTER fills in the key and leaves the rest of the element
		 * holding whatever dynahash last had there.  The mismatch branch below
		 * initialises every other field, but it does so after testing metacxt,
		 * so that one has to be cleared here or a new entry would reset a
		 * garbage context.
		 */
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
	 * We have a cache hit ONLY if the entry exists, the unique index matches,
	 * and the predicate is the same predicate.  Same predicate means an equal()
	 * tree: the plans were built by deparsing this tree, so two trees that
	 * compare equal deparse to the same statement, and a difference anywhere in
	 * the tree is a difference in the rows selected.  The entry's qual is also
	 * checked non-NULL, which is not redundant -- equal() would answer this
	 * correctly, but an entry whose plan build threw partway is worth refusing
	 * explicitly rather than by implication.
	 *
	 * The tree is compared rather than its deparsed text because the text was
	 * this comparison's only reader, and producing it costs 4.5-5.3 us on every
	 * refresh including one that goes on to hit (RESULTS.md R14).  It is also
	 * the stronger key: pg_get_expr renders a Param as "$n" with no type, which
	 * is B3, while the tree carries paramtype and paramtypmod on the node.
	 * argtypes stays anyway -- it covers a parameter the predicate never names,
	 * which cannot appear in the tree and which the generated statement still
	 * has to declare.
	 *
	 * The plans are also specific to which implementation built them, and that
	 * can change between two refreshes of the same matview in one session
	 * while the two are being compared against each other.
	 */
	if (found &&
		cacheEntry->uniqueIndexOid == uniqueIndexOid &&
		cacheEntry->optimized == use_optimized &&
		cacheEntry->qual != NULL &&
		equal(cacheEntry->qual, qual) &&
		cacheEntry->nargs == (params ? params->numParams : 0) &&
		matview_argtypes_match(cacheEntry, params))
	{
		/* Cache is valid.  Do nothing. */
	}
	else
	{
		if (found)
		{
			/* Index or WHERE clause changed; discard stale plans. */
			if (cacheEntry->lockPlan)
				SPI_freeplan(cacheEntry->lockPlan);
			if (cacheEntry->refreshPlan)
				SPI_freeplan(cacheEntry->refreshPlan);
			if (cacheEntry->sourcePlan)
				DropCachedPlan(cacheEntry->sourcePlan);
			if (cacheEntry->metacxt)
				MemoryContextReset(cacheEntry->metacxt);
		}

		cacheEntry->lockPlan = NULL;
		cacheEntry->refreshPlan = NULL;
		cacheEntry->sourcePlan = NULL;
		cacheEntry->qual = NULL;
		cacheEntry->nargs = 0;
		cacheEntry->argtypes = NULL;
		cacheEntry->optimized = use_optimized;
		cacheEntry->invalid = false;
	}

	old_depth = matview_maintenance_depth;
	old_relid = matview_maintenance_relid;
	OpenMatViewIncrementalMaintenance(matviewOid);

	PG_TRY();
	{
	SPI_connect();

	/*
	 * Register the relation the fused statement will read its source rows
	 * from.  It has to exist before the statement is parsed, and the rows have
	 * to be collected after the locking step rather than before it, so the
	 * tuplestore is registered empty here and filled further down.  Nothing
	 * reads it in between.
	 */
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

		/*
		 * Whether the prune may be elided on a row count alone.  A property of
		 * the request's shape rather than of the data, so it could be computed
		 * once on a cache miss and stored -- but it is a walk of a predicate
		 * that has just been parsed, and it does NOT change the generated SQL
		 * (the gate rides in the parameter values, see below), so it stays out
		 * of the cache entry and out of the cache key.
		 */
		qual_key_only = refresh_qual_is_key_only(qual, nkeyatts, keyattnums);

		sourceStore = tuplestore_begin_heap(false, false, work_mem);

		enr = (EphemeralNamedRelation) palloc0(sizeof(EphemeralNamedRelationData));
		enr->md.name = MATVIEW_SOURCE_ENR_NAME;
		enr->md.reliddesc = InvalidOid;
		enr->md.tupdesc = CreateTupleDescCopy(RelationGetDescr(matviewRel));
		enr->md.enrtype = ENR_NAMED_TUPLESTORE;

		/*
		 * A row estimate for new_data, which at this moment is empty: the
		 * tuplestore is not filled until after the pre-lock, further down.
		 *
		 * The true count cannot be supplied here and this is not an oversight
		 * that a later assignment could correct.  addRangeTableEntryForENR()
		 * copies this value into the range table entry during PARSE ANALYSIS,
		 * so it is captured by SPI_prepare() below and then travels inside the
		 * cached plan; updating the ENR afterwards changes nothing the planner
		 * reads.  And the plan is reused across refreshes whose scopes differ by
		 * orders of magnitude, so no single true count would be true twice.
		 * costsize.c asks for exactly this case by name: "in others the same
		 * plan will be re-used, so a 'typical' value might be estimated and
		 * used."
		 *
		 * So the question is which wrong value is least wrong, and the matview's
		 * own row count answers it two ways.  It is the right order of magnitude
		 * -- the source is the view's output for the scope, and the matview is
		 * the view's output for everything -- and it errs high, which is the
		 * safe direction: an overestimate biases the prune's anti-join towards a
		 * hash join, which is what a large scope wants, while an underestimate
		 * invites a nested loop over rows that turn out to be plentiful.
		 *
		 * Measured rather than argued, in the cells where the anti-join actually
		 * runs.  Against this: enrtuples = 1 costs 23.878 -> 25.898 ms at scope
		 * 10000 and 2.910 -> 3.355 on a non-key predicate.  And a *perfect*
		 * estimate is no better -- supplying the exact scope reads 24.849 at
		 * scope 10000 against this line's 23.610, and 2.954 at scope 1000
		 * against 2.770.  Nothing tested beats it, including the truth.
		 */
		enr->md.enrtuples = Max(matviewRel->rd_rel->reltuples, 0);
		enr->reldata = sourceStore;

		if (SPI_register_relation(enr) != SPI_OK_REL_REGISTER)
			elog(ERROR, "could not register source rows for partial refresh");
	}

	/* Prepare plans if we don't have valid cached ones. */
	if (cacheEntry->lockPlan == NULL || cacheEntry->refreshPlan == NULL)
	{
		StringInfoData buf;
		char	   *matview_name;
		const char *matview_alias;
		char	   *whereClauseStr;
		Oid		   *argtypes = NULL;
		Oid		   *dml_argtypes;
		int			nargs = 0;
		int			dml_nargs;
		Relation	indexRel;
		Form_pg_index indexStruct;
		TupleDesc	tupdesc = matviewRel->rd_att;
		StringInfoData conflict_cols;
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
		matview_alias = quote_identifier(RelationGetRelationName(matviewRel));

		/*
		 * The one place the predicate still has to be text: SPI takes a string.
		 * Inside the miss branch rather than above it, because a hit has no use
		 * for it -- the cache is keyed on the tree this was deparsed from.
		 */
		whereClauseStr = deparseRefreshWhereClause(matviewOid, qual);

		if (params && params->numParams > 0)
		{
			nargs = params->numParams;
			argtypes = (Oid *) palloc(nargs * sizeof(Oid));
			for (i = 0; i < nargs; i++)
				argtypes[i] = params->params[i].ptype;
		}

		/*
		 * The fused statement takes three parameters of its own after the
		 * predicate's, carrying the prune guard.  They are always declared and
		 * the guard is always in the SQL: what decides whether the prune runs
		 * is the values, not the text, so the statement stays one statement
		 * with one plan under one cache key.  (B31: anything that changes the
		 * generated SQL has to be part of the key.  This does not.)
		 */
		dml_nargs = nargs + MATVIEW_PRUNE_GUARD_NARGS;
		dml_argtypes = (Oid *) palloc(dml_nargs * sizeof(Oid));
		for (i = 0; i < nargs; i++)
			dml_argtypes[i] = argtypes[i];
		dml_argtypes[nargs + 0] = BOOLOID;	/* skip the prune outright */
		dml_argtypes[nargs + 1] = INT8OID;	/* rows the pre-lock matched */
		dml_argtypes[nargs + 2] = INT8OID;	/* rows the source produced, or -1 */

		indexRel = index_open(uniqueIndexOid, AccessShareLock);
		indexStruct = indexRel->rd_index;

		/*
		 * The anti-join decides which matview rows are still produced by the
		 * query, and ON CONFLICT decides which ones the upsert can match.  The
		 * two must agree about NULLs, or a row can be "still present" to one
		 * and "brand new" to the other, which duplicates it.  Follow whatever
		 * the arbiter index does.
		 *
		 * Preferring plain equality where we can also matters for speed: it is
		 * hashable and mergeable, where IS NOT DISTINCT FROM is neither and
		 * forces a nested loop over the whole candidate set.
		 */
		anti_join_op = indexStruct->indnullsnotdistinct ?
			"IS NOT DISTINCT FROM" : "=";

		initStringInfo(&conflict_cols);
		initStringInfo(&mv_cols);
		initStringInfo(&excluded_cols);
		initStringInfo(&set_clause);
		initStringInfo(&join_clause);

		/* Build the ON CONFLICT column list and anti-join condition. */
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
				appendStringInfoString(&join_clause, " AND ");
			}
			first = false;

			appendStringInfoString(&conflict_cols, quoted);
			appendStringInfo(&join_clause, "nd.%s %s mv.%s",
							 quoted, anti_join_op, quoted);
		}

		/* Build the DO UPDATE SET clause for non-key columns. */
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

			/*
			 * The same columns again, as a row comparison, so the upsert can
			 * skip a row whose values did not change.  ON CONFLICT DO UPDATE
			 * writes a new row version whether or not anything differs, and
			 * a partial refresh re-reads scopes that are mostly unchanged --
			 * a drain re-refreshing a key it already caught up on writes the
			 * whole scope again for nothing.
			 *
			 * Non-key columns only: the key columns are what the row was
			 * matched on, so they are equal by construction.
			 */
			if (!first_distinct)
			{
				appendStringInfoString(&mv_cols, ", ");
				appendStringInfoString(&excluded_cols, ", ");
			}
			first_distinct = false;
			appendStringInfo(&mv_cols, "%s.%s", matview_alias, quoted);
			appendStringInfo(&excluded_cols, "EXCLUDED.%s", quoted);
		}

		index_close(indexRel, AccessShareLock);

		/*
		 * Preconditions for the guarantees this function has to deliver.
		 *
		 * Two overlapping refreshes must take the rows they share in the same
		 * order, both for rows the matview already holds and for rows they
		 * each insert; otherwise they deadlock.  That was reported on -hackers
		 * (A5) and both halves are gated by isolation specs -- see
		 * matview-where-lockorder and matview-where-insertorder.
		 *
		 * Whatever produces the ordering, it needs an order to produce.  Both
		 * take it from the arbiter index's key columns, so an empty
		 * conflict_cols means no deterministic order exists to impose, and the
		 * ON CONFLICT target is empty as well.  Assert the precondition rather
		 * than the SQL: a check that the generated text contains "ORDER BY"
		 * would pin one way of ordering and go red against any other, which is
		 * the defect that made the pg_stat_statements block unkeepable.
		 *
		 * The anti-join condition is the prune's half of the same contract --
		 * it decides which rows the view no longer produces, and an empty one
		 * would delete the whole scope.
		 *
		 * Note what is deliberately NOT asserted here: that the upsert and the
		 * prune see a single evaluation of the view query (A3).  That is a
		 * property of how the statement executes, not of anything visible at
		 * build time, and a correct implementation has no window in which the
		 * difference can be observed.  Its gates are the differential oracle
		 * and fuzz.sh's serial mode; see PLAN.md 1.1b.
		 */
		Assert(conflict_cols.len > 0);
		Assert(join_clause.len > 0);

		/*
		 * Prepare the row-locking statement.  This acquires row locks on the
		 * matview rows matching the WHERE clause to serialize concurrent
		 * partial refreshes on overlapping rows.
		 *
		 * FOR NO KEY UPDATE rather than FOR UPDATE.  The two are equally good
		 * at the job this statement exists for -- FOR NO KEY UPDATE conflicts
		 * with itself, so two refreshes over overlapping scopes still order
		 * against each other, which is the property that stops the second one
		 * evaluating its source from a snapshot taken before the first commits
		 * and then writing a stale value over it.  What FOR UPDATE adds is a
		 * conflict with FOR KEY SHARE, and it takes the key-exclusive tuple
		 * lock rather than the weaker one the following update actually needs:
		 * the upsert's DO UPDATE sets non-key columns only, because the key
		 * columns are what it matched on, so it is by construction a no-key
		 * update.  Taking the stronger lock first only escalates what has to be
		 * recorded in xmax.
		 *
		 * The prune may still DELETE a row this locked, which needs the
		 * stronger lock.  That upgrade cannot block or deadlock: this
		 * transaction already holds a conflicting lock on the row, so no other
		 * transaction can be holding one to wait for.
		 *
		 * Lock in a fixed order so that two refreshes whose predicates overlap
		 * cannot take the same rows in opposite orders and deadlock.  When the
		 * predicate is on the key columns the index already returns rows in
		 * this order, so the ORDER BY adds no sort.
		 *
		 * It is emitted unconditionally, and the bare form's ExclusiveLock is
		 * NOT an excuse to drop it even though nothing else can write the
		 * matview at that level.  That was implemented and measured and it does
		 * not pay: the clause is nearly free where the arbiter index already
		 * yields key order, and where it is not -- a matview whose physical
		 * order has drifted from its key, which is what repeated refreshing
		 * produces -- removing it makes the statement cheap enough that
		 * plancache stops settling on a generic plan and re-plans it on every
		 * call.  On a range predicate that cost 613 us against the 137 us the
		 * ordering itself was worth.  RESULTS.md R44, and PLAN.md 4.1 for the
		 * plancache behaviour it runs into.
		 */
		initStringInfo(&buf);
		appendStringInfo(&buf,
						 "SELECT 1 FROM %s mv WHERE (%s) ORDER BY %s "
						 "FOR NO KEY UPDATE",
						 matview_name, whereClauseStr, conflict_cols.data);

		cacheEntry->lockPlan = SPI_prepare(buf.data, nargs, argtypes);
		if (cacheEntry->lockPlan == NULL)
			elog(ERROR, "SPI_prepare failed for lock acquisition: %s", buf.data);
		if (use_cache)
			SPI_keepplan(cacheEntry->lockPlan);

		resetStringInfo(&buf);

		/*
		 * The source rows are the registered tuplestore, materialised before
		 * this statement started, which the upsert and the prune each read and
		 * both see identically.  An earlier revision could instead inline the
		 * view as a MATERIALIZED CTE; that path is gone, and with it the only
		 * caller that needed the view deparsed to text.
		 */
		appendStringInfoString(&buf, "WITH ");

		appendStringInfo(&buf,
						 "upsert AS ( "
						 "  INSERT INTO %s SELECT * FROM new_data "
						 "  ON CONFLICT (%s) DO ",
						 matview_name, conflict_cols.data);

		if (has_non_key_cols)
		{
			appendStringInfo(&buf, "UPDATE SET %s ", set_clause.data);
			if (use_optimized)
				appendStringInfo(&buf, "WHERE (%s) IS DISTINCT FROM (%s) ",
								 mv_cols.data, excluded_cols.data);
		}
		else
			appendStringInfoString(&buf, "NOTHING ");

		/*
		 * RETURNING says whether each row the upsert touched was an insert,
		 * which is what the prune guard counts.  OLD is the row ON CONFLICT
		 * matched and is entirely NULL when there was none, so OLD.ctid is NULL
		 * exactly for an inserted row -- and a matview cannot have a column
		 * called ctid ("column name \"ctid\" conflicts with a system column
		 * name"), so the reference is unambiguous.  A key column would not do:
		 * under a NULLS NOT DISTINCT arbiter an existing row with a NULL key
		 * can be updated, and OLD.key IS NULL would call that an insert.
		 *
		 * This is also why the count is of inserts rather than of updates.  The
		 * row comparison (use_optimized) suppresses the write for a row nothing
		 * changed about, and a suppressed row returns nothing at all -- so the
		 * updates are not all visible here, while the inserts are: an insert is
		 * never filtered by a DO UPDATE ... WHERE.
		 */
		appendStringInfo(&buf,
						 "  RETURNING (OLD.ctid IS NULL) AS ins "
						 "), "
						 "pruned AS ( "
						 "  DELETE FROM %s mv WHERE (%s) AND NOT EXISTS ( "
						 "    SELECT 1 FROM new_data nd WHERE %s"
						 "  ) AND NOT ($%d OR $%d + (SELECT pg_catalog.count(*) "
						 "    FILTER (WHERE ins) FROM upsert) = $%d) "
						 "  RETURNING 1 "
						 ") "
						 "SELECT (SELECT pg_catalog.count(*) FROM upsert) "
						 "     + (SELECT pg_catalog.count(*) FROM pruned)",
						 matview_name, whereClauseStr, join_clause.data,
						 nargs + 1, nargs + 2, nargs + 3);

		cacheEntry->refreshPlan = SPI_prepare(buf.data, dml_nargs, dml_argtypes);
		if (cacheEntry->refreshPlan == NULL)
			elog(ERROR, "SPI_prepare failed for refresh CTE: %s", buf.data);
		if (use_cache)
			SPI_keepplan(cacheEntry->refreshPlan);

		/*
		 * Save cache metadata in a long-lived context.  Only for a real entry:
		 * the metadata exists to be compared on a LATER call, and a nested
		 * refresh's entry is gone when this one returns, so writing it into
		 * CacheMemoryContext would be a leak with no reader.
		 */
		if (use_cache)
		{
			/*
			 * The qual is a node tree, and a node tree cannot be pfree'd: it is
			 * many allocations reachable only from each other.  So the entry's
			 * metadata gets a context of its own, reset when the key changes and
			 * deleted when the entry goes.  argtypes rides along in it so that
			 * one reset covers both and neither can outlive the other.
			 */
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
		pfree(set_clause.data);
		pfree(mv_cols.data);
		pfree(excluded_cols.data);
		pfree(join_clause.data);
		if (argtypes != NULL)
			pfree(argtypes);
		pfree(dml_argtypes);
	}


	/* Execute: lock matching rows, then run the refresh CTE. */
	if (matview_execute_spi_plan(cacheEntry->lockPlan, params,
								 InvalidSnapshot, false) < 0)
		elog(ERROR, "SPI_execute_plan failed during lock acquisition");

	/*
	 * How many rows the matview holds in scope right now, under a lock that
	 * stops them changing.  Half of the prune guard's accounting, and the half
	 * that is matview-side: the source count below says what the view produces,
	 * which on its own cannot decide whether anything is orphaned.
	 */
	n_locked = (int64) SPI_processed;

	/*
	 * The two statements take separate snapshots, so a base-table change that
	 * commits here is invisible to the locking step above and visible to the
	 * refreshing step below.  The window is microseconds wide in practice; the
	 * injection point lets a test land inside it deterministically.  See
	 * src/test/modules/injection_points/specs/matview-where-snapshot.spec.
	 */
	INJECTION_POINT("matview-where-locked", NULL);

	{
		Query	   *sourceQuery;
		Snapshot	snapshot;

		/*
		 * One snapshot for the whole of step 2.  SPI would otherwise take its
		 * own for the DML, leaving the view evaluated as of one moment and the
		 * rows it is compared against read as of a later one; a key another
		 * refresh inserted in the gap would then be pruned as though the view
		 * no longer produced it.  The fused CTE never had that gap because
		 * evaluation and DML were one statement, and this keeps it that way.
		 */
		CommandCounterIncrement();
		PushCopiedSnapshot(GetTransactionSnapshot());
		snapshot = GetActiveSnapshot();

		/*
		 * Build the source plansource on the first refresh through this entry
		 * and keep it.  On the ones after, plancache hands back the plan it
		 * already has -- that is 3.7.
		 *
		 * The query itself is only built on a miss, which is a second saving
		 * on top of the plan: the entry is keyed on the arbiter index, the
		 * deparsed predicate and the argument types, and those are exactly the
		 * inputs matview_build_source_query() reads besides the matview OID.
		 * A hit therefore means it would build the same tree again.  Values
		 * that vary between refreshes arrive through `params`, not through the
		 * tree, which is what plancache exists to handle.
		 *
		 * SaveCachedPlan() only under use_cache, matching what SPI_keepplan()
		 * does for the other two plans.  This is B14's guard: a nested refresh
		 * at maintenance depth > 0 holds a stack entry that is gone when it
		 * returns, so saving its plansource would leak it into
		 * CacheMemoryContext with nothing left to read it.  It is dropped
		 * below instead.
		 *
		 * It must be saved *before* the first GetCachedPlan(): SaveCachedPlan()
		 * asserts the plansource is not already saved and discards any plan it
		 * is holding.
		 */
		if (cacheEntry->sourcePlan == NULL)
		{
			sourceQuery = matview_build_source_query(matviewRel, dataQuery,
													qual, nkeyatts,
													keyattnums);
			cacheEntry->sourcePlan =
				matview_build_source_plansource(sourceQuery);
			if (use_cache)
				SaveCachedPlan(cacheEntry->sourcePlan);
		}

		n_source = (int64) matview_materialize_source(cacheEntry->sourcePlan,
													  params, snapshot,
													  sourceStore);

		/*
		 * The rows are computed; the statement that compares the matview
		 * against them has not run yet.  Whether anything can be observed in
		 * between is the whole question this path has to answer, so give a
		 * test somewhere deterministic to stand.
		 */
		INJECTION_POINT("matview-where-source-materialized", NULL);

		if (matview_execute_spi_plan(cacheEntry->refreshPlan,
									 matview_prune_guard_params(params,
																serialized,
																qual_key_only,
																n_locked,
																n_source),
									 snapshot, false) < 0)
			elog(ERROR, "SPI_execute_plan failed during refresh");

		PopActiveSnapshot();
	}

	/*
	 * The statement returns one row holding the number of rows upserted plus
	 * the number pruned.  SPI_processed would only count the rows the top-level
	 * statement returned, which is always one.
	 */
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

	/*
	 * A nested refresh's plansource was never saved, so nothing else will ever
	 * free it -- SPI_finish() reclaims its two SPI plans but knows nothing
	 * about this one, and the stack entry holding the pointer is about to go
	 * out of scope.  Drop it here.  The saved one is left alone: it belongs to
	 * the hash entry and is freed by matview_cache_sweep() or by the mismatch
	 * branch that rebuilds the entry.
	 */
	if (!use_cache && cacheEntry->sourcePlan != NULL)
	{
		DropCachedPlan(cacheEntry->sourcePlan);
		cacheEntry->sourcePlan = NULL;
	}

	SPI_finish();
	}
	PG_CATCH();
	{
		/*
		 * Restore the maintenance flag.  Leaving it raised would disable the
		 * "cannot change materialized view" check for the rest of the session.
		 */
		matview_maintenance_depth = old_depth;
		matview_maintenance_relid = old_relid;

		/* Same reasoning as the success path; see above. */
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
 * Choose the unique index to use as the ON CONFLICT arbiter.  Returns
 * InvalidOid if the matview has none that is usable.
 *
 * This used to prefer indisprimary, which can never be set here: a
 * materialized view cannot have a primary key at all, because ALTER ... ADD
 * CONSTRAINT rejects matviews outright.  Any index it has arrived via CREATE
 * INDEX, so the first usable one is the answer.
 */
static Oid
matview_pick_arbiter_index(Relation matviewRel)
{
	List	   *indexoidlist = RelationGetIndexList(matviewRel);
	ListCell   *lc;
	Oid			result = InvalidOid;

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
			result = indexoid;
			break;
		}
	}
	list_free(indexoidlist);
	return result;
}

/*
 * Build the pieces of an ON CONFLICT clause for the given arbiter index: the
 * conflict target column list, the DO UPDATE SET list covering every non-key
 * column, and the equality operator whose NULL handling matches the index.
 */
static void
matview_build_upsert_clause(Relation matviewRel, Oid arbiterOid,
							StringInfo conflict_cols, StringInfo set_clause,
							bool *has_non_key_cols, const char **anti_join_op)
{
	Relation	indexRel = index_open(arbiterOid, AccessShareLock);
	Form_pg_index indexStruct = indexRel->rd_index;
	TupleDesc	tupdesc = matviewRel->rd_att;
	bool		first;
	int			i;
	int			j;

	*has_non_key_cols = false;
	if (anti_join_op)
		*anti_join_op = indexStruct->indnullsnotdistinct ?
			"IS NOT DISTINCT FROM" : "=";

	first = true;
	for (i = 0; i < indexStruct->indnkeyatts; i++)
	{
		int			attnum = indexStruct->indkey.values[i];
		Form_pg_attribute attr = TupleDescAttr(tupdesc, attnum - 1);

		if (!first)
			appendStringInfoString(conflict_cols, ", ");
		first = false;
		appendStringInfoString(conflict_cols,
							   quote_identifier(NameStr(attr->attname)));
	}

	first = true;
	for (i = 0; i < tupdesc->natts; i++)
	{
		Form_pg_attribute attr = TupleDescAttr(tupdesc, i);
		const char *quoted;
		bool		is_key = false;

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
			appendStringInfoString(set_clause, ", ");
		first = false;
		*has_non_key_cols = true;
		quoted = quote_identifier(NameStr(attr->attname));
		appendStringInfo(set_clause, "%s = EXCLUDED.%s", quoted, quoted);
	}

	index_close(indexRel, AccessShareLock);
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
 * If whereClauseStr is provided, only rows matching the WHERE condition
 * in the existing matview are considered for the diff operation, enabling
 * partial concurrent refresh.
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
static uint64
refresh_by_match_merge(Oid matviewOid, Oid tempOid, Oid relowner,
					   int save_sec_context, char *whereClauseStr,
					   ParamListInfo params)
{
	StringInfoData querybuf;
	uint64		applied = 0;
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
					 "FROM ",
					 diffname, tempname);

	if (whereClauseStr)
		appendStringInfo(&querybuf, "(SELECT ctid, * FROM %s WHERE %s) mv", matviewname, whereClauseStr);
	else
		appendStringInfo(&querybuf, "%s mv", matviewname);

	appendStringInfo(&querybuf, " FULL JOIN %s newdata ON (", tempname);

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

	if (whereClauseStr)
	{
		StringInfoData cols;
		int			i;
		bool		first = true;

		initStringInfo(&cols);
		for (i = 0; i < relnatts; i++)
		{
			Form_pg_attribute attr = TupleDescAttr(tupdesc, i);

			if (attr->attisdropped)
				continue;
			if (!first)
				appendStringInfoString(&cols, ", ");
			first = false;
			appendStringInfo(&cols, "mv.%s", quote_qualified_identifier(NULL, NameStr(attr->attname)));
		}

		appendStringInfo(&querybuf,
						 " AND newdata.* OPERATOR(pg_catalog.*=) ROW(%s)) "
						 "WHERE newdata.* IS NULL OR mv.ctid IS NULL "
						 "ORDER BY tid",
						 cols.data);
		pfree(cols.data);
	}
	else
	{
		appendStringInfoString(&querybuf,
							   " AND newdata.* OPERATOR(pg_catalog.*=) mv.*) "
							   "WHERE newdata.* IS NULL OR mv.* IS NULL "
							   "ORDER BY tid");
	}

	/* Populate the temporary "diff" table. */
	if (matview_execute_spi(querybuf.data, params, false) != SPI_OK_INSERT)
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
	applied += SPI_processed;

	/* Inserts go last. */
	resetStringInfo(&querybuf);
	appendStringInfo(&querybuf,
					 "INSERT INTO %s SELECT (diff.newdata).* "
					 "FROM %s diff WHERE tid IS NULL",
					 matviewname, diffname);

	/*
	 * For a partial refresh the diff only covers rows matching the predicate,
	 * so a fresh row can collide on the unique key with an existing row that
	 * does not match it and was therefore never considered for deletion -- a
	 * row that "drifted" into scope.  Resolve that in place rather than
	 * failing, which is what the direct-modification path does.
	 *
	 * A full concurrent refresh diffs the whole matview, so no such row can
	 * exist and the plain insert is left alone.
	 */
	if (whereClauseStr)
	{
		Oid			arbiterOid = matview_pick_arbiter_index(matviewRel);
		StringInfoData conflict_cols;
		StringInfoData set_clause;
		bool		has_non_key_cols;

		if (!OidIsValid(arbiterOid))
			elog(ERROR, "could not find suitable unique index on materialized view \"%s\"",
				 RelationGetRelationName(matviewRel));

		initStringInfo(&conflict_cols);
		initStringInfo(&set_clause);
		matview_build_upsert_clause(matviewRel, arbiterOid, &conflict_cols,
									&set_clause, &has_non_key_cols, NULL);

		if (has_non_key_cols)
			appendStringInfo(&querybuf, " ON CONFLICT (%s) DO UPDATE SET %s",
							 conflict_cols.data, set_clause.data);
		else
			appendStringInfo(&querybuf, " ON CONFLICT (%s) DO NOTHING",
							 conflict_cols.data);

		pfree(conflict_cols.data);
		pfree(set_clause.data);
	}

	if (SPI_exec(querybuf.data, 0) != SPI_OK_INSERT)
		elog(ERROR, "SPI_exec failed: %s", querybuf.data);
	applied += SPI_processed;

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

	return applied;
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
 * - REFRESH ... WHERE ... which modifies the matview in-place.
 */
bool
MatViewIncrementalMaintenanceIsEnabled(Oid relid)
{
	if (matview_maintenance_depth <= 0)
		return false;

	/*
	 * Only the matview actually being refreshed is exempt.  Without this a
	 * function in a partial refresh's WHERE clause could modify any matview in
	 * the database, since it is evaluated inside this window.
	 */
	return (!OidIsValid(matview_maintenance_relid) ||
			matview_maintenance_relid == relid);
}

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
