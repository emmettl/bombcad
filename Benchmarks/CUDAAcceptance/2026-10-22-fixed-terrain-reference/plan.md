# Fixed-terrain reference prerequisite — 22 October 2026

Tracking: emmettl/bombcad-work#39, emmettl/bombcad-work#47,
emmettl/bombcad-work#62, emmettl/bombcad-work#63 and emmettl/bombcad-work#80.
User direction pauses weak-wave precision work and its follow-ons until these
pilots use fresh Metal references containing `aff21dff`.

Rebuild release scenebench from main at/after that fix. Freeze the executable,
resources, selected public source/scripts and original field-plan inputs before
running. Use fresh output directories, never the old reference or dataset index.
Record revision, content hashes, command/environment and initial mapped start.
The old pilot outcomes remain evidence of their old reference, not current gates.

Run once each: `made-perimeter-s1-1` flat control, `made-perimeter-s3-1` shaped-ground
slope and `beirut-p0-1`. Preserve the original 4m plan, charge/layout, default
production arithmetic, all three target channels, features and masks. Capture a
portable initial-state diagnostic while completing ordinary production Metal,
then run CUDA from those exact buffers using unchanged generated source and the
PC shared training lock. Mac GPU work uses shared gpu-slot and no quiet timing
claim. Retain all three outcomes even if an earlier comparison fails; no retries.
No fine-grid resolution sweep or dataset-scale generation before these pilots.

Require exact features/masks and the existing per-value target threshold
`abs(candidate-reference) <= 0.05 + 0.002 * abs(reference)` at every valid point.
Report peak, total impulse and first-phase failures individually, including their
locations, values and gate margins. Compare with the old receipts descriptively;
changed initialization changes the solution and is not a byte-parity requirement
against old balloon outputs. No threshold, mask or target-definition change.

If the fixed pilots pass the unchanged gate, record the outcome on
emmettl/bombcad-work#62 and emmettl/bombcad-work#63 and reopen the existing bulk
CUDA generation path with a gate on every generated case. If failures merely
shrink to the flat case's level, record that fact but retain any individual gate
failure; it does not authorize admitting a rejected target. If they persist,
continue those issues and emmettl/bombcad-work#80 against the corrected reference.
No relabeling, tolerance relaxation or inferred physical validation.

## Queue amendment before any CUDA numerical solve

All three initial CUDA launches refused the existing shared GPU lock before
calling the worker's numerical routine or creating output. Preserve those
failures and the already uploaded immutable jobs. The owning PC job is
`field-unet-l3-strict-125` (emmettl/bombcad-work#69); do not interrupt it.
A separately frozen queued wrapper waits up to80 minutes using the existing lock
helper, then holds that same lock while invoking the three unchanged staged
workers once each. Inner workers omit a second lock acquisition because their
parent owns the shared lease throughout. Verify worker/source hashes and refuse
any existing numerical output before waiting. Keep all numerical failures;
no retry or replacement solve. Retrieve into a separate `queued-cuda` directory
and apply the original gate to every outcome. Queue time is not a benchmark.


## Second lease window — declared after the first queue terminated

The first queue reached its 80-minute budget without acquiring a lease. Original
exec62933 is terminal, exit1. Logs show no worker start, and a fresh read-only PC
check confirms all three staged output directories are absent. Preserve the
entire first attempt at `queued-cuda-attempt-1`, including its unchanged run.json,
logs, copied helpers/configuration and a separate terminal receipt.

After that inspection, authorize one further 80-minute lease window using the
same published queue helper and unchanged staged physical inputs/workers. This
is a new scheduling window, not a numerical retry: none of the three solves has
run. Recheck source/worker hashes and refuse preexisting numerical output before
waiting. The new window writes a fresh `queued-cuda`; do not overwrite old data.
Retain every failed scheduling and numerical outcome. Training is not interrupted,
the lock is not bypassed, and the original per-value gate remains unchanged.
