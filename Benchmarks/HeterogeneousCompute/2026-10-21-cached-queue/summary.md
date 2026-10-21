# Cached CUDA retry scheduling — 21 October 2026

A pending retry with verified prepared input now avoids the Mac GPU preparation
capacity requirement. CUDA-only cached dispatch does not probe Mac GPU slots;
PC availability, VRAM checks, shared training/simulation lock, worker validation
and numerical admission remain authoritative. Fresh preparation keeps the existing
Mac GPU checks. A Metal alternative still requires Mac observations.

An optional job-level `cachedCudaCosts` uses separately pinned measured terms.
Without it, a cached retry retains the fresh estimate conservatively. Dispatch
records the selected duration and prepared object; running attempts retain that
selected estimate. The controller verifies case/contract identity and all prepared
file hashes before choosing cached resources/costs. A directory's existence is
insufficient. Corruption fails closed; the worker revalidates and acquires actual
locks, including a Mac slot if a missing cache must be regenerated after dispatch.

## Real recovery controls

Three independent queues replay the existing uniform 10 kg, 48 × 48 × 16-cell
first-phase case. For each queue, an explicit fault wrapper runs the real worker
in its own process group and reports PC unavailability on its second availability
probe, after real Metal export/validation. This is a synthetic deferral, not an
external user's workload, and it performs no PC deployment. All other code and
first PC observations are real. The wrapper, marker and terminal outcome are retained.

Each normal controller then resumes that cache. Its Mac GPU probe is replaced by
an assertion that fails if called; PC probes, deployment and worker locks remain
real. All three CUDA outputs pass the production target gate and publish once.
Each queue has exactly two attempts (one deferred, one accepted); a second resume
reuses the accepted object. Numerical files match across all three CUDA outputs.
No training index or broader field-generation admission changes.

Trial 0 retains the prior fresh-worker estimate. Trials 1/2 pin trial 0's observed
cached worker-body duration as their separate retry estimate. This one-sample
calibration excludes controller/publication and is **not** a complete cost model.
The first estimate comes from the prior small queue cost report, also scoped to
worker body. These are functional scheduling controls, not comparative performance
or contention measurements. The Mac was not artificially filled with GPU jobs.

| Trial | Controller completion, s | Worker body before publication, s | Cached preparation, ms | Selected estimate, s |
| --- | ---: | ---: | ---: | ---: |
| 0 | 11.741 | 10.966 | 5.933 | 9.283 |
| 1 | 9.432 | 8.688 | 4.498 | 10.966 |
| 2 | 9.502 | 8.788 | 5.139 | 10.966 |

The cached preparation column is the existing `prepareSeconds` scope: generation
and cache-existence selection, ending before common hash/schema verification.
Those later checks remain in worker-body/controller intervals; the column is not
the total cache-use cost. Variability exceeds this narrow interval; no throughput
improvement is claimed.
Repeated complete-cost calibration and larger representative queues remain in #59.

## Reproduction and validation

study.py and defer-worker.py are exact run-specific controllers, not general host
management tools. study.json retains full accepted receipts, deferral outcomes,
dispatch identities, estimates and completion intervals. state.tar.gz retains all
three immutable plans/contracts, prepared inputs, attempts, accepted datasets and
logs. Plan/source/input hashes remain frozen per queue. The coordinating PC session
reported no reservation or timing-sensitive work before the controls.

Tests cover cached-only dispatch without Mac probing, fresh Mac capacity, PC busy
and VRAM rejection, corrupted bytes, selected running estimates, pinned cost
identity, invalid costs and timeout bounds, plus existing gate/recovery controls.

`make check-affected` passed: strict build without warnings, lint/scripts/docs,
68 CUDA/queue/profiler tests (four local Torch skips), seven selected Mac tests
and 36 PC tests. All six owned worker groups are terminal; PC lock absent, GPU
0%/912 MiB at handover. All 12 archived accepted dataset files match their
content-addressed receipts.
