# Resumable Metal/CUDA field queue

`Scripts/cuda/field-queue.py` runs a bounded, explicit queue of reference replays on this Mac's
production Metal solver and one configured NVIDIA PC. It supports the recommended field-export
configuration with fixed uniform or static-terrain geometry, including optional first-phase
targets and balloon initialization. Every case needs an existing matching production Metal
reference. The queue does not publish a training index or expand a field-generation plan.
The terrain/Beirut batch-admission failures in [the CUDA backend](cuda-backend.md) remain gated.

The [retained integration](../Benchmarks/HeterogeneousCompute/2026-10-21-field-queue/summary.md)
runs three real cases, including a CUDA static-terrain case, and exercises busy-worker handling,
a terminated attempt, controller interruption, resume and accepted-object reuse. It establishes
correctness and recovery, not a mixed-queue throughput speedup.

## Running a queue

From the repository root, with an existing `scenebench`, SSH alias and PC CUDA environment:

```sh
swift build -c release --product scenebench
python3 Scripts/cuda/field-queue.py init --plan plan.json --queue /path/to/new-queue
python3 Scripts/cuda/field-queue.py run --queue /path/to/new-queue
python3 Scripts/cuda/field-queue.py status --queue /path/to/new-queue
```

The controller itself runs directly; individual GPU preparation/Metal commands take `gpu-slot`.
CUDA takes the existing `bombcad-ml/lock` shared with training. Availability probes are advisory;
the existing locks and the CUDA worker's actual memory check remain authoritative. An unknown
or starting PC lock is busy. A dead owner/previous boot can be reported stale, but the queue's
probe never deletes it; acquisition uses the existing lock helper.

Ctrl-C stops the controller and leaves independent case workers running. Resume the same
queue to observe them. Their leases, boot/session identity, command nonce and live process
groups are checked; a surviving descendant still counts after the session leader exits.
Accepted cases are not dispatched again. `--once` performs one dispatch pass; `--poll` controls
observation cadence, and `--max-seconds` bounds the controller's watch interval. These do not
cancel active workers. Exit 0 means all cases accepted, 1 means remaining cases exhausted or
blocked, 75 means pending/active work remains, and 130 means the controller was interrupted.

Transient failures return to the queue with backoff, up to `maxAttempts` per backend (default
three). `retry --queue DIR` starts a new transient-retry generation for exhausted cases,
retaining history. A numerical, format, capability or declared-memory failure blocks that
backend for the case; another allowed backend can still run. Retry does not erase a failed
numerical gate. Each attempt retains its logs and outcome, including failed/unaccepted results.

## Plan contract

The plan has format `bombcad-field-queue-1`, purpose `reference-replay`, a `scenebench` path,
optional `gpuSlot` path, optional CUDA settings and one to eight jobs. The
[actual experiment plan](../Benchmarks/HeterogeneousCompute/2026-10-21-field-queue/plan.json)
is a complete example; its recorded absolute paths need matching local inputs/references.
For a small uniform case, the schema is:

```json
{
  "format": "bombcad-field-queue-1",
  "purpose": "reference-replay",
  "scenebench": "/absolute/path/to/scenebench",
  "cuda": {"host": "bombcad-pc", "cacheDir": "bombcad-cuda/ptx-cache"},
  "maxAttempts": 3,
  "jobs": [{
    "id": "case-1",
    "arguments": ["--osm", "/absolute/path/to/synthetic-neighbourhood.geojson",
      "--centre", "0.00045,51.50028", "--radius", "48", "--dx", "2", "--height", "32",
      "--mass", "10", "--until", "0.08", "--above", "1", "--id", "case-1", "--first-phase"],
    "reference": "/absolute/path/to/matching-metal-reference",
    "physics": "recommended-uniform",
    "backends": ["metal", "cuda"],
    "metalGB": 1,
    "cudaBytes": 50000000,
    "costs": {
      "metal": [{"report": "/absolute/path/to/costs.json", "keys": ["case-1", "metalCaseSeconds"]}],
      "cuda": [
        {"report": "/absolute/path/to/costs.json", "keys": ["case-1", "prepareSeconds"]},
        {"report": "/absolute/path/to/costs.json", "keys": ["case-1", "deploymentSeconds"]},
        {"report": "/absolute/path/to/costs.json", "keys": ["case-1", "compareSeconds"]}
      ]
    },
    "timeoutSeconds": 120
  }]
}
```

Use measured cost reports: each `keys` list selects a finite seconds value from its JSON report;
terms are summed into an estimate and the evidence file is pinned. Use complete costs on a
common observer clock, including preparation/transfers/comparison where measured. Worker-only
solve time is insufficient. The initial integration uses single calibration samples, so its
estimates have not established a speedup or a production scheduling fit; actual case receipts
provide fuller observations for subsequent calibration.

