kind: added

**Watch the blast wave sweep a district live, and drag the charge to move it.** Simulation ▸ Show
Live Blast Wave (⌥⌘B) draws the front before any run: when it arrives, how strong it is, and the
shadows behind buildings. A bar under the view has play, scrub and speed controls, and the wave
follows the charge as it is dragged, in tens of milliseconds. It is an estimate, not a run:
Kingery–Bulmash along the shortest paths round and over buildings, fitted to BombCAD's own 4 m
district runs. It is illustrative. On Beirut's runs, which it was not fitted to, 91% of cells in
sight and 68% behind buildings came within ×1.25 of the runs' peaks, and arrivals beyond 200 m
were 0.4–5% out on average. Close in behind buildings it reads high
([the live wave](../../live-wave.md)). Headless, `scenebench field-export --arrival` records a
run's arrivals, and `blastmodel live-wave-judge` judges the wave against them.
