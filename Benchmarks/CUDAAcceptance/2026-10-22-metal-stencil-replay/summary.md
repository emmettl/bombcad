# Separate Metal replay matches the saved fluxes — 22 October 2026

Tracking: emmettl/bombcad-work#82, parent emmettl/bombcad-work#80.

The separate Metal stencil replay matches every captured face-flux word in
all 432 declared cases: **82,279,280 Float32 words, zero differences**, including
both faces, all five components and signed zero. Default and unfused policies
each pass all 216 cases. All 216 full/tiled pairs also agree byte-for-byte on
commonly executed observations. [summary.json](summary.json) retains every
fixed-factor stratum; overlapping strata and correlated full/tiled observations
must not be added together.

This establishes a compatible separate face-flux recomputation for the complete
saved corpus. It does not observe production intermediates or emitted instructions,
evolve a PDE, validate physical accuracy, or explain the remaining peak error.
Any intermediate-output variant needs a fresh full-corpus compatibility gate;
adding stores may change compiler arithmetic. No such variant is promoted here.

The runner uses the frozen production `primOfCell`, `mirrored` and `stencilFluxes`
helpers, actual physical Cell words, reflected primitive velocity and captured
lambda. It preserves nil Metal compile options, the contract-off prefix for
unfused arithmetic and ideal-gas function constant 2=0. A parsed scalar-only
uniform layout supplies the relevant recorded configuration. Source, Swift
runner/binary, compiler, inputs, helper imports and device receipts are pinned.
Selected pins do not make the SDK, framework or driver environment hermetic;
compatibility is established by the full output comparison on this host.

Six analytic controls pass before corpus scoring: stationary, moving and
rigid-wall cases under both policies. Bounds were fixed before dispatch and are
conditioned roundoff checks, not tolerances on the scientific byte gate.
Uniform low/high flux values are equal, giving zero conservative update. For
example, the default stationary control has an energy flux of −2.6318271160125732
on each face; equal face residuals cancel in the update. A single-face error is
therefore not a measurement of physical dissipation. The control definitions,
outputs and bounds are all retained in [control-results.json](control-results.json).

All 432 source cases were revalidated against the canonical parser, predecessor
gates, source-history hashes and archived input bytes. The replay covers
8,227,928 executed and 814,552 skipped sampled opportunities. Skipped observations
have no fabricated operation. All actual analytic/scientific cases ran once
under shared `gpu-slot --mem 1`; no numerical retry or production trajectory
rerun was used to obtain compatibility. Four failed host preflights were fully
retained before numerical dispatch: helper path, sibling import path, compiler
driver invocation and SDK/deployment-target invocation. The repaired wrapper
passes Swift typecheck, warning-as-error executable build and empty-manifest
Metal compile/pipeline checks. Compiler caches stay outside the raw archive.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-metal-stencil-replay`.
[run.json](run.json) records every case, input/output hash and process receipt.
The [archive receipt](archive.json) retains all own outputs, original failed
preflights and their inherited copies. Numerical arrays and runtime binaries
stay external by kind, regardless of outcome. Inherited complete source records
remain immutable in their preceding verified archive.

Keep this replay as the face-flux compatibility prerequisite for further bounded
component work on emmettl/bombcad-work#82. The earlier
[CPU-model limitation](../2026-10-22-source-order-controls/summary.md) remains:
those models do not reproduce the captured GPU flux words. Next, any
instrumented replay must preserve all captured flux words before its recomputed
intermediates can be compared with independent component models. Such comparisons
would still describe a compatible replay, not directly captured production
intermediates or a causal peak proof. No production shader, numerical precision,
default, phase/label rule, tolerance, mask, training-index, service or CUDA admission
change. Corrected Beirut remains rejected under emmettl/bombcad-work#62.

Required format/lint, warning-free strict build and plain `make check-affected`
pass, including selected Mac suites and 62 PC tests in 11 suites. The standalone
Swift runner also builds with warnings as errors. Post-check verification covers
all 3,264 own raw files, both archives, consumed source cases and every selected
runtime/compiler/helper/source pin; see [publication-checks.json](publication-checks.json).
The full archive is 266,355,916 bytes; public metadata is 202 files / 1,211,880
bytes. Numerical data and runtime binaries remain external.

The subsequent [91-word component-output variant](../2026-10-22-metal-stage-replay/summary.md)
was tested on the complete corpus and failed flux compatibility in all 432 cases.
Its payloads are retained and rejected for component attribution. This face-only
replay remains accepted; finiteness and full/tiled reproducibility do not waive
the observer's separate compatibility gate.
