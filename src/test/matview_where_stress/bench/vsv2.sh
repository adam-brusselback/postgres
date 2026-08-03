#!/bin/sh
#
# The current implementation against the patch as posted to -hackers (c8beb05).
#
#   ./vsv2.sh speed    per-refresh cost, both forms, across the scope decades
#   ./vsv2.sh correct  the shapes where v2 is WRONG, which speed must not average over
#
# PLAN.md 3.5 and Phase 7: "the numbers Adam posted originally describe v1 and
# have to be superseded explicitly rather than quietly."  This is that.
#
# The three traps, and what is done about each
# --------------------------------------------
# 1. WRONG IS FASTER.  v2 duplicates NULL-keyed rows on a nullable unique key
#    (B4), and its diff insert does not arbitrate on the index so a row leaving
#    the scope survives (A4).  On those shapes it does less work because it is
#    doing the wrong thing, and a speed chart that averages them in publishes a
#    number where the correct implementation looks slower for being correct.
#    `correct` runs them as a separate PASS/FAIL table and `speed` does not
#    touch them.
#
# 2. THE FORM LABELS DO NOT MEAN THE SAME THING.  Which spelling selected which
#    algorithm changed twice since v2 -- first the A8 swap, then B21 moving the
#    routing onto the unique-index count.  So `bare` against `bare` is not
#    like-for-like.  Every matview here has exactly ONE unique index, which is
#    the case both trees route to direct modification for at least one spelling,
#    and both spellings are reported so the mapping is visible rather than
#    assumed.
#
# 3. CROSS-BUILD.  Two trees, so two prefixes and two clusters, each built -O2
#    with assertions off and each carrying an identical fixture built by the
#    same SQL.  Arms alternate per round with the order flipped, and the fixture
#    is rebuilt from scratch before every timed block on both sides, so neither
#    inherits the other's heap state -- which is the axis RESULTS.md X1 and R5
#    exist about.  Report the median of the rounds; a mean over few rounds is
#    not robust to one excursion (X14).
#
# 4. THE PREDICATE SHAPE DECIDES THE SMALL-SCOPE ANSWER, and getting this wrong
#    would have shipped the headline backwards.  A narrow range predicate is
#    PLAN.md 4.1's worst case for plancache: `auto` keeps choosing a custom plan
#    for `id BETWEEN $1 AND $1` and re-plans on every execution.  Only the
#    current tree is exposed to it, because only the current tree parameterises
#    the predicate's constants; v2 leaves them as literals, so `params` is NULL,
#    `choose_custom_plan()` short-circuits, and it gets a generic plan
#    unconditionally and forever.  Measured at scope 1, bare, median of 40:
#
#      BETWEEN 1 AND 1            v2 0.107   cur 0.397    cur 3.7x slower
#      id = 1                     v2 0.144   cur 0.107    cur 1.3x FASTER
#      BETWEEN, cur forced generic           cur 0.146    the re-plan is 2.7x
#
#    So "current is 3.3x slower at scope 1" is a statement about plancache's
#    handling of one predicate shape, not about the cost of the guarantees, and
#    reporting the range sweep alone would have said the opposite of the truth.
#    Run both shapes.  Note also that a range sweep makes every CURRENT figure
#    pessimistic at every scope, so the large-scope wins below are lower bounds.
set -eu

DIR=$(cd "$(dirname "$0")/.." && pwd)
V2_PREFIX=${V2_PREFIX:-/home/user/pgsql-v2}
CUR_PREFIX=${CUR_PREFIX:-/home/user/pgsql-opt}
V2_PORT=${V2_PORT:-5611}
CUR_PORT=${CUR_PORT:-5610}
DB=${DB:-postgres}
RUNAS=${RUNAS:-pgtest}
ROUNDS=${ROUNDS:-5}
SCALE=${SCALE:-100000}
# eq | range.  This is an AXIS, not a detail -- see the note below.
PRED=${PRED:-range}

mode=${1:-}
[ -n "$mode" ] || { sed -n '2,7p' "$0"; exit 2; }

psql_on() {  # psql_on <arm> <args...>
    arm=$1; shift
    case "$arm" in
    v2)  su "$RUNAS" -c "$V2_PREFIX/bin/psql -p $V2_PORT -d $DB -qX $*" ;;
    cur) su "$RUNAS" -c "$CUR_PREFIX/bin/psql -p $CUR_PORT -d $DB -qX $*" ;;
    esac
}
feed() {  # feed <arm>, SQL on stdin
    arm=$1
    case "$arm" in
    v2)  su "$RUNAS" -c "$V2_PREFIX/bin/psql -p $V2_PORT -d $DB -qtAX" ;;
    cur) su "$RUNAS" -c "$CUR_PREFIX/bin/psql -p $CUR_PORT -d $DB -qtAX" ;;
    esac
}

