# Continuous integration

The solver needs a Metal device: most of `Tests/BlastCoreTests` stops without one, and every
`blastbench` command runs on the GPU. GitHub's hosted macOS runners are virtual machines with
limited Metal support, so CI runs on a self-hosted Mac mini (M4, 10-core GPU, 24 GB) instead,
reached as `scrimply-ci-tb`. The runner is `mac-mini-bombcad`, installed in
`~/Developer/bombcad-runner` as a launch agent.

## What runs

| Workflow | When | What |
|---|---|---|
| [Check](../.github/workflows/check.yml), light | Every push to `main` | `make check-light`: lint, script tests and the documents' links, a build without warnings, the core tests and the release-build smoke runs, about ten minutes |
| [Check](../.github/workflows/check.yml), full | By hand (suite `all`) | Lint, script tests, build, application and core tests, the packaged app's signature |
| [Nightly](../.github/workflows/nightly.yml) | 19:00 UTC by GitHub's schedule and 19:20 UTC from the mini, whichever comes first; or by hand | The full check on `main`'s head, with what failed and the suspect commits; then `Scripts/nightly.py`: the benchmarks and the validation suite, compared with earlier nights |

**The gate is the full check before pushing.** Every session runs `make check` (or
`make check-anywhere`, see [below](#checks-on-the-mini-instead-of-this-mac)) before it pushes, so
CI repeating it after every push was mostly duplicate work that kept the mini busy an hour each
time. Since 11 October a push runs only the light check, a backstop for what a pre-push check
cannot catch (a merge of two green branches, a file left out of a commit), and the nightly runs
the whole suite on `main`'s head. When the nightly's full check fails, its summary lists the
failing tests and errors, and the commits since the last green full check, newest first, as
the suspects (`Scripts/nightly-suspects.py`; the runner keeps that commit in
`~/bombcad-nightly/last-green-full`). A full run by hand is still there for a change that wants
it at once.

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

The core tests have no deadlines, sleeps or timings of their own (their elapsed times are
simulated), but the solvers wait on the GPU synchronously. On Swift Testing's few cooperative
threads those waits starved the rest: with the GPU busy, even trivial tests reported only near
the end of the run, after half an hour or more. Suites that use the GPU now run their tests on
threads of their own, as many as cores (`.gpuThreads`, Tests/BlastCoreTests/GPUThreads.swift),
leaving the cooperative pool to the others: with the GPU saturated by `blastbench` runs, over 500
of the 875 tests had passed within four minutes, where none had after eighteen. The whole run
still takes as long as the GPU allows (3,078 and 3,450 s saturated, against 3,199 and 4,244 s
before). Each test is held to two hours of running on its thread (a GPU suite) or in all (the
others): at a load average of 250, heavy tests of a debug build ran for over half an hour.

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

Without the file nothing goes to another Mac. **When to use which:** `make check` here when the
Studio is quiet or the change needs this Mac (the M4 Max's timings, the app's window);
`make check-anywhere` otherwise, which is most of the time; `make check-remote` to keep this Mac
free for a measurement.

Measured on 11 October: `make check` on the mini took 46 minutes from a cold build cache, every
test passing (278 core and 868 application tests), after waiting its turn behind a Check run; on
the Studio it took about 30 minutes at load averages near 20. Until then BombCAD's own Check kept
the mini's runner busy much of the day, 45 to 70 minutes for each push to `main`, with pushes about
hourly, so a check sent there mostly waited; that is why a push now runs only the light check,
LIGHT on the mini. `check-anywhere` never waits: when the mini is taken it runs here.

### The nightly comparison

`Scripts/nightly.py` runs `blastbench throughput` and `structure`, the reproduction commands
listed in [Validation](validation.md), and a street snapshot. Each night's output goes into
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
