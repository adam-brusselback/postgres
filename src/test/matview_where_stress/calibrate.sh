#!/bin/sh
#
# Measure which known bugs the safety oracle actually detects.
#
#   ./calibrate.sh --baseline      record the pristine divergence vector
#   ./calibrate.sh [MUT ...]       apply each mutation, rebuild, re-run, compare
#
# PLAN.md 1.1c: "A fuzzer nobody has seen catch anything is the same defect as a
# test that cannot fail, one level up."  This is what turns that into a number.
#
# The pass/fail rule
# ------------------
# A mutation is CAUGHT if any (shape, form) cell diverges MORE than it does on
# pristine code, or if the run fails outright.
#
# Deliberately not "any nonzero divergence".  Six of the eighteen shapes are
# expected to diverge -- they are the unsafe-predicate cases, that is what they
# are there to show -- and one more (distincton) diverges because its view
# definition is non-deterministic by construction.  A rule that ignores this has
# to carry a hand-maintained list of which shapes to look at, and the list that
# existed in checkall.sh omitted the single shape whose behaviour was
# unexplained.  Comparing against a recorded baseline needs no such list and
# cannot drift out of step with the cases.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$DIR/../../.." && pwd)
PORT=${PORT:-5610}
DB=${DB:-postgres}
PREFIX=${PREFIX:-/home/user/pgsql-opt}
BASELINE=${BASELINE:-$DIR/calibrate.baseline}
PSQL_BIN="$PREFIX/bin/psql"

# The oracle's verdict as a stable, sorted, machine-comparable vector.
#
# diverged AND errs.  exh_driver.sql catches per-mutation exceptions into a
# separate errs column rather than counting them as divergence, so a bug that
# turns every refresh into an ERROR moves `errs` and leaves `diverged` alone.
# Comparing only `diverged` would have called that MISSED -- the detector would
# have been looking straight at the failure and reporting nothing.
vector() {
    su pgtest -c "$PSQL_BIN -p $PORT -d $DB -Atc \
        \"SELECT id||'|'||form||'|'||diverged||'|'||errs FROM exh_result ORDER BY id, form\"" \
        2>/dev/null
}

# exh_result is a TABLE, and a run that dies partway leaves the PREVIOUS run's
# rows sitting in it.  Reading those and finding them unchanged looks exactly
# like "the mutation was not detected" -- a false MISSED, which is the single
# worst result this harness could produce, because it would retire a bug as
# invisible when nothing had actually looked at it.  So: drop the table before
# every run, and treat a short vector afterwards as "no verdict" rather than as
# a clean one.
run_oracle() {
    su pgtest -c "$PSQL_BIN -p $PORT -d $DB -qc 'DROP TABLE IF EXISTS exh_result'" \
        > /dev/null 2>&1
    su pgtest -c "PSQL_BIN=$PSQL_BIN $DIR/safety/run.sh $PORT $DB" > "$1" 2>&1
}

CELLS=$(wc -l < "${BASELINE:-/dev/null}" 2>/dev/null || echo 0)

if [ "${1:-}" = "--baseline" ]; then
    echo "== restoring pristine"
    (cd "$SRC" && ./src/test/matview_where_stress/mutations.py pristine)
    "$DIR/rebuild.sh" --source > /dev/null
    echo "== running oracle on pristine code"
    start=$(date +%s)
    run_oracle /tmp/pgt/cal-baseline.log || { echo "BASELINE RUN FAILED" >&2; exit 1; }
    echo "   $(( $(date +%s) - start ))s"
    vector > "$BASELINE"
    echo "== baseline written to $BASELINE ($(wc -l < "$BASELINE") cells)"
    awk -F'|' '$3 != 0 {print "   diverges on pristine: "$1" ("$2") = "$3}' "$BASELINE"
    exit 0
fi

[ -f "$BASELINE" ] || { echo "no baseline; run --baseline first" >&2; exit 1; }

MUTS=${*:-$(cd "$SRC" && ./src/test/matview_where_stress/mutations.py --list | awk '{print $1}')}

printf '%-6s %-5s %-8s %-9s %6s  %s\n' MUT ISSUE NEEDS VERDICT SECS DETAIL
printf '%s\n' '--------------------------------------------------------------------'

for m in $MUTS; do
    meta=$(cd "$SRC" && ./src/test/matview_where_stress/mutations.py --list \
           | awk -v m="$m" '$1==m {print $2" "$3}')
    issue=$(echo "$meta" | cut -d' ' -f1)
    needs=$(echo "$meta" | cut -d' ' -f2)

    (cd "$SRC" && ./src/test/matview_where_stress/mutations.py "$m") > /dev/null
    if ! "$DIR/rebuild.sh" --source > /tmp/pgt/cal-build.log 2>&1; then
        printf '%-6s %-5s %-8s %-9s %6s  %s\n' "$m" "$issue" "$needs" BUILDFAIL - \
            "see /tmp/pgt/cal-build.log"
        continue
    fi

    start=$(date +%s)
    run_oracle "/tmp/pgt/cal-$m.log" || true
    got=$(vector)
    ngot=$(printf '%s' "$got" | grep -c '|' || true)

    if [ "$ngot" -lt "$CELLS" ]; then
        # The oracle did not finish, so there is no differential verdict to
        # give.  Report that separately from CAUGHT: a mutation that makes
        # every refresh raise an error is not a silent-corruption risk, and
        # counting it as "detected" would flatter the detector.  The bugs worth
        # measuring are the ones that leave the run green and the data wrong.
        verdict=ERRORED
        detail="aborted at $ngot/$CELLS cells: $(grep -m1 -io 'ERROR:.*' "/tmp/pgt/cal-$m.log" | cut -c1-52)"
    else
        # CAUGHT when any cell diverges or errors MORE than it does on pristine.
        detail=$(printf '%s\n' "$got" | awk -F'|' -v base="$BASELINE" '
            BEGIN { while ((getline l < base) > 0) {
                        split(l,a,"|"); d[a[1]"|"a[2]]=a[3]; e[a[1]"|"a[2]]=a[4] } }
            { k=$1"|"$2
              if ($3+0 > d[k]+0) { n++; if (n<=2) s=s (s?", ":"") $1"/"$2" div "d[k]"->"$3 }
              if ($4+0 > e[k]+0) { n++; if (n<=2) s=s (s?", ":"") $1"/"$2" err "e[k]"->"$4 } }
            END { if (n) printf "%d cell%s worse: %s", n, (n>1?"s":""), s }')
        verdict=$([ -n "$detail" ] && echo CAUGHT || echo MISSED)
    fi
    secs=$(( $(date +%s) - start ))

    printf '%-6s %-5s %-8s %-9s %6s  %s\n' "$m" "$issue" "$needs" "$verdict" "$secs" "$detail"
done

echo
echo "== restoring pristine"
(cd "$SRC" && ./src/test/matview_where_stress/mutations.py pristine) > /dev/null
"$DIR/rebuild.sh" --source > /dev/null
