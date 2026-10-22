# Compensated conserved updates: retain the bounded candidate

22 October 2026. Tracking: emmettl/bombcad-work#81; precision parent
emmettl/bombcad-work#80; remaining peak mechanism emmettl/bombcad-work#82.

Retaining protected Float32 update residuals substantially improves weak-pulse
impulse in this bare 1-D experiment. Keep energy-only and combined compensation
as research candidates. Reject the protected helper without residual retention
as a fix for the measured 1 Pa loss. Do not adopt a default or extend this result
to CUDA, geometry, refinement, hot-air/strong-blast labels or product validation.
Peak error remains material, and some stronger-pulse errors worsen.

## Complete matrix and controls

All predeclared 432 single-case commands / 1296 exports completed once:
retain/discard residuals × default/unfused surrounding arithmetic × CFL0.45/0.225
× density/energy/both × A1/10/100 Pa × nx512/1024/2048 × full/tiled, with
plain/pressure/update observations for every group. Every command acquired a
shared 2 GB GPU slot. No numerical case or failed observation was replaced.

All 432 complete observation gates pass: state/residual/recorder/initial/final
hashes, records, steps and host clocks agree across modes; pressure-trace bytes
agree; actual selected operations replay exactly with protected Float32
arithmetic and one compatible ordinary arithmetic policy per whole trace.
Skipped opportunities remain explicit, with no fabricated values. All 216
full/tiled pairs have identical final state/residual/recorder hashes, native
pressure histories, steps and clocks. No density or energy floor event occurred.
All 864 native receiver histories close within the declared window, and offline
and streaming Double phase definitions agree here. This is arithmetic/output
compatibility, not emitted-instruction attestation.

Independent nonlinear Float64 references ran once for each of 157 byte-identical
input sets, retaining all 432 aliases. They use each candidate's exact retained
Float32 initial state, gamma, dx and timestep sequence. All references completed,
with zero reconstruction fallbacks and all phases closed. They retain both
dt-sum and recorded-tick axes; pressure comparisons interpolate only within
reference coverage. Float64 is an independent numerical control, not exact
finite-amplitude PDE truth.

## Accuracy and adverse outcomes

The previously problematic wall receiver, A1 Pa/nx2048/CFL0.225/default/full:

| Method | Native first-impulse error | Native peak error | Independent Float64 impulse error |
|---|---:|---:|---:|
| Ordinary / each matched no-carry selector | −15.59097% | −17.18126% | +0.11443% |
| Retain density only | −2.28628% | −11.71210% | +0.11443% |
| Retain energy only | +0.04010% | −6.24294% | +0.11443% |
| Retain density and energy | −0.08493% | −4.68032% | +0.11443% |

Errors use the existing analytic weak-wave targets and actual native recorder
impulse. Double accumulation of the same native pressure is a separate control.
The represented-pair pressure projection is also a counterfactual: the GPU
continues consuming its stored-state Float32 pressure. At the combined case
above, pair-projected peak error is −4.63763%, while the independent Float64
peak error is −0.40856%. Merely widening the readout does not remove the
remaining evolved-wave discrepancy. This does not yet identify its cause.

Across **all 48 A1 receiver/case combinations per selector** (including the
full/tiled duplicates), worst absolute native impulse errors are 16.75401%
for each no-carry selector, 7.27839% retaining density, 1.44683% retaining
energy and 1.17753% retaining both. Combined retention improves 42/48 and
worsens 6/48 relative to ordinary impulse error. Its worst native peak error
is still 7.80556%. Density alone is insufficient as a general fix in this matrix.
Every A1 no-carry impulse is unchanged from the ordinary baseline; the helper's
explicit rounding alone does not explain the retention benefit.

Stronger-pulse regressions are retained. Combined retention improves 36/48
A10 impulse errors and worsens 12/48 (worst absolute error 0.11465%); at A100
it improves 20/48 and worsens 28/48 (worst 0.07217%). These counts describe
absolute error against the existing analytic target, not a new pass threshold.
Across all amplitudes, only 174/216 no-carry groups match every ordinary final
hash and host clock; do not generalize the A1 impulse equality to complete state
identity everywhere. [results.json](results.json) retains all per-column values.

## Conservation, positivity and cost scope

Conserved changes use exact retained Float32 high/low components and `fsum`
before background cancellation, with unit transverse area. Boundary fluxes are
observed at every step in all 216 full-grid groups. Tiled boundary opportunities
include skips, so their global boundary budgets are explicitly unavailable;
identical final states do not turn skipped slots into flux observations.

