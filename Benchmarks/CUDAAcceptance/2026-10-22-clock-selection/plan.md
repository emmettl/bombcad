# Native initial clock replay — 22 October 2026

Tracking: emmettl/bombcad-work#86 under emmettl/bombcad-work#62.

First audit all frozen native and matched histories, startup CFL words and source expressions.
Then replay initial measurement and selection on all three original complete coarse Cell states
and masks, whose bytes already match between backends. No PDE advancement or new GPU kernel.
Reuse the archived full Metal producer source, nil compiler options, and original native
measureWaveSpeed/prepareStep functions; reuse the full original CUDA diagnostic compilation
unit, cudaMeasure/cudaPrepare entry points and original precise/unfused flags.

Require each backend's first dt word to reproduce its immutable native history before any
cross-selection. This is an end-to-end first-dt gate: the original run did not capture its
initial maximum-speed word, so do not claim full consumed-control parity. Uniform fields
consumed by measurement/selection match physical jobs. Unused tile/gauge/refinement context
is disabled; no tiles or gauges are advanced. Native initial Metal absolute clock origin
and CUDA relative origin are retained. Controls retain native clipping and safety semantics.

After both three-case first-dt gates pass, feed both actual measured maxima to both original
selectors on identical relevant uniform/control inputs. Preserve all outputs and any refusal;
no numerical retries or changed helper to obtain agreement. Only claim bounds on these
initial inputs. A maximum-word difference does not identify its contributing Cell, expression
or instruction; no exhaustive extrema/tie capture is claimed. Native later-step inputs are
not present in the histories and may require a separate parity-gated capture.

Use ordinary Mac gpu-slot and PC shared leases. All commands are bounded below 90 minutes,
including PC lock wait. Archive source/runtime pins, raw measured speeds, native controls,
full initial-state/mask hashes and all outcomes. Do not change defaults, tolerances, masks,
phase rules or admission. Bulk remains held under emmettl/bombcad-work#39 and
emmettl/bombcad-work#47. Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-clock-selection`.
