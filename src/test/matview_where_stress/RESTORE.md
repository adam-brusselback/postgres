# Restore points

Commits worth being able to come back to, with the build that produced the
numbers attached to them.  Branch-local; delete with this directory.

There is a local annotated tag for each of these, but **the tags are not on the
remote** — this branch's git proxy accepts branch refs and rejects tag refs, so
a tag does not survive the container.  The SHAs below are the durable record.

Rebuild with `rebuild.sh --full` after checking one out.  `autodepend` is empty
in this tree, so a configure change relinks stale objects and exits 0; `--full`
runs `make clean` first, and then asks the running server what it was actually
compiled with instead of trusting make.

---

## `phase-2.1b` — `1d58a82`

Phase 2.1 complete, measured, and injection-tested.  The state to return to
after any experiment on older code.

| commit | what |
|---|---|
| `9a5195b` | 2.1: the read side evaluates the view from its Query tree |
| `608b3ad` | `matview_where_inject`, covering all three SQL generators |
| `0ef1fed` | mutation corpus repaired; `Q1`-`Q3` added |
| `1d58a82` | PLAN.md 2.1b |

Build, as reported by the running server rather than by make:

    ./configure --prefix=/home/user/pgsql-opt --without-icu CFLAGS=-O2
    debug_assertions = off
    no --enable-injection-points

Note that build has assertions and injection points **off**, because it exists
to be benchmarked.  The `injection_points` suite cannot run against it; restore
`-O2 --enable-cassert --enable-injection-points` before going back to
development.

Benchmark data for this point is in `bench_result` under `run_label = 'p21-O2'`.
That lives in the database, not in the repository, and does not survive the
container either — `bench/report.sql` prints it, and the summary that mattered
is in PLAN.md 2.1b.

---

## `c8beb05` — the patch as posted to -hackers

Not a restore point so much as the reference: the original implementation,
before any of the fixes in ISSUES.md.  Useful for answering "was this ever
actually wrong" rather than "is it right now", which is a question that keeps
coming up and that only the original code can answer.

Build it in a worktree rather than by checking it out in place:

    git worktree add /home/user/pg-orig c8beb05
