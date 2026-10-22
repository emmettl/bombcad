# Full intermediate observer rejected before scientific use

22 October 2026. Tracking: emmettl/bombcad-work#82 remains open and claimed;
parent emmettl/bombcad-work#80. No scientific stencil matrix was launched.

The proposed full actual-stencil observer fails its observation gate. Preserve
its source and failure evidence, remove it from the solver/CLI/tests, and retain
the current numerical baseline. Passing local or arithmetic subsets do not make
this observer valid for the intended default/unfused scope. This is a diagnostic
implementation rejection, not a newly measured PDE or CUDA accuracy result.

## Implemented candidate and defined-member correction

The sibling sweep retained the existing 33 update/residual words and added
underlying source cells, ghost source offsets/mirror signs, actual primitives,
limited slopes and predicted face pairs. Captured slope/face locals fed the
operator's actual reconstruction and HLLC calls, rather than a second evaluation.
Ordinary .metal source and Cell/uniform ABI were never edited.

Source inspection corrected the historical 150-word proposal to 147: slope()
defines rho, three velocities and pressure, but never defines or consumes slope
gamma. Those three undefined members were omitted. Primitive and predicted-face
gamma are defined and retained. No undefined-member capture was used in a GPU
control. [plan.md](plan.md) records the revised intended experiment; the full
432-group/1728-export scientific matrix remained conditional and did not run.

## Complete focused gate outcomes

The gate compares plain, pressure-only, existing 33-word update and new full
stencil observations for all default/unfused × density/energy/both × retain/no
carry × full/tiled combinations: 24 controls at nx64, A100 Pa, eight steps.
Initial states and the first three ordinary observation modes match. New stencil
results are:

| Policy / residual mode | Complete final hash and clock match | Entire selected 33-word prefix match |
|---|---:|---:|
| Default, no carry | 6/6 | 0/6 |
| Default, retain | 0/6 | 0/6 |
| Unfused, no carry | 6/6 | 6/6 |
| Unfused, retain | 0/6 | 6/6 |

Default controls contain 334 differing selected prefix words in total. Every
retained-residual control changes the complete final hash, including unfused
cases with identical selected prefixes. This is why selected-cell agreement is
insufficient: it does not establish transparency of unobserved cells/residuals.
Only 6/24 controls pass both gates, all unfused/no-carry. That subset cannot
replace the declared scope or justify changing arithmetic/defaults.

The initial complete GPU test run records 124 issues. A second bounded control
run adds per-case reporting without changing the GPU diagnostic generator or
the exact gates; it again records 124 issues and supplies the table above.
This is an explicit classification of a failed implementation gate, not an
unreported retry of the scientific matrix. Both failures are retained. Separate
source/ghost-map and constant-stencil/skip/scope/overflow controls pass; they do
not override the failed transparency test. An earlier test-harness compile error
in nested pressure-history comparison is also retained and produced no GPU data.

[results.json](results.json) retains all 24 labeled outcomes; the full failure
logs retain actual differing words. The evidence shows observer-induced output
differences. It does not identify an emitted instruction, prove that one store
or one arithmetic expression caused them, or determine the original peak-error
mechanism. No tolerance was relaxed and no passing variant was substituted.

## Retained evidence and production restoration

The [rejected prototype](rejected-prototype/) preserves all five Swift source/
test files and the plan, as text outside build targets. [prototype-pins.json](prototype-pins.json)
is a **post-control** snapshot. These focused attempts did not have a pre-run
immutable-byte receipt; do not present that snapshot as continuous provenance
or a frozen scientific producer. All raw test/compile failures remain public.
All owned test processes are terminal and the shared GPU slot is released.

The three modified production files were restored byte-for-byte to the current
published baseline; the two new diagnostic/test files and unshipped release
fragment were removed. The failed observer is not an available solver/CLI
feature. Final publication verification concerns that restored tree, and is
recorded separately; it does not turn failed prototype tests into passes.
Restored-tree format/lint, warning-free strict build and plain
`make check-affected` pass, including 33 selected Mac tests and 62 PC tests/11
suites. Source-restoration and evidence hashes were checked again afterward.
[restoration.json](restoration.json) and
[publication-checks.json](publication-checks.json) retain this distinction.

[Next host-side plan](next-host-plan.md): read actual source cells at the existing
blocking-advance synchronization point while keeping the current GPU program
unchanged, then require complete observation/prior-wave gates before any use.
That route supplies observed conserved inputs for explicitly recomputed component
models, not actual GPU intermediate variables. It has **not been implemented or
executed**. The original operator cause is unresolved; emmettl/bombcad-work#82
stays open. No numerical default, phase rule, label, acceptance tolerance, mask,
training index, service or CUDA admission change.
