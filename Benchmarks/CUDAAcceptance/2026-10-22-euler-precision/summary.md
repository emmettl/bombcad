# Nonlinear CPU Euler precision comparison — 2026-10-22

Tracking: emmettl/bombcad-work#80, supporting emmettl/bombcad-work#62.

## Result

All 54 predeclared CPU runs complete, with 108 receiver histories closing and no
reconstruction fallback or state floor activated. The standalone nonlinear Euler scheme
shows a large precision effect at fixed retained initial state and timestep sequence.
At 1 Pa/nx2048/CFL0.225, wall impulse error against linear acoustics is −21.8006% in
NumPy Float32, +0.11443% in Float64 from the identical rounded initial state, and
−0.0000760% in Float64 from analytic initial conditions. The corresponding Metal error
is −15.5910%; **the CPU Float32 model is not a GPU replay**.

This supplies the previously missing nonlinear higher-precision comparison. It establishes
that finite precision can cause a similar weak-amplitude loss in this independently
implemented scheme; it does not identify a specific production GPU instruction or establish
a validated weak-load operating range. No solver/shader/default or admission change.

## Fixed experiment

[The plan](plan.md) fixes all 18 full-grid/default-arithmetic cases from the
[preceding control matrix](../2026-10-22-acoustic-controls/summary.md): A=1/10/100 Pa,
nx=512/1024/2048, CFL0.45/0.225. Each has three CPU modes:

- Float32 from the retained conserved initial state and exact configured Float gamma.
- Float64 from that identical rounded state/gamma, with the same recorded dt sequence.
- Float64 from the analytic initial state with gamma=1.4, using that same dt sequence.

All serialized Float32 inputs are rounded back to Float32 before storage. Timesteps are
prescribed from the Metal histories, not recomputed from each model's evolving state;
this holds the discrete clock inputs fixed. The CPU reference uses the actual cumulative
dt for its analytic comparison. Its clock differs from the recorded Metal clock by at
most 1.864 ns. Receiver centres, rigid x-min reflection, copied x-max outflow and the
16 m, compact bipolar pulse are unchanged. Every outcome is retained without replacement.

[The independent Python model](../../../Scripts/reference/planar_euler.py) uses conservative
1-D ideal-gas MUSCL-Hancock, theta=1.5 primitive limiting, Roe/Einfeldt speed estimates
and HLLC fluxes. Its algebra is informed by the checked Metal core, but its vectorized
operation ordering, shared face evaluation and separate NumPy operations differ. It has
no tiling, thermally perfect gas, afterburning, geometry or GPU instruction model. It
refuses non-positive states instead of silently flooring them; its reconstruction fallback
is recorded and never activates in this matrix.

Four [reference tests](../../../Scripts/reference/test-planar-euler.py) verify physical/contact
and rigid-wall fluxes, stationary-state/dtype preservation, Sod shock-tube conservation and
refinement against an independent exact Riemann construction, and invalid-state refusal.
They pass on Mac Python3.12.14/NumPy2.3.5 and [PC WSL Python3.12.3/NumPy2.5.2](linux-tests.json).
PC tests use a unique immutable source directory; no shared worker source, GPU job,
software or service settings change. The 54 scientific runs are Mac CPU runs, not a
cross-host scientific-output comparison. Optional CI reference checks report SKIP if NumPy
is absent; the scientific run used the pinned available runtime and all four tests passed.

## Every wall-cell impulse result

Signed error is (offline half-final-peak impulse / analytic linear impulse − 1). The Metal
column is its existing measured streaming result; the preceding audit established identical
Double offline/streaming phase selection on those consumed histories. CPU histories use
the same offline analysis, not an assertion that a hypothetical streaming recorder would
make identical decisions on every new CPU history. Direct-receiver, peak, pressure-history,
clock, closure and balance metrics are all retained in [results.json](results.json).

| A (Pa) | nx | CFL | Metal | CPU Float32 retained | CPU Float64 retained | CPU Float64 analytic |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 512 | 0.45 | -0.961986% | -0.366239% | +0.144762% | -0.036302% |
| 1 | 1024 | 0.45 | -0.437163% | -1.058518% | +0.075004% | -0.000593% |
| 1 | 2048 | 0.45 | -3.037144% | -0.748294% | +0.114642% | +0.000736% |
| 1 | 512 | 0.225 | +2.236824% | -5.956616% | +0.107570% | -0.073143% |
| 1 | 1024 | 0.225 | -16.754014% | -15.647278% | +0.069529% | -0.007416% |
| 1 | 2048 | 0.225 | -15.590969% | -21.800621% | +0.114429% | -0.000076% |
| 10 | 512 | 0.45 | -0.107942% | +0.020687% | -0.032659% | -0.032002% |
| 10 | 1024 | 0.45 | +0.113885% | -0.037988% | +0.011444% | +0.003381% |
| 10 | 2048 | 0.45 | -0.046725% | -0.008114% | +0.005367% | +0.004614% |
| 10 | 512 | 0.225 | -0.022514% | -0.190862% | -0.070243% | -0.069124% |
| 10 | 1024 | 0.225 | -0.569708% | -1.250171% | +0.004031% | -0.004045% |
| 10 | 2048 | 0.225 | -2.112695% | -4.274163% | +0.004136% | +0.003313% |
| 100 | 512 | 0.45 | -0.011174% | +0.005051% | +0.000614% | +0.000230% |
| 100 | 1024 | 0.45 | +0.036336% | +0.036349% | +0.038663% | +0.038608% |
| 100 | 2048 | 0.45 | +0.028933% | +0.042807% | +0.039555% | +0.039235% |
| 100 | 512 | 0.225 | -0.038711% | -0.035493% | -0.031980% | -0.032396% |
| 100 | 1024 | 0.225 | +0.034233% | +0.042914% | +0.032012% | +0.031961% |
| 100 | 2048 | 0.225 | +0.053984% | +0.076602% | +0.038833% | +0.038503% |

