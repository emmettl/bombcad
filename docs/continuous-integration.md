# Continuous integration

The solver needs a Metal device: most of `Tests/BlastCoreTests` stops without one, and every
`blastbench` command runs on the GPU. GitHub's hosted macOS runners are virtual machines with
limited Metal support, so CI runs on a self-hosted Mac mini (M4 Pro, 24 GB) instead.

## What runs

| Workflow | When | What |
|---|---|---|
| [Check](../.github/workflows/check.yml) | Every push to `main`, or by hand | `make check`: lint, tests, release-script tests, build |
| [Nightly](../.github/workflows/nightly.yml) | 01:00 UTC, or by hand | `Scripts/nightly.py`: the benchmarks and the validation suite, compared with earlier nights |

Both run only on a runner labelled `metal`. A single runner takes one job at a time, so the
benchmarks never share the GPU.

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

The times are the mini's, not the M4 Max figures in [Performance](performance.md): the M4 Pro
has about half the memory bandwidth, so expect runs to take about twice as long. The largest run
in the suite needs about 4 GB of GPU memory.

One entry or several can be run alone, locally or from the Actions tab:

```bash
python3 Scripts/nightly.py --list
```

```bash
python3 Scripts/nightly.py --only beam,snapshot --history /tmp/bombcad-nightly
```

## Setting up the runner

On the mini, signed in as the user that will run the jobs:

1. Install the same Xcode as the development machine (the package needs Swift 6.4 tools, and
   `make lint` uses Xcode's `swift format`), and accept its licence.
2. Keep it awake and signed in: in System Settings, prevent automatic sleeping on power and turn
   on automatic login. The runner is a launch agent, so it runs only while that user is signed in.
3. In the repository's Settings → Actions → Runners → New self-hosted runner, choose macOS and
   ARM64 and follow the download and configure commands, adding the label: `./config.sh --url
   https://github.com/emmettl/bombcad --token <token> --labels metal`.
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

## Not done

- **Releases.** The mini could sign and notarize, but only with the Developer ID key and the
  notary profile in its Keychain. [Releasing](releasing.md) stays on the development machine.
- **Notification of a changed result** is GitHub's failed-workflow email; nothing posts the
  diff anywhere else.
