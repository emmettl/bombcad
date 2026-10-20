# Continuous integration

The solver needs a Metal device: most of `Tests/BlastCoreTests` stops without one, and every
`blastbench` command runs on the GPU. GitHub's hosted macOS runners are virtual machines with
limited Metal support, so CI runs on a self-hosted Mac mini (M4, 10-core GPU, 24 GB) instead,
reached as `scrimply-ci-tb`. The runner is `mac-mini-bombcad`, installed in
`~/Developer/bombcad-runner` as a launch agent.

## What runs

| Workflow | When | What |
|---|---|---|
| [Check](../.github/workflows/check.yml), light | By hand (suite `light`); no longer on each push since 20 October 2026 | `make check-light`: lint, script tests and the documents' links, a build without warnings, the core tests and the release-build smoke runs, 15 to 20 minutes on the mini, most of it building the tests |
| [Check](../.github/workflows/check.yml), full | By hand (suite `all`) | Lint, script tests, build, application and core tests, the packaged app's signature |
| [Nightly](../.github/workflows/nightly.yml) | 19:00 UTC by GitHub's schedule and 19:20 UTC from the mini, whichever comes first; or by hand | The full check on `main`'s head, with what failed and the suspect commits; then the [test-impact map](#choosing-tests-by-coverage) of that commit; then `Scripts/nightly.py`: the benchmarks and the validation suite, compared with earlier nights |
| [Linux BlastModel](../.github/workflows/linux-blastmodel.yml) | Every push to `main` and every pull request, on GitHub's hosted Ubuntu runner | Once the BlastModel split has landed (see [`Scripts/split/`](../Scripts/split/)): builds BlastModel, the model without Metal, and runs `BlastModelTests` on Linux, about 12 minutes; before that it does nothing. The Mac mini stays the reference |

**The gate is the full check before pushing.** Every session runs `make check` (or
`make check-anywhere`, see [below](#checks-on-the-mini-instead-of-this-mac)) before it pushes, so
CI repeating it after every push was mostly duplicate work that kept the mini busy an hour each
time. Since 20 October a push runs no check on the mini at all (the pre-push check is the gate, Linux CI runs on each push, the full check runs nightly), which frees the mini for remote checks and sweeps. From 11 October to then a push ran only the light check, a backstop for what a pre-push check
cannot catch (a merge of two green branches, a file left out of a commit), and the nightly runs
the whole suite on `main`'s head. When the nightly's full check fails, its summary lists the
failing tests and errors, and the commits since the last green full check, newest first, as
the suspects (`Scripts/nightly-suspects.py`; the runner keeps that commit in
`~/bombcad-nightly/last-green-full`). A full run by hand is still there for a change that wants
it at once.

**The pre-push check is sized to the change** (since 18 October 2026, at the user's request: while
the project's only user is its author, velocity counts for more than repeating the whole suite on
every push). `make check-affected` (`Scripts/check-affected.py`) compares
the branch with `origin/main` and runs one of five tiers. Since 19 October the suites are chosen
by coverage when a [test-impact map](#choosing-tests-by-coverage) is at hand, and since 20 October
a change to the solvers' core runs its suites and the [digests](#the-digests), not the whole suite:

| Change | Runs |
|---|---|
| Documents, images and the Python scripts only | `make lint` and `make ci-test` (the scripts' tests and the documents' links); no Swift build |
| Code, with a map at or behind the merge base (tier `covered`) | lint, `make build-strict`, `ci-test`, and the Swift suites that executed a changed function when the map was built; for a shader, the suites that ran the Swift lines dispatching the kernels the change reaches, and the quickest suite that compiles that library. Plus the suites in changed test files, those whose test files read a changed file by its path, those the map has no coverage for, and the standing's and the shader layouts' suites |
| Code without a map (tier `affected`), or a file the map can't speak for | the suites that name a changed file's type (an extension's file, `BlastSolver+Stepping.swift`, by the type it extends) or sit in a changed test file, plus the standing's and the shader layouts' suites |
| The solvers' core (tier `core`): the solvers' shaders (`Sources/BlastCore/Shaders`), RadialBlast, and BlastSolver and its extensions, SolverTypes, StructureSolver, StructureTypes, ShellSolver, Scenario, MappedStart, Refinement, StructuralBody (with their `+GPU`/`+CPU` halves) | the suites as for `covered` (or `affected` without a map); for a core file the map can't speak for, its names and every suite that ran any of it; for a shader the kernel lookup can't follow, the suites that ran the Swift mirrors of the shader types it touches. Then the six digest sets, bit for bit against the merge base |
| `Package.swift`/`.resolved`, or `ARGS=--full` | the full `make check`, here or on the mini (below) |

`--dry-run` prints the tier, the map's commit, what was made of each changed file and the suites,
each with why it was chosen, and for the core what the digests will build and reuse; `--full`
forces the full check; `--no-map` chooses by name as without a map; `--base <commit>` compares
with that commit instead of the merge base (to time a past commit as the branch it was). Through
make they go in `ARGS` (`make check-affected ARGS=--dry-run`): `make check-affected --dry-run` is
make's own dry run, which prints the command and runs nothing. The full check still runs nightly
on `main` and on every release commit, and its suspect list names the commit that broke anything
the tiers missed. When the project gains users, the full check before every push comes back.

### The digests

`blastbench digest` hashes, to the bit, five air scenes after 80 steps (open ground, a street with
and without afterburning, a blast wall in solids and in shells: every cell, the peaks and the
impulse) and two walls struck to failure on their own over 3,000 substeps, in solids and in
shells. The core tier runs it in six sets (`DIGEST_SETS` in the script), the options sessions have
used to show a change bit-identical:

| Set | Options |
|---|---|
| plain | none |
| recommended | `--recommended` |
| mapped | `--recommended --mapped` |
| refined | `--refine 2` |
| refined twice | `--refine 2 --refine-levels 2` |
| terrain | `--recommended --terrain hill --gravity --refine 2` (cut cells) |

They run on this branch's release build (`swift build -c release --product blastbench` in the
worktree) and on the merge base's, both on the Studio under `gpu-slot --mem 8`, and every
variant's line (hash and counts) is compared. A difference fails the check and is listed by set and
variant, with both hashes; a variant unstable at the base (`unstable`, a NaN) is not compared. A
change meant to move results goes through `ARGS=--full`, with the reason in its commit message.

The merge base's binary is built once, in a clone of this repository kept at
`/Volumes/StudioData/bombcad/digest-cache/source` and checked out at each base in turn, so its
release build is incremental. The binary and its resource bundles are copied to
`digest-cache/<commit>/`, with the base's digests on that Mac (`digests-<host>.json`), so the next
check on the same base runs only its own side. One base is built at a time, under a lock
(`digest-cache/build.lock`); the last eight bases are kept. Without StudioData the cache is
`~/bombcad-digest-cache`. The digests run beside the build and tests, on the Studio whether those
run here or on the mini, and their output follows the steps'; a step that fails stops them.

Measured on 20 October: each set takes 1 to 19 s on the Studio (the terrain set 101 s the first
time, 12 s once its shaders were cached), about a minute for the six; two runs of the same binary
gave the same 42 lines.

Timed on 20 October on 5a045b56 (a refined patch's fill: `Refinement.swift`,
`BlastSolver+Refinement.swift` and `Refine.metal`), as a branch on its parent (`--base 5a045b56^
--remote`), against a map 23 commits behind: tier `core`, 106 of 375 suites, about 45% of the map's
suite time (the BlastSolver extension files are newer than that map, so they went by name). Before,
that branch meant the full check. It took 20 minutes (1,204 s) from start to finish: lint and
`ci-test` a minute here; the build and tests 873 s on the mini; and meanwhile the digests here,
1,150 s, of which both release builds from cold (211 s for the branch, 226 s for the base in the
new clone), 460 s waiting for a slot (all five were held) and 245 s of runs for the two sides. The
same digests again, the base's binary and digests cached and the branch's build current, took
187 s: 162 s waiting for the slot and 22 s of runs. The full check it replaces held a slot for a
median 41 minutes in its last 15 runs on the Studio (quartiles 26 and 46), its wait for the slot
aside. The runs' memory peaked at 5.1 to 7.3 GB (refined twice), so they declare 8 GB.

## Landing work: `make ship`

`make ship` (`Scripts/ship.py`) is the one command a session uses to push. In order, each step's
exit status checked and nothing piped:

1. It refuses a dirty tree (untracked files too: check-affected would build them), a rebase or
   merge in progress, a branch holding merge commits (a rebase drops them silently), nothing to
   push, or being run inside gpu-slot.
2. `make format`; if that changed anything, it stops and asks for the change to be committed.
3. `make lint`, and `make build-strict` when the branch changes Swift, Metal or the package.
4. `python3 Scripts/check-affected.py`, bare.
5. `git fetch origin` and, if main has moved, `git rebase origin/main` (aborted, and refused, on a
   conflict or a commit the rebase left out).
6. The diff check. `git diff origin/main...HEAD --stat` is printed, and must hold only files the
   branch's own commits change. And the branch must not look like a commit made over a stale copy,
   as 459e15f8 was: blocks of five or more lines that one of the last 20 commits on main to touch a
   file (within four days) put in, taken out and not moved elsewhere, with the text they replaced
   back, or in the code of two files, or one block of 25 lines. Over the last 300 commits of main,
   taken as branches on their parents, that flags 459e15f8 (six files) and two others, a file
   split by script and a test rewritten whole. `ARGS=--allow-reverts` passes it when meant.
7. If main moved since the check, the check runs again only when the new commits touch one of the
   branch's files or a core file; otherwise straight to the push.
8. `git push origin HEAD:main`. Rejected as not a fast-forward, it fetches, rebases, checks the diff
   (re-checking by step 7) and pushes again, three times at most.
9. One line: the commits pushed, the checks and their time, the rebases and pushes.

`ARGS=--dry-run` says what it would do and runs check-affected's own dry run; `ARGS=--remote`,
`ARGS=--local` and `ARGS=--full` (for a change meant to move the digests) reach check-affected. Its tests, on temporary repositories with made-up steps, are
in `Scripts/test-ship.py` (`make ci-test`).

### Where the build and tests run

Lint and `ci-test` take a minute or two and always run on the Studio. The expensive steps (the
strict build, the IFC converter and the `swift test` run of the chosen suites; for the full tier,
`make check`) go to the mini when the Studio's GPU line is long and the mini is free (since 19
October 2026). Before them, `check-affected` reads `gpu-slot --status` and decides:

- **The Studio is busy** when 3 or more jobs are waiting for a gpu-slot slot (`--min-waiting`), or
  when the memory declared by the jobs holding slots and those waiting is more than its budget, so
  a new job would wait for memory as well.
- **Then it asks the mini**, by `Scripts/remote.py`'s own look (`remote.py free` gives the same
  answer): free unless one of its CI runners has a job, it is Scrimply's nightly window, its load
  is above a core each, or another BombCAD job holds it. A second lane is allowed beside that job
  only under the rules [below](#two-lanes-on-the-mini).
- **Busy and free: on the mini.** The worktree is copied over, as for `check-anywhere`, and
  `python3 Scripts/check-affected.py check-steps --suites …` runs there, the same steps in the
  same order. Its output streams back and its exit status is check-affected's. Lines starting
  with `remote:` say where it ran, in which lane, how long it took and its peak memory. If the
  mini is taken between the look and the run, the steps run here instead.
- **Otherwise here**, under gpu-slot, as before: `gpu-slot python3 Scripts/check-affected.py
  check-steps`, the suites passed in `CHECK_AFFECTED_SUITES`, so that gpu-slot learns one
  command's memory, whatever the suites.

It prints the decision and its reason (`build and tests on scrimply-ci-tb, since this Mac is busy
(6 waiting for gpu-slot, 46 GB declared …) and scrimply-ci-tb is free`). `ARGS=--dry-run` prints
it without running anything. `ARGS=--local` keeps the steps here. `ARGS=--remote` sends them to
the mini, waiting up to two hours for it if it is taken. Run as `gpu-slot make check-affected`
(the habit before 19 October), check-affected already holds a slot, so it stays here; holding a
Studio slot while the mini works would only lengthen the line. A full check run that way still
goes to `make check-anywhere`, as before. Run it without gpu-slot, which it now uses itself.

Measured on 19 October, with 6 jobs waiting and the Studio's load average at about 150: a
covered-tier check (15 suites) took 175 s from start to finish with the build and tests on the
mini. That was 93 s for lint and `ci-test` here, then 81 s for the copy and the remote steps,
78 s of them building incrementally and running the suites. In a fresh lane the same steps took
82 s, 65 s of it the build. The same check with `--local`, started minutes later, took 819 s. It
waited 628 s for a slot, behind seven jobs, then took 114 s for the build and tests: 95 s of
that was the build, from cold in a fresh worktree, and its largest process peaked at 2 GB. Once a
slot is free the Studio's steps are about as quick as the mini's. The time saved is the wait for
the slot.

### Full studies

A few tests run a whole study: a building settled under its own weight and then loaded, an
assembly pushed to failure, a convergence sweep. Since 19 October 2026 such a test can carry the
`.fullStudy` trait (`Tests/BlastModelTests/FullStudies.swift`, and the same in BombCADTests), which
runs it only with `BOMBCAD_FULL_STUDIES=1` in the environment. The nightly full check sets it, and
so does `make release` (`Scripts/release.py`); the pre-push checks (`make check-affected`,
`make check`, `make check-anywhere`) and the test-impact map don't. A gated test's suite keeps a
check-time version beside it, on a smaller mesh or a shorter run, that goes down the same code and
asserts the same kind of answer with tolerances set from measured values, so the map still sees
the suite and `check-affected` still chooses it. To run the full versions by hand:

```sh
BOMBCAD_FULL_STUDIES=1 ~/.local/bin/gpu-slot swift test --filter '<Suite>'
```

### Choosing tests by coverage

`Scripts/test-impact.py build` (`make test-impact`) builds a map of which suites execute which
functions of `Sources/`:

1. It compiles the package and its tests with coverage (`swift build --build-tests
   --enable-code-coverage`) in a build folder of its own, `test-impact/build` beside the maps, so
   no worktree's `.build` is rebuilt with other flags.
2. It lists the tests (`swift test list`) and runs each top-level suite alone, `swift test
   --skip-build --filter '^Module.Suite(/|$)'`, four at once, each writing its own raw profile
   through `LLVM_PROFILE_FILE`. Swift's coverage is counted per process, not per test, so a
   process per suite is the practical grain: a process per test would be about 2,000 of them.
   The suites run under `~/.local/bin/gpu-slot` (the script takes the slot itself, after the
   compile; `--mem` declares its memory, 10 GB by default).
3. Each suite's profile is merged (`xcrun llvm-profdata merge`) and exported (`xcrun llvm-cov
   export`), and the map records the functions it executed, each by its file and line extent.
   A suite that doesn't pass (or times out, after 90 minutes) gets no coverage, and is always run.

The map goes to `/Volumes/StudioData/bombcad/test-impact/<commit>.json` on the Studio
(`~/bombcad-test-impact/` elsewhere), keyed by the commit it was built at, which must be clean; it
is never committed. The last three are kept, where they are built and where they are fetched to.
The nightly builds one on the mini straight after the full check, for the commit that check tested
(the `test-impact` job, about 35 minutes there; before 20 October it ran after the validation
suite, three hours later); `check-affected` copies the mini's maps to the Studio at most hourly
(`test-impact.py fetch`, over SSH to the host in `~/.config/bombcad/remote.json`). On the Studio,
`python3 Scripts/test-impact.py build` builds one on demand. `test-impact.py show <file>` lists the
suites covering a file, `list` the maps kept.

`check-affected` takes the newest map whose commit is the merge base or an ancestor of it. For each
changed Swift file it takes the lines the branch changes, as lines of the merge base (for an
insertion, the lines either side of it), carries them back to the map's commit through `git diff`
between the two, and finds the functions holding them. A line in no function (a stored property,
a type's declaration, a function's signature above its brace, an import) counts as the whole file:
every suite that executed any of it. Then:

- **Shaders.** Metal has no coverage. Each changed shader line is taken to its top-level
  declaration (function, kernel, type, constant or macro; the comment above a declaration is its
  own) in the library at the merge base. The kernels it can reach are those that name it, through
  any chain of declarations naming each other; a directive (`#include`, `using namespace`) counts
  as the whole file. Each kernel's name is found as a Swift literal: where it is assigned to a
  pipeline property or field (`sweepPipeline = try pipeline("sweep")`), the lines using that name
  (`setComputePipelineState(sweepPipeline)`) are the dispatch; otherwise the literal's own line.
  Those Swift lines are treated as changed, as above. The quickest mapped suite that compiles the
  library is added, so a shader that no longer compiles is caught whatever kernels it reaches.
- **Files the map can't speak for** go by the name rules (a core file by its names and every
  suite that ran any of it, with the digests): a file
  the map doesn't hold (new, or without any compiled code), one changed by more than
  `--max-map-age` commits (30, merges not counted; BlastSolver.swift takes about 20 a day) since the map, and files that aren't Swift or shaders (scripts,
  samples, the Makefile). A shader the kernel lookup can't follow (a kernel dispatched from no
  Swift line found by name, a shader changed in more than `--max-map-age` commits since the map, or
  one new on the branch) takes the suites that ran the Swift mirrors of the shader types the change
  touches or uses (the pairs `check-shader-mirrors.py` finds), or without any those of the Swift
  that loads the library, and the quickest suite that compiles it.
