# Continuous integration

The solver needs a Metal device: most of `Tests/BlastCoreTests` stops without one, and every
`blastbench` command runs on the GPU. GitHub's hosted macOS runners are virtual machines with
limited Metal support, so CI runs on a self-hosted Mac mini (M4, 10-core GPU, 24 GB) instead,
reached as `scrimply-ci-tb`. The runner is `mac-mini-bombcad`, installed in
`~/Developer/bombcad-runner` as a launch agent.

## What runs

| Workflow | When | What |
|---|---|---|
| [Check](../.github/workflows/check.yml) | Every push to `main`, or by hand | `make check`: lint, tests, release-script tests, build |
| [Nightly](../.github/workflows/nightly.yml) | 19:00 UTC, or by hand | `Scripts/nightly.py`: the benchmarks and the validation suite, compared with earlier nights |

A Check run is never cancelled by a newer push: the newest push waits behind it and older waiting
ones are dropped, so every run finishes and at most one waits. Both run only on a runner labelled `metal`. The mini also runs Scrimply's two runners and one
for hellomini-builds, so a BombCAD job can share the GPU with theirs; the nightly run is timed
to miss Scrimply's, which takes the mini from about 01:30 to 04:30 UTC. A time flagged slower
may be another job on the machine: check the Actions tabs of those repositories before looking
for a regression.

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
