# Metal raw pressure inputs — implementation stage, 22 October 2026

Tracking: emmettl/bombcad-work#83; parent emmettl/bombcad-work#62.

The opt-in `field-export --trace-pressure-inputs` diagnostic is implemented. It requires the
existing pressure trace and captures two raw Cells, column descriptors and Float32 interpolation
weights through a separately compiled read-only Metal pipeline. Initialization, active-step
times and the native sample budget remain aligned; overflow refuses complete readback.
Independent host reads of the full state buffers supply initial/final endpoint checks.
Producer shader source and pipeline construction are unchanged; encoder bindings are restored
after observer dispatch. Defaults, phase rules and admission are unchanged.

The broad initial implementation passed plain `make check-affected`, including the selected
Mac suites and 128 PC tests in 36 suites. Final endpoint API/binding-restoration revisions
then passed a warning-free strict build, formatting/lint and all eight first-phase tests
under the shared GPU scheduler. Those tests cover layered tail grids, mapped/balloon starts,
native pressure bit parity, raw endpoint words and overflow refusal. The controller's read-only
preflight passed after fixing its frozen-helper import path. See
[implementation checks](implementation-checks.json) for exact scopes and source pins.

The [declared protocol](plan.md) and [controller](run.py) are ready for corrected flat, slope
and Beirut captures. **Those captures and wider-pressure comparisons are pending.**
Mechanism tests do not establish full-case observer parity, continuum accuracy or a CUDA pass.
Bulk generation stays held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.
