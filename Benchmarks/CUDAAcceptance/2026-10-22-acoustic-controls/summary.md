# Fine acoustic arithmetic and temporal controls — 2026-10-22

Tracking: emmettl/bombcad-work#80, supporting emmettl/bombcad-work#62.

## Result

All 144 predeclared Metal runs complete stably. Every plain/observed and full-grid/tiled
pair matches exactly on complete coarse state/recorder hashes, selected records, steps and
times. All 18 shared-baseline checks (12 run snapshots and six pressure histories at nx512,
default arithmetic, CFL0.45) exactly reproduce the published preceding stage. Every receiver
history has exact replay under a single compatible Float32 arithmetic model. All 144 receiver
histories close; the offline and streaming Double definitions select identical impulses and
closing samples. This does not eliminate the separate analytical three-phase counterexample.

The 1 Pa accuracy limit is not cured by refinement or smaller timesteps. With default
arithmetic and CFL0.45, wall-cell impulse errors are −0.962%, −0.437%, −3.037% at
512/1024/2048 cells. Halving CFL gives +2.237%, −16.754%, −15.591%. Unfused arithmetic
changes those outcomes materially without delivering convergence. At 100 Pa, finest wall-cell
impulse errors remain within about 0.066% across all four controls. No setting is selected.

## Declared controls

[The predeclared plan](plan.md) fixes the same 16 m, ideal-gas, compact bipolar direct pulse
and rigid-wall reflection as the [preceding study](../2026-10-22-weak-acoustic/summary.md).
A=1/10/100 Pa; nx=512/1024/2048; both full-grid/tiled and plain/consumed-pressure observation;
existing default/unfused kernel arithmetic policies; CFL0.45/0.225. Each of four CLI
invocations performs 36 numerical runs under the cooperative GPU slot. All four owned
process groups are terminal; no GPU reservation remains. This is not a quiet timing study.

Only the opt-in CLI changes: `--fine` chooses the three finer grids and `--cfl` accepts
exactly 0.45 or 0.225. It records initial conserved density, x-momentum and energy in
addition to host-projected overpressure. The default matrix still selects 128/256/512 and
CFL0.45. No shader, solver default, label, tolerance, mask or training-index changes.

The far receiver is its actual cell centre just above x=4 m; the wall receiver is x=dx/2.
Every reference uses those physical centres and actual sample times, with each consumed
Float32 timestep as the integration weight. The stop remains 14/c. Percentages are signed
(measured/reference−1); impulse means the current recorder's first phase. Tiled results are
identical to the full-grid values below.

| A (Pa) | nx | Default .45: direct / wall I error | Unfused .45 | Default .225 | Unfused .225 |
|---:|---:|---:|---:|---:|---:|
| 1 | 512 | -0.685% / -0.962% | -1.065% / -1.256% | +1.187% / +2.237% | +1.403% / +2.815% |
| 1 | 1024 | -0.098% / -0.437% | +0.195% / +0.469% | -8.227% / -16.754% | -4.158% / -10.543% |
| 1 | 2048 | -1.397% / -3.037% | -1.168% / -2.931% | -4.918% / -15.591% | -3.224% / -10.382% |
| 10 | 512 | -0.051% / -0.108% | -0.044% / -0.090% | -0.070% / -0.023% | -0.092% / +0.034% |
| 10 | 1024 | +0.073% / +0.114% | +0.023% / -0.001% | -0.149% / -0.570% | +0.019% / -0.093% |
| 10 | 2048 | +0.022% / -0.047% | -0.081% / -0.218% | -0.857% / -2.113% | -0.470% / -1.037% |
| 100 | 512 | -0.050% / -0.011% | -0.041% / -0.013% | -0.079% / -0.039% | -0.072% / -0.021% |
| 100 | 1024 | -0.022% / +0.036% | -0.019% / +0.033% | -0.030% / +0.034% | -0.022% / +0.027% |
| 100 | 2048 | -0.012% / +0.029% | -0.017% / +0.019% | +0.001% / +0.054% | -0.014% / +0.065% |

The complete peak, pressure-history, closure-time, native/Double integration and initial-state
metrics are in [results.json](results.json). At 1 Pa/nx2048, the wall-cell peak error is
−3.899% at CFL0.45 for both policies, versus −17.181% default / −15.228% unfused at CFL0.225.
The default/CFL0.225 wall closing time is about 0.255 ms later than the linear reference.
Changing arithmetic is a diagnostic control, not a repair or physical validation.