- **Package.swift and Package.resolved** always mean the full check: a new ContinuumKit moves code
  and shader source the map can't see.
- **Suites the map lacks** (added since, or without coverage) are always run, as are the suites
  whose test files read a changed file by its path (`"Samples/Importer"`,
  `"Sources/BlastRender/Shaders/Render.metal"`): coverage doesn't see a file read as text.

The tests of the selection, on made-up maps, are in `Scripts/test-check-affected.py` (`make ci-test`).

**What a map costs.** Built on the Studio at `7d95be96` on 19 October, at load averages of 75 to
160: the coverage build about 3 minutes from cold (seconds when incremental), the 315 suites 22 to
28 minutes at four at once in one slot (5,100 to 5,600 suite-seconds; the terraced houses take 9 to
12 minutes alone, so they start first, by the last map's times), a peak of 3.4 to 5.7 GB, and a
2.2 MB map. All 315 passed.

**What it saves.** Each of the 92 commits since 17 October that touched the core (non-merge), taken
as a branch on its parent against that map:

- 4 still meant the full check: three changed `Package.swift`, one added a shader file.
- The other 88 ran a median 63% of the suites' time (quartiles 52% and 72%): changes in the hot
  path (the solver's `init`, `encodeBatchPart`, `prepareStep`, the sweep) reach every suite that
  steps the air, about half the time, and a change outside any function (a stored property)
  takes in a whole file, BlastSolver.swift's 160 suites. Focused fixes did far better: 11 ran a
  quarter or less, such as the mapped start's GPU clock (15%), the fine grid's pane lookup header
  (1%) and the renderer's shell stride (1%).

Against a full check of 30 to 45 minutes, most of it the test run, that is roughly a third of the
test time saved on a typical core change, and nearly all of it on a focused one.

**What it would have caught.** In 75 of the 77 of those commits that changed tests, the code
alone (without the changed test files) chose every suite of the test files they changed. Of the
other two, one's tests were in a sibling suite of the same file, which was chosen; the other was
`EnvelopeImportStudyTests`, which skips without the IFC converter, so the first map, built without
it, saw almost none of its coverage: the build now prepares the converter as `make test` does.
The NaN wave-speed guard's change (3caa3e48) and its fast-math repair (03606e38), both in
`prepareStep`, choose `StabilityTests`; the stale cached addresses that 2da843b2 fixed were in the
solver's `init`, which every suite that builds a solver runs (124 suites, `SolverMemoryTests` among
them). So no path is kept on the full check beyond the package.

**What it can miss.**

- Code run by a test only sometimes (a race, a timing): the map has one run's coverage.
- Calls added on `main` since the map: a suite that has since started to run a function isn't
  credited with it. Hence the age limit, and a nightly map.
- A suite that fails only beside others (shared state, a full GPU), or grows slow: only the chosen
  suites run.
- Files read other than by a path literal in the test, and data outside `Sources/` (samples,
  scripts), which go by the name rules.
- A `//` line inside a Swift multi-line string is taken for a comment. Shaders keep their comments
  (BuildProbe's edits anchor on them).
- Kernels found through their pipeline's name: a pipeline dispatched through a name the lookup
  doesn't follow falls back to its literal's line, usually the solver's `init` (broader, not
  narrower); a kernel with no Swift literal at all goes by the mirrors of its types, and the
  digests.

**The GPU structs match on both sides.** `make ci-test` runs `Scripts/check-shader-mirrors.py`,
which lays out each Swift struct uploaded to a Metal buffer and the shader struct that reads it by
the two languages' rules (no compiler is needed, so it runs on any machine), and each shader struct
the renderer copies from a solver's. It fails when a size, a stride, a field's offset or a field's
kind (float, integer, half, bool) differs. It finds pairs by name, by a Swift doc comment naming
the shader struct in backticks, and by `pair` lines in `Scripts/shader-mirrors-allow.txt`, which
also lists each deliberate difference with its reason. It was added on 18 October 2026, after
`ShellElement` grew from 40 to 52 bytes in the solver and not in `Render.metal`; the Swift test
`RenderLayoutTests` guards that one pair as well. It does not read the shader source ContinuumKit
compiles in, and buffers written as raw floats are checked only where a `size` line names the Swift
constant holding their stride.

**No compiler warnings.** Every check builds with `make build-strict` (`Scripts/build-strict.py`):
the package and its tests, failing on any warning in this package's own code, each listed once;
SwiftPM suppresses ContinuumKit's. There were none on 12 October 2026, down from 108 (mostly
`concurrentPerform` closures that Dispatch marks `@Sendable`; the parallel loops now go through
`concurrently(iterations:_:)` in BlastCore, whose comment says what keeps them safe). Only files
compiled in a build can warn, so an incremental build catches what a change brings; `rm -rf
.build` first to see them all.

