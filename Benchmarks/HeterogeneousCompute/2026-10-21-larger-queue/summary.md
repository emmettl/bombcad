# Eight-case larger replay queue — 21 October 2026

The bounded queue completes eight larger uniform/static-terrain cases correctly,
but CUDA does not improve throughput for these short trajectories. Automatic
selection chooses Metal for all eight and still incurs substantial controller
cost. This is an evaluation checkpoint for [#59](https://github.com/emmettl/bombcad-work/issues/59),
not broader CUDA generation admission or a throughput win.

## Workload and method

Eight new production Metal references: uniform and cut-cell terrain at 5/10/20/40 kg,
128 × 128 × 32 cells (524,288 cells each), dx 2 m, radius 128 m, height 64 m,
until 0.16 s, saturated ground, first-phase output. Each has about 14.2 times the
cells of the earlier 48 × 48 × 16 study. The retained extended DEM covers the
larger domain. These are larger grids with short trajectories; they do not stand
in for long-running full districts or all supported physics.

Each exact case/backend is calibrated three times in isolated one-case queues:
48 executions. Calibration order reverses on the middle round. The pinned cost
report uses the median Mac controller subprocess completion interval, including
its startup, resource probes, polling, publication and exit observation. The
pre-trial quietness snapshots and queue initialization are outside that interval.
These complete isolated-case observations are approximate per-job estimates:
shared controller overhead can be counted repeatedly, and multi-case probing
costs can differ. They are not an exact additive scheduling model.

Then three rounds rotate Metal-only, automatic and forced split policies. The
split assigns 10/40 kg uniform and 10/40 kg terrain to CUDA, the other four to
Metal. All trials use fresh preparation and the existing persistent PTX cache;
cache enablement and compile phase values are retained, without assuming every
lookup is a cache hit. No cached retry or failure is mixed into the policy trials.
Mac gpu-slot and the PC shared training/simulation lock protect actual work.
The coordinating session reported no reservation or timing-sensitive PC work.
Every calibration/policy trial starts with zero declared Mac GPU memory, no
waiting work, normal pressure and an available PC. These snapshots do not prove
exclusive use throughout each interval. No owned build/test load overlaps timing.

The controller's bounded `Popen.wait(timeout=...)` uses timeout polling; exit
observation can add tens of milliseconds (installed Python caps polling at 50 ms).
This matters for subsecond isolated Metal controls. It cannot explain the
multi-second policy differences. Nested PC worker durations use their recorded
raw clock and are not added to the Mac outer interval. The RAW worker clock
and normalized host policy from #64 remain in use.

## Results

| Policy | Median controller completion, s | Range, s | CUDA assignments per trial |
| --- | ---: | ---: | ---: |
| Metal only | 3.854 | 3.641–5.240 | 0 |
| Automatic | 11.265 | 10.374–12.829 | 0 |
| Forced split | 49.690 | 49.191–49.983 | 4 |

Initial cost-plan makespans are 3.884 s for both Metal-only and automatic, and
48.870 s for the split. The automatic model therefore misses substantial
controller cost; its isolated Metal calibrations never incur PC probes.

All 120 calibration/policy executions pass the existing target gate, accept once
and retain worker/source/input provenance. Within each exact case/backend, all
observed numerical file hashes agree across calibration and policy repetitions;
this does not claim bit equality between Metal and CUDA. No case is excluded or declared CUDA
blocked. Each trial's owned worker groups are confirmed terminal. All three
rounds are retained, including the slower third Metal round; no retrospective
quietness exclusion or timing threshold is applied.

Automatic selection's backend choice is sensible for these costs: the eight-case
Metal backlog is cheaper than one fresh CUDA execution. Its controller interval
is nevertheless much larger than Metal-only. Serial Metal worker-body sums are
1.911–2.809 s for Metal-only and 2.098–2.921 s for automatic. The difference is
consistent with the controller's synchronous PC observations whenever any CUDA
alternative is eligible, but this study does not trace and attribute every
residual component. `audit.json` retains initial cost-plan predictions versus
observed completion, rather than treating calibration as a validated model.

The concrete next step is to test a cost-based preflight that asks whether any
CUDA dispatch can improve the current plan before paying for a PC observation.
It must still probe when CUDA can be selected, preserve actual worker locking
and VRAM checks, and handle busy Mac lanes and cached preparations. A matched
comparison is needed before attributing the policy gap or adopting the change.
Longer full-district queues remain another separate throughput evaluation.

## Retained evidence

- `study.py`, `study.json`, `study.log`: exact run controller, snapshots, arguments,
  receipts, source/executable identity, all calibration/policy intervals and outcomes.
- `calibrated-costs.json`: three complete isolated queue observations per exact
  case/backend and pinned medians used in all policy plans.
- `audit.json`: independent validation of 120 accepted objects, numerical hash
  clusters, terminal process groups and initial scheduling predictions.
- Six round-specific state archives: immutable plans/contracts, attempts, initial
  CUDA preparation, gated outputs and logs. `references.tar.gz` retains production
  Metal references. Paths and host policy are run-specific.

No training index, numerical threshold, physics capability or default backend
changes. #59 remains open for predictive controller costs, cost-based PC probe
experiments and long-running representative queues. #47/#62/#63 remain the broader
CUDA admission gates, despite these eight cases passing.

Validation: `make check-affected` passed (68 CUDA/queue/profiler tests, four
local Torch skips; strict build without warnings, lint/scripts/docs, selected
seven Mac and 36 PC tests). All 480 archived accepted dataset files match their
content-addressed receipts, JSON parses and reproduction scripts compile. Final
PC snapshot: GPU 0%/912 MiB, shared lock absent; guest time client remains
inactive/masked. No clock/service changes were made by this study.
