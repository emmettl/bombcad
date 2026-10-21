# Capturing consumed production pressure

2026-10-21; emmettl/bombcad-work#79, supporting emmettl/bombcad-work#62 and
emmettl/bombcad-work#59. No numerical default or admission policy is changed.

The opt-in diagnostic now records the pressure actually consumed by an instrumented
first-phase recorder, including zero-dt initialization and seeded history. The ordinary
shader source and default generated CUDA source remain unchanged. Four control cases retain
exact exported arrays, initial/final complete coarse state hashes and recorder histories
across plain, recorder-only and pressure-observed modes. The previously missing Beirut
receiver 255969 is captured under these controls; its observed closing pressure is
**−0.078125 Pa**, with final first-phase impulse **634.6305541992188 Pa s**.

## Implementation and contract

`--trace-pressure` requires `--trace-columns` and `--first-phase`. It builds a sibling of
`sampleFirstPhase` from the unchanged body, adding bounded selected-column stores for the
consumed p and resulting recorder state. It does not calculate a second pressure or add an
observation pass. Ordinary runs neither append the sibling shader nor allocate its buffers.
The optional `--diagnostic-state-hashes` hashes complete coarse fluid/species, peak/impulse,
mask and all first-phase buffers before and after stepping; refinement and structural state
are outside this hash contract. Times and step count are retained alongside the hashes.

The new `bombcad-production-pressure-trace-1` contains eight float32 fields: overpressure,
peak, all-positive impulse, first-phase impulse, phase peak, open, dt and batch time. Metadata
retains seeded recorder state and the zero-dt initial sample. Flattened receiver indices
include additional export heights. Recorder-only tracing keeps its existing first-layer
format. A 2–32768 sample budget, including initialization, bounds retained history;
overflow refuses export before a dataset is written, rather than marking a truncated
capture complete. A trace is diagnostic evidence, not a completed dataset admission.

The replay loader explicitly refuses recorder-only input as pressure, validates the version,
completeness, dimensions, initialization and active steps, and rounds JSON seeds back to
float32. Separate multiply/add and native float32 fused accumulation are reported
independently for the whole history. No per-step policy switching or relaxed tolerance is
used. Matching an arithmetic model is not an attestation of emitted GPU instructions.
Existing one-sample counterfactuals remain labelled separate-accumulation sensitivity probes.

## Controlled observations

Each default case has three current release-executable exports: plain, existing recorder-only
observation and consumed-pressure observation. Normal logical batch boundaries remain.

| Case | Active steps | Pressure receivers | Arrays / initial and final coarse state / recorder history | Whole-history arithmetic compatibility |
|---|---:|---:|---|---|
| small-layers | 55 | 5 | exact | fused |
| terrain | 2708 | 2 | exact | fused |
| beirut | 2477 | 6 | exact | fused |
| flat-half | 2666 | 1 | exact | fused |

The small fixture includes the base receiver plane and three additional height/roof layers.
The GPU unit controls separately cover balloon and mapped starts with nonzero seeded impulse,
odd 15×17×9 grids, layer indexing, state/recorder parity and budget failure. All three full
plain exports match their historical inputs/masks/targets byte for byte. The new terrain
and Beirut recorder-only trace **bytes, step lists and clocks also exactly match the archived
production traces**, rather than merely agreeing at the final target.

An additional small explicit safe/contract-off pair retains plain/pressure array and state
parity and exact separate-operation replay. It does not replace default arithmetic.
Four CPU format/arithmetic tests pass on both Mac and PC Linux; the native FMA control uses
a fixed case where separate and fused sums differ, and validates initialization closure and
later reopening. A separate JSON-decimal seed check guards float32 round-trip interpretation.

[The independent audit](evidence/audit.json) rereads 42 default-control dataset-array instances /
94,985,472 bytes and rechecks source/executable/resource pins, complete state receipts,
recorder histories, archived references and full replay. The additional unfused pair verifies
10 arrays / 406,784 bytes. Twelve default numerical commands, two unfused commands, and three
expected refusal commands are terminal. Refusals cover missing columns, missing budget value
and actual budget overflow, each with no dataset output. This is a numerical study with
cooperative GPU slots, not a quiet performance benchmark.

## New flat-case closing-decision sensitivity

One additional precise CUDA trace covers receiver 62902 in the fixed 100400 kg flat case.
The existing GPU lease is acquired normally. Independent remote rehashing verifies all
**12 baseline numeric files, including dt, are byte-identical** in the traced run; the only
additional numeric file is `trace.npy`. The existing CUDA diagnostic recomputes pressure
from its declared expression, with exact recorder replay; it is distinct from the new
in-kernel Metal store. Source/worker/diagnostic hashes and the retained original result are
verified in [cuda-audit.json](evidence/cuda-audit.json).