## Separating initialization, propagation and recording

The independent analytic reference is Double linear acoustics, not exact nonlinear Euler.
A second [Double characteristic reference](characteristics.py) transports the piecewise-linear
interpolant of the **rounded initial state**, with pressure reflection and ambient boundary
extension. The two declared pressure projections are (1) the host Float32 primitive pressure,
converted back to its exact Float32 value, and (2) pressure reconstructed from retained conserved
rho/mx/energy in Double using the exact configured Float gamma. Both use Double mx/rho
velocity and the declared ambient characteristic speed. This second EOS projection can contain
a small uniform pressure offset; it is reported rather than silently normalized away.

All serialized Float32 values, including gamma and conserved state, are explicitly rounded
back to Float32 before Double postprocessing, avoiding JSON-decimal reinterpretation. The
transport solves the stated **linear interpolant**, not a nonlinear high-precision Euler run,
and its interpolation/boundary assumptions are explicit. Three CPU controls independently
check affine interpolation, uniform pressure, wall reflection and packet travel.

At 1 Pa, host-projected-initial-state transport changes the sampled first impulse by only
−0.00247% to +0.05106% across all declared receiver/control combinations. For the default
CFL0.225/nx1024 wall case, analytic right-endpoint quadrature changes impulse by −0.000246%,
host-projected transport by −0.00185%, and conserved-Double transport by +0.0681%, while the
measured value is −16.754%. These particular linear reference controls do not account for
the observed discrepancy. This is not a rigorous bound on nonlinear Euler error or an
identification of an individual GPU instruction.

Across the entire matrix, native versus Double streaming accumulation differs by at most
1.104e-6 of the analytic impulse (0.000111%). The much larger weak-wave discrepancy therefore
cannot be repaired by changing only accumulator precision on these same consumed histories.
The measured pressure history and numerical updates still need investigation. A nonlinear
Double Euler comparison, update-level precision analysis and a justified weak-load operating
range remain open in emmettl/bombcad-work#80. This stage supplies controlled evidence toward
that issue; it does not complete it or admit CUDA targets.

## Receipts and reproduction

- [Controller](run.py), [all-outcome audit](audit.py), [reference tests](test_characteristics.py).
- [Results](results.json) retain all raw, source, runtime and postprocessing SHA-256 receipts.
- [Archive manifest](archive.json) covers all 225 raw files / 140,709,516 bytes. All are gzip
  archived and hash-verified on StudioData (10,076,641 compressed bytes). All 153 non-trace
  metadata/log files are also copied under `evidence/` (1,126,528 compressed bytes); all 72
  complete pressure histories remain in the external archive. This is a size-based split,
  not outcome selection; no run or receiver was dropped or replaced.
- Before execution, all 547 producing executable/resource/source files / 34,848,860 bytes
  were frozen under the raw root's `sources/`; the audit verifies those copies.

Raw root: `$BOMBCAD_DATA/experiments/2026-10-22-acoustic-controls`. For an individual fresh matrix:

```sh
~/.local/bin/gpu-slot --mem 2 .build/release/blastbench acoustic-phase --fine --rounding default --cfl 0.225 --out NEW-DIRECTORY
```

Use `unfused` and/or `0.45` only as the other explicitly declared controls. The controller
requires its fixed scratch directory not to exist and retains partial results on failure;
never restart solely because an observation timed out. The CPU audit needs the raw files
(or decompressed full external archive), frozen producing bytes and declared source checkout.
Compatible recorder arithmetic is not emitted-instruction attestation, and observable parity
does not prove every unobserved intermediate bit in an ordinary binary.

Both invalid-CFL [refusals](refusals.json) exit 1 before creating output. The first build failed
because the diagnostic used shader field names instead of the Swift API; it was corrected
before numerical execution, with the failed log retained. The initial integrated check's
Linux lane refused a changing local snapshot while the report was still being edited; it
retained staging and launched no worker. Numerical runs are not repeated for that failure.
Final integrated validation is recorded separately after freezing this report.

Final validation: [plain make check-affected](check-affected.log) passes the covered
selection: 17 selected Mac tests and 62 PC Linux tests across 11 suites, plus script/docs
checks. Format/lint and the [strict build](strict-build.log) pass without warnings; the
three [Double characteristic tests](characteristic-tests.log) also pass. The initial
changing-snapshot [check log](check-v1-changing-snapshot.log) and failed diagnostic
[build log](build-v1.log) are retained separately. No numerical outcome was replaced.
