# Metal setup accounting — 21 October 2026

The optional field-export phase receipt now separates command-queue creation,
shader-library loading/building, eager compute pipelines, shared buffers/private
visualization texture, initial uniform state and scenario loading. These intervals
are nested within the existing outer solver setup duration. Shader and pipeline
intervals include host work and driver cache lookup or compilation; they do not
measure pure compiler time. Lazy work remains in the later phase that triggers it.
No solver arithmetic or dispatch order changes.

## Controls

Four existing 48 × 48 × 16-cell replay cases (uniform 5/10/20 kg and cut-cell terrain
10 kg) were each exported with and without timing, in Metal execution and CUDA
preparation modes, three paired repetitions with alternating order: 48 exports.
Every pair has identical NPY hashes, including CUDA initial-state/buffer exports.
All 24 Metal exports additionally match the pre-existing production reference NPY
files bit for bit; reference-audit.json retains that independent check.
Untimed exports write no phase receipt; all 24 timed receipts contain six finite,
nonnegative subphases whose sum fits within the outer setup interval. Existing
producer receipts without subphases remain readable. Queue validation rejects
missing/invalid subphase fields, nonfinite/negative/bool values and over-counting.

The Mac gpu-slot protects each export (1 GB declaration); slot snapshots are
retained per run. These are small warm-driver-cache accounting controls, not a
cold-compilation study or a throughput improvement. No PC workload was launched.
The existing gates and reference-replay admission policy remain unchanged.

## Observed median host milliseconds

Medians pool the 12 timed observations per mode across these four small cases;
use study.json for individual cases and ranges.

| Subphase | Metal | CUDA preparation |
| --- | ---: | ---: |
| buffersAndTextureSeconds | 0.093 | 0.093 |
| commandQueueSeconds | 0.434 | 0.439 |
| eagerPipelinesSeconds | 2.781 | 2.734 |
| initialUniformStateSeconds | 4.416 | 4.413 |
| scenarioLoadSeconds | 0.671 | 0.653 |
| shaderLibrarySeconds | 3.397 | 3.439 |

Initial uniform state includes actual initialization work; scenario loading can
also trigger specialization and uploads. Do not interpret allocation alone as
all setup, nor add nested subphases again to complete job cost. Complete scheduling
costs still require slot waits, preparation, transfer, process startup, comparison
and publication/controller overhead. #59 remains open for those costs and larger
queues; this checkpoint supplies finer observations rather than a fitted scheduler.

## Evidence

study.py is the exact run controller, study.json retains arguments, executable
hash, per-run slot snapshots, numerical hashes, outer intervals and all receipts.
exports.tar.gz retains all numerical outputs and logs. Paths are run-specific.
Validation and source identities are retained in manifest.json and check.log.

Validation completed: release build, strict build without warnings, lint, scripts
and docs checks; 63 CUDA/queue/profiler tests (four local Torch skips); 456 Mac
tests and 186 PC tests; all 42 digest variants across six sets bit-identical to
base 25736353. Queue consumer accepted all 24 real nested receipts; all 120
archived numerical files match their recorded hashes.
