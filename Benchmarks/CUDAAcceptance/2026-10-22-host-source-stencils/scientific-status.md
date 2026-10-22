# Scientific pipeline and matrix launch — 22 October 2026

> **Paused by user direction, 22 October 2026:** all 432 producer commands completed,
> but the full auditor is stopped with SIGSTOP at its verified owned PID83120.
> Partial audit output is preserved. No weak-wave work resumes until fresh
> slope/Beirut acceptance pilots use Metal main containing `aff21dff`.
> See [the fixed-reference prerequisite](../2026-10-22-fixed-terrain-reference/plan.md).
> Earlier launch/check descriptions below are historical checkpoints.

Tracking: emmettl/bombcad-work#82 remains open and claimed; parent
emmettl/bombcad-work#80. The remaining peak mechanism is unresolved.

The parser and six independent local counterfactual models are implemented in
[source-audit.py](source-audit.py) and [components.py](components.py). Controls
compare analytic uniform flux, full-array Euler centre updates in Float32 and
Float64, nonuniform smooth/discontinuous inputs and explicit refusal/rounding
scope. All three pass on Mac and on BLINKENLIGHTS using its existing Python3.12.3 /
NumPy2.5.2 venv, one CPU thread and no GPU. The initial system-Python preflight
failed for missing NumPy and is retained; no package was installed. The PC result
establishes within-host reference agreement, not cross-host numerical equality
or throughput. See [pc-component-controls.json](pc-component-controls.json).
Three Mac source-parser controls additionally exercise actual serialized words,
latched-state continuity and malformed source/ghost/executed rejection. The
[pipeline control](pipeline-control.json) verifies all six finite models and
exact pre-step pressure alignment using the earlier nx128 CLI fixture; its
self-derived baseline is not an independent wave-accuracy test.

The frozen [scientific plan](scientific-plan.md) launches exactly 432 commands /
1728 exports, retaining every amplitude, resolution, CFL, arithmetic policy,
component selector, carry/no-carry and tiling outcome. Each command uses shared
`gpu-slot --mem 2`, an 80-minute queue-inclusive budget and no automatic retry.
The validated CLI-control executable and resources are immutable copies, with
SHA256 `9a67af6a53819ee4f04f3611f2be98d1e52403d9469681196883bfb6ef453f86`.
Its producing source content matches published implementation `8ecf240b`; the
binary was originally built from that implementation's dirty source state atop
`d2ebdf4e`. These provenance facts are retained separately in `run.json`.

Raw root: `$BOMBCAD_DATA/experiments/2026-10-22-host-source-matrix`.
Controller started 22 October 2026 at 05:06:02 UTC, PID53856, boot
sec1790719465/usec531341, original exec handle3440. `run.json` is authoritative
for current state and child identity. Do not restart on an observation timeout.
The producer freezes 538 selected source/helper files plus runtime resources,
analysis imports and selected Python/NumPy-core byte pins. This is not a hermetic
OS/driver/dependency environment. All 529 preceding published source pins and
validated runtime pins were checked before launch.

The first completed A1/nx512/full/default/CFL0.45/density-retained case passes an
early read-only audit: four-mode physical parity, old word replay, source parser,
six finite models, exact pre-step pressure alignment and prior-wave update and
pressure byte equality. Receipt: `early-audit/result.json` under the raw root.
This is one case and does not establish full-matrix acceptance or causal attribution.

After the producer terminates, run its frozen `analysis/audit-sources.py` against
all 432 outcomes. It verifies prior-wave and four-mode gates, full/tiled final
and entire source-history parity, consumed-file pins and unchanged reference
input keys. Independent Float64 histories are reused only for exact matching
inputs. No GPU producer or temporal oracle is rerun to obtain a pass. The new
[summarizer](summarize-sources.py) and [archive tool](archive-scientific.py) were
added after producer launch and are separately versioned postprocessing; they
are not part of its frozen numerical pipeline. Archive every raw file and verify
every decompressed member. Public metadata selection is by file kind, never pass
status. Full-matrix audit, archive and interpretation are still pending.

All model intermediates are recomputed counterfactuals, not observed GPU stages
or independently evolved PDE solutions. Native equal-face counts and conditional
increment sums are not physical dissipation or proof of peak causation. No quiet
performance claim. No default, phase, label, tolerance, mask, training-index,
service or CUDA admission change.

Pipeline publication checks: required format/lint and strict build pass without
compiler warnings; plain `make check-affected` passes scripts/reference/docs,
seven Mac tests in one selected suite and 36 PC tests in four suites. Existing
implementation tests and ordinary bit-identical digest evidence remain in
[publication-checks.json](publication-checks.json); this tooling-only stage does
not rerun or supersede that broader implementation gate.
