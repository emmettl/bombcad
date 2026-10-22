# Next candidate: host observation of actual pre-step source cells (not executed)

Tracking: emmettl/bombcad-work#82. The rejected full-intermediate observer must
not supply ordinary-run evidence. Do not switch the numerical baseline to its
passing subset or change arithmetic/defaults to make it pass.

Investigate an explicit host-side source-stencil option on the existing
33-word update observer, without changing generated Metal source, pipeline
selection, encoder uniforms, buffer bindings or logical batches. In blocking
advance, the previous command buffer is already complete before encoding the
next one. Read the actual conserved source cells at that synchronization point;
retain source indices and raw UInt32 words for each selected cell's five-cell
stencil. The bare 1-D no-charge/no-source scope must prove no intervening source
operation modifies these cells before the sweep. Refuse unsupported periodic,
far-field or geometry configurations rather than guessing ghost mapping.

Do not use the public withState API while batchInFlight: it deliberately refuses
that access. Any internal read must be placed only in blocking advance after the
prior GPU wait and before the next encoding. A general asynchronous encoder hook
would not establish a safe read. Pair source records to actual positive-dt update
samples, keeping skipped opportunities and rejecting missing/overflow histories.

The GPU must execute exactly the existing update-observer program. Require exact
plain/pressure/old-update/host-source state/residual/recorder/time and 33-word
trace parity, plus all prior wave outputs and full/tiled controls. Verify source
centre words against actual captured old-state words on every executed sample;
validate reflected/copy ghost source mappings against known physical indices.
This proposal still needs implementation and those gates before scientific use.

Independent component models can then consume observed conserved inputs and
compare modeled primitive/slopes/predictor/flux values with actual captured face
fluxes. Model outputs are explicitly recomputed counterfactuals, not observed
GPU intermediates. Whole-stage compatibility and residual bounds must retain
all failures and cannot claim emitted instructions or an identified mechanism
where evidence does not distinguish one. This is an investigative route toward
the same unresolved peak cause, not completion of emmettl/bombcad-work#82.

Retain all original 432 method/component/math/CFL/amplitude/resolution/tiling
groups and adverse cases if a scientific matrix becomes justified; exact export
counts, budgets, source/runtime/model/input pins must be frozen before launch.
No new GPU matrix, acceptance/default/target/mask/training-index or service
change is authorized merely by this written proposal.
