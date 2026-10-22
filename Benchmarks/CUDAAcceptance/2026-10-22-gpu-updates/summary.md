# Observing production GPU sweep updates — 2026-10-22

Tracking: emmettl/bombcad-work#80, supporting emmettl/bombcad-work#62.

## Result

All 108 declared numerical exports complete. Every one of the 36 pressure-plus-update
cases preserves plain/pressure-only state, recorder, step/time and initial-state observables
exactly, including the preceding fine-control baselines. Both pressure traces in each case
are byte-identical. The captured pre/post cell bits are continuous across all active steps
and agree with the final selected host-read states. Full/tiled increment statistics agree.

Each whole update trace has one compatible Float32 arithmetic model: fused for default
builds and separate multiply/subtract for unfused builds. No per-sample policy switching or
numerical tolerance is used. This is arithmetic compatibility, not emitted-instruction
attestation. The stores capture actual helper variables, not a recomputed flux pass.

At the 1 Pa/nx2048/CFL0.225 default central cell, 7,728 of 7,898 nonzero modeled density
increments and 6,977 of 7,968 nonzero modeled energy increments leave the corresponding
stored value unchanged. Their absolute modeled-increment magnitude fractions are about
91.20% density and 65.28% energy. All 3,203 nonzero modeled x-momentum increments move the
stored momentum. These are selected-cell/time diagnostics, not a global dissipation budget.
They directly corroborate a representational update limit in the actual 1-D GPU core,
while the independent mixed-precision model remains the storage/evaluation counterfactual.

No state representation, numerical default, phase rule or CUDA admission changes.

## Fixed controls and implementation

[The plan](plan.md) fixes two matrices (default/unfused), CFL0.225, A=1/10/100 Pa,
nx512/1024/2048, both full-grid/tiled paths and three modes: plain, pressure-only, and
pressure plus sweep updates. Two owned CLI process groups perform 108 numerical exports;
both groups and the controller are terminal and GPU slots released. This is not a quiet
performance study. The [post-run default-device query](device-post-run.json) reports Apple
M4 Max on macOS27.0.1; it is context, not continuous device observation.

The opt-in `configureSweepUpdateDiagnostics` supports only an unmasked 1-D bare ideal-gas
core: no species, gravity, cooling, mixing, cut/congested cells, refinement or structures.
It accepts 1–16 distinct cells and a 1–32768 active-sample budget. Restart disables it;
blocking advance collects every active step, and missing/overflowed histories are refused.
The acoustic CLI's `--trace-updates` explicitly adds the third observation mode. Its default
matrix and ordinary numerical modes retain their existing settings.

A separate observed library appends siblings of `sweepCell`, `sweep` and `sweepTiles` from
unchanged production source. The helper's original numerical statements remain intact;
stores follow its final `dst[index] = result`. Capture includes five old/new conserved
components, five low/high flux components, lambda, dt, axis and the active-step tag.
A single packed buffer at slot 30 contains the cell-to-slot map and output bits. No GPU
uniform/Cell struct changes are introduced. All [44 common ordinary Metal source/resource
pins](ordinary-source-audit.json) match the preceding matrix; no shader or CUDA source file
is edited. Ordinary runs compile their existing source and allocate no capture buffer.

Per-part clearing and execution tags distinguish a sleeping tiled opportunity from a real
zero-valued state. Unexecuted slots are explicitly false/zero; the audit carries the last
known state through them. Logical batches are preserved using the existing one-step
observation-part mechanism. Canonical `uint32-ieee754-binary32` value/initial/final bits
avoid JSON decimal or signed-zero reinterpretation. The initial/final human-readable values
are supplementary; `valueBits`, `initialStateBits` and `finalStateBits` are normative.

Three [GPU tests](tests.log) pass: full/tiled plain parity and actual pre/post host bit
identity, skipped sleeping cells, and invalid scope/index/budget/incomplete-history refusal.
The scientific matrix separately rechecks complete coarse state/recorder hashes, times,
all pressure-history bytes and preceding baseline fields for every case before classifying
it as an ordinary-run observation. Exact observables do not prove every unobserved
intermediate bit of an ordinary binary is identical.

## All central and wall energy/density counts

“Nonzero” means the separate Float32 product of captured lambda and captured high-minus-low
flux. “Unchanged” means old/new stored component bits agree. The actual captured variables
are the inputs and resulting state; a standalone product need not exist as an emitted GPU
instruction in a fused build. The whole-trace update models verify consistency separately.
Across the matrix there are 779,044 executed and 58,036 skipped selected-cell/step opportunities.
Counts include quiet/late flux noise, so frequency alone is not an accuracy measure. Full-grid
numbers are below; tiled nonzero/unchanged counts and absolute-magnitude sums are identical,
with skipped opportunities retained separately in [results.json](results.json).

