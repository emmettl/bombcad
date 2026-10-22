# Captured Metal timestep control — 22 October 2026

Tracking: emmettl/bombcad-work#85 under emmettl/bombcad-work#62; related
emmettl/bombcad-work#63 and emmettl/bombcad-work#80. Follow-up:
emmettl/bombcad-work#86.

All three controlled CUDA pilots pass every valid target value against the corrected Metal
reference, with the original `0.05 + 0.002 * abs(reference)` gate. CUDA used the captured Metal
positive Float32 timestep history. This is a reference-dependent diagnostic; default CUDA
generation remains held under emmettl/bombcad-work#39 and emmettl/bombcad-work#47.

| Pilot | Active steps | Inactive zero-dt events | Actual clock gate | Peak / total / first-phase failures |
| --- | ---: | ---: | --- | --- |
| Flat | 2645 | 2 | Pass | 0 / 0 / 0 |
| Slope | 2711 | 1 | Pass | 0 / 0 / 0 |
| Beirut | 2417 | 2 | Pass | 0 / 0 / 0 |

Before enabling the schedule, the artifact-only worker ran each native CUDA pilot once.
All eleven original numeric files per case matched their immutable baselines byte for byte,
including full dense state, dt, native pressure traces and pressure input cells. The subsequent
three controlled solves each ran once. All six workers exited successfully through normal
shared PC scheduling; no other job was interrupted.

The actual controlled `dt.npy` words equal Metal's positive history. Every active device
relative tick equals the integer timestep prefix, and adding the source-defined rounded Metal
epoch reproduces every captured Metal active time exactly. Initialization and inactive events
remain present; inactive events consume no schedule entry. Original CUDA raw timestamps remain
unchanged. Their unrounded epoch differs from Metal's tick epoch by −0.3783 ps, +0.0730 ps and
−0.4147 ps for flat, slope and Beirut respectively. These offsets come from frozen native
source rounding; none was fitted to the result.

At Beirut receiver 187747, native CUDA closes the first phase at sample 827 with pressure
−0.0078125 Pa and impulse 1514.2877197265625 Pa s. Matched-clock CUDA closes at sample 900,
as Metal does. Its impulse is 1696.1107177734375 versus Metal's 1696.1177978515625 Pa s:
error 0.007080078125 against allowance 3.4422355957031248. Closing pressures still differ
(CUDA −59.65625 Pa; Metal −59.75 Pa). The schedule resolves this acceptance failure on the
captured case, while finite state/reader differences remain.

The prior native-reader cross-replay changed zero negative-pressure decisions on frozen
native histories. This new evolved-state control shows that timestep history can remove
Beirut's early closure. It does not identify the source of native timestep divergence, prove
an instruction-level cause, or establish continuum accuracy. emmettl/bombcad-work#86 tracks
native clock-selection inputs and source expressions before any production policy proposal.

The fixed reference is frozen Metal `c78451c099a5899ca2e95b4e375280e56f6f486a`, after terrain
mapped-start fix `aff21dff`. Its original recheck removed the slope failures but retained
one Beirut first-phase failure. Weak-wave work resumed only after that corrected-reference
comparison; historical balloon-start results are not the acceptance reference.

Only a Python prepare-uniform copy receives the existing `forcedStep` value. CUDA source,
compiler flags, sweep uniforms, clipping, stopping, cooling and safety remain unchanged.
The source audit records the existing forced branch's diagnostic-only suppression of the
max-overpressure refresh and second speed-slot reset; neither value feeds evolution or worker
termination. The fastest-speed reset and nonphysical-speed guard remain active. No new CUDA
kernel, pressure helper, product option, tolerance, mask, phase rule or training admission change.

Targets use the previously validated saved-output assembly. Reference feature/mask bytes and
receiver-column bytes are exact, and the native mask covers every reference-valid receiver.
Sharing those static templates follows existing packaging; it is not an independent geometry
prediction. All three channels are scored over the full valid field. All failed-value lists
are retained, including the empty lists for these controlled outcomes.

Raw evidence: `$BOMBCAD_DATA/experiments/2026-10-22-matched-clock`. Local histories, maps,
receipts and analysis are archived with decompressed-member verification. Complete dense solver
fields remain on the PC at the receipt paths, with fresh per-file hash verification of both
stages, original physical inputs and worker sources. Selected runtime-library hashes match the
archived native replay environment; these pins do not constitute a hermetic environment.
See `archive.json`, `results.json` and the metadata archive for detailed receipts and limits.

Validation: four analytic clock controls pass, the scalar batch/clip model reproduces the
original and requested histories, actual device clock gates pass, and all consumed archived
reference bytes verify. Format/lint pass; the host strict build reports no warnings. Plain
`make check-affected` passes, including 36 tests in four PC suites. Its existing Python
ResourceWarnings are not a clean-warning claim. The first strict-build attempt was denied
access to sandboxed Swift caches; the same build succeeded with host access. This was a build
environment retry, not a numerical rerun. All experiment jobs and verification commands are
terminal. No global GPU-free claim is made.
