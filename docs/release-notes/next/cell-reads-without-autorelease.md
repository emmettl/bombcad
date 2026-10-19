kind: fixed

**Reading a run's cells no longer piles up memory.** Each read of a cell's state, mask, peak or
impulse went through `MTLBuffer.contents()`, which autoreleases its buffer, so a sweep, digest or
export reading every cell added an entry per read to the thread's autorelease pool until it
drained: a digest's resident memory peaked at 445 MB, now 327 MB. The solver now takes those
addresses once (`SolverMemoryTests`); results are bit for bit the same.
