# Beirut product consequences of arithmetic/backend variation

For emmettl/bombcad-work#62 and emmettl/bombcad-work#63, the seven existing Beirut field
outcomes were passed through the declared wall/roof judging model: default tiled, default
full-grid, fast/safe × explicit contraction on/off, and CUDA. All field hashes match the
published reference-spread evidence. No flow, target, product default or admission gate changes.

## Result and coverage

All 20 substitutions have identical wall moderate/heavy and roof-proxy moderate probabilities
across all six declared factor/scatter pairs: factors 1 and 1.3, scatter scales 0, 0.5 and 1.
The 50 uncertainty draws are shared; zero-scatter pairs use one deterministic assessment.
Peak-only, first-phase-only and combined substitutions isolate each contribution; a duplicate
default-load control is also exactly identical.

The sample is the existing 10,013 judged ground-floor strips of `beirut-p0-1`, on 1,081
reinforced-concrete buildings, 1,071 with roof proxies. It is one charge/yield and construction
population, inside the existing 0.85-domain boundary. None of the field receivers that fail
the current numerical gate contributes to these sampled strips. Thus unchanged outcomes
here do **not** establish harmlessness of the rejected points or satisfy broader admission.

| Field outcome | Largest sampled peak change | Largest sampled first-phase change | Strips changing nominal 3% peak / impulse bin |
|---|---:|---:|---:|
| Default full-grid | 0.00229% | 0.000820% | 2 / 0 |
| Fast, contraction on | 0.00647% | 0.00119% | 1 / 0 |
| Fast, contraction off | 0.00574% | 0.000516% | 1 / 1 |
| Safe, contraction on | 0.00337% | 0.00115% | 1 / 0 |
| Safe, contraction off | 0.00364% | 0.000852% | 3 / 1 |
| CUDA | 0.00402% | 0.00125% | 1 / 3 |

These are relative changes in the sampled field means, before uncertainty or load factors.
The existing product path rounds pulse peak and impulse to 3% bins, retains the surrogate's
rise and judges triangular pulses through the envelope SDOF. Some bins change, but none
changes the assessed outcomes here. This is not an unquantized-response or physical-validation
result. Roof loads remain the existing proxy: their surrogate loads scaled by the building's
ground-floor load ratios, not measured/predicted loads at roof height. No parameter was fitted
to these arithmetic variants.

## Sampling, controls and operational history

The front-cell selection, ground-floor boxes and sampling filter follow `judge_field.py` and
`train_field.py`; dataset masks remain unchanged. The published baseline CSV's log/exp and
six-significant-digit path is reproduced exactly for every peak and impulse entry. The actual
new judging inputs use full-precision means from raw fields. `analysis.json` retains every
probability comparison, and `study.json` retains sampled-load differences and source/input pins.

The first preflight stopped before launching a judgement because it incorrectly demanded
closer agreement than the published CSV's serialization supports. That failed attempt is
retained, followed by the exact published-pipeline check. Two further launches exposed CSV
reader failures: standard CRLF is a single Swift newline character, so splitting on a literal
LF fails, and trimming fields alone is insufficient. `FieldWalls.swift` now splits on newline
characters and trims header/numeric fields. All 10,013 CRLF rows then match. A separate LF
nominal control has identical outcomes and building metadata for all 1,081 buildings, including
the final numeric column.

The successful main judging process completed before its controller's summary hit an omitted
optional `roof` key. A separate audit consumed the saved output with missing optional fields
handled correctly; the judging run was not repeated. Original failed state and exact scripts
remain retained. The original judging return-code value was not saved before the wrapper reread
state; its successful path is inferred from reaching postprocessing after the pinned explicit
nonzero-return guard, rather than represented as a contemporaneous return-code receipt.
All four owned CLI process groups are terminal (two CSV failures, main judging, LF control).
There is no timing or GPU-performance claim in this CPU study.

## Reproduction and limits

`study.py`, `run.py`, `analyse.py`, `lf-control.py`, `finish.py` and `package.py` retain the exact
commands, source/binary hashes, saved-output audit and packaging procedure. Producing source
is the recorded base revision plus the CSV-reader change, identified by actual file hashes.
The archive retains all seven full numerical fields, both sampled-load CSV encodings, the
published sampling tables, all judged outcomes and failed-attempt records. All 52 retained
file instances were hash-verified; 12 identical immutable payloads use tar hard links. The
archive is 27,040,004 bytes.

Original OSM/raster assets and recorded façade/component histories are hash-pinned local
prerequisites, not included in this archive. Recomputing saved-field comparisons and outcome
statistics uses the retained data; rerunning the geometry/history-based judging command
requires those original assets. No trained model, training index or host service changed.

The numerical gate remains failed for Beirut. Remaining work needs consequences at the
rejected receivers or appropriate targeted load fixtures, other geometries/constructions,
weak/reflected/multiphase histories and resolution/timestep controls. An unchanged result in
this covered product subset does not choose phase semantics or justify a portability bound.
emmettl/bombcad-work#62, emmettl/bombcad-work#63 and emmettl/bombcad-work#47 remain open.

Validation: `make check-affected` passed: strict build without warnings, lint, script/docs
checks, 71 CUDA/queue tests (four local Torch skips), seven selected Mac tests and 36 PC tests.
All experiment judging and archive verification finished before repository validation began.
