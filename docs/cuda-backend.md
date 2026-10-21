# CUDA training-data backend

An optional headless worker for generating learned-model reference fields on an NVIDIA PC.
It executes BombCAD's numerical method; it does not use a learned approximation. The app and
its default Metal solver are unchanged.

## What runs where

The Mac loads the district, constructs the grid and fixed-obstacle mask, and initializes the
charge exactly as the Metal run does, including its one-dimensional mapped start when used.
It exports a checksummed, versioned job. The PC performs all subsequent uniform-grid air
steps and produces peak pressure, positive impulse and optionally first-phase impulse targets.
The existing CPU/Linux tools can prepare layouts, score results and train models independently.

Supported: uniform grids; stationary whole-cell obstacles and static terrain cut cells; ideal, thermally perfect and
production dissociating-air equations; HLLC or HLL fluxes; reflective/copy/far-field boundaries;
transport and fitted afterburning of fuel and oxygen; radiative cooling; production startup CFL
ramping, alternating sweeps and receiver interpolation. Dissociating air and HLL are available
from the translated equations but not covered by the initial acceptance record below.

Not supported: refinement, structural cut cells, gravity, sub-grid mixing, mixing- or
extinction-limited burning, deflagration, congestion, periodic boundaries, moving bodies,
structural mechanics, delayed events or glazing venting. The exporter and worker refuse these
rather than substituting different physics. Static terrain retains the production volume fractions,
face apertures, wall normals and conservative defect redistribution.

## Using it

On the Mac, from the repository root:

```sh
python3 Scripts/cuda/generate.py --out /tmp/bombcad-uniform.cu
swift run -c release scenebench field-export \
  --osm Samples/MapBuildings/synthetic-neighbourhood.geojson \
  --centre 0.00045,51.50028 --radius 48 --dx 2 --height 32 \
  --mass 10 --until 0.08 --above 1 --first-phase \
  --cuda-job --cuda-source /tmp/bombcad-uniform.cu --out /path/to/new-job
python3 Scripts/cuda/remote.py bombcad-pc /path/to/new-job --out /path/to/new-result
```

Wrap the Mac's GPU command in `~/.local/bin/gpu-slot --mem 2` as for other solver work. Both
output directories must be new. The generated source must match the job's SHA-256. Jobs include
buffer hashes; corrupt files, unsupported versions and mismatched source are rejected.

The PC needs an existing PyTorch/CUDA environment with NVIDIA NVRTC (the training environment
at `~/bombcad-ml/venv` works). No system compiler or toolkit is installed by the deployment.
`--python` selects another existing remote interpreter. SSH uses the user's configured alias.
Deployment sends only worker code and manifest-listed job files, takes the existing
`bombcad-ml/lock` shared with training, runs, and brings results back. A busy GPU lock causes
failure instead of running alongside the owner. Versioned deployments/results remain in
`~/bombcad-cuda/` on the PC for inspection.

`result/dataset/` contains the existing `inputs.npy`, `mask.npy`, `targets.npy` and `meta.json`
format; targets have two channels, or three with `--first-phase`. The metadata records CUDA
provenance, requested configuration, actual time reached and device. Raw final conserved states,
species, accumulated fields and timesteps are also retained outside that directory for auditing.
A job template has `stable: false` and no `targets.npy`: it cannot be mistaken for completed
training data. Failed or incomplete simulations do not write a completed dataset manifest.

## Numerical contract

`generate.py` obtains the sweep, CFL preparation, thermodynamics, first-phase recorder and
cooling's medium/ray/loss equations from the production Metal files. The CUDA adapter changes
address spaces, vector syntax and kernel entry points. It does not keep a second hand-maintained
Riemann solver. Vector buffer strides are explicit, especially the 8-byte species pair.

The initial CUDA mode uses float32, no FMA contraction, precise division/square root and preserved
subnormal values. Metal and CUDA are not promised bit-identical: library arithmetic and
compiler choices can still differ. The default Metal solver also contracts arithmetic. Both
matched unfused comparisons and an actual production-Metal training pair were checked.

Cooling follows the same 13 lattice directions in order, both ways, with the same medium,
absorption and energy cap. The worker now bounds ray traversal and energy application by the
positive-opacity medium, skipping empty evaluations while preserving the cooling-clock reset.
The medium pass and dispatch envelope still cover the full grid. `--full-grid-cooling` retains
the original work selection as a diagnostic fallback; equations and precision are identical.
Repeated complete-field/timestep equality and performance measurements are recorded below.

## Acceptance, 21 October 2026

The [retained metrics](../Benchmarks/CUDAAcceptance/2026-10-21.json) were measured on an
Apple M4 Max and the user's RTX 3080 Ti:

- Eight 32-cubed fixtures: still air, shock, blast, fixed obstacle, hot air, afterburning,
  far-field boundaries and a closed domain. All complete-state, species, peak, impulse and
  first-phase comparisons pass `0.05 + 0.002 * abs(reference)` per float. Still air is exact;
  state/peak/impulse relative L2 errors are around 10^-7, first-phase records below 10^-5.
- A ninth luminous, reacting fixture with radiative cooling passes the same gate.
- An actual 13-building synthetic neighbourhood, 48 x 48 x 16 cells, 10 kg, 80 ms,
  recommended thermodynamics and cooling, first-phase recording: both production Metal and CUDA
  take 56 steps. Against the production Metal training targets, relative L2 errors are
  1.16e-6 (peak), 9.39e-7 (positive impulse), 9.37e-7 (first-phase impulse), with no valid target
  outside that per-value gate. Peak's 99th-percentile relative error above 100 Pa is 0.015%;
  impulses' above 0.1 Pa s are 0.077%. Input features and masks agree exactly.
- The SSH deployment command runs that job on the PC and retrieves the training pair.

Two additional production-Metal pairs use the same district over a planar slope and a curved hill,
made by `python3 Scripts/cuda/terrain-fixtures.py /path/to/terrain`. Supply the resulting
`--dem /path/to/terrain/slope.asc` or `hill.asc` to the export command above. Both retain cooling,
afterburning and first-phase recording. Slope takes 61 steps on both devices; hill takes 58.
All complete-state comparisons pass the same tolerance. Production training targets have relative
L2 errors below 1.1e-6, with exact features and masks. The terrain source hash and full metrics are
in [the terrain acceptance record](../Benchmarks/CUDAAcceptance/2026-10-21-terrain.json).

The nine uniform fixtures were also repeated at 64³ cells with the terrain-capable worker.
All pass the same complete-field gate; still air remains exact. Their full metrics are included
in the terrain acceptance record.