| Math | A (Pa) | nx | Centre density unchanged/nonzero | Centre energy unchanged/nonzero | Wall energy unchanged/nonzero |
|---|---:|---:|---:|---:|---:|
| default | 1 | 512 | 1880/1994 | 1771/1994 | 665/1009 |
| default | 1 | 1024 | 3803/3985 | 3487/3985 | 1414/1993 |
| default | 1 | 2048 | 7728/7898 | 6977/7968 | 3167/3936 |
| default | 10 | 512 | 1813/1978 | 1641/1994 | 578/1016 |
| default | 10 | 1024 | 3688/3986 | 3428/3986 | 1273/2011 |
| default | 10 | 2048 | 7313/7909 | 6797/7968 | 2637/4001 |
| default | 100 | 512 | 1795/1988 | 1701/1996 | 557/1026 |
| default | 100 | 1024 | 3621/3965 | 3418/3989 | 1215/2020 |
| default | 100 | 2048 | 7255/7891 | 6817/7974 | 2464/4010 |
| unfused | 1 | 512 | 1864/1994 | 1664/1993 | 705/1007 |
| unfused | 1 | 1024 | 3797/3982 | 3473/3982 | 1439/1994 |
| unfused | 1 | 2048 | 7777/7949 | 7029/7953 | 3055/3968 |
| unfused | 10 | 512 | 1765/1937 | 1636/1979 | 613/1015 |
| unfused | 10 | 1024 | 3579/3890 | 3355/3900 | 1307/2011 |
| unfused | 10 | 2048 | 7318/7946 | 6628/7930 | 2577/4000 |
| unfused | 100 | 512 | 1773/1968 | 1649/1969 | 621/1025 |
| unfused | 100 | 1024 | 3640/3973 | 3343/3981 | 1261/2019 |
| unfused | 100 | 2048 | 7303/7967 | 6653/7947 | 2439/4009 |

The raw per-cell/component counts, absolute increment sums, arithmetic-model differences,
skipped opportunities and all gating outcomes are retained for every trace. Only five
predeclared cells are sampled; these statistics cannot be extrapolated to every cell in the
domain or treated as a causal budget for the measured first-impulse error.

## A recorded operation during the direct positive pulse

At default/1 Pa/nx2048/full, cell512, active step1904 (t=0.009822242396694492 s), old and new
energy are both **253314.546875 J/m³**. The captured-flux separate product is
**−0.007807129994 J/m³**, below half the local energy spacing (ULP 0.015625 J/m³,
half 0.0078125). The compatible fused update also rounds back to the old stored value.
The actual consumed post-step pressure at this receiver is 0.8125 Pa; the analytic direct
pulse is about 0.88575 Pa at that time.

[The example](example.json) is a post-hoc illustrative maximum unchanged energy increment
at the predeclared far receiver during the analytic direct-positive-phase window. It is not
a filter for aggregate statistics, a selected passing admission subset or a physical error
budget. [The all-window central-cell example](example-all-window.json) is retained too;
quiet-period increments can be noise. Source bits and the exact sample identify both records.

This establishes observed unchanged stored density/energy with nonzero modeled increments
under strict parity controls. It does not attribute the entire pressure/impulse error to one
component, prove an instruction sequence, validate a representation change or settle strong
blast near-zero target semantics. Component-wise and candidate-representation controls,
plus broader independent/product validation, remain in emmettl/bombcad-work#80 and
emmettl/bombcad-work#62. Production peak admission in emmettl/bombcad-work#63 and distributed
admission in emmettl/bombcad-work#59/emmettl/bombcad-work#47 are unchanged.

## Evidence and reproduction

- [Controller](run.py), [parity/arithmetic audit](audit.py), [audit log](audit.log), [controller log](controller.log).
- [All source/binary/input/outcome receipts](results.json), including every parity gate.
- [Archive manifest](archive.json): all 221 raw files / 528,785,708 bytes gzip archived and
  independently verified on StudioData (31,543,259 compressed bytes). All 113 non-trace
  metadata/log files are also published under `evidence/` (848,961 compressed bytes). All
  108 full pressure/update traces remain in the external archive. This split is by data size,
  not outcome; no numerical case is discarded or replaced.
- All 549 producing source/executable/resource files / 34,899,663 bytes were frozen before
  execution under the raw root's `sources/`, and rehashed by the audit.
- [Release build](release-build.log), [three GPU diagnostic tests](tests.log).

Raw root: `$BOMBCAD_DATA/experiments/2026-10-22-gpu-updates`. A fresh individual matrix:

```sh
~/.local/bin/gpu-slot --mem 2 .build/release/blastbench acoustic-phase --fine --trace-updates --rounding default --cfl 0.225 --out NEW-DIRECTORY
```

Use `unfused` for the other declared control. The controller requires a nonexistent fixed
scratch root, freezes inputs/source/runtime and retains partial output on failure. The CPU
audit requires NumPy, the raw outputs (or decompressed full external archive), frozen
producing files and the preceding fine-control receipts. All floating bit fields are read
as Float32, and an individual update trace uses one compatible arithmetic model throughout.
Never restart a command merely because an observation timed out.

No numerical algorithm, ordinary shader source, default, label, tolerance, mask, training index or host-service change. The host solver gains only opt-in diagnostic selection and collection.
The observer API is diagnostic and must be paired with numerical parity; trace completeness
alone is not evidence that an arbitrary observed run matches its ordinary counterpart.


## Integration verification

Format/lint and the [Mac strict build](strict-build.log) pass with no build warnings.
The [plain `make check-affected`](check-affected.log.gz) passes at core tier: 228 app and
348 core tests on the Mac, 253 BlastModel tests in 62 suites on bombcad-pc, plus the
reference/script/document checks. All 42 production digest variants across six sets
(plain, recommended, mapped, refined, refined twice and terrain) are bit-identical to
base `140e10661e6a6d6fa6822000cdb27f817c736a83`. The Linux build reports two existing
unused `createFile` result warnings in `USDSceneWriter.swift`; they are unrelated to
this diagnostic change. All verification jobs are terminal. Source/test/controller/plan
pins still match all 524 corresponding frozen producing inputs.
