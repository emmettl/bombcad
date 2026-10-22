# Saved-output dataset assembly — declared before target comparisons

22 October 2026. emmettl/bombcad-work#62 and emmettl/bombcad-work#63.

All three unchanged staged CUDA workers completed with returncode0. The queue
released its lease and printed every result. Local retrieval then failed because
`out/dataset` does not exist: the initial-state diagnostic exports physical buffers
but does not attach the templates normally added by `field-export --cuda-job`.
This is a runner mistake, not a numerical worker failure. Preserve the original
controller failure, stale running receipt, remote log and all physical outputs.
Do not rerun Metal or CUDA to repair it.

Retrieve hash-pinned saved CUDA targets.npy (peak/total impulse),
firstPhaseImpulse.npy, native mask, dt and result.json. Inventory every retained
remote output, including full-state binaries, without changing it. For the same
three original completed dataset-mode pilot jobs, retrieve their raw arrays,
actual dataset and original input templates/receiver columns as controls. Old
balloon-start targets are controls of serialization only, never the new reference.

Apply exactly the existing worker's dataset rule: stack the two saved target
planes and saved first-phase plane as Float32, then zero only positions excluded
by the unchanged template mask. Require whole-array Float32-word equality with
each original worker-written three-channel control dataset. Do not select a
favorable arithmetic model or scalar. The templates' features/masks must equal
the fresh fixed-main Metal features/masks exactly; receiver columns must match
the new physical jobs. Require the new native-valid mask to include every selected
template pixel. Reject unavailable/mismatched controls; no invented masks or
replacement reference. No valid candidate value is changed.

Write separately versioned assembled datasets and recovery receipt, retaining
every control and all three current outcomes. Use actual CUDA result provenance,
with explicit CPU saved-output assembly metadata. Extend the auditor/archive
entry points to accept that recovery receipt and dataset paths; preserve their
original records. Apply the original per-value0.05+0.002*abs(reference) gate and
retain every failing value. No tolerance, label, mask, default, training index or
bulk admission change. Weak-wave work remains paused until the fixed-reference
comparisons are complete.
