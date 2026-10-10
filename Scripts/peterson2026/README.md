# Peterson et al. (2026): derived peaks

`peaks.json` holds, for each of the sixteen beams with a DAQ record, the largest impact force
and support reactions, when they came, and the impulse to 10 ms, as `ImpactBenchmark.petersonTests`
uses them.

**Source.** V. Peterson, *High-speed camera dataset from impact tests on reinforced concrete
beams*, Mendeley Data, doi:10.17632/kn28g6dbj5.3, licensed
[CC BY 4.0](https://creativecommons.org/licenses/by/4.0/); described in V. Peterson, *Data in
Brief* 65, 112487 (2026). The tests are reported in V. Peterson, J. Magnusson, M. Hallgren and
A. Ansell, "Shear-type failure of deep, short and slender impact-loaded RC beams",
*International Journal of Impact Engineering* 208, 105539 (2026), and Peterson's KTH thesis
(2026). `peaks.json` is derived from the records and shared under the same licence; the records
themselves are not copied here.

**How.** `extract.py` reads the MATLAB 5 files with `readmat.py` (numpy and zlib; scipy and h5py
were not available), finds each impact where the striker's deceleration, smoothed over 0.5 ms,
first passes 1,000 m/s², takes each channel's offset off as its mean over the 50 ms before, and
smooths the impact force (70 kg times the striker's deceleration) and the reactions by a centred
moving average of 0.42 ms, as `blastbench impact --force` reads the model's. Run it with the
records at the path at the top of `extract.py`:

```
python3 extract.py 0.42 > peaks.json
```

**Caveats.** The dataset's readme says beams D-04d-S90-2 and D-04d-S45-2 have no DAQ record, but
the records present are filed under those names (and none under D-04d-S90-1 or D-04d-S45-1); they
are taken as named. The striker trace filed as D-04d-S90-2 implies five times the striker's
momentum by 10 ms and is not used for the impact force. Peterson's own low-pass filter's cut-off
is not given, so peaks smoothed differently differ: unsmoothed, the impact forces are 250–420 kN.
