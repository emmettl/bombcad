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
| Independent field jobs, sweeps and uncertainty cases | Highest immediate priority. Route only supported cases to CUDA, keep coupled/refined cases on Metal; measure total job cost. [#59](https://github.com/emmettl/bombcad-work/issues/59). |
| Simulation/training pipeline | Both stages exist. Use separate machines concurrently or alternate bounded batches on one PC; never bypass the shared lock. Add automated generate/train/judge only after acceptance and resumable scheduling work. |
| CUDA worker optimization | Profile cold/warm startup, per-step control readback, dispatches and cooling before changing algorithms. [#60](https://github.com/emmettl/bombcad-work/issues/60). |
| Separate one-way physics consumers | Replay compact extracted fields for thermal exposure, later damage or other effects. CUDA ports and scientific validation are additional work. Begin with thermal replay economics, [#61](https://github.com/emmettl/bombcad-work/issues/61). |
| RTX geometric ray queries | OptiX is a candidate for occlusion. Integration through luminous gas remains compute work. Compare against existing Metal rather than assuming NVIDIA wins. |
| Active selection of training cases | Models select uncertain/failed cases for the numerical solver, which supplies checked targets. Feasible after scheduling; judge held-out layouts and damage outcomes under #33/#35 rather than training loss alone. |
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
  resumability, busy-worker handling, memory/physics checks, accepted outputs and total cost.
- [#60 CUDA profiling and dispatch/control experiments](https://github.com/emmettl/bombcad-work/issues/60):
  quiet repetitions and full correctness gates before a performance claim.
- [#61 thermal replay feasibility](https://github.com/emmettl/bombcad-work/issues/61):
  transfer/cadence budget before a CUDA/OptiX port; stop if local Metal remains preferable.

These are scoped follow-ups, not commitments to port every subsystem. #47 retains the terrain
acceptance blocker and dataset generation. #22 retains the thermal model discrepancy; faster
execution does not repair a model error.

Technical references: [CUDA Graphs](https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/cuda-graphs.html)
can reduce repeated launch setup; [OptiX](https://developer.nvidia.com/designworks/optix/download)
provides programmable accelerated ray tracing. Their benefit to these workloads remains to be measured.

## Experiments 3–5: isolated worker overhead and compilation reuse

The PC became idle after #47's pilots. `Scripts/cuda/profile-worker.py` takes the shared lock
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
remain uncached. Next on #60: representative larger-grid/terrain stage timings and allocation,
control-readback or cooling profiling; retain #47's acceptance gate before bulk generation.

## Numerical gate follow-up: first-phase labels

The next diagnostic stage found why the terrain phase targets diverge: a pressure difference
of hundredths of a pascal can change the exact-zero phase-closing decision and include or exclude
a later positive tail. Matched safe Metal itself fails one production target, while fast/fused
standalone Metal reproduces the entire first-phase plane within the existing gate. This is
label sensitivity, not evidence of a large sampled-pressure discrepancy or permission to relax
the dataset gate. See [the diagnosis and complete histories](cuda-backend.md#diagnosing-first-phase-acceptance-21-october-2026).

Read-only opt-in tracing and a float32 replay tool are available; diagnostic-only remote retrieval
avoids transferring large fields. [#62](https://github.com/emmettl/bombcad-work/issues/62) tracks
justified phase semantics and validation. #47 remains open. Beirut traces demonstrate near-zero closure sensitivity at two more phase
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
points against default production, and CUDA still fails against the safe reference. #63 tracks
the separate peak portability contract; #62 tracks label conditioning. These findings do not
enable a full CUDA batch or justify changing the acceptance gate.

Explicit contraction-on **and** contraction-off each make the Beirut tiled/full-grid pairs
bit-identical under fast and safe math. Bridge controls rule out merely constructing explicit
fast options as the cause. Thus an explicit contraction policy removes this case's path
variation without proving that fusion must be disabled. None of those variants passes the
original gate. The six-outcome reference spread and an offline phase-band sweep are retained
as diagnostics; an analytic weak-wave counterexample shows why a band that repairs selected
points cannot simply become the target rule. #62/#63 remain policy/validation work, not resolved
by a precision switch or larger tolerance. See the backend documentation for full receipts.
