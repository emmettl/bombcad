kind: fixed

**On the mapped start, glass breaks and envelope histories are timed from detonation** (also in
0.5.1). The mapped start begins a run some time after detonation, but each pane's and wall's clock
in venting, and the clock the envelope component histories are binned by, still started at zero:
a pane broken by the blast recorded its break that much early, and a history's window start and
bins ran behind the run's time. They now start with the run's clock, as the GPU's own clock
already did; runs on the balloon start are unchanged ([building envelopes](../../building-envelopes.md)).
