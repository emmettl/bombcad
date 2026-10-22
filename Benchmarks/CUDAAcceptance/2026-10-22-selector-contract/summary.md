# Explicit native selector arithmetic contract — 22 October 2026

Tracking: emmettl/bombcad-work#88 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

Explicit Metal `mathMode = .safe` and `mathFloatingPointFunctions = .precise` eliminate
all same-input timestep and stop-decision differences against native CUDA and the exact
rational Float32 source-order model on the six actual clock-input banks. Before testing
the candidate, the nil-options baseline reproduces all 375,672 archived Metal output words
across 15,653 records. Both numerical stages complete once, terminal0, without a numerical
failure or retry. No new PDE trajectory or PC arithmetic job is run.

| Bank | Records | Baseline timestep differences against CUDA | Candidate timestep differences against CUDA |
| --- | ---: | ---: | ---: |
| Flat, Metal inputs | 2,689 | 1,125 | 0 |
| Flat, CUDA inputs | 2,647 | 1,160 | 0 |
| Slope, Metal inputs | 2,753 | 870 | 0 |
| Slope, CUDA inputs | 2,712 | 840 | 0 |
| Beirut, Metal inputs | 2,433 | 1,038 | 0 |
| Beirut, CUDA inputs | 2,419 | 1,036 | 0 |

The candidate preserves every baseline stop decision, speed reset and tile output. Full
24-word baseline/candidate outputs and every common CUDA output difference are retained.
On the CUDA-origin banks all 20 common output words agree with CUDA. On Metal-origin
banks, only `activeTiles` and `tileSweeps` differ from CUDA, whose selector has no tile
arguments; those differences are reported rather than discarded. Timestep, batch time,
last step and clock-word comparisons agree on every bank, including inactive rows.

At slope active step1, both banks give candidate word953740700, matching CUDA, versus
baseline Metal953740701. At Beirut active step2, both give967115815 versus baseline967115816.
Later paired inputs already differ: at Beirut827, candidate words are988878765 on the Metal
bank and988878764 on the CUDA bank; at900 they are988916302 and988916313. Each matches CUDA
on that same bank. The conditional matrices retain both histories; this is not a new
trajectory or a claim that the option change alone restores Beirut closure900.

The original full untransformed main Metal producer source, native `prepareStep`, empty
constants and actual scalar/tile bindings are unchanged. Baseline and candidate use the
same harness binary and linked minOS/SDK15 context. Both requested properties are read
back in receipts. Other option properties stay at defaults; the default language-version
readback is the same in both stages. Source, compiler, SDK capability, host OS/kernel,
bank/output hashes and terminal owned controllers verify independently.

The [Apple documentation](https://developer.apple.com/documentation/metal/mtlcompileoptions/mathmode)
and [Metal language specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
section1.6.3 justify this options experiment: safe mode disables unsafe transformations
while allowing within-statement contraction; precise selects the precise FP32 function
namespace. This experiment does not isolate those settings from one another, identify an
instruction, promise unfused execution or establish general correctly rounded arithmetic.
Agreement with the rational model is measured on these captured inputs.

One compile-only preflight refusal is retained. The first warning-free binary linked
minOS15/SDK27 despite the intended original context. Before any dispatch, its binary,
command and logs were preserved; documented linker arguments made minOS/SDK15 explicit
for the unchanged source. The resulting baseline passed every archived output word.

emmettl/bombcad-work#89 tracks a bounded selector-only trajectory experiment with independent
physical/convergence controls and the existing complete corrected-reference target gate
declared beforehand. Compiling the entire production solver safe would change other
kernels and is not established by this selector replay. Neither a captured reference
schedule nor scalar parity alone is a production generation policy.

Corrected slope acceptance already passes; native Beirut still has one first-phase impulse
failure. Bulk remains held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47. No
production default, tolerance, mask, phase rule or training-admission change.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-selector-contract`. The parent replay
and clock-capture archives stay immutable. All local inputs, outputs, source/toolchain
evidence and failed-preflight artifacts are retained externally; public metadata is
indexed by `archive.json`. No throughput or global GPU-idle claim.

Validation: standalone harness warnings-as-errors, format/lint, warning-free host strict
build and plain affected checks pass, including seven Mac tests and 36 PC tests in four
suites. Existing Python ResourceWarnings remain. Independent full-output verification
and archive member checks are recorded alongside the retained evidence.
