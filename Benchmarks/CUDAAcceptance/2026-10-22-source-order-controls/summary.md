# Written-order model check — 22 October 2026

Tracking: emmettl/bombcad-work#82, parent emmettl/bombcad-work#80.

The tested written-order rearrangements leave the existing CPU-model fluxes
unchanged for this corpus. All 432 Float32 flux arrays are bit-identical to the
earlier separate-Float32 model; all 432 Float64 arrays are bit-identical to the
earlier stored-source Float64 model. This is direct array comparison, including
UInt64 words for the Double model, after verifying both sets of archived hashes.
It is stronger evidence than the initially observed equal aggregate counts.
The result covers these saved stencils, not arbitrary states or every model
intermediate. See [model-equivalence.json](model-equivalence.json).

Both models remain incompatible with the captured GPU fluxes: neither has a
single whole-trace compatible case out of 432, including Float64 outputs rounded
to Float32 for that comparison. The written Float32 model differs in 20,908,970
captured flux words:

| Component | Different Float32 words |
|---|---:|
| Density flux | 5,948,836 |
| Momentum flux | 951,526 |
| Energy flux | 14,008,608 |

All word differences are also numerical differences, rather than signed-zero
changes. The maximum absolute momentum-flux difference is 0.0078125 Pa. This
quantifies model compatibility; it does not establish physical dissipation or
explain the evolved peak error. Each opposite-face difference is a conditional
local comparison. The earlier component interpretation limits remain in force.

All five frozen mathematical controls pass: analytic uniform flux/zero update,
wall mass/energy conservation to roundoff, reflection symmetry, independent
Double agreement on smooth/discontinuous inputs, and scope/reflection refusals.
The scientific driver verified archived inputs, required the predecessor
gates to pass, and revalidated every canonical source case. All 432 rows are audited, covering 8,227,928 executed and 814,552 skipped
sample opportunities, with no reconstruction fallbacks. Both models preserve
byte parity on commonly executed observations across all 216 full/tiled pairs.
Skipped opportunities have no invented GPU operation. Full/tiled observations
are correlated; overlapping fixed-factor strata must not be added.

The new model follows the shader's written primitive kinetic-energy, reconstructed
energy and Roe-speed expression trees, and mirrors primitive velocity after the
physical-cell conversion. Separate CPU operations do not attest contraction,
vector-dot lowering, reciprocal/sqrt accuracy or GPU instructions. No model or
policy was selected per scalar. The earlier independent model remains unchanged.
The driver and mathematical controls were frozen before scoring. The direct
array comparison and summarizer are separately versioned postprocessing; their
plans, sources and all outcomes are retained.

Keep these models as explicitly conditional numerical counterfactuals. Reject
using them as instruction-exact GPU surrogates or as a basis for component-level
peak-cause attribution. The tested written-order changes alone do not resolve
the mismatch. Further attribution needs independently validated evidence of the
operator actually executed; no precision intervention follows from this study.
emmettl/bombcad-work#82 remains open for the peak mechanism.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-source-order-controls`.
[summary.json](summary.json) retains every outcome and fixed-factor stratum;
[run.json](run.json) records frozen/consumed pins and all common-execution pairs.
The [archive receipt](archive.json) covers every new raw file and the inherited
source/runtime dependencies. All derived arrays remain in the external archive
by kind, regardless of outcome. No GPU or independent PDE/oracle rerun, timing
claim, production solver change, label rule, mask, tolerance, default, training-index,
service or CUDA admission change. Corrected Beirut admission remains separately
gated by emmettl/bombcad-work#62.

Required format/lint, warning-free strict build and plain `make check-affected`
pass, including selected Mac suites and 62 PC tests in 11 suites. Post-check
verification covers all 452 own raw files, both archives, every consumed prior
input and all selected runtime/helper/source pins. See
[publication-checks.json](publication-checks.json). The full archive is
349,934,615 bytes; public metadata is 20 files / 231,420 bytes.
