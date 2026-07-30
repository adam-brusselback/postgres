#!/bin/sh
#
# Measure which known bugs the CONCURRENT fuzzer detects.
#
#   ./calibrate-fuzz.sh [MUT ...]        default: the four the oracle misses
#
# calibrate.sh does this for the single-session oracle.  This is the same
# exercise for fuzz.sh, and it exists for the same reason: a detector nobody has
# watched catch anything is indistinguishable from one that cannot.  fuzz.sh
# passing on pristine code is not evidence that it works -- the first version of
# matview-where-snapshot.spec also passed on pristine code, and it passed under
# the mutation it was written to catch as well.
#
# The bar here is higher than for the oracle.  These four mutations are the ones
# the oracle provably cannot see, so if this instrument misses them too, nothing
# in the tree sees them and the rewrite has no guard at all.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$DIR/../../.." && pwd)
PORT=${PORT:-5610}
DB=${DB:-postgres}
PREFIX=${PREFIX:-/home/user/pgsql-opt}
ITER=${ITER:-40}
SPIN=${SPIN:-400}

MUTS=${*:-M1 M2 M3 M6}

printf '%-8s %-5s %-9s %6s  %s\n' MUT ISSUE VERDICT SECS 'MODE THAT FIRED'
printf '%s\n' '---------------------------------------------------------------'

run_fuzz() {
    su pgtest -c "PSQL_BIN=$PREFIX/bin/psql ITER=$ITER SPIN=$SPIN \
        $DIR/fuzz.sh $PORT $DB" > "$1" 2>&1
}

for m in $MUTS pristine; do
    if [ "$m" = pristine ]; then
        issue='-'
    else
        issue=$(cd "$SRC" && ./src/test/matview_where_stress/mutations.py --list \
                | awk -v m="$m" '$1==m {print $2}')
    fi

    (cd "$SRC" && ./src/test/matview_where_stress/mutations.py "$m") > /dev/null
    "$DIR/rebuild.sh" --source > /tmp/pgt/fz-build.log 2>&1 \
        || { printf '%-8s %-5s %-9s %6s  %s\n' "$m" "$issue" BUILDFAIL - ''; continue; }

    start=$(date +%s)
    run_fuzz "/tmp/pgt/fz-$m.log" && rc=0 || rc=$?

    case "$rc" in
    0)  verdict=$([ "$m" = pristine ] && echo QUIET || echo MISSED)
        detail='' ;;
    2)  # The fixture did not build, so the run never happened.  Never report
        # this as a catch: a green-looking nonzero exit is how a detector
        # convinces you it works when it has not run at all.
        verdict=SETUPFAIL
        detail=$(grep -m1 -i '^ERROR' "/tmp/pgt/fz-$m.log" | cut -c1-48) ;;
    *)  verdict=$([ "$m" = pristine ] && echo 'FALSE POS' || echo CAUGHT)
        detail=$(grep -B2 '^  FAIL' "/tmp/pgt/fz-$m.log" \
                 | grep '^== ' | sed 's/^== \([a-z0-9]*\):.*/\1/' | tr '\n' '+')
        detail="$detail $(grep -m1 '^  FAIL' "/tmp/pgt/fz-$m.log" | sed 's/^  FAIL: //')" ;;
    esac

    # Every mode must have reached a verdict, or a mode that silently stopped
    # running looks exactly like a mode that found nothing.
    ran=$(grep -c '^  \(ok\|FAIL\|SKIP\)' "/tmp/pgt/fz-$m.log" 2>/dev/null || true)
    [ "$rc" = 2 ] || [ "$ran" -eq 3 ] || detail="$detail [only $ran/3 modes ran]"
    printf '%-8s %-5s %-9s %6s  %s\n' "$m" "$issue" "$verdict" \
        "$(( $(date +%s) - start ))" "$detail"
done

echo
echo "== restoring pristine"
(cd "$SRC" && ./src/test/matview_where_stress/mutations.py pristine) > /dev/null
"$DIR/rebuild.sh" --source > /dev/null
