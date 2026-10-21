The CPU sweep runner sends `rsync --delete` into the shared `~/bombcad-sweeps/src` checkout before the remote worker acquires `~/bombcad-sweeps/lock`. Input files are also copied before that lock. A second invocation can therefore overwrite the first owner's source/input files while its build or cases are running, even when the second worker subsequently reports that the lock is taken.

Evidence in public emmettl/bombcad at 0e135ad4: `Scripts/remote-sweep.py` `run()` sends sources/inputs before invoking `serve-run`; `serve_run()` acquires the lock only on entry. This is a source-inspection finding; no destructive concurrent reproduction was performed. Current receiver-fixture work checks actual ownership before sending and coordinates its bounded CPU run, but that advisory check does not remove this race.

Feasible next step: stage each invocation's immutable source and inputs in a unique directory, then select/build it under the host lock, or reserve the host with a verified owner token before any shared mutation. Preserve boot/process ownership, stale-lock handling, bounded wait, cancellation and reusable build-cache semantics. Apply the same audit to the test lane and retrieval paths.

Acceptance:
- A second invocation cannot change an active owner's checkout or inputs, including with `--wait 0`.
- Safe concurrent-controller tests verify ordering and exact snapshot identity without racing real production jobs.
- Interrupted/waiting controllers do not delete another owner's lock, results or staging.
- A resumed invocation builds/runs its own pinned snapshot; both ordinary run and test lanes remain functional.

Related: emmettl/bombcad-work#59 distributed scheduling and integration; emmettl/bombcad-work#39 CPU/portable execution. This is separate from numerical portability in emmettl/bombcad-work#62 and emmettl/bombcad-work#63.