At corresponding active step 1558, production Metal consumes −0.0078125 Pa and closes;
CUDA's diagnostic pressure is +0.0078125 Pa and its recorder stays open. Simulation times
are 2.5300621522146685 / 2.5300625132769534 s, respectively; these are simulation clocks,
not cross-host wall-clock measurements. CUDA closes at step 1584 with −9.265625 Pa.

| First-phase impulse | Pa s |
|---|---:|
| Actual Metal | 703.286865234375 |
| Actual CUDA, still rejected | 705.982666015625 |
| Offline CUDA recorder with only sample 1558 replaced by measured Metal pressure | 703.2847290039062 |

The single-sample offline replacement reduces the difference from 2.69580078125 to
0.00213623046875 Pa s. It changes neither flow nor any accepted result. This demonstrates
how a closing decision can amplify a small pressure discrepancy into the label gap; it
does not identify a particular machine instruction, select a threshold or establish the
physical truth of either phase definition. The original tolerance stays
1.45657373046875 Pa s and the actual CUDA case remains rejected. Full windows, raw traces
and the explicitly targeted counterfactual are retained in
[phase-decision.json](evidence/phase-decision.json).

## Provenance, development observations and limits

The source/executable/resource/input identities are in [study.json](evidence/study.json).
Seven exact candidate source files and the baseline-relative patch are retained; the
matrix uses the recorded executable and source snapshot. The default generated CUDA source
remains SHA-256 `c58f4f0a7ab5563b4d8539eb884b95dc4c1613034fcee98664b0db019eb14094`.
[retained-files.json](retained-files.json) hashes all 139 raw files / 97,956,093 bytes.
The artifact copies and independently rehashes 87 metadata/trace files. Large datasets stay
under `/Volumes/StudioData/bombcad/experiments/2026-10-21-production-pressure-v2`; full CUDA
fields stay at their receipted PC paths. No private OSM/DEM inputs or executables are copied.

Development failures are kept separate from the fixed matrix. The first GPU unit run's
ordinary/observed parity passed but its CPU separate-operation replay failed ten one-ULP
impulse comparisons; explicit FMA replay resolves them. The next unit run found that the
chosen corner receivers had no mapped seed; the stronger final fixture includes a near-charge
seeded receiver as well as tail/layer receivers. The final eight-test suite passes. An initial
harness setup error occurred before any child or numerical run; its source/log is retained
and the actual study uses a fresh v2 root. A sandboxed build/test invocation hit host cache/ps
restrictions; host checks pass. No started scientific matrix run is discarded or replaced.

A store can alter compiler arithmetic. Exact observable parity here does not prove that
every unobserved intermediate of an uninstrumented binary has identical bits. The pressure
is the value consumed by the **instrumented** recorder, with its original exported outputs
and recorded histories matched. This is not physical validation, a timing result, a universal
portability bound or a new dataset rule. emmettl/bombcad-work#79's diagnostic acceptance is
met; emmettl/bombcad-work#62 still needs independent weak/reflected/multiphase and resolution/
product validation before any justified versioned label change. Peak admission under
emmettl/bombcad-work#63 and broader distributed integration under emmettl/bombcad-work#59
remain separate.


## Independent corpus availability audit

A separate [read-only inventory](independent-corpus-inventory.json) verifies all six history
hashes from the newly imported pyro2 ideal-gas-balloon-v1 receipt. The eight free-field gauge
peaks range from 32,224.16 to 2,832,021.73 Pa; the five room histories are volume-weighted
mean pressures and contain no negative samples. The documented model is 1-D spherical,
including the room-volume surrogate, not the decks' 3-D geometry. These files are available
for independent strong-wave analysis, but they do not supply 1 Pa-scale weak-load or local
reflected/multiphase validation. This inventory does not close emmettl/bombcad-work#62 or
select a phase rule. Its source histories remain at the receipted StudioData paths and are
not copied into this artifact.


## Final integrated validation

The candidate was rebased onto the open-benchmark update at `99fc0fcac50d` before the final
checks. Format/lint and the strict build pass without warnings. `make check-affected` passes
at core tier: 575 selected Mac tests (230 app, 345 core), 248 PC tests, script/docs checks and
42 digest variants in six sets bit-identical to that base. The first integration attempt's
release-note header failure and the corrected passing check are retained separately. The
seven source snapshots and 87 scientific evidence/trace files were rehashed after rebase;
source bytes still match. QA logs and the independent corpus inventory are additional
records outside the frozen 139-file scientific-run manifest.
