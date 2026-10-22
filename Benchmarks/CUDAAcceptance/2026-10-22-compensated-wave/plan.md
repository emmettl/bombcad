# Protected compensated wave experiment — predeclared 2026-10-22

Tracking: emmettl/bombcad-work#81, parent emmettl/bombcad-work#80.

Implement and verify the guarded opt-in protected-kahan-v1 candidate, then freeze all
producing sources, executable/resources, matrix definitions and inputs before execution.
The preceding scalar gate rejects unprotected Kahan and retains a locally safe,
contract-off helper as a bounded candidate, including its large-cancellation failure.

The complete numerical matrix is A1/10/100 Pa × nx512/1024/2048 × CFL0.45/0.225 ×
default/unfused surrounding arithmetic × full/tiled × density-only/energy-only/both ×
plain/pressure-only/pressure+update observations: 648 candidate exports. Add the identical
648-case protected-update-no-carry-v1 control, which clears residuals after every update:
1296 exports total. This separates residual retention from the helper's explicit rounded
flux difference/product and addition. This extension is declared before any wave outcome.
No-carry uses the same helper, component selectors and floor behavior; trace mask bit 4
identifies discard-after-update. Preserve the
existing ordinary baselines separately; intentional candidate changes are not original
method admission. No failing case may be removed or replaced with a passing rerun.

Use the same 16 m domain, initial pulse, receivers, gamma, rigid left wall, copied right
outflow and stopping rule as the acoustic controls. Record physical receiver centres and
actual times. Capture both boundary cells for signed boundary-flux/conservation audits.
For each candidate, require exact plain/pressure/update complete coarse state, residual,
recorder, selected record, initial state, step and clock parity. Full/tiled comparisons
retain skipped opportunities explicitly; do not invent unobserved sleeping-cell fluxes.
Refuse incomplete/overflowed update traces, verify raw state/residual continuity and replay
all enabled compensated operations from actual captured flux, lambda and residual words.
Disabled components keep ordinary updates, not a compensated zero-residual substitute.

Report all pressure histories, peaks, phase closure/open status, impulses and analytic
errors. Align comparisons by physical time, not step number. Compare the independent
Float64 nonlinear retained-initial-state reference at corresponding actual timestep/time
sequences; preserve the preceding ordinary Float32 and Float64 controls. Report raw and
residual-corrected conserved totals and signed boundary balances wherever observations
support them; absolute increment counts are not physical dissipation. Keep floor events,
positivity/stability outcomes and residuals. Report held-buffer memory and diagnostic wall
cost with contention/measurement scope; no quiet throughput or performance win claim.

The candidate is bare, unmasked 1-D ideal gas only, with no charges/pending firings,
reactions, structures, cut cells, refinement or extra source terms. Separate residuals
persist through tiled skips. Floors clear the overridden component residual and count
events; restart/fill disables the experiment. Checkpoints/general geometry/CUDA are not
supported by this experiment. Ordinary source/Cell/uniform ABI and defaults stay intact.

Before publication: format/lint, warning-free strict build, focused GPU parity/replay,
skip/floor/restart/scope/overflow controls, plain make check-affected and required ordinary
bit-identical digests. Run GPU work through shared slots with bounded commands, retain
partial outputs and exact process identities on failure, never relaunch on observation
timeout. Publish receipts/all adverse outcomes and an evidence-backed keep/reject decision.
This implementation gate alone does not close the scientific experiment or change any
phase rule, label, tolerance, mask, training index, host service or dataset admission.
