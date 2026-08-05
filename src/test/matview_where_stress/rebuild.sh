#!/bin/sh
#
# Rebuild the scratch cluster, and prove the rebuild actually happened.
#
#   ./rebuild.sh --full  [configure args ...]   reconfigure from scratch
#   ./rebuild.sh --source                       recompile changed .c only
#
# Why this exists
# ---------------
# `autodepend` is empty in this tree, so there are no .deps/*.Po files and no
# object depends on any header.  Two consequences, and they are not the same:
#
#   editing a .c file      make rebuilds that object.  Correct, and fast.
#   editing configure      make rebuilds NOTHING.  It relinks stale objects
#                          against the new pg_config.h and exits 0.
#
# The second case produced two silently wrong builds -- a "-O2" build that was
# not optimised, and an "--enable-injection-points" build with no injection
# points -- each of which was believed for hours because make said nothing.
#
# So: a configure change means `make clean`, always.  And because a build that
# lies exits 0, this script does not trust exit codes.  It asks the running
# server what it was compiled with, which is the only answer that cannot be
# stale.
set -eu

PREFIX=${PREFIX:-/home/user/pgsql-opt}
PGDATA=${PGDATA:-/home/pgtest/pgdata-opt}
PORT=${PORT:-5610}
LOG=${LOG:-/home/pgtest/pg-opt.log}
JOBS=${JOBS:-8}
SRC=$(cd "$(dirname "$0")/../../.." && pwd)

mode=${1:-}
[ -n "$mode" ] || { echo "usage: $0 --full [configure args] | --source" >&2; exit 2; }
shift

cd "$SRC"

case "$mode" in
--full)
    # Preserve the current flags when none are given, so "rebuild it the same
    # way" does not silently become "rebuild it the default way".
    if [ $# -eq 0 ]; then
        set -- $(sed -n 's/^#define CONFIGURE_ARGS "\(.*\)"$/\1/p' \
                 src/include/pg_config.h | tr -d "'")
        echo "== reusing current flags: $*"
    fi
    echo "== configure $*"
    su pgtest -c "cd $SRC && ./configure $*" > /tmp/rebuild-conf.log 2>&1 \
        || { tail -20 /tmp/rebuild-conf.log; echo "CONFIGURE FAILED" >&2; exit 1; }
    echo "== make clean (mandatory: no header deps in this tree)"
    su pgtest -c "cd $SRC && make -s clean" > /tmp/rebuild-clean.log 2>&1
    ;;
--source)
    ;;
*)
    echo "unknown mode $mode" >&2; exit 2 ;;
esac

echo "== make -j$JOBS install"
su pgtest -c "cd $SRC && make -s -j$JOBS install" > /tmp/rebuild-make.log 2>&1 \
    || { tail -30 /tmp/rebuild-make.log; echo "BUILD FAILED" >&2; exit 1; }

echo "== restart"
su pgtest -c "$PREFIX/bin/pg_ctl -D $PGDATA -m fast restart -l $LOG -o '-p $PORT' -w" \
    > /tmp/rebuild-ctl.log 2>&1 \
    || { tail -20 "$LOG"; echo "RESTART FAILED" >&2; exit 1; }

# ---- verification.  Nothing above is believed without these. ----
fail=0

# 1. No object older than pg_config.h.  This is the stale-build detector: after
#    a clean build every object is newer, and a skipped `make clean` shows up
#    here as a nonzero count rather than as a mystery three hours later.
stale=$(find src/backend src/bin -name '*.o' ! -newer src/include/pg_config.h 2>/dev/null | wc -l)
if [ "$mode" = "--full" ] && [ "$stale" -ne 0 ]; then
    echo "  STALE: $stale objects predate pg_config.h" >&2
    find src/backend src/bin -name '*.o' ! -newer src/include/pg_config.h 2>/dev/null | head -5 >&2
    fail=1
fi

# 2. Ask the *running server* what it was configured with.  The tree's
#    pg_config.h describes what configure last wrote; this describes what is
#    actually answering queries on $PORT.  Only the second one matters.
running=$(su pgtest -c "$PREFIX/bin/psql -p $PORT -d postgres -Atc \
    \"SELECT setting FROM pg_config() WHERE name = 'CONFIGURE'\"" 2>/dev/null || true)
[ -n "$running" ] || { echo "  could not query the running server" >&2; fail=1; }

echo "  running server CONFIGURE: $running"
echo "  assertions: $(su pgtest -c "$PREFIX/bin/psql -p $PORT -d postgres -Atc 'SHOW debug_assertions'" 2>/dev/null)"

# 3. Every requested flag is present in what the server reports.
if [ "$mode" = "--full" ]; then
    for want in "$@"; do
        case "$want" in
        --*|CFLAGS=*)
            case "$running" in
            *"$want"*) ;;
            *) echo "  MISSING from running server: $want" >&2; fail=1 ;;
            esac ;;
        esac
    done
fi

[ $fail -eq 0 ] || { echo "REBUILD VERIFICATION FAILED" >&2; exit 1; }
echo "== ok"
