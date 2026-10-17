# Monk and Clubley's annealed windows in the air blast tunnel

`windows.json` holds the window trials of S. Monk and S. K. Clubley (University of Southampton),
*Quantifying the influence of aspect ratio on window failure when subject to long-duration blast
loading*, a paper for ISIEMS 2017 (eprints.soton.ac.uk/413793). The paper is British Crown Owned
Copyright 2017/AWE, with no open licence, and its acknowledgements say the trial data remain the
property of the UK Ministry of Defence. As for [Keys2016](../Keys2016/README.md), only numbers are
kept: those of its tables and text, and values read off its figures, used only to compare the
model. The paper itself is on StudioData (`envelope-damage/sources/`), not here.

**The trials.** Eight trials in the 10.2 m section of the air blast tunnel at MOD Shoeburyness,
each with two identical panes on two sealed steel cubicles facing the wave: 4 mm annealed glass,
0.89 m² a pane, at aspect ratios 1:1, 1:1.3, 1:1.7 and 1:2 (table 1; `glass_m` is the pane,
`opening_m` the frame's clear opening). Each pane sat between 3 mm foam strips in a steel frame
bolted against 7 mm spacers, a 65 mm bite (figure 6), which the authors call rigid.

**The load.** Free field 13.4 ± 0.1 kPa, 690 ± 7 kPa·ms over a 100 ± 1 ms positive phase;
reflected on the cubicles' faces 38.8 ± 1.3 kPa (the peak of a spiky record) and 724 ± 8 kPa·ms in
all, "approximately constant until after glass failure". `reflectedPressure.allTrials` is figure
8's main plot, all sixteen records overlaid, read column by column at 0.28 ms: the median, lowest
and highest dark pixel of each column, kPa, to 10 ms. `oneTrial` is the figure's inset, one
record over 0–20 ms traced at 0.15 ms and given every 0.2 ms to 8 ms. A pixel is 0.13 kPa on the
main plot and 0.5 kPa on the inset. Integrated to the break, the median gives 91–114 kPa·ms where
table 2 gives 97–122, 5–7% less (the inset 8% less): the table's impulses were taken from each
record by the authors, and the read median sits a little under the records' spikes.

**The breaks.** Every pane broke, all within 4 ms of the wave's arrival. Table 2 gives, for each
aspect ratio, the mean and 90% confidence half-width of the centre's deflection at the first
crack, the break time and the reflected impulse to it, from high-speed video (75,000 frames a
second; errors 0.01 ms and 0.5 mm). Trials 1 and 2 lost their break records to a gauge fault, so
twelve panes are timed; the paper says two remain at 1:1 and 1:1.3 and four at 1:1.7 and 1:2,
though by table 1 trials 1 and 2 were both 1:1. `breakTimes_ms` is the twelve read off figure 9b,
whose crosses were found by colour at 600 dpi (a pixel is 0.004 ms); overlapping crosses are
split by fitting a single cross's profile. Their means match table 2's to 0.01 ms.

`Scripts/monk-clubley/digitise.py` reads the figures again into this file (numpy, and poppler's
`pdfimages` and `pdftoppm`):

```sh
python3 Scripts/monk-clubley/digitise.py <paper.pdf> Fixtures/MonkClubley/windows.json
```

`GlassMeasurementTests` runs the one-way glass model on these loads; see
[Validation](../../docs/validation.md#window-glass).
