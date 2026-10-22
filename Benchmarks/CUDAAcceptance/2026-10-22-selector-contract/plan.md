# Explicit native selector contract — 22 October 2026

Tracking: emmettl/bombcad-work#88 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

Use the immutable six actual clock-input banks from emmettl/bombcad-work#87 and the
original untransformed full Metal main producer unit. Keep its native `prepareStep`,
empty function constants, bindings, dispatch, SDK15 context and source bytes.

1. One nil-options baseline stage on all six banks must reproduce all 24 archived Metal
   output words per record, including controls, speed resets and tile count/dispatch.
   Preserve failures; do not retry a numerical parity failure.
2. Only after the complete baseline gate passes, one candidate stage on all six banks
   sets `mathMode = .safe` and `mathFloatingPointFunctions = .precise`. Other properties
   remain at their defaults. Retain effective property readback, every output word and
   compilation/process outcome. No source rewrite or replacement arithmetic helper.
3. Compare the candidate with the archived native CUDA outputs and exact rational
   Float32 source-order model. Keep full differences, including work counters, clock
   words, stop/clipping decisions and inactive rows. Separately compare each bank with
   its baseline; never infer identical physical states across backend histories.

Primary basis: Apple's [mathMode documentation](https://developer.apple.com/documentation/metal/mtlcompileoptions/mathmode)
and [mathFloatingPointFunctions documentation](https://developer.apple.com/documentation/metal/mtlcompileoptions/mathfloatingpointfunctions),
the [Metal language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
section 1.6.3 (4 June 2026), and installed SDK `MTLLibrary.h`. Safe mode disallows unsafe
arithmetic transformations but keeps within-statement contraction enabled; precise selects
the precise namespace for ordinary FP32 math functions. This is a documented options
contract, not an assertion of unfused execution, correct rounding of every operation or
instruction attribution. Capability/compiler/SDK pins precede dispatch.

One ordinary shared Mac GPU lease per stage (`--mem 1`), 90-minute bound, exact owned
process cleanup. No PC arithmetic job, PDE evolution, throughput claim, production change,
training admission, tolerance, mask or phase-semantics change. Bulk stays held under
emmettl/bombcad-work#39 and emmettl/bombcad-work#47. A passing scalar candidate still needs
independent physical/convergence validation and the existing complete target gate before
any proposed production policy.
