# Selector-only diagnostic: implementation controls — 22 October 2026

Final district result: [candidate rejected](summary.md). The district stage is complete;
the text below preserves the earlier implementation checkpoint and its then-pending gates.

Tracking: emmettl/bombcad-work#89 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80. This is a prerequisite checkpoint;
the corrected district baselines and selector-only district target gates remain outstanding.

The optional solver API and `field-export --precise-step-selector-diagnostic` use a safe/precise
sibling only for the original `prepareStep`. The original full producer source remains byte
identical (SHA256 `9b71ace9e68302d44903ae6d6d391932384e29efc51db3189c34a41b04fb9eed`).
Every other pipeline retains its original source/options. The nil path is unchanged; restart
disables the diagnostic. Untested physics/kernel overrides refuse configuration or encoding.
The CLI requires clock/pressure tracing and labels the export as diagnostic, not admitted.

Three focused controls pass: pipeline isolation/disabled full-field parity; original clipping,
inactive dispatches, one-step budget and nonphysical-speed guard; lifecycle/support refusal.
The actual solver's original and diagnostic pipeline objects then reproduce all 24 words per
record on the six immutable scalar banks: 375,672 exact words per mode, 751,344 total.
All original-mode banks pass before the diagnostic-mode banks are dispatched.

The predeclared independent matrix completes once: eight Sod and four Sedov runs, both modes,
with every complete initial/final Cell field saved. An independent Python readback recomputes
the analytic errors and original bounds; initial states agree byte-for-byte between modes.

| Control | Original mode | Selector-only mode | Original bound |
| --- | --- | --- | --- |
| Sod HLLC, 400 → 800, density L1 | 0.0013287451 → 0.0007483257 | 0.0013287288 → 0.0007483294 | <0.004 |
| Sod HLL, 400 → 800, density L1 | 0.0013976417 → 0.0007827065 | 0.0013976333 → 0.0007827001 | <0.004 |
| Sedov axis error, 80 → 120 | 3.125006% → 2.083335% | same | <4% |
| Sedov diagonal error, 80 → 120 | 0.767922% → 0.166512% | same | <4% |

Stability, reached times and existing Sedov peak-density bounds pass. Relative mass/energy
changes in these controls have magnitude below4.71e-8. Refinement improves the reported errors
in both modes; selector-only error changes against original are small and not uniformly better.
This is bounded independent evidence, not a universal physical or portability guarantee.

Focused and scalar controls preserve their executed binary and resources, verified against
both pre-dispatch binary hashes before later harness edits. Their source snapshots are explicitly
post-terminal. The analytic stage snapshots source/resources before dispatch and verifies them
unchanged afterward. Each stage's actual Mach-O minOS/SDK15 context is checked before GPU work.
Both test-binary versions and all commands/outcomes remain retained. No numerical failure/retry.

The district stage must still pass the predeclared disabled original-output gate and candidate
plain/captured parity before interpretation. Its full target comparisons keep the EXISTING
corrected production reference, every valid target/channel and tolerance. Moving Metal toward
CUDA cannot by itself justify replacing that reference. Bulk remains held under
emmettl/bombcad-work#39 and emmettl/bombcad-work#47. No production default, tolerance, mask,
phase rule, reference, training index or admission changes.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-selector-trajectories`.
`implementation-archive.json` freezes the files present at this checkpoint; later stages may
add new files to the root while these checkpoint bytes and parent archives remain immutable.

Implementation validation passes: format/lint, warning-free strict build and plain core
affected checks (200 selected suites,62-suite PC lane). All42 default digest variants in
six sets are bit-identical to630be97ee0e2. Existing Python ResourceWarnings remain. Before
district dispatch, the immediate follow-up must refuse gauges (their logging is inside
prepareStep) and allow the untraced candidate control with mandatory first-phase/state-hash
provenance. This checkpoint does not declare that remaining interface work or district gates done.

## Support refinement after implementation94213c24

The gauge/qualification follow-up is now validated: enabling or later encoding with gauges
refuses, while plain and traced candidates both require first-phase output and state hashes.
The diagnostic constructor and all other BlastCore source files remain unchanged from the
executed analytic stage; captured bank gauge words are all zero. Both original control-source
versions and the new guard/interface snapshots remain retained. The542 implementation archive
members still verify unchanged. Format/lint, warning-free strict build and plain affected
checks pass again (22 selected suites;62 PC tests in11 suites). The district stage is ready
to start under the declared gates; no district acceptance result is claimed here.
