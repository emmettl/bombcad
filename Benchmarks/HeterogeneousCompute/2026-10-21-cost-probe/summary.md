# Cost-planned PC observations — 21 October 2026

The controller now skips a PC availability observation when an optimistic cost
plan cannot dispatch CUDA now. This removes substantial overhead for the measured
eight-case workload while preserving real PC probes when CUDA could be selected.
Tracking: [emmettl/bombcad-work#59](https://github.com/emmettl/bombcad-work/issues/59).

## Planning rule

After obtaining any required Mac observation, plan with the current measured
costs, active-lane estimates and actual Mac capacity, assuming available PC capacity
and unbounded VRAM. If this plan has a CUDA proposal that can launch now, probe
the PC and replan with actual availability/VRAM. Otherwise record why no PC probe
was required and plan without newly available CUDA capacity. The optimistic result
never authorizes CUDA execution. Requests/dispatch receipts retain the assumptions,
proposals and `probeRequired` decision; actual workers retain their shared GPU
lock, VRAM checks, prepared-input validation and target gate.

Virtual Metal backlog can make a later CUDA case launchable now, so this considers
the whole bounded queue rather than comparing only the first job's isolated costs.
Cached CUDA-only dispatch still requires a PC probe. Unavailable PC capacity or
insufficient observed VRAM can return a cheaper CUDA proposal to Metal. Estimates
can be inaccurate; this is selection under the current model, not a guarantee of
the fastest real execution.

## Real comparison

Same eight 128 × 128 × 32-cell uniform/static-terrain cases and pinned cost report
as the [larger queue study](../2026-10-21-larger-queue/summary.md). Baseline and
candidate each have three automatic and three Metal-only trials, alternating their
order within each version, followed by one forced uniform-10kg CUDA control.
All baseline trials precede candidate trials; this is a sequential comparison,
not randomized interleaved A/B. No owned validation/build load overlaps timings.
Normal gpu-slot/shared PC lock and pre-trial quietness snapshots remain in use;
snapshots do not guarantee exclusive host use throughout each trial.

Both versions use drained stdout/EOF subprocess observation with bounded
`communicate`, avoiding timeout-only exit polling. Thus these values are a fresh
comparison and are not replacements for the historical polling-observed values.
Outer intervals use the Mac clock, including controller startup/observations,
publication and teardown; initialization and pre/post quietness snapshots are
outside. The persistent PTX cache setting remains the same. Numerical code,
physical inputs, executable and CUDA worker support files are unchanged.

| Policy | Baseline median (range), s | Candidate median (range), s |
| --- | ---: | ---: |
| Automatic, all Metal | 12.784 (11.570–12.835) | 5.444 (5.393–5.553) |
| Metal only | 5.663 (5.637–5.724) | 5.465 (5.012–5.516) |
| Forced CUDA control, one sample | 13.790 | 11.376 |

The automatic median improves about 57% and becomes comparable to Metal-only
controls in this workload. This supports adopting the controller change. The
single CUDA sample is a correctness/required-probe control; variation is not a
CUDA performance claim. Longer full-district queues remain unmeasured here.

All 98 case executions pass the existing gate and accept once; all owned process
groups are confirmed terminal. For each exact case/backend, all numerical-file
hashes match across both controller versions. Candidate automatic requests record
`probeRequired=false` and the optimistic-plan reason; the forced CUDA request
records `probeRequired=true` and actual PC availability. This is not an independent
SSH API trace of every intermediate controller iteration.

## Validation and evidence

Unit controls cover all-Metal cost plans without SSH, cheaper CUDA with actual
busy/VRAM observations returning work to Metal, six-job virtual-backlog spillover
requiring a PC probe, CUDA-only dispatch, cached preparations, running/backoff
queues and existing failure/recovery/target gates. The optimistic memory assumption
is never passed to a worker as an observed memory measurement.

`baseline-study.json`, `candidate-study.json` retain snapshots, all request
observations, full accepted receipts, exact completion intervals and states.
The state archives retain plans/contracts, attempts, prepared inputs, gated outputs
and logs. `audit.json` independently checks accepted objects, frozen inputs/support,
controller hashes and process liveness. Because the canonical controller changed
between versions, the post-run baseline pin check uses the retained exact baseline
bytes for that single role; all other pinned paths are checked directly. Each
trial's original contract verification ran while its controller version was current.
Run-specific paths require adaptation for another checkout. Reproduction scripts
and both controller snapshots are retained.

No training index, numerical threshold, physics capability or host clock/service
policy changes. emmettl/bombcad-work#59 remains open for longer representative
queues and further complete-cost validation. Broader admission remains governed
by emmettl/bombcad-work#47, emmettl/bombcad-work#62 and emmettl/bombcad-work#63.

Validation: `make check-affected` passed: 71 CUDA/queue/profiler tests (four local
Torch skips), strict build without warnings, lint/scripts/docs, selected seven
Mac and 36 PC tests. All 392 archived accepted files match their receipts; JSON
parses and reproduction scripts compile. An initial documentation check reached
the new summary link before the file existed; the completed documentation passed
the final check. Both logs are retained.