A planned training-scale case (made-up grid, seed 3, sloped ground, 30 tonnes, 512 m radius,
4 m cells) places 1,176 buildings in a 256 × 256 × 44 grid. Both backends take 1,229 steps
to 2.25 s. CUDA takes 5.7 s for the simulation, excluding initialization, compilation and
SSH transfer; this is not a speedup claim. Production target relative L2 errors are 9.49e-8
(peak), 6.12e-7 (impulse) and 4.70e-7 (first-phase impulse), with no valid target outside the
same tolerance. Features and masks agree exactly; every final cell has positive density and
internal energy. The acceptance record retains these measurements.

A closed-boundary sloped-district control runs to 0.2 s with burning and cooling disabled.
Volume-weighted CUDA mass drifts by -4.15e-8 and gas energy by -1.02e-8 relative to the initial
state; matched Metal has comparable rounding drift. All complete fields pass the comparison gate.

This establishes the tested uniform and static-terrain paths, not agreement for every geometry, resolution or
long-duration run, and not agreement with physical measurements. Existing model errors and grid
resolution errors remain. Large training batches should first check representative cases against
Metal, particularly near reflections and damage thresholds. No training-model accuracy claim is
inferred from this backend comparison.

Tests and reproduction tools are in [Scripts/cuda](../Scripts/cuda/README.md).

## Full training-plan pilots: acceptance stop, 21 October 2026

The resumable `Scripts/cuda/field-runs.py` prepares the existing 200-case plan on the Mac and
integrates it on the PC, retrieving training arrays while retaining raw fields remotely. Each
case must pass the existing exact feature/mask and per-value target gate before entering the
new dataset. Compressed transfers avoid sending repeated still-air values uncompressed.

The [training-pilot record](../Benchmarks/CUDAAcceptance/2026-10-21-training-pilots.json) records:

- Flat `made-perimeter-s1-1`: 15.5M cells, 2,645 steps; 61.7 s CUDA and 97.7 s end to end.
  All three channels pass. First-phase impulse relative L2 is 5.32e-7.
- Sloped `made-perimeter-s3-1`: 13.1M cells, 2,708 steps; 50.1 s CUDA and 87.9 s end to end.
  Features and masks agree exactly; peak and total impulse pass. First-phase impulse has two
  values outside tolerance: Metal/CUDA 426.405/417.138 Pa s and 225.719/186.434 Pa s
  (2.17% and 17.4% discrepancies), despite overall relative L2 of 5.36e-5.
- Beirut `beirut-p0-1`: 21.0M cells, 2,477 steps; 86.8 s CUDA and 150.4 s end to end.
  Features and masks agree exactly and total impulse passes; three peak values and three
  first-phase values exceed the per-value gate. First-phase relative L2 is 4.73e-5.

A fresh production Metal run of the slope reproduces the older training reference exactly in
all three target channels. The cause of the CUDA discrepancy remains unresolved; a discontinuous
first-phase stopping decision is a hypothesis, not an established diagnosis. The earlier smaller
terrain acceptance cases do not cover this failure. The failing case is excluded, the full CUDA
dataset and its training have not started, and no tolerance or model default was changed.

Separately, the overnight **Metal** first-phase dataset and both PC training rounds already
completed; see [learned models](learned-models.md). This stop concerns CUDA generation.

## Measuring worker costs and optional compilation cache

`result.json` and the dataset's CUDA provenance now include host-wall `timings`: imports and
input validation, NVRTC compilation (including capability query), device setup/upload and initial
kernels, solver, and final validation/array output. `wallSeconds` keeps its existing solver-only
meaning. `workerSecondsBeforeManifests` excludes manifest writes and module unload; SSH deployment
and retrieval are outside the worker. Timing fields do not alter numerical configuration.

The local `deployment.json` now complements worker timings with generation/validation,
remote-directory setup, worker and compressed-input upload, remote process lifetime,
retrieval, and returned-provenance validation. `totalSecondsBeforeReceipt` covers the whole
`deploy` call through validation/byte counting; `otherLocalSeconds` accounts for staging and
other local overhead outside named phases. Input/returned byte counts are uncompressed file
sizes, not wire traffic. The remote process phase includes cold SSH/Python startup and teardown;
worker timings describe work within it and must not be added again. The two hosts use
independent clocks; do not derive startup overhead by subtracting worker seconds from the
local remote-process phase. Caller-side scene preparation, availability probes,
acceptance comparison and the final receipt write are outside the deployment total.

`profile-deployment.py HOST PLAN.json --out NEW-DIR --cache-dir NEW-REMOTE-PATH --context TEXT`
measures three alternating uncached/primed-cache pairs for each explicit plan entry. Entries
specify `name`, `input`, `reference` and `retrieval` (`all` or `dataset`). The first job primes a
new cache; priming is retained separately. Each run checks the existing Metal gate and compares
all remote numerical fields/timesteps bit for bit across repetitions and cache modes, even
when only dataset arrays return. It records before/after cooperative lock/load observations
and fails on a busy worker or numerical discrepancy. Partial reports remain failed/running,
never complete. The tool does not publish a training dataset or establish a Metal speedup.

`Scripts/cuda/remote.py --cache-dir bombcad-cuda/ptx-cache` opts into persistent PTX reuse on
the PC. The same option is available on `run.py`; `compile.py` uses `--cache-dir` too. Entries
are keyed by source SHA-256, target architecture, every compilation flag and hashes of installed
NVRTC and companion builtins binaries. Each entry checks its key and PTX checksum. Corrupt or
partial entries are cache misses and rebuilt with an atomic replacement; no pickled objects
are loaded. Preserve normal user ownership of the cache. A hit still pays compiler hashing
and driver module loading. Default deployments remain uncached.

Repeated correctness-gated fixture experiments are retained in
[Heterogeneous compute](heterogeneous-compute.md). They establish useful startup savings for
small jobs, not faster numerical sweeps or an end-to-end large-district speedup. The full-size
training acceptance failures above remain open regardless of caching.

The [complete deployment and current Metal experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-deployment-profile/summary.md)
now records three primary uncached/primed-cache pairs for 32³, 64³ and a flat district. Deployment
medians are 9.18/8.19 s, 15.98/13.83 s and 78.11/78.76 s respectively. All numerical files and
timesteps are bit-identical across cache modes/repetitions; all existing gates pass for these
selected cases. The district's current production Metal case takes 21.38 s median on the same
Mac observer clock; CUDA preparation adds another 2.49 s before deployment. Primed compilation
is cheaper, but no district deployment speedup is observed. Availability and complete cost,
not solver-only time, should drive dispatch. This does not resolve the terrain/Beirut gates.

