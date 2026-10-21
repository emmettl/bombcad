# Heterogeneous compute: Mac and NVIDIA PCs

Status and first experiments, 21 October 2026. The desktop PC adds an independent CUDA execution
resource; it does not automatically pool its 12 GB VRAM with the Studio's unified memory.
Prefer whole jobs and infrequent handovers first. Splitting a tightly coupled simulation remains
an experiment, not an established speedup.

## What exists

- Metal remains the full production solver and numerical reference. The Studio prepares CUDA
  initial states, grids and fixed geometry.
- The [generated CUDA worker](cuda-backend.md) runs uniform air and static terrain, including
  fitted afterburning and cooling. Refinement, moving bodies, structural mechanics and several
  other physics modes are explicitly unsupported. Its numerical kernels derive from production
  source rather than a separately maintained Riemann solver.
- The [PC training runner](learned-models.md) uses the same desktop GPU lock as CUDA simulation.
  Training has actually run on the PC; historical setup-only passages are not current status.
- [Mac distributed workers](distributed-computing.md) already share independent runs and provide
  consumer extraction/transport. Those capabilities do not automatically extend to CUDA.

The retained CUDA acceptance includes small fixtures, static terrain and a 256 × 256 × 44 district.
That district's 5.7 s solve excludes setup, compilation and transfers. It is not an end-to-end
speedup measurement. A concurrent session's broader dataset pilot found two first-phase impulse
values outside the existing tolerance on a terrain case; a fresh production-Metal reference
reproduces the stored reference. [#47](https://github.com/emmettl/bombcad-work/issues/47) owns
that investigation. Passing existing fixtures does not authorize generalizing acceptance to all
training cases, and scheduling must keep that gate.

## Options and order

| Option | Status and next useful experiment |
|---|---|
| Independent field jobs, sweeps and uncertainty cases | A [bounded replay queue](field-queue.md) now handles explicit recommended uniform/terrain field cases with per-case gates and total-cost estimates. Other physics stays in existing Metal workflows; broader evaluation remains open. [#59](https://github.com/emmettl/bombcad-work/issues/59). |
| Simulation/training pipeline | Both stages exist. Use separate machines concurrently or alternate bounded batches on one PC; never bypass the shared lock. Add automated generate/train/judge only after acceptance and resumable scheduling work. |
| CUDA worker optimization | Profile cold/warm startup, per-step control readback, dispatches and cooling before changing algorithms. [#60](https://github.com/emmettl/bombcad-work/issues/60). |
| Separate one-way physics consumers | Replay compact extracted fields for thermal exposure, later damage or other effects. CUDA ports and scientific validation are additional work. Begin with thermal replay economics, [#61](https://github.com/emmettl/bombcad-work/issues/61). |
| RTX geometric ray queries | OptiX is a candidate for occlusion. Integration through luminous gas remains compute work. Compare against existing Metal rather than assuming NVIDIA wins. |
| Active selection of training cases | Models select uncertain/failed cases for the numerical solver, which supplies checked targets. Feasible after scheduling; judge held-out layouts and damage outcomes under emmettl/bombcad-work#33/emmettl/bombcad-work#35 rather than training loss alone. |
| Two PCs doing learning | First distribute independent architectures, seeds and evaluations. Multi-host synchronized training needs a measured benefit and link/memory analysis; a second 12 GB card does not automatically give a model 24 GB. Laptop availability and sustained performance are unverified here. |
| Air on PC, structure on Mac | Requires a structural interface, repeated transfers and coupling stability checks. Strong two-way coupling and structural cost may dominate; not a first port. |
| One grid split between Metal and CUDA | Requires halo exchange, global CFL coordination, load balancing, supported physics and reproducibility across different arithmetic. Reassess only after quiet link and per-device measurements. |
| CPU preparation and postprocessing | Geometry, data checks, scoring and replay can overlap GPU work where dependencies allow. Measure CPU/memory/I/O contention too. Existing CPU fragment work is cheap enough that remote offload need not pay. |
| Offline rendering | Existing USD/volume export can feed another renderer on the PC. Useful for keeping rendering off the simulation GPU; a separate workflow from solver acceleration. |
| Other portable APIs or neural acceleration | CUDA already provides a working NVIDIA path. Vulkan/WebGPU/SYCL or Mac neural inference need a specific measured portability/deployment benefit before another backend is justified. No such experiment was run here. |

The old [distributed analysis](distributed-computing.md) predominantly considers the Studio and
mini. Its hardware-specific speedup estimates cannot be reused for this pairing. Its principles
still apply: frequent synchronization penalizes small jobs; independent jobs avoid that cost;
one-way consumers can trail the solver; inseparable physics limits speedup.

## Experiment 1: actual SSH route while PC is busy

Reproduce with `python3 Scripts/cuda/link-probe.py bombcad-pc --out NEW.json --context 'describe load'`.
The script opens one persistent connection, waits for a remote Python ready message, then checks
exact echoed bytes. It launches no CUDA kernels and writes no remote files. Total payload is
about 15.3 MiB each way. Remote lock and GPU snapshots are recorded before and after.

[Raw results](../Benchmarks/HeterogeneousCompute/2026-10-21-link-busy.json): desktop
RTX 3080 Ti, 3,178 MiB used, 99% GPU utilization, same dataset-job lock owner at both snapshots.
Active sessions were notified; no lock was removed or borrowed. Measurements include Python,
SSH encryption, local pipes, buffering and the network; route capacity and one-way bandwidth
were not isolated. This is a **busy-host application measurement**, not an idle network benchmark.

| Payload each direction | Repetitions | Median echo round trip |
|---|---|---|
| 1 byte | 20 | 23.8 ms |
| 64 KiB | 5 | 78.4 ms |
| 1 MiB | 3 | 1.033 s |
| 4 MiB | 3 | 3.341 s |

Connection/remote Python startup took 0.611 s. At 4 MiB the aggregate out-plus-back payload rate
was 2.39 MiB/s; do not label that a one-way bandwidth. These observations favor persistent workers,
compressed/cached inputs and whole jobs. A blocking exchange every timestep could be expensive:
1,000 exchanges at the observed tiny-message median alone would total about 23.8 s. That is a
conditional cost illustration, not a measured distributed solve or an impossibility result.

Next: repeat in a coordinated quiet window, record actual link/route and SSH configuration, and
measure one-way upload/download independently. Do not inherit the Mac Thunderbolt figures.

## Experiment 2: lossless compression of real job buffers

`Scripts/cuda/compression-probe.py FILE... --out NEW.json` measures three local CPU zlib encodes
at levels 1 and 6, one decode, and exact reconstructed bytes. The source files are read only;
source hashes and sizes are retained. No PC GPU work is involved.

[Raw results](../Benchmarks/HeterogeneousCompute/2026-10-21-compression.json) use the terrain
pilot's exported initial state and returned target array. The initial state is predominantly
still air, whereas the output fields vary spatially.

| Buffer | Level 1 size reduction | Median encode | Level 6 size reduction | Median encode |
|---|---|---|---|---|
| Initial conserved state | 144.5× | 0.212 s | 412.1× | 0.440 s |
| Completed target array | 1.80× | 0.035 s | 1.86× | 0.048 s |

All lossless round trips pass. Strong initial-state compression supports the other session's
existing compressed input deployment. Output compression looks worth measuring end to end but
has much smaller gains. This local zlib experiment is **not** a measurement of `scp -C`, its
compression level, compression on the PC, or transfer speedup. No transport default changed.
Before adopting output compression, include encode/decode, worker startup and retrieval times.

## Experiment discipline and tracking

Reserve GPU experiments through `~/bombcad-ml/lock` and coordinate with the active dataset/training
owner. On the Mac use its existing `gpu-slot`. Record load, lock ownership, hashes, device/software,
setup, transfers and solve separately; report contended observations separately from quiet runs.
Do not run a competing benchmark to estimate how fast an occupied GPU would have been.

- [#59 capability-aware independent job scheduling](https://github.com/emmettl/bombcad-work/issues/59):
  a bounded reference-replay queue is implemented and recovery-tested; finer Metal phase accounting and larger queue evaluation remain.
- [#60 CUDA profiling and dispatch/control experiments](https://github.com/emmettl/bombcad-work/issues/60):
  quiet repetitions and full correctness gates before a performance claim.
- [#61 thermal replay feasibility](https://github.com/emmettl/bombcad-work/issues/61):
  transfer/cadence budget before a CUDA/OptiX port; stop if local Metal remains preferable.

These are scoped follow-ups, not commitments to port every subsystem. emmettl/bombcad-work#47 retains the terrain
acceptance blocker and dataset generation. emmettl/bombcad-work#22 retains the thermal model discrepancy; faster
execution does not repair a model error.

Technical references: [CUDA Graphs](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cuda-graphs.html)
can reduce repeated launch setup; [OptiX](https://developer.nvidia.com/designworks/optix/download)
provides programmable accelerated ray tracing. Their benefit to these workloads remains to be measured.

## Experiments 3–5: isolated worker overhead and compilation reuse

The PC became idle after emmettl/bombcad-work#47's pilots. `Scripts/cuda/profile-worker.py` takes the shared lock
for the entire experiment, alternates baseline/candidate order and hashes every raw output,
NumPy array and timestep history. It refuses an accepted report if any bytes differ. These
runs used the same generated source, RTX 3080 Ti, driver 617.42 and existing CUDA environment;
GPU snapshots, source/worker hashes and all individual timings are retained in each JSON.
Snapshots do not measure all external CPU, power or clock variation.

First, an isolated candidate reused identical prepare-uniform buffers, leaving every equation
and CFL value unchanged. [Short 64³ trajectories](../Benchmarks/HeterogeneousCompute/2026-10-21-worker-cache-small.json)
showed no consistent end-to-end gain. With duration extended from 0.002 to 0.05 seconds
(568 blast steps and 552 cooling steps), [longer trajectories](../Benchmarks/HeterogeneousCompute/2026-10-21-worker-cache-long.json)
showed modest gains, but a later **timing-only** variant also changed observed solve time.
The attribution is therefore uncertain. This optimization was **not adopted**. Its
[experimental patch](../Benchmarks/HeterogeneousCompute/uniform-cache-experiment.patch) is retained
against the uninstrumented worker at commit 0ae90f53 for reproduction.

Next, [timing instrumentation](../Benchmarks/HeterogeneousCompute/2026-10-21-worker-timing.json)
showed median NVRTC compilation around 0.98 seconds per run, compared with 0.20 seconds of blast
solve or 0.36 seconds of cooling solve. All outputs and timestep histories remained bit-identical.
The timings are now available in production worker reports without per-step instrumentation.

That motivated an **opt-in persistent PTX cache**, keyed by generated source, architecture,
compiler flags, and hashes of NVRTC and its companion builtins binaries. Entries include a PTX
checksum; corrupt/partial entries are rebuilt and atomically replaced. The precision flags and
all numerical kernels remain unchanged. Hashing compiler binaries still costs time on a cache hit.

Three alternating pairs per case were run both
[in one interpreter](../Benchmarks/HeterogeneousCompute/2026-10-21-worker-ptx-cache.json) and
[in fresh Python processes](../Benchmarks/HeterogeneousCompute/2026-10-21-worker-ptx-fresh.json).
The fresh-process results, including Python/PyTorch startup, are:

| 64³ job, 0.05 s simulated | Uncached median worker process | Cache-enabled median worker process |
|---|---|---|
| Blast, 568 steps | 2.596 s | 1.540 s |
| Cooling, 552 steps | 2.666 s | 1.684 s |

The first cache-enabled blast invocation was a cold miss (2.602 s); the subsequent two were hits.
Cooling used the already populated cache because the generated program/flags were identical.
Every baseline/candidate pair produced bit-identical complete arrays and timestep histories.
Compilation is cached, not solution state. Solver time is effectively unchanged in this test.
These totals exclude SSH deployment and retrieval. They do not establish a speedup for a full
training-scale district, a larger grid, a different compiler or thermal model, or the full app.

To reproduce on an isolated PC experiment folder, copy the worker, `job.py`, `compile.py` and
lock helper beside both variants; generate matched 64³ blast/cooling fixtures with `fixtures.py`,
and set `duration` to 0.05 in each job manifest. Use `run.py` from 0ae90f53 as the original baseline,
or the timing-instrumented worker without a cache as in the final comparison. Run:

```sh
~/bombcad-ml/venv/bin/python profile-worker.py \
  --baseline baseline.py --candidate candidate.py --source solver.cu \
  --jobs blast-long cooling-long --out NEW-RESULTS \
  --lock ~/bombcad-ml/lock --lock-helper remote-train.py \
  --candidate-cache-dir NEW-CACHE --fresh-process
```

Keep output/cache directories new to reproduce the cold-miss observation. The helper must be
the existing `Scripts/ml/remote-train.py`; the benchmark does not bypass that lock. Optional
remote deployment uses `remote.py --cache-dir bombcad-cuda/ptx-cache`. Default worker deployments
remain uncached. Next on emmettl/bombcad-work#60: representative larger-grid/terrain stage timings and allocation,
control-readback or cooling profiling; retain emmettl/bombcad-work#47's acceptance gate before bulk generation.

## Numerical gate follow-up: first-phase labels

The next diagnostic stage found why the terrain phase targets diverge: a pressure difference
of hundredths of a pascal can change the exact-zero phase-closing decision and include or exclude
a later positive tail. Matched safe Metal itself fails one production target, while fast/fused
standalone Metal reproduces the entire first-phase plane within the existing gate. This is
label sensitivity, not evidence of a large sampled-pressure discrepancy or permission to relax
the dataset gate. See [the diagnosis and complete histories](cuda-backend.md#diagnosing-first-phase-acceptance-21-october-2026).

Read-only opt-in tracing and a float32 replay tool are available; diagnostic-only remote retrieval
avoids transferring large fields. [#62](https://github.com/emmettl/bombcad-work/issues/62) tracks
justified phase semantics and validation. emmettl/bombcad-work#47 remains open. Beirut traces demonstrate near-zero closure sensitivity at two more phase
points; the direct follow-up now confirms the third. Fast standalone Metal still fails the peak
gate, so a precision switch is not an established fix. Backend scheduling and performance work
must preserve those acceptance dependencies.

Direct production observation now confirms all five problematic phase closures, including the
remaining Beirut point, while preserving both original datasets bit for bit. A same-kernel
all-tiles control also preserves every Beirut export array, while production's full-grid path
fails 64 peak/two phase targets against its tiled path. Skipping still tiles is therefore not
the explanation for these differences in this case; kernel/execution arithmetic remains to be
isolated. See the [production controls](cuda-backend.md#direct-production-observation-and-execution-path-controls).

The paired production safe/unfused experiment makes tiled and full-grid exports bit-identical.
That isolates arithmetic-mode-sensitive path variation for the Beirut case; it does not prove
which compiler transformation causes it. Safe production still fails seven peak/six phase
points against default production, and CUDA still fails against the safe reference. emmettl/bombcad-work#63 tracks
the separate peak portability contract; emmettl/bombcad-work#62 tracks label conditioning. These findings do not
enable a full CUDA batch or justify changing the acceptance gate.

Explicit contraction-on **and** contraction-off each make the Beirut tiled/full-grid pairs
bit-identical under fast and safe math. Bridge controls rule out merely constructing explicit
fast options as the cause. Thus an explicit contraction policy removes this case's path
variation without proving that fusion must be disabled. None of those variants passes the
original gate. The six-outcome reference spread and an offline phase-band sweep are retained
as diagnostics; an analytic weak-wave counterexample shows why a band that repairs selected
points cannot simply become the target rule. emmettl/bombcad-work#62/emmettl/bombcad-work#63 remain policy/validation work, not resolved
by a precision switch or larger tolerance. See the backend documentation for full receipts.

A concrete emmettl/bombcad-work#60 gain is now integrated: bounding the CUDA cooling work preserves complete
Beirut outputs/timesteps bit for bit while three paired runs reduce median solver time from
88.90 to 65.90 seconds (worker total 93.20→70.12 seconds, excluding SSH and cold Python startup).
The integrated default and full-grid fallback also pass luminous/empty controls. This improves
worker throughput; it changes neither the numerical gate nor the unresolved label contract.


## Thermal transport audit and idle-at-start link repeat

The [retained repeat](../Benchmarks/HeterogeneousCompute/2026-10-21-quiet-link.json)
used the same bounded echo probe with the shared GPU lock absent and GPU utilization 0% before,
1% after. PC-session coordination was sent before measurement; this is an idle-at-start observation,
not proof of exclusive CPU/network use. Setup took 0.460 s. Median tiny-message RTT was 26.0 ms;
64 KiB, 1 MiB and 4 MiB each-way echoes took 0.103, 1.129 and 5.084 s respectively.
All bytes matched. The largest echo was slower than the earlier busy-GPU run, so GPU utilization
alone cannot explain link performance. These are application round trips, not one-way bandwidth.

The transport audit for emmettl/bombcad-work#61 found that `FrameInput.payload` sends `LuminousCells.binary`,
not the march's compact directional tiles. Its 32-byte header precedes a voxel box of at most
1,048,576 cells, at 3, 5 or 7 bytes per cell depending on optional products/absorption channels.
A full current afterburn frame can therefore be 7 MiB plus header, before shape JSON or result
traffic. Receiver fluence/peak updates and static scene setup also belong in the cost model.
The older thermal documentation's 1.6 MB maximum was stale and is corrected.

This strengthens the case for measuring saved, representative frames and compression before a
live CUDA consumer. It does not establish a one-way transfer budget or close emmettl/bombcad-work#61. The next
experiment must capture actual evolving fields, scene and receiver setup, measure extraction,
encoding, compressed transfer and reconstruction separately, and compare the complete sequence
with local Metal. A synthetic sphere or echo alone cannot meet that acceptance criterion.


### Recording and replaying actual thermal inputs

`blastbench snapshot --thermal spec.json --thermal-record NEW-DIR` records each actual
consumer frame: shape JSON and the existing binary cells, with static scene/spec/receiver
setup, per-frame extraction, encoding/write and local consumer times, and final reference.
The directory must be new; a completed recording has `frames.json` and `reference.json`.
Recording is synchronous diagnostic I/O and perturbs the solver's elapsed time; do not use
its total run time as an uninstrumented throughput benchmark.

`blastbench thermal --replay DIR` reconstructs the same inputs, rebuilds the receiver set,
and requires exact final fluence/peak equality with the capture. It reports read/decode,
consumer and total time. This is Mac replay, not a CUDA implementation. The static scene
is the initial consumer geometry, matching existing one-way thermal semantics.

`python3 Scripts/cuda/thermal-link-probe.py bombcad-pc DIR --out NEW.json --context "load/coordination"` selects the
first, median-size, largest and last luminous cell payloads (deduplicated), and sends each
three times raw and with zlib levels 1/6 over one SSH connection. Remote SHA256 verifies
every decoded byte; no files or GPU jobs are created on the PC. Timings include pipe/SSH,
remote decoding/hashing and a small acknowledgement round trip. Compression is timed once
per variant. This isolates cell transport; frame JSON, static setup and receiver results
remain additional costs, and no receiver computation is performed by the remote probe.

### Street replay result: defer live PC thermal offload on this route

The [complete retained experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-thermal-replay/summary.md)
captures 61 actual street frames and 10,456 receivers. Cells total 53.5 MB, shape JSON 4.08 MB,
static setup 0.715 MB. Local replay matches every final fluence/peak float exactly and takes
0.746 s after setup-file decoding. A complete input batch compressed to 10.0–10.7 MB takes
5.18–5.61 s median send/ack over SSH, plus 0.18–0.39 s compression. These timings include remote
decode/hash, but no PC thermal computation or result return. All payload hashes pass; GPU
snapshots stay idle. The original extraction and recording cost are separately retained.

For this case and route, even zero-cost PC computation cannot recover the measured transfer
cost versus the local consumer. emmettl/bombcad-work#61's feasibility decision is therefore **defer live thermal
porting**, preserving a reusable recorder/replay fixture. Offline replay remains possible;
revisit acceleration with a faster route, heavier receiver/ray work or measured Mac contention.
No claim extends this result to every scene, and no thermal-model validation threshold changes.
The probe's optional `--sequence` tests all inputs together, compressed only, with explicit
length framing; it does not run a remote volume march.


## Complete CUDA deployment and current Metal costs

The [retained #60 experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-deployment-profile/summary.md)
compares three primary uncached/primed-cache pairs on each of two cooling fixtures and a flat
district, including upload, cold process startup and retrieval. All gates pass and complete
remote numerical outputs/timesteps remain bit-identical. The flat district takes 78.11/78.76 s
median deployment, before Mac preparation; current full production Metal takes 21.38 s median,
measured on the same observer clock. Caching reduces compilation but does not improve the
observed district total. This favors an idle Mac for this case's latency; PC spillover may
still improve a queue's throughput, which has not yet been measured.

The explicit deployment profiler and timing receipts are reusable for emmettl/bombcad-work#59 cost decisions.
[#64](https://github.com/emmettl/bombcad-work/issues/64) tracks independently reproduced elapsed-clock
disagreement; worker times must not be directly compared across hosts or subtracted from the
common-observer deployment total. No new broad CUDA dataset admission is enabled.


The [follow-up clock audit](../Benchmarks/HeterogeneousCompute/2026-10-21-clock-audit/summary.md)
now isolates WSL adjusted monotonic versus raw timing: raw agrees with Windows QPC during
paired intervals; changing kernel tick discipline is consistent with the discrepancy. CUDA
worker/profiler elapsed measurements now use raw time with explicit provenance and a dual-clock
audit. Existing gates and all numerical outputs/timesteps remain unchanged. This corrects
measurement, not compute throughput. emmettl/bombcad-work#64's host discipline investigation remains open; no clock
or service settings were changed, and old receipts must not be normalized by one fixed factor.


## Resumable mixed field queue

The [field queue](field-queue.md) now freezes explicit case/reference/code identities, selects
backends with cost/memory/availability checks, respects existing GPU/training locks and publishes
gated content-addressed objects. A real three-case run includes static-terrain CUDA and uniform
Metal work, survives a busy PC, retries a terminated attempt, and resumes an active CUDA worker
after controller interruption without relaunching it. Accepted cases are reused exactly once.

[Receipts and recovery evidence](../Benchmarks/HeterogeneousCompute/2026-10-21-field-queue/summary.md)
retain the physical/calibration cases and all outcomes. This is bounded reference replay, not
bulk generation or a throughput speedup claim. emmettl/bombcad-work#59 remains open for finer phase accounting and
larger evaluation; emmettl/bombcad-work#47/emmettl/bombcad-work#62/emmettl/bombcad-work#63 admission remains gated.


### Repeated small queue costs

The [four-case queue cost study](../Benchmarks/HeterogeneousCompute/2026-10-21-queue-costs/summary.md)
repeats Metal-only, automatic and forced split policies three times. Removing irrelevant PC
probes reduces Metal-only median controller completion from 3.475 s to 1.360 s. Automatic
selection keeps all four cases on Metal (3.518 s); the forced split takes 21.142 s. These small
jobs establish an overhead floor and show why worker solve time is insufficient for scheduling.
They do not establish a CUDA throughput win. emmettl/bombcad-work#59 retains larger/repeated representative queues,
finer Metal accounting and complete-cost modelling; synchronous PC probing remained measurable in that controller.


### Per-step control waits

The [control-readback study](../Benchmarks/HeterogeneousCompute/2026-10-21-control-readback/summary.md)
compares 36 fresh-process runs across six cases, including full flat and Beirut districts.
Removing the device-wide wait before a blocking CPU control copy is numerically exact but has
mixed process-level results; it is not adopted. The separate API trace confirms that explicit
wait removal shifts waiting into blocking copies. Full flat and Beirut worker-process medians
are 47.897/47.612 s and 68.639/68.312 s, baseline/candidate. These exclude deployment/retrieval
and do not establish a heterogeneous throughput gain. The executed-worker provenance bug is
fixed, and symmetric-cache profiling is supported. emmettl/bombcad-work#60 retains pinned control-buffer reuse and
further launch/control experiments; numerical and clock-discipline gates remain unchanged.


### Pinned control-buffer reuse

The [pinned host-buffer follow-up](../Benchmarks/HeterogeneousCompute/2026-10-21-pinned-control/summary.md)
adds 36 baseline/candidate timed runs and 24 identical-worker controls. Allocation counts fall,
but full-district process times are effectively unchanged and smaller apparent gains overlap
control variation. The existing synchronization and control storage remain in production;
emmettl/bombcad-work#65 concludes without adoption. The candidate patch, complete phase timings, allocation trace,
file/provenance audit and both failure controls are retained for later work under emmettl/bombcad-work#60.


### WSL clock ownership

The [kernel clock-caller observation](../Benchmarks/HeterogeneousCompute/2026-10-21-clock-actor/summary.md)
finds accepted coarse-tick writes by VM-level chronyd alongside guest timesyncd updates on the
same timekeeper. Runtime PHC0 tracking and WSL 3.0.3 init source explain the actor missed by
Ubuntu's service list. That trace established a concrete single-owner normalization
experiment; the later controlled experiment below validates and applies the policy. Owned
tracing state was cleaned up; worker/profiler durations continue using raw elapsed time.


### Fresh-process observation precision

The [corrected profiler](../Benchmarks/HeterogeneousCompute/2026-10-21-observer-precision/summary.md)
uses drained stdout/EOF readiness rather than relying solely on timeout polling. A 30-pair CPU
control measures 8.260/1.914 ms median final-stamp-to-parent-return intervals, including teardown;
18 same-source GPU runs preserve numerical files and provenance. Distinct cache arguments are
also routed correctly in fresh processes. This closes emmettl/bombcad-work#66 as a measurement fix; it does not
promote the emmettl/bombcad-work#65 candidate or establish a solver speedup. Historical observations remain intact.

### Controlled clock ownership experiment

The [phase-acknowledged pause/restore experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-clock-normalization/summary.md)
supports duplicate clock controllers as the present feedback mechanism: median
absolute five-second MONOTONIC/RAW error was 743 ppm with both clients active,
30 ppm after pausing Ubuntu's client, and 1854 ppm after restoring it. Both
experimental cycles restored their original service configuration and released
the shared PC reservation. Longer single-owner validation and its exact final
policy receipt are retained with the experiment. emmettl/bombcad-work#64 remains open for reboot
persistence and operational stability; worker durations continue to use RAW.

Longer validation passed: maximum absolute MONOTONIC/RAW error was 19.3 ppm
for 5/15-second checks and 9.3 ppm for 60-second checks. Ubuntu-24.04
systemd-timesyncd is now inactive/masked, with WSL PHC0 retained as clock owner.
The rollback timer was removed and the shared reservation released.

### Finer Metal setup accounting

The [setup accounting controls](../Benchmarks/HeterogeneousCompute/2026-10-21-metal-setup/summary.md)
separate library loading/building, eager pipelines, allocation, initial uniform
state and scenario loading in opt-in field-export receipts. Across four small
uniform/terrain cases, both Metal execution and CUDA preparation preserve all
numerical files in 24 timed/untimed pairs. These nested host timings include
driver caching and do not establish pure compiler cost or a speedup. emmettl/bombcad-work#59 retains
complete cost calibration and larger queue evaluation.

### Cached CUDA retries

The [cached retry controls](../Benchmarks/HeterogeneousCompute/2026-10-21-cached-queue/summary.md)
verify prepared input before using cached resource/cost estimates. CUDA-only
cached retries can dispatch without Mac GPU observations; fresh preparation
still requires Mac capacity, and PC availability/VRAM/locking remain enforced.
Three real post-preparation deferral/resume controls accept once and reuse their
accepted objects, with matching numerical files. Optional `cachedCudaCosts` terms
are pinned separately; the retained one-sample worker-body estimate is functional
calibration, not a complete scheduling-cost fit. emmettl/bombcad-work#59 remains open for complete
costs and larger representative queues.

### Eight larger cases with repeated complete-cost calibration

The [eight-case replay study](../Benchmarks/HeterogeneousCompute/2026-10-21-larger-queue/summary.md)
adds three isolated controller-cost observations per exact case/backend and three
rotated queue-policy rounds. All 120 executions pass their gates and accept once.
For these 128 × 128 × 32-cell short trajectories, median completion is 3.854 s
Metal-only, 11.265 s automatic (all Metal), and 49.690 s forced four-CUDA split.
The larger grid still does not amortize CUDA deployment. Complete isolated-case
costs are an approximate model; automatic policy's extra controller time motivates
a cost-based PC-probe experiment under emmettl/bombcad-work#59. Longer full-district queues and broader
numerical admission remain separate work.

### Cost-planned PC probing

The [cost-preflight comparison](../Benchmarks/HeterogeneousCompute/2026-10-21-cost-probe/summary.md)
adopts an optimistic cost plan before paying for a PC observation. When that plan
cannot dispatch CUDA now, the controller skips SSH; when it can, actual PC
availability/VRAM and normal worker locking still govern dispatch. In the same
eight-case workload, automatic completion falls from 12.784 to 5.444 s median,
close to Metal-only controls (5.663/5.465 s). All 98 accepted executions preserve
numerical files across versions. This improves controller overhead; longer
full-district throughput and cost modelling remain in emmettl/bombcad-work#59.

### Long-running full-flat replay backlog

The [full-flat queue comparison](../Benchmarks/HeterogeneousCompute/2026-10-21-full-queue/summary.md)
shows an end-to-end benefit for independent-job spillover: three monitored
8-job pairs complete in 194.47 s median on Metal alone and 170.13 s automatically,
about 12.5% less time. Each automatic trial uses seven Metal jobs and one CUDA job.
These are independent replays of one admitted 15.5-million-cell case with existing
production references, not distinct new training examples. The original pair is
retained/excluded after another checkout's GPU check appeared; replacement trials
retain 106 ownership samples. All 70 accepted executions, including excluded
observations, preserve their gates/provenance and have terminal worker groups.
emmettl/bombcad-work#59 remains open for integration beyond reference replay and
cost validation across distinct admitted long-running cases; broader admission
remains separate. The CUDA load also retains bounded rate-consistency evidence
for emmettl/bombcad-work#64, without claiming reboot verification.


### Source reuse and a bounded graph-dispatch result

CPU offload now uses verified private staging and reuses unchanged source files from completed
snapshots, with separate mutable build caches. The [source-reuse study](../Benchmarks/HeterogeneousCompute/2026-10-21-source-reuse/summary.md)
completes emmettl/bombcad-work#70; it reduces repeated transfer/storage work while preserving
emmettl/bombcad-work#68's concurrency and recovery protections. See [Linux studies](linux.md)
for run/test/resume behavior. This is separate from GPU solver throughput.

The [steady-state graph study](../Benchmarks/HeterogeneousCompute/2026-10-21-step-graphs/summary.md)
completes emmettl/bombcad-work#71 without adoption. Grouping prepare/sweeps/terrain launches
preserves all numerical files and timesteps across 72 timed runs, and the trace confirms fewer
direct driver launches, but full-worker gains are small/mixed against same-worker controls.
Startup, per-step stop checks, dynamic cooling and prepare allocation remain. This tests one
graph scope rather than all graph/control strategies. Production behavior and numerical
admission stay unchanged. Broader work remains in emmettl/bombcad-work#60, with launch block
sizes separately tracked in emmettl/bombcad-work#72; distributed integration and data gates
remain in emmettl/bombcad-work#59 and emmettl/bombcad-work#47 / emmettl/bombcad-work#62 /
emmettl/bombcad-work#63.
