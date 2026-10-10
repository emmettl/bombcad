# Continuous integration

The solver needs a Metal device: most of `Tests/BlastCoreTests` stops without one, and every
`blastbench` command runs on the GPU. GitHub's hosted macOS runners are virtual machines with
limited Metal support, so CI runs on a self-hosted Mac mini (M4, 10-core GPU, 24 GB) instead,
reached as `scrimply-ci-tb`. The runner is `mac-mini-bombcad`, installed in
`~/Developer/bombcad-runner` as a launch agent.

## What runs

| Workflow | When | What |
|---|---|---|
| [Check](../.github/workflows/check.yml) | Every push to `main`, or by hand | Lint, release/nightly script tests, build, then application and core tests |
| [Nightly](../.github/workflows/nightly.yml) | 19:00 UTC by GitHub's schedule and 19:20 UTC from the mini, whichever comes first; or by hand | `Scripts/nightly.py`: the benchmarks and the validation suite, compared with earlier nights |

A Check run is never cancelled by a newer push: the newest push waits behind it and older waiting
ones are dropped, so at most one waits. A failed check or timeout still stops a run. Both run
only on a runner labelled `metal`. The mini also runs Scrimply's two runners and one
for hellomini-builds, so a BombCAD job can share the GPU with theirs; the nightly run is timed
to miss Scrimply's, which takes the mini from about 01:30 to 04:30 UTC. A time flagged slower
may be another job on the machine: check the Actions tabs of those repositories before looking
for a regression.

Check exposes lint, script tests, build and `make test` as separate steps. The test step has a
45-minute limit inside the job's 60-minute limit so a stalled test process fails before the
job runs out of time to retain its diagnostics. Its combined output is streamed to Actions
and uploaded as `check-<run ID>-<attempt>/tests.log`, retained for 14 days even if the test step
fails or times out. The pipeline preserves `make test`'s failure status. Build and script
checks run before the tests, so their results remain visible if tests stall. `make check`
remains the equivalent local set of required checks.

On 9 October, Check runs [37965308304](https://github.com/emmettl/bombcad/actions/runs/37965308304)
and [37975918140](https://github.com/emmettl/bombcad/actions/runs/37975918140) hit the job limit
in the core test target.
In the latter, all 220 application tests passed in 123 seconds; output from the core target
stopped well before cancellation with several tests still unfinished. The core-test stall is
unresolved. The passing nightly on the same commit covers a different suite and does not
replace Check.

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
