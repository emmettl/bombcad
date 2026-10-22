# Reject the component-output replay — 22 October 2026

Tracking: emmettl/bombcad-work#82, parent emmettl/bombcad-work#80.

The 91-word component-output variant fails the strict flux-compatibility gate in
**all 432 cases**, under both declared arithmetic policies. Keep its payloads as
failed-observer evidence; reject their use for component or peak-cause attribution.
The [face-only replay](../2026-10-22-metal-stencil-replay/summary.md) remains
compatible with every captured flux word. Its immutable inputs and outputs were
reused read-only, with fresh output folders for this experiment.

| Policy | Cases | Byte-compatible cases | Different flux words | Numeric differences |
|---|---:|---:|---:|---:|
| Default | 216 | 0 | 502,710 | 456,014 |
| Unfused | 216 | 0 | 151,492 | 151,492 |

Of 82,279,280 compared flux words, 654,202 differ; 607,506 differ numerically.
The remaining 46,696 differences are signed zero in transverse components.
Every case also has numerical differences, so the rejection is not solely a
signed-zero issue. Across both policies, density/momentum-x/energy differences
number 318,262 / 98 / 289,146. The maximum normal momentum-flux error is
0.0078125 Pa. These are compatibility errors, not measurements of dissipation
or bounds on an evolved pressure peak. Every fixed-factor stratum is retained
in [summary.json](summary.json).

Six unchanged analytic controls pass, every 91-word payload is finite, and all
216 full/tiled pairs have identical complete payloads on commonly executed
observations. Those controls establish schema and reproducibility; they do not
replace agreement with captured native fluxes. No passing policy/scalar subset
is promoted, and no independent-model comparison of the rejected primitive,
slope or face values was performed.

The transformation appends an instrumented sibling to the frozen helper source.
It names the three limited-slope locals, stores five primitives, three limited
slopes (excluding uninitialized slope.g), six reconstructed faces and both face
fluxes. Stored locals are passed to the replay's reconstruction/Riemann calls.
The transformation changes the compilation context through both local naming
and additional stores; this experiment does not isolate one source change or
machine instruction as the cause of the mismatch. It observes a separate
recomputation, not production intermediates.

All 432 archived cases were retained, spanning 8,227,928 executed and 814,552
skipped selected-stencil opportunities. Both policies use nil Metal compile
options, the original contract-off prefix where declared and ideal-gas constant2=0.
All analytic/scientific cases ran once under shared `gpu-slot --mem 1`, with
recorded identity/budget controls and no numerical retry or PDE trajectory rerun.
Frozen source, compiler/runner, input and inherited archive hashes are retained;
selected pins do not claim a hermetic SDK/driver environment.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-metal-stage-replay`.
[run.json](run.json) records every outcome; [fields.json](fields.json) defines
the 91-word layout. The [archive receipt](archive.json) preserves every payload
externally and metadata publicly by kind, regardless of failure. The inherited
complete input/native/face-only evidence remains in its preceding verified
archive. No production source ownership or solver/default/precision/phase/label/
tolerance/mask/training-index/service/admission change.

This component-observer approach stops at its failed gate. Further work on
emmettl/bombcad-work#82 needs a compatible observation or a separately controlled
operator experiment before component attribution; the evolved peak mechanism
remains unresolved. Keep the accepted face-only replay as a control. Corrected
Beirut still fails its separate first-phase gate under emmettl/bombcad-work#62;
no CUDA generation is reopened by these diagnostics.

Required format/lint, warning-free strict build, standalone Swift warnings-as-errors
build and plain `make check-affected` pass, including selected Mac suites and
62 PC tests in 11 suites. Those checks do not change the rejected scientific
gate. All 470 own raw files, both own archives, the parent full archive, consumed
parent inputs and selected compiler/runtime/helper/source pins still match
after verification; see [publication-checks.json](publication-checks.json).
The full archive is 371,220,602 bytes; public metadata is 31 files / 287,844 bytes.
