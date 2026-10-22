# Expanded selector-failure histories — 22 October 2026

emmettl/bombcad-work#90, under emmettl/bombcad-work#62 and emmettl/bombcad-work#63.
The selector-only candidate remains rejected. Bulk CUDA generation remains held under
emmettl/bombcad-work#39 and emmettl/bombcad-work#47.

Four observation-only jobs ran once on the frozen qualified `8b393c81` executable/resources,
with normal shared Mac GPU leases. Original/selector-only slope and Beirut all exited zero.
Every ordinary array, complete initial/final coarse-state hash, clock byte/metadata value,
old selected pressure/raw-input/endpoint word and original sample/time axis matches its
immutable parent. Exact feature/mask and all-channel target gates are inherited unchanged.
There was no PC numerical job or throughput measurement.

The first controller stopped after three jobs because it compared selector JSON key order.
All parsed keys and values were identical. The failed controller and source are retained;
`resume.py` dispatched only the missing fourth job. Independent `verify.py` audits all four.
No numerical capture was retried or modified to obtain parity.

## Slope: a half-peak qualification boundary

At receiver244192, both modes first open at step2051 and close at2243. Actual closure
pressures are −8.3046875/−8.2890625 Pa (original/candidate), with phase impulses
134.0760955810547/134.0763397216797 Pa s. This first closure is shared, not the event
that produces the final231.0229034423828 Pa s difference.

The retained first-phase peak is746.8984375 Pa in both. A later pressure maximum at
step2461 is1493.7734375 Pa original and1493.8125 Pa candidate. The existing strict rule
`retainedPhasePeak < 0.5 * runningPeak` therefore has these exact operands:

| Mode | Half running peak (Pa) | Retained minus half (Pa) | Reopens |
|---|---:|---:|---|
| Original | 746.88671875 | +0.01171875 | No |
| Selector-only | 746.90625 | −0.0078125 | Yes |

The candidate reopens at2461 (native time4.114193071714908 s), then closes at2544,
pressure−14.2890625 Pa, native time4.267134625102699 s. Its final first-phase impulse
is365.0989990234375 Pa s; original retains134.0760955810547. Both recorder values
match their exported phase target words exactly. Original and candidate raw times are
preserved separately: the same step number does not establish the same physical state.

This directly explains the candidate's new phase failure through the existing recorder
qualification branch. It does not identify the upstream source of the small pressure
trajectory difference, prove continuum accuracy, or justify a phase-rule/deadband change.
The two old slope controls retain their original closure steps1276/1593 and exact old words.

## Beirut: observed pressure peaks, accumulated peak still unobserved

The selected set contains the old phase point187747, first peak failure161319, largest
excess164878 and valid adjacent nonfailure165390. It is not an exhaustive61-point inventory.

| Receiver | Recorder pressure max, original/candidate (Pa) | Step | Exported peak, original/candidate (Pa) |
|---|---:|---:|---:|
| 161319 | 6030.59375 /6017.921875 | 1171 | 6030.5908203125 /6017.93359375 |
| 164878 | 5055.03125 /5068.3671875 | 1330 | 5056.1845703125 /5069.54248046875 |
| 165390 | 5073.4453125 /5079.8359375 | 1331 | 5074.78369140625 /5081.16015625 |

The actual pressure histories change at the selected peak failures; their maxima occur at
the same listed step in the two modes, on distinct raw times. Nearby samples, dt, the ten
largest local pressure maxima and every open/close transition are retained in `histories.json`.
The old Beirut phase point still closes900 in both Metal modes; candidate1696.1187744140625
versus original1696.1177978515625 Pa s. Native CUDA's earlier827 closure remains unresolved.

`pressure-trace` field1 is the recorder's maximum of interpolated pressure. Exported target0
instead interpolates the per-cell accumulated peak buffers (`FieldExport.swift`); taking a
maximum and interpolating need not commute. These captures lack those accumulated-buffer
histories and winning per-cell times. Do not substitute recorder peak for the acceptance
quantity or claim the61 target failures are fully explained. emmettl/bombcad-work#92
tracks a feasible bounded follow-up using the existing `production-trace` accumulatedPeak field, with ordinary/state/clock
parity and a direct final-target word check, before considering richer cell-argmax capture.
emmettl/bombcad-work#91 separately tracks actual upstream speed-producer context.

## Evidence and limits

Raw: `$BOMBCAD_DATA/experiments/2026-10-22-selector-failure-histories`.
Both parent archives remain immutable. `archive.json` records the complete local inventory,
full raw archive and public metadata archive with decompressed-member and final raw rehash
verification. District full3D arrays are not captured here: complete initial/final state
hashes, original arrays, selected raw cell/receiver histories and clock streams are retained.
No source/default/reference/tolerance/mask/phase/index/admission change is adopted.
