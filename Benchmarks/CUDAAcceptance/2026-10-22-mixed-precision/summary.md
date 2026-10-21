# Mixed state/evaluation precision controls — 2026-10-22

Tracking: emmettl/bombcad-work#80, supporting emmettl/bombcad-work#62.

## Result

All 72 predeclared CPU numerical runs complete with finite positive states and zero
reconstruction fallback. Both matching-type controls exactly reproduce all 36 preceding
retained-state CPU runs: native pressure histories, final states, clocks, conserved totals,
update diagnostics and boundary balances. That establishes the refactor control before
interpreting the new hybrid outcomes.

Preserving Float64 state while evaluating in Float32 removes most of the model's severe
weak-wave impulse loss; Float64 evaluation followed by Float32 storage does not. At
1 Pa/nx2048/CFL0.225, common-Double-readout wall impulse error is −21.6538% in S32/E32,
+0.11443% in S64/E64 and −0.19813% in S64/E32. S32/E64 has **no positive native wall
pressure signal** and no closing phase. Its tiny positive common-Double background offset
is not a recovered wave.

Two S32/E64 wall receiver histories (1 Pa, nx1024/2048, CFL0.225) have no closing phase;
the other 142 histories close under both readouts. These are retained adverse outcomes,
not successful phase measurements. No numerical setting, label or admission rule changes.

## Fixed experiment and precision semantics

[The predeclared plan](plan.md) keeps all 18 initial states/timestep sequences from the
[preceding nonlinear study](../2026-10-22-euler-precision/summary.md): A=1/10/100 Pa,
nx512/1024/2048, CFL0.45/0.225. Four modes factor stored conserved-state precision S and
primitive/reconstruction/HLLC/increment evaluation precision E:

- S32/E32: original Float32 control.
- S64/E64: original retained-state Float64 control.
- S64/E32: cast a copy of the state to Float32 for evaluation; promote the evaluated
  increments to Float64 and subtract from the preserved Float64 state.
- S32/E64: evaluate in Float64, subtract in Float64 and round every updated state to Float32.

Subtraction uses the wider of S/E. This defines a **state/update versus evaluation**
experiment, not an independent factorial of every possible subtraction implementation.
In the E64 pair specifically, evaluation and subtraction precision are fixed; the final
stored-state rounding is the changed factor. Density, momentum and energy storage change
together, so this does not assign the result to energy alone.

All initial retained Float32 numbers and configured Float gamma are identical mathematical
inputs after casting, with prescribed recorded dt, physical receiver centres, reflected
left boundary and copied right boundary unchanged. There is no analytic-initial substitute
in this matrix. The [standalone NumPy model](../../../Scripts/reference/planar_euler.py)
is an independent nonlinear MUSCL-Hancock/HLLC implementation, not a GPU bit/instruction
replay. Its matching-type operation order is preserved by the `advance` wrapper;
`advance_mixed(..., evaluation_dtype=...)` exposes the explicit diagnostic control.

Every run records two pressure histories: native stored-type evaluation, preserving the
preceding baseline, and a common Double evaluation of the actual stored conserved state.
The common readout is used across the four modes below to avoid confusing observation
precision with propagation. Both native/common phase metrics and pressure differences
remain in [results.json](results.json). The common readout is a numerical EOS projection,
not experimental truth or the pressure actually consumed by a Metal recorder.

## All wall-cell outcomes

Signed impulse error is (common-Double offline half-final-peak result / analytic linear
impulse − 1). Open histories do not have a completed first phase and are marked explicitly.
The direct receiver, native readout, peaks, closures, clocks and every raw result are retained.

| A (Pa) | nx | CFL | S32/E32 | S64/E64 | S64/E32 | S32/E64 |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 512 | 0.45 | -0.2409% | +0.1448% | -0.5574% | +14.3677% |
| 1 | 1024 | 0.45 | -0.9315% | +0.0750% | +0.6352% | +21.8207% |
| 1 | 2048 | 0.45 | -0.5976% | +0.1146% | -0.5194% | -77.3951% |
| 1 | 512 | 0.225 | -5.8327% | +0.1076% | +1.3435% | -68.3503% |
| 1 | 1024 | 0.225 | -15.5059% | +0.0695% | -1.4362% | no wave / open |
| 1 | 2048 | 0.225 | -21.6538% | +0.1144% | -0.1981% | no wave / open |
| 10 | 512 | 0.45 | +0.0318% | -0.0327% | -0.0191% | +1.6003% |
| 10 | 1024 | 0.45 | -0.0238% | +0.0114% | +0.0379% | +2.9536% |
| 10 | 2048 | 0.45 | +0.0047% | +0.0054% | +0.0114% | +0.3047% |
| 10 | 512 | 0.225 | -0.1802% | -0.0702% | -0.0986% | -1.5381% |
| 10 | 1024 | 0.225 | -1.2357% | +0.0040% | -0.0113% | -6.5914% |
| 10 | 2048 | 0.225 | -4.2618% | +0.0041% | +0.0892% | -12.5411% |
| 100 | 512 | 0.45 | +0.0064% | +0.0006% | +0.0030% | +0.1375% |
| 100 | 1024 | 0.45 | +0.0376% | +0.0387% | +0.0333% | +0.3682% |
| 100 | 2048 | 0.45 | +0.0442% | +0.0396% | +0.0384% | +0.7354% |
| 100 | 512 | 0.225 | -0.0343% | -0.0320% | -0.0313% | -0.0606% |
| 100 | 1024 | 0.225 | +0.0443% | +0.0320% | +0.0303% | -0.1201% |
| 100 | 2048 | 0.225 | +0.0779% | +0.0388% | +0.0377% | -0.5302% |

