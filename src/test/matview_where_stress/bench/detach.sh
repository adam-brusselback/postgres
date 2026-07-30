#!/bin/sh
#
# Run run.sh so that it outlives the shell that started it.
#
#   ./detach.sh <logfile> [run.sh options...]
#
# A sweep takes tens of minutes.  Anything started as an ordinary child of the
# calling shell dies when that shell's session goes away, and a benchmark that
# dies two thirds of the way through leaves a partial sweep that is worse than
# no sweep -- the combinations that did land are not comparable with the ones
# that did not, and nothing in bench_result says which is which.
#
# setsid puts the run in its own session, so it is no longer reachable by a
# signal aimed at the caller's process group; </dev/null and the redirects
# detach it from the caller's terminal.  This is what pg_ctl does for the
# postmaster, and for the same reason.
#
# Progress is readable at any time from the log, or from bench_result, which
# run.sh writes one row at a time rather than at the end.
set -e

LOG=$1; shift
DIR=$(dirname "$0")
[ -n "$LOG" ] || { echo "usage: $0 <logfile> [run.sh options...]" >&2; exit 2; }

setsid nohup "$DIR/run.sh" "$@" >"$LOG" 2>&1 </dev/null &
sleep 1
echo "started: $LOG"
