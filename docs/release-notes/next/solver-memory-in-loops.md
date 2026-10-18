kind: fixed

**Sweeps and ensembles no longer keep every run's memory.** Building a solver left it in an
autorelease pool that a worker's or a command-line thread never drains, so runs made one after
another kept all their memory: six solvers of 584 MB built in turn held 2.8–3.2 GB, and
`blastbench validate` reached 43 GB on the 36 GB Studio. The ensembles' runs and the app's own
runs (its parameter sweeps and headless workers) now build their solvers in a pool of their own,
and six built in turn hold 0–7 MB (`SolverMemoryTests`). Results are unchanged. What in building
a solver is autoreleased is still being traced; other loops that build solvers in a tool of their
own should build each in a pool until then.