At 1 Pa across both receivers and six cases, maximum absolute **closed-history** common
impulse error is 21.6539% for S32/E32, 0.1600% for S64/E64, 1.4363% for S64/E32 and
90.4354% for S32/E64, with the latter additionally having the two open/no-wave wall histories.
This closed-history statistic is accompanied by the explicit failure count; it is not a
selected passing admission subset. S64/E32 still has a finest wall peak error of about
−5.08% at the highlighted case, versus about −0.409% for S64/E64, so improved impulse
alone does not establish a validated operating range.

For each open S32/E64 wall history, native peak/impulse are exactly zero. Common Double
peak is about 0.00021056 Pa with a window integral about 8.66e-6 Pa·s and no negative
closing sample. This is the retained-state EOS background offset integrated over the
window, not a completed reflected pulse. The model/data are not modified to create closure. No claim is made about an indefinitely
extended run or permanent pulse destruction.

## Update diagnostics and limitations

At the highlighted 1 Pa/nx2048/CFL0.225 point, summed absolute computed energy increments
absorbed by stored rounding are approximately 34,193.79 J/m³ in S32/E32, 8.09e-7 in S64/E64,
4.54e-10 in S64/E32 and 20,339.67 in S32/E64. The corresponding ratios to summed absolute
computed energy increments are about 65.2%, 4.64e-9%, 1.30e-12% and 94.3%.
These span cells/timesteps and include tiny flux noise; they are diagnostics, **not physical
dissipation, net conserved-energy loss or a causal impulse-error budget**. Counts, magnitudes
and boundary-balanced conserved residuals are all retained, rather than relying on a count
or a small ambient-relative total-energy error alone.

The E64 storage pair demonstrates that stored-state rounding can prevent the expected positive wall pulse from appearing
within the declared window in this numerical model even when evaluation/subtraction are high precision. The S64
pair measures remaining evaluation sensitivity. It does not prove a particular production
GPU update caused the Metal/CUDA differences. Source algebra, operation ordering, precision
of all three stored components and the model's ideal-gas/1-D regime differ from broader
product use. No Float64 GPU implementation, representation or default is adopted.

Next in emmettl/bombcad-work#80: isolate component-wise state precision, then observe actual
GPU pre/post state and update increments under plain/observer parity. A compensated or
reference-centred representation is only a candidate to test after those controls, not a
proposed accepted target. Strong-blast near-zero closure semantics and hot-air/terrain/CUDA
admission remain separate in emmettl/bombcad-work#62/emmettl/bombcad-work#63 and
emmettl/bombcad-work#59/emmettl/bombcad-work#47.

## Receipts and reproduction

- [Controller](run.py), [worker](worker.py), [read-only audit](audit.py), [audit log](audit.log).
- [All outcome/source/runtime/input receipts](results.json), including 36 exact baseline checks.
- [Archive manifest](archive.json): all 260 raw files / 4,947,436 bytes published under
  `evidence/` as 4,286,040 gzip bytes, including every native/common history, final state,
  input, result, log and seven frozen pre-execution sources. No case is replaced or discarded.
- [Runtime identity reference](runtime-reference.json): producing Python/NumPy-core hashes
  match the preceding preserved runtime byte copies; not a self-contained environment.
- [Mac reference tests](tests-mac.log), [PC receipt](linux-tests.json), [isolated PC test driver](linux_check.py).

The four physical/contact/wall/Sod/dtype/invalid-state reference checks pass on Mac
NumPy2.3.5 and PC WSL NumPy2.5.2, now including stationary-state preservation under all four
type combinations. PC checks use a new isolated source directory and touch no shared worker
source or GPU job. Scientific runs are Mac CPU only; cross-host scientific arrays are not
claimed identical. All 72 worker process groups and the controller are terminal, with no
GPU reservation or timing/speedup claim.

```sh
python3 Scripts/reference/test-planar-euler.py
python3 Benchmarks/CUDAAcceptance/2026-10-22-mixed-precision/run.py
python3 Benchmarks/CUDAAcceptance/2026-10-22-mixed-precision/audit.py
```

Use NumPy and the preceding retained histories. Raw root is
`$BOMBCAD_DATA/experiments/2026-10-22-mixed-precision`; the controller requires a nonexistent
root, freezes sources and inputs and uses at most two CPU workers. The native matching-type
baselines are checked against the preceding hash-pinned final states and full pressure histories.
The current nonlinear reference remains approximate; no exact PDE bound is inferred.
There is no solver/shader/default/label/tolerance/mask/training-index or admission change.

Final validation: format/lint and the [strict build](strict-build.log) pass without
warnings. [Plain make check-affected](check-affected.log) passes the covered selection:
17 selected Mac tests and 62 PC Linux tests/11 suites, plus reference/script/docs checks.
The four physical/reference test methods pass on both hosts, including all mixed-type
rest/dtype controls. No numerical run was discarded or repeated.
