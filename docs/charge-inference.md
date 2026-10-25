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
- **The scene's glass in the app is the surrogate's alone.** Simulation ▸ Infer Charge from
  Arrivals… weighs a survey on the scene's own buildings ([below](#in-the-app)) without a run near
  the estimate. On BombCAD's own runs, the glass alone placed the charge 20–70 m off, and a run there
  did not help it (above).
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
