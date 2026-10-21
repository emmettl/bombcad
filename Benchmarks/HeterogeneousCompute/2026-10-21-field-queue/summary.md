# Mixed field queue: real recovery experiment, 21 October 2026

The bounded `field-queue.py` implementation completes three explicit production-reference
replays across local Metal and the RTX PC. It preserves existing per-case gates and GPU locks,
retries an abruptly terminated attempt, resumes a live worker after controller interruption,
and publishes one content-addressed accepted object per requested case. This is functional
and recovery evidence, not a measured mixed-queue throughput speedup.

## Physical cases and routing

All cases use the repository's synthetic-neighbourhood map: radius 48 m, dx 2 m, height 32 m,
requested end 80 ms, recommended physics and three target channels. A small geographic slope
raster supplies 2,559 geometry records and 2,304 active cut columns for the CUDA case. Calibration exports matching
production Metal references and replays each on CUDA with the existing target/features/mask
gate. All four calibrated cases pass (three uniform masses plus the terrain mass-10 case).

The actual queue selects:

| Case | Allowed backends | Accepted backend | Purpose |
|---|---|---|---|
| queue-m5 | Metal | Metal | abrupt case-worker termination and retry |
| queue-terrain-m10 | CUDA | CUDA | real cut-cell export/solve, busy lock and live-worker resume |
| queue-m20 | Metal, CUDA | Metal | automatic selection using measured cost/availability |

The explicit CUDA-only case exercises the PC path; it is not evidence that CUDA is faster for
these tiny cases. Single calibration samples favor Metal latency. No performance inference
uses the deliberately held busy-PC window or interrupted attempt. Queue estimates are assembled
from measured stage reports, not a validated production fit or an optimal makespan result.

## Recovery sequence

1. A bounded live SSH/Python process acquires the existing training/CUDA lock through the real
   lock helper. It does no GPU computation and releases in `finally`. Another owner would abort
   the test; none is overwritten. The queue leaves the CUDA-only case pending with zero attempts
   while the owner is live, and dispatches available Metal work.
2. The harness verifies the owned Metal worker's command/root identity, stops its own process
   group, terminates it and confirms the group is terminal. This happens during worker startup,
   not a claimed mid-kernel recovery. The failed/unaccepted attempt remains in history; the
   queue retries it and accepts its case once.
3. After the busy owner actually exits, the CUDA worker starts preparation/deployment. The
   controller receives SIGINT while that worker is deploying and exits 130. The independent
   worker's process group is verified live before a new controller is started.
4. Resume observes the same lease/process/attempt and waits; it does not relaunch the active
   CUDA case. It completes successfully and passes the production Metal reference gate.
5. There are three accepted objects: Metal case attempts 2, CUDA case attempts 1, flexible
   Metal case attempts 1. A subsequent run does no new work. Every owned case group is verified
   terminal, not inferred from a pointer or observation timeout.

`integration.json`, controller logs and the complete queue snapshot retain these observations.
All accepted receipts were revalidated, and pinned sources were unchanged after the experiment.
Accepted-case reuse means exactly-once acceptance; an interrupted unaccepted computation may
need to run again after its owned processes are confirmed terminal.

## Publication and admission controls

Unit/process tests cover schema/argument/reference identity, unsupported CUDA physics and
unknown options, invalid numeric options that would otherwise fall back to defaults, memory
bounds, measured-cost planning/spillover, busy/unreachable probes, missing phase receipts,
transient retry, numerical quarantine/backend fallback, retry generations, object/pointer
recovery, corruption and live-descendant/PID-reuse handling. Their producers are explicitly
local orchestration stubs; the real Metal/CUDA evidence is the experiment above.

A stable production Metal format-1 reference, six named feature channels, requested target
channels/shapes and matching physical command are required. Failed gates cannot be cleared by
transient retry. Accepted objects bind the case/contract, backend/source/worker provenance,
comparison, timings and four dataset-file hashes. Files and publication directories are synced
before the atomic object and pointer sequence. Orphan publication is recoverable and rechecked.
No training index or bulk data plan is modified. Full-size #47 terrain/Beirut failures remain
blocked; this new small passing terrain case does not change their admission.

## Timing observations and controls

The optional producer `--phase-timings` receipt records scene preparation, solver setup including
compilation/allocation/initial state, recorder setup, solve and output. Compilation inside Metal
setup is not isolated. The queue also records the outer call, CUDA deployment phases including
upload/retrieval, raw worker compile/solve, comparison and worker-body total before publication.
These are nested intervals with declared clock scopes; do not sum all clocks together.

The three uniform cases' new numerical dataset files and CUDA initial buffer hashes match the
pre-instrumentation executable's results bit for bit (`phase-controls.json`). Timing/metadata
receipts do not change equations, stepping or thresholds. The real CUDA case retains raw-clock
provenance from #64; system clock settings were not changed by this work.

## Retained material and remaining work

- `plan.json`, `contract.json`, `costs.json`: actual constraints, immutable identities and single
  calibration observations. Paths are the actual test paths, not a portable installation plan.
- `queue-state.tar.gz`: complete final queue state/attempts, prepared input, accepted objects,
  requests, process records and logs. It is an audit snapshot; source/path pins apply on resume.
- `references.tar.gz`, `slope.asc`: the three selected physical references and terrain input.
- `calibrate.py.txt`, `terrain.py.txt`, `integrate.py.txt`: exact test scripts. To reproduce choose
  fresh roots and regenerate references/evidence before initializing a new queue.
- `unit.log`, `build.log` and the final repository check log record verification.

#59 remains open for finer Metal setup/compile accounting, complete-cost calibration using queue
telemetry, and larger/repeated queue evaluation. #60 retains CUDA dispatch/control optimization;
#47/#62/#63 retain broader numerical admission. No throughput speedup or automatic training
pipeline is claimed.


An additional isolated CUDA queue tests cached preparation after failure: an owned worker is
stopped only after the validated preparation exists and while its progress is still `prepare`,
before deployment. Its group is confirmed terminal; the retry accepts once with
`preparationCacheHit: true` and the same preparation content identity. All three numerical
dataset files match the main queue's CUDA result byte for byte. The cached producer phase
receipt describes the original export; it is not time spent again by the retry. Evidence and
full state are in `cache-recovery.json` and `cache-queue-state.tar.gz`.

Verification: release build; phase controls; both real recovery experiments; `make check-affected`
passes lint/strict build/scripts/docs, 35 Mac tests in seven suites and 54 PC tests in 12 suites.
CUDA/queue contract tests run 50 tests with four local Torch-dependent skips; the real PC
integration supplies the GPU evidence. Sources, references, accepted object hashes and all
owned groups are rechecked after verification. No training/bulk dataset admission was enabled.