Maximum absolute residual-corrected boundary-balance residuals over all full-grid
amplitudes/resolutions/policies are:

| Retention | Mass (kg/m²) | x momentum (Pa s) | Energy (J/m²) |
|---|---:|---:|---:|
| Density only | 1.01e−8 | 4.57e−6 | 1.64043 |
| Energy only | 3.08e−5 | 2.75e−6 | 0.001776 |
| Both | 1.01e−8 | 3.57e−6 | 0.002017 |
| No carry, any selector | 2.97e−5 | 5.41e−6 | 2.49615 |

These are signed global balance checks, not summed absolute increment loss or
a physical dissipation budget. Compensation improves the selected balances but
does not make the rounded flux/operator exactly conservative. The independent
Float64 maximum balance residuals are 1.42e−14 kg/m², 4.86e−16 Pa s and
2.13e−9 J/m². Its minimum final density/pressure across cases are
1.22414 kg/m³ and 101225.545 Pa. GPU runs are stable, captured values finite,
and global floor counters stay zero; this is not positivity validation outside
the guarded scope.

Reported held GPU-buffer bytes range 55,808–223,232 in plain mode,
57,984–231,552 with pressure observation, and 60,824–240,536 with update
observation. The residual representation itself adds 16 bytes per cell. These
are the solver's reported held buffers, not total process/driver/JIT/CPU-history
memory. Plain advance wall times range approximately 0.017–2.246 seconds across
the matrix. They exclude initialization/JIT and were collected on a shared
machine; no quiet throughput, speedup or admission-cost claim follows.

## Evidence and limits

Producer implementation: `4ef88d4daa472f66c815351c947fd3189c1336e0`. Before the
first export, the runner copied/hashed 537 selected source/helper files, 33
runtime/resource files and 15 original analysis files, plus Python executable
and NumPy-core bytes. Before/after default-device queries agree on Apple M4 Max.
Byte checks pass before/after every analysis stage. This is a selected
source/runtime pin, not a hermetic OS/driver/dependency environment or continuous
device attestation. [execution.md](execution.md) records the preserved initial
clock-assertion failure and separately pinned v2 auditor: exact host dt-sum and
integer-tick replay replace the mistaken equality, without a tolerance change
or numerical rerun.

All 5,253 raw files / 7,596,666,240 bytes are archived and each decompressed
member independently verified: 848,690,000 compressed bytes at
`$BOMBCAD_DATA/experiments/2026-10-22-compensated-wave-archive/all-raw.tar.gz`.
The public [evidence](evidence/) includes 3,050 metadata/source/log files in
25 archives / 83,145,104 compressed bytes. Every outcome remains represented;
the public subset excludes trace JSON, numerical NPZ and runtime binaries by
file kind, never by passing status. [archive.json](archive.json) records all
raw and published hashes. Complete traces, reference arrays and executable
bytes remain in the external archive. All producer/reference/controller jobs
are terminal, and the GPU slot is released.

Implementation verification is in [implementation.md](implementation.md) and
[final-checks.json](final-checks.json). The experiment-tool controls pass all
five tests, and pre-run format/lint, warning-free strict build and plain
`make check-affected` pass, including the PC lane. Final publication checks also
pass after preserving incoming whole-event/rubble commit `1ccde59f`: warning-free
strict build, 33 selected Mac tests and 62 PC tests/11 suites. Two existing Linux
unused-result warnings remain in the log. An earlier changing-snapshot refusal
occurred before a PC worker launched, was retained, and was resolved by freezing
repository files during the final verification. See
[publication-checks.json](publication-checks.json).

All 537 frozen producing-source copies, runtime/helper/environment pins and
published/external archive hashes still match after publication preparation.
The current rebased checkout matches 520/524 preceding production pins; four
files differ because of the preserved incoming commit, as listed in
[publication-source-scope.json](publication-source-scope.json). This does not
change the frozen producer or reattribute its results to the incoming tree.

Next: emmettl/bombcad-work#82 isolates or bounds the remaining peak mechanism
using existing histories first, then predeclared actual-stencil/primitive/
reconstruction/flux observations if needed. Broader operating-range/product
validation remains in emmettl/bombcad-work#80 and emmettl/bombcad-work#62;
emmettl/bombcad-work#63 peak admission and emmettl/bombcad-work#59 /
emmettl/bombcad-work#47 CUDA generation/admission remain separate. No numerical
default, phase rule, label, tolerance, mask, training index or service changes.
