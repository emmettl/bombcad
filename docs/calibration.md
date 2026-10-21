# Calibrating parameters against the validation record together

The first step of calibrating the model's own uncertain parameters against many validation
comparisons at once, rather than each regime by hand. It uses a Kennedy–O'Hagan posterior, with
a discrepancy for each regime, over emulators fitted to a small design of runs (20 October 2026,
emmettl/bombcad-work#35).

**Standing: a study.** Nothing here changes a default. It gives three of the model's parameters
the spread that 21 comparisons allow, and asks three questions:
- whether that spread differs from today's hand-chosen values;
- whether the discrepancies swamp the parameters (the idea's stop rule);
- which data would narrow the spreads most.

**In short:**
- Today's afterburning time and concrete tension lie well inside their posteriors.
- Today's glass strength lies at the posterior's weak edge: the comparisons favour glass about a
  quarter stronger, as if a fifth of a pane bore its largest stress. Most of that pull is E1300's
  own flaw-model integral, not a test ([review](#independent-review-20-october-2026)).
- The discrepancies widen the afterburning time from a third of its prior to three-quarters, and
  the glass from an eighth to near three-quarters. That half-swamps those two but does not kill
  the idea.
- The concrete's tension is decided by one beam changing how it fails, not by the discrepancy.
- What would narrow it most: tests that pin a regime's own error. For glass, panes that only
  just break (68% narrower); for the air, open-air impulses with their scatter by distance (48%).
  Those figures are for an error known exactly; known to ±10% they are 41% and 17%.

## The choice

Declared on the issue before any run.

**Parameters**, each with a prior uniform in its logarithm:

| Parameter | Range | Today | What it is |
|---|---|---|---|
| `afterburnTime` | 3–30 ms/kg^⅓ | 10 | The time over which detonation products that meet air burn; chosen by hand so that the open blast's incident impulse matches Kingery–Bulmash ([afterburning](air-blast-model.md#afterburning)) |
| Concrete tension | 0.6–1.6 | 1 | A factor on the tensile strength the model takes for every concrete, from its correlation with the compressive strength or as measured |
| Glass flaw factor | 0.01–3 | 1 | A factor on the flaw constant k of ASTM E1300's flaw model, or equally on the share of a pane at its largest stress (1: the whole pane, today's). The 60 s strength goes as its −1/7 power ([window glass](validation.md#window-glass)) |

**Comparisons**, 21 outputs in seven regimes, each regime with a discrepancy of its own:

| Regime | Comparisons | Reads |
|---|---|---|
| Air, incident | Kingery–Bulmash's incident impulse at Z = 1, 2 and 4 m/kg^⅓: one 100 kg surface burst, 0.25 m cells, the recommended air | afterburning time |
| Air, reflected | Kingery–Bulmash's reflected impulse at the same distances: three rigid-wall runs | afterburning time |
| Concrete, static | Janney's beam, peak moment; OA1, peak load | tension |
| Concrete, impact | Saatci's SS2b-1, peak and residual deflection; Peterson's D-1d-NoS and D-2d-S90, impact force | tension |
| Concrete, blast | The contest slab, peak deflection (its load prescribed) | tension |
| Glass, break time | Monk and Clubley's four aspect ratios, break time on the measured load | glass factor |
| Glass, threshold | ASTM E1300's load resistance of four panes (A, D, T and CC of Soules, Morse and Norville) | glass factor |

Each case reads only its own parameter: the air's cases have no concrete or glass, the structural
cases prescribe their loads, and the glass cases take measured loads.

**Each comparison's error**, on the logarithm, is the square root of the sum of squares of:
- **the measurement's scatter:** its repeats' scatter where it has any (Monk and Clubley's panes,
  Peterson's beams, the contest slab's repeat); Kingery–Bulmash's ±6.7% on incident impulse
  ([3g](data-survey.md#3g-the-reference-curves-own-scatter)); 10% for its calculated reflected
  curves and for a single test, assumed;
- **the specimen's own inputs:** their spread, from the
  [ensemble](validation.md#the-models-spread-from-uncertain-inputs) where recorded (2–25%). This
  is conservative, since that spread included the tension now calibrated;
- **the emulator:** its uncertainty, including the runs' own scatter about their trend.

## The method

- **Design.** Today's values, then a Latin hypercube of 12 points over the three parameters,
  uniform in their logarithms (`Scripts/calibration/design.py`). The same 13 points serve every
  case, each case's own inputs at their middle values.
- **Runs.** `BombCAD ensemble <cases> --design design.json` runs each case at each point and
  prints each run's outputs. `Scripts/calibration/runs.py` sends the cases to the CI mini through
  `Scripts/remote.py`, with its lock and its waiting, in three chunks of under an hour, and
  gathers the runs.
  - 169 runs took 52 minutes of computing on the mini, two hours with its build and queue. (The
    kept `runs.jsonl` holds 130, ten cases at 13 points; the review could not trace the 169.)
  - The mini's results match the Mac Studio's to the last digit (the open burst's impulses, the
    one case run on both).
  - The new cases are `kb-open`, `kb-reflected`, `glass-monk` and `glass-e1300`. The air's take
    `afterburnTime` and the glass's `glassK`; the structural cases already took `ft`.
- **Emulators.** One Gaussian process for each output's logarithm over its own parameter's unit
  interval (`Scripts/calibration/calibrate.py`, numpy only). Each has a linear mean, a
  squared-exponential kernel, and a nugget for the runs' own scatter, all found by the marginal
  likelihood. Leave-one-out errors: 0.0–0.6% for the air, glass and Peterson's and the contest
  slab's responses; 2–7% for Saatci's, OA1's and Janney's, about their own scatter.
  - **Each emulator is over one axis.** Over all three, the scatter of Janney's, OA1's and
    Saatci's runs was fitted as dependence on parameters those cases never read: Saatci's peak
    "followed" the glass at −0.56.
- **Posterior.** For each comparison, log(model / measured) = δ_regime + u + e:
  - δ_regime: the regime's shared discrepancy, normal with a standard deviation of 0.3,
    marginalised;
  - u: the comparison's own discrepancy, normal with a standard deviation s_regime (half-normal,
    scale 0.15);
  - e: its error above.

  The parameters and the seven spreads are sampled by a stretch-move ensemble (40 walkers, 3,000
  steps, the second half kept; the script's default is 4,000, and the figures here are 3,000 at
  seed 1). Beside it, the same with no discrepancy (δ = u = 0), the hand fit's assumption. Rerun,
  the widths move by up to about 0.08: the afterburning time's read 0.74 and 0.82 in runs that
  differed only in the glass, which it does not read. There is no convergence diagnostic.
- **Which data.** The posterior's precision, linearised at its medians, with three candidate
  additions for each regime:
  - its shared discrepancy pinned;
  - as many comparisons again, like its own;
  - repeats halving its scatter.

  For each, how much narrower each parameter would be.

```bash
python3 Scripts/calibration/design.py > Scripts/calibration/design.json
python3 Scripts/calibration/runs.py kb-open,kb-reflected,glass-monk,glass-e1300,peterson-d-1d-nos,peterson-d-2d-s90 --out runs.jsonl
python3 Scripts/calibration/runs.py janney,oa1 --out runs.jsonl
python3 Scripts/calibration/runs.py contest-slab,saatci --out runs.jsonl
python3 Scripts/calibration/calibrate.py runs.jsonl [--bias-sd 0.3] [--json posterior.json]
```

The runs of 20 October are kept in `Scripts/calibration/runs-2026-10-20/`, so the posterior can be
rerun in a minute without them.

## Results

**The responses.** What each comparison does across its parameter's range, from the runs:
- **The air.** Each impulse falls as the burning slows, over the range from 3 to 30 ms:
  - the incident impulse by 34–36% at every distance;
  - the reflected impulse by 12%, 19% and 35% at Z = 1, 2 and 4.
- **Saatci's beam** changes how it fails near a tension factor of 0.9:
  - below it, peak 44–46 mm and residual 26–33 mm;
  - from 0.97 up, peak 35–37 mm and residual 13–18 mm;
  - measured: 37.9 and 18.5 mm.

  OA1's peak load rises with tension to about 0.9 of today's, then holds at 350–380 kN (332
  measured). The contest slab's peak falls from 117 to 110 mm over the range (109 measured).
  Peterson's impact forces rise 2–3%.
- **Janney's peak moment** scatters by 5% from run to run, with no trend: it is the bars'.
- **The glass.**
  - Monk and Clubley's break times lengthen by 23–43% from the factor's top to its bottom.
  - E1300's load resistances grow two- to threefold. At today's values they are 0.57–0.65 of
    E1300's, as [the record](validation.md#the-threshold-against-astm-e1300) has them.

**The parameters**, median (90% interval) and width against the prior's (in the logarithm):

| Parameter | Today | No discrepancy | Width | With discrepancy (0.3) | Width |
|---|---|---|---|---|---|
| Afterburning time, ms/kg^⅓ | 10 | 12.2 (8.9–18.3) | 0.33 | 15.5 (5.5–28.1) | 0.75 |
| Concrete tension, factor | 1 | 1.07 (0.82–1.52) | 0.71 | 1.16 (0.80–1.55) | 0.74 |
| Glass flaw factor | 1 | 0.043 (0.030–0.062) | 0.13 | 0.22 (0.030–1.49) | 0.71 |

The regimes' shared discrepancies, model over measured, median (90%):

| Regime | Model / measured | Spread within the regime |
|---|---|---|
| Air, incident | 0.94 (0.84–1.17) | 0.05 (0.01–0.17) |
| Air, reflected | 1.04 (0.91–1.21) | 0.07 (0.01–0.21) |
| Concrete, static | 1.05 (0.89–1.25) | 0.08 |
| Concrete, impact | 0.93 (0.79–1.11) | 0.07 |
| Concrete, blast | 1.02 (0.78–1.32) | 0.09 |
| Glass, break time | 0.91 (0.80–1.08) | 0.08 |
| Glass, threshold | 0.76 (0.56–1.24) | 0.06 |

**Against the discrepancy's prior.** With the shared discrepancy's standard deviation at 0.1, 0.3
and 0.5:

| Parameter | 0.1 | 0.3 | 0.5 |
|---|---|---|---|
| Afterburning time | 15.6 (7.4–27.8), width 0.62 | 15.5 (5.5–28.1), 0.75 | 16.5 (5.0–28.3), 0.80 |
| Concrete tension | 1.10 (0.77–1.53), 0.75 | 1.16 (0.80–1.55), 0.74 | 1.14 (0.77–1.55), 0.75 |
| Glass flaw factor | 0.092 (0.032–0.25), 0.37 | 0.22 (0.030–1.49), 0.71 | 0.37 (0.044–2.14), 0.72 |

## The answers

**1. Against today's values.**
- **Afterburning time.** Today's 10 ms lies inside every posterior. Without discrepancy the
  comparisons favour 12 ms (9–18): the incident impulse at Z = 4 reads 106% today, and a slower
  burning lowers it. With discrepancy they say little more than the prior.
- **Concrete tension.** Today's factor of 1 lies inside every posterior. The comparisons rule
  out a tension much below today's (under about 0.8), where Saatci's beam fails in a way the test
  did not. Above it they hardly care.
- **Glass.** Today's whole pane at E1300's flaw constant is the posterior's weak edge:
  - without discrepancy it is excluded outright (0.03–0.06);
  - with discrepancy it lies inside, near the 90th percentile (0.030–1.49).

  The comparisons want glass stronger by a factor of 1.2 to 1.6 (the strengths of the two
  medians, not an interval), the strength going as the
  factor's −1/7 power. Equally, a fifth (0.03–1) of a pane at its largest stress, where the
  record's hand analysis found a third to a tenth fitting one set or the other but not both
  ([window glass](validation.md#window-glass)).
  - **Why it pulls that way.** E1300's threshold wants glass half as strong again; Monk and
    Clubley's break times (today 0.81–1.07 of the measured) want it only a little stronger.
  - **What the discrepancy does.** It lets the threshold regime read about a quarter weak (0.76)
    rather than move the strength that far.
  - **Today's whole pane** is the safe side: panes break under lower loads than E1300 says,
    further from a charge. The calibration does not argue for moving it without the threshold
    tests below.

**2. Does the discrepancy swamp the parameters?** Partly, and not enough to stop.
- **Only one parameter acts within each regime.** So with a free shared discrepancy the parameter
  is learnt only from how differently it moves the regime's comparisons. This is
  Kennedy–O'Hagan's known confounding: the parameter and the discrepancy trade off.
- **Afterburning time.** It moves the three incident impulses alike (34–36% over its range),
  so the incident regime cannot tell it from its own discrepancy. Only the reflected impulses
  (12–35%) differ, and their curves were calculated. The afterburning time keeps three-quarters
  of its prior's width (0.62–0.80 as the discrepancy's prior goes from 0.1 to 0.5).
- **Glass.** The two regimes' sensitivities differ more (0.25–0.44 against 0.8–1.3 a unit). So
  the glass keeps more information, but how much depends on the discrepancy's prior: 0.37 of the
  prior's width at 0.1, 0.71–0.72 at 0.3–0.5.
- **Concrete tension.** Not swamped at all. Its information is a threshold, Saatci's change of
  failure, which no smooth discrepancy can mimic. Otherwise the comparisons are flat in it.
- **So the parameters are not swamped,** but the joint calibration earns its keep only where a
  parameter acts on comparisons with differently shaped responses. The stop rule's "the
  emulators need too many runs" is not met: 13 runs a case gave emulators within the runs' own
  scatter.

**3. What would narrow them most** (linearised at the posterior's medians):

| Parameter | Most | Then |
|---|---|---|
| Glass flaw factor | the threshold regime's own error pinned: **68% narrower** | the break-time regime's pinned, 19%; repeats of the threshold, 16% |
| Afterburning time | the incident regime's own error pinned: **48% narrower** | the reflected regime's pinned, 19%; repeats, 2–7% |
| Concrete tension | nothing linear (its information is a threshold) | tests near a change of failure, with tension measured and varied |

**Pinning a regime's error** means a comparison whose error is known apart from the parameter:
- **Glass.** Panes held beside panes broken, at loads near the threshold, so that the breaking
  probability is itself measured: Johns and Clubley's, first in
  [data wanted](data-wanted.md#to-fetch) since the search of 20 October (Beauchamp and Matalucci's
  EMRTC tests describe weakened tempered glass, not a threshold series). E1300's load resistance
  is a model (Beason and Morgan's) of tests, not a test: its own error is unknown here.
- **The air.** Kingery's data by distance, rather than pooled (BRL 1344, in
  [data wanted](data-wanted.md#to-fetch)), with their scatter. Also, on the model's side, the
  same comparison on finer cells: part of the incident regime's 0.94 is the grid's under-resolution
  ([close in](validation.md#close-in)), which a converged run would take out of the discrepancy.
- **Repeats of what is already compared** help little in every regime: more of the same does not
  separate the parameter from the regime's error.

## Independent review, 20 October 2026

A cloud session reran the calibration from the committed runs (numpy, Linux) and checked it. It
reproduces: the posteriors, the shared discrepancies, the sensitivities and the ranking to the
digits given at 3,000 steps and seed 1, and the 0.1 column of the prior's table. The emulators'
leave-one-out errors are as stated, and their rms matches their predicted spread (0.020 against
0.020 for Saatci's peak, 0.065 against 0.057 for its residual). The likelihood and the sampler
are correct as written. Its report is kept outside the repository, at
`/Volumes/StudioData/bombcad/cloud-reports/2026-10-20/review-crackedhex-calib.md`. What it found:
- **The glass threshold regime is a model against a model.** Its four "measurements" are E1300's
  load resistances, and its outputs BombCAD's own Beason–Morgan flaw model with the whole pane at
  its largest stress; E1300's charts are the same flaw model with the risk integrated over the
  pane. So the regime measures what share of the pane makes the one reproduce the other, close to
  deterministic, and with sensitivities two to five times the break times' it sets the glass's
  posterior. Only the break times are evidence about glass from tests. Either take the regime out
  and set the stressed share by calculation, or read its result as that share.
- **The ranking follows from the set-up.** Each regime reads one parameter, so with its shared
  discrepancy's prior of 0.3 its information is capped along the direction that moves all its
  comparisons together, and a discrepancy pinned exactly wins by construction. Pinned to a stated
  precision instead:

| Regime pinned to | exactly | ±5% | ±10% | ±20% |
|---|---|---|---|---|
| Glass, threshold: the glass narrower by | 68% | 58% | 41% | 15% |
| Air, incident: the afterburning time narrower by | 48% | 34% | 17% | 4% |
| Glass, break time: the glass narrower by | 19% | 12% | 6% | 1% |

  A fairer rival is a comparison whose response has a different shape, as the reflected impulses'
  has.
- **Scatter from two repeats** has one degree of freedom: Monk and Clubley's 1:1.3 pane gets 1.7%.
  Pooling their twelve break times' scatter (12.7% in the logarithm) doubles the no-discrepancy
  glass factor, 0.044 to 0.085, and moves "1.6 times as strong" to 1.4. Today's glass stays
  excluded without discrepancy.
- **Fixed: d₂ for four repeats.** The repeats' scatter divided any range of three or more by 1.693,
  d₂ for three; for four it is 2.059. Monk and Clubley's 1:1.7 and 1:2 panes, four repeats each,
  had 0.169 and 0.214 for 0.139 and 0.176. `ValidationEnsemble.scatter` now takes d₂ for two to ten
  repeats. The committed `measured.json` keeps the values the runs were made with; rerun with the
  right ones, the posterior moves within the sampler's noise.
- **Smaller points.** Kingery–Bulmash's three distances are treated as independent errors, though
  read off one smooth fit (the no-discrepancy afterburning time may count them up to three
  times). The regimes' spreads sit near their half-normal prior's median, and the one-comparison
  regime (concrete, blast) is the prior's. Saatci's change of failure lies between design points
  0.87 and 0.97, so the tension's lower tail rests on how the emulator bridges a step it did not
  see: three or four runs between 0.85 and 1.0 would settle it. Peterson's D-2d-S90 force is
  238.0 kN in the script against the tests' mean 238.5.

## What this does not do, and next

- **Three parameters, chosen so they barely interact.** Joint calibration across parameters pays
  where cases read several: Wu's and Chiquito's slabs read the afterburning time and the
  concrete's tension together, at 20–30 and 5–13 minutes a run on the mini.
- **The concrete's other parameters.** The [ensemble](validation.md#the-models-spread-from-uncertain-inputs)
  found that the fracture energy, not the tension, moves OA1 and Saatci most. It is the better
  concrete parameter for a second step.
- **Specimens at their middle inputs.** Their spread is carried as each comparison's error, not
  sampled with the parameters; it included the tension, so it is counted twice, on the safe side.
- **A scalar discrepancy per comparison.** Kennedy and O'Hagan's discrepancy is a function over
  the inputs; here each comparison has its own, with a regime's shared part. With more
  comparisons per regime, a discrepancy over distance (air) or pane size (glass) would say where
  the model drifts.
- **Kingery–Bulmash and E1300 stand in for tests.** They are fits to tests, with their stated
  scatter. Kingery–Bulmash's reflected curves were calculated, not measured.
- **Nothing feeds the error bands yet.** The posterior's spreads could become the bands'
  parameter term ([standing](standing.md)) once a discrepancy's prior is argued rather than
  assumed.
