# Host source-stencil observer — 22 October 2026

Tracking: emmettl/bombcad-work#82 remains open and claimed.

Read actual physical source conserved words and compensation residual words at
the existing blocking-advance synchronization point, after the previous GPU wait
and before encoding the next part. The first blocking call requires no batch in
flight. This does not change GPU source, pipelines, uniforms, bindings, logical
batches, 24/33-word layouts or numerical defaults. The option requires the bare
compensated 1-D scope, copied open faces and no periodic sides; reflective x-face
mapping must remain fixed. Public withState is not used mid-batch.

Keep source physical indices and ghost velocity signs as mapping metadata.
These are not observed GPU primitives, slopes or reconstructed faces. Source
centre conserved/residual words must match actual old-state/update words on
every executed sample. Retain host reads even when a tiled GPU opportunity skips;
GPU skipped values remain explicit zeros. Refuse incomplete/asynchronous,
overflowing or centre-misaligned histories. Restart discards capture.

CLI --trace-source-stencils requires --trace-updates and --compensated, and adds
a fourth distinct output mode. Keep the prior three outputs/headers unchanged.
New canonical UInt32 source/residual arrays retain M2/M1/C/P1/P2 physical cells
and enough configuration for explicitly recomputed component models.

Before scientific use: focused and optimized-release four-mode/trace-word/
full-tiled parity, physical neighbor/ghost checks, skip/overflow/scope/asynchronous
refusals, CLI input rejection, warning-free strict build, plain make
check-affected and required bit-identical ordinary digests. Existing 432 groups
and all adverse amplitudes/policies/components/retention/tilings remain intended
for the later 1728-export scientific matrix. Freeze verified sources, executable,
resources, runner, parser/component models and exact budgets before launching it.
This implementation gate is not that scientific matrix or an operator diagnosis.

No numerical default, phase target, label, tolerance, mask, training index,
service, general geometry/refinement/checkpoint support or CUDA admission change.

Implementation CLI control, declared before launch: A100 Pa/nx128/full,
default surrounding arithmetic, CFL0.45, both residuals retained, four observation
modes. This is outside the planned fine-grid scientific matrix and tests output
serialization/transparency only, not wave accuracy. Freeze source/executable/
resources first, retain all outputs and invalid-flag attempts, and run once.
