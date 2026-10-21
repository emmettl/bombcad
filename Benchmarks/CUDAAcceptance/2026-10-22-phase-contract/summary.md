# Phase eligibility contract audit — 2026-10-22

Tracking: emmettl/bombcad-work#62. CPU-only; no GPU reservation or new simulation.

## Result

The existing single-phase streaming recorder is an approximation to the offline façade
rule. Eight predeclared scalar histories isolate that distinction from pressure rounding.
Seven agree. With positive samples 1, 1.6 and 3 Pa separated by negative samples, and
1 s sample widths, the offline rule returns 2.6 Pa·s while streaming returns 5.6 Pa·s.
The discrepancy persists in separate and fused Float32 analytical models.

The offline rule qualifies the second phase against half the final 3 Pa peak. Streaming
retains the first phase when the running peak reaches 1.6 Pa, discarding the second phase's
endpoint. When the final peak reaches 3 Pa, it replaces the first phase with the third.
This is a semantic counterexample, not a physical pressure history or a newly selected rule.
The existing source already described an approximation, but its exception was too narrow:
the discarded intermediate phase can be the largest seen so far. Only that comment changes.

All 13 gauge histories from the six receipted pyro2 CSVs were tested at each of
25, 50 and 100 µs, using identical signed piecewise-linear bin means for both algorithms.
All 39 comparisons agree on impulse and closing sample. The 24 free-field comparisons close;
the 15 room-mean comparisons have no negative pressure before the window ends. Their agreement
does not demonstrate correct phase closure. These are strong 1-D spherical waves and room
volume means, not independent weak-load or local reflected-point validation.

Both actual Swift offline functions (`HybridFarField.firstImpulse` and
`SurrogateBench.firstImpulse`) pass all eight hand-calculated controls and all 39 derived
corpus inputs. The native tests compare the two functions exactly and use ordinary Double
summation roundoff bounds against real-arithmetic/Python expectations. Those bounds are
numerical test checks, not changes to dataset tolerances.

## Reproduction and receipts

From the repository root, with the existing receipted open-benchmark data under
`$BOMBCAD_DATA/open-benchmark/pyro2-decks/entry-20mm`:

```sh
python3 Benchmarks/CUDAAcceptance/2026-10-22-phase-contract/audit.py
BOMBCAD_SETTLE_CACHE="$BOMBCAD_DATA/settle-cache" swift test --filter FirstPhaseDefinitionTests
```

- [Predeclared plan](plan.md), [analytical inputs](fixtures.json), [CPU audit](audit.py).
- [Results and source/input SHA-256 receipts](results.json), [audit log](audit-final.log).
- [Derived bin means](binned-fixtures.json) let the native tests run without external data.
- [Native test log](swift-test-final.log).
- [Original corpus receipt](../../open/records/pyro2-ideal-gas-balloon-v1/receipt.json).

The audit verifies every source CSV hash, finite pressure/time values, increasing times,
and signed-area conservation for each rebinned curve. An independent linear interpolant
checks the binning calculation. The first audit attempt stopped on a final timestamp
roundoff (roughly 1e-16 s); [its failure is retained](audit-v1-endpoint.log). Clamping the
last bin endpoint to the actual final timestamp fixes that numerical boundary without
changing or filtering any history. Every subsequent declared comparison completes.

The results record the pre-publication base revision and dirty candidate source hashes;
they do not claim to have run from the eventual publication commit. Float32 replay is
an analytical model, not a new GPU execution or emitted-instruction attestation.

## Decision and next work

No algorithm, shader, default, label, mask, tolerance or training index changes. No CUDA
acceptance failure is relaxed. emmettl/bombcad-work#62 stays open: predeclare independent
weak/reflected/multiphase controls and a resolution sweep, then justify the target contract
before choosing or implementing a replacement. The existing production-pressure controls
remain the evidence for near-zero closure sensitivity; this audit addresses a separate
semantic limitation. A larger or multi-phase state representation is an implementation
option to evaluate only after that target decision, not an adopted remedy.

Validation: `make format`, strict lint and the host strict build pass without warnings.
Plain `make check-affected` passes its covered selection, including the PC Linux CPU lane
(60 tests across ten suites, including both new definition tests), selected Mac suites
and script/docs checks. The initial sandbox strict-build attempt failed to update the
existing `.build/debug` symlink; the host retry passed. No GPU numerical experiment was
needed for this audit. [Integrated log](check-affected.log), [strict-build log](build-strict-host.log).
