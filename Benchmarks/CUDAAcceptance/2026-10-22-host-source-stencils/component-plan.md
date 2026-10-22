# Scientific component analysis — original prelaunch requirements

Current execution state is recorded in [scientific-status.md](scientific-status.md).
The requirements below preceded implementation and remain in force.

Tracking: emmettl/bombcad-work#82. Host-source implementation controls do not
identify the remaining peak mechanism. Do not launch a scientific matrix until
this parser/model pipeline, its controls and the immutable runner are ready.

Preserve all 432 preceding groups /1728 four-mode exports, every adverse outcome,
actual timestep/clock axes and prior-wave/full-tiled gates. Verify canonical
source/residual UInt32 shapes, physical indices/ghost signs, executed/skipped
semantics, source-centre/old-state alignment and every consumed-file hash. Models
use the recorded Float32 configuration and lambda, widened explicitly as needed.

Source arrays are pre-update state, while their shared step/time/dt keys identify
the completed update. For update k, compare source-centre pressure with the
preceding native sample k−1 where needed, not the post-update sample k. Preserve
that distinction across logical-batch boundaries and zero-dt no-op parts.

Evaluate an independent Float64 five-cell MUSCL-Hancock/HLLC operator from the
observed physical conserved inputs and declared ghost mapping. Retain primitive,
limited-slope, predicted-face and low/high flux arrays, fallback/positivity
outcomes and comparison with actual captured GPU face fluxes. Validate the local
operator against constant-state analytic fluxes and the centre update of the
existing independent full-array Euler reference, including nonuniform fixtures.

Predeclare pressure/flux quantization as a hypothesis, not a finding: compare
absolute-pressure momentum face fluxes and their differences with the Double
component model, retaining Float32 spacing and zero/nonzero difference counts.
Distinguish primitive conversion, limiting/predictor effects, HLLC evaluation and
rounded flux difference/product from residual-retaining storage. Absolute lost
increment counts are not a physical dissipation budget. A mismatch with an
independent model does not alone isolate one of those stages.

Where explicit Float32 operation models or rounded-stage counterfactuals are
used, report whole-stage/whole-trace compatible policies and failures; never
choose a different passing arithmetic model for each scalar. Native recorder
pressure can constrain its own evaluation model, but cannot attest a different
kernel's unobserved primitive evaluation. Also retain represented-pair source
counterfactuals separately: the GPU does not consume those low-part projections.

All reconstructed model intermediates are recomputed counterfactuals, not
observed GPU variables or emitted instructions. Local conditional updates are
not independently evolved PDE solutions. Keep original analytic targets and
reference controls. Only propose alternative algebra if the complete component
evidence supports it, with a new predeclared all-outcome experiment. No default,
acceptance tolerance, phase/label/mask/training-index/service or CUDA admission
change belongs to this analysis.
