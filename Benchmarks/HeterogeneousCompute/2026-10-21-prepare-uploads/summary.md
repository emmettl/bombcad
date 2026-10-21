# Prepare-uniform reuse: complete-cost experiment

2026-10-21; emmettl/bombcad-work#75 under emmettl/bombcad-work#60.

## Decision

Retain the production worker. A lazy one-entry immutable tensor cache passes the measured
correctness, device-payload and lifetime controls and benefits cooling64, but the complete
worker benefit is workload-dependent. This is a completed no-adoption experiment, not a
claim that the optimization cannot help. No kernel, numerical policy, configuration default,
training admission or distributed scheduling change is made.

The candidate still computes every prepared struct with the original ramp arithmetic and
runs every kernel/host control check. Only consecutive equality of the **entire 276-byte
payload** permits reuse; a miss uploads a fresh tensor. There is no eager extra allocation.
The exact baseline, candidate and patch are in [evidence](evidence/).

## Measurements

RTX 3080 Ti 12 GB, PyTorch 2.11.0+cu128, CUDA 12.8, driver 617.42, WSL. Six retained
small/cooling/terrain/full flat/Beirut jobs; symmetric precise PTX caches primed before timing.
Fresh worker processes, alternating arms, raw monotonic elapsed clock, shared GPU lease and
periodic GPU/process-group observations. No external resolved compute group was observed.
Samples cannot establish laboratory exclusivity. Complete process cost includes startup and
retrieval. Separate tracing/readback diagnostics are excluded from timing.

Negative changes below mean faster candidate. Null is baseline versus the identical baseline
under the two labels, not a pointwise correction or confidence bound.

| Workload | Initial 3-pair total median change | Initial null | Confirmation 12-pair total median change | Confirmation null | Faster confirmation pairs |
|---|---:|---:|---:|---:|---:|
| blast64 | +4.331% | +0.577% | -1.029% | -0.719% | 8/12 |
| cooling32 | -5.074% | -0.843% | -0.658% | +0.226% | 7/12 |
| cooling64 | -2.736% | +0.369% | -4.110% | +0.005% | 10/12 |
| terrain256 | -1.502% | +0.105% | -0.704% | +0.114% | 11/12 |
| flat512 | -0.707% | -0.093% | — | — | — |
| beirut512 | -0.525% | -0.086% | — | — | — |

All original observations are retained separately. Before confirmation began, one 12-pair
confirmation plus matching null cohort was declared for **all four** smaller workloads;
there was no further timing retry based on the result. Cooling64's improvement survives
its controls; terrain256 wins 11/12 pairs with a modest median difference. Blast64 reverses
its initial regression, and cooling32's initial gain shrinks substantially. Full district
results have only three pairs and mixed paired wins. Solver-only or transfer-count reductions
do not establish a universal end-to-end gain. The candidate remains available for an explicit
workload-specific adoption decision; additional untargeted repetition is not a next step.

## Independent audit and controls

[verification.json](evidence/verification.json) rereads 2,628 numerical-file instances /
23,927,907,024 bytes from all **264 timed executions**, verifies exact input/source/executed
worker/support hashes, raw clocks, dt histories and full outputs, and matches 108 historical
launch-study rows. All timed groups are terminal. Large numerical arrays remain at their
hashed paths on the PC under `~/bombcad-prepare-01a15d45`; this repository contains metadata,
source, logs and traces, not those arrays. [metadata-files.json](metadata-files.json) hashes
all 429 archived files; archive contents were independently rehashed after retrieval.

Fourteen separate successful diagnostic executions and four expected no-output failure
refusals pass. Real driver forwarding checks the exact device payload **after** prepare,
confirming that the cached input remains read-only and current. Equal-byte hits reuse the
same live tensor; changes to maxStep/axis force misses. At most three prepare objects are
live under the perturbing frame/weakref observer; none survives successful worker return.
No-repeat and short-ramp controls incur no extra prepare upload. Two-/one-axis tail grids,
odd start, startup, duration, step-limit and nonfinite failure behavior remain checked.
These controls cover this candidate and these cases, not general dataset admission.

The blast64 diagnostic reduces prepare uploads 569 → 1; its separate Torch trace reduces
pageable HtoD copies 590 → 22 and `aten::empty` calls 594 → 26. Kernel/control work remains:
pageable DtoH stays 580. Full evidence and all individual timings are in
[analysis.json](evidence/analysis.json) and the retained profiles.

One initial confirmation dispatch was refused because the preflight observed nonzero GPU
utilization. No profiler/worker started; its failed campaign and guard log are retained.
The fresh v2 campaign completed. Before diagnostic dispatch, the idle v2 controller alone
was SIGSTOP'ed while its independently grouped timed child finished unchanged. Its zombie
child and terminal monitor were verified before correcting an unexecuted diagnostic hook
(Mock side-effect frames obscured caller inspection), then the same controller was resumed.
The original planned hook and [hold/resume record](evidence/controller-hold.json) are retained;
no measured worker or timing instrumentation changed and no started GPU run was discarded.

## Scope and follow-up

emmettl/bombcad-work#75's experiment acceptance is met without adoption. This completes the
explicit prepare-reuse item in emmettl/bombcad-work#60; synchronization, pinned staging,
graph grouping and launch geometry have separate published outcomes. Review that parent
against its original profiling acceptance rather than leaving it open for speculative knobs.
The distributed and numerical admission work in emmettl/bombcad-work#47,
emmettl/bombcad-work#59, emmettl/bombcad-work#62 and emmettl/bombcad-work#63 remains separate.