The controller uses a greedy earliest-completion plan across the remaining jobs, reserving
virtual backend time for earlier assignments. This can spill a later job to an idle PC when
the predicted Mac backlog exceeds its complete PC cost. It does not force every pending job
onto the PC. It runs at most one case worker per backend; a CUDA worker's Mac preparation
also uses a real `gpu-slot`, with its own declaration. External waiting jobs and pressure are
observed conservatively, and actual lock acquisition can still race a preflight observation.

Resource probes run only when a pending case can dispatch. A Metal-only eligible set does
not query the PC; a queue containing only running cases or cases in retry backoff does not
probe either host. A runnable CUDA alternative still triggers the PC availability/memory
check, even when Metal is likely to be cheaper. The latest dispatch receipt retains its own
observation timestamp; it is not continuously refreshed while no dispatch is possible.

A [three-repeat four-case study](../Benchmarks/HeterogeneousCompute/2026-10-21-queue-costs/summary.md)
measures controller-to-completion time as well as accepted worker-body time. With these tiny
cases, Metal-only median falls from 3.475 s to 1.360 s after removing irrelevant probes;
automatic selection uses Metal for every case (3.518 s), while a forced two-Metal/two-CUDA
split takes 21.142 s. The automatic policy still pays for synchronous PC observations. This
is a small warm-cache overhead study, not evidence for broader CUDA throughput or a complete
cost model. Its observed-cost report excludes controller overhead and publication explicitly.

Only the field-export options explicitly recognized by the queue are accepted. Output paths,
CUDA export flags and phase timing are supplied by the worker. Copy the requested physical
options from the reference's metadata, removing its output/diagnostic options. Unknown options
such as `--refine` are rejected before dispatch; the queue does not pretend that field-export
supports additional physics. Use the existing full Metal workflows for physics outside this
field interface. `recommended-static-terrain` requires `--dem`; uniform excludes it.

A stable `bombcad-field-1` Metal reference is required: matching physical arguments, six named
input channels, the requested two/three named target channels and consistent NPY shapes.
A CUDA result cannot be its own production reference. Candidate schema/arguments, features,
masks and targets are checked before acceptance with the existing `0.05 + 0.002*abs(reference)`
per-valid-target gate. No threshold or first-phase policy is changed.

Memory declarations are checked against the reference's Metal allocation and the portable
CUDA lower bound. After CUDA preparation, the exported buffers/geometry are validated and the
actual CUDA requirement must fit the declaration and 80% of observed free VRAM. The worker
rechecks actual free memory under its GPU lock. Memory shortage never changes grid/precision.

## Durable state and accounting

Initialization freezes executable/resource hashes, worker/controller/source identities, input
and reference hashes, evidence files and slot policy. A queue belongs to one controller host.
Kernel-math probes and forced-memory overrides are cleared. The observed Git revision is
context rather than a build attestation; dirty working trees are marked in producer metadata.
The executable, runtime resources and worker hashes identify the code actually selected.
Change an external input, reference, binary, worker or controller only by creating a new queue.

Each case has independent attempt directories and a lease. Validated CUDA preparation can be
reused after a transient/deferred attempt, with its full inventory/content identity checked.
An accepted object is addressed by the canonical receipt's SHA256, which binds the four
standard dataset-file hashes, case/contract, backend/worker provenance, comparison and timings.
Data and directories are synced before atomic object publication; the accepted pointer is
written afterward. An orphan object from interruption between those operations is recovered
and revalidated. Corrupted bytes or conflicting accepted objects fail closed.

`state.json` summarizes current cases; `dispatch.json` retains the latest availability and
virtual schedule. Attempts retain request, launch/process identity, progress, logs and outcome.
`objects/HASH/receipt.json` and `dataset/` contain accepted evidence. None is automatically copied
into a model-training dataset.

`scenebench field-export --phase-timings` writes an opt-in `phase-timings.json`: scene preparation,
solver setup **including** shader compilation/allocation/initial state, recorder setup, solve
and output. With setup measurement enabled, `solverSetupPhasesSeconds` additionally separates command-queue creation, shader-library loading/building, eager pipeline creation, buffers/texture allocation, initial uniform state and scenario loading. These host intervals are nested within setup, not additive top-level costs. Driver cache lookup and compilation may occur in library/pipeline creation; lazy work stays in the later phase that triggers it. Queue receipts embed these
phases, the outer Metal/prepare call, deployment upload/process/retrieval phases, raw worker
compile/solve and comparison, plus total worker-body time before publication. Producer phases
exclude process startup/slot wait/receipt writing; the outer calls include startup and slot
wait. On a preparation-cache hit, producerPreparation describes the original export, while
the retry records its own outer time. Nested timings and different clocks must not be summed twice. See
[the clock audit](cuda-backend.md#raw-elapsed-clock-correction).

[#59](https://github.com/emmettl/bombcad-work/issues/59) remains open for complete cost modelling
and broader queue/performance evaluation. [#60](https://github.com/emmettl/bombcad-work/issues/60)
retains dispatch/control optimization. Repeated quiet runs are needed before a throughput claim;
[#47](https://github.com/emmettl/bombcad-work/issues/47) still gates broader CUDA generation.
