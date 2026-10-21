# CUDA launch block sizes — 21 October 2026

**Decision: no adoption.** 64 threads improves the small blast observation but has mixed complete-worker results elsewhere, with tiny full-flat changes against variable identical-worker controls and no Beirut pair wins. 256 threads is consistently slower in both full cases (about 11.9% flat and 2.1% Beirut in median), with no broad compensating benefit. Retain the existing 128-thread default; this is a bounded workload/device result, not a universal optimal-block-size claim.
The production worker remains byte-identical to the measured 128-thread baseline at producing
base `17bbe21c82f0a8beb676c1e632f56d5217535fa3`. This completes the bounded experiment in
emmettl/bombcad-work#72; broader emmettl/bombcad-work#60 remains open.

## One launch-geometry change at a time

The isolated candidates change only the launch ceiling/divisor and threads per block together,
from 128 to 64 or 256. Generated numerical source, exact cell work, host controls, prepare
allocation, startup, cooling and precision are unchanged; no graphs are used. The preflight
loads both precise cut-cell PTX variants and queries all ten entry functions (20 records),
including supported block limits, registers, shared/local storage. Both candidates fit every
queried limit. Both PTX variants are explicitly primed before timing. Function-specific limits
are described by [NVIDIA's driver API](https://docs.nvidia.com/cuda/cuda-driver-api/cuda_driver_api/group__CUDA__EXEC.html);
legal launch sizes are not automatically efficient ones. Register/storage observations are
retained without attributing timing changes to an unmeasured occupancy mechanism.

## Fresh-worker observations

RTX 3080 Ti / driver 617.42 / PyTorch 2.11.0+cu128 / CUDA 12.8. For each size and case there are
three alternating fresh-process pairs with the current 128-thread worker, equal primed PTX
caches and the corrected drained-stdout/EOF observer. Another three pairs/case run the exact
same baseline file under both labels. Seconds are Linux CLOCK_MONOTONIC_RAW and include
compile/setup/output/teardown, while deployment/retrieval are outside timing.

| Case | Matched 128 / 64 median, s | 64 ratio | Matched 128 / 256 median, s | 256 ratio | Same-worker label medians, s |
|---|---:|---:|---:|---:|---:|
| blast64 | 1.509 / 1.464 | -2.97% | 1.524 / 1.531 | +0.49% | 1.535 / 1.506 |
| cooling32 | 1.553 / 1.545 | -0.52% | 1.624 / 1.794 | +10.47% | 1.493 / 1.544 |
| cooling64 | 1.641 / 1.677 | +2.20% | 2.001 / 2.030 | +1.46% | 1.654 / 1.666 |
| terrain256 | 5.657 / 5.669 | +0.21% | 5.757 / 6.015 | +4.47% | 5.775 / 5.764 |
| flat512 | 47.925 / 47.753 | -0.36% | 48.285 / 54.018 | +11.87% | 49.152 / 48.287 |
| beirut512 | 68.417 / 68.517 | +0.15% | 68.622 / 70.077 | +2.12% | 68.865 / 69.518 |

Negative ratios mean a shorter candidate process. Each candidate size has its **own matched
128 baseline**; raw medians across the separate size batches are not a direct 64-versus-256
comparison. Null controls are later separate observations, not a pointwise correction. Full
paired process/solver observations and win counts are in `analysis.json`. Three repetitions
and observed ranges are not confidence intervals, error bounds or a universal optimal size.
No solver/cross-backend speedup or cost-model promotion is claimed.

## Independent controls and provenance

All 108 timed runs (72 candidate/baseline executions, 36 identical-worker executions) retain every case's
numerical files/dt across variants, repetitions and labels. The independent audit rereads
1134 numerical-file instances / 26,611,742,232 bytes,
checks executed-worker/support/source/input/result hashes, dt length/sum and clocks/cache
routing, and matches all 72 rows of the earlier CUDA graph study. This repeats six retained
CUDA cases; it is not new physical validation, diverse generation or dataset admission.

Separate perturbed instrumentation forwards actual driver calls while checking recorded grid,
block, shared-memory and useful-count fields. All ten entries execute under each size across
blast, cooling and cut-cell terrain controls. Eighteen diagnostic runs succeed with exact
paired outputs/dt; six expected fatal/step-limit runs refuse without completed output. Tail
controls use 31-cubed, 31-by-31-by-1 and 31-by-1-by-1 grids, covering non-multiple launch counts,
single/two/three axes and an odd global start with an eight-step ramp. Tiny control kernels
retain their one-useful-thread guards. No tolerance, mask, label or precision is relaxed.

All profiles use the existing PC GPU lease and retain 903 periodic resource/ownership
samples. Every resolved compute group is owned; 0 observation(s) are unresolved at
group read, and all resource queries succeed. These observations are not proof of laboratory
exclusivity. All six timed process groups independently have no live non-zombie members after
completion. Owned PC builds/checks/archiving are outside timing; diagnostics and independent
hashing follow the timed campaign. No observation or failed attempt is silently discarded.

`metadata.tar.gz` contains 241 independently verified metadata files:
exact workers/support/source, actual command/state/resource logs, all result JSONs, inputs and
hashes, loaded-kernel attributes, driver geometry and diagnostic specifications. The large
numerical arrays stay at their receipted paths under `~/bombcad-blocks-01a15d45`; original job
inputs remain in the earlier control roots. The archive does not claim to contain those arrays.
`metadata-files.json` binds it, and `manifest.json` binds this published artifact set.

## Separate next experiment: repeated prepare uploads

emmettl/bombcad-work#75 tracks a [CPU-only proposal](followup-prepare/summary.md) to cache the
immediately previous complete prepared byte sequence and reuse an immutable GPU buffer only
on exact equality. The original graph trace retained 590 pageable HtoD transfers including
setup/control traffic; per-iteration prepare allocation remained. Byte identity is checked on
this Mac for six 276-byte job configurations and 1005 additional CFL bit patterns. That is
feasibility only: no GPU execution, lifetime proof or performance claim for this proposal, and
its candidate is not mixed into these launch-size measurements or installed in production.

emmettl/bombcad-work#60 and emmettl/bombcad-work#59 remain open; emmettl/bombcad-work#75 is the
separate followup. emmettl/bombcad-work#47 generation and emmettl/bombcad-work#62 /
emmettl/bombcad-work#63 numerical admission remain gated, and emmettl/bombcad-work#64 reboot/clock
persistence remains separate. No host-service, clock, training-index or production default change.

Repository validation on efad49660501dab5bf70c5b6f6e0d6b164f10f2c plus this report: make check-affected passed with strict build without warnings, lint/scripts/docs, 71 CUDA/queue tests (four local Torch skips), 45 selected Mac tests and 103 PC tests in 21 suites. This integration includes concurrent source/data/occupant-model changes; the measured CUDA worker remains unchanged.

Final integration: rebased onto 80ead8cba166199f9b238146e2affe49f59dbf7a, whose intervening changes are documentation/reference normalization and a Make-exported BOMBCAD_DATA variable. Source inspection finds no runtime consumer of that new variable in Scripts/Sources/Tests; CUDA code is unchanged. Documentation links pass after rebase. The full covered checks above ran before this documentation/environment-only integration.
