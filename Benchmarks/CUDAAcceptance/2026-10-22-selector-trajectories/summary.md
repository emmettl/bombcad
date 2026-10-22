# Selector-only native trajectories: rejected candidate — 22 October 2026

Tracking: emmettl/bombcad-work#89 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80. Follow-ups:
emmettl/bombcad-work#90 (new failure histories) and emmettl/bombcad-work#91 (upstream speed production).

The explicit safe/precise selector is not an accepted generation policy. Flat passes the
existing corrected-reference gate, but the candidate introduces one slope first-phase
impulse failure and61 Beirut peak failures. Native CUDA still fails the original Beirut
phase value against both the fixed production reference and candidate Metal. No reference,
default, tolerance, mask, phase definition or training admission changes; bulk remains held
under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.

| Pilot | Candidate Metal vs existing reference: peak / total / phase failures | Native CUDA vs existing reference | Native CUDA vs candidate Metal |
| --- | --- | --- | --- |
| Flat | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Slope | 0 / 0 / 1 | 0 / 0 / 0 | 0 / 0 / 1 |
| Beirut | 61 / 0 / 0 | 0 / 0 / 1 | 0 / 0 / 1 |

All comparisons use every valid value in all three target channels and the original
`0.05 + 0.002 * abs(reference)` bound, with exact feature/mask bytes. The conditional
candidate-Metal comparison does not replace the existing reference. Every failed value,
location and allowed error is retained in [trajectory-results.json](trajectory-results.json).

## Controls and actual execution

All nine declared district commands run once, terminal0, under ordinary shared Mac GPU
leases. Three disabled-feature captures reproduce every original numeric array, complete
initial/final coarse-state hash, pressure/raw-cell trace and clock record against immutable
emmettl/bombcad-work#87. They also reproduce the fixed production target arrays exactly.
Three selector-only plain runs then complete from the identical initial states/features/masks.
Three captured candidates retain every ordinary plain output and complete initial/final
coarse-state hash exactly before their new histories are interpreted. No numerical failure
is retried. No PC arithmetic job or performance benchmark is run.

The [implementation checkpoint](checkpoint.md) already qualifies751,344 actual scalar-bank
output words and12 independent Sod/Sedov controls, with full analytic fields saved and
errors improving on refinement in both modes. The default42 digest variants/six sets remain
bit-identical. Those controls support this bounded experiment; they do not establish universal
physical accuracy or guarantee the per-value field gate.

Only original `prepareStep` uses the safe/precise sibling. All other measurement, sweep,
cooling and sampling pipelines retain their original source/options. Full untransformed
producer SHA256 is `9b71ace9e68302d44903ae6d6d391932384e29efc51db3189c34a41b04fb9eed`.
The published release, resources, sources, original input geometry and selected host context
are frozen and rehashed. Actual linked minOS/SDK15 is checked before dispatch. Gauges and
untested physics/build overrides are refused; no reference schedule or arithmetic helper is
substituted. All owned command groups are terminal; no global GPU-idle claim.

## New failures and observed phase behavior

The new slope failure is at row476/column480, index244192. Fixed-reference first-phase
impulse is134.0760955810547 Pa s; candidate is365.0989990234375. Error231.0229034423828
exceeds the unchanged allowance0.31815219116210935. That receiver was not among the two
existing trace columns, so its pressure crossing/closure mechanism has not been observed.
The old monitored slope receivers still close at steps1276 and1593 in both Metal modes.
Do not infer the new point's mechanism from the endpoint impulse alone.

The61 new Beirut peak failures occupy rows315–324/columns4–39. Largest excess is at
row322/column14, index164878: fixed5056.1845703125 Pa, candidate5069.54248046875,
error13.35791015625 versus allowance10.162369140625001. Existing captures do not contain
these peak receivers' histories. emmettl/bombcad-work#90 declares a parity-gated observation
follow-up for the new slope point, two deterministic Beirut peak failures and a neighboring
valid nonfailure; that subset is not an exhaustive spatial or argmax inventory.

At the existing Beirut phase receiver187747, candidate Metal still closes at active step900,
with final impulse1696.1187744140625 Pa s, close to fixed1696.1177978515625. Native CUDA
still closes at827 with1514.2877197265625. Its error against candidate Metal is181.8310546875
versus allowance3.4422375488281247. Original raw history times are retained separately:
candidate Metal closure1.6764550068628523 s; original Metal1.6764549618392266 s;
CUDA1.5420506962259823 s. A step index or similar timestamp does not prove a shared state.

## Clock partition

All7,875 actual candidate prepare records, including inactive rows, match exact rational
Float32 source-order timestep/stop evaluation. Every integer-clock increment is exact and
the active dt words match the recorded native pressure history. No forced-step schedule is
used. Counts remain flat2689/2645, slope2753/2711, Beirut2433/2417 encoded/active records.

| Pilot | First remaining candidate-Metal/native-CUDA dt difference | Different native active dt words | Incoming maximum-speed words, Metal / CUDA |
| --- | ---: | ---: | --- |
| Flat | 4 | 2584 / 2645 | 1163367390 / 1163367389 |
| Slope | 2 | 2459 / 2711 | 1161045875 / 1161045876 |
| Beirut | 3 | 2390 / 2417 | 1156366961 / 1156366960 |

At each first difference, CFL/dx/max-step/forced-step words agree and both results equal
their unclipped source-order proposal. The difference is already in the incoming maximum
speed words, not a same-input selector discrepancy. Contributing cells, intermediate sweep
states, reduction ties and individual instructions are not identified. emmettl/bombcad-work#91
tracks actual upstream producer context; replacing that producer with a fresh measurement
on final state would not establish the original inputs.

## Preservation and limits

Fresh verification checks complete local output inventories, frozen inputs/resources/context,
all baseline/capture gates, all failed-value locations and the remaining-clock recomputation.
The542-file implementation checkpoint remains unchanged. Its complete analytic fields and
executed test versions are retained; district 3D-state fidelity uses whole-buffer hashes,
not locally archived complete district state arrays. Original CUDA data are frozen local
comparators from the qualified parent experiment; no new CUDA execution is claimed.

One CPU-analysis preflight failure is retained: the first analyzer looked for the archived
source-order model in the selector-contract folder, while that unchanged model belongs to
the clock-selector-replay archive. The corrected version changes only dependency paths and
a fresh output folder. Both analyzer versions, the failure receipt and all numerical outcomes
are preserved. No GPU rerun or arithmetic change obtains parity.
The executed final auditor is [selector_analyze_pilots_v2.py](selector_analyze_pilots_v2.py);
[selector_analyze_pilots.py](selector_analyze_pilots.py) is retained as the failed preflight version.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-selector-trajectories`.
This completes the bounded emmettl/bombcad-work#89 experiment as a rejection of adoption.
Broader emmettl/bombcad-work#62, emmettl/bombcad-work#63 and emmettl/bombcad-work#80 remain open.

Validation: format/lint, warning-free host strict build and plain affected checks pass,
including36 PC tests/four suites. Existing Python ResourceWarnings remain. Fresh full
inventory/gate verification and decompressed archive-member checks accompany the evidence.
