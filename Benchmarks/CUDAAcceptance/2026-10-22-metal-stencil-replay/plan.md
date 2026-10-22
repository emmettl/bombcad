# Separate Metal stencil replay compatibility — 22 October 2026

Tracking: emmettl/bombcad-work#82, parent emmettl/bombcad-work#80.

The written-order CPU models do not match captured GPU flux traces. Test whether
a separate Metal kernel using the frozen production helpers can reproduce the
observed fluxes from the same physical source words. This is a recomputation in
a new compilation/dispatch context, not an observation of production intermediates.
No production shader, executable, state or PDE trajectory is changed or rerun.

Freeze the 0528-Solver.metal source from the accepted host-source matrix, the
replay kernel/Swift runner/Python driver and imported validators before GPU use.
Preserve nil Metal compile options and the original default/unfused contract
prefix, ideal-gas function constant 2=0, physical Cell words, primitive reflection
and observed lambda. Reuse the parsed scalar-only SolverUniforms layout. Refuse
unsupported tangential momentum or configuration. Record source, runner/binary,
input, dependency and device provenance; selected pins are not a hermetic system.

First run uniform stationary, uniform moving and rigid-wall analytic controls
under both fixed arithmetic policies, with predeclared roundoff bounds. Preserve
failures and do not score the corpus if these mathematical controls fail.
Then replay every executed opportunity in all 432 archived cases once, after
canonical validation and archived-hash checks. Skip no declared case. Retain
skipped opportunities as unavailable operations, not invented fluxes. Shared
Mac gpu-slot --mem 1 protects both GPU commands; each has an 80-minute limit,
no automatic retry, and termination only of an identity-verified owned group.

Compare all five components of both returned face fluxes to the actual captured
UInt32 words, including signed zero. Report numeric versus bit differences,
per-component errors, every fixed-factor stratum, and common-executed full/tiled
parity. No tolerance applies to this byte-compatibility gate. Retain every failed
or ineligible outcome. A partially compatible policy/case subset does not pass
the complete 432-case gate. Do not change contexts or models per scalar to get a
match. No intermediate-stage attribution unless the full gate passes; any later
intermediate-output variant would need its own fresh compatibility controls.

Archive every own raw file and verify all members. Large input/output arrays
stay external by kind, never by outcome. All inherited complete source records
remain pinned in their already verified archive. Record keep/reject/stop for
this separate replay as an attribution prerequisite; no instruction attestation,
physical dissipation, peak-cause proof, throughput claim, default, precision,
phase/label/tolerance/mask/training-index/service or CUDA admission change.

Analytic control bounds, fixed before the first dispatch: epsilon is Float32's
machine epsilon, and c is the ideal-gas sound speed of the represented input.
Mass bound = 32 epsilon rho (|u|+c); momentum bound = 32 epsilon
(p + rho (|u|+c)^2); energy bound = 32 epsilon (E+p)(|u|+c).
Uniform controls require equal low/high flux values (zero conservative update),
plus these analytic-flux bounds. Wall controls require finite positive normal
momentum flux and mass/energy within their zero-flux bounds. These conditioned
roundoff checks are separate from the strict scientific byte-compatibility gate.

Preflight amendment before any compiler/GPU work: the first wrapper assumed
`analysis/cuda/job.py` existed in the preceding source-matrix archive. It does
not. That launch exited before compilation or dispatch; the complete partial
folder, original wrapper/plan and traceback are preserved as preflight-1.
Freeze the existing repository scalar-layout parser explicitly into the new
analysis folder, pin both original/copy, and use that copy. This changes only
host ABI parsing provenance; no shader, mathematical bound or numerical command
has run or been changed. Include the full failed preflight in the final archive.

Second preflight also ended before compilation/dispatch: importing the existing
queue process-identity helper required its sibling module search path. Preserve
preflight-2 (including its retained preflight-1 copy), add that search path, and
freeze/pin all five imported queue modules. Verify imports and the frozen scalar
ABI before the next launch. Neither failed host preflight executed a GPU command;
no model, arithmetic policy, analytic bound or scientific case is retried.

Third host preflight reached the compiler but failed before compilation because
resolving swiftc's symlink invoked swift-frontend without a frontend action.
The runner independently passes `xcrun swiftc -typecheck -warnings-as-errors`.
Preserve preflight-3, invoke the compiler driver through its original swiftc
path, and record both driver hash and resolved path. Add an empty-manifest Metal
compile/pipeline preflight under the shared slot before either numerical command;
it creates both declared pipelines but issues no numerical dispatch. The six
analytic and 432 scientific cases, source, bounds and strict gate are unchanged.

Fourth build preflight required explicit SDK/deployment-target arguments when
invoking the standalone compiler. Preserve preflight-4, including the successful
manual `xcrun --sdk macosx swiftc -target arm64-apple-macosx14.0 -sdk <selectedSDK>`
build and empty-manifest Metal compilation of both policies. That preflight
issued zero numerical dispatches. Use this tested invocation, pin compiler and
xcrun bytes, and record SDK path/target; do not claim a hermetic SDK environment.
All mathematical/scientific commands and strict matching criteria remain as
originally declared. Compiler caches live outside the own-raw archive root.
