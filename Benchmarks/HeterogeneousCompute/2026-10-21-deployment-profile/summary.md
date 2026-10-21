# Fresh-process CUDA deployment costs, 21 October 2026

This experiment measures already-exported jobs from local validation to verified returned
provenance and byte counting. It does not include Mac scene preparation, GPU initial-state
export, caller availability probes, or target comparison. Comparison and retained-field
hashing are recorded separately; priming is retained but excluded from paired medians.
A separate current Metal series and initial-state export series provide a case-level comparison
on the same Mac observer clock; they are described below, not inferred from worker clocks.

Plan: 32³ and 64³ cooling fixtures retrieve all outputs; the 512×512×59 flat district retrieves
only training arrays and provenance, leaving raw fields on PC. The first small job primes a new
PTX cache. Each job then runs three alternating uncached/primed-cache pairs, each with fresh
SSH/scp and Python processes. “Uncached” means no PTX artifact cache; OS caches and driver state
are not reset. No precision, kernel, timestep or acceptance rule differs across modes.

The worker holds the existing shared GPU lock while solving. Before/after snapshots require
the cooperative lock to be free and GPU utilization at most 5%; snapshots and ownership context
are retained. These observations exclude a known cooperating workload, but cannot prove total
network/CPU isolation. Input upload and retrieval show appreciable variation. Do not attribute
whole-deployment differences to compilation merely because the cache setting differs.

Every deployment checks the original Metal gate (full fields for small fixtures, production
training targets/features/mask for the district). It also SHA256-checks every raw numerical
output/timestep on the PC across all six runs of each job, including dataset-only retrieval.
No output is published into an accepted training dataset. The broader terrain/Beirut #47
failures remain gated; this flat-case timing experiment does not resolve them.

All local phase durations share the Mac clock. Worker timings use an independent PC clock;
they describe work within the remote process but must neither be added to local phases nor
subtracted to estimate startup overhead. One PC worker interval exceeds its enclosing Mac
remote-process observation, so cross-host subtraction is demonstrably unsuitable here. Local
receipt totals remain the direct measurements for deployment decisions.

The report pins profiling/controller/worker hashes. Reference hashes sampled after the first
32³ pairs, before the 64³/district measurements, are rechecked at completion; they are not
claimed to be a pre-run hash for those first pairs. The input manifests, comparison receipts,
remote file hashes, device/driver and individual repetitions are retained. Inputs and references
remain in their explicit scratch/archive paths; manifests make their content identities clear.


## Results

Primary medians below use three observations per cell. The original third district pair is
retained in `profile.json` but excluded because local lint/script tests overlapped it. The check
was stopped during local script tests, before the PC CPU lane could start. Replacement pair 3
and recomputed medians are in `repeat-pair.json`; no observations were silently discarded.

| Job / retrieval | Uncached deployment | Primed-cache deployment | Uncached / primed compile, PC clock |
|---|---:|---:|---:|
| 32³ cooling / all | 9.179 s | 8.192 s | 1.107 / 0.184 s |
| 64³ cooling / all | 15.978 s | 13.829 s | 1.093 / 0.182 s |
| Flat district / dataset | 78.113 s | 78.758 s | 1.094 / 0.175 s |

Compilation gets cheaper with the cache, but the district's total does not improve in this
series. There is no numerical solver change. In the primed district series, phase medians are
21.19 s input upload, 47.80 s remote process, 7.95 s retrieval and 1.41 s worker upload.
The input has 589,043,109 file bytes; returned files are about 10.49 MB. These are uncompressed
file sizes, not wire traffic. Phase medians need not sum to the median total. Gate/hash costs
are outside deployment and retained separately (district median about 0.95 s).

Three fresh production Metal `scenebench field-export` runs under a Mac gpu-slot take
22.424, 21.333 and 21.380 s end to end (median 21.380). Three matching CUDA initial-state exports
take 2.486, 2.409 and 2.499 s (median 2.486), before deployment. Every exported physical-buffer
hash and control matches the input used in the PC series. All three current Metal datasets
are bit-identical; all eight district CUDA datasets (including the excluded timing pair) pass
the existing target/features/mask gate against fresh Metal. `mac-profile.json` retains commands,
executable, runtime Metal and input hashes, with `matched-gates.json` for the comparisons.
The Mac series excludes gpu-slot waiting and was not continuously GPU-telemetry instrumented;
no known competing solver was launched, but total hardware isolation is not proven.

For this workload and route, observed case latency favors an idle Mac: even CUDA deployment
alone exceeds the complete Metal case, before adding Mac preparation or acceptance comparison.
This is not a measured mixed-queue throughput result. An available PC can still process work
while the Mac is occupied; #59 should use complete measured costs and availability, not assume
that an RTX solver is faster. Broad CUDA batch generation remains gated by #47/#62/#63.

## Clock diagnostic and follow-up

The read-only five-second sleep probe reproduces disagreement: PC monotonic 5.005/5.007/5.010 s
versus Mac round trips 4.900/4.901/4.910 s. Mac wall and perf-counter intervals agree; PC wall
reports 5.005/5.007/4.151 s, with an apparent step in the final sample. Raw samples and the exact
probe are retained. [#64](https://github.com/emmettl/bombcad-work/issues/64) tracks calibration,
independent reference and clocksource/time-sync diagnosis. No clock settings were changed and
no root cause or absolute clock authority is inferred. Case/deployment comparisons above use
the same Mac observer clock, avoiding direct PC-versus-Mac solver-time comparison.

#60 stays open for per-step dispatch/synchronization profiling and any measured reversible
optimization. These results provide total-cost evidence; they do not establish a CUDA Graphs
benefit or relax numerical gates. No packages, driver or toolkit were installed.

Validation: `make check-affected` passed (strict build/lint, script and document checks,
35 Mac tests in seven suites and 54 PC tests in 12 suites). Final document links and whitespace checks
passed after the report additions. Complete check output and the interrupted earlier local
check are retained. All experiment processes are terminal; recheck current locks before new work.

The post-experiment environment snapshot retains PyTorch 2.11.0+cu128, CUDA 12.8, NVRTC
library hashes and the verified cache-entry checksum. The observed WSL clocksource is `tsc`;
this is a diagnostic fact, not an established cause of the clock disagreement. Final PC GPU
lock is free, with 1% utilization/876 MiB at the last observation.
