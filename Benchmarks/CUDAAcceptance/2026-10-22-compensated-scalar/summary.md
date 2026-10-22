# Compensated scalar compiler gate — 2026-10-22

Tracking: emmettl/bombcad-work#81, parent emmettl/bombcad-work#80.

## Result and decision

All 18 predeclared GPU dispatches complete: eight fixed input sequences, three methods,
three compiler policies, with and without per-step trace stores. Every one of the nine
observation pairs has exactly matching final sum/error words across all eight sequences.
No numerical sequence is discarded, replaced or rerun.

**Unprotected Kahan is rejected for the next default/unfused candidate.** Under both fast
policies its entire trace and final sum/error words equal naive addition. It differs from
the explicitly operation-rounded Kahan CPU reference in 40,120 of 49,536 trace words per
policy. Turning off contraction alone does not protect this addition/subtraction algebra.
This is observed output behavior, not an emitted-instruction attestation.

**A locally protected Kahan helper passes this bounded arithmetic gate.** Its function body
uses `#pragma METAL fp math_mode(safe)` and `contract(off)` while the surrounding library
retains the selected policy. All 148,608 protected trace words match the CPU reference
exactly across default, unfused and safe/unfused libraries. The safe/unfused library's
unprotected Kahan also agrees exactly with its protected helper. All naive traces match
the separate Float32 CPU addition model.

Keep the protected helper as a candidate for the component-wise 1-D solver experiment;
do not adopt an unprotected algebraic compensation expression. This does not establish
PDE accuracy or close emmettl/bombcad-work#81.

## All fixed sequences, including the adverse outcome

The [predeclared plan](plan.md) fixes canonical Float32 input words and reset events.
There are 24,768 scalar updates per traced method/compiler pair. Density starts from
Float32(1.225); energy starts from exactly 253314.546875 J/m³. Density increments are
±2⁻²⁷ and energy increments ±2⁻¹². For Kahan's error convention, the corrected readout
is Double(sum) − Double(error). This is an observation of its representation, not an
extra value the solver currently consumes.

Maximum absolute corrected-readout error against the cumulative Double `math.fsum`
target after the most recent reset:

| Sequence | Updates | Naive / unprotected fast | Protected Kahan |
|---|---:|---:|---:|
| Density positive | 4096 | 0.000030517578125 | 0 |
| Density negative | 4096 | 0.000030517578125 | 0 |
| Energy negative | 4096 | 1 | 0 |
| Energy sign reversal | 4096 | 0.25 | 0 |
| Signed zeros | 2048 | 0 | 0 |
| Large cancellation | 192 | 65 | 21 |
| Cross zero | 2048 | 0 | 0 |
| Density reset | 4096 | 0.00000762939453125 | 0 |

The density sequences finish with ±0.000030517578125 accumulated change, and the energy
negative sequence with −1 J/m³. Naive and unprotected-fast addition leave those stored
starting values unchanged; protected Kahan reaches the exact final targets. Its residual
also preserves the sub-ULP portion between stored changes. The sign-reversal sequence's
final target returns to the start, so final error alone would hide naive's 0.25 intermediate
error. Both full histories are retained.

**Compensation is not universally exact.** The large-cancellation adversary starts at 1
and repeats `[2²⁴, 1, −2²⁴]` 64 times. Its exact final target is 65; naive/unprotected-fast
produce 0 and protected/safe Kahan produce 86. The protected result matches the specified
Kahan algorithm, but is numerically wrong by +21. No claim of lossless general accumulation,
positivity, conserved PDE balance or arbitrary dynamic-range support follows.

The reset fixture replaces the sum with the original density and explicitly zeros the
error before increments at indices 1024, 2048 and 3072. It verifies that explicit scalar
rule; actual solver restart/clamp/checkpoint behavior has not been implemented or tested.

## Compiler contract and scope

[Apple's Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf),
2026-06-04, section 1.6.3, pp.15–17, documents scoped math-mode and contraction pragmas.
[MTLMathMode.safe](https://developer.apple.com/documentation/metal/mtlmathmode/safe)
disables unsafe floating-point transformations. The probe places both pragmas at the
start of the protected helper's compound statement. The default library uses nil compile
options; unfused prepends contract-off without changing math mode; safe/unfused additionally
sets `MTLCompileOptions.mathMode = .safe`. These mirror the existing default/unfused
distinction, with a separate safe control. There are no multiplies here: the contraction
control is retained for consistency, but does not test flux/increment FMA behavior.

The standalone probe builds with `-O -warnings-as-errors`, target arm64/macOS15, on Swift6.4;
all dispatches run on Apple M4 Max/macOS27.0.1. These are finite scalar fixtures on one
compiler/device, not an independent physical wave experiment, CUDA validation, compiler
proof, performance comparison or quiet-run measurement. Input words are dynamic buffer
loads. Function constants produce separate traced and final-only pipeline specializations.
The trace captures post-update sum/error, not compiler instructions or every internal value.

No production solver, ordinary shader, Cell/uniform ABI, numerical default, target,
label, tolerance, mask, training index or service changes. No new dependency is installed.
Full density-only/energy-only/combined PDE controls, residual hashing, actual-update replay,
clamp/restart support, conservation/stability and memory/cost reporting remain required
in emmettl/bombcad-work#81. emmettl/bombcad-work#80, emmettl/bombcad-work#62,
emmettl/bombcad-work#63 and emmettl/bombcad-work#59/emmettl/bombcad-work#47 remain open.

## Evidence and reproduction

- [Swift probe](probe.swift), [explicit Float32 reference](reference.py), [single-run controller](run.py).
- [Post-hoc independent audit](independent-audit.py): Decimal exact final binary-input targets
  agree with Double `math.fsum`; whole trace/final comparisons retain every method.
- [Complete archive receipt](archive.json): all 16 raw files / 3,798,939 bytes archived and
  independently decompressed/hashed, 225,613 compressed bytes. All 15 non-executable files
  are published under `evidence/` (205,295 compressed bytes), including complete input and
  trace words, results, original run receipt, logs and four frozen producing source files.
  The producing executable remains in the external archive. No outcome-based filtering.
- The controller and all four child commands are terminal; the GPU slot is released.

Raw root: `$BOMBCAD_DATA/experiments/2026-10-22-compensated-scalar`.
`run.py` refuses an existing root and freezes its four producing inputs before compilation.
The original CPU audit and GPU output can be rechecked without any GPU execution:

```sh
python3 reference.py audit RAW-ROOT/fixtures.json RAW-ROOT/gpu.json NEW-RESULTS.json
python3 independent-audit.py RAW-ROOT NEW-INDEPENDENT.json
```

The first command also verifies the fixture against its fixed definitions. An observation
timeout is never a reason to launch another copy of the experiment.


## Repository verification

Format/lint and [warning-free Mac strict build](strict-build.log) pass. The plain
[affected check](check-affected.log.gz) passes at covered tier: seven selected Mac tests,
36 PC Linux tests in four suites, plus reference/script/document checks. Two existing
Linux unused `createFile` result warnings remain in `USDSceneWriter.swift`. No production
solver/shader changes require new digest runs for this standalone probe. All producing
source/fixture/executable receipts still match, and all 15 published gzip copies reverify.
