# Corrected Beirut first-phase decision — 22 October 2026

Tracking: emmettl/bombcad-work#62; related emmettl/bombcad-work#63 and
emmettl/bombcad-work#80. Bulk CUDA generation remains gated.

The corrected mapped-start reference still exposes a near-zero closing decision
at receiver 187747 (row366/column355). Metal first-phase impulse is
1696.1177978515625 Pa s; CUDA is 1514.2877197265625. Error 181.830078125 exceeds
the unchanged allowance 3.4422355957031248. This is the same rejected value in the
[fixed-reference pilots](../2026-10-22-fixed-terrain-reference/summary.md).

| Observation | Metal | CUDA |
|---|---:|---:|
| Trace samples | 2418 | 2420 |
| Physical start time (s) | 0.025454009796289062 | 0.025454009796289062 |
| First opening time (s) | 1.2255867266367204 | 1.2255876711720193 |
| Closing time (s) | 1.6764549618392266 | 1.5420506962259823 |
| Pressure at its closing sample (Pa) | −59.75 | −0.0078125 |
| Exact recorder replay policy | fused | separate |

At the nearest Metal sample to CUDA's closure (1.5420496433080189 s), consumed
pressure is +0.03125 Pa and the phase remains open. The time displacement is
1.052918 microseconds; these are nearby physical-time samples, not identical
states. Metal then remains open through the remaining positive tail. At Metal's
later closure, the nearest CUDA sample is 1.086911 microseconds away and has
pressure −59.7421875 Pa, but its recorder has already closed. Each backend uses
its own time axis; the different total step counts are retained.

The frozen auditor's offline zero-at-own-closure replay changes only CUDA's
sample 827 pressure from −0.0078125 to 0 Pa. It then closes at sample 900, producing
1696.1112060546875 Pa s, only 0.006591796875 from Metal. All actual outputs remain
unchanged and rejected. This bounds a closing-decision sensitivity; it does not
prove which primitive, flux or instruction caused the pressure difference, or
validate a zero-pressure replacement as a physical phase rule. All closure
sensitivities, including Metal's non-improving zero-at-closure replay, are
retained in [analysis-results.json](analysis-results.json).

Observer controls passed before interpretation. Both Metal plain and
consumed-pressure runs match every corrected-baseline dataset array byte, and
paired initial/final coarse state hashes match: fluid, optional species,
accumulated peak/impulse, masks and first-phase buffers. This hash scope excludes
refinement and structural state. The existing CUDA trace preserves all 9 original
remote numeric outputs, including dt, with trace.npy the only added numeric
file. Metal records consumed pressure; CUDA pressure is recomputed by its
read-only diagnostic kernel. Exact full-recorder replay supports its use for
this decision analysis, without turning it into direct instruction attestation.

All 3 numerical commands completed once under shared GPU locks. The frozen
executable and physical inputs from Metal main c78451c0 (containing aff21dff)
were reused, with consumed-file hashes checked before/after. No numerical retry.
The first offline report failed before writing results because the wrapper
omitted the frozen auditor's sibling import path. Its original source and
failure description are retained; the repaired CPU-only report succeeded.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-corrected-beirut-trace`.
The [archive receipt](archive.json) inventories every own raw file and the
separately retained immutable runtime/input dependencies and remote full outputs.
No quiet performance claim. No phase rule, label, tolerance, mask, default,
training-index, service or admission change.

The concrete next step for emmettl/bombcad-work#62 is an explicit, validated
first-phase definition that remains meaningful at these near-zero pressures.
This corrected-reference result supports continuing that work; the terrain-start
fix alone did not remove it. Any candidate must retain the existing per-value
gate and include both this Beirut case and the earlier flat closing-sensitivity
case, with independent physical/weak-wave validation under
emmettl/bombcad-work#80. No production rule is adopted by this diagnostic.

Required format/lint, warning-free strict build and plain `make check-affected`
pass, including selected Mac suites and 62 PC tests in 11 suites. All 32 raw
files, both archives, consumed inputs and helper snapshots still match after
checks. [publication-checks.json](publication-checks.json) records this artifact
stage; it does not claim an unrelated ordinary-solver digest rerun.
