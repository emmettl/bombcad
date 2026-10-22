# Protected compensated sweep implementation gate — 2026-10-22

Tracking: emmettl/bombcad-work#81, parent emmettl/bombcad-work#80.

This checkpoint implements the opt-in candidate and its arithmetic control. It does not
report wave-accuracy results or a keep/reject decision for the full scientific experiment.
[The predeclared plan](plan.md) requires 648 retained-residual exports and 648 matching
no-carry controls, with full component, amplitude, resolution, CFL, compiler, tiling and
observation factors. That complete matrix and its independent-reference/conservation
analysis remain pending.

## Numerical method and scope

`configureCompensatedSweep` accepts density-only, energy-only or both. A separate per-cell
Float4 buffer holds density error, energy error, a component mask and a count of all density/energy floor events, including unselected components. A helper scoped to safe math and contraction-off computes the rounded flux
difference, signed increment, corrected increment, new sum and new error. The surrounding
sibling sweep retains its selected default/unfused arithmetic. Unselected components use
the original update statements, not a compensated substitute.

The arithmetic control sets `retainResiduals: false` (CLI `--discard-compensation`) and
clears residuals after every update. Its mask adds bit 4 to density/energy bits 1/2. It uses
the identical protected helper. This is necessary because the protected helper's explicit
flux-difference/product and addition also differ from the ordinary fused update: candidate
versus ordinary alone would conflate arithmetic ordering with residual retention.

The represented conserved quantity is sum minus error. The flux calculation still sees
the stored Float32 state; it does not reconstruct primitives from sum minus error. Floors
clear the residual of the component they override and count events. Residuals survive
sleeping tiled opportunities. Restart/fill disables compensation and update capture;
reconfiguration starts with zero errors and event counts. No checkpoint, physical error
bound, general dynamic-range or broader geometry support is claimed.

The candidate refuses masked/non-1-D grids, charges or pending firings, flame/species,
extra source terms, structures, cut cells, congestion and refinement. The same guard is
rechecked before encoding. Generated sibling kernels use buffer slot 29 for the residuals,
which ordinarily holds structure-cut defects; that geometry is forbidden in this scope.
Slot 30 remains the packed update-trace mapping/output. Ordinary shader source, Cell and
uniform layouts remain unchanged; disabled runs allocate no residual buffer and select
the original cached pipelines. No numerical default or CUDA admission change.

## Diagnostics and CLI

Full residual-buffer hashes join the existing complete coarse state/recorder hashes.
Candidate update traces have format `bombcad-compensated-sweep-updates-1` and 33 fields:
the original 24 plus old/new density/energy errors, component mask, before/after floor
counts, and actual signed density/energy increments passed through compensation. All words
use the existing canonical UInt32 encoding. Ordinary traces retain their 24-field format.
Incomplete/overflowed histories are refused.

`acoustic-phase --compensated density|energy|both --trace-updates --fine` enables the
candidate. Add `--discard-compensation` for the matching no-carry control, `--cfl 0.45|0.225`
and `--rounding default|unfused` for the declared controls. Output snapshots include initial/
final complete residual words, final conserved state, method identity, held-buffer bytes
and advance wall duration. The latter is diagnostic cost under contention, not a quiet
throughput comparison. Candidate traces additionally include the last boundary cell for
later signed boundary-flux auditing. Invalid component/no-carry combinations refuse before
creating output.

No labels, phase rules, thresholds, tolerances, masks, training indexes, host services or
dataset admission changes. emmettl/bombcad-work#81 remains open for all scientific outcomes
and broader validation. emmettl/bombcad-work#80 and emmettl/bombcad-work#62,
emmettl/bombcad-work#63, emmettl/bombcad-work#59/emmettl/bombcad-work#47 remain separately gated.


## Focused verification

The [final strict build](strict-build.log) is warning-free and the [release build](release-build.log)
passes. All six [focused GPU test methods](focused-tests.log) pass, including the existing
ordinary observer tests. The candidate parity/replay method exercises both default/unfused
policies, every component selector, retention/no-carry and full/tiled paths: 24 paired cases.
It compares complete residual/state hashes and replays actual signed increment, sum and error
words. Additional tests retain seeded residuals through skipped tiles, clear both overridden
components under floors, disable/reset on restart, reject unsupported scope/configuration
order and refuse a bounded history overflow. These finite implementation fixtures do not
prove parity across the scientific matrix.

