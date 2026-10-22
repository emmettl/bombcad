# Completed source-stencil audit — 22 October 2026

Tracking: emmettl/bombcad-work#82 and emmettl/bombcad-work#80.

All 432 command groups / 1728 exports completed once. After the corrected
[terrain-reference pilots](../2026-10-22-fixed-terrain-reference/summary.md)
fulfilled the requested pause prerequisite, the original CPU auditor resumed
and completed without rerunning a producer or temporal oracle. All 432
observation and prior-wave checks, 216 full/tiled final-state pairs, and their
entire captured selected-stencil source histories pass. This establishes the
observer's acceptance scope; it does not establish whole-grid trajectory equality.

The six local models have no reconstruction fallbacks across 8,227,928 executed
and 814,552 skipped sampled opportunities. They use observed source words but
recompute their own intermediate stages. In the stored64 model, native opposite
faces are equal despite a nonzero modeled difference in 464,486 density,
3,735,670 momentum and 353,128 energy opportunities. Model nonzero counts are
7,376,396 / 7,376,380 / 7,376,396 respectively. These are correlated sample counts,
including small tail differences, not amounts of physical dissipation.

The separately evaluated Float32 model differs from the captured native flux in
20,908,970 words, with no whole-trace equality in any of the 432 groups. It cannot
serve as an instruction-exact surrogate for the GPU operator. The rounded
primitive, slope and face variants likewise remain conditional models. None
isolates the cause of the earlier peak gap or justifies changing production
precision. Summed local conditional increments are not independently evolved
PDE trajectories or global conservation measurements.

[scientific-summary.json](scientific-summary.json) reports every outcome and
all fixed-factor strata; overlapping strata must not be added. The complete
[archive receipt](scientific-archive.json) covers 6,393 raw files / 29,072,825,186
bytes. The external archive at
`$BOMBCAD_DATA/experiments/2026-10-22-host-source-matrix-archive/all-raw.tar.gz`
is 8,173,804,778 bytes, SHA256
`6f51c7dd02688345ae8ee1fd1b6d477d1113d6e352c608381c068ef99577dd54`.
Every decompressed member was verified. Public metadata comprises 3164 files
in 25 verified archives (110052184 bytes). Numerical arrays, full traces and runtime
binaries remain external by kind; no outcomes were excluded by status.

The [written-order compatibility controls](../2026-10-22-source-order-controls/summary.md)
are now complete: both model flux arrays remain bit-identical to their earlier
CPU counterparts in all 432 cases, and neither matches an entire GPU trace.
These tested rearrangements do not resolve model compatibility; component-level
causal attribution and a precision intervention remain unsupported. Separately, emmettl/bombcad-work#62 retains the corrected Beirut
first-phase receiver failure and needs a corrected-reference pressure trace.
Existing old-start traces are historical evidence only. Bulk CUDA generation
remains gated; no tolerance, mask, label, default or training-index change.
