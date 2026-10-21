# Full-flat replay backlog — 21 October 2026

Automatic Metal/CUDA scheduling reduces median completion from **194.47 s to
170.13 s**, about **12.5%**, for eight independent replays of one admitted
full-flat district. Each automatic trial assigns seven jobs to Metal and one to
CUDA. This demonstrates a bounded reference-replay throughput benefit from
independent-job spillover, not a faster CUDA solver or broader dataset admission.
Tracking: [emmettl/bombcad-work#59](https://github.com/emmettl/bombcad-work/issues/59).

Measurements use producing source/controller revision `586b36b4` and the retained
executable/runtime hashes. Later upstream changes were integrated after timing.

## Workload and calibration

The existing admitted `made-perimeter-s1-1` physical case: radius 1,024 m, dx 4 m,
200,800 kg, saturated ground, mapped start, first-phase targets. The production
Metal reference has 512 × 512 × 59 cells (15,466,496 cells), 2,645 steps and reaches
about 4.51 s. Eight newly generated production references differ only by replay
identifier. Their numerical files agree bit for bit and each passes the historical
production reference gate. This is intentionally one repeated physical case,
not eight distinct scenes or useful new training examples.

Reference generation is outside all queue timing. Every queued execution still
prepares/runs/validates its own result; CUDA uses fresh Mac preparation and the
existing persistent PTX cache setting. No cached retry or training index is used.
The source, binary, runtime resources, inputs, references and costs are pinned.
Normal Mac gpu-slot and PC shared training/simulation locking remain in force;
no physics, precision, numerical gate, host clock or service setting changes.

Three isolated complete one-case controller intervals per backend calibrate the
costs for these physically identical replay labels:

| Backend | Median controller interval, s | Range, s |
| --- | ---: | ---: |
| Metal | 23.145 | 22.870–23.413 |
| CUDA | 84.255 | 83.841–85.984 |

These are approximate per-job estimates, not exact multi-case costs. The initial
plan predicts about 185.16 s for all Metal and 162.02 s for seven Metal plus one
CUDA. Actual queue intervals include extra multi-case controller/publication work.
The predicted backend assignments match all included automatic trials.

## Included queue results

| Paired round | Metal-only, s | Automatic, s | Reduction |
| --- | ---: | ---: | ---: |
| 1 | 191.992 | 175.598 | 8.5% |
| 2 | 195.864 | 170.092 | 13.2% |
| Replacement 0 | 194.468 | 170.135 | 12.5% |
| Median | **194.468** | **170.135** | **12.5%** |

Policies run sequentially, with order reversed for round 1. The replacement pair
runs last; this is not randomized A/B. Both included policies use the same drained
stdout/EOF observer with bounded `communicate`; outer intervals use Mac
`time.perf_counter`, including controller startup/probing, publication and teardown.
Initialization and pre/post availability snapshots are excluded. Nested worker
RAW timings are retained separately and are not added to the Mac outer interval.
No owned build/test/archiving load overlaps timing.

All included automatic trials dispatch replay 3 to CUDA concurrently with Metal.
All 48 included policy jobs and six calibrations pass the unchanged target gate
and accept once. Within each backend, numerical hashes agree across all replay
identifiers and repetitions. This does not assert bit equality between Metal and
CUDA. All 70 accepted executions, including excluded data below, have provenance
and terminal process-group checks.

## Resource interruption and exclusion

The original round 0 completed in 201.594 s Metal-only and 171.305 s automatic.
The automatic post-trial snapshot found a different checkout's GPU check holding
a Mac slot. The next trial therefore stopped at its preflight gate before any
attempt launched. Exact overlap with the measured automatic interval was not
proved. Conservatively, the entire pair is excluded from performance summaries
and retained in full, including its unaffected Metal-only member. No performance
threshold is used for exclusion.

All 22 workers from calibration/original round were verified terminal. The next
initialized queue had zero attempts; continuation reused that untouched queue,
not any already executed job. The coordinating sessions reported no planned GPU
work, and actual slots were checked again before continuation. One continuation
preflight declined to start before any worker launch; its exception log is retained.
An earlier harness setup error (missing advisory-probe metadata) also launched no
worker and is retained separately.

For all six included trials, ownership is additionally sampled after each ten-second
controller observation interval. A live slot owner outside the known case-worker
process groups interrupts the controller; active workers are allowed to finish
under their existing locks. None was detected in 106 included samples; before
and after snapshots also meet the quietness predicate. Sampling cannot rule out
brief unsampled work or unrelated CPU activity. This is a consumer-host experiment,
not proof of exclusive laboratory conditions. The included protocol and its
additional observer work are identical for both policies.

## Clock and scope limits

The seven CUDA worker clock audits (including the excluded trial) show adjusted
monotonic versus RAW differences of about −8.55 to −8.32 ppm over their worker
intervals, consistent under load with the normalized clock policy. This is
operational rate-consistency evidence for
[emmettl/bombcad-work#64](https://github.com/emmettl/bombcad-work/issues/64), not
new independent Windows-QPC/UTC calibration or reboot verification. Continue RAW
worker timings; do not rescale historical measurements.

The result applies to a warm-cache backlog of one physical case with existing
production references. It does not prove gains for diverse districts, a single
job, cold caches, arbitrary contention, training, or newly generated cases without
matching references. Broader generation remains governed by
emmettl/bombcad-work#47, emmettl/bombcad-work#62 and emmettl/bombcad-work#63.
emmettl/bombcad-work#59 remains open for operational integration beyond reference
replay and cost validation across distinct admitted long-running cases.

## Evidence and restoration

`study.json`, `calibrated-costs.json`, `audit.json` retain all outcomes, excluded
rows, exact costs, assignments, numerical identities, ownership samples and clock
audits. `study.py` and `continue.py` are exact run-specific controllers. Initial
setup/preflight logs are retained; they are not timed trials.

`state.tar.gz` retains the synthetic OSM input, historical/new production
references and complete plans/contracts/attempts/prepared inputs/gated outputs/logs.
Identical immutable NPY/binary/shader payloads use tar hard links inside the archive;
state/lease/JSON files remain independent. `archive-files.json` records every file
hash, and all 1,395 archived file bytes were independently audited. All 280 accepted
dataset-file instances match their receipts. Extract into a new directory for
inspection; byte-copy linked payloads before modifying them. Paths, host identity
and frozen controller pins are run-specific: create new queues for reproduction,
rather than executing these historical queues with changed paths or sources.

Validation: `make check-affected` passed (71 CUDA/queue/profiler tests, four local
Torch skips; strict build without warnings, lint/scripts/docs, selected seven Mac
and 36 PC tests). JSON parses and reproduction scripts compile. The post-run
read-only `host-after.json` retains same-boot PHC0/Normal tracking and unchanged
guest inactive/masked policy; shared lock absent and GPU idle.

After integrating independent upstream commit `b8cd063c`, `make check-affected`
also passes with 71 CUDA/queue/profiler tests (four local Torch skips), 35 Mac
and 54 PC tests, strict build/lint/scripts/docs. `check-integrated.log` retains
that check. No measurements were rerun on the upstream change; producing source
remains `586b36b4`.