All three [invalid-option checks](invalid-options.json) refuse before output creation,
using [this checker](check-invalid.py). The [source/executable pin receipt](implementation-source-pins.json)
records the implementation inputs before integrated verification. The scientific matrix
has not run. Integrated checks and ordinary digest results are recorded below.


## Initial integration verification (before rebase/instrumentation)

The plain [make check-affected](check-affected.log.gz) passes at core tier: 228 app tests
plus 351 core tests on the Mac, 253 PC Linux tests in 62 suites, and reference/script/doc
checks. All 42 ordinary digest variants in six sets are bit-identical to base
`8515944056f6ec5812655e6b6fc36b283d3108d3`. All source pins still match. The full check used the standard test profile; the separate optimized-release result is recorded below.

Before the scientific matrix, the floor counter and per-case selection were extended
so an adverse case cannot prevent the remaining cases from being attempted. The initial implementation counter covered only enabled components. A subsequent
instrumentation change counts all density/energy floors and adds exact case selection;
the earlier receipts above describe the pre-change snapshot. The full scientific matrix and physical/reference/conservation audit remain in
emmettl/bombcad-work#81.


The [optimized-release focused test run](release-focused-tests.log.gz) also passes all six
methods, including both compiler policies and all 24 paired component/retention/tiling
cases. These exercise the optimized host assembly and the actual GPU helper, separately
from the ordinary digest check. [The implementation check receipt](implementation-checks.json)
records the completed checks and source/executable pin comparisons. No scientific wave
export has run at this checkpoint.


The integrated/release-test builds rebuilt the mutable cached `blastbench` executable,
so its current hash differs from the initial CLI-check pin; both hashes are recorded.
The initial pin is historical, not a frozen executable copy. All 524 producing source
pins still match. The scientific stage must freeze its actual executable/resources
before execution; no scientific outcome is attributed to this mutable-cache checkpoint.


## Final instrumentation and concurrent integration

The incoming terrain mapped-start change in `aff21dff` changes `Scenario+GPU.swift`,
one of the initial source pins. The nearby-session change in `fb237073` touches only app
code. Both were preserved by the clean rebase. The final source snapshot and fresh checks
are recorded separately from the pre-rebase receipts above; the original 42-digest check
is not claimed as verification of the new combined solver.

The final counter records both density and energy floor activity even when a component
is unselected; only selected component errors are cleared. The floor fixture now tests
all selectors with both floors active. `--only-case a1-n512-full` (or another exact case
in the selected resolution matrix) permits one planned case per command, leaving the
default full matrix unchanged. Unknown/missing/out-of-matrix selectors refuse before output.
No scientific wave export has run.


The [final strict build](final-strict-build.log) passes without warnings. The
[combined optimized-release tests](final-release-tests.log.gz) pass all 20 methods in
four suites, covering both diagnostic suites and the incoming mapped-charge/start tests.
All three selectors now verify both density and energy floor counts. All six
[final invalid-option checks](final-invalid-options.json) refuse before output creation.
[The final source/executable pins](final-source-pins.json) replace the initial snapshot
for the fresh combined verification; they explicitly list four changed source/test paths.
The fresh combined ordinary-digest/integration verification is recorded below; the scientific matrix remains pending.


## Final combined verification — passed

The [fresh plain affected check](final-check-affected.log.gz) passes: 238 app plus 351 core
Mac tests, 253 PC Linux tests in 62 suites, reference/script/doc checks, and all 42 ordinary
digest variants in six sets bit-identical to upstream
`aff21dff0944eab205b39def06a22de35f4e1bf4`. This includes both incoming commits and the
final all-floor counter/case selector. All 524 final source pins still match.
[The final check receipt](final-checks.json) records the counts and current cached binary
hash. Both verification jobs are terminal. The optimized-release and six input-refusal
checks above also pass. No scientific wave export, performance win, operating range or
CUDA admission is claimed by this implementation checkpoint.
