#!/bin/sh
#
# Poor man's profiler: sample a running backend's call stack with gdb.
#
#   ./pmp.sh <pid> <samples> [outfile]
#
# Why gdb rather than perf
# ------------------------
# perf is not installed here and the distro only carries linux-tools for 6.8.x
# against a 6.18.5 kernel.  gdb is present, ptrace is unrestricted, and the
# server binary is not stripped -- and crucially, gcc emits .eh_frame on x86-64
# whether or not you build with -g, so gdb can walk the stack of the ordinary
# -O2 build with no frame pointers and no debug info.
#
# That matters more than convenience: it means the profile is taken on the SAME
# binary that produced the benchmark numbers.  Rebuilding with -g and
# -fno-omit-frame-pointer to please a profiler would have given a build whose
# timings no longer match the run being explained, which is the mistake this
# directory's README exists to prevent.
#
# What it costs
# -------------
# Each attach stops the process for a few milliseconds and takes ~100-200ms
# wall clock, so this samples at roughly 5-10 Hz -- perf does thousands.  For a
# backend doing the same refresh over and over that is fine, because samples
# land at uniformly random points in the work; it is useless for anything that
# happens once.  Treat the output as "where does this spend its time on
# average", never as a timeline.
#
# The stop is real, so the process being sampled runs measurably slower while
# this is attached.  Do not read latency numbers out of a run being profiled.
set -eu

PID=${1:-}
N=${2:-200}
OUT=${3:-/tmp/pmp.stacks}

[ -n "$PID" ] || { echo "usage: $0 <pid> <samples> [outfile]" >&2; exit 2; }
kill -0 "$PID" 2>/dev/null || { echo "no such process: $PID" >&2; exit 1; }

: > "$OUT"
i=0
missed=0
while [ "$i" -lt "$N" ]; do
    i=$((i + 1))
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "process $PID gone after $i samples" >&2
        break
    fi
    # -batch detaches on exit.  Failures are expected and survivable: the
    # backend may be between statements, or gdb may lose the race.
    if timeout 10 gdb -p "$PID" -batch -ex "bt" 2>/dev/null \
         | grep '^#' >> "$OUT" 2>/dev/null; then
        echo "//SAMPLE" >> "$OUT"
    else
        missed=$((missed + 1))
    fi
done

got=$(grep -c '^//SAMPLE' "$OUT" 2>/dev/null || echo 0)
echo "samples: $got captured, $missed missed -> $OUT"
