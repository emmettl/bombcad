# Host-source scientific matrix — frozen before launch, 22 October 2026

Tracking: emmettl/bombcad-work#82, parent emmettl/bombcad-work#80.

Run exactly 432 single-case commands /1728 exports once: retained/no-carry ×
default/unfused × CFL0.45/0.225 × density/energy/both × A1/10/100 Pa ×
nx512/1024/2048 × full/tiled. Every command exports plain, pressure-only,
existing update and host-source modes to distinct files. Use the already frozen,
validated 8ecf240b-content CLI-control executable/resources, checking all 529
published producer-source pins and the control runtime hashes before copying.
Freeze all scripts, imported legacy helpers, independent Euler model, prior-wave
inventory and configuration before the first case. Require 128 GiB free at start.

Each GPU command acquires shared gpu-slot --mem 2 and has an 80-minute execution
budget including queue acquisition. Termination requires exact owned PID/group,
boot and birth identity; retain every failed/partial result and no automatic
retry. Observation timeouts never authorize another launch. Record contextual
before/after device queries and Python/NumPy-core byte pins; these are selected
pins, not a hermetic OS/driver/dependency environment. No quiet throughput claim.

After producer termination, audit every case. Require exact four-mode physical
state/residual/recorder/clock/initial/final and pressure-byte parity; every old
33-word GPU trace must equal its host-source counterpart. Compare all prior
compensated-wave outputs, including full update/pressure trace bytes and physical
snapshot fields. Parse canonical source/residual words, fixed ghost maps,
pre-step/old-state continuity, overlapping physical cells and configuration.
Report full/tiled final and entire host-source history parity separately; do not
silently waive either discrepancy. Retain parser/observation/producer failures
as unavailable or ineligible outcomes rather than dropping or replacing them.

Use the existing all-outcome wave replay/phase/conservation audit, retaining
its floor/unsupported-boundary limits. Source arrays precede the completed step
identified by shared step/time/dt, so compare source-centre Double pressure with
the preceding derived stored-state pressure sample. Reuse prior independent
Float64 reference summaries only when exact initial/dt/clock/receiver/gamma/dx
input keys match; no oracle or GPU case rerun to obtain a pass.

For every executed opportunity retain six conditional local operators: Float64
stored source, Float64 represented-pair source, separate Float32 reference, and
Float64 operators rounding respectively primitives, limited slopes or predicted
faces to Float32. Preserve their primitive/slopes/predictor/faces/flux/delta arrays,
fallbacks and actual captured flux comparisons. Record complete Float32-model
flux-word compatibility, never per-scalar policy selection. Skipped opportunities
have real host reads but no invented GPU flux operation or model-versus-GPU match.

Pressure/momentum-flux quantization is a hypothesis. Report absolute face and
face-difference errors, conditional delta errors, nonzero model differences with
equal native faces, and Float32 spacing. Such counts are not physical dissipation.
All intermediates are recomputed counterfactuals, not observed GPU variables or
emitted instructions; local conditional updates are not evolved PDE solutions.
Retain every amplitude/policy/component/tiling result and stronger-pulse regressions.
No numerical default, phase/label/tolerance/mask/training-index/service/CUDA
admission change or alternative solver algebra is authorized by this matrix.
