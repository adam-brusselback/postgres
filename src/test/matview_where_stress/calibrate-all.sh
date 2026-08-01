#!/bin/sh
#
# Every mutation, every instrument, both directions.
#
#   ./calibrate-all.sh [MUT ...]      default: the whole corpus
#
# calibrate.sh drives the differential oracle and calibrate-fuzz.sh drives the
# concurrent fuzzer.  Between them they cover the `data` and `concur` mutations
# and nothing else, which left the `cache`, `privs` and `inject` third of the
# corpus never verified in either direction -- their instrument is the
# regression suite, and no harness ran it.  This runs all three against one
# build per mutation and prints the matrix.
#
# The two directions, and why both are needed
# -------------------------------------------
# A detector that never fires and a detector that cannot fire look identical
# from the outside.  Four instruments in this directory have now been caught
# reporting success while measuring nothing -- mutations.py against the code it
# mutates (B23), profile.py against a code block that moved, calibrate-fuzz.sh
# against its own hardcoded mode count, and fuzz.sh's error counters against a
# psql message prefix.  Every one of them was found the same way: by running it
# against a build where the bug was known to be present.
#
# So each row is measured twice.  Bug present: does anything fire?  Bug absent
# (the pristine row): does anything fire that should not?  A `benign` mutation
# is the interesting third case -- it is verified to change nothing observable,
# so ANY instrument firing on it is a false positive and a defect in the
# instrument, not a catch.
#
# What counts as caught
# ---------------------
# regress   any matview_where* file whose output differs from its expected file.
#           The suite is the specification, so a diff is a behaviour change.
# oracle    any (shape, form) cell diverging or erroring MORE than the recorded
#           pristine baseline.  Same rule calibrate.sh uses, and for the same
#           reason: six shapes diverge on pristine by design.
# fuzz      any mode failing.  fuzz.sh exits nonzero and names the mode.
# specs     any isolation or injection-point spec failing.  Needs a tree built
#           --enable-injection-points; reported NOSPEC when it is not.
#
# A mutation is CAUGHT if any instrument fires, and the matrix says which -- a
# bug caught only by the suite and not by the oracle is a different risk from
# one caught by both, and the point of a matrix rather than a verdict column is
# that it says so.
set -eu

DIR=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$DIR/../../.." && pwd)
PORT=${PORT:-5610}
DB=${DB:-postgres}
PREFIX=${PREFIX:-/home/user/pgsql-opt}
BASELINE=${BASELINE:-$DIR/calibrate.baseline}
ITER=${ITER:-15}
REFRESHERS=${REFRESHERS:-4}
OUT=${OUT:-/tmp/pgt/calall}
PSQL_BIN="$PREFIX/bin/psql"
RUNAS=${RUNAS:-pgtest}

mkdir -p "$OUT"

