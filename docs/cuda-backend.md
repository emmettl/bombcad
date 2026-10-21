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
absorption and energy cap. The first implementation traverses the full grid rather than Metal's
luminous bounding box. Transparent cells add no radiation, so this is extra work rather than a
change to the equations. Its performance needs measuring for large domains.

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

[#62](https://github.com/emmettl/bombcad-work/issues/62) tracks a justified, versioned phase-label
robustness policy and its physical/product checks. #47 remains gated; neither a new epsilon nor
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
execution-path arithmetic and #62's label definitions remain under investigation. No broad CUDA batch has been enabled.

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

[#63](https://github.com/emmettl/bombcad-work/issues/63) tracks peak-path arithmetic and a
justified portability contract. Next isolate contraction from other math-mode effects with
fixed fixtures, and assess localized errors and damage-threshold effects before deciding
whether to constrain arithmetic or revise a versioned contract. #62 separately owns phase
label conditioning. No default, mask, label or tolerance changed in these controls.
