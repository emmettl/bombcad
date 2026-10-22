# Actual native clock selector replay — 22 October 2026

Tracking: emmettl/bombcad-work#87 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80.

Both native selectors reproduce every captured own-input output word: 189,000 Metal
words and 155,560 CUDA words across all 15,653 active and inactive records. Metal includes
complete controls, both speed-reset words and tile count/dispatch; CUDA includes complete
controls and both speed-reset words. Only after both gates passed was each selector run on
the opposite backend's frozen inputs. All four native stages completed once, without a
numerical failure or retry. No new physical trajectory was generated.

| Pilot | First different active timestep | Relevant incoming differences | Metal selector on Metal / CUDA bank | CUDA selector on Metal / CUDA bank |
| --- | ---: | --- | --- | --- |
| Flat | 3 | Maximum speed differs by one ULP | 965173314 / 965173313 | 965173313 / 965173313 |
| Slope | 1 | None | 953740701 / 953740701 | 953740700 / 953740700 |
| Beirut | 2 | None | 967115816 / 967115816 | 967115815 / 967115815 |

Values in the last two columns are Float32 timestep words. Relevant incoming comparisons
include maximum speed, CFL, dx, maximum/forced step, batch time, time limit, step index and
stop state. Thus slope and Beirut's first differences reproduce within native selection
on identical relevant inputs. Flat already has a measured-speed difference; selector choice
also changes its result on the Metal bank. This bounds source-expression evaluation and
measured-input contributions without identifying an individual machine instruction.

Across Metal / CUDA banks respectively, same-input selector timestep differences number
1,125 / 1,160 for flat, 870 / 840 for slope and 1,038 / 1,036 for Beirut. Every CUDA
timestep and stop decision matches the exact rational, nearest-even Float32 model of the
written source expression. Four analytic controls pass, including ties and clipping/stops.
Both selectors have identical stop decisions on every bank. Complete output differences,
including work counters and clock words, are retained; CUDA has no Metal tile arguments.

Later evolved maximum-speed and batch-control inputs differ. The replay retains the
conditional four-way timestep matrix and original pressure/phase/time values around Beirut
steps 827 and 900. Those are separate native trajectories at their original times. This
experiment does not prove that changing selector precision alone restores closure900 or
passes the full target gate. The captured-Metal-clock result in emmettl/bombcad-work#85
remains a reference-dependent diagnostic.

Metal compiles the original untransformed main producer unit with nil options, empty
constants and captured minOS/SDK15 context. Own/cross source and harness binary are identical.
CUDA uses its original full diagnostic source, precise/unfused flags and both original PTX
identities. Frozen input/source pins, all local own outputs, remote stage inventories,
selected runtime pins and terminal controllers verify. No global idle or throughput claim.

The prerequisite corrected terrain reference already passes slope; Beirut still fails one
first-phase impulse value under the unchanged full target gate. Bulk generation remains
held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47. No default, tolerance, mask,
phase rule or training-admission change. emmettl/bombcad-work#88 tracks a bounded explicit selector arithmetic-contract
experiment on these frozen banks before a new PDE candidate.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-clock-selector-replay`.
The parent clock capture archive is immutable. Native outputs, input banks, full producer
source/PTX, harnesses and analysis are retained externally; public metadata is indexed by
`archive.json`. This is scalar replay, not a new field-state capture.

Validation: format/lint, warning-free host strict build and plain affected checks pass,
including seven selected Mac tests and 36 tests in four PC suites. Existing Python
ResourceWarnings remain. An initial sandbox-only strict build could not write host caches;
the host retry passed. No numerical experiment was rerun.