# A mutation that crashes the server kills this script mid-table, and until C3
# did exactly that the tree was left mutated behind it -- which is the worst
# possible residue, because everything run afterwards is measuring the wrong
# code and looks fine.  Restore on any exit, not just the happy one.
cleanup() {
    (cd "$SRC" && ./src/test/matview_where_stress/mutations.py pristine) >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

# The server does not survive every mutation, and a crashed one poisons every
# instrument after it with "the database system is in recovery mode" -- which
# reads as a quiet instrument, not as a catch.  Wait for it to come back, and
# say plainly if it does not.
server_live() {
    su "$RUNAS" -c "$PSQL_BIN -p $PORT -d $DB -Atc 'SELECT 1'" >/dev/null 2>&1
}
wait_for_server() {
    i=0
    while [ $i -lt 30 ]; do
        server_live && return 0
        i=$((i + 1))
        sleep 2
    done
    return 1
}
# pg_regress runs as pgtest and writes its outputdir itself.  Root-owned and it
# bails out before running a single test -- see the liveness check below, which
# exists because exactly that happened and was reported as "quiet".
chmod 777 "$OUT" 2>/dev/null || true
CELLS=$(wc -l < "$BASELINE" 2>/dev/null || echo 0)
[ "$CELLS" -gt 0 ] || { echo "no baseline at $BASELINE; run calibrate.sh --baseline" >&2; exit 1; }

REGRESS_TESTS="matview_where matview_where_cache matview_where_privs matview_where_contract matview_where_inject"
ISOLATION_SPECS="matview-where-serialize matview-where-deadlock matview-where-lockorder matview-where-insertorder"
PGHOST=${PGHOST:-/tmp}
export PGHOST

# ---- instrument 1: the regression suite -------------------------------------
# Its own database per run, because a mutation that corrupts data would
# otherwise leave it behind for the next mutation to be blamed for.
run_regress() {
    su pgtest -c "PATH=$PREFIX/bin:\$PATH PGPORT=$PORT \
        $PREFIX/lib/pgxs/src/test/regress/pg_regress \
          --bindir=$PREFIX/bin --inputdir=$SRC/src/test/regress \
          --outputdir=$OUT/reg --port=$PORT --dbname=calall_regress \
          $REGRESS_TESTS" > "$1" 2>&1
}
regress_failed() { grep -c '^not ok' "$1" 2>/dev/null || true; }
# LIVENESS.  Zero failures and zero passes is not a pass, it is a run that never
# happened -- and the first version of this harness reported it as "quiet" for
# A4, a mutation that makes every refresh die of a unique violation.  pg_regress
# could not create its output directory, printed "Bail out!", and produced no
# test lines at all.  So count what DID run and refuse a verdict below the
# expected number.  Same rule calibrate.sh applies to a short oracle vector and
# calibrate-fuzz.sh to a setup failure; this file needed its own.
regress_ran()    { grep -cE '^(not )?ok ' "$1" 2>/dev/null || true; }
REGRESS_N=$(set -- $REGRESS_TESTS; echo $#)

# ---- instrument 2: the differential oracle ----------------------------------
vector() {
    su pgtest -c "$PSQL_BIN -p $PORT -d $DB -Atc \
        \"SELECT id||'|'||form||'|'||diverged||'|'||errs FROM exh_result ORDER BY id, form\"" \
        2>/dev/null
}
run_oracle() {
    su pgtest -c "$PSQL_BIN -p $PORT -d $DB -qc 'DROP TABLE IF EXISTS exh_result'" >/dev/null 2>&1
    su pgtest -c "PSQL_BIN=$PSQL_BIN $DIR/safety/run.sh $PORT $DB" > "$1" 2>&1
}

# ---- instrument 4: the isolation and injection-point specs ------------------
# S1's declared detector is matview-where-prune-gap.spec, and the first version
# of this harness did not run it -- so S1 came back UNCAUGHT from an instrument
# that was never pointed at it.  Verified afterwards by hand: with S1 applied
# the spec fails, on pristine it passes.  That is the row this instrument
# exists to stop being wrong.
#
# The injection-point specs need a tree configured --enable-injection-points,
# and the benchmark build deliberately is NOT, because R26-R29 were measured
# without them and adding INJECTION_POINT() calls to the refresh path would
# make future measurements incomparable.  So this checks the capability and
# reports NOSPEC rather than passing quietly -- an absent instrument must never
# read as a clean result.
specs_capable() { grep -q '^#define USE_INJECTION_POINTS' "$SRC/src/include/pg_config.h"; }
# Two runners, because the specs live in two places and only one of them was
# being called.  The injection-point specs sit in a module that sets
# NO_INSTALLCHECK and starts its own instance; the other four are in the
# isolation schedule and run against the server on $PORT.  Calling only the
# first left matview-where-{lockorder,insertorder,serialize,deadlock} outside
# every matrix this script has printed -- four of the eleven gates that survive
# Phase 4, and the deterministic detectors for M1 and M2.  The matrix said M1
# was caught by the probabilistic fuzzer alone, which was never true.
#
# That is the same hole this script was written to close, one directory over:
# an instrument nothing called, reported as coverage because the row was quiet.
run_specs() {
    su pgtest -c "PATH=$PREFIX/bin:\$PATH make -C $SRC/src/test/modules/injection_points check" \
        > "$1" 2>&1
    mkdir -p "$OUT/iso"; chmod 777 "$OUT/iso" 2>/dev/null || true
    su pgtest -c "cd $SRC/src/test/isolation && PGPORT=$PORT PGHOST=$PGHOST \
        ./pg_isolation_regress --bindir=$PREFIX/bin --inputdir=. \
        --outputdir=$OUT/iso $ISOLATION_SPECS" >> "$1" 2>&1 || true
}
specs_ran()    { grep -cE '^(not )?ok ' "$1" 2>/dev/null || true; }
specs_failed() { grep -c '^not ok' "$1" 2>/dev/null || true; }

# ---- instrument 3: the concurrent fuzzer ------------------------------------
run_fuzz() {
    su pgtest -c "PSQL_BIN=$PSQL_BIN ITER=$ITER REFRESHERS=$REFRESHERS \
        $DIR/fuzz.sh $PORT $DB" > "$1" 2>&1
}

MUTS=${*:-$(cd "$SRC" && ./src/test/matview_where_stress/mutations.py --list | awk '{print $1}')}

printf '%-6s %-5s %-7s  %-10s %-10s %-10s %-9s  %s\n' \
       MUT ISSUE NEEDS REGRESS ORACLE FUZZ SPECS VERDICT
printf '%s\n' '-------------------------------------------------------------------------------'

for m in $MUTS pristine; do
    if [ "$m" = pristine ]; then
        issue='-'; needs='-'
    else
        meta=$(cd "$SRC" && ./src/test/matview_where_stress/mutations.py --list \
               | awk -v m="$m" '$1==m {print $2" "$3}')
        issue=$(echo "$meta" | cut -d' ' -f1)
        needs=$(echo "$meta" | cut -d' ' -f2)
    fi

    (cd "$SRC" && ./src/test/matview_where_stress/mutations.py "$m") >/dev/null
    if ! "$DIR/rebuild.sh" --source > "$OUT/build-$m.log" 2>&1; then
        printf '%-6s %-5s %-7s  %-10s %-10s %-10s %-9s  %s\n' \
               "$m" "$issue" "$needs" - - - - BUILDFAIL
        continue
    fi

    # --- regress ---
    rm -rf "$OUT/reg"
    run_regress "$OUT/reg-$m.log" && rfail=0 || rfail=1
    nreg=$(regress_failed "$OUT/reg-$m.log")
    nran=$(regress_ran "$OUT/reg-$m.log")
    if   [ "${nran:-0}" -lt "$REGRESS_N" ]; then reg="NORUN($nran/$REGRESS_N)"
    elif [ "${nreg:-0}" -gt 0 ];            then reg="FIRED($nreg)"
    else                                         reg="quiet"
    fi

    # A mutation can take the server down with it, and from here on every
    # instrument would report "the database system is in recovery mode" -- which
    # counts as quiet, i.e. as a miss, for a mutation that was caught in the
    # loudest way available.  C3 did this.  Wait for recovery, and record the
    # crash as its own verdict rather than letting it read as silence.
    crashed=0
    if ! wait_for_server; then
        printf '%-6s %-5s %-7s  %-10s %-10s %-10s %-9s  %s\n' \
               "$m" "$issue" "$needs" "$reg" - - - \
               'CAUGHT (server did not recover)'
        continue
    fi
    if grep -qE 'terminated by signal|was terminated|in recovery mode' \
            "$OUT/reg-$m.log" 2>/dev/null; then
        crashed=1
    fi

    # --- oracle ---
    run_oracle "$OUT/orc-$m.log" || true
    got=$(vector); ngot=$(printf '%s' "$got" | grep -c '|' || true)
    if [ "${ngot:-0}" -lt "$CELLS" ]; then
        orc="ABORTED"
    else
        worse=$(printf '%s\n' "$got" | awk -F'|' -v base="$BASELINE" '
            BEGIN { while ((getline l < base) > 0) {
                        split(l,a,"|"); d[a[1]"|"a[2]]=a[3]; e[a[1]"|"a[2]]=a[4] } }
            { k=$1"|"$2
              if ($3+0 > d[k]+0) n++
              if ($4+0 > e[k]+0) n++ }
            END { print n+0 }')
        if [ "$worse" -gt 0 ]; then orc="FIRED($worse)"; else orc="quiet"; fi
    fi

    # --- fuzz ---
    run_fuzz "$OUT/fz-$m.log" && ffail=0 || ffail=$?
    case "$ffail" in
    0) fz="quiet" ;;
    2) fz="SETUPFAIL" ;;   # never a catch: the fixture did not build
    *) fz="FIRED($(grep -c '^  FAIL' "$OUT/fz-$m.log" 2>/dev/null || echo 1))" ;;
    esac

    # --- specs ---
    if ! specs_capable; then
        sp="NOSPEC"
    else
        run_specs "$OUT/sp-$m.log" || true
        nsran=$(specs_ran "$OUT/sp-$m.log")
        nsp=$(specs_failed "$OUT/sp-$m.log")
        if   [ "${nsran:-0}" -lt 20 ]; then sp="NORUN($nsran)"
        elif [ "${nsp:-0}" -gt 0 ];    then sp="FIRED($nsp)"
        else                                sp="quiet"
        fi
    fi

    # --- verdict ---
    fired=0; broke=0
    case "$reg" in FIRED*) fired=1 ;; NORUN*) broke=1 ;; esac
    [ "$crashed" -eq 1 ] && fired=1
    case "$orc" in FIRED*) fired=1 ;; ABORTED*) broke=1 ;; esac
    case "$fz"  in FIRED*) fired=1 ;; SETUPFAIL*) broke=1 ;; esac
    # NOSPEC is a deliberate configuration choice, not a broken instrument, so
    # it does not void the row -- but it is printed, so a reader can see that
    # one detector was not consulted.
    case "$sp"  in FIRED*) fired=1 ;; NORUN*) broke=1 ;; esac

    if [ "$broke" -eq 1 ] && [ "$fired" -eq 0 ]; then
        # An instrument that did not run cannot vote either way, and a row that
        # says "quiet" on its behalf is the exact failure this harness exists to
        # stop.  Ordered FIRST so it cannot be shadowed by a later rule.
        verdict='!!! INSTRUMENT DID NOT RUN -- no verdict !!!'
    elif [ "$m" = pristine ]; then
        verdict=$([ "$fired" -eq 0 ] && echo QUIET || echo '*** FALSE POSITIVE ***')
    elif [ "$needs" = benign ]; then
        # Benign mutations are verified to change nothing observable.  Firing on
        # one is an instrument defect, not a detection.
        verdict=$([ "$fired" -eq 0 ] && echo 'quiet (correct)' || echo '*** FALSE POSITIVE ***')
    else
        verdict=$([ "$fired" -eq 1 ] && echo CAUGHT || echo '*** UNCAUGHT ***')
    fi

    printf '%-6s %-5s %-7s  %-10s %-10s %-10s %-9s  %s\n' \
           "$m" "$issue" "$needs" "$reg" "$orc" "$fz" "$sp" "$verdict"
done

echo
echo "== restoring pristine"
(cd "$SRC" && ./src/test/matview_where_stress/mutations.py pristine) >/dev/null
"$DIR/rebuild.sh" --source >/dev/null
echo "logs in $OUT"
