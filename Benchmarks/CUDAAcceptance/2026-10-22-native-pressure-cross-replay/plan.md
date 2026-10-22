# Native pressure cross-replay — 22 October 2026

Tracking: emmettl/bombcad-work#84, bounded work under emmettl/bombcad-work#62.

Reuse all captured ground-receiver histories from the accepted paired-input study:
flat62902, slope134058/250097 and Beirut187747, with initialization retained.
No new PDE solve. Freeze harnesses, existing compiler/runtime pins, consumed inputs,
source libraries and exact launch/ABI choices before numerical replay.

First run mathematical ideal-gas controls through each native reader. Reconstruct the
complete frozen Metal producer compilation unit using its original Swift pressure-capture
transform and frozen ContactSearch/source resources. Use the existing
sampleFirstPhasePressure entry point, nil compile options and empty function constants.
Keep original plan/grid shape, receiver indices/descriptors and pressure-read gas/control
parameters. Other columns are disabled; unrelated fluid cells and unused uniform/control
fields may be zero. Own-input word parity must validate this sparse replay context.
Do not append a new EOS kernel or rewrite the pressure expression.

For CUDA, reuse the exact frozen augmented source (including the previous raw-input
diagnostic append), original cudaTraceColumns entry point, scalar ABI and NVRTC flags.
Use normal PC/shared GPU locks and capture compiler/runtime provenance. Preserve the
distinction between Metal actual consumed pressure and CUDA read-only recomputation.

Gate every selected native pressure Float32 word on all original samples from each
reader's own backend. A numerical parity failure is a recorded stop: retain it, do not
choose a looser comparison, another helper or a different subset to obtain a desired sign.
Compiler/preflight failures are retained separately from numerical attempts.

Only after both readers pass own-input gates, run cross-input histories and retain the
full2x2 reader/input matrix. Conditional phase replay uses the input backend's original
seed, timestep history and previously verified accumulator policy. Keep startup samples,
all models and unfavorable outcomes. Compare physical times with explicit displacement;
equal indices are not assumed to mean equal time.

This isolates reader versus captured-state sensitivity for these represented histories;
it does not identify an earlier flow operator or establish continuum truth.
No default, tolerance, mask, phase rule, training index or admission change.
Bulk remains held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.
Artifacts/raw data: `$BOMBCAD_DATA/experiments/2026-10-22-native-pressure-cross-replay`.
