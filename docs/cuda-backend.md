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
