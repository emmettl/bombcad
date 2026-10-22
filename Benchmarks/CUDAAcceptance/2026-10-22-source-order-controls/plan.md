# Written-order component compatibility controls — 22 October 2026

Tracking: emmettl/bombcad-work#82, parent emmettl/bombcad-work#80.

The completed host-source matrix preserved all 432 observation gates, but its
independent Float32 model differed from captured GPU fluxes in 20,908,970 words.
Before attributing component errors, evaluate a separate model following the
frozen shader's written expression tree. In particular, primitive kinetic energy
uses `0.5 * rho * (velocity * velocity)` rather than the independent model's
`0.5 * momentum * velocity`; reconstructed total energy and Roe speed likewise
retain the shader's parentheses. Reflect primitive velocity as `0 - velocity`,
not conserved momentum before division. This is a CPU model of written source,
not a claim about compiler contraction, reciprocal/sqrt accuracy or instructions.

Keep two fixed models: separate Float32 and separate Float64 written-order
operators. Retain the earlier independent model unchanged. Limit scope to the
existing ideal-gas, one-dimensional, stationary left-wall/copied-right-boundary
stencils; require zero tangential momentum, finite states, supported configuration,
and explicit reconstruction fallback counts. Check analytic uniform flux and
zero update, reflected zero wall mass/energy flux, reflection symmetry, refusal
of unsupported scope, and agreement with the independent Float64 model within
roundoff on smooth/discontinuous nonuniform controls. Preserve control failures;
no numerical producer or independent PDE oracle is rerun.

Freeze the model, controls, driver, imported validators/model and the selected
Python/NumPy byte pins before the first scientific row. Read all 432 saved
source cases, verify their archived input hashes and preceding all-outcome gates,
run the existing canonical source validator, then compare both fixed models
against every executed captured flux. Skipped opportunities remain skipped.
Record per-component word/absolute errors, whole-trace compatibility, fallback
counts, all fixed-factor strata and full/tiled consistency. Do not select a
model or arithmetic policy separately per scalar or discard adverse cases.

Archive every new raw file and verify every member, preserving failed and
ineligible outcomes. Existing large source traces and runtime dependencies stay
immutable in their separately verified archive, referenced by content hashes.
Report a keep/reject/stop decision about using either model for component
attribution. Even full compatibility would not prove emitted instructions or
an independently evolved PDE cause. Any incompatibility retains the limitation;
no flux/precision alternative, default, physical label rule, tolerance, mask,
training index, service or CUDA admission change is authorized by this study.
