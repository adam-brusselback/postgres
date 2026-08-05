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
REFRESHERS=${REFRESHERS:-4}

# B4 is here on purpose and is not one of the four the oracle misses: it is a
# DATA mutation that leaves stale rows without deadlocking, which is the only
# thing that can exercise the end-state assertion p2/p3 gained.  That assertion
# has never been seen to fail, and an assertion nobody has watched fail is the
# thing this whole directory exists to distrust.
MUTS=${*:-M1 M2 M3 M6 B4}

printf '%-8s %-5s %-9s %6s  %s\n' MUT ISSUE VERDICT SECS 'MODE THAT FIRED'
printf '%s\n' '---------------------------------------------------------------'

run_fuzz() {
    su pgtest -c "PSQL_BIN=$PREFIX/bin/psql ITER=$ITER REFRESHERS=$REFRESHERS \
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
    # MODES is the count fuzz.sh actually has.  This was hardcoded to 3 and went
    # stale the moment `nest` was added -- which would have appended
    # "[only 4/3 modes ran]" to every row rather than failing, i.e. a staleness
    # check that itself goes stale.  Derive it.
    want=$(grep -c '^mode_[a-z0-9]*() {' "$DIR/fuzz.sh")
    ran=$(grep -c '^  \(ok\|FAIL\|SKIP\)' "/tmp/pgt/fz-$m.log" 2>/dev/null || true)
    [ "$rc" = 2 ] || [ "$ran" -ge "$want" ] || detail="$detail [only $ran/$want modes ran]"
    printf '%-8s %-5s %-9s %6s  %s\n' "$m" "$issue" "$verdict" \
        "$(( $(date +%s) - start ))" "$detail"
done

echo
echo "== restoring pristine"
(cd "$SRC" && ./src/test/matview_where_stress/mutations.py pristine) > /dev/null
"$DIR/rebuild.sh" --source > /dev/null
