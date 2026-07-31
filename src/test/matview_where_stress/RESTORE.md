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

## Navigating the history

267 commits since the patch was posted to -hackers. **Ten of them touch
`src/backend/commands/matview.c`** — that is the entire feature, and it fits on
one screen. 80 touch this directory, which is deleted before posting. What feels
unnavigable is the scaffolding sitting between the ten.

Use paths, and **anchor at `c8beb05`** — the posted patch. Unanchored, these
commands reach back into upstream PostgreSQL history and return hundreds of
irrelevant commits:

    # the feature itself — ten commits, the whole story
    git log --oneline c8beb05..HEAD -- src/backend/commands/matview.c

    # everything shippable: code, grammar, tests, docs
    git log --oneline c8beb05..HEAD -- src/backend src/include src/test/regress \
                         src/test/isolation src/test/modules doc contrib

    # this directory alone
    git log --oneline c8beb05..HEAD -- src/test/matview_where_stress

Two of those ten are worth knowing by name. `0c16eaf` is the original
use-after-free fix in the plan cache — the one ISSUES.md B14 has since reopened,
because it deferred the free to "the next refresh" and a nested refresh is the
next refresh. `9a5195b` is Phase 2.1, where the read side stopped being text.

**The path filter is the reliable view; the prefix is only a convenience.**
Going forward, `matview stress:` marks a commit touching nothing but this
directory and `matview:` marks one that does not — but 33 of the older commits
predate that convention and are research-only while carrying no prefix, so
`--grep` alone will mislead. Rewriting pushed history to fix that is not worth
it; the path filter already gives the right answer for every commit.

### What the submission actually gets

Not this branch. -hackers receives a patch series generated with
`git format-patch` from a curated, squashed set with this directory removed —
probably four to six patches split by subsystem (grammar, `matview.c`, tests,
docs). So there is no reason to shape the development history toward
submission, and every reason not to curate it twice: that happens once, at
Phase 4/7.

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
