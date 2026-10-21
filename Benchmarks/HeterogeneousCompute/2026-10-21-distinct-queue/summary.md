# Distinct full-flat workloads: admission stops the proposed queue

2026-10-21; emmettl/bombcad-work#59, emmettl/bombcad-work#62 and emmettl/bombcad-work#79.

The predeclared three-case set is **not fully admitted**. At half the original charge,
one first-phase impulse target fails the unchanged CUDA/Metal gate. The original and
1.5× masses pass. No mixed-queue calibration or throughput trial is run on a selected
passing subset. The earlier 12.5% queue benefit remains a repeated-reference backlog
result; it does not establish cost or eligibility across these distinct cases.

## Fixed design and results

Before outcomes, masses were fixed at 100400/200800/301200 kg on `made-perimeter-s1-1`'s
synthetic flat layout, original charge location, saturated ground and recommended mapped
start with first-phase targets. Grid is 512×512×59 at 4 m, top 236 m, duration 4.51 s.
Height and duration are explicit because their omitted defaults can depend on mass. The
original export's recorded end time is 4.510000000004387 s; the default duration formula
rounds its request to hundredths, giving the pinned 4.51 s. The original-mass current
reference passes its historical gate. No parameters are selected after the failed gate.
These are three charge strengths on one layout, not three independent geometries.

| Charge mass (kg) | Metal / CUDA active steps | Peak failures | Total impulse failures | First-phase failures | Gate |
|---:|---:|---:|---:|---:|---|
| 100400 | 2666 / 2666 | 0 | 0 | 1 | rejected |
| 200800 | 2645 / 2645 | 0 | 0 | 0 | passes |
| 301200 | 2716 / 2716 | 0 | 0 | 0 | passes |

The unchanged tolerance is `0.05 + 0.002 * abs(reference)` at every valid target, with
identical inputs and masks required. The rejected half-mass receiver is column **62902**,
x=438, row=122. First-phase impulse: Metal **703.286865234375 Pa s**, CUDA
**705.982666015625 Pa s**, absolute error **2.69580078125 Pa s**, tolerance
**1.45657373046875 Pa s**. Its peak is 5102.265625 / 5102.296875 Pa and total impulse
1015.7855224609375 / 1015.779296875 Pa s, both passing. This identifies an additional
portability failure; it does not establish its arithmetic/phase-closing mechanism or
which label is physically correct. Passing here is an unchanged diagnostic gate, not
publication to a training index or general dataset admission.

## Controls and independent audit

For each mass, a current plain Metal reference is compared byte for byte with a second
export that snapshots its portable physical initialization before stepping. All inputs,
masks and target arrays match exactly. The snapshot and separately prepared CUDA job
match in full physical file hashes, uniforms, axes, start state, startup, duration,
cooling and terrain metadata; work-selection buffers are outside that portable contract.
The three reference targets, and the three CUDA targets, have distinct hashes across
masses. CUDA uses the current precise worker and shared PC GPU lease with opt-in warm PTX
cache; no physics, precision, rounding, mask or comparison setting is changed.

[audit.json](evidence/audit.json) independently revalidates all source/executable/resource/
support pins, finite arrays, masks, input/target comparisons and initial jobs, and localizes
all failures. It rereads **24 reference/CUDA dataset-file instances / 62,940,071 bytes**,
plus checks the nine plain/observed array identities and validates initial job buffers.
All **12** started command process groups are terminal: three plain references, three
snapshot controls, three preparations and three CUDA deployments. The stage completes
successfully as an experiment with one rejected gate; failed admission is retained as a
result rather than converted into a successful data case.

[retained-files.json](retained-files.json) hashes all **131 raw files / 3,606,930,271 bytes**.
The large numerical arrays remain at the declared scratch paths under
`/Volumes/StudioData/bombcad/experiments/2026-10-21-distinct-queue` (remote full CUDA fields
also remain at deployment receipt paths). This artifact copies and independently rehashes
**50 metadata/source/log files**, not the large arrays. Exact harnesses and their
predeclared plan, build log, command identities, gates, provenance and rejected values
are retained. Reproduction requires the pinned synthetic layout and matching scratch
paths; the earlier full-queue archive retains that synthetic layout too.

## Interruption and timing limits

The first controller finished the half-mass case and the second case's references and
preparation, then stopped on an SSH availability-probe timeout **before** starting the
second CUDA deployment. Its handle was confirmed terminal. A fresh read-only probe reached
the same PC boot and observed idle GPU/no lease. The continuation verifies source/input
pins and terminal owned groups, preserves `interrupted-stage.json`, reuses that existing
preparation, and starts only the missing work. It skips the first completed case entirely.
No numeric run or unfavorable observation is discarded or repeated. The original failed
log, continuation source/log and probe receipt are retained.

Other Mac jobs were observed holding cooperative GPU slots during this numerical stage;
[external-load-observation.json](evidence/external-load-observation.json) records them.
No other owner's processes are signalled. Incidental durations and deployment timings are
not a quiet benchmark, paired cost comparison or throughput claim. This stage tests
numerical contracts, not performance. All owned GPU work is now terminal.

## Remaining work

emmettl/bombcad-work#59 stays open for distinct-case integration and a measured cost model
on an eligible workload; this failed fixed set is not substituted with easier cases.
emmettl/bombcad-work#62 now has an additional flat-case first-phase rejection beyond the
prior terrain/Beirut subset. New emmettl/bombcad-work#79 tracks a prerequisite for reliable
phase diagnosis: capture the **actual signed pressure consumed inside the production
recorder**, with plain/observer parity and exact initial-state/replay controls. Existing
production traces contain recorder/accumulated fields, so host pressure reconstruction or
reinterpretation of recorder-only traces cannot establish that missing evidence.

No label definition, numerical/default policy, comparison tolerance, dataset mask,
training index or production solver source is changed by this experiment.
