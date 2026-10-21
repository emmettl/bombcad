# Independent geometry and grid-spacing controls

Numerical sensitivity study for emmettl/bombcad-work#63 and emmettl/bombcad-work#62.
This is not a performance measurement or dataset admission decision.

## Results

All four groups completed: 48 Mac exports/preparations and four CUDA deployments.
Each default observed export is bit-identical to its unobserved control. All ten production
variants per group have identical portable physical initialization, including geometry and
recorder buffers. The archive audit separately checks standard CUDA preparation identity.

| Geometry / spacing | Valid targets per channel | Largest Metal failure counts across variants (peak / total / first phase) | CUDA vs default (peak / total / first phase) |
|---|---:|---|---|
| Flat / 4 m | 158,013 | 0 / 0 / 0 | 0 / 0 / 0 |
| Flat / 8 m | 38,488 | 0 / 0 / 0 | 0 / 0 / 0 |
| Terrain / 4 m | 153,610 | 0 / 0 / 1 | 0 / 0 / 2 |
| Terrain / 8 m | 36,993 | 0 / 0 / 0 | 0 / 0 / 0 |

All 16 explicit-policy tiled/full-grid pairs are bit-identical in every numerical array.
Each default tiled/full-grid pair differs; only terrain at 4 m exceeds tolerance (one
first-phase target). Every explicit-policy terrain 4 m variant also fails one first-phase
target against default production. CUDA still fails one phase target against every explicit
policy there, versus two against default. Maximum CUDA/default phase difference is 39.2853 Pa s.
Changing the reference arithmetic therefore does not resolve terrain admission.

The explicit-contraction path agreement previously observed in Beirut extends to these two
geometries and spacings. It is not proof of universal agreement or of particular emitted
instructions. Peak pressure and total impulse pass every within-grid comparison here, while
terrain phase labels remain sensitive. The absence of failures at 8 m is not convergence:
receiver centres, masks and discretized geometry differ. Product damage consequences and
independent weak/reflected/multiphase-load validation remain outstanding; the existing Beirut
peak failures are not resolved by these additional cases.

`audit.json` retains the failing receiver indices, reference/candidate values and tolerances.
`study.json` retains every comparison, source/input hash and deployment receipt. Completion of
this experiment does not change the rejected terrain case or enable broader CUDA generation.

## Design

Two additional synthetic geometries, flat `made-perimeter-s1-1` and terrain
`made-perimeter-s3-1`, each use 4 m and 8 m cells over the same 2048 × 2048 m footprint.
The physical top is fixed at 240 m for flat and 200 m for terrain. Flat's top deliberately
differs from its historical 236 m reference so both spacings represent the same top;
the new default exports are diagnostic controls, not replacements for admitted references.
Charge, location, ground, layout and duration come from each original case's metadata.

Each geometry/grid has an unobserved default tiled reference, ten observed production
exports (default plus explicit fast/safe × contraction on/off, each tiled/full-grid),
and a standard CUDA preparation and deployment through the shared PC lock. Every observed
production export snapshots its actual portable physical buffers before stepping.
The default observed export must reproduce the unobserved arrays bit for bit.
Initial state metadata and buffer hashes, including the separately prepared CUDA input,
are audited independently of final target comparisons. All four CUDA preparations match
their default physical initial state. Work-selection buffers are omitted.

The unchanged per-value gate is `0.05 + 0.002 * abs(reference)` for each of peak pressure,
total positive impulse and first-phase impulse. Shapes, inputs and masks must agree before
comparing targets. Comparisons are within one geometry/grid only: different grid spacings
have different receiver centres and masks, so this is not a pointwise convergence study.
Requested arithmetic policies do not establish which machine instructions were emitted.

## Provenance and reproduction

The exact controller is `study.py`; it records executable, source, runtime resource and input
hashes and checks them after each command. The producing binary includes the opt-in
`FieldExport.swift` initial-state diagnostic on top of the recorded base revision, so it is
not represented as a clean base-revision executable. The run uses ordinary gpu-slot sharing
and the existing PC lock; no quiet-host performance claim is made.

`smoke.py` and its receipts retain a real CLI transparency check, tiled/full physical-buffer
identity check and seven invalid-argument rejection controls. `package.py` recomputes gates,
validates initial jobs and verifies the retained archive file by file. Only identical immutable
binary payloads are deduplicated as tar hard links; state JSON and receipts remain independent.

No arithmetic default, mask, phase definition or admission tolerance changes in this work.
Product damage consequences and a justified versioned portability/label contract remain
separate requirements before broader CUDA generation (emmettl/bombcad-work#47).

The 4 m terrain default arrays reproduce the historical admitted-reference arrays bit for
bit. Its CUDA failures are the previously diagnosed columns 134058 (426.4054 vs 417.1382 Pa s)
and 250097 (225.7193 vs 186.4339 Pa s), not unexplained new failure locations. All nine
non-default terrain 4 m Metal variants fail at column 250097. The snapshot control therefore
adds an initialization and execution-path check around the existing diagnosis.

The compressed archive is 47,156,634 bytes; all 881 file instances were hash-verified,
including 581 identical immutable payloads represented as tar hard links.

Validation: `make check-affected` passed (strict build without warnings, lint, script/document
checks, 71 CUDA/queue tests with four local Torch skips, 18 selected Mac tests and 54 PC tests).
The experiment and archive audit completed before validation builds/tests began.

Integration: rebased onto concurrent `8701c269` wall/roof judging work and repeated
`make check-affected` successfully; `check-integrated.log` retains the combined-tree check.
The numerical experiment still uses its recorded base revision and binary, not this later tree.
