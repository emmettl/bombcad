# CPU sweep snapshot ownership and recovery

Fix for emmettl/bombcad-work#68. Previously a controller transferred sources and tools into
shared paths before its worker took the host lock. A second controller could change an active
build's source even if it later returned “taken”. Results keyed only by sweep name could also
be replaced by a later invocation before retrieval.

## Resulting protocol

Every remote run/test has a fresh UUID directory under `bombcad-sweeps/staging`. Sources,
inputs, tools and the request are private to that invocation. Local before/after transfer
identity checks detect concurrent edits; the host verifies the received snapshot before
activating its source in the reusable build checkout under ownership. The existing Swift
build cache is retained. No other invocation's staging or results is deleted.

Source/tool manifests exclude generated build/Git/cache metadata. Input and result payload
manifests include every declared entry, even names such as `dist`, `.build` and `__pycache__`.
Regular-file bytes/modes, directory identity and supported internal links are checked; external
links and ambiguous input basenames are refused. Requests are bound to their manifests.

Lease transitions and stale reclamation are serialized by a short filesystem mutex. Boot and
live non-zombie process-group ownership protect orphaned children after parent death. On
TERM/HUP/INT the worker signals and drains only its own group before unlocking. If forced
group termination is needed, it kills itself too and leaves the lease for recovery only after
the group is dead. Wait deadlines use a monotonic clock.

Run completion receipts bind the resulting files. Recovery verifies them on the host and after
retrieval, refuses an existing local destination, and does not replace an explicit worker
refusal with an old success receipt. An SSH disconnect can recover a completed result only
when the receipted bytes verify. `resume HOST ID` sends no current sources/inputs and reuses a
completion without repeating work. A staged invocation that never began can run its retained
snapshot; interrupted partial work is preserved and refused for automatic replay. A fresh
invocation is required for an explicit retry of partial work.

The run/test interfaces and local result naming remain. `--here` retains local, unflattened
input semantics. All clients sharing this checkout must use the revised protocol: an older
client that directly overwrites shared sources before locking cannot be made safe by a new
receiver alone. Staging is retained for inspection/recovery and has storage/transfer costs;
automatic cleanup or immutable-snapshot transfer reuse is not claimed here.

## Verification

The 21 deterministic/local process controls include:

- Staging B while A holds the cache cannot change A's source, input or result. B returns taken,
  then runs its original B snapshot after local inputs have changed again to C.
- Completed recovery does not rebuild; interrupted partial tests do not silently replay.
- Input/request/result tampering, external links, ambiguous/reserved paths, existing output,
  failed retrieval and missing copied bytes refuse success.
- A successful checksummed completion can recover after a simulated SSH disconnect; an explicit
  refusal cannot be overridden by its receipt.
- Two real isolated controllers contend for the same stale lease in three trials: exactly one
  wins each time. TERM cleanup and live orphan protection are also exercised with synthetic
  local process groups, never production jobs.
- Source exclusions do not hide payload data, and lock waiting uses its bounded monotonic
  deadline. Local input compatibility is retained.

The separate final-source forced-stop control gives its child an explicit TERM-ignore handler.
The worker exits by SIGKILL, its lease remains, and stale recovery removes it only after no
live group member remains. No PC or production process is targeted by that control.

Real PC controls exercise normal CPU run/test lanes, cached recovery, changed local inputs,
existing-destination refusal and checksum-bound output/input corruption refusal and restoration.
Only files in these completed, owned test invocations were altered. Final controls include
declared input trees with cache-like names and a result at `dist/__pycache__`; both are pinned.
The CPU fixture outputs agree exactly with the earlier PC receiver-fixture study. These are
repeated protocol probes, not independent physical cases or a throughput benchmark.

Earlier protocol candidates are retained with their exact source hashes and receipts. An early
local cleanup test exposed the macOS `ps` observer counting itself as an owned child; that was
corrected before PC deployment. Input/result exclusion behavior was separately probed before
and after the payload/source split. The final-source controls and repository validation are
reported separately from those development observations.

## Evidence and scope

`audit.json` and `state.tar.gz` retain the four protocol candidates, requests/manifests,
completion/retrieval receipts, exact results and logs. Candidate source copies identify the
actual producing protocol, rather than treating every candidate as the final implementation.
`smoke-payload.py` is the final real-run control; `forced-stop.py` is the isolated local control.
The live CPU source staging directories remain on the PC for explicit recovery; the archive
retains their manifests and results rather than copying whole project trees into Git again.

The fix changes CPU dispatch/ownership/recovery, not the GPU solver, numerical defaults,
dataset masks, phase labels, admission tolerances, training index or host services. Numerical
portability remains tracked separately by emmettl/bombcad-work#62 and emmettl/bombcad-work#63;
broader generation remains gated by emmettl/bombcad-work#47.

Final validation: `make check-affected` passed (strict build without warnings, lint/scripts/docs,
71 CUDA/queue tests with four local Torch skips, 21 runner controls, seven selected Mac tests
and 36 PC tests). All 21 runner controls also pass on the PC Python/Linux runtime. The forced
TERM-ignore control passes separately on both platforms. Recovery of the exact final staged
test completion is cached and matches the final published protocol source hash.

The candidate archive verifies all 117 file instances (1,016,646 bytes). Final integration,
Linux process controls and final test recovery receipts are retained as separate files, bound
by the artifact manifest. Candidate-producing source copies remain distinct from
`protocol-published.py.txt`; extra preflight and nonblocking transition checks were added
after the earlier real-run candidates and validated by the final test lane and controls.

Integration: rebased onto `4543c5ce` (concurrent optional learned peaks and close-call
refinement), then repeated `make check-affected` successfully: 21 runner controls, 39 selected
Mac tests, 68 PC tests and 71 CUDA/queue tests (four local Torch skips), plus strict build,
lint/scripts/docs. All 21 controller controls and forced cleanup also pass directly on Linux
against this exact final protocol source; its staged test completion is recovered without replay.

A real temporary rsync fixture reproduced same-size/same-mtime cache activation refusing
the new bytes. Activation now uses checksums before final SHA verification; the fixture
copies the new source correctly and retains `.build`. The earlier refusal is retained in
`unit-cache-before.log`; no wrong source was built. Candidate numerical outputs still refer
to their recorded pre-integration sources rather than this later application tree.


Final rebase onto 3afdd0c9 (independent wall-convergence CLI/docs): combined strict build passed with no warnings and documentation links passed. The full affected suite above was run on 4543c5ce; runner and CPU model code were unchanged by the intervening commit.

Additional rebase onto 0c79c820 (learned field download/app changes): combined strict build passed with no warnings and documentation links passed; no CPU runner changes in this upstream commit.
