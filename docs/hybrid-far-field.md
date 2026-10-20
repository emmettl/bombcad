# A city in minutes: the air near, the surrogate far

A district run spends most of its time on air that has stopped mattering much. Beyond a
kilometre at 0.5 kt the shock is weak and nearly spherical, yet the full Beirut run still carries
it on 4 m cells for another 6 s and 3 km. The hybrid mode runs the air in 3-D only out to a
hand-over radius. Beyond it, each façade's load comes from the [façade load
surrogate](surrogate-first-look.md), matched to the near run where both hold. It is the first step
of [Horizons](roadmap.md#horizons) item 3, "City scale in minutes". It is in the app under File ▸
New District, and headless in SceneBench.

## What holds and what does not

Judged on Beirut against the full 4 m runs at 0.2, 0.5 and 1.1 kt ([Beirut,
2020](beirut-2020.md)), handing over at 1 km:

- **Holds: inside the hand-over.** The near run is the full run there. On a box reaching 1,320 m
  (the hand-over and 4 m/kg^(1/3) beyond it), its façade strips' peaks are the full run's to within
  3–8% (median 1.00) and its glass states identical.
- **Holds: the time.** The near run took 135, 335 and 230 s on the CI mini against the full run's
  1,604, 2,017 and 2,464 s. The far field's loads take a few seconds, and laying out and judging
  all 14,169 buildings about a minute on the Studio. At 0.5 kt the whole district takes about
  7 minutes against 34.
- **Holds: the glass to 1.5 km at every yield.** The share of building sides with some glass broken
  comes within 0.04 of the full run's there; to 2 km at 0.5 kt and to 2.5 km at 1.1 kt.
- **Holds: arrivals.** Beyond the hand-over, Kingery–Bulmash's arrival scaled to the near run's
  comes 2–4% before the full run's. Against Rigby et al.'s observers past 1 km that is 0.95–1.08
  of the observed at 0.5 kt, and 0.91–1.02 at 1.1 kt.
- **Does not: the far edge at the small yield.** At 0.2 kt the share broken falls 0.16–0.28 below
  the full run's from 1.5 to 2.5 km. The near run's trend with distance, carried on, falls faster
  there than the run does; the surrogate unscaled is closer.
- **Does not: blown-out glass in every band.** Its share differs from the full run's by up to 0.22
  in a band (0.5 kt: 0.37 against 0.59 at 1.25–1.5 km).
- **Does not: walls and roofs beyond the hand-over.** They take the surrogate's standing, which
  says to run the scene for the structure.
- **Inherits the full run's verdict against GEER.** Close in it breaks more glass than GEER saw;
  the far edge is about right ([Beirut](beirut-2020.md#what-holds-and-what-does-not)).

## How it works

1. **The near run.** The district is laid out on a box reaching the hand-over and its open faces'
   clearance beyond (4 m/kg^(1/3): 320 m at 0.5 kt). The air runs until the blast has passed the
   hand-over and its façades have been loaded (3 s at 1 km), with each façade strip's history
   recorded. Its half side is a multiple of the cells, so that its cells and buildings are the full
   layout's.
2. **The match.** Over the near run's strips just inside the hand-over (0.8–1 of it), the median
   of its peak over the surrogate's, and of its first impulse. Over those from half the hand-over,
   the slope of that ratio's logarithm with the logarithm of distance. Over its gauges from
   500 m, the median of their arrival over Kingery–Bulmash's (`HybridFarField.fit`).
3. **The far field.** Every component beyond the hand-over takes the surrogate's prediction (its
   features along a line over the ground, Kingery–Bulmash's base, the fitted terms). Its peak and
   impulse are scaled by the match at the hand-over and carried on its trend; its arrival is
   scaled likewise (`HybridFarField.apply`). It is then a triangular pulse, as in the first look.
4. **The damage.** The near run's histories inside, the far field's pulses beyond, judged by the
   same SDOF, panes and glazing mixes as a run's (`EnvelopeDamageAssessment`).

The shielding in the far field is the surrogate's: the buildings a line over the ground passes
through, the length inside them, ridges and the ground's rise. It was fitted to BombCAD's runs,
and one shielding model serves both the first look and the hybrid.

Matched at 0.5 kt, the surrogate needed its peak raised by 1.09 and its impulse by 1.20 at 1 km,
falling as distance^-0.47 and ^-0.30 beyond.

## Against the full run, by band

Sides with some glass broken, full run / hybrid (the surrogate unscaled), and the hybrid's
façade peak over the full run's (median). The 0.2 kt column was rerun on 19 October with the
surrogate held at its fitted range's ends, which moves its far edge; the others predate it.

| Distance | 0.2 kt | 0.5 kt | 1.1 kt | Peak, 0.2 / 0.5 / 1.1 kt |
|---|---|---|---|---|
| 0.5–1 km | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 | 1.00 / 1.00 / 1.00 |
| 1–1.25 km | 1.00 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 0.95 / 0.99 / 0.99 |
| 1.25–1.5 km | 0.99 / 0.95 (0.97) | 1.00 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 0.88 / 0.93 / 0.96 |
| 1.5–1.75 km | 0.84 / 0.68 (0.82) | 0.99 / 0.99 (1.00) | 1.00 / 1.00 (1.00) | 0.89 / 0.98 / 1.04 |
| 1.75–2 km | 0.61 / 0.33 (0.52) | 0.91 / 0.93 (0.98) | 0.99 / 1.00 (1.00) | 0.79 / 0.91 / 0.99 |
| 2–2.5 km | 0.23 / 0.07 (0.15) | 0.66 / 0.51 (0.77) | 0.94 / 0.95 (1.00) | 0.76 / 0.88 / 1.00 |
| 2.5–3 km | 0.02 / 0.02 (0.06) | 0.18 / 0.18 (0.47) | 0.65 / 0.78 (0.97) | 1.09 / 1.12 / 1.29 |

Carrying the trend only to 1.5 times the hand-over and holding it beyond, as the app does, moves
the share broken at 1.75–2 km to 0.40, 0.96 and 1.00, at 2–2.5 km to 0.10, 0.69 and 0.99, and at
2.5–3 km to 0.04, 0.38 and 0.95 (0.2, 0.5 and 1.1 kt). That is closer to the full run at 0.2 kt
and at 2–2.5 km at 0.5 kt, and further at 2.5–3 km at the larger yields. Carrying it to twice the
hand-over lands between the two (`--trend-reach`).

Beyond about 2.2 km the full run's own side faces lie near the buildings
([Beirut](beirut-2020.md#what-the-model-can-and-cannot-represent)), so its far bands are the less
sure reference. Impulses run 1.04–1.5 times the full run's from the hand-over to 2.5 km, and up to
1.9 times at 2.5–3 km.

## Using it

- **Bench (headless):** two steps, the near run and then the district.

  ```bash
  scenebench district-compare <inputs> --dx 4 --height 320 --radius 1320 --until 3 --window 0.5 --save-loads near-loads --out near
  ```

  ```bash
  scenebench district-hybrid <inputs> --dx 4 --height 320 --radius 2500 --near-loads near-loads --near-radius 1320 --near-report near/comparison.json --handover 1000 --out district.json
  ```

  `district.json` holds each building's damage, as `BombCAD run --envelope-damage` writes it, with
  the mode's method, its standing and the match. `scenebench hybrid-judge` sets it against a full
  run's saved loads; unlike `district-hybrid`, it fits the trend only when given `--trend-from`
  (500 m for a hand-over at 1 km), and otherwise carries the match on flat.
- **In the app:**

  ![Beirut at 0.5 kt in the app: the air run to the hand-over at 950 m on 3 m cells, painted with its pressure and its buildings' damage, and the 7,245 buildings beyond judged after the run on the far field (blue: glass broken; pale: none)](hybrid-far-field-app.png)

  Beirut at 0.5 kt through New District on a Studio, cells left to the advisor: the whole district
  would have taken 5 m cells, so it handed over at 950 m on uniform 3 m cells. The run and the
  judgement of the 7,245 far buildings took 8 minutes, the judgement 91 s of it, matched at the
  hand-over at peak ×1.06 and impulse ×1.27 (`HybridDistrictImageTests`). On uniform 4 m cells
  given by hand it took 3 minutes, matched at ×1.12 and ×1.21.

  File ▸ New District with **Near field and far field** on (the default when the
  radius reaches 1.25 times the hand-over). The sheet hands over at 12 m/kg^(1/3), rounded to 50 m,
  and draws the hand-over on the map. Lay Out weighs that against this Mac's memory and the run's
  time, with the cells left to the advisor.
  - **No far field** while the whole district runs in the air on 4 m cells (those the surrogate
    was fitted on) within an hour unloaded.
  - **Otherwise the hand-over is brought in** by tenths, to half of it and no nearer than 50 m,
    until the near run does. The sheet says which, and why
    (`NewDistrictModel.advisedHandover`). The project's air reaches the hand-over; the buildings beyond
  it are kept beside it (saved as `farField.json`, never voxelised) and drawn with the rest. When the run
  ends they are judged in seconds on the cores and painted with their damage, labelled "far field
  estimate" in the Envelope damage section with the match and its standing. Their sides' glass
  chances are drawn over the far field's scatter and each building's glass strength, as the
  quick estimate's are (`HybridFarField.judge(..., glass:)`), and the view colours by them. The app carries the
  trend to 1.5 times the hand-over and holds it from there (`FarFieldSet.trendReachDefault`; see
  below).

## Limitations

- **The hand-over must lie where the near run's façades are loaded in full.** At 1 km on Beirut
  the near run reaches 3 s; a nearer hand-over leaves the surrogate more to carry.
- **One charge on the ground**, as the surrogate and Kingery–Bulmash assume.
- **The trend is a straight line in log distance**, fitted over the near run's half of the
  hand-over. Where the district changes beyond it (a ridge, the sea, a denser core), the surrogate's
  own terms must carry the change.
- **Judged on one city.** Beirut's full runs are its reference, with their own limits on 4 m cells.

## Future work

- **A hand-over chosen by the run**, where the shock has weakened past a threshold, rather than
  given.
- **The trend damped** toward the surrogate's own form far out, which held better at 0.2 kt. The
  reach held at 1.5 times the hand-over is a first, cheap form of it.
- **Far buildings in the app's other views.** They are painted in the viewport and the map, but
  picking, the inspector and the damage table's per-component rows hold only the near buildings.