A Check run is never cancelled by a newer push: the newest push waits behind it and older waiting
ones are dropped, so at most one waits. A run started by hand has a queue of its own, by its suite
for a bounded comparison and by its branch or tag for the full checks, so a push to `main` never
drops it while it waits, nor it a push. A failed check or timeout still stops a run. Both run
only on a runner labelled `metal`. The mini also runs Scrimply's two runners and one
for hellomini-builds, so a BombCAD job can share the GPU with theirs; the nightly run is timed
to miss Scrimply's, which takes the mini from about 01:30 to 04:30 UTC. A time flagged slower
may be another job on the machine: check the Actions tabs of those repositories before looking
for a regression.

The full Check exposes lint, script tests, build and `make test` as separate steps. The test step has a
45-minute limit inside the job's 60-minute limit so a stalled test process fails before the
job runs out of time to retain its diagnostics. Its combined output is streamed to Actions
and uploaded as `check-<run ID>-<attempt>/tests.log`, retained for 14 days even if the test step
fails or times out. The pipeline preserves `make test`'s failure status. Build and script
checks run before the tests, so their results remain visible if tests stall. `make check`
remains the equivalent local set of required checks.

The application tests wait for the state they are about (a run finished, a consumer caught up,
an edit settled), with no deadline of their own: a run that takes a second alone has taken
minutes at load averages of 50–140, so a deadline failed for load rather than a fault. A test
that never gets there is failed as hung after ten minutes (`hangLimit`). Paced playback is
checked on a clock the test drives, not the wall's.

