# Wider pressure evaluation does not fix Beirut's closure — 22 October 2026

Tracking: emmettl/bombcad-work#62; related emmettl/bombcad-work#80.

At corrected Beirut receiver 187747, the captured CUDA state still gives a
negative pressure under both fixed Double thermally perfect evaluations:

| Evaluation at native closing sample 827, 1.5420506962259823s | Overpressure (Pa) |
|---|---:|
| Native CUDA diagnostic | −0.0078125 |
| Source expression in Double | −0.0018087679636664689 |
| Independent monotone energy-relation root in Double | −0.0018090502708218992 |

The two declared interpolation policies give the same results for these selected
column descriptors. Both temperature evaluators and both weight policies produce
conditional first-phase impulse 1514.297607421875 Pa s, still 181.8201904296875
from Metal's 1696.1177978515625, against unchanged allowance 3.4422355957031248.
All four retain the early closure. This rejects these wider-pressure-only
counterfactuals as a fix for the remaining point. It does not identify a
particular flow-state difference, observe Metal's input state, or prove a
continuum pressure sign.

The earlier [single-sample zero substitution](../2026-10-22-corrected-beirut-trace/summary.md)
demonstrated closing sensitivity. These wider evaluations do not supply that
zero replacement. They use the same rounded CUDA cells, promoted Float32 source
parameters and existing phase rules, with no feedback into the flow solution.
The independent root solves that parameterized energy relation; it is not an
independent physical field solution or native-instruction emulation.

All four counterfactuals give the same final Float32 recorder impulse at the
three selected control points:

| Corrected case / column | Metal (Pa s) | Native CUDA (Pa s) | Conditional wider-pressure recorder (Pa s) |
|---|---:|---:|---:|
| Flat /62902 | 1107.3367919921875 | 1107.3350830078125 | 1107.3505859375 |
| Slope /134058 | 439.7640075683594 | 439.7618103027344 | 439.774658203125 |
| Slope /250097 | 188.52630615234375 | 188.5260467529297 | 188.54249572753906 |

Those selected-point differences remain below their original allowances. This
is not a whole-field counterfactual admission test. All actual CUDA outputs
remain unchanged, including the rejected Beirut value 1514.2877197265625.

Initial sampling was retained. On Beirut's represented initial CUDA state, the
Double source formula gives +0.0067189466 Pa and opens the shadow recorder at
sample 0; native recording opens at sample 655. The independent root behaves
similarly. Widening the reader of an already rounded, natively initialized state
does not automatically preserve its ambient equilibrium. The actual initial
record/open buffers seed every replay, including sample 0; no early samples or
unfavorable outcomes were dropped.

Observation gates pass for all three declared diagnostic solves: all nine
original numeric outputs and timestep files are byte-identical to their accepted
fixed-input baselines; only the native trace and 16-word input trace are added.
Physical/diagnostic source and worker hashes match. Column words and native
weights are constant and verified. Both captured Cells match the corresponding
full state words at the initial and final endpoints. Every native recorder word
replays exactly from the actual input seed, and Beirut's eight-field trace is
byte-identical to the preceding accepted corrected-input trace. All three solves
ran once under the normal PC lock, with no numerical retry or lock bypass.

Four mathematical controls pass on both capture and scoring runtimes: thermally
perfect source temperature versus independent bisection over 1–60000 K, density/
velocity pressure consistency, ideal-gas analytic pressure and interpolation/
refusal behavior. Model constants are the frozen source's Float32 literals;
Double arithmetic is not claimed to emulate native compiler constant folding.
The model/control sources were frozen before capture; the gated all-outcome
analysis is separately versioned postprocessing. [analysis-results.json](analysis-results.json)
retains every model, column, closure and consumed-file pin.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-phase-pressure-inputs`.
[run.json](run.json) records all commands and remote paths; the
[archive receipt](archive.json) retains every own outcome. Complete full-grid
outputs stay at their recorded PC paths/hashes, and immutable baseline sources
and inputs stay in their preceding verified archive. No timing comparison,
production source/precision/default/phase/label/tolerance/mask/training-index/
service or admission change. Bulk CUDA generation stays gated. Further work on
emmettl/bombcad-work#62 needs the remaining cross-backend state/phase-definition
validation; this pressure-width-only result does not close the issue.

Required format/lint, warning-free strict build and plain `make check-affected`
pass, including selected Mac suites and 62 PC tests in 11 suites. All 49 own raw
files, both archives, consumed reference/input and selected runtime/source pins
still match. Every new remote numeric inventory was independently rehashed
after checks. See [publication-checks.json](publication-checks.json). Full archive:
578,569 bytes; public metadata: 40 files / 156,526 bytes.

## Corresponding Metal inputs

The [paired Metal/CUDA study](../2026-10-22-metal-pressure-inputs/summary.md) now captures
the corresponding Metal cells without altering producer compilation. All four wider evaluators
retain opposite pressure signs near CUDA's early closure and preserve the native backend
impulse gap181.830078125 Pa s. See that report for exact physical-time displacement and limits.
