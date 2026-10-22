# Saved-history peak decomposition — predeclared 22 October 2026

Tracking: emmettl/bombcad-work#82; parent emmettl/bombcad-work#80.

Analyze every one of the preceding 432 groups /864 receiver histories. Use the
saved native pressure, Double stored-state projection, represented-pair projection
and independent Float64 histories; verify each consumed input against the published
archive inventory before and after analysis. No GPU case, oracle or producer rerun.
Freeze this plan and the analysis script before execution; record Python/NumPy-core
byte identities and the parent source/analysis receipts. This is not a hermetic
operating-system/dependency environment.

Use the native integer-tick axis for native/stored/pair histories and interpolate
independent Float64 pressure from its retained dt-sum axis only within coverage.
Retain both axes and their lag. Preserve original global peak targets and existing
phase closure; this descriptive decomposition creates no threshold or acceptance
policy. Record all equal-maximum sample indices/times, not a selected passing peak.
Report the Float64 raw peak and its interpolated sampled peak separately.

For every covered sample, decompose native minus aligned reference into native
minus Double stored-state projection, stored minus represented-pair projection,
and represented-pair minus reference. Report signed values, extrema and absolute
bounds. At every native global maximum also retain the reference-at-that-time
minus reference global maximum term, separating timing/sampling from the pressure
and evolved-state discrepancy. Report ranges across all tied native maxima and
the first maximum's full tuple for reproducibility. Retain first-phase closure
indices and timing rather than changing the global peak definition.

A native/Double difference measures pressure evaluation on the same stored state;
the pair projection is a counterfactual not consumed by the GPU. Pair/reference
difference also contains operator/discretization differences between independent
models; it cannot identify a primitive, limiter or flux cause by itself. Report
all amplitudes, policies, CFLs, selectors and tilings, including regressions and
failures. If these inputs cannot isolate a cause, record that limit and predeclare
bounded actual-stencil instrumentation as a distinct next stage. No solver,
default, phase, label, tolerance, mask, training-index, service or admission change.