The app's own deadlines take nil in the tests, keeping the app's values otherwise: a connection's
steps and a worker's greeting (`NearbyWorkers.Limits.none`, `SweepWorkerClient.helloTimeout`),
the probes that place companions by cost (`probeTimeout`), the end of a run waiting for its
companions' last frames (`SimulationModel.catchUpLimits`), an ensemble worker's answer
(`answerLimit`) and the IFC converter (`IFCImporter.conversionLimit`). On 19 and 20 October
2026 a test process on the loaded Studio stalled for about a minute, and tests failed for a 20-fold
margin on a one-second limit, a 30 s probe, a three-minute limit on the network tests and a
consumer that never caught up. A test of a deadline itself gives its own and checks only that it
never comes early, or runs its timer by hand. `Scripts/check-test-deadlines.py` (in `ci-test`)
reports any new wall-clock bound in Tests/: an upper bound on elapsed time, a deadline, a time
limit shorter than the target's hang limit, a sleep of a second or more, or a wait that gives up
after a count of sleeps; the few deliberate ones are listed in
`Scripts/test-deadlines-allow.txt`, each with its reason.

The core tests have no deadlines, sleeps or timings of their own (their elapsed times are
simulated), but the solvers wait on the GPU synchronously. On Swift Testing's few cooperative
threads those waits starved the rest: with the GPU busy, even trivial tests reported only near
the end of the run, after half an hour or more. Suites that use the GPU now run their tests on
threads of their own, as many as cores (`.gpuThreads`, Tests/BlastCoreTests/GPUThreads.swift),
leaving the cooperative pool to the others: with the GPU saturated by `blastbench` runs, over 500
of the 875 tests had passed within four minutes, where none had after eighteen. The whole run
still takes as long as the GPU allows (3,078 and 3,450 s saturated, against 3,199 and 4,244 s
before). Each test is held to two hours of running on its thread (a GPU suite) or in all (the
others): at a load average of 250, heavy tests of a debug build ran for over half an hour. A GPU
test past its two hours ends the test run: it is named on standard error and the test process
exits with a failure. Recording an issue was not enough: on 15 October two Sod shock-tube tests
were recorded hung at two hours, but a test that never returns never finishes, so the run went on
for three more until it was stopped, and its log, buffered, showed nothing after 13:14.

