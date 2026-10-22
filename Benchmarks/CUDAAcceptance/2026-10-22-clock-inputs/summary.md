# Native clock-input capture checkpoint — 22 October 2026

Tracking: emmettl/bombcad-work#87 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80. Capture gates are complete. Native selector
own-input and cross-input replay remains required before causal attribution; this issue stays open.

All six own-backend capture gates pass. Metal retains every original numeric array, pressure
and raw-cell trace JSON, and complete initial/final coarse-state hash from the corrected paired
input study. CUDA retains every original byte in all eleven numeric outputs, including dense
state/species/peak/impulse fields, first-phase records, dt and both native traces. Three CUDA
disabled-feature baselines passed first; each subsequent Metal/CUDA capture ran once.
These are observer-fidelity gates. Native CUDA's remaining Beirut acceptance failure is unchanged.

| Pilot | Metal encoded / active / inactive | CUDA encoded / active / inactive |
| --- | --- | --- |
| Flat | 2689 / 2645 / 44 | 2647 / 2645 / 2 |
| Slope | 2753 / 2711 / 42 | 2712 / 2711 / 1 |
| Beirut | 2433 / 2417 / 16 | 2419 / 2417 / 2 |

All 15,653 records have both completion markers. Actual pre/post control counters, integer
device-clock increments, native pressure-trace timestep and batch-time words, and original
time axes verify exactly. Metal's source-defined absolute clock origins and CUDA's relative
zero origins remain unchanged. Inactive rows are retained rather than treated as active steps.
Each record has 119 UInt32 words: two speed words, four tile-context words, 18 control words,
69 prepared-uniform words, 18 post-control words, two post-speed words, four post-tile words
and two markers. Metal records actual count/dispatch inputs and outputs. CUDA's full-grid
prepare has no tile-buffer arguments; those four-word slots are explicit zero placeholders.

All eight complete Metal initial-buffer hashes match the original physical CUDA jobs:
Cell state, fluid mask, species, accumulated peak and impulse, receiver columns, first-phase
records and open flags. This does not make later backend states identical. Gauge count is zero
in every captured uniform record; source/control layouts agree at 276/72 bytes on both backends.

The optional Metal observer is a separate copy-only library at buffer slots 24–30, preserving
native bindings 0–17 and the full original producer compilation units, flags and function
constants. Original shader-resource bytes verify, and the captured and original field-export
binaries both link minOS/SDK 15.0. CUDA uses an optional CPU readback around its original prepare;
no CUDA source, compiler, control, clipping, safety, sweep or cooling path changes. Complete and
partial raw CUDA streams are byte-identical on successful captures and remain retained.

Implementation: `78cc5b66`; launcher-only correction: `dbfe83bb`. Four focused GPU controls pass:
mapped/balloon field and pressure parity with actual control words; inactive clipped dispatches;
overflow refusal without changing the solver; and lifecycle handling. Format/lint and the host
strict build pass warning-free. Plain affected checks selected 154 suites including 44 Linux
suites, and all 42 digest variants in six sets match base `05bd762c` bit for bit. Later artifact
checks are recorded separately. Existing Python test ResourceWarnings remain documented.

Two development/preflight outcomes are retained. The first development fixture incorrectly
expected the blocking aggregate result to propagate `reachedLimit`; the captured native control
already showed stopped = 2 correctly. The fixture now checks the actual native control; solver
behavior did not change. The first Metal launcher invocation failed to import a sibling Python
helper before any GPU pilot. Its source/error receipt is retained, and `dbfe83bb` corrects the
search path. Both CUDA stages had already finished; their frozen helper snapshots and the
post-terminal launcher-only source transition verify. No physical acceptance failure was retried.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-clock-inputs`. Local histories, target maps,
coarse-state hashes, source/runtime snapshots, all outcomes and metadata are archived with member
verification. Complete dense CUDA fields remain on PC at receipt paths under fresh verified
inventories; they are not claimed as locally archived. Original full initial states remain in
pinned parent archives/jobs. All owned capture/check processes are terminal; shared GPU leases
were used without interrupting other work. Capture timings do not establish throughput.

Next, reuse the original full native prepare compilation units on these actual scalar/control
and tile inputs. Require complete relevant own-output word parity before cross-feeding. The
Metal prepare belongs to its untransformed main producer unit; the pressure-observer append
used in the earlier initial replay is not its native compilation context. Preserve the actual
SDK 15.0 context and empty function constants. No gauge/refinement context may be silently
invented. Cross-selector results will be conditional on recorded inputs, without advancing a
new PDE trajectory. Further state/reduction-candidate capture needs a separate declared gate.

No default, tolerance, mask, phase rule or training-admission change. Bulk generation remains
held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47. The captured-Metal schedule from
emmettl/bombcad-work#85 remains a diagnostic; these captures do not reopen generation.
