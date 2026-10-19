kind: fixed

**Parameter sweeps and ensembles no longer keep every run's memory,** 0.5.0's known limitation of
sweeps. Building a solver left it in an autorelease pool that a worker's or a command-line thread
never drains, so runs made one after another kept all their memory: six solvers of 584 MB built in
turn held 2.8–3.2 GB, and `blastbench validate` reached 43 GB on the 36 GB Studio. The app's
parameter sweeps and headless workers, and the ensembles' runs, now build their solvers in a pool of
their own, and six built in turn hold 0–7 MB. Reading a run's cells piled up the same way: each read
of a cell's state, mask, peak or impulse autoreleased its buffer, so a sweep, digest or export
reading every cell added an entry per read until the pool drained (a digest peaked at 445 MB, now
327 MB); the solver now takes those addresses once. Results are bit for bit the same
(`SolverMemoryTests`).