On 9 October, Check runs [37965308304](https://github.com/emmettl/bombcad/actions/runs/37965308304)
and [37975918140](https://github.com/emmettl/bombcad/actions/runs/37975918140) hit the job limit
in the core test target.
In the latter, all 220 application tests passed in 123 seconds; output from the core target
stopped well before cancellation with several tests still unfinished. The core-test stall is
unresolved. The passing nightly on the same commit covers a different suite and does not
replace Check.

## Checks on the mini instead of this Mac

Many sessions each running `make check` on the development Studio pile up (load averages of 30 to
60, an hour a check). The mini can take them:

```bash
make check-remote
```

```bash
make check-anywhere
```

`check-remote` copies the worktree to the mini (rsync, leaving out `.build`), waits its turn, runs
`make check` there and streams its output back, returning its exit status; `TARGET=lint` (or any
other target) runs that instead. `check-anywhere` looks at both Macs first, their load averages
and how busy their GPUs are (each process's GPU time from `ioreg`), and runs where it should
finish sooner, saying where and why; the mini counts as three times slower than a quiet Studio, as measured below.
`python3 Scripts/remote.py status` shows both Macs and what `check-anywhere` would do.

A pass on the mini counts as a pass here for pushing: the same `make check`, on the same commit,
on a Mac that runs Check itself. The push rules are otherwise unchanged (merge `origin/main`,
check, push as a fast-forward).

**Sharing the mini politely.** It runs Scrimply's two runners, hellomini-builds' and BombCAD's,
and Scrimply's nightly takes it from about 01:30 to 04:30 UTC. A check there waits, saying why,
while one of the Scrimply runners or BombCAD's has a job, in that window, or while another BombCAD
job holds its lock, `~/bombcad-remote/lock` (a directory, with its owner's process, start and
purpose; a lock whose process has gone, or six hours old, is taken over). `check-anywhere` does not
wait: if the mini is not free it runs here. Everything runs in one folder on the mini,
`~/bombcad-remote/check`, so that its paths, and with them SwiftPM's build cache, are the same
every time; after a check only the cache is kept, and it is cleared when it passes 20 GB.

### Two lanes on the mini

The mini can run two of check-affected's build-and-test jobs at once (since 19 October 2026). The
first BombCAD job takes lane 1, in `~/bombcad-remote/check`, and the lock as before. A second job
may take lane 2, in `~/bombcad-remote/check-2`, which has a build cache of its own. A SwiftPM
`.build` folder can't be shared by two builds at once, and a separate folder keeps the paths, and
so the cache, the same for each lane. A second lane runs only when all of the following hold:

- both jobs declare their memory, at most 7 GB each (`laneGB`) and 14 GB together (`lanesGB`).
  check-affected's build and tests declare 7 GB. A full `make check`, a `BombCAD worker` and a
  check from an older copy of `remote.py` declare nothing, so they take the mini whole: nothing
  runs beside them, and they wait for both lanes;
- no runner of any project there has a job: every `~/Developer/*runner*`, which includes
  Edgerton's, ContinuumKit's, RoomCAD's and hellomini's as well as the three in `runners`;
- the mini's memory pressure is normal and at least half its memory is free (`laneFreePercent`);
- its load is under two a core (`laneLoadPerCore`), where the first lane's build is most of it.

The lanes are taken and released one at a time, under a file lock (`~/bombcad-remote/lanes.mutex`),
and recorded in `~/bombcad-remote/lanes/<n>`. `~/bombcad-remote/lock` stays held while any lane runs.
When its holder finishes first it hands the lock to the job still running, so a worker or an older
copy of `remote.py` (which know only the lock) always finds the mini taken. One gap remains: if a
lane's process is killed outright (`kill -9`), the lock's owner is dead, and a worker could start
beside the surviving lane until it ends. `remote.py status` lists the lanes and says whether a 7 GB
job would be taken.

Measured on 19 October, two check-affected runs side by side: one took lane 2 with a cold cache and
the other lane 1, warm. The lane-2 job's processes peaked at 5.2 GB together, sampled every 5 s
(the build: 65 s on the mini), and the warm job's at 0.5 to 1.0 GB. The mini's memory stayed 77%
free throughout, and its load average reached 41 during the cold build. Both runs passed, and when
the lane-1 job ended first the lock went over to the lane-2 job.

**The mini as a worker.** `BombCAD sweep` and `BombCAD ensemble` take the Macs named as `workers`
below when no `--worker` is given (`--no-default-workers` stops them). Such a worker decides on its
own Mac, before it greets, whether to take work (the same runners, window and lock, and a load
average under one a core), and holds the lock while it runs; a sweep or ensemble that finds the
mini busy runs without it, and says so.

**Settings** are in `~/.config/bombcad/remote.json`, read by `Scripts/remote.py` and by BombCAD,
so every session and worktree shares them:

```json
{
  "host": "scrimply-ci-tb",
  "workers": ["scrimply-ci-tb"],
  "runners": ["Developer/bombcad-runner", "Developer/actions-runner", "Developer/actions-runner-2"],
  "quietUTC": ["01:30-04:30"],
  "maxLoadPerCore": 1.0,
  "cacheGB": 20,
  "remoteRatio": 3.0
}
```

The lane settings ([above](#two-lanes-on-the-mini): `lanes` 2, `laneGB` 7, `lanesGB` 14,
`laneFreePercent` 50, `laneLoadPerCore` 2) take those defaults when left out; `"lanes": 1` goes
back to one job at a time. Without the file nothing goes to another Mac. **When to use which:** `make check` here when the
Studio is quiet or the change needs this Mac (the M4 Max's timings, the app's window);
`make check-anywhere` otherwise, which is most of the time; `make check-remote` to keep this Mac
free for a measurement.

Measured on 11 October: `make check` on the mini took 46 minutes from a cold build cache, every
test passing (278 core and 868 application tests), after waiting its turn behind a Check run; on
the Studio it took about 30 minutes at load averages near 20. Until then BombCAD's own Check kept
the mini's runner busy much of the day, 45 to 70 minutes for each push to `main`, with pushes about
hourly, so a check sent there mostly waited; that is why a push now runs only the light check,
15 to 20 minutes on the mini (its first run, on 11 October, took 15.5: 13 of them building and
running the core tests). `check-anywhere` never waits: when the mini is taken it runs here.

### The nightly comparison

`Scripts/nightly.py` runs `blastbench throughput` and `structure`, the reproduction commands
listed in [Validation](validation.md), a Hupfauf slab ending on steps of zero length (`contact-sn144`,
which once went NaN there), and a street snapshot. Each night's output goes into
`~/bombcad-nightly/<time>-<commit>/` on the runner, and is uploaded with the run.

- **Results.** Each validation command's output is compared, as text with the wall times masked,
  with the last night on which the same command succeeded. The solvers repeat a run to the last
  bit (their atomic sums are fixed-point), so any other difference is a change in the answer.
  The snapshot is compared by hash.
- **Times.** Every command's wall time is compared with its median over the last seven nights,
  once three are recorded, and flagged at 20% slower. The two benchmarks are run three times and
  their best time kept: on the M4 Max, `blastbench structure` run straight after a five-minute
  beam test was 23% slower than run cool.
- The job fails when a command fails, a result changes or a time is flagged; the run summary
  shows the table and the diffs. The next night compares against the changed output, so each
  change fails once: check that it was intended.

The times are the mini's, not the M4 Max figures in [Performance](performance.md): the M4 has
a third of the GPU cores and under a quarter of the memory bandwidth (120 against 546 GB/s),
and runs take 3.2 to 4.9 times as long ([Other Macs](performance.md#other-macs)). The mini is
not a quiet machine (other projects' CI, and an app on its desktop that uses the GPU), so a time
flagged slower may be another job. `swift test` takes about 8 minutes there, building
included (262 tests, all passing on 2026-10-07). The largest run
in the suite needs about 4 GB of GPU memory.

One entry or several can be run alone, locally or from the Actions tab:

```bash
python3 Scripts/nightly.py --list
```

```bash
python3 Scripts/nightly.py --only beam,snapshot --history /tmp/bombcad-nightly
```

## Starting the nightly

GitHub's schedule has run the nightly four and a half hours late and, the next night, not at all,
so the mini starts it too. A launch agent there, `dev.bombcad.nightly-trigger`, runs
`~/bombcad-nightly-trigger/trigger.sh` at 21:20 local time (19:20 UTC in summer time): it asks
GitHub, with `gh`, whether a nightly has started in the last 12 hours, and starts one if not,
logging to `~/bombcad-nightly-trigger/trigger.log`. A scheduled run that finds one already started
in that time skips itself, so the suite runs once whichever comes first.

Starting a run needs `gh` on the mini signed in to an account that can run the workflow (`gh auth
login`); asking which runs have started does not, the repository being public. `gh` keeps its token
in the login keychain, which an SSH session cannot open, so over SSH it reports the token invalid;
the agent runs in the logged-in session, where it is signed in.

## Setting up the runner

Done on 2026-10-07 over SSH, with runner 2.338.0; the runner updates itself. To set it up
again, on the mini, signed in as the user that runs the jobs:

1. Install the same Xcode as the development machine (the package needs Swift 6.4 tools, and
   `make lint` uses Xcode's `swift format`), and accept its licence.
2. Keep it awake and signed in. The runner is a launch agent, so it runs only while that user is
   signed in.
3. Download the macOS ARM64 runner from github.com/actions/runner into
   `~/Developer/bombcad-runner`, check its SHA-256 against the release notes, and register it
   with a token from `gh api -X POST repos/emmettl/bombcad/actions/runners/registration-token`:
   `./config.sh --unattended --url https://github.com/emmettl/bombcad --token <token> --name
   mac-mini-bombcad --labels metal`.
4. Install it as a service, so it starts at login:

```bash
./svc.sh install
```

```bash
./svc.sh start
```

5. Run Check from the Actions tab, then Nightly with `only` set to `snapshot`, to confirm the
   runner sees the GPU.

## Keeping strangers' code off the mini

The repository is public, and a self-hosted runner runs whatever a workflow tells it to. Neither
workflow runs on pull requests, but a pull request from a fork could add a workflow of its own
that does. In Settings → Actions → General, under fork pull request workflows, require approval
for all external contributors, and never approve a run that touches `.github/workflows` without
reading it.

## The first nights

The first scheduled run, on 7 October, started at 23:27 UTC, four and a half hours after its
19:00 schedule: GitHub's schedules can run late, and it may clash with Scrimply's nightly from
about 01:30. It failed: every structural command crashed at once in the release build
(fixed the same night in 4ccfdb4, which also added `make release-smoke`). The air ran: the
benchmarks in 35 s, `validate` in 17.5 minutes and `closeair` in 2.5. How long the whole suite
takes is still to be seen.

## Not done

- **Releases.** The mini could sign and notarize, but only with the Developer ID key and the
  notary profile in its Keychain. [Releasing](releasing.md) stays on the development machine.
- **Notification of a changed result** is GitHub's failed-workflow email; nothing posts the
  diff anywhere else.

## Bounded shared wall adoption comparison

The manual Check suite `wall-adoption` runs the complete original/shared wall, piston
and public reflection comparison, then independent conservation/completeness and
negative-control gates. It uploads complete reports and dependency pins for fourteen
days. It has a separate concurrency group so unrelated main pushes cannot replace
its pending run; the physical runner still serializes its jobs. The normal app check
also packages the optimized application and verifies its deep strict signature.

Manual suite `packet-adoption` additionally retains complete native remap and moving
reservoir states/loads with the wall/piston comparison and independent corruption
controls. All bounded manual suites now have separate concurrency groups, including
adiabatic, so unrelated main pushes cannot replace a queued comparison. The adiabatic
job checks both its protected historical operator and the actual current shared alias,
requiring complete sample continuity at the exact released dependency.

The bounded `euler-adoption` manual suite compares an immutable pre-adoption app
against the current source with an identical optimized fixture. It retains full
wall/piston/packet/moving and new Euler/SSPRK2 stage/trace/scatter reports, independent
scalar and composed-budget checks, exact pins and rejection controls. Its manual
concurrency group survives unrelated main pushes; full app tests/package/signature
checks remain a separate `all` run.

The Euler adoption's complete mini comparison and full app/package runs pass.
Original/shared/cross-host wall, packet and staged reports remain byte-identical.
The public aggregate records separate measured and integrated revisions; package
and affected peer checks supplement the earlier full-run source rather than
relabeling its measurements. One local playback timing failure passes an isolated
unchanged-limit rerun, with its initial log retained.
