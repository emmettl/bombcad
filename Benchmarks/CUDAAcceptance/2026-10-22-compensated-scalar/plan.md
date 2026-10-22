# Predeclared compensated scalar gate — 2026-10-22

Tracking: emmettl/bombcad-work#81, parent emmettl/bombcad-work#80.

Before any production sweep change, run eight fixed scalar sequences: density positive/
negative sub-ULP increments, energy negative increments, energy sign reversal, signed
zeros, a large cancellation adversary, crossing zero, and explicit density reset events.
Inputs use canonical Float32 words. All sequences and reset indices are frozen before
compiling/executing the probe; no failing sequence is removed or replaced.

Compare naive addition, ordinary Kahan addition, and a Kahan helper with scoped
`#pragma METAL fp math_mode(safe)` and `contract(off)`. Compile default (nil options),
unfused (global contract off, otherwise default) and safe/unfused controls. Each of nine
method/compiler pairs runs with and without per-step trace stores: 18 GPU dispatches.
Keep per-step sum/error words and final words, explicit operation-rounded CPU references,
and Double `math.fsum` targets after the most recent reset. Compare traced/final-only
results exactly. Do not infer arbitrary-program correctness from these finite fixtures.

The Kahan error convention is `y=delta-error; next=sum+y; error=(next-sum)-y`.
Residual correction is `sum-error`; a reset explicitly replaces sum and clears error
before that step's increment. This models an explicit restart/clamp event, not a solver
clamp implementation. Large cancellation may defeat ordinary Kahan; retain that result.

Gate the next solver prototype on protected-helper CPU word agreement and observation
parity. Unprotected failures are experimental results, not reasons to rerun or discard.
Use the shared GPU slot, bounded 10-minute command, frozen source/executable/fixture pins,
and retain all output. No performance claim, solver/default/shader/Cell ABI change or
dataset admission. This gate cannot close the full PDE experiment in emmettl/bombcad-work#81.

Compiler contract: Apple Metal Shading Language Specification, 2026-06-04, section 1.6.3,
pp.15–17, https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf;
https://developer.apple.com/documentation/metal/mtlmathmode/safe.
