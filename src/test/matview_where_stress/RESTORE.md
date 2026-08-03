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

Two of those are worth knowing by name. `0c16eaf` is the original
use-after-free fix in the plan cache — the one ISSUES.md B14 reopened, because it
deferred the free to "the next refresh" and a nested refresh is the next refresh;
the second fix refuses the shared cache at maintenance depth > 0. `9a5195b` is
Phase 2.1, where the read side stopped being text.

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

## `a5672af` — Phase 3's specialisations, decided

The point at which the two optimisations that survive are in and the two that
do not are recorded as rejections rather than as ideas.  The state to return to
before opening anything in SPECIALIZE.md §3f.

| commit | what |
|---|---|
| `a72e2a3` | the prune is skipped when it provably cannot delete |
| `38aebba` | …and needs the lock level as well, with the case that says so |
| `a4ea46b` | the pre-lock `ORDER BY` elision, **reverted** — sound and a net loss (R44) |
| `a89df5b` | the upsert stops rewriting rows nothing changed about, by default (R45) |
| `a5672af` | the profile behind that, and the 1:150 that removes the gate (R47) |

Build, as reported by the running server:

    ./configure --prefix=/home/user/pgsql-opt --without-icu CFLAGS=-O2
    debug_assertions = off
    no --enable-injection-points

That is the measurement build; R45 through R47 were taken on it, except R45,
which says in its own protocol column that it was taken on an assertions build
after a container reclaim.  Restore
`-O2 --enable-cassert --enable-injection-points` before running the
injection-point specs or the isolation suite.

Gates at this point, all pristine: regress 250/250, isolation 135/135,
injection_points 5 regress + 13 specs, the differential oracle's vector
identical to `calibrate.baseline`, `fuzz.sh` PASS on all four modes,
`mutations.py --check` 29/29, `profile.py --check` 15/15.

---

## the deparse elision — the plan cache stops needing text

The point at which the cache key is the qual tree rather than its deparsed
form, and a refresh that hits the cache does no deparse at all.

| commit | what |
|---|---|
| `0675444` | nothing checked that the key reads the predicate — the gate, first |
| `09cf6ff` | the predicate is no longer deparsed on a refresh that hits |
| `bcb81e2` | the arm that measures it, and `--overlay` so it can compose with the profiler |

Build, as reported by the running server:

    ./configure --prefix=/home/user/pgsql-opt --without-icu \
                --enable-cassert --enable-injection-points CFLAGS=-O2
    debug_assertions = on

R48 and R49 were taken on the **measurement** build — the same flags without
`--enable-cassert --enable-injection-points`.  The gate below was run on the
assertions build.  Do not compare a timing across the two.

Gates at this point, all pristine: regress **250/250**, isolation **135/135**,
injection_points **5 regress + 13 specs**, the differential oracle's vector
identical to `calibrate.baseline` (46 cells), `fuzz.sh` PASS on all four modes,
`mutations.py --check` **33/33**, `profile.py --check` **15/15**,
`leakcheck.sh` +0 on all four modes in all three columns, `pg_stat_statements`
15/16 confirmed as B25's exact one-line diff, and all five `matview_where*`
files green under `debug_discard_caches = 1`.

---

## `c8beb05` — the patch as posted to -hackers

Not a restore point so much as the reference: the original implementation,
before any of the fixes in ISSUES.md.  Useful for answering "was this ever
actually wrong" rather than "is it right now", which is a question that keeps
coming up and that only the original code can answer.

Build it in a worktree rather than by checking it out in place.  **R51 needs it
side by side with the current tree**, which means its own prefix, its own
cluster and its own port -- and none of that survives a container reclaim, so
the recipe is here rather than in anyone's shell history:

    git worktree add /home/user/pg-orig c8beb05
    chown -R pgtest /home/user/pg-orig
    mkdir -p /home/user/pgsql-v2 && chown pgtest /home/user/pgsql-v2
    su pgtest -c "cd /home/user/pg-orig && \
        ./configure --prefix=/home/user/pgsql-v2 --without-icu CFLAGS=-O2 && \
        make -j2 install"
    su pgtest -c "/home/user/pgsql-v2/bin/initdb -D /home/pgtest/pgdata-v2 -U pgtest"
    su pgtest -c "/home/user/pgsql-v2/bin/pg_ctl -D /home/pgtest/pgdata-v2 \
        -l /home/pgtest/pg-v2.log -o '-p 5611' -w start"

`-O2` with assertions **off** on both sides, or the comparison is not one.  Then
`bench/vsv2.sh correct` before `bench/vsv2.sh speed`, in that order and for the
reason its header gives — and leave `PRED` at its default of `move`.  A constant
window is v2's most favourable configuration and current's least at the same
time, so `PRED=const` is the adversarial cell and not the headline; three sweeps
were run that way before anyone noticed.  The current tree has to be on the measurement build
too -- `rebuild.sh --full --prefix=/home/user/pgsql-opt --without-icu CFLAGS=-O2`
-- and restored to `--enable-cassert --enable-injection-points` afterwards
before any correctness work.