For the exact-analytic Float64 mode at 1 Pa, maximum absolute impulse error over both
receivers and all six cases is about 0.0732%; for retained-state Float64 it is about
0.1600%, versus 21.8007% for retained-state Float32. The higher-precision analytic mode's
finest wall peak remains about 0.44% low, so this is not an exact PDE solution or a proof
of asymptotic convergence. Finite-amplitude nonlinear effects and residual discretization
remain in the numerical reference. Retained-state Float64 also retains the initial energy
and gamma projection offset; it is not silently renormalized to the analytic ambient state.

## Absorbed updates and conserved balance

The model counts a nonzero computed conserved increment when subtracting it leaves that
stored component unchanged. These are **model-operation** diagnostics. Float64 also has
many such tiny increments; count alone is not an accuracy measure. Absolute increment
magnitudes, all-component counts, totals and boundary fluxes are retained.

At the 1 Pa/nx2048/CFL0.225 retained-state point, Float32 absorbs 11,963,328 nonzero energy
updates, summing 34,193.79 J/m³ in absolute cell/step increment magnitudes. Float64 absorbs
112,895, summing about 8.09e-7 J/m³. These sums span different cells and timesteps; multiplied
by dx they are accumulated absolute diagnostics per unit transverse area, **not physical
energy dissipation or a causal budget for the impulse error**. Cancellation and the flow's
changed trajectory preclude that interpretation.

Over the full matrix, maximum absolute boundary-balanced conserved residuals (mass,
x-momentum, energy per unit area) are approximately (3.18e-5, 2.09e-7, 4.219) in Float32,
(2.90e-13, 2.26e-16, 9.45e-8) in retained Float64 and (5.47e-13, 4.03e-16, 9.53e-8) in
analytic Float64. The large ambient energy means a small *relative total-energy* residual
alone would be misleading for a 1 Pa signal. These diagnostics strengthen the precision
hypothesis within this model; a GPU-specific cause still requires actual update-level
measurements or carefully controlled counterfactuals with parity checks.

## Reproduction and receipts

- [Controller](run.py), [worker](worker.py), [audit](audit.py), [audit log](audit.log).
- [All source/input/runtime/outcome receipts and metrics](results.json).
- [Archive manifest](archive.json): all 206 raw files / 3,060,031 bytes are published under
  `evidence/` as 2,920,388 gzip bytes. This includes all inputs, final states, pressure
  histories, run results, logs and the seven pre-execution source snapshots. Every archive
  is rehashed after decompression.
- [Matching runtime byte copies](runtime-pins.json) are retained on StudioData. They preserve
  the producing Python executable and NumPy-core pins, not a self-contained dependency environment.
- [Mac reference-test log](tests-mac.log), [isolated PC test receipt](linux-tests.json).

Raw root: `$BOMBCAD_DATA/experiments/2026-10-22-euler-precision`. The controller requires
NumPy, the preceding hash-pinned histories and a nonexistent fixed output root. It stages
immutable sources/inputs, starts at most two CPU workers and records every process group
to terminal state. There is no GPU reservation or quiet timing/speedup claim.

```sh
python3 Scripts/reference/test-planar-euler.py
python3 Benchmarks/CUDAAcceptance/2026-10-22-euler-precision/run.py
python3 Benchmarks/CUDAAcceptance/2026-10-22-euler-precision/audit.py
```

Use an environment with NumPy; exact producing versions and binary pins are in the receipts.
The numerical controller uses immutable snapshots while its worker processes run, so later
report edits do not alter producing sources. No numerical case failed or was discarded.

emmettl/bombcad-work#80 remains open for a controlled separation of update stages, actual GPU
parity/instruction evidence and a justified operating range. Precision in the stored state,
primitive reconstruction and flux evaluation all change together between these model modes;
this experiment cannot assign the improvement to only one of them. It also does not settle
strong-blast near-zero closure semantics, recommended hot-air/terrain or CUDA admission.
emmettl/bombcad-work#62/emmettl/bombcad-work#63 and emmettl/bombcad-work#59/emmettl/bombcad-work#47
remain separately gated. No label, tolerance, mask or training-index change.

Final validation: `make format`, strict lint and the [strict build](strict-build.log)
pass without warnings. [Plain make check-affected](check-affected.log) passes its covered
selection: 17 selected Mac tests and 62 PC Linux tests/11 suites, plus scripts/docs.
The new optional NumPy reference test is registered in `ci-test`; the explicit pinned-runtime
Mac and PC runs above each pass all four reference tests. All owned CPU workers are terminal.