An independent [clock-calibration issue emmettl/bombcad-work#64](https://github.com/emmettl/bombcad-work/issues/64)
records reproducible Mac/WSL interval disagreement and an apparent PC wall-clock step. Until
resolved, use a common observer for cross-host latency and keep worker-clock diagnostics
separate. No time or clocksource settings were changed in that experiment. The completed
per-step profiling acceptance audit is recorded below under emmettl/bombcad-work#60. A [bounded field replay queue](field-queue.md) now covers emmettl/bombcad-work#59
resumability and per-case admission; finer accounting and larger evaluation remain open.

### Raw elapsed-clock correction

The [paired Windows/WSL/Mac audit](../Benchmarks/HeterogeneousCompute/2026-10-21-clock-audit/summary.md)
isolates adjusted Linux monotonic running about 2.5% faster while raw and native Windows QPC
agree in the observed intervals. Read-only kernel discipline queries show enlarged/changing
ticks; merely seeing `tsc` is not evidence that the clocksource itself is broken. emmettl/bombcad-work#64 remains
open for discipline ownership and safe host normalization; no system settings were changed.

`run.py` and `profile-worker.py` now use Linux `CLOCK_MONOTONIC_RAW` for elapsed measurements
and record `timingClock`. Worker `clockAudit` retains raw and adjusted-monotonic intervals.
`wallSeconds` remains solver-only, with its clock identity explicit in result/dataset provenance;
legacy receipts retain their original adjusted-clock values. Do not retroactively apply a fixed
conversion or mistake the reporting correction for a solver speedup. Host stopping/deadline
behavior and GPU timesteps are unchanged. The profiling harness labels each solver result's
clock so old/new worker durations are not silently treated as identical measurement contracts.

Timing-only reruns of both cooling fixtures and the flat district preserve every numerical
output/timestep hash and pass existing Metal gates. The six-run fresh-process profiler control
also preserves all outputs. Deployment costs measured on the Mac observer remain independent
of the PC's adjusted-clock rate; the earlier case-latency decision therefore remains intact.

## Diagnosing first-phase acceptance: 21 October 2026

Read-only traces now identify the terrain pilot's two first-phase discrepancies as sensitivity
to a tiny pressure's sign at phase closure. The [retained histories and replay summary](../Benchmarks/CUDAAcceptance/2026-10-21-phase-traces/summary.json)
cover columns 134058 (x=426, y=261) and 250097 (x=241, y=488), in the 512 × 512 × 50
`made-perimeter-s3-1` job. CUDA took 2,708 steps; both matched Metal arithmetic variants took
2,708 too. Trace samples also include the initial state and no-op control samples.

| Column | CUDA first phase, Pa s | Safe/unfused Metal | Fast/fused standalone Metal | Production Metal |
|---|---|---|---|---|
| 134058 | 417.1382 | 426.4038 | 426.4051 | 426.4054 |
| 250097 | 186.4339 | 186.4344 | 225.7190 | 225.7193 |

At sample 1216 of column 134058, CUDA sees -0.0078125 Pa and closes the phase at 1.965568 s;
safe Metal sees +0.03125 Pa and stays open until 2.038151 s. At sample 1581 of column 250097,
CUDA and safe Metal see -0.046875 and -0.0234375 Pa and close near 2.584012 s. Fast/fused Metal
stays open until 2.702129 s. CUDA versus safe-Metal sampled pressures differ by at most 0.0625 Pa
over these two full histories. This bound describes only the sampled columns, not the whole grid.

The safe-Metal **whole first-phase target plane itself fails one production-reference point**;
fast/fused standalone Metal passes that plane's existing per-value gate (relative L2 7.68e-7).
Thus the observed issue is not unique to a CUDA translation: the phase label amplifies a
near-zero rounding decision into later positive impulse inclusion. This does not establish that
all discrepancies, particularly Beirut's peak failures, share that cause.

`diagnose-phase.py` replays the recorder in float32. CUDA's recorder values match at every
sample exactly; all three arithmetic paths' final impulses replay exactly. Fast Metal has small
intermediate sum differences (up to 1.53e-5) consistent with contraction. In an **offline sensitivity
experiment only**, replacing just the single CUDA closing pressure with zero recovers 426.4032
and 225.7174 Pa s. No solver, recorder, target, mask or tolerance was changed by that experiment.

Full CUDA terrain arrays and timestep histories are bit-identical with tracing enabled and
without it; smaller CUDA and Metal controls pass the same no-change check. Compressed complete
histories, source/worker hashes, transition windows and counterfactual summaries are retained.
These traced runs perturb execution timing and must not be used as performance benchmarks.

[emmettl/bombcad-work#62](https://github.com/emmettl/bombcad-work/issues/62) tracks a justified, versioned phase-label
robustness policy and its physical/product checks. emmettl/bombcad-work#47 remains gated; neither a new epsilon nor
exceptions to dataset comparison have been introduced. The Beirut follow-up below separates peak behavior from phase decisions; assess candidate
definitions on held-out histories before changing any label semantics or regenerating data.

### Reproducing a trace

`run.py` and `remote.py` accept `--trace-columns 134058,250097` (up to 64 distinct flattened
plan indices). The diagnostic kernel derives its pressure expression from the generated
production recorder and writes only a separate trace buffer. It records overpressure, peak,
all-positive impulse, first-phase impulse, phase peak, open state, dt and batch clock after each
recorder sample. Output includes `trace.npy`, `trace.json`, indices and diagnostic-source hash.
Ordinary runs do not compile or dispatch that kernel.

Use `remote.py --trace-columns ... --diagnostics-only` to retrieve just those histories and
provenance, keeping large raw fields on the PC. Dataset-only retrieval cannot be combined with
traces. The shared GPU lock still applies. Tracing is diagnostic, not an acceptance bypass.

For standalone matched Metal, generate its source, then append the read-only kernel:

```sh
python3 Scripts/cuda/generate.py --out solver.cu --metal-out reference.metal
python3 Scripts/cuda/trace_columns.py reference.metal --metal-out trace.metal
swiftc Scripts/cuda/metal-reference.swift -o metal-reference
# Run under the normal Mac gpu-slot reservation:
metal-reference JOB trace.metal NEW-OUT 134058,250097
```

The reference defaults to safe, unfused math. Set `BOMBCAD_REFERENCE_MATH=fast` for the separate
fast/fused diagnostic, or `unfused-fast` to isolate contraction from the math mode. These options
change only that standalone diagnostic; no production default is affected. `diagnose-phase.py
TRACE-DIR... --out NEW.json` reads CUDA NPY, Metal binary or the archived gzip traces and reports
transitions and float32 replay. The standalone runner remains a supported-subset reference,
not a complete substitute for production Metal.

### Beirut follow-up

[Six-column Beirut histories and full-plane comparisons](../Benchmarks/CUDAAcceptance/2026-10-21-beirut-traces/summary.json)
now cover all three peak and three first-phase failures. Both CUDA and fast/fused standalone
Metal took 2,477 steps. Tracing preserved every original CUDA array and timestep byte.

At columns 164452 and 200270, CUDA closes at -0.03125 and -0.015625 Pa, giving 1244.798 and
1024.856 Pa s. Fast standalone Metal stays open longer and gives 1345.859 and 1032.393 Pa s,
matching production's 1345.858 and 1032.393. Offline zeroing of those single CUDA samples gives
1345.850 and 1032.389 Pa s. This extends the demonstrated near-zero sensitivity to those points.

At column 255969, both standalone paths give about 684.06 Pa s, against production's 634.63.
A +0.03125 Pa CUDA sample at index 2022 occurs near that accumulated impulse; offline replacing
it with -0.0078125 Pa gives 634.6302. This supports the same sensitivity hypothesis, but the
production closure had not yet been captured at that stage; the direct production
follow-up below now confirms its timing. `diagnose-phase.py --replace COLUMN:SAMPLE:PA` makes this
counterfactual reproducible and explicitly labels it offline-only.

The peak discrepancy remains separate. CUDA's original three failures are around 5.8 kPa,
about 12–13 Pa low. Fast/fused standalone Metal gives still lower peaks there (5806.81,
5716.25 and 5806.08 Pa), and its whole peak plane has 112 values outside the existing gate,
maximum absolute difference 46.87 Pa. The first-phase plane has one failure, at column 255969.
Its very small aggregate peak L2 error does not override those individual failures; neither a
new math mode nor a global precision switch is a demonstrated acceptance fix.

The direct production follow-up below resolves the closure question and tests work selection;
execution-path arithmetic and emmettl/bombcad-work#62's label definitions remain under investigation. No broad CUDA batch has been enabled.

## Direct production observation and execution-path controls

The production solver now supports opt-in host observation of selected first-phase columns.
`scenebench field-export --first-phase --trace-columns i,j` accepts up to 64 distinct enabled
receiver columns and keeps normal logical batches, but
splits their existing command-buffer parts into single steps and reads the completed recorder
and accumulated-field buffers. It adds no shaders and does not recompute pressure. The exported
`production-trace.npy` and `production-trace.json` therefore use a **different format** from the
CUDA pressure traces: recorder peak, all-positive impulse, first-phase impulse, phase peak,
open flag, interpolated accumulated peak, interpolated accumulated impulse, and dt. Initial
samples are omitted; active steps and the fixed-point GPU clock identify every observation.

Ordinary observed production runs of both `made-perimeter-s3-1` and `beirut-p0-1` reproduce
**all inputs, masks and all three target arrays bit for bit** against the original datasets.
A smaller GPU regression also checks the full solver digest, recorder arrays, active steps and
clock with observation enabled. Observed runs perturb timing and are not speed benchmarks.
The synchronous `advance` path collects these samples; manually encoded asynchronous batches
do not promise per-step diagnostic collection.

The previously uncertain Beirut closure is now directly confirmed. Column 255969 closes in
production at active step 2022, t=3.656500318 s, freezing its first-phase impulse at
634.630554 Pa s. CUDA stays open near that time and reaches 684.057068 Pa s. The production
trace records the actual open flag, not a reconstructed pressure: its 1→0 transition establishes
that the recorder took its negative-pressure branch, but does not provide an exact pressure
value. Terrain production closes at steps 1259/1650 (2.038150849/2.702128566 s); the other two
Beirut phase columns close at steps 1071/1416 (1.907766015/2.538027098 s).

A further control separates work selection from the tiled versus full-grid execution paths:

| Beirut production variant | Peak values outside the original gate | Total impulse | First-phase impulse |
|---|---|---|---|
| Ordinary tiled, observed | 0 | 0 | 0 |
| Same tiled kernel, every tile active from the start | 0 | 0 | 0 |
| Full-grid production path, `skipStillAir=false` | 64 | 0 | 2 |

The all-tiles run is bit-identical to ordinary tiled production in **every exported array**.
Thus skipping dormant tiles does not explain these target differences for this case. The
full-grid production path differs by up to 33.45 Pa in peak and 49.43 Pa s in first phase;
CUDA compared to that different reference still fails 34 peak and one phase target. Switching
references is not an acceptance fix. The paired safe/unfused control below narrows these differences to arithmetic-mode-sensitive
execution paths; it does not identify one specific compiler transformation.

`--full-grid-diagnostic` selects the existing production full-grid path. The mutually exclusive
`--all-tiles-diagnostic` keeps the tiled path and marks all tiles active. Neither changes a
product default; they cannot be combined with CUDA job export. These options, selected-column samples, actual executable/source hashes,
array hashes and comparisons are retained in
[the production-trace archive](../Benchmarks/CUDAAcceptance/2026-10-21-production-traces/manifest.json).
`diagnose-production.py TRACE-DIR REFERENCE --out NEW.json` audits live exports; with archived
compressed traces, pass `--arrays EXPORTED-ARRAYS` to recompute the gates. It rejects arrays
whose hashes differ from the archive receipt. Trace artifacts alone are not presented as a
fresh array-comparison pass.

For initial-state controls, `field-export --first-phase --initial-state-diagnostic NEW-FOLDER
--cuda-source GENERATED.cu` copies the actual portable physical buffers before the ordinary
production solve. Existing CUDA export capability checks still apply. The new folder must be
outside `--out`, with neither folder containing the other, and cannot already exist. This option
cannot be combined with `--cuda-job`. Compare job metadata and buffer hashes to establish
physical initialization identity; work-selection buffers are deliberately omitted. The accompanying
`initial-diagnostic.json` records the path and requested arithmetic policies, not emitted machine
instructions. The snapshot contains no final targets and confers no dataset admission. Optional
copying contributes to the timing receipt's total but lies outside its component phase intervals.

No phase semantics, dataset mask or acceptance tolerance changed. The full CUDA training batch
remains gated. Direct production closure resolves the earlier hypothesis; peak-path attribution
and a justified versioned phase policy remain separate work.

### Safe/unfused production pair

With the existing compiler probes `BOMBCAD_KERNEL_MATH=safe` and
`BOMBCAD_KERNEL_CONTRACT=off`, production tiled and full-grid Beirut runs are **bit-identical
in every exported array**, including all three target channels. They each take 2,477 active
steps. Along with the all-tiles result, this identifies arithmetic-mode-sensitive execution-path
variation for this case rather than a dormant-tile work-selection error. Both math mode and
contraction were changed together: fusion alone versus other fast-math transformations has
not yet been isolated, nor has this result been generalized to every geometry or resolution.

This is not a new reference or an acceptance pass for CUDA. Each safe production variant
still fails seven peak and six phase targets against original default-math production
(maximum differences 16.44 Pa and 239.90 Pa s). CUDA versus the safe production reference
still fails 12 peak and five phase targets, with total impulse passing. Changing arithmetic
or choosing whichever reference is closer therefore does not resolve the current contract.
All comparisons and executable/source/environment receipts are in the production archive.

[emmettl/bombcad-work#63](https://github.com/emmettl/bombcad-work/issues/63) tracks peak-path arithmetic and a
justified portability contract. Next isolate contraction from other math-mode effects with
fixed fixtures, and assess localized errors and damage-threshold effects before deciding
whether to constrain arithmetic or revise a versioned contract. emmettl/bombcad-work#62 separately owns phase
label conditioning. No default, mask, label or tolerance changed in these controls.

## Explicit contraction-policy factorial

[The complete factorial and bridge records](../Benchmarks/CUDAAcceptance/2026-10-21-math-factorial/summary.json)
now separate requested math mode from contraction policy on Beirut. Each explicit fast/safe ×
contract-on/off setting was run through tiled and full-grid production. Every within-setting
pair is bit-identical in all exported arrays. Relative to the original default production gate:

| Requested math | Contraction policy | Peak failures | Total-impulse failures | Phase failures |
|---|---|---|---|---|
| fast | on | 170 | 0 | 7 |
| fast | off | 87 | 0 | 2 |
| safe | on | 44 | 0 | 2 |
| safe | off | 7 | 0 | 6 |

Bridge controls matter here. Explicit fast mode **without a contraction pragma** reproduces
both original tiled/full-grid arrays exactly, including their 64-peak/two-phase disagreement.
Leaving math mode unset but adding contract-off matches explicit fast/off exactly. Thus
constructing explicit fast options is not the explanation for path agreement in this case;
the explicit contraction policy is the distinguishing source-level intervention. Contract-on
still permits fusion, so disabling fusion is not necessary for the observed path agreement.
No particular emitted instruction or compiler transformation has been inspected or established.

No explicit-policy variant passes the original gate. These are diagnostic settings, not a new
reference or chosen product policy. The safe/off repeat also reproduces the previous safe/off
arrays exactly. emmettl/bombcad-work#63 still needs independent-case, resolution and damage-threshold evidence
before a justified numerical portability contract can be chosen.

`math-matrix.py` reproduces the experiment from prepared field-run inputs and a matching stable
three-channel reference. It uses gpu-slot, resets known compiler probes, hashes the executable,
runtime Metal resources and sources, and records variant receipts, whole-array gates and atomic
running/failed/complete status. Complete experiment status is separate from acceptance status.
The final runner also checks layout inputs and all observations before and after each variant;
its single-configuration smoke reproduced the original arrays bit for bit. Initial archived
runner snapshots predate that input-hash hardening; their after-run input hashes are labelled
as such. Cancellation/timeout terminates the owned process group. Invalid modes, duplicate
columns and a mismatched reference were rejected without creating outputs.

```sh
python3 Scripts/cuda/math-matrix.py --case beirut-p0-1 \
  --scenebench .build/release/scenebench --reference REFERENCE \
  --out NEW-MATRIX --columns 159267,159777,159779,164452,200270,255969
# Optional bridges, in another new output root:
# --modes default-off,fast-default
```

## Whole-field spread and phase-conditioning probes

[A bounded product-consequence study](../Benchmarks/CUDAAcceptance/2026-10-21-product-portability/summary.md)
passes the seven existing Beirut fields through the declared wall/roof judging model, with
peak-only, phase-only and combined substitutions and shared uncertainty draws. All 20
substitutions have identical assessed probabilities across six factor/scatter pairs on 1,081
reinforced-concrete buildings (1,071 roof proxies). Some nominal 3% pulse bins change; outcomes
do not. None of the currently rejected field receivers contributes to those 10,013 sampled
ground-floor strips, so this result cannot justify their admission or establish a physical error
bound. The study retains that coverage limitation, exact sampling controls and full outcomes.
Its real CLI control also fixes `field-walls` numeric CSV reading for CRLF as well as LF.

### Receiver-fixture sensitivity

The follow-up applies all eight rejected Beirut/terrain receiver peak/first-phase pairs, plus
the legal arithmetic variants and isolated CUDA substitutions, to four predeclared uniform-load
fixtures: RC wall/roof, masonry wall and glass pane. `blastmodel receiver-fixtures` runs both
raw-pair and existing 3% product triangles. Across three bin widths and both Mac/Linux CPUs,
the 1,920 assessments per host have no variant-induced damage-level changes. Continuous
responses do change: a masonry fixture still below the failed category shifts about 0.080°
(19.5%). A larger 4.025° shift occurs after both alternatives are already classified failed;
it is not a credible post-collapse deformation prediction. No categorical changes across these
bin widths establish convergence or an error bound.

These are hypothetical uniform component loads, not inferred building-area loads or the actual
pressure histories. Both host outputs agree within the existing sweep comparison's `1e-9`
numeric tolerance. No phase definition or admission rule changes. The
[full receiver-fixture evidence](../Benchmarks/CUDAAcceptance/2026-10-21-receiver-fixtures/summary.md)
retains the declarations, source pairs, response ranges, controls and limitations.

The CPU runner now transfers only into invocation-private verified staging. Its reusable
checkout updates under host ownership, and completion/retrieval receipts bind result bytes.
The [snapshot ownership evidence](../Benchmarks/HeterogeneousCompute/2026-10-21-sweep-snapshots/summary.md)
records the fix for emmettl/bombcad-work#68, including stale-child ownership, concurrent-controller
and recovery controls. Earlier ownership probes were advisory; the revised protocol supplies
the protection. All clients sharing the host must use it.

[Immutable source reuse](../Benchmarks/HeterogeneousCompute/2026-10-21-source-reuse/summary.md)
implements emmettl/bombcad-work#70. A private basis view includes only checksum/mode-identical
files from a verified completed stage. In the bounded PC control, a 247 MB source tree sent
only five file-data bytes after a byte/mode change, then zero for unchanged source; metadata
traffic and verification work remain. Old snapshots and the mutable build cache stay separate.
Normal run/test, cached success/failure recovery and 23 Mac/Linux protocol controls pass.
These are transfer/storage results, with no solver throughput or numerical admission claim.

### Independent geometry and grid controls

[Independent geometry/grid controls](../Benchmarks/CUDAAcceptance/2026-10-21-independent-portability/summary.md)
extend the arithmetic/path study to synthetic flat and terrain geometries, each at 4 m and 8 m
with fixed physical domains. All 16 explicit-policy tiled/full-grid pairs are bit-identical;
all default pairs differ. Initial physical buffers match across every policy/path, and the
initial-state observer leaves each default output bit-identical. Peak pressure and total impulse
pass every within-grid gate. Terrain at 4 m still has two CUDA first-phase failures against
default production, and one against each explicit policy; three other geometry/grid groups pass.
No arithmetic setting resolves that terrain case. These are within-grid sensitivity controls,
not convergence, physical validation or a revised reference/admission policy. Retained arrays,
localized failures and exact scripts support the remaining product/label work in
emmettl/bombcad-work#62 and emmettl/bombcad-work#63.

### Whole-field reference spread

[The full-field spread study](../Benchmarks/CUDAAcceptance/2026-10-21-reference-spread/study.json)
uses six distinct reference outcomes (default tiled/full plus four explicit policies), with
223,548 valid targets per channel. Their observed range exceeds the original per-value
tolerance at 228 peak and 11 phase points; total impulse has none. Maximum ranges are 45.06 Pa,
0.431 Pa s and 239.90 Pa s respectively. Many CUDA values sit outside the raw observed min/max;
none lies farther outside it than the original per-value tolerance in this one case.
This is descriptive context, **not an error bound, confidence interval, physical validation or
admission rule**. These variants are not independent observations. The original CUDA gate
remains failed. `reference-spread.py` reports that unchanged gate beside the spread and retains
all input hashes; it does not admit data or select a policy.

[The offline closing-threshold sweep](../Benchmarks/CUDAAcceptance/2026-10-21-phase-conditioning/summary.json)
uses the previously recorded pressure histories only. At 101,325 Pa, float32 ambient spacing is
0.0078125 Pa. A probe band of eight spacings (0.0625 Pa) reduces four large between-backend
impulse spreads from 9.27, 39.29, 101.06 and 7.54 Pa s to below 0.01 Pa s. Three smaller spreads
remain. That sweep lacked actual production pressure at the recorder-only fifth point, so
it could not reconstruct that point’s new label. The consumed-pressure controls below now
fill the observation gap without selecting a new phase policy. These columns were preselected because they
disagreed; this is not held-out/full-field validation, and ambient spacing is not a proven total
pressure-error bound.

An analytic counterexample prevents interpreting this as a ready fix. Two genuine positive
phases at 1 Pa peak, separated by a sustained -0.05 Pa interval, have first-positive impulse
0.016 Pa s. The 0.0625 Pa band merges the phases and gives 0.028 Pa s (+75%). Scaling the same
proportional history to 10/100 Pa avoids that merge. This is a mathematical control, not a CFD
or measured-data validation. `phase-conditioning.py` retains all candidate outcomes and those
controls; no threshold is selected. emmettl/bombcad-work#62 requires a justified definition and independent weak,
reflected/multiphase and resolution/product checks before any versioned target change.

## CUDA cooling work selection

The worker now uses a luminous-box work selector by default. It computes integer bounds from
`medium[:, 0] > 0`, the same opacity condition the radiation equations use. Outside this box
there is no radiative exchange; transparent prefixes carry zero incident radiation. The 13
directions, their order, medium, weights, equations, energy cap and cooling clock remain the
same. Empty evaluations skip ray/application kernels and still take the normal clock-reset
path. The medium pass and launch envelope remain full-grid; this is not sparse air solving.

[Retained paired measurements and integration receipts](../Benchmarks/HeterogeneousCompute/2026-10-21-cooling-box/summary.json)
cover the existing RTX 3080 Ti. Three alternating original/bounded pairs of the complete Beirut
job produce bit-identical saved state, species, peak, impulses, first-phase records, training
arrays and timestep histories. Their medians are:

| Work selection | Solver | Worker total |
|---|---|---|
| Original full-grid cooling | 88.90 s | 93.20 s |
| Bounded prototype | 65.90 s | 70.12 s |

These totals share one warm Python interpreter and include compilation, setup and output,
but exclude SSH deployment/retrieval and cold Python startup. They are paired worker
measurements, not a cross-backend speedup or a claim for every domain. Hardware/load snapshots
and every repetition are retained. The numerical gate is not changed by this timing result.

The integrated default and its full-grid fallback also pass three alternating pairs each on
a 128³ luminous fixture and a 64³ empty-medium control. CPU tensor tests cover empty medium,
radiance without opacity, single-cell non-cubic coordinates and disjoint hot cells. They pass
in the existing PC PyTorch environment; a Mac Python without PyTorch skips those four tests
while still running the 20 CPU contract/deployment tests. Final integrated Beirut validation
compares all 12 saved numerical files bit for bit against the original full-grid worker.

That integrated run evaluates 620 cooling intervals/attempts, eight empty; its mean box has
108,796 cells, maximum 163,020, in a 20,971,520-cell domain. These are work statistics, not
physical energy accounting. The final worker report identifies `coolingWorkSelection` and
aggregated work counts; deployment provenance still pins the worker files.

`run.py --full-grid-cooling` or `remote.py --full-grid-cooling` selects the original path for
diagnosis. The CUDA worker's default work selection changed; app defaults, arithmetic, labels,
masks, accepted physics and tolerances did not. Original-reference acceptance failures remain
exactly the same, so no full training batch is enabled by this optimization. emmettl/bombcad-work#60 retains
further profiling; emmettl/bombcad-work#47/emmettl/bombcad-work#62/emmettl/bombcad-work#63 retain their separate numerical contract work.


## Resumable field dispatch

[The mixed Metal/CUDA queue](field-queue.md) runs explicit, bounded reference replays with
immutable inputs/code, per-case production Metal gates and content-addressed accepted objects.
It preserves gpu-slot and the training/CUDA lock; controller interruption does not relaunch live
case workers. A small real static-terrain CUDA case passes alongside uniform Metal cases in
the recovery experiment. This changes neither the larger terrain/Beirut failures nor bulk
dataset admission. The CLI's optional `--phase-timings` records local field initialization,
setup including compilation, solve and output without changing numerical arrays.


## Control-readback profiling

The [three-pair six-case control-readback experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-control-readback/summary.md)
removes only the device-wide wait immediately before the blocking CPU control copy. All saved
numerical fields and timestep histories match across 36 timed runs, including full flat,
static-terrain and Beirut cooling cases; the existing Metal admission failures remain unchanged.
Worker-process medians for flat and Beirut are 47.897/47.612 s and 68.639/68.312 s, respectively,
with mixed smaller-case results. The candidate is retained as a patch and is **not adopted**:
removing explicit waits alone does not establish a consistent complete worker-process benefit.
A separate perturbed API trace shows device-wide waits falling from 571 to 2, while blocking
copy/stream waits remain and waiting shifts into the copy API. Trace timings are not benchmark
predictions. Network deployment and queue overhead are outside these worker-process totals.

`profile-worker.py --baseline-cache-dir PATH --candidate-cache-dir PATH --fresh-process`
now supports symmetric cached-worker comparisons; omit the baseline option for the original
uncached-versus-cached experiment. The worker hashes its executed `__file__` under the logical
`run.py` provenance role, even when the variant is renamed. The profiler rejects a result whose
executed-worker hash differs from the selected file. This fixes aliased variants attesting an
unexecuted canonical sibling. The pinned host StepControl buffer experiment below retains
synchronization to separate allocation/staging from waits under emmettl/bombcad-work#60.


## Pinned host control-buffer experiment

The [emmettl/bombcad-work#65 pinned-buffer study](../Benchmarks/HeterogeneousCompute/2026-10-21-pinned-control/summary.md)
retains synchronization and reuses one pinned CPU tensor plus a ctypes view for StepControl.
All 36 candidate/baseline runs are numerically exact; 24 same-worker controls and two failure
controls per variant are separate. The API trace confirms reduced CPU allocation/pageable
staging, while transfer and wait counts remain unchanged. Full flat/Beirut worker-process
medians are 47.880/47.778 s and 68.590/68.603 s. Small apparent process gains overlap variation
in the same-worker control and are not consistently reflected in solve time. The candidate
is retained as a patch, with no production adoption. emmettl/bombcad-work#65 is complete as an experiment; emmettl/bombcad-work#60
retains broader control/launch work. Existing numerical admission and default worker behavior
remain unchanged.


## Steady-state CUDA graph dispatch

The [emmettl/bombcad-work#71 graph study](../Benchmarks/HeterogeneousCompute/2026-10-21-step-graphs/summary.md)
captures prepare, sweeps and optional terrain redistribution after the startup CFL ramp.
Per-step host control, dynamic cooling and prepare-uniform allocation remain. All 72 timed
runs retain exact files/dt across graph/baseline and same-worker controls; separate graph-path
fatal/step-limit and one-/two-axis controls pass. The perturbed trace reduces direct
`cuLaunchKernel` calls from 2,847 to 583, plus 569 graph launches, but complete worker cost
does not establish a consistent benefit. Flat/Beirut medians are 47.826/47.631 s and
68.805/68.648 s; graph wins only one of three pairs per full case and same-worker labels also
vary. Cooling32 worsens in median. The production worker is unchanged; this bounded candidate
is retained without adoption. emmettl/bombcad-work#60 stays open; the completed
emmettl/bombcad-work#72 block-size matrix below retains the same numerical and total-cost requirements.


## CUDA launch block-size controls

The [emmettl/bombcad-work#72 launch-size study](../Benchmarks/HeterogeneousCompute/2026-10-21-launch-blocks/summary.md)
compares 64/128/256 threads with only the launch ceiling/divisor/block changed. Both precise
PTX variants are primed before timing; all ten entries' loaded-kernel limits permit the sizes.
All 108 timed runs retain exact files/dt; actual-driver geometry, 31³/31×31×1/31×1×1 tail grids, axis/startup
and six expected failure refusals are checked separately. Independent audit verifies 1,134
numerical-file instances / 26.61 GB, source/input/provenance and terminal process groups.

Retain 128 threads. The 64-thread results are mixed against same-worker controls, while
256 threads raises full flat/Beirut worker medians from 48.285 to 54.018 s and 68.622 to
70.077 s in its own matched batches. These observations do not establish a universal optimal
size or attribute a mechanism to the recorded register counts. No default or numerical gate
changes. The separate [prepare-reuse experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-prepare-uploads/summary.md)
completes emmettl/bombcad-work#75 without adoption: 264 timed runs preserve exact outputs/dt;
14 successful device/lifetime diagnostics and four failure refusals pass. Cooling64 improves
4.11% in the 12-pair confirmation, while smaller gains and mixed initial/full results do not
establish a general complete-worker benefit. The correctness-validated candidate is retained;
production prepare allocation remains unchanged.


## Clock-adjustment actor identified

The [bounded clock-caller trace](../Benchmarks/HeterogeneousCompute/2026-10-21-clock-actor/summary.md)
identifies chronyd making 22 accepted ADJ_TICK/frequency updates (ticks 10,044–10,048 µs),
while Ubuntu systemd-timesyncd also updates the same kernel timekeeper. Version-matched WSL
3.0.3 init source launches a VM-level PHC-based chronyd agent; system-distribution tracking
reports PHC0 and about 4,576 ppm correction. Ubuntu service inventory alone misses that actor.
All tracing state is removed and verified; no clock/service settings changed. This identifies
the setter and duplicate controllers, not a proven feedback mechanism or completed fix. emmettl/bombcad-work#64
retains quiescent single-owner normalization and paired/longer validation. Raw elapsed reporting
and existing numerical gates remain unchanged.


## Fresh-process observer precision

The [emmettl/bombcad-work#66 observer correction](../Benchmarks/HeterogeneousCompute/2026-10-21-observer-precision/summary.md)
now drains stdout/EOF readiness while retaining the deadline and owned-child cleanup. A bounded
CPU control reduces median final-child-timestamp to parent-return interval from 8.260 to
1.914 ms; that interval includes child teardown and is not pure wait latency. Eighteen real
same-source GPU runs retain every numerical hash and provenance contract. The fresh path also
now passes each worker's selected cache argument, fixing the distinct/baseline-only routing bug;
earlier symmetric-cache studies used equal paths and remain valid. Reports record observer
scope and profiler source hash. Historical values are retained, not rescaled. This is a
measurement correction, not a CUDA speedup or numerical-admission change; emmettl/bombcad-work#65 remains unadopted.

The subsequent [controlled clock-ownership experiment](../Benchmarks/HeterogeneousCompute/2026-10-21-clock-normalization/summary.md)
reproduces improvement when Ubuntu's time client is paused and renewed instability
when restored, while WSL's PHC0 agent remains active. It therefore adds mechanism
evidence beyond the earlier setter trace. See the transaction receipts for the
longer single-owner validation and final service policy. emmettl/bombcad-work#64 stays open for reboot
and operational validation. Keep RAW elapsed measurements and all numerical gates.

Longer validation passed: maximum absolute MONOTONIC/RAW error was 19.3 ppm
for 5/15-second checks and 9.3 ppm for 60-second checks. Ubuntu-24.04
systemd-timesyncd is now inactive/masked, with WSL PHC0 retained as clock owner.
The rollback timer was removed and the shared reservation released.


## Worker profiling acceptance audit

The original emmettl/bombcad-work#60 profiling scope is complete. The
[deployment/current-Metal study](../Benchmarks/HeterogeneousCompute/2026-10-21-deployment-profile/summary.md)
and retained worker cold/warm-cache reports separate compilation, initialization, transfers,
launches, synchronization, solve and retrieval with complete job cost. They cover small,
flat/terrain/cooling and full Beirut cases across the programme. Cross-host comparisons use
a common observer; raw-clock correction and host clock-persistence work remain separate.

The individual reversible experiments retain their own three-or-more-pair comparisons,
identical-worker controls, exact numerical/provenance audits and separate tracing: control
readback (emmettl/bombcad-work#60), pinned staging (emmettl/bombcad-work#65), graph dispatch
(emmettl/bombcad-work#71), launch geometry (emmettl/bombcad-work#72) and prepare tensor reuse
(emmettl/bombcad-work#75). Each records its complete-cost decision, including no-adoption
outcomes; optional persistent PTX caching and corrected profiler/source attestation have
already landed. This fulfils profiling and bounded optimization acceptance, without claiming
that every possible GPU optimization has been exhausted or that CUDA beats production Metal.

No numerical gate is relaxed. emmettl/bombcad-work#47 / emmettl/bombcad-work#62 /
emmettl/bombcad-work#63 admission, emmettl/bombcad-work#59 distributed integration and
emmettl/bombcad-work#64 reboot/clock persistence remain separate deliverables.


## Charge-strength portability control

The [distinct full-flat admission stage](../Benchmarks/HeterogeneousCompute/2026-10-21-distinct-queue/summary.md)
adds a phase discrepancy beyond the original terrain/Beirut subset. On the same geometry,
512×512×59 grid, 236 m top and 4.51 s duration, the 100400 kg case rejects receiver 62902:
Metal/CUDA first-phase impulse 703.286865/705.982666 Pa s differs by 2.695801 Pa s,
exceeding the unchanged 1.456574 Pa s tolerance. Both backends take 2666 steps. The 200800/301200 kg
controls pass; every peak/total-impulse gate passes. Plain/snapshot exports are exact and
portable physical initial buffers agree for all three. This does not diagnose the new
receiver's mechanism or establish physical correctness of either label.

The [consumed-pressure controls](../Benchmarks/CUDAAcceptance/2026-10-21-production-pressure/summary.md)
complete emmettl/bombcad-work#79’s diagnostic prerequisite. Plain/recorder-only/pressure modes
preserve arrays, initial/final coarse state and histories, including archived terrain/Beirut
trace bytes. At flat receiver 62902, Metal consumes −0.0078125 Pa and closes at step 1558;
CUDA’s diagnostic pressure is +0.0078125 Pa and closes at 1584. An offline one-sample
replacement reduces the impulse discrepancy from 2.6958 to 0.00214 Pa s, without changing
flow or accepted results. This isolates closing-decision sensitivity, not an emitted
instruction or a justified replacement rule. emmettl/bombcad-work#62 remains open.


## Consumed-pressure diagnostics

`field-export --first-phase --trace-columns INDICES --trace-pressure` records the signed
pressure actually consumed by an instrumented sibling of `sampleFirstPhase`, with the
resulting recorder state. This differs from recomputing pressure later from the grid.
Ordinary exports retain their original shader source and allocate no pressure buffers.
The diagnostic compiles a sibling from the unchanged recorder body, adds stores for at most
64 selected receivers, and preserves normal logical batches. Indices in pressure mode are
flattened across the base plan and any `--levels` / `--roof` layers, in export order.

Pressure mode writes `pressure-trace.json` / `pressure-trace.npy` with format
`bombcad-production-pressure-trace-1`. Fields are consumed overpressure, peak, all-positive
impulse, first-phase impulse, phase peak, open, dt and batch time. Metadata includes the
seeded recorder values before initialization; the first sample is the actual zero-dt
initialization. Recorder-only `--trace-columns` retains its existing first-layer format.
`--trace-pressure-max-samples N` sets a 2–32768 budget, including initialization (default
32768). Exhausting it refuses export before writing a dataset; no truncated history is
marked complete.

`--diagnostic-state-hashes` separately records initial/final SHA-256 hashes of complete
coarse fluid/species, peak/impulse, mask and all first-phase buffers, plus times and step
count. It adds host readback only when explicitly requested and excludes refinement and
structural state. Use it on ordinary and observed controls alongside exact exported-array
and recorder-history comparisons. A pressure store may alter compiler arithmetic; a
complete trace alone does not establish parity with an uninstrumented run.

`python3 Scripts/cuda/diagnose-phase.py EXPORT --out NEW-SUMMARY.json` accepts the new pressure
format and refuses recorder-only traces as pressure. It normalizes JSON seeds to float32,
replays zero-dt initialization and every active state, and reports separate multiply/add and
native float32 fused accumulation independently. `exactAccumulationPolicies` identifies
models matching every recorded state for each column; use one compatible policy for the
whole trace. These are arithmetic compatibility checks, not emitted-instruction attestation.
The existing one-sample counterfactuals remain explicitly separate-accumulation sensitivity
probes. This diagnostic introduces no phase-rule, comparison or dataset-admission change.


The [four-case control matrix](../Benchmarks/CUDAAcceptance/2026-10-21-production-pressure/summary.md)
verifies exact state/array/history parity and a single compatible fused replay across each
default history; a small explicit contract-off pair verifies separate-operation replay.
All three full references and both archived recorder histories match exactly. Beirut receiver
255969 now has an instrumented consumed-pressure history under those parity controls, closing
at −0.078125 Pa. Source/trace receipts, refusal controls and the separate CUDA whole-file parity
check are retained. The actual half-mass CUDA case stays rejected; no new phase rule is adopted.

## Phase eligibility contract

The current streaming recorder approximates the offline façade definition; it does not
implement that definition for every possible history. The offline functions use half the
**final** history peak to qualify a phase, then integrate all positive pressure from the
start through that phase's first negative sample. The streaming recorder retains one phase
against the running peak. It can discard an intermediate phase that would qualify against
the final peak. With separated positive peaks 1, 1.6 and 3 Pa, negative gaps and 1 s samples,
the offline impulse is 2.6 Pa·s and the streaming impulse is 5.6 Pa·s. This semantic difference
persists in the analytical Float32 models and is separate from near-zero sign sensitivity.

The [2026-10-22 CPU audit](../Benchmarks/CUDAAcceptance/2026-10-22-phase-contract/summary.md)
checks eight fixed analytical controls and all 13 receipted pyro2 gauge histories at
25/50/100 µs bins. Both algorithms receive identical signed bin means. All 39 corpus
comparisons agree on impulse and closing sample; 24 close within the window and 15 room-mean
comparisons remain open. Both actual Swift offline functions pass the analytical controls
and all 39 derived inputs. The strong spherical free-field and room-volume-mean data do not
validate weak loads or local 3-D reflections. emmettl/bombcad-work#62 remains open for a
justified target definition and independent weak/reflected/multiphase/resolution validation.
No recorder behavior, default, tolerance, mask or training admission changes here.