# One fixture, one definition, built identically on both sides.  A plain
# projection with one unique index on the key and an index on the non-key
# column, which is the shape both trees can route to direct modification and the
# shape USE-CASES.md's cost model is stated against.
fixture() {
    cat <<SQL
DROP MATERIALIZED VIEW IF EXISTS vv_mv;
DROP TABLE IF EXISTS vv_base;
CREATE TABLE vv_base(id bigint primary key, cust int, status text, amt numeric);
INSERT INTO vv_base
  SELECT g, g % 1000, 'S' || (g % 5), g::numeric
    FROM generate_series(1, $SCALE) g;
CREATE INDEX ON vv_base(cust);
CREATE MATERIALIZED VIEW vv_mv AS
  SELECT id, cust, status, amt FROM vv_base;
CREATE UNIQUE INDEX ON vv_mv(id);
CREATE INDEX ON vv_mv(cust);
VACUUM ANALYZE vv_base;
VACUUM ANALYZE vv_mv;
SQL
}

# A timed block: rebuild the fixture, then N refreshes of one scope, timed by
# psql itself.  The fixture rebuild is inside the arm and outside the timing, so
# both sides start from the same heap every time.
timed() {  # timed <arm> <form> <scope> <n>
    arm=$1; form=$2; scope=$3; n=$4
    conc=""
    [ "$form" = conc ] && conc="CONCURRENTLY"
    lo=1; hi=$scope
    if [ "$PRED" = eq ] && [ "$scope" = 1 ]; then
        where="id = 1"
    else
        where="id BETWEEN $lo AND $hi"
    fi
    {
        fixture
        echo "SET synchronous_commit = off;"
        # Warm the plan cache / any per-session state before the clock starts.
        i=0; while [ $i -lt 3 ]; do
            echo "REFRESH MATERIALIZED VIEW $conc vv_mv WHERE $where;"
            i=$((i+1)); done
        # printf, not echo: this script is #!/bin/sh, and dash's echo
        # interprets backslash escapes, so `echo "\\timing on"` sends a TAB
        # followed by "iming on".  psql then never turns timing on, every block
        # reports no samples, and the table fills with 0.000 -- which is what
        # happened on the first run of this script.
        printf '%s\n' '\timing on' 
        i=0; while [ $i -lt "$n" ]; do
            echo "REFRESH MATERIALIZED VIEW $conc vv_mv WHERE $where;"
            i=$((i+1)); done
    } | feed "$arm" 2>&1 \
      | awk '/^Time:/ { v[n++] = $2 }
             END { if (!n) { print "NA"; exit }
                   for (i=0;i<n;i++) for (j=i+1;j<n;j++)
                     if (v[j]<v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
                   printf "%.3f", (n%2) ? v[(n-1)/2] : (v[n/2-1]+v[n/2])/2 }'
}

median() {
    awk '{ v[n++] = $1 }
         END { if (!n) { print "NA"; exit }
               for (i=0;i<n;i++) for (j=i+1;j<n;j++)
                 if (v[j]<v[i]) { t=v[i]; v[i]=v[j]; v[j]=t }
               printf "%.3f", (n%2) ? v[(n-1)/2] : (v[n/2-1]+v[n/2])/2 }'
}

case "$mode" in
speed)
    echo "== current against c8beb05 (the posted patch), -O2 assertions off"
    echo "   scale=$SCALE, PRED=$PRED, $ROUNDS rounds, arms alternated with the order flipped,"
    echo "   fixture rebuilt before every timed block on both sides"
    echo
    printf '%-6s %-6s %10s %10s %10s\n' form scope v2_ms cur_ms change
    for form in conc bare; do
        for scope in 1 10 100 1000 10000; do
            case $scope in
            1|10)   n=40 ;;
            100)    n=20 ;;
            1000)   n=10 ;;
            10000)  n=4  ;;
            esac
            : > /tmp/vv-v2.raw; : > /tmp/vv-cur.raw
            r=1
            while [ "$r" -le "$ROUNDS" ]; do
                if [ $((r % 2)) -eq 1 ]; then order="v2 cur"; else order="cur v2"; fi
                for arm in $order; do
                    timed "$arm" "$form" "$scope" "$n" >> "/tmp/vv-$arm.raw"
                    echo >> "/tmp/vv-$arm.raw"
                done
                r=$((r + 1))
            done
            v2m=$(median < /tmp/vv-v2.raw); curm=$(median < /tmp/vv-cur.raw)
            chg=$(awk -v a="$v2m" -v b="$curm" \
                'BEGIN { if (a+0==0 || a=="NA" || b=="NA") print "NA";
                         else printf "%+.1f%%", 100*(a-b)/a }')
            printf '%-6s %-6s %10s %10s %10s\n' "$form" "$scope" "$v2m" "$curm" "$chg"
        done
    done
    echo
    echo "   change is how much cheaper the CURRENT refresh is; + is current faster."
    ;;
