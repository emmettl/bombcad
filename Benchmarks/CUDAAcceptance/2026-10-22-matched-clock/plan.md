# Captured Metal timestep control — 22 October 2026

Tracking: emmettl/bombcad-work#85, bounded work under emmettl/bombcad-work#62;
related emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

Native reader swapping preserved every negative-pressure decision on the selected histories.
Test the clock-selection contribution using the original corrected flat, slope and Beirut
physical jobs and a frozen artifact-only CUDA worker. No new GPU kernel, pressure expression
or product option. Retain all attempts, source/runtime pins and complete numerical inventories.

## Preflight and controls

Use original archived CUDA worker/source and original numerical input jobs. Extract the
captured Metal positive Float32 dt values; initialization and inactive zero-dt samples consume
no schedule entry. Require full provenance, finite positive values, expected active counts
and independently reproduced batch/clipping logic. Validate the CPU model against original
CUDA histories and analytic clipping/refusal controls, then preflight all Metal schedules.

Audit the existing forcedStep branch. Only the prepare-uniform copy receives forcedStep;
all sweep uniforms and CUDA source/flags stay unchanged. The maximum-wave-speed accumulator
is still cleared and the nonphysical-speed guard remains. forcedStep suppresses the
maxOverpressure diagnostic update/reset of the second speed slot; audit that neither value
is consumed by evolution or worker termination. Preserve the original batch/stopping/clipping
and cooling paths; do not change the final dt or disable a stop to force agreement.

Before a controlled solve, run the disabled-feature variant on all three cases once, and
require every original numeric output, dt and diagnostic trace byte to match the immutable
CUDA baseline. New clock-ledger metadata may be additional; no native numeric output may change.

## Clock coordinates

The captured initial physical time is the same input epoch. Native Metal rounds that epoch
to the nearest tick of2^-40 s before its first active step, then publishes absolute device
ticks. CUDA's original raw trace adds the unrounded epoch to elapsed dt. Keep that raw trace
unchanged. Predeclare the source-derived Metal tick origin (positive nearest, ties away)
from the same initial epoch; do not fit an offset to observed differences.

For every controlled active step require:
1. Actual dt Float32 words exactly equal the Metal schedule.
2. Actual CUDA device relative clock ticks exactly equal the integer dt-prefix ticks.
3. Those actual device ticks plus the source-defined Metal origin exactly reproduce every
   captured Metal active-step tick/time. Report the original raw-axis epoch offset separately.

Initialization remains present in traces. CUDA inactive zero-dt rows remain present, and
must not consume or advance the external schedule.

## Numerical commands and outcome gates

Declare three disabled-feature baselines, followed only after all pass by one forced-history
flat, slope and Beirut solve each. Use the PC's normal shared lock, no interruption or bypass,
and no automatic numerical retry. Retain complete fields remotely with inventories, plus
local histories and comparison evidence. A clock-word, device-tick or coordinate mismatch is
a recorded stop for clock attribution, even if target errors improve.

Compare all valid target values and exact features/masks against the fixed Metal reference,
using unchanged0.05+0.002*abs(reference), all three target channels and existing masks.
Controlled results do not reopen default generation or establish continuum/instruction truth.
No default, tolerance, mask, phase semantics, training-index or admission change.
Bulk stays held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.
Scratch: `$BOMBCAD_DATA/experiments/2026-10-22-matched-clock`.
