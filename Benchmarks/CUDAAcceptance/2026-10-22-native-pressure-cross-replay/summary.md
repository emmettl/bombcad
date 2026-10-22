# Native pressure reader cross-replay — 22 October 2026

Tracking: emmettl/bombcad-work#84, bounded work under emmettl/bombcad-work#62;
related emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

**Swapping the native readers does not remove the Beirut early closure.**
Both readers reproduce their own captured pressures exactly. On the same frozen input bank,
they always agree on whether pressure is negative across all20982 selected-history comparisons.
The remaining difference follows the captured state histories in this experiment; the earlier
flow-update or timestep cause is unresolved.

## Own-input gates

The Metal reader reproduces all10488 pressure words; CUDA reproduces all10494.
This covers initialization and every selected sample: flat62902, slope134058/250097,
Beirut187747. Native phase replay also reproduces all104910 recorder words from real seeds
and the original backend accumulator policy, before interpreting a cross-reader phase.
Three independent ideal-gas cases (interpolation, kinetic subtraction, zero-weight side)
passed at initialization and an active step on both GPUs:12 exact pressure values.
Three host recorder controls passed too.

Metal uses the original complete producer compilation unit assembled from archived shader
resources and ContactSearch functions, through its original Swift pressure-capture transform.
The existing sampleFirstPhasePressure entry point is unchanged: nil compile options and empty
function constants. Source SHA256:
`20110cf2fc2a4331717e0c10216e91a81e8e8bbd58571569b83d062d5b0e24e2`.
CUDA uses the original cudaTraceColumns entry point and complete archived augmented source,
including the prior raw-input diagnostic append; source SHA256:
`9fb0da4bb7388b02c86150f0e7a9ee77541a5a7abac77fa44f995fac00bc0666`.
Original NVRTC flags are preserved (fmad=false, precise division/sqrt, ftz=false, original
cut-cell define). Own/cross CUDA PTX and selected runtime pins are identical.

The sparse harness retains original grid shape, receiver indices/descriptors, selected Cell
words and gas-read parameters; unrelated columns are disabled. Unused control/uniform fields
are zero. Own-input word gates validate this replay context on these histories; they are not a
general instruction-level or whole-solver equivalence claim. Metal observes actual consumed
pressure; CUDA remains its original read-only recomputation diagnostic.

## Beirut reader/input matrix

At CUDA sample827, time1.5420506962259823s, its frozen Cells give the same negative pressure
through either reader. Nearest Metal sample827 is1.5420496433080189s, earlier by
1.05291796348439 microseconds. Reader comparisons within each row use identical Cell words;
the two input rows are nearby states, not simultaneous states.

| Input bank | Metal reader (Pa) | CUDA reader (Pa) |
| --- | ---: | ---: |
| Metal | +0.03125 | +0.0390625 |
| CUDA | -0.0078125 | -0.0078125 |

Conditional recorder replay preserves the input bank's original seed, dt history, initialization
and accumulator policy (Metal fused, CUDA separate). It changes only the pressure reader.

| Input bank | Reader | First-phase impulse (Pa s) | Closing sample |
| --- | --- | ---: | ---: |
| Metal | Metal | 1696.1177978515625 | 900 |
| Metal | CUDA | 1696.117919921875 | 900 |
| CUDA | Metal | 1514.28857421875 | 827 |
| CUDA | CUDA | 1514.2877197265625 | 827 |

Even the Metal reader on CUDA inputs has error181.8292236328125 against the original Metal
target and unchanged allowance3.4422355957031248: **FAIL**.
The native CUDA result remains unchanged and rejected. These are frozen-state reader swaps,
not rerun flow solutions, new native targets or dataset admission.

## All retained outcomes

The cross-readers change5225 of20982 pressure words (2566 on Metal inputs,2659 on CUDA inputs).
Every difference is numeric; there are no signed-zero-only changes.
The maximum absolute reader difference is0.03125 Pa. There are **zero negative-pressure
decision differences** across all selected histories. Three positive/zero decisions change,
shifting one slope onset by one sample and the other backend's corresponding onset by two;
all closing samples remain unchanged.

Every selected flat/slope conditional point fits the original allowance; this is not a
whole-field conditional acceptance test. Every reader, point, transition and outcome remains
in [the full matrix](matrix-results.json). Metal input histories have2646/2712/2418 samples
(flat/slope/Beirut); CUDA has2648/2713/2420. Their physical time axes remain distinct. These are trace samples, not active-step counts:
both original backends take2645/2711/2417 active steps. CUDA retains2/1/2 additional
inactive zero-dt rows besides initialization; the Metal capture omits inactive rows.
All stored rows are retained in this study.

No PDE was advanced in this study. Native-reader controls, own-input and cross-input runs
used normal Mac GPU slots and the PC's existing shared lock. Two local preflight errors are
retained in [their receipt](preflight-failures.json): a sandbox-denied gate-receipt write,
then Metal launch refusal because that receipt was absent. Neither started a numerical
Metal cross replay. Host access corrected the receipt, and the first numerical cross launch
then completed. No numeric parity failure was discarded, helper substituted or tolerance relaxed.

The next bounded diagnostic is a controlled CUDA pilot driven by the captured Metal timestep
history, using the existing forced-step path and requiring realized dt words to match exactly.
This tests the clock-selection contribution before attributing the difference to a flow
operator. It needs its own controls and keeps default CUDA generation held.

Raw source, libraries, inputs, pressure vectors and every outcome:
`$BOMBCAD_DATA/experiments/2026-10-22-native-pressure-cross-replay`.
No tolerance, mask, phase, default, training-index or admission change.
Bulk stays held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.

## Publication checks and archives

Formatting/lint and the Mac strict build passed without warnings, as did the standalone
Swift harness compiled with warnings as errors. Plain `make check-affected` passed:
selected Mac suites and36 PC tests in4 suites. The Linux lane reported two unused-result
warnings in unchanged `Sources/BlastModel/USDSceneWriter.swift` (createFile at83/285);
those are not hidden by the Mac's warning-free strict-build result.

After the checks, native vectors, prepared/consumed/runtime pins and sample accounting were
independently verified, along with fresh remote own/cross output inventories, terminal
controller receipts and selected runtime binaries.
See [publication checks](publication-checks.json) and [independent verification](independent-verification.json).

All201 raw files (14,296,651 bytes) are preserved in
`$BOMBCAD_DATA/experiments/2026-10-22-native-pressure-cross-replay-archive/all-raw.tar.gz`
(3,080,771 bytes, SHA256
`ff1c6d88268e58fbf7e77ebb545f08203cd197b2ded3c60bcf96837603cf20db`).
The [public metadata archive](evidence/metadata.tar.gz) contains67 files
(224,397 bytes, SHA256
`59917059917bb04399f8f33dbe96b077864f4642d155766afc6e651e64f611f8`).
Every decompressed member and raw file was verified against the [complete manifest](archive.json).
