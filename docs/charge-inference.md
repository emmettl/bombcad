# From what was seen back to the charge

Given when the shock reached observers after an explosion (from videos and audio), and optionally
which façades' glass broke, `scenebench infer-charge` infers the charge: its TNT mass, its place
and, if asked, its height and a clock offset common to the observers, each with its uncertainty.
It is the first step of [Horizons](roadmap.md#horizons) item 5, "from damage back to the explosion",
and it automates what [Beirut, 2020](beirut-2020.md#arrival-times-rigby-et-al-2020) did by hand:
running 0.2, 0.5 and 1.1 kt and seeing which arrivals fit.

**Standing: approximation for the yield and place from arrival times; illustrative for broken
glass.** On Beirut it finds 0.50–0.54 kt (90%: about 0.36–0.85 kt) and Warehouse 12 to within
25–32 m from Rigby et al.'s observers, and 0.57–0.66 kt from Stennett et al.'s six: their own
estimates. Its credible intervals hold the truth as often as they claim on synthetic charges
(below). On charges BombCAD itself ran over a made-up district it finds the place to a metre, and
the yield within 3% once BombCAD's own ratios correct the curves ([below](#against-charges-bombcad-ran)). The glass does not fit with any yield and is
not used for one ([below](#broken-glass)).

```bash
scenebench infer-charge --observers Rigby2020_ESM1_radius_time.csv --centre 35.519042,33.901425 --correction final2-200000/comparison.json,final2-500000/comparison.json,final2-1100000/comparison.json --out posterior.json --samples samples.csv
```

It takes about a second (arrivals only) or half a minute (with 9,000 façades), on the CPU. It prints
its standing, also under `standing` in `--out`'s JSON ([validation](validation.md#the-charge-from-its-arrivals)).
In the app, Simulation ▸ Infer Charge from Arrivals… does the same from arrivals and glass, without
BombCAD's ratios ([using the app](using-the-app.md#inferring-the-charge-from-arrivals)).

## The model

**Forward.** The shock's arrival at range R from a hemispherical surface burst of W kg of TNT is
Kingery–Bulmash's (Swisdak's fits, as `KingeryBulmash` has them), tabulated in scaled distance
R/W^(1/3) and beyond the fits' 40 m/kg^(1/3) carried on at the speed of sound. Sachs scaling
takes the air's temperature (`--temperature`): the time scales with the speed of sound, which
is 2.6% faster at 30 °C than the curves' 15 °C. A height of burst (`--height a,b`) enters as
slant range only, and a clock offset common to every observer (`--offset a,b`) adds to each
time.

**BombCAD's correction** (`--correction`). A run of the scene (`scenebench district-compare`)
gives, at each observer, its arrival over Kingery–Bulmash's: the city's own geometry, its
ground and its grid. Each observer's predicted time is multiplied by that ratio, interpolated in
log yield between the runs given (on Beirut's 0.2, 0.5 and 1.1 kt runs the ratios differ by about
1% between yields, 0.93–1.02 over the observers). The ratio belongs to a run with the charge at
one place, so it holds near that place.

**Observations.** Each arrival is a window, from Rigby et al.'s "best" time back to the frame
before, or `earliest_s` to `latest_s` in a plain CSV. An observer is either an inlier, off the
model by a fraction (the "spread") that is inferred too, with 5 ms of timing on top, or with 5%
chance an outlier, whose time's log is normal about the model's with a standard deviation of 1
(anything up to several times off). The heavy tail matters: Rigby's nearest observer, 85 m out,
saw the shock at 0.27–0.30 s where Kingery–Bulmash has 0.04 s, and with a 30% outlier the fit
moved the charge 100 m to explain it. Each observer's chance of being an outlier is printed.

**Posterior.** Uniform priors on log mass (`--mass-range`, 1 t–10 kt by default), on the place
within `--radius` of the reference (500 m), on the log of the spread (0.5–30%), the height and
the offset; sampled by an affine-invariant ensemble (Goodman and Weare's stretch move), 48
walkers started about the best of 24 Nelder–Mead searches from the best of several thousand
prior draws, 3,000 steps of which the first half is discarded. A brute-force grid over mass,
place and spread gives the same quantiles of log mass as the sampler to 0.01 on six synthetic
charges.

## Beirut

Rigby et al.'s 31 observers (the fireball's points left out), the reference Warehouse 12's centre
(33.901425 N, 35.519042 E):

| Model | Yield, kt TNT: median (90%) | Place off Warehouse 12 (90% within) | Observers off the model |
|---|---|---|---|
| Kingery–Bulmash, 15 °C | **0.54** (0.39–0.85) | 25 m (33 m) | 6.0% |
| the same, the place held | 0.42 (0.34–0.51) | – | 6.2% |
| Kingery–Bulmash, 30 °C | 0.42 (0.31–0.56) | 21 m (29 m) | 5.7% |
| with BombCAD's 4 m runs' ratios, 15 °C | **0.50** (0.36–0.85) | 32 m (35 m) | 5.9% |
| the same, 30 °C | 0.38 (0.28–0.53) | 27 m (29 m) | 5.6% |
| height free, 0–150 m | 0.78 (0.59–0.99) | 17 m (26 m), height 134 m (96–149) | 5.0% |
| clock offset free, ±0.1 s | 1.06 (0.75–1.34) | 19 m (26 m), offset 0.085 s | 5.0% |

Stennett et al.'s six videos (their distances, the place held at the warehouse):

| Model | Yield, kt TNT: median (90%) |
|---|---|
| Kingery–Bulmash, 15 °C | 0.66 (0.50–0.83) |
| with BombCAD's 0.5 kt run's ratios | 0.57 (0.38–0.79) |
| Kingery–Bulmash, 30 °C | 0.53 (0.42–0.64) |

- **It finds Rigby's yield again, and the warehouse.** Rigby et al. gave 0.50 kt (best) and
  1.12 kt (upper) from the same observers, by Kingery–Bulmash with the place known; here 0.54 kt
  with the place free and the warehouse within 25 m, and 0.50 kt with BombCAD's ratios. Stennett
  et al. found 637 t (407–960 t) from their six videos by the same curves: 0.66 kt here. Of the
  published range, 0.2–1.1 kt, the arrivals take 0.36–0.85 kt at 90%.
- **The day's heat lowers it by a fifth.** At 30 °C, as Stennett et al. noted the calculators did
  not allow for, the same arrivals give 0.38–0.42 kt.
- **Nearest observer out.** Audio [1], 85 m out, is an outlier with chance 1.00; the rest under
  0.1.
- **Height and clock are not resolved.** Left free, a height of 134 m or a clock offset of 85 ms
  explains the three nearest observers' lateness (seen at 0.71–0.83 of the model's time, as
  Dewey's lower TNT equivalence close in would have it), and the yield rises to 0.78 or 1.06 kt
  with them. The burst was on the ground; these are what the arrivals alone cannot rule out.
- **Others' yields.** Pilger et al. (2021) give 0.13–2 kt from seismic (0.13–0.34), infrasound
  (about 0.5) and radar damage (0.8–1.1) data; Díaz (2021) 0.6 ± 0.3 kt and Aouad et al. (2021)
  from the fireball; Valsamos et al. (2021) assume 1.1 kt (2,750 t of ammonium nitrate at 0.4)
  rather than infer one; Sadek et al. (2022) quote about 0.5 kt from these.

## Broken glass

`--glass` adds GEER's survey of 9,183 street façades (classes W0–W3; DesignSafe PRJ-3030, read
from its shapefile, each façade at the centre of its segment's bounding box, its outward normal from `Azimuth_N`,
which the layer holds in degrees though its README says radians):
in each 250 m band of distance from the charge, how many façades were damaged (W1 or worse)
against the mean chance the envelope glass model gives a 150 m² façade of the apartments' mix of
panes under Kingery–Bulmash's pulse, side-on, or reflected for a façade facing the charge, as a
beta-binomial (concentration 30), so that neighbours, which break together, are not counted as
independent.

It biases the result rather than tightening it:

- **Free-field loads break everything.** At 0.5 kt the model breaks some pane of almost every
  façade out to 3.5 km (0.97–1.00), where GEER found 0.84 damaged at 0.5–0.75 km falling to 0.05–0.16
  beyond 2.5 km. Some pane of twenty breaks.
- **A city's façades are not in the free field.** In the 0.5 kt Beirut run, the façade strips'
  peaks are 0.72 of Kingery–Bulmash's side-on at their distance (median; 0.30–1.09 between the
  tenth and ninetieth percentiles, by area), falling from 1.06 at 300–750 m to 0.53 beyond 2 km,
  and their impulses 0.57. Taken as a log-normal exposure (`--exposure 0.6 --exposure-spread 0.85`),
  the glass still breaks 0.73–0.99 of façades at 0.5 kt.
- **So the glass wants a small charge, or no exposure fits.** With that exposure and the place
  held, arrivals and glass together give 0.010 kt; free, 0.014 kt and the place 487 m off, at the
  search's edge. The yield it gives moves 2,000-fold over a 30-fold range of assumed exposure
  (0.004 kt at 1, 0.076 at 0.3, 0.84 at 0.1, 9.3 at 0.03, each with a spread of 1): the glass
  alone cannot tell yield from exposure, and GEER's share falls with distance more steeply than
  any one yield's curve.
- This is the [Beirut page](beirut-2020.md#glass-against-the-street-survey-geer-2021)'s finding
  in another form: the glass model breaks more than the survey saw (3.8 times the army's count),
  and GEER's photographs, two months on and some repaired, do not count a broken pane as the
  model does.

`--glass-curve 0.5` prints the bands at a yield, to see the comparison without the inference.

## Against charges BombCAD ran

### Synthetic arrivals

`scenebench infer-charge-study --synthetic 200`: 200 charges of 100 kg to 1 kt (log-uniform),
within 300 m of the reference, each seen by 25 observers at 5–40 m/kg^(1/3), their times
Kingery–Bulmash's off by 5% (normal) and rounded up to a 30 fps frame. The model is the data's, so
this checks the inference:

| | Inside the 68% interval | Inside the 90% interval |
|---|---|---|
| Mass | 0.62 | 0.91 |
| Place (radius about the median) | 0.76 | 0.95 |

The found mass is 0.99 of the true at the median (0.76–1.34 between the tenth and ninetieth
percentiles), and the place 0.23 m/kg^(1/3) off (0.49 at the ninetieth).

### BombCAD's arrivals on a made-up district

`scenebench infer-charge-study --forward`: four charges (0.5, 1, 2 and 5 t) in the streets and
yards of the made-up New District (Fixtures/SyntheticDistrict: 51 blocks on a 100 m grid, a
slope, a hill and a sea), each run by BombCAD with the recommended air, 40 observers 2 m above
the ground 40–350 m out, each arrival (500 Pa above the first sample) rounded up to a 120 fps
frame. Inferred first by Kingery–Bulmash alone, then again with BombCAD's ratios from a run at the
last estimate, until the yield moves under 5% (at most three runs):

| Cells | Kingery–Bulmash alone: found / true | With BombCAD's ratios: found / true | Truth in the 90% interval (alone, then with) | Place off |
|---|---|---|---|---|
| 4 m | 1.95, 1.87, 1.58, 1.58 | 0.87, 0.97, 0.99, 0.98 (1–3 runs) | 0 of 4, then 3 of 4 | 0.7–2.2 m, then 0.1–0.9 m |
| 2 m | 1.43, 1.40, 1.33, 1.27 | **0.97, 1.01, 1.01, 0.99** (1–2 runs) | 0 of 4, then **4 of 4** | 0.5–1.6 m, then 0.2–0.3 m |

(In the order 0.5, 1, 2, 5 t.)

- **Kingery–Bulmash alone finds the place, not the yield.** BombCAD's shock reaches these
  observers up to a quarter sooner than Kingery–Bulmash's (its arrivals 0.73–1.03 of the curves'
  at 4 m, 0.84–1.03 at 2 m, the nearest the earliest), and a bigger charge is the curves' way of
  saying so: 1.3–2 times the truth, the finer grid the nearer. The posterior is confident and
  wrong, as model data have no scatter to widen it (the observers come out 0.6% off the model):
  the spread it infers is the observers', not the model's.
- **One or two runs of BombCAD at the estimate put it right** on 2 m cells: the yield within 3%
  and inside its intervals every time, the place within 0.3 m. On 4 m cells the 0.5 t charge
  (0.5 m/kg^(1/3) a cell) swings between 0.74 and 1.09 of its yield from pass to pass and does
  not settle.
- For an event this means: infer by Kingery–Bulmash, run the scene at the estimate, and infer
  again with its ratios, as `--correction` takes them. On Beirut the ratios move the yield from
  0.54 to 0.50 kt.

## What it cannot do

- **One source, at the surface or at a slant range.** A charge above the ground is taken as a
  surface burst at the slant range: no Mach stem, no height-of-burst curves. Several charges, a
  moving source and an elongated one are not represented.
- **Kingery–Bulmash's TNT.** The yield is TNT-equivalent by arrival times, the far field's
  equivalence: close in, ammonium nitrate (and most explosives) is less like TNT, which is why the
  nearest observers are late.
- **The correction holds near its run's charge.** Its ratios come from a run at one place and
  yield; a posterior far from that place should be rerun there (as the forward study does).
- **Glass is illustrative.** As above: the glass model's breakage and the survey's damage are not
  the same quantity, and no exposure calibrates one to the other.
- **No app sheet yet.** It runs headless only.

## Sources

- Rigby, S.E., Lodge, T.J., Alotaibi, S., Barr, A.D., Clarke, S.D., Langdon, G.S., Tyas, A.
  (2020). Preliminary yield estimation of the 2020 Beirut explosion using video footage from
  social media. *Shock Waves* 30, 671–675. doi:10.1007/s00193-020-00970-z (its electronic
  supplementary table of 38 observations).
- Stennett, C., Gaulter, S., Akhavan, J. (2020). An estimate of the TNT-equivalent net explosive
  quantity (NEQ) of the Beirut port explosion using publicly-available tools and data.
  *Propellants, Explosives, Pyrotechnics* 45, 1675–1679. doi:10.1002/prep.202000227
- Sadek, S., Dabaghi, M., Zimmaro, P., Hashash, Y., O'Donnell, T.M., Stewart, J. (2021). In person
  damage assessment and 360° photo collection and analysis, GEER – August 4, 2020 Beirut Port
  Explosion. DesignSafe-CI. doi:10.17603/ds2-rh78-ak38 (ODC-By), and GEER-070 (2021),
  doi:10.18118/G6C96C.
- Sadek, S. et al. (2022). Impacts of 2020 Beirut explosion on port infrastructure and nearby
  buildings. *Natural Hazards Review* 23(2), 04022008. doi:10.1061/(ASCE)NH.1527-6996.0000550
- Valsamos, G., Larcher, M., Casadei, F. (2021). Beirut explosion 2020: a case study for a
  large-scale urban blast simulation. *Safety Science* 137, 105190. doi:10.1016/j.ssci.2021.105190
- Pilger, C. et al. (2021). Yield estimation of the 2020 Beirut explosion using open access
  waveform and remote sensing data. *Scientific Reports* 11, 14144. doi:10.1038/s41598-021-93690-y
- Díaz, J.S. (2021). Explosion analysis from images: Trinity and Beirut. *European Journal of
  Physics* 42, 035803. doi:10.1088/1361-6404/abe131
- Aouad, C.J. et al. (2021). Beirut explosion: TNT equivalence from the fireball evolution in the
  first 170 milliseconds. *Shock Waves* 31, 813–827. doi:10.1007/s00193-021-01031-9
- Swisdak, M.M. (1994). Simplified Kingery airblast calculations. 26th DoD Explosives Safety
  Seminar.
- Goodman, J., Weare, J. (2010). Ensemble samplers with affine invariance. *Communications in
  Applied Mathematics and Computational Science* 5(1), 65–80.
