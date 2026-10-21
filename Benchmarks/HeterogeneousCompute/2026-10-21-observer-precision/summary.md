# Fresh-process profiler exit observation — 21 October 2026

The profiler now drains a captured stdout pipe, allowing output/EOF readiness to wake
`communicate` instead of relying solely on timeout polling of a child with discarded output.
The 600-second deadline, child-error propagation and owned-child kill/reap semantics remain.
This improves observation, not CUDA computation. Solver code, kernels, precision, clock/service
settings and numerical admission are unchanged.

A related real fresh-process test exposed a cache-routing bug: baseline runs used the candidate
cache argument. The fresh branch now passes the selected worker's cache, consistent with the
in-process path. Distinct-cache and baseline-only-cache cases run actual CPU fixture children
in tests. Previous real symmetric-cache studies used the same path on both sides, so that bug
does not change their results; candidate-only cache experiments also retain their original policy.

## Bounded CPU control

Thirty alternating pairs use the installed PC Python 3.12.3. Each identical CPU child sleeps
one of 0/7/17/31/43 ms, writes a raw-clock final timestamp to its own file, prints a short
message and exits. The parent compares the previous DEVNULL/timeout runner with the new
pipe/timeout runner. Timing uses CLOCK_MONOTONIC_RAW on both sides. No fragile timing threshold
is used as a unit-test assertion; every observation is retained.

| Child final timestamp to parent return | Old polling observer | Drained-pipe observer |
| --- | --- | --- |
| Median | 8.260 ms | 1.914 ms |
| Minimum | 2.375 ms | 1.807 ms |
| Maximum | 20.661 ms | 2.762 ms |

This interval includes the child's final file write and interpreter teardown, so it is not
pure wait latency or an exact child-death timestamp. It demonstrates reduced observer delay
in this bounded control, not zero overhead or an elimination of all runtime noise. Early EOF
or other teardown behavior can still require residual exit observation. The profiler records
`freshProcessObserver` and its own source hash, and historical totals are not rescaled.

## Real same-source GPU control

The coordinated PC window reports no conflicting reservation. Three alternating fresh-process
pairs each of cooling32, blast64 and cooling64 use the exact same current worker for both
labels, identical inputs/source and symmetric persistent primed PTX cache. The existing shared
GPU lock protects the whole profile. RTX 3080 Ti / driver 617.42 / PyTorch 2.11.0+cu128 /
CUDA 12.8; before/after GPU observations and hashes are retained.

| Case | Median process, label baseline / label candidate, s |
| --- | --- |
| cooling32 | 1.571 / 1.549 |
| blast64 | 1.518 / 1.515 |
| cooling64 | 1.757 / 1.700 |

Both labels are the same source; these differences are ordinary variation, not an optimizer
comparison or a speedup. The corrected observer does not make repeated GPU timings identical.
All 18 actual runs' saved numerical files are reread and checked against their recorded hashes,
executed-worker/support/source provenance and per-case repetitions. Every retained numerical
field and dt history also matches the preceding study's baseline for the same exact cases.
The GPU run confirms the corrected CLI/cache/provenance path; full-size physics was not rerun
because no worker/numerical behavior changed or failed.

Process observer intervals include interpreter startup, setup, cache validation, solve, output,
result-file parsing and residual exit observation; they exclude deployment/retrieval and output
hashing after the measured interval. Nested solver/stage timings remain worker raw-clock
measurements. Do not add them to the enclosing process interval or equate a shorter observer
interval with faster kernels.

## Verification and remaining work

CPU-only tests exercise real fresh children for separate and baseline-only cache paths,
provenance rejection/lock release, output drainage larger than pipe capacity, propagated child
failure and timeout-driven owned-child termination/reaping. They contain explicit fake workers,
not GPU physics evidence. Existing in-process cache/provenance contracts remain covered.

#66 is complete with this bounded measurement correction. #65 remains closed without adoption;
a future optimization must compare both workers under the same corrected observer. #60 retains
control/launch/graph work, #59 complete queue costs, #64 coordinated clock normalization, and
#47/#62/#63 broader numerical admission. No training/index or default solver changes.

`cpu-control.json`, `gpu-profile.json`, `verification.json`, `analysis.json`, exact experiment
programs and `experiment.log` retain the observations, hashes and procedure. The actual raw
GPU outputs remain in `bombcad-observer-profile-01a15d45/gpu-results` on the PC, with the exact
input symlinks to the prior retained fixtures. Use fresh output directories and the shared
lock to reproduce. `old-profiler.py.txt` preserves the old runner and its cache-path behavior;
`profiler.py.txt` is the actual new profiler used here. GPU source and both cache arguments are
identical in this control. No clock or service configuration changes occurred during measurement.

Validation: `make check-affected` passed strict build/lint/scripts/docs, 62 CUDA/queue/profiler
tests (four local Torch skips), 7 selected Mac tests and 36 PC tests. Measured profiler bytes
match the final implementation; the production worker matches the same-source control.
Final resource snapshot is retained in `final-resource.txt`; all owned experiment/audit/check
commands are terminal and no compute reservation remains.
