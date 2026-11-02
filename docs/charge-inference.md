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
not used for one ([below](#broken-glass)). A small network reads the charge from buildings a user
marks, in milliseconds, as the full posterior on the quick estimate's chances would
([below](#the-charge-from-marked-damage-learned-1-november-2026)): illustrative, and on Beirut right
from its stone walls and far too low from its glass.

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

## Damage on the scene's own buildings

`ChargeInference.SurrogateDamage` weighs the glass seen on a scene's own buildings, side by side,
with the façade load surrogate as the forward model (roadmap Horizons 5; stages 1 and 2 of the
plan, 20 October 2026). Where `--glass` loads every façade with Kingery–Bulmash's free field, this
loads each side as the surrogate does from the place being weighed, with the shielding and facing
that place gives it.

**How.**
- **Features.** Each observed side's features (its distance and facing, what stands between it and
  the charge) are worked out once, for charges on a square grid of places 20 m apart over the
  search disc. At a place between them, each side's log peak and log impulse at the yield weighed
  are blended from the four nodes round it.
- **Breakage.** Each glazing mix's chance that some pane breaks is tabulated per square metre of
  façade, by the pulse's log peak, log duration and rise: the log chance that none breaks grows
  with the panes, so one table serves every side's area. The chance is taken over a log-normal
  factor on the load: the surrogate's scatter by scaled distance, and the glass strength's (0.25).
- **Likelihood.** Each side is weighed on its own, broken or whole against its chance, held 0.02
  from 0 and 1 (`damagePerSide`); or by bands of distance, as the glass is.
- **Cost.** On the made-up district (136–192 sides seen), the features and tables take 1–5 s and
  an evaluation 0.05–0.1 ms, so a full posterior (48 walkers, 3,000 steps) takes 8–16 s.

**Against charges BombCAD ran** (`scenebench infer-charge-study --forward-damage --dx 4|2`). The
four charges on the made-up district are run with the recommended air, the glass of every side
within the run judged as the app judges it (a side counts broken where its chance that some pane
breaks is over a half). The charge is then inferred from that glass alone, then from the
arrivals at 40 observers alone (Kingery–Bulmash), then from both:

| Truth | 4 m: glass alone (90%) | 4 m: arrivals alone | 2 m: glass alone (90%) | 2 m: arrivals alone |
|---|---|---|---|---|
| 500 kg | 539 kg (456–632) | 982 kg | 686 kg (596–787) | 713 kg |
| 2,000 kg | 3,018 kg (1,998–4,117) | 3,147 kg | 2,779 kg (1,898–4,051) | 2,588 kg |
| 5,000 kg | 5,767 kg (3,994–9,908) | 7,848 kg | 13,944 kg (5,469–43,467) | 6,302 kg |
| 1,000 kg | 1,059 kg (844–1,331) | 1,873 kg | 951 kg (785–1,185) | 1,402 kg |

- **On 4 m cells the glass alone does better than the arrivals.** Its interval holds the truth
  for all four charges, and its median is within 6–15% for three (51% high for 2 t). The
  arrivals alone read 1.6–2 times high, as above.
- **On 2 m cells it holds the truth for two of four.** The finer run breaks more glass than the
  surrogate's cell term allows for (93 of 192 sides at 500 kg, against 62 on 4 m cells), so the
  yield reads high. Where nearly every side breaks (164 of 167 at 5 t), the glass only says the
  charge was large.
- **Together,** the arrivals' far narrower intervals decide the yield, the glass moving it by 1–20%,
  towards the truth: no worse than the arrivals alone.
- **The place** the glass gives is 3–70 m off, against 1–2 m from the arrivals.
- **A bias shared by the district's sides**, sampled as a parameter of its own
  (`damageBiasLogSD`, off by default), widens the yield's interval but moves its median up 1.1–2.9
  times. Given the bias, a larger charge matches the run's fall of broken glass with distance
  better than the surrogate's own does. That is the surrogate's error, not one the yield can be
  freed from by a single factor.

So the plan's bar is met on 4 m cells, where the truth falls inside every interval and three
medians come within 15%, and not on 2 m cells.

**A run near the estimate** (stage 3, `--forward-damage --passes 3 [--side-load glass|glass-common|mean|peak]`).
As the arrivals' ratios do, BombCAD is run at the estimate, and the surrogate's load on each
side corrected toward the run's there (`SurrogateDamage.correct`), the correction applied wherever
the charge is weighed; then inferred again, at most three times, until the yield moves under 5%.
The glass alone is run at its own estimates; the arrivals and glass together at theirs, which
correct both. The correction tried four ways:
- **glass** (the default): each side's load takes the factor whose chance from its mix is the
  run's chance there. Only sides whose chance lies within 2–98% say anything (past the load that
  surely breaks a pane, any load does); the rest take those sides' median.
- **glass-common**: that median for every side.
- **mean** and **peak**: the run's strips' mean log load, or the most loaded strip's peak.

Each run takes 2–20 s. The truth inside the 90% interval, after the last pass:

| | 2 m: glass alone | 4 m: glass alone | 2 m: arrivals and glass | 4 m: arrivals and glass |
|---|---|---|---|---|
| No run (as above) | 2 of 4 | 4 of 4 | 0 of 4 | 0 of 4 |
| glass | 1 of 4 | 1 of 4 | **4 of 4** (505–5,033 kg, within 2%) | 3 of 4 (500 kg reads 457) |
| glass-common | 2 of 4 | 2 of 4 | 4 of 4 | 3 of 4 |
| glass, every certain side at its limit (e^±1.5) | 3 of 4 | 1 of 4 | 4 of 4 | 3 of 4 |
| mean (stopped after two charges) | 0 of 2 | – | 2 of 2 | – |

- **The glass alone is not put right by a run at its estimate.** Its place is 20–70 m off.
  A run there measures the surrogate's error at the wrong place, so its corrections move the yield
  the wrong way as often as the right. On 4 m cells the 500 kg charge drifts from 539 to 387 kg as
  each run's correction grows. The mean correction is near 1 (0.9–1.1): the surrogate's mean load
  on a side is right, and the glass's error is in how loads vary along it and with the place.
- **Together, the run puts both right**, but the arrivals carry it. With the place from the arrivals
  (within a metre), every correction gives the truth within 2% on 2 m cells and 1–9% on 4 m cells:
  just what the arrivals' ratios give alone ([below](#bombcads-arrivals-on-a-made-up-district)).
- So stage 3 meets the bar of three of four on 2 m cells, no worse on 4 m, only with the arrivals.
  On the glass alone it does not, and the correction is left to the study, not offered in the app.

### Beirut's surveyed damage (20 October 2026)

Does Beirut's surveyed damage, weighed by the quick estimate as the app gives it, say the yield the
arrivals say? (`scenebench damage-yield`; stage 4 of emmettl/bombcad-work#18.) The place is held at
Warehouse 12, which the arrivals put within 25 m. At each of 13 yields from 0.05 to 5 kt, each
surveyed building or façade takes its chance from 100 draws of the load scatter and the strength
(no yield scatter). Two surveys are weighed:
- GEER's façades: the openings blown out (W3), by the openings' fragility
  ([glass](glass-probability.md)).
- GEER's buildings (in person and from 360° photographs): stone bearing walls classed D3 or worse
  against the walls' chance of heavy damage, each taken as 0.5 m stone, and concrete frames and
  walls classed D2 or worse against the walls' chance of moderate damage
  ([walls and roofs](glass-probability.md#walls-and-roofs)).
  - A class that straddles the line, such as D2–D3 for stone, is left out, as are mixed structures.
  - Each building is matched to the map building its centroid lies in, or the nearest within 15 m.
    GEER's own distances agree with these to a median of 4 m.

Each survey's likelihood is taken by 250–1,000 m bands of distance (beta-binomial, concentration 30,
as the glass is weighed above), with the prior flat in log yield:

| Survey | Observed (damaged) | Yield, kt: median (90%) | Overlaps the arrivals' 0.39–0.85 |
|---|---|---|---|
| GEER openings W3 | 8,227 façades (1,779) | 0.83 (0.59–1.12) | yes, but circular |
| GEER stone buildings D3 or worse | 49 (23) | **0.72** (0.53–0.99) | yes |
| GEER concrete buildings D2 or worse | 91 (42) | 4.6 (3.5–5.0, at the grid's end) | no |

- **Stone calibrates.** Its 90% interval overlaps the arrivals', from damage the model was never
  fitted to. Weighed building by building, it gives 0.69 kt (0.54–0.88). Two cautions apply:
  - it rests on 49 buildings, 12 of 12 damaged at 0.5–0.75 km;
  - GEER chose buildings from calls to a hotline, which leans towards damage and so towards a
    larger yield.
- **The openings agree, but by construction.** Their fragility was fitted to GEER's W3 on the 0.5 kt
  run's loads, so they say only that the quick estimate's loads are near that run's. Weighed façade
  by façade, they give 0.69–0.70 kt. That interval is far too narrow, because neighbouring façades
  share an error the Bernoulli takes as independent. The bands are the ones to read.
- **Concrete does not calibrate.** The quick estimate damages none of GEER's concrete buildings
  moderately at 0.5 kt (0.3 expected of 42 seen), and reads 3–5 kt. It judges a 0.2 m concrete wall.
  A Beirut concrete building is a frame with hollow-block infill, and GEER's D2 counts damage to
  that infill and the partitions ([Beirut](beirut-2020.md#structure-against-the-building-survey-geer-2021)).
  Concrete damage cannot be used to infer a yield until infill walls are modelled.

So the plan's test for stage 4 is met for stone and the openings and fails for concrete. The
damage counts here only as a check on the arrivals, not as a way to sharpen them. It is not
offered in the app: the Infer Charge sheet weighs the glass on the scene's own buildings, not its
walls.

### In the app

The Infer Charge sheet weighs a survey of broken glass on the scene's own buildings where it can:
**On this scene's buildings**, under Broken glass, beside the arrivals. It is offered only when
the scene has building sides whose glass the app judges in a run (`SurrogateDamage.judgedSides`:
envelope buildings with a glazing mix and façade strips on the air), and needs the scene's corner
(0, 0) in longitude and latitude, as a map import places buildings.
- **Matching.** Each surveyed façade goes to the nearest such side whose face lies within 6 m of
  it in plan and which faces within 60° of the façade's own way, where known
  (`SurrogateDamage.observed`). A side counts broken where any façade on it is.
- **Weighing.** The sides are weighed by the surrogate from the place being searched, with places
  on a grid no finer than 20 m (a fifteenth of the search radius beyond 300 m), in place of the
  free-field glass.
- **Standing.** The result shows how many sides the survey reached and how many broke, and states
  the standing: illustrative. On Beirut it is circular, as the glazing mixes' openings curve was
  fitted there (`ChargeInference.sceneGlassStanding`).

### On the clear-top façade terms (25 October 2026)

On 25 October the quick estimate took the clear-top façade terms (`TermSet.clearTop`,
emmettl/bombcad-work#99). `SurrogateDamage` kept the terms of 23 October (`TermSet.fitted`) and
their load scatter, because it had not been judged on the new ones. This section judges it on
both (emmettl/bombcad-work#100). The scatter by scaled distance, which `chances` used to take from
`leaveOneOut` whatever the terms, now comes with the terms.

Both sets can be run, and `fitted` stays the default everywhere:
- `SurrogateDamage(…, terms:)` in code;
- `infer-charge-study --forward-damage --terms clear-top|fitted`;
- `infer-charge --scene-glass` (new): the glass on a district scene's own buildings, built from
  the district's inputs, as the app's sheet weighs it, with `--no-arrivals` for the glass alone.

The runs and outputs are in `$BOMBCAD_DATA/scratch/issue100` (`forward/`, `infer/`).

**BombCAD's own charges** (`--forward-damage`: the four charges above, rerun with today's solver,
each judged on both sets with the same runs and seeds):

| | 4 m: 23 October | 4 m: clear-top | 2 m: 23 October | 2 m: clear-top |
|---|---|---|---|---|
| Glass alone, found / true (0.5, 2, 5, 1 t) | 0.92, 1.53, 1.27, 1.03 | 1.04, 1.36, 1.34, 1.09 | 1.17, 1.01, 2.38, 0.87 | 1.07, 0.89, 1.72, 0.79 |
| Mean \|log(found / true)\| | 0.19 | 0.18 | 0.29 | 0.24 |
| Truth in the 90% interval | 3 of 4 (not 2 t) | 3 of 4 (not 2 t) | 3 of 4 (not 0.5 t) | 3 of 4 (not 1 t) |
| Place off | 42–76 m | 7–79 m | 36–145 m | 10–111 m |
| Arrivals and glass, found / true | 1.31, 1.55, 1.64, 1.75 | 1.47, 1.53, 1.63, 1.70 | 1.39, 1.33, 1.30, 1.40 | 1.33, 1.29, 1.30, 1.31 |

- **As well or better.** The yields are as good within the scatter. Each set holds the truth in
  three intervals of four on each grid. The clear-top terms place the charge nearer in seven
  cases of eight: within 43 m in six of the eight, against two of eight on the terms of 23 October.
- **With the arrivals**, the arrivals decide the yield on both sets, as before.
- Today's runs break fewer sides on 4 m cells than those of 20 October (47 of 192 at 500 kg,
  against 62), so the 4 m column of 23 October no longer holds all four.

**Beirut** (GEER's 9,175 façades put on the judged sides of the 2.5 km scene on 4 m cells: 2,295
sides seen, 983 broken; 1,148 of them weighed, 495 broken; Rigby et al.'s 31 observers; 15 °C,
Kingery–Bulmash):

| | Terms of 23 October | Clear-top terms |
|---|---|---|
| Arrivals alone (no glass; for reference) | 0.54 kt (0.39–0.85), 25 m off | the same |
| Glass alone, the place free | 0.076 kt (0.071–0.081), 476 m off (the search's edge) | **0.055 kt** (0.051–0.059), 466 m off |
| Glass alone, the place held at Warehouse 12 | 0.040 kt (0.038–0.043) | **0.030 kt** (0.028–0.032) |
| Arrivals and glass, the place free | 0.058 kt (0.038–0.068), 246 m off; observers 29% off | **0.041 kt** (0.036–0.048), 223 m off; 29% off |
| Arrivals and glass, the place held | 0.041 kt (0.038–0.043); observers 18% off | **0.030 kt** (0.029–0.032); 19% off |

The published estimates are Rigby et al.'s 0.50 kt (1.12 upper), Stennett et al.'s 0.64 kt
(0.41–0.96) and Pilger et al.'s 0.13–2 kt.

- **On Beirut both sets are far off, and the clear-top terms are further.** The glass on the
  scene's own buildings wants a charge 7–13 times too small on the terms of 23 October. It wants
  9–17 times too small on the clear-top terms. The clear-top yield is 25–30% lower at every
  setting, and the 90% intervals overlap in one pair of four.
- **With the arrivals the result is no better.** The glass overrides them: the observers are
  then 18–29% off the model on either set, against 6% alone.
- **Why.** The clear-top terms read Beirut's far façades higher (0.82–1.03 of a clear-top run at
  0.5 kt, against 0.72–0.92). That is right for the loads. But more glass then breaks for each
  kilotonne, and a smaller charge matches the survey's share broken. It is the free-field
  glass's finding again ([above](#broken-glass)): the glass model breaks more than GEER's survey
  counts, and better loads widen that gap.

**Proposal: the inference's glass keeps the terms of 23 October.**
- On BombCAD's own charges the clear-top terms do as well on the yield and better on the place.
- On Beirut against the published estimates they do worse: 25–30% lower, on a result that was
  already 7–13 times low. Neither set gives a usable yield there.
- What keeps Beirut out of reach is the glass's own bias against the survey, not the loads.
- Moving would put the sheet's glass on the same terms as the quick estimate beside it. It would
  take a quarter to a third more off the Beirut yield. It is the user's decision.

**Still pinned on the deep-city terms (25 October 2026).** That evening the quick estimate, the
far field and the planner took the deep-city terms, the clear-top ones with far terms for façades
deep in a city (emmettl/bombcad-work#105). The inference's glass keeps the terms of 23 October,
as the user decided. On the deep-city terms glass alone reads 0.055 kt with the place free and
0.030 kt held, as on the clear-top terms
([the surrogate](surrogate-first-look.md#far-terms-past-2-km-of-city-25-october-2026)).

**Still pinned on the outline's facing (28 October 2026).** That day the quick estimate, the glass
chances and the far field took the deep-city terms refitted with each wall facing as its
building's map outline (`deep-city-outline`, emmettl/bombcad-work#109); the planner stayed on the
deep-city terms. The inference's glass keeps the terms of 23 October, as the user decided. On the
outline's terms glass alone reads 0.056 kt with the place free and 0.030 kt held
([the surrogate](surrogate-first-look.md#façade-incidence-from-map-outlines-28-october-2026)).
`--terms deep-city-outline` names them; a side then faces as its strips' outline normals, by area.

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

## The charge from marked damage, learned (1 November 2026)

emmettl/bombcad-work#116. A user marks a few buildings: glass whole or broken, walls undamaged,
damaged or heavily damaged, or either left unseen. A small network turns the marks into a
posterior over the charge's place and yield in a few milliseconds, and each new mark adds to it in
under half a millisecond. It is trained on the quick estimate's own chances, drawn for charges of
many places and yields over Beirut and made-up districts. It is judged against the full posterior
on the same chances, on charges held out, and on Beirut's surveys.

**Standing: illustrative.** On charges drawn from the quick estimate's chances, its 50% and 90%
regions and intervals hold the truth as often as they claim, and it comes within a factor of about
1.1 of the full posterior's yield and some 10–35 m of its place. That holds on a made-up district
it never saw too. On a real event it is exactly as good as the quick estimate's glass and walls,
which on Beirut means the glass reads the yield far too low ([below](#on-beiruts-surveys)).

```bash
blastmodel charge-from-damage table <district's inputs> [--masonry] [--geer … --structure …] --out t.bcct
python3 -I Scripts/ml/remote-train.py bombcad-pc <tables> Scripts/ml/train_charge.py --job charge-net-1 --args …
blastmodel charge-from-damage judge --tables a.bcct,b.bcct [--weights charge-net.bccd]
blastmodel charge-from-damage infer --marks marks.csv [--table t.bcct] [--weights charge-net.bccd]
```

`scenebench charge-from-damage` runs the same. The code is in BlastModel
(`ChargeFromDamage`, `ChargeFromDamage.ChanceTable`; Sources/BlastModel/Studies/ChargeFromDamageStudy.swift),
so it runs on Linux as well.

### The data: the quick estimate's chances on a grid

For each district a table holds, for chosen buildings, the quick estimate's chance of each mark:
- the glass broken (some pane of some side, the sides' draws taken together, since a building's
  glass strength is one draw for all its sides);
- the walls damaged moderately or worse, and heavily or worse, built as the scene says
  (`structureProbabilities`);
- for Beirut, the walls again as 0.5 m unreinforced masonry, as its stone is judged
  ([above](#beiruts-surveyed-damage-20-october-2026)), for 537 of its buildings: GEER's and one in six of
  the rest.

The chances are for charges on a grid of places 50 m apart over a square 1.1 km across about a
reference point (the scene's charge: Warehouse 12 for Beirut). There are 16 yields from 100 kg
doubling to 3.3 kt, each chance drawn 16 times over the load scatter and the strengths. Between
nodes and yields a chance is read bilinearly in place and linearly in log yield.

The tables take a drag's preview of each building (its nearest component of each group,
`Prepared.preview`), which is several times quicker than the full look. On the made-up perimeter
district at two nodes, every one of 16 yields, the preview's chances came within 0.1 of the full
look's for 96.7% of the building-yields where either was over 0.01 for glass (mean difference
0.016), and for all of them for concrete walls. **Not for masonry:** there the preview's chances
came within 0.1 for only 49% (mean 0.47 against the full look's 0.68), and at 300–600 m it needed
two to four times the yield to give the same chance. A masonry wall's resistance grows with the
storeys over it, and the nearest strip, the preview's, is the ground floor's, the strongest.
Beirut's masonry channels are therefore the full look's (`--masonry-only`, `merge-masonry`).

| District | Buildings chosen | Of which GEER's | Masonry | Hours on bombcad-pc (16 cores) |
|---|---|---|---|---|
| Beirut, 2.5 km scene, 4 m cells | 2,500 | 1,440 | 537 of them, from the full look | 1.26, and 1.19 for the masonry |
| made-up perimeter blocks (flat) | 1,000 | – | no | 0.27 |
| made-up street grid (slope) | 1,000 | – | no | 0.32 |
| made-up towers (hill) | 880 | – | no | 0.30 |
| made-up industrial sheds (flat) | 535 | – | no | 0.20 |
| made-up mixed (valley), **never trained on** | 1,000 | – | no | 0.42 |

The buildings are chosen in rings 100 m wide about the reference, an even share from each ring, so
that near buildings are not swamped by the many far ones; Beirut's include every building GEER
surveyed. The made-up districts are `Scripts/ml/make_district.py`'s, 2.4 km across. No solver run
is needed. The generation ran on the PC's CPU (`Scripts/remote-sweep.py`), not on the Studio.

**Drawn cases.** Training draws its cases from the tables afresh at every step, so there is no
fixed set to overfit, by rules the judge's Swift draws repeat (`ChanceTable.drawCase`):
- the charge uniform over a disc of 500 m about the reference, and in log yield over the ladder;
- 1–64 marks, chosen about a focus that knows nothing of the charge (anywhere within 1 km, the
  buildings weighted e^(−distance / L), L 100–1,500 m), so that the marks cluster as a user's do;
- each seen for both (45%), its glass alone (30%) or its walls alone (25%), and, where the table
  has masonry, its walls taken as masonry three times in ten;
- what was seen drawn from its chances, with a chance of misreading (4% for glass, 6% for walls,
  spread over the classes) that keeps every likelihood at least 0.02 from 0 and 1, as the full
  inference's floor does. A building heavily damaged is said heavy half the time and damaged
  otherwise.

### The network: each mark's likelihood by its distance, summed

The task is a set of any size, each element a building's place, construction and what was seen,
with any part unseen. Three set encoders were tried, all to the same grid over the place (32 × 32
cells of 31 m over the 500 m disc) and the log yield:

- **Pooled** (deep sets): each mark through a small network, the set's mean and maximum through a
  second to each cell's probability and a normal for the log yield there. On the first made-up table,
  6,000 steps, its intervals were calibrated but nearly as wide as the prior, and it barely firmed
  up with marks: pooling has to rediscover where each mark is.
- **Surfaces**: each mark gives its own log likelihood over the cells (a map of offsets and slopes,
  read as log sigmoid(a + b t) at standardised log yield t), the marks' summed. The sum is right
  (the marks are independent given the charge), but a map read straight off a mark's coordinates
  learns slowly (loss 8.73 after 6,000 steps).
- **Distance** (adopted): a mark's likelihood depends on the cell only through the distance r
  between the building and the charge there. A network 64 wide, twice, of the mark's own features
  (log height, log footprint, the share built round it, its walls, what was seen) and of r gives two
  offsets and slopes, and the likelihood at standardised log yield t is
  0.02 + 0.98 σ(a₁ + b₁ t) σ(a₂ + b₂ t). Two sigmoids give a bump, as "damaged but not heavily"
  needs; the floor is the misreading's. The marks' log likelihoods are summed over the cells and 32
  bins of log yield, and the posterior is the sum's softmax.

The distance network has 5,316 weights. It reached loss 7.27 in 3,000 steps on the same table and
came within a factor 1.1 of the full posterior's yield there. It is translation- and
rotation-invariant: it is the same at any place, in any district, about any reference, and weighs
any number of marks with no grouping. The cost of that: it cannot know which buildings shield which.
The full posterior on the same chances does, and is the sharper by what shielding tells
([below](#calibration-and-agreement-with-the-full-posterior)).

In the app's code the network is evaluated at 96 distances (1 m to 8 km, even in ln r) once per
mark and read linearly in ln r for each cell, as training reads it; sigmoids and logarithms are
tabulated. The weights are float16 in a `.bccd` file (a JSON header, then the tensors), 10 KB of
weights plus four cases' outputs for the test against PyTorch, which agree to 6 × 10⁻⁶ (relative).

**Training.** `Scripts/ml/train_charge.py` on bombcad-pc (RTX 3080 Ti) through
`Scripts/ml/remote-train.py`: AdamW, one-cycle at 3 × 10⁻³, batches of 96 cases each from one table
in turn, the eight turns and flips of the square at random. The final network (`charge-net-2`)
trained on Beirut and the four made-up districts, the mixed district held out, 10,000 steps in 19
minutes (the PC's CPU shared with the tables' sweep). A network trained without Beirut
(`charge-net-made`, 8,000 steps, 13 minutes) was judged on Beirut too.

### Calibration and agreement with the full posterior

`charge-from-damage judge`, 300 held-out cases for each number of marks on each district, drawn
from another seed. "Full" is the exact posterior on the table's own chances, cell by cell (four
points to a cell) and on 46 log yields: the full inference on the same marks, with every building's
own shielding. 300 held-out cases for each number of marks on each district, drawn from another
seed than training's; the marks 1–64 at random:

| District | Learned: place in 50% / 90% | yield in 50% / 90% | Full: place | yield | Yields' medians apart (median, 90th) | Places apart (median) |
|---|---|---|---|---|---|---|
| beirut | 0.49 / 0.87 | 0.47 / 0.88 | 0.52 / 0.87 | 0.49 / 0.85 | ×1.17, ×1.45 | 15 m |
| made-perimeter-s3 | 0.50 / 0.89 | 0.46 / 0.90 | 0.49 / 0.88 | 0.51 / 0.92 | ×1.13, ×1.43 | 18 m |
| made-grid-s4 | 0.50 / 0.88 | 0.50 / 0.90 | 0.49 / 0.88 | 0.51 / 0.92 | ×1.08, ×1.23 | 11 m |
| made-towers-s5 | 0.45 / 0.89 | 0.49 / 0.91 | 0.47 / 0.90 | 0.49 / 0.93 | ×1.09, ×1.29 | 10 m |
| made-industrial-s6 | 0.47 / 0.89 | 0.45 / 0.89 | 0.48 / 0.88 | 0.47 / 0.90 | ×1.09, ×1.26 | 13 m |
| made-mixed-s7 (never trained on) | 0.50 / 0.89 | 0.52 / 0.89 | 0.54 / 0.89 | 0.52 / 0.92 | ×1.12, ×1.35 | 16 m |

- **Calibrated.** On every district the truth falls in the learned 50% regions and intervals
  0.45–0.52 of the time and in the 90% ones 0.87–0.91, as often as in the full posterior's
  (0.47–0.54 and 0.85–0.93). (With 300 cases a share of 0.9 is good to about ±0.02.) By the
  number of marks it stays so: on Beirut 0.87–0.91 at 90% for the place and 0.87–0.91 for the yield
  with 1, 3, 10 or 30 marks; on the mixed district, never trained on, 0.88–0.92 and 0.88–0.93.
- **Close to the full posterior.** The two yields' medians are a factor 1.08–1.17 apart (median
  case), at most 1.23–1.45 in nine cases of ten, and their mean places 10–18 m apart. The network
  is barely wider: knowing which buildings shield which adds little once the marks are many and
  scattered.
- **The district it never saw** (made-up, mixed styles, a valley) is judged as well as those it
  trained on.
- **Beirut needs Beirut.** The network trained only on made-up districts, judged on Beirut's cases:
  its 90% regions held the place 0.75 of the time with 30 marks (0.85 over all), and its yield came
  a factor 1.36 from the full posterior's, against 1.17 once Beirut is in training. Beirut's
  buildings are larger and taller, and its stone walls are judged as masonry.

**How fast it firms up** (the median case; "high/low", the 90% interval's top over its bottom):

| District | Marks | Learned: 90% yield high/low | 90% place radius | Full: 90% yield high/low | 90% place radius | Median found/true yield (learned) | Learned, ms (all marks; one added) | Full, ms |
|---|---|---|---|---|---|---|---|---|
| beirut | 1 | 445 | 472 m | 452 | 472 m | 1.03 (0.07–15.49) | 0.3; 0.34 | 1.1 |
| beirut | 3 | 99 | 467 m | 101 | 466 m | 1.14 (0.16–6.73) | 0.6; 0.34 | 1.6 |
| beirut | 10 | 32 | 448 m | 30 | 445 m | 0.97 (0.22–3.84) | 1.9; 0.35 | 2.8 |
| beirut | 30 | 12 | 400 m | 12 | 398 m | 1.25 (0.44–2.82) | 5.7; 0.35 | 6.3 |
| made-perimeter-s3 | 1 | 513 | 471 m | 522 | 471 m | 0.90 (0.06–11.09) | 0.3; 0.34 | 1.1 |
| made-perimeter-s3 | 3 | 97 | 450 m | 109 | 449 m | 0.89 (0.14–4.62) | 0.6; 0.34 | 1.5 |
| made-perimeter-s3 | 10 | 23 | 392 m | 24 | 380 m | 0.88 (0.28–3.16) | 1.9; 0.36 | 2.7 |
| made-perimeter-s3 | 30 | 6 | 264 m | 6 | 243 m | 0.93 (0.43–2.17) | 5.8; 0.36 | 5.8 |
| made-grid-s4 | 1 | 524 | 471 m | 480 | 470 m | 0.98 (0.07–13.28) | 0.3; 0.34 | 1.1 |
| made-grid-s4 | 3 | 97 | 447 m | 99 | 446 m | 0.90 (0.15–6.69) | 0.6; 0.34 | 1.5 |
| made-grid-s4 | 10 | 21 | 383 m | 21 | 380 m | 0.93 (0.30–3.11) | 1.9; 0.36 | 2.7 |
| made-grid-s4 | 30 | 6 | 255 m | 6 | 244 m | 1.10 (0.48–2.52) | 5.8; 0.36 | 6.1 |
| made-towers-s5 | 1 | 1278 | 470 m | 1210 | 470 m | 0.91 (0.07–25.61) | 0.3; 0.34 | 1.1 |
| made-towers-s5 | 3 | 146 | 455 m | 130 | 455 m | 0.94 (0.11–6.94) | 0.6; 0.34 | 1.5 |
| made-towers-s5 | 10 | 23 | 397 m | 21 | 397 m | 0.97 (0.30–4.07) | 1.9; 0.36 | 2.7 |
| made-towers-s5 | 30 | 7 | 297 m | 7 | 285 m | 0.94 (0.48–2.15) | 5.9; 0.37 | 6.0 |
| made-industrial-s6 | 1 | 577 | 471 m | 556 | 471 m | 1.21 (0.09–22.26) | 0.3; 0.34 | 1.1 |
| made-industrial-s6 | 3 | 101 | 456 m | 100 | 456 m | 0.84 (0.12–6.29) | 0.6; 0.34 | 1.5 |
| made-industrial-s6 | 10 | 24 | 399 m | 26 | 400 m | 1.08 (0.22–4.71) | 1.9; 0.36 | 2.7 |
| made-industrial-s6 | 30 | 8 | 290 m | 8 | 282 m | 1.06 (0.48–2.27) | 5.9; 0.36 | 5.9 |
| made-mixed-s7 | 1 | 503 | 470 m | 585 | 470 m | 0.88 (0.08–15.07) | 0.3; 0.34 | 1.1 |
| made-mixed-s7 | 3 | 103 | 448 m | 104 | 446 m | 0.82 (0.13–5.15) | 0.6; 0.34 | 1.5 |
| made-mixed-s7 | 10 | 23 | 391 m | 24 | 385 m | 0.85 (0.24–3.02) | 1.9; 0.36 | 2.7 |
| made-mixed-s7 | 30 | 7 | 260 m | 7 | 247 m | 0.95 (0.44–2.11) | 5.9; 0.36 | 6.0 |


- One mark leaves the yield open over a factor of 450–1,300 and the place nearly anywhere in the
  disc; three marks narrow the yield to a factor of about 100, ten to 20–30, thirty to 6–12. The
  place firms up more slowly: the 90% region's radius falls from 470 m to 250–300 m with 30 marks on
  the made-up districts, and to 400 m on Beirut, whose buildings near the port are few. Marks drawn
  about a focus that knows nothing of the charge are a hard case: a user who marks the damaged
  buildings near the blast tells it more.
- The full posterior firms up at the same pace.

**Time.** In Swift on the Studio's CPU (loaded), one core: 0.3 ms for one mark, 2 ms for 10 and
6 ms for 30, recomputed from nothing. A mark added to the others' summed likelihood costs 0.35 ms,
which is what the app pays per click. The full posterior on the table takes 1–6 ms on the made-up
tables' 1,000 buildings and is possible only for buildings the table holds.

### On Beirut's surveys

GEER's surveys put on the table's buildings (`charge-from-damage table … --geer … --structure …
--marks-out`): 1,351 buildings' glass (broken where any of their façades was classed W1 or worse,
657 broken) and 139 buildings' walls: concrete frames D0–D1 undamaged, D2 damaged, D3 or worse
heavy (91), and stone bearing walls, as masonry, D3 or worse heavy, the rest undamaged (48), as the
stone was weighed before ([above](#beiruts-surveyed-damage-20-october-2026)). A class straddling the
line is left out. In the order of a fixed shuffle, the first 1, 3, 10, 30 and all (`infer`):

| Marks | Learned: yield (90%), place free | Full: yield (90%), place free | Learned, place held at Warehouse 12 | Full, place held |
|---|---|---|---|---|
| Stone walls, 1 | 1.04 kt (0.01–2.95) | 0.98 kt (0.002–3.26) | 1.10 kt (0.02–2.95) | 1.05 kt (0.002–3.27) |
| Stone walls, 3 | 1.14 kt (0.28–2.88) | 1.44 kt (0.30–3.29) | 1.23 kt (0.40–2.86) | 1.68 kt (0.45–3.34) |
| Stone walls, 10 | 0.69 kt (0.25–1.74) | 0.85 kt (0.30–2.13) | 0.60 kt (0.34–1.16) | 0.71 kt (0.38–1.37) |
| Stone walls, 30 | 0.64 kt (0.34–1.52) | 0.78 kt (0.39–1.69) | 0.82 kt (0.54–1.22) | 0.93 kt (0.61–1.38) |
| **Stone walls, all 48** | **0.69 kt (0.29–1.62)**, 141 m S of the warehouse | 0.70 kt (0.33–1.62), at it | **0.70 kt (0.49–0.89)** | 0.80 kt (0.60–1.06) |
| All walls, 139 (concrete too) | 2.69 kt (1.83–3.21) | 2.17 kt (1.87–2.81) | 2.04 kt (1.71–2.80) | 1.86 kt (1.01–2.27) |
| Glass, 30 | 20 t (9–39) | 20 t (9–36) | 16 t (10–25) | 14 t (9–20) |
| Glass, all 1,351 | 30 t (25–34) | 32 t (29–36) | 21 t (18–25) | 16 t (15–18) |
| Everything, 1,435 | 30 t (25–34) | 32 t (29–36) | 21 t (18–25) | 16 t (15–18) |

The accepted figures: 0.50–0.54 kt from the arrivals here (90%: 0.36–0.85), Rigby et al.'s 0.50 kt
(1.12 upper), Stennett et al.'s 0.64 kt, Pilger et al.'s 0.13–2 kt; Warehouse 12.

- **The stone finds Beirut.** From the 48 stone buildings alone the network gives 0.69 kt with the
  place free (90%: 0.29–1.62) and its most likely cell 141 m south of the warehouse; with the place
  held, 0.70 kt (0.49–0.89). The full posterior on the same chances gives 0.70 and 0.80 kt, and
  `damage-yield`, weighing the same stone by the full look at the warehouse, 0.69 kt (0.54–0.88). It
  firms up as a user would see it: a factor of 200 after one wall, 0.25–1.7 kt after ten, 0.3–1.5 kt after thirty.
- **Read D2 as damaged and the stone reads 2.0–2.5 kt.** The model's masonry walls go from
  undamaged to heavily damaged at once (their moderate and heavy chances are the same), so a stone
  building GEER classed D2 is, to the model, as damaged as a D3. Against the line the stone was
  calibrated at, D3, it is undamaged. Which a user means by "damaged" for a stone building matters
  by a factor of three.
- **The glass reads tens of tonnes, as the full inference's does.** 16–32 t, 15–30 times too small:
  the quick estimate's glass breaks far more than GEER's survey counts, as the side-by-side
  inference found (0.030–0.076 kt, [above](#on-the-clear-top-façade-terms-25-october-2026)). With
  1,351 glass marks against 48 stone ones the glass decides any mixture. It is the quick estimate's
  bias, which the network inherits faithfully.
- **Concrete pushes the walls high** (1.9–2.7 kt with them), as `damage-yield` found (3–5 kt): no
  infill walls.
- **Learned and full agree on the real marks** as on drawn ones: within a factor 1.4 on every row.

So on a real event the network is as good as the quick estimate's chances, no better: stone walls
read at D3 give the yield and place; glass does not.

### Standing and what is next

**Illustrative.** Calibrated against the quick estimate's own chances, and within about 10–20% of
the full posterior on them, on Beirut, on four made-up districts and on one it never saw; on
Beirut's survey right from stone walls read at their calibrated line, and 15–30 times low from
glass. The standing is the quick estimate's, carried through.

What it does not do:
- **No shielding.** A mark is known by its distance and its own building. Close in among tall
  buildings, the full posterior is the sharper.
- **Its reach.** Charges within 500 m of the reference, 100 kg to 3.3 kt, the yield's prior flat
  in its logarithm and the place's flat over the disc. A charge beyond is put at the disc's edge.
- **Marks taken as independent given the charge,** as the full inference takes them: a survey's
  neighbours, which err together, make it too sure (1,351 glass marks give a 90% interval of a
  factor 1.3). Since stage 3 the panel and the commands take an error shared by every mark
  ([below](#marks-that-err-together-surveys-and-kept-marks-2-november-2026)); calibrated up to 30
  marks, still too sure with hundreds.
- **In the app** since 2 November 2026: Simulation ▸ Read the Charge from the Damage…
  ([below](#marking-the-damage-in-the-app-2-november-2026)).

**The weights are built in** (the user's decision, 2 November 2026), as the live drag's are:
`Scripts/ml/embed_charge.py` writes `charge-net-2`'s `charge-net.bccd` (188,960 bytes with its four
reference cases, SHA-256 c016fc77…) as base64 into Sources/BlastModel/ChargeFromDamage+Embedded.swift
(255 KB), which `ChargeFromDamage.Network.builtIn` reads. `judge` and `infer` take it unless
`--weights` names another file, and the test against PyTorch checks it.

The tables, sweeps and judgements are in `$BOMBCAD_DATA/scratch/issue116`; the networks in
`$BOMBCAD_DATA/ml/charge-net-2` and `ml/charge-net-made`.

### Marking the damage in the app (2 November 2026)

emmettl/bombcad-work#116, stage 2. **Simulation ▸ Read the Charge from the Damage…** opens a panel
beside the view on any scene with envelope buildings. While it is open, a click on a building marks
it with the brush chosen in the panel: glass broken or whole, walls undamaged, damaged or heavily
damaged, or the mark cleared; the same brush again takes that part of the mark away. With each mark:

- **The chance of the charge's place is painted on the ground** over the network's 32 × 32 cells
  of 31 m, the likeliest cell pale yellow and a hundredth of it dark red, less left bare; a thick
  white line round the likeliest half of the chance and a thin one round nine tenths.
- **Each marked building is outlined over its roof:** glass broken crimson, whole cyan; walls
  undamaged blue, damaged amber, heavily damaged dark red.
- **The yield** is drawn as the posterior's 32 bins on a logarithmic axis, the 90% interval shaded
  and the median marked.
- **In words**, which VoiceOver reads as the result: "Most likely 40 m south of the scene's charge;
  half the chance within 60 m of there, nine in ten within 130 m. Yield about 11.5 t; nine in ten
  between 2.9 t and 76.5 t." The distances are true radii about the likeliest cell, not equivalent
  areas. The standing follows.
- **Mark from the Damage Shown** marks every building the quick estimate or the last run judged,
  as its damage would be marked (`ChargeFromDamage.seen`): glass broken where some pane broke (for
  a glazing mix, where some pane more likely broke than not), walls by their worst level with
  simply supported edges, as the network's training chances counted them. That is the solver or
  the full estimate as referee: run a scene or estimate it, mark from it, and see where the network
  puts the charge you placed.
- **Move the Charge There** puts the scene's charge at the likeliest place, at the yield's median;
  **Search About the Likeliest Place** moves the 500 m disc searched there (the marks weighed again),
  and **Search About the Charge** brings it back.

The search starts about the scene's charge, so the words say how far the reading is from it. Marks
are kept by building while the window is open, through edits to the scene. The code is
`ChargeFromDamage.Marking` (BlastModel, tested on Linux), which keeps the marks' summed log
likelihood and adds or takes out one mark's alone, and `ChargeMarkingModel`/`ChargeMarkingView` in
the app. The view draws the paint through the thermal paint's path (`RenderSettings.showsPaint`)
and the outlines as the hazards' lines are drawn, so no shader changed.

**Frame times** (release build, offscreen, `InterfaceReviewChargeMarkingTests`, on the Studio
lightly loaded; the made-up mixed district, which the network never saw, 858 buildings within
600 m, its terrain): 60 buildings marked one at a time, nearest the middle first.

| Step | Median | Most |
|---|---|---|
| A mark weighed into the others, to the posterior | 0.81 ms | 0.95 ms |
| The paint, outlines and words laid out | 0.36 ms | 0.60 ms |
| A frame at 1800 × 1200 with the paint and outlines, GPU | 7.0 ms | 12.9 ms |
| Click to frame drawn and read back | 19.5 ms | 94.7 ms (a frame written to disk) |

So each mark shows within a frame at 30 fps, and well within 60 fps but for the read-back the
offscreen test adds. In BlastModel's test, a mark into 1–60 others took 0.32 ms (0.35 at most).
Marking from the damage shown on that district (852 buildings at once) weighs in parallel; the
quick estimate before it took most of the time.

**Judged on charges it never saw.** Two ways, the error given as the likeliest cell's distance from
the true charge and the yield's median as a factor off the true yield (either way).

*Through the app's own path*, on the held-out mixed district: twelve charges drawn over the inner
350 m of the disc and from 200 kg to 1 kt, each estimated (the quick estimate, the full look) and
marked from its damage, then 3, 10 and 30 of those marks at random and all of them, the search
about the district's middle:

| Marks | Place off, median | 90th | Yield off, median | 90th |
|---|---|---|---|---|
| 3 | 262 m | 472 m | ×3.4 | ×14 |
| 10 | 194 m | 476 m | ×1.9 | ×4.5 |
| 30 | 88 m | 196 m | ×1.9 | ×3.7 |
| all (852) | 31 m | 49 m | ×1.4 | ×2.0 |

With every building marked the place comes within about 30 m and the yield within a factor 1.4,
but its 90% intervals are then far too narrow (a factor 1.3–1.8 wide; they missed the true yield
on eight charges of twelve, six of them high): the marks are taken as independent, and neighbours
judged by the same estimate are not, and marks read from the estimate's median loads are not the
drawn chances the network learned from.

*On the tables* (`charge-from-damage judge --seed 21`, 300 cases each, learned and full on the
same chances; `--about-damage` chooses the marks as a user does, about a building drawn by its
chance of damage, 100–500 m round it):

| District | Marks chosen | Marks | Learned: place off (median, 90th) | yield off | Full: place off | yield off |
|---|---|---|---|---|---|---|
| made-mixed-s7 (never trained on) | about a focus | 3 | 429 m, 800 m | ×2.8, ×13 | 417 m, 776 m | ×2.6, ×12 |
| | | 10 | 309 m, 720 m | ×2.0, ×5.4 | 299 m, 717 m | ×1.9, ×4.9 |
| | | 30 | 158 m, 514 m | ×1.5, ×2.9 | 165 m, 531 m | ×1.5, ×2.9 |
| | about the damage | 10 | 233 m, 758 m | ×2.1, ×6.5 | 248 m, 691 m | ×1.9, ×5.7 |
| | | 30 | 121 m, 505 m | ×1.5, ×2.9 | 114 m, 496 m | ×1.5, ×3.0 |
| beirut | about a focus | 30 | 345 m, 728 m | ×1.7, ×3.5 | 326 m, 700 m | ×1.6, ×3.3 |
| | about the damage | 30 | 434 m, 801 m | ×1.9, ×4.8 | 435 m, 788 m | ×1.7, ×4.4 |

The learned reading is as good as the full posterior on the same chances at every count, here as
in stage 1 (calibrated: the truth in its 90% regions and intervals 0.83–0.92 of the time). A few marks say little: the likeliest cell is a poor
point when the 90% region is still 400 m across, and the paint shows that spread rather than a
pin. Thirty marks bring the place to 100–160 m and the yield to a factor 1.5 on the made-up
district. On Beirut, its buildings few near the port and its charges drawn anywhere on the disc,
thirty marks leave the place 350–430 m off.

Stage 2 left three things undone: marking the far field's buildings, loading a survey file, and
saving the marks with the project. Stage 3 did all three
([below](#marks-that-err-together-surveys-and-kept-marks-2-november-2026)).

The judgements are in `$BOMBCAD_DATA/scratch/issue116/stage2`.

### Marks that err together, surveys and kept marks (2 November 2026)

emmettl/bombcad-work#116, stage 3. Stage 2 summed the marks' log likelihoods as if the marks were
independent given the charge. They are not. Every building is judged by the same quick estimate
(or seen by the same surveyor), and that estimate's errors are shared, more or less, by all of them.
With every building marked, the 90% yield intervals missed the true yield for 8 of 12 charges.

**The weighing.** `ChargeFromDamage.Weighing` adds the marks' shared error to the posterior.
Three forms were built, each off at zero:
- **Neighbours' weights:** each mark scaled by one over the count of marks near it.
- **A correlation shared by all:** the sum scaled by 1 / (1 + (n − 1) ρ).
- **A shared error of the charge:** the marks' joint likelihood taken over a normal offset of the
  log yield (σ in ln kg) and of the place (σ in m) that every mark shares. The posterior is then
  the independent one blurred by that offset, in log yield within each cell and over the cells bin
  by bin.

The shared error widens a posterior only once it is narrower than the error itself. So it changes
little at 3 or 10 marks and sets a floor to the width once there are hundreds.

**Adopted: `shared`, 0.5 in ln yield (a factor 1.65) and 12 m in place.** It is now the panel's and
the commands' weighing (the user approved it on 2 November 2026). Stage 2's is kept by name, as
`independent`: `--weighing independent` on `judge`, `infer`, `judge-looks` and `survey`, or
**Weigh the marks: As independent (stage 2)** in the panel. Any other weighing can be named by its
parameters, for example `--weighing yield=0.5,place=12,neighbours=50`.

**How it was judged: the app's own path, headless.** `charge-from-damage looks` makes the quick
estimate (the full look, as Quick Estimate makes it) for charges drawn over a district's inner
350 m, 200 kg to 1 kt, and marks the damage as **Mark from the Damage Shown** does. Each look takes
0.1–1.5 s on bombcad-pc. `judge-looks` then weighs 3, 10 and 30 of those marks and all of them,
chosen two ways: at random, or about the damage as a user would (a building seen damaged, then
buildings drawn by e^(−d / L), L 100–500 m, as `--about-damage` draws them). The search is about the
district's middle, as in stage 2.
- **Calibrated on** the four made-up districts the network trained on: 100 charges each, 400 in all.
- **Reported on** the mixed district it never saw (150 charges) and on Beirut's 1 km scene
  (100 charges, many of them in the harbour). Neither was used to choose the weighing.

The calibration grid (`$BOMBCAD_DATA/scratch/issue116/stage3/cfd-judge{1,2}-bombcad-pc`) covered:
- the yield's σ from 0.3 to 1.0 and the place's from 0 to 60 m;
- ρ from 0.01 to 0.1;
- neighbours' lengths from 50 to 200 m, and combinations of these.

What it showed:
- **The place was already wide enough.** At 3–30 marks the place's 90% region held the truth
  0.91–0.97 of the time, and its 50% region 0.56–0.70. Neighbours' weights and ρ widened the place
  further (to 0.98–1.00), which made it worse.
- **The yield was not.** At 30 marks it held 0.78–0.84, and with all marks 0.33.
- **A shared error of the yield** puts the yield right at every count without touching the place
  while the marks are few. The place's 12 m matters only with every building marked: 10 m did
  nothing, 15 m overshot.

**Before and after, with the truth inside the 50% / 90% regions and intervals** (the share of
charges; the errors are the likeliest cell's distance from the truth and the median yield's factor
off it, both medians):

| District | Marks | Place, independent | Place, shared | Yield, independent | Yield, shared | Place off | Yield off: independent → shared |
|---|---|---|---|---|---|---|---|
| training (400) | 3 at random | 0.58 / 0.95 | 0.57 / 0.95 | 0.57 / 0.96 | 0.61 / 0.97 | 322 → 311 m | ×2.12 → ×2.03 |
| | 10 at random | 0.61 / 0.97 | 0.61 / 0.97 | 0.51 / 0.89 | 0.60 / 0.96 | 142 → 138 m | ×1.65 → ×1.62 |
| | 30 at random | 0.69 / 0.97 | 0.69 / 0.97 | 0.37 / 0.78 | 0.57 / 0.94 | 55 → 56 m | ×1.46 → ×1.43 |
| | 30 about the damage | 0.67 / 0.95 | 0.67 / 0.96 | 0.41 / 0.84 | 0.59 / 0.97 | 50 → 51 m | ×1.48 → ×1.45 |
| | all | 0.65 / 0.83 | 0.67 / 0.92 | 0.15 / 0.33 | 0.50 / 0.91 | 18 → 18 m | ×1.43 → ×1.41 |
| **mixed, held out (150)** | 3 at random | 0.53 / 0.95 | 0.55 / 0.95 | 0.65 / 0.97 | 0.67 / 0.99 | 288 → 284 m | ×1.78 → ×1.79 |
| | 10 at random | 0.61 / 0.96 | 0.60 / 0.96 | 0.61 / 0.94 | 0.70 / 0.99 | 128 → 123 m | ×1.49 → ×1.44 |
| | 30 at random | 0.67 / 0.97 | 0.67 / 0.97 | 0.37 / 0.84 | 0.63 / 0.99 | 57 → 57 m | ×1.46 → ×1.40 |
| | 3 about the damage | 0.55 / 0.90 | 0.57 / 0.89 | 0.49 / 0.93 | 0.53 / 0.93 | 287 → 268 m | ×2.39 → ×2.44 |
| | 10 about the damage | 0.61 / 0.93 | 0.62 / 0.93 | 0.50 / 0.91 | 0.56 / 0.94 | 141 → 135 m | ×1.83 → ×1.79 |
| | 30 about the damage | 0.52 / 0.95 | 0.55 / 0.95 | 0.36 / 0.85 | 0.63 / 0.98 | 59 → 57 m | ×1.50 → ×1.40 |
| | all (1,080) | 0.38 / 0.48 | 0.38 / 0.70 | 0.09 / 0.19 | 0.52 / **1.00** | 21 → 21 m | ×1.42 → ×1.41 |
| **Beirut, 1 km (100)** | 3 about the damage | 0.51 / 0.97 | 0.58 / 0.97 | 0.57 / 0.98 | 0.60 / 0.98 | 468 → 442 m | ×2.44 → ×2.39 |
| | 10 about the damage | 0.52 / 0.98 | 0.52 / 0.99 | 0.54 / 0.89 | 0.58 / 0.93 | 448 → 409 m | ×2.12 → ×2.07 |
| | 30 about the damage | 0.47 / 0.97 | 0.50 / 0.97 | 0.47 / 0.81 | 0.51 / 0.90 | 420 → 392 m | ×1.98 → ×2.01 |
| | 30 at random | 0.50 / 0.94 | 0.50 / 0.95 | 0.37 / 0.77 | 0.47 / 0.91 | 364 → 341 m | ×2.08 → ×2.08 |
| | all (1,553) | 0.15 / 0.29 | 0.14 / 0.28 | 0.06 / 0.23 | 0.22 / 0.47 | 198 → 198 m | ×2.50 → ×2.51 |

- **Up to 30 marks, calibrated on both districts held out.** At 3–30 marks the yield's intervals
  hold the truth 0.90–0.99 of the time at 90% and 0.47–0.70 at 50%. The place's regions hold it
  0.89–0.99 and 0.50–0.67. Where they miss, they err wide, not narrow. With 3–10 marks the shared
  error is barely felt and stage 2 was already about right. The fix bites at 30, where the yield's
  90% interval went from holding the truth 0.81–0.85 of the time to 0.90–0.99.
- **With every building marked, calibrated on the yield, not the place.** On the mixed district the
  yield's 90% interval now holds the truth for every charge (it held 19%), and its 50% interval 52%.
  The place's 90% region holds the truth 70% of the time (from 48%). The likeliest cell is 21 m
  off, but a cell is 31 m across, and the 12 m chosen on training is too little here.
- **Beirut with every building marked is not calibrated.** Its 1,553 buildings, the charge often in
  the harbour, put the likeliest place 200 m off and the yield a factor 2.5 off. That is a bias of
  the quick estimate on Beirut that a shared error of a factor 1.65 does not cover. The yield's
  90% interval held the truth 47% of the time (from 23%), the place's 28%.
- **The errors are no worse.** The median place and yield are within a few metres and a few per
  cent of stage 2's at every count, and mostly better.
- **On the tables' drawn cases**, which are independent by construction (`judge --seed 21`), the
  shared weighing keeps stage 2's calibration: 0.83–0.93 at 90% on the mixed district and Beirut.
  The yield at 30 marks moves from 0.88 to 0.93–0.95, slightly wide.

So the target, regions and intervals holding the truth about 50% and 90% of the time across 3, 10,
30 and all marks, is met up to 30 marks on both districts held out. It is met for the yield, but not
the place, with every building marked on the made-up district, and not at all on Beirut.

**A warning instead, past 100 marks.** The panel says plainly when the answer is likely surer than
it should be:
- with the marks weighed as independent, past 20 of them;
- however they are weighed, past 100 (`ChargeMarkingModel.manyMarks`): "it rests on the quick
  estimate's own errors, which so many marks share", with the held-out shares quoted.

**Recorded stop (2 November 2026): calibration with hundreds of marks.** Getting there needs the
quick estimate's own district-wide bias, which differs between districts (a factor 1.4 on the
made-up ones, 2.5 on Beirut, and 15–30 for Beirut's glass against GEER). There are three ways it
could go, none of them done:
- an error that grows with the marks' spread or count, fitted on more districts than four;
- marks drawn in training from shared draws of the load scatter rather than independent ones;
- a run (the referee) to measure the bias on the scene itself, as `--forward-damage` does.

**Surveys in the panel.** **Load a Survey…** reads any of the following and puts them on the
scene's buildings, near and far, in place of the marks given (`ChargeFromDamage.readSurvey`,
`match`):
- a marks CSV, as `charge-from-damage infer` reads it, east and north about the scene's charge;
- GEER's façade shapefile, a building's glass broken where any of its façades is W1 or worse;
- a CSV of façades `lat,lon,class`, as the Infer Charge sheet reads one;
- GEER's structural tables, read as `table --structure` reads them: stone at D3, concrete at D2;
- a folder of any of these, such as DesignSafe PRJ-3030 as downloaded.

Each entry goes to the building it stands in, or the nearest within 15 m. Places in longitude and
latitude are put on the scene by its corner (0, 0), which the panel asks for, as the Infer Charge
sheet does. A stone building's walls are weighed as masonry. The panel then says how many entries
matched, on how many buildings (and how many of those are the far field's), how many found no
building, and how many records were left out because their class is not one the network weighs.

**Beirut's survey through it** (`charge-from-damage survey`, the panel's code headless: the 2.5 km
scene, the corner 35.491954 E, 33.878942 N). The survey's data are on StudioData under
Beirut2020/GEER2021 with its SOURCE.md (ODC-By), not committed.
- **What matched:** GEER's 9,175 façades and 155 buildings (in person and from 360° photographs),
  8,724 of 9,330 entries on 1,354 buildings. 606 found no building within 15 m, and 34 records were
  left out (mixed structures, straddling classes).
- **What was marked:** 1,266 buildings' glass and 141 buildings' walls, 50 of them stone. Stage 1's
  matching gave 1,351 and 139.

| Marks | Independent: yield (90%) | Shared: yield (90%) | Likeliest place | Warehouse 12 in the 90% region |
|---|---|---|---|---|
| Stone walls, 50 | 0.71 kt (0.30–1.63) | **0.70 kt (0.21–2.16)** | 173 m south of the warehouse | yes, and in the 50% region |
| All walls, 141 | 2.69 kt (1.82–3.21) | 2.08 kt (0.97–3.14) | 178 m north | yes |
| Glass, 1,266 | 29 t (25–34) | 29 t (13–66) | 386 m north-west | no |
| Everything, 1,354 | 29 t (25–34) | 29 t (13–66) | 386 m north-west | no |

With the place held at the warehouse, the stone reads 0.70 kt (0.28–1.66) shared, against 0.71 kt
(0.49–0.89) independent.

The accepted figures are 0.50–0.54 kt from the arrivals (90%: 0.36–0.85), Rigby et al.'s 0.50 kt,
Stennett et al.'s 0.64 kt and Pilger et al.'s 0.13–2 kt.
- **The stone holds them.** Its shared 90% interval holds every one of these, and its place regions
  hold Warehouse 12.
- **The glass does not.** It reads 13–66 t, the quick estimate's known bias against GEER
  ([above](#on-beiruts-surveys)). It is wider now, but still nowhere near the true yield, and the
  panel's past-100 warning shows.
- **So on Beirut:** load the structural tables alone, or clear the glass, to read the yield.

**Kept with the project.** The marks are saved as `chargeMarks.json` in the project package
(`ChargeFromDamage.SavedMarks`): each building's glass and walls by its id, the stone taken as
masonry, the place searched about if it was moved, the weighing if it is not the default, and the
survey's corner. They are weighed again once the panel reads the scene's buildings. A project saved
before has no such file and opens as it did. An older BombCAD keeps the file untouched, as it keeps
any file it does not know.

**The far field's buildings** (New District's near and far) can be marked: a click on one marks it,
and Mark from the Damage Shown and a survey take them in. It was cheap because the far field's own
`combined(with:)` already gives the near and far scene the network's features need, picking already
reached far buildings, and their outlines come from their blocks. Far buildings 0.6–2.5 km out say
most about the yield (the network reads distances to 8 km); the place is still searched within
500 m.

**Frame times** (release build, offscreen, `InterfaceReviewChargeMarkingTests` as in stage 2, the
Studio loaded by other sessions; 60 buildings marked one at a time on the mixed district):

| Step | Shared: median (most) | Independent: median (most) |
|---|---|---|
| A mark weighed into the others, to the posterior | 0.98 ms (1.24) | 0.42 ms (1.10) |
| The paint, outlines and words laid out | 0.14 ms (0.29) | 0.18 ms (0.36) |
| A frame at 1800 × 1200, GPU | 5.6 ms (12.1) | 6.2 ms (11.9) |
| Click to frame drawn and read back | 10.1 ms (85.3) | 10.7 ms (90.9) |

The shared error's blur costs about half a millisecond a mark, so each mark still shows within a
frame at 60 fps but for the read-back. The same test's twelve charges, marked from the quick
estimate (852 marks each), now hold the true yield in the 90% interval for 11 of 12 charges, against
3 of 12 weighed as independent, and the place in its 90% region for 7, against 4. The median errors
are unchanged: 31 m, and ×1.34 against ×1.37. (Its 3, 10 and 30 marks are drawn from an order that
changes from run to run, so those rows are not comparable between runs. The headless judgement
above is the measure.)

The judgements, looks and sweeps are in `$BOMBCAD_DATA/scratch/issue116/stage3`.

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
- **The scene's glass in the app is the surrogate's alone.** Simulation ▸ Infer Charge from
  Arrivals… weighs a survey on the scene's own buildings ([below](#in-the-app)) without a run near
  the estimate. On BombCAD's own runs, the glass alone placed the charge 20–70 m off, and a run there
  did not help it (above).
- **The learned reading of marks** ([above](#the-charge-from-marked-damage-learned-1-november-2026))
  is as good as the quick estimate's chances it learned, and knows no shielding.
- **Walls as a check, and stone only.** Beirut's stone buildings say a yield consistent with the
  arrivals. Its concrete buildings say 3–5 kt, because the model has no infill walls
  ([above](#beiruts-surveyed-damage-20-october-2026)).

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
