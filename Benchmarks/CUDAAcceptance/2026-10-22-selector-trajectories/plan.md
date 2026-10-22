# Selector-only trajectory validation — 22 October 2026

Tracking: emmettl/bombcad-work#89 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80. Raw root:
`$BOMBCAD_DATA/experiments/2026-10-22-selector-trajectories`.

The opt-in diagnostic compiles the original untransformed full producer with safe/precise
options, but dispatches only its original `prepareStep`. Every other pipeline keeps its
original source/options. Default storage is nil; disabling and restart restore the original
path. Refuse unsupported physics and kernel-build overrides. No replacement arithmetic
helper, reference schedule, shader expression edit or global safe-mode substitution.

## Predeclared controls and order

Publish the implementation only after focused lifecycle/guard/isolation controls, formatting,
lint, warning-free strict build, plain affected checks and unchanged default digests.
Development failures are retained separately; a physical baseline/parity failure is a stop,
not permission to retry or change the observer to obtain parity.

Before interpreting a trajectory, replay all six immutable emmettl/bombcad-work#88 scalar
banks through the actual solver's original and diagnostic prepare pipelines. Require every
24-word output record exact against that archive: 375,672 words per mode. Freeze source,
SDK15 executable context, resource bytes, native constants/bindings and runtime/toolchain
provenance. Do not replace absent context or infer a shared physical state from a step index.

Independent physical controls use the existing `SolverVerificationTests` setups/formulas:

- Sod: 400 and 800 cells, HLL and HLLC, original and selector-only modes: eight runs. Keep
  diaphragm, initial states, floors, gamma, boundaries and final time0.2. Retain the original
  density L1<0.004 bound at400 cells; report it at800 too. Save complete initial/final states,
  exact-solution L1, mass/energy totals, steps, reached time and stability.
- Sedov–Taylor: 80 and120 cells per octant side, original and selector-only modes: four runs.
  Keep total full-sphere energy1, source radius3.5dx, ambient/floors, symmetry/outflow faces,
  target radius0.6 and original similarity time. Preserve axis/diagonal radius error<4%,
  peak density between2.5 and6.5, stability. Save initial/final states, radial metrics,
  mass/energy totals and clocks. The120 grid has1.728M cells; bounded shared-memory state
  storage is feasible on the Studio. Report every refinement change, including nonmonotonic
  ones; do not tune source radius or tolerance to pass.

The analytical controls must pass at original bounds; report refined outcomes in full.
Retain original stable, clipped/inactive, one-step budget and nonphysical-speed behavior.
These controls are independent evidence, not proof of universal physical accuracy.

Only after scalar gates and independent controls pass:

1. Run one disabled-feature captured baseline per corrected flat/slope/Beirut pilot. Require
   every original numeric array, initial/final coarse-state hash, native pressure/raw-cell
   history and clock-input stream exact against immutable emmettl/bombcad-work#87. Preserve
   original host/GPU time axes and inactive records; no throughput inference.
2. Run one selector-only plain case and one selector-only captured case per pilot. Require
   every common original numeric array and full initial/final coarse-state hash identical
   between plain/captured before interpreting the new pressure/raw-cell/clock traces. Captures
   use the previously qualified observers, with no additional producer rewrite.
3. Evaluate all three target channels at every valid cell against the EXISTING corrected
   production Metal reference, unchanged `0.05 + 0.002 * abs(reference)` and exact features/masks.
   Separately compare candidate Metal with native CUDA; do not replace the reference to make
   agreement pass. Preserve all values/failures and native pressure/phase/time histories.

Each physical mode/case runs once. Normal shared GPU leases; no interruption of other work.
Bound any stage including lease wait to90min; retain owned PID/process outcomes and exact
timeout cleanup. No new PC arithmetic job is needed; original CUDA outputs remain pinned.

## Boundaries

If independent controls or a baseline/parity gate fail, retain the stop before candidate
interpretation. A changed Metal trajectory that agrees with CUDA but fails the existing
reference is still incompatible. A production/reference policy needs separate justification
and the user's decision. No default, tolerance, mask, phase definition, reference overwrite,
dataset index or training-admission change. Bulk remains held under
emmettl/bombcad-work#39 and emmettl/bombcad-work#47.