correct)
    # The shapes v2 gets wrong.  Each is a fix recorded in ISSUES.md, driven
    # through the real command and read back, on both trees and under BOTH
    # spellings -- because the spelling selects a different ALGORITHM in each
    # tree and running one spelling would silently test the wrong path.
    #
    #   v2:      qual && !concurrent  ->  direct modification.  So BARE is the
    #            path B4 and A4 are defects of, and CONCURRENTLY is match/merge.
    #   current: routing is on the unique-index count, so with one unique index
    #            BOTH spellings reach direct modification.
    #
    # That was not a hypothetical.  The first version of this mode drove
    # CONCURRENTLY on both, which on v2 is match/merge, and every case came back
    # green -- v2 looking correct because the buggy path was never entered.
    echo "== shapes where the two trees disagree about the ANSWER"
    echo "   (run before reading any speed number: v2 is faster on these because"
    echo "    it does less work than correctness requires)"
    echo
    echo "   v2 routes BARE to direct modification and CONCURRENTLY to match/merge;"
    echo "   current routes both to direct modification.  Both spellings shown."
    echo
    rm -f /tmp/vv-correct.raw
    for arm in v2 cur; do
      for sp in bare conc; do
        conc=""; [ "$sp" = conc ] && conc="CONCURRENTLY"
        {
            cat <<SQL
DROP MATERIALIZED VIEW IF EXISTS c_nk; DROP TABLE IF EXISTS c_nkb;
CREATE TABLE c_nkb(k int, v int);
INSERT INTO c_nkb VALUES (1,10), (NULL,20), (NULL,30);
CREATE MATERIALIZED VIEW c_nk AS SELECT k, v FROM c_nkb;
CREATE UNIQUE INDEX ON c_nk(k);
REFRESH MATERIALIZED VIEW $conc c_nk WHERE k IS NULL OR k = 1;
REFRESH MATERIALIZED VIEW $conc c_nk WHERE k IS NULL OR k = 1;
SELECT 'B4_nullable_key ' || count(*) || ' rows (3 ok)' FROM c_nk;

DROP MATERIALIZED VIEW IF EXISTS c_dr; DROP TABLE IF EXISTS c_drb;
CREATE TABLE c_drb(id int primary key, grp int, v text);
INSERT INTO c_drb VALUES (1,1,'a'), (2,1,'b'), (3,2,'c');
CREATE MATERIALIZED VIEW c_dr AS SELECT id, grp, v FROM c_drb;
CREATE UNIQUE INDEX ON c_dr(id);
UPDATE c_drb SET grp = 2 WHERE id = 1;
REFRESH MATERIALIZED VIEW $conc c_dr WHERE grp = 1;
SELECT 'A4_scope_drift ' ||
       CASE WHEN EXISTS (SELECT 1 FROM c_dr WHERE id = 1 AND grp = 1)
            THEN 'STALE' ELSE 'ok' END;

DROP MATERIALIZED VIEW IF EXISTS c_inc; DROP TABLE IF EXISTS c_incb;
CREATE TABLE c_incb(id int primary key, v int);
INSERT INTO c_incb VALUES (1,10), (2,20);
CREATE MATERIALIZED VIEW c_inc AS SELECT id, v FROM c_incb;
CREATE UNIQUE INDEX ON c_inc(id) INCLUDE (v);
UPDATE c_incb SET v = 99 WHERE id = 1;
REFRESH MATERIALIZED VIEW $conc c_inc WHERE id = 1;
SELECT 'A1_include_col ' ||
       coalesce((SELECT v::text FROM c_inc WHERE id = 1), 'gone') || ' (99 ok)';
SQL
        } | feed "$arm" 2>&1 \
          | grep -E '^(B4|A4|A1)_|^ERROR' \
          | sed "s/^/$arm-$sp|/" >> /tmp/vv-correct.raw
      done
    done
    awk -F'|' '{ split($2, f, " "); key=f[1]
                 rest=substr($2, length(f[1])+2)
                 r[key,$1]=rest
                 if (!(key in seen)) { seen[key]=1; order[n++]=key } }
         END { printf "%-18s %-22s %-22s %-22s %s\n",
                      "case","v2 bare (directmod)","v2 conc (match/merge)",
                      "cur bare","cur conc"
               for (i=0;i<n;i++) { k=order[i]
                 printf "%-18s %-22s %-22s %-22s %s\n", k,
                        r[k,"v2-bare"], r[k,"v2-conc"],
                        r[k,"cur-bare"], r[k,"cur-conc"] } }' /tmp/vv-correct.raw
    ;;
*)  echo "unknown mode $mode" >&2; exit 2 ;;
esac
