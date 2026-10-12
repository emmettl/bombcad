# The slab contest's measured displacement histories

`displacement-histories.json` holds the three measured histories of the ACI 447/370 blast blind
simulation contest's normal-strength slabs, read off Figure 4 of L. E. Schwer, "Blind blast
simulation: a validation effort assessment", *Transactions, SMiRT-23*, Manchester, 2015, Division
III, Paper ID 015: the central displacement of the unloaded face (mm) against time (ms), under
load 1a (slab 2, the slab `blastbench slab` compares), its repeat 1aa (slab 4), and the lower
load 1b (slab 6). The user's copy is on `/Volumes/StudioData/bombcad/data/Schwer2015/`; only
these derived numbers are kept, with citation.

**How.** The figure is a 621 × 605 pixel image in three colours. Per pixel column, the median
height of each curve's colour inside the plot (the legend masked); axes fitted to all the
gridlines (residual 0.09 ms and 0.13 mm); every 0.5 ms, the median over ±0.5 ms, which keeps the
record's noise spikes out (the raw column readings are on StudioData,
`digitise-sources/schwer/fig4-raw.json`). A pixel is 0.13 ms by 0.23 mm.

**Checks.** The peaks read 107.9 mm at 29.5 ms and 112.7 mm at 32.5 ms against the 4.29 in
(109.0 mm) at 29.94 ms and 4.45 in (113.0 mm) at 32.73 ms that Schwer's Figure 5 states. Load
1a's history agrees with `SlabBenchmark.measuredHistory` (read by hand) to 1.0 mm rms, worst
2.4 mm, and with Xu and Lu's plot of it (`Fixtures/XuLu2016`) to 0.9 mm. The lower shot reads a
median of 70.7 mm over 21–29 ms (spikes to 75 mm in the 1 ms medians, 80 mm raw) and 54.1 mm at
the end, as the hand reading's "about 72" and "about 54".
