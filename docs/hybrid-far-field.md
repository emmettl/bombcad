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
- **Holds: the glass to 1.75 km.** The share of building sides with some glass broken comes within
  0.04 of the full run's to 1.75 km at 0.2 and 0.5 kt and to 2 km at 1.1 kt (on the surrogate's
  terms refitted on 23 October 2026; [below](#on-the-refitted-surrogate-23-october-2026)).
- **Holds: arrivals.** Beyond the hand-over, Kingery–Bulmash's arrival scaled to the near run's
  comes 2–4% before the full run's. Against Rigby et al.'s observers past 1 km that is 0.95–1.08
  of the observed at 0.5 kt, and 0.91–1.02 at 1.1 kt.
- **Does not: the loads at the large yield beyond 1.5 km.** At 1.1 kt the far field's peaks read
  1.12–1.19 of the full run's from 1.5 to 2.5 km and its impulses 1.6–2.0 times. At 0.2 kt, where
  the share broken fell 0.16–0.28 below the full run's on the terms before, it now falls 0.01–0.06
  below.
- **Does not: blown-out glass in every band.** Its share differs from the full run's by up to 0.19
  in a band (1.1 kt: 0.88 against 0.69 at 1.5–1.75 km; 0.5 kt: 0.42 against 0.60 at 1.25–1.5 km).
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

Fading the match back to the surrogate's own loads past the reach instead of holding it
(`--trend-damping d`: the match's logarithm falls by e each d of log distance) was judged the same
way on 20 October, rerunning the hold on the same build. Over 1–2.5 km, the mean error in the
share of sides with some glass broken, against the full run, at 0.2, 0.5 and 1.1 kt:

| Past 1.5× the hand-over | 0.2 kt | 0.5 kt | 1.1 kt | Blown out, 1.1 kt |
|---|---|---|---|---|
| Held (the app's) | 0.103 | 0.013 | 0.012 | 0.043 |
| Faded, d = 0.7 | 0.090 | 0.021 | 0.013 | 0.026 |
| Faded, d = 0.35 | 0.080 | 0.029 | 0.013 | 0.023 |

Fading helps at the small yield, where the surrogate's own form is the better one, and with the
blown-out share at the large one. It does worse at 0.5 kt, and beyond 2.5 km it raises the share
broken above the full run's at the larger yields (0.41–0.44 against 0.18 at 0.5 kt; 0.96 against
0.65 at 1.1 kt), where the held match already ran over. No fading length gains overall, so the app
holds the match (`FarFieldSet.trendDamping` nil). The results are in
`$BOMBCAD_DATA/hybrid-damp` (`compare.py`).

Beyond about 2.2 km the full run's own side faces lie near the buildings
([Beirut](beirut-2020.md#what-the-model-can-and-cannot-represent)), so its far bands are the less
sure reference. Impulses run 1.04–1.5 times the full run's from the hand-over to 2.5 km, and up to
1.9 times at 2.5–3 km.


### On the refitted surrogate (23 October 2026)

The surrogate's terms were refitted on air refined to 2 m and given shielding by the charge's
surroundings (emmettl/bombcad-work#56; [the first look](surrogate-first-look.md#adopted-23-october-2026)).
The same judge on the adopted terms, trend from 500 m carried on (`hybrid-judge --trend-from 500`),
as the table above, with a rising trend held at nothing (below):

| Distance | 0.2 kt | 0.5 kt | 1.1 kt | Peak, 0.2 / 0.5 / 1.1 kt | Impulse, 0.2 / 0.5 / 1.1 kt |
|---|---|---|---|---|---|
| 1–1.25 km | 1.00 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 0.99 / 0.98 / 0.98 | 1.04 / 1.07 / 1.14 |
| 1.25–1.5 km | 0.99 / 0.98 (0.97) | 1.00 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 0.95 / 0.97 / 0.98 | 1.09 / 1.14 / 1.28 |
| 1.5–1.75 km | 0.84 / 0.83 (0.77) | 0.99 / 1.00 (1.00) | 1.00 / 1.00 (1.00) | 1.01 / 1.07 / 1.12 | 1.25 / 1.34 / 1.58 |
| 1.75–2 km | 0.61 / 0.55 (0.48) | 0.91 / 0.98 (0.98) | 0.99 / 1.00 (1.00) | 0.97 / 1.07 / 1.15 | 1.26 / 1.36 / 1.67 |
| 2–2.5 km | 0.23 / 0.17 (0.13) | 0.66 / 0.75 (0.73) | 0.94 / 1.00 (0.99) | 0.97 / 1.08 / 1.19 | 1.42 / 1.55 / 1.98 |
| 2.5–3 km | 0.02 / 0.06 (0.04) | 0.18 / 0.44 (0.42) | 0.65 / 0.97 (0.96) | 1.49 / 1.51 / 1.68 | 1.82 / 1.93 / 2.54 |

- **The small yield's far edge closes up.** At 0.2 kt the share broken now falls 0.01–0.06 below
  the full run's from 1.5 to 2.5 km, where it fell 0.16–0.28 below.
- **The large yield still reads high beyond 1.5 km**, peaks 1.12–1.19 of the full run's at 1.1 kt
  and impulses 1.6–2.0 times; the blown-out share at 1.5–1.75 km is 0.88 against the run's 0.69.

**Why it read higher still, and the hold on a rising trend.** The trend is the near run's ratio to
the surrogate over 500 m to the hand-over, carried on. On the terms before, that ratio fell with
distance at every yield (slopes −0.31, −0.43 and −0.40 in the peak at 0.2, 0.5 and 1.1 kt): the old
terms read the near band at Z 5–10 low (0.85–0.91 of the run) and Z 10–14 about right. Carried on,
it pulled the far field down, which at 1.1 kt happened to cancel the surrogate's own far over-read
there (1.1–1.4 times the full run at Z 14–28, before and after the refit alike) and at 0.2 kt
pulled the share broken 0.16–0.28 too low. The refit lifted the near band to the 2 m runs' level
(0.97–1.03), so the slopes went to −0.01, −0.02 and **+0.09**. Neither the seed (×1.01–1.06) nor
the shielding (behind buildings within Z 8 only, at most ×0.92 at Warehouse 12's openness) moved it.
Carried 2.5 times out, the rising 1.1 kt slope read the far peaks 1.18–1.29 high and blew out 0.96
at 1.5–1.75 km. Since 23 October 2026 a slope that would raise the match outward is held at
nothing (`HybridFarField.fit`, emmettl/bombcad-work#56). It changes nothing at 0.2 and 0.5 kt,
whose slopes fall, nor anything fitted on the terms before. Over 1–2.5 km, the mean error in the
share of sides, against the full run (some broken / blown out):

| | 0.2 kt | 0.5 kt | 1.1 kt |
|---|---|---|---|
| The terms before, held past 1.5× (the app's) | 0.102 / 0.006 | 0.010 / 0.074 | 0.012 / 0.040 |
| Refitted, the rising slope carried | 0.026 / 0.002 | 0.036 / 0.042 | 0.014 / 0.072 |
| **Refitted, a rising slope held at nothing** | 0.026 / 0.002 | 0.036 / 0.042 | 0.014 / **0.046** |

Fitting the trend only from Z 10 (where the refit's 2 m and the near run's 4 m cells agree) or not
at all gave the same at 1.1 kt and worse impulses at 0.5 kt (up to 2.1 times). What is left at
1.1 kt is the surrogate's own far over-read, part of it the full run's far faces
([above](#against-the-full-run-by-band)). The judgements are in `$BOMBCAD_DATA/refit56/takeover`:
`judge-adopt/hybrid-*` before the hold, `hybrid-try/` with it (`base-*` carried, `held-*` as the
app holds it) and the other trend bands.

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

## Channelling down a street (20 October 2026)

Does a street lined with buildings carry the blast further than open ground, so that the far field
needs a term for it? This was [emmettl/bombcad-work#13]'s question.

**Against Beirut's full runs.** At 0.5 and 1.1 kt, over 1–1.5 and 1.5–2.5 km, a street-canyon
feature fitted to the residuals of the full 4 m runs against the surrogate took a coefficient of
only +0.01–0.02 on log peak. With the canyon and open-run features together, the peak scatter fell
from 0.217 to 0.209, and the impulse scatter did not change. The only structure in the residuals was
line of sight: a clear view −0.15, an enclosed one +0.1. That is the surrogate's own term list,
owned by emmettl/bombcad-work#4. But 4 m cells cannot resolve 10–20 m streets, so a fine test followed.

**The fine canyon** (`blastbench canyon`):

- **Charge:** 1 t of TNT on rigid ground.
- **Street:** a straight radial street 10 or 20 m wide, from 60 to 260 m out, between continuous
  walls 15 m tall and 20 m deep.
- **Gauges:** in the air cell beside the wall, 1.5 m up and at half the walls' height, and on the
  centreline. They stand at Z 8–24 (80–240 m), and each is set against a gauge at the same point
  on the same grid with the buildings taken away.
- **Domain:** a quarter of the burst. The street's centreline and the charge's other side are
  mirrors, and the open faces are 1.5 √(R W^(1/3)) from the gauges.

Each run took under a minute, so the cells went down to 0.5 m.

Wall gauge 1.5 m up, canyon over open ground, peak / positive impulse:

| Cells | Street | Z 8 | Z 10 | Z 12 | Z 14 | Z 16 | Z 20 | Z 24 |
|---|---|---|---|---|---|---|---|---|
| 4 m | 10 m (8 m as laid) | 1.38 / 1.34 | 1.39 / 1.23 | 1.31 / 1.11 | 1.18 / 0.98 | 1.05 / 0.88 | 0.83 / 0.79 | 0.69 / 0.84 |
| 1 m | 10 m | 1.27 / 1.35 | 1.39 / 1.23 | 1.41 / 1.08 | 1.37 / 0.94 | 1.29 / 0.82 | 1.09 / 0.64 | 0.90 / 0.88 |
| 0.5 m | 10 m | 1.22 / 1.35 | 1.37 / 1.22 | 1.44 / 1.03 | 1.44 / 0.93 | 1.40 / 0.83 | 1.25 / 0.65 | 1.07 / 0.85 |
| 4 m | 20 m (16 m as laid) | 1.29 / 1.30 | 1.34 / 1.26 | 1.32 / 1.18 | 1.25 / 1.10 | 1.17 / 1.01 | 1.00 / 0.87 | 0.86 / 0.79 |
| 1 m | 20 m | 1.24 / 1.29 | 1.29 / 1.24 | 1.38 / 1.18 | 1.39 / 1.08 | 1.36 / 1.01 | 1.26 / 0.88 | 1.14 / 0.81 |
| 0.5 m | 20 m | 1.27 / 1.29 | 1.27 / 1.24 | 1.37 / 1.17 | 1.44 / 1.01 | 1.42 / 0.95 | 1.36 / 0.83 | 1.25 / 0.72 |

- **It exceeds 1.2×.**
  - **Peak:** 1.2–1.45 times open ground's along most of the street on fine cells; the mean log
    ratio is +0.27 (10 m) and +0.29 (20 m) on 0.5 m cells.
  - **Impulse:** 1.2–1.35 times in the first 20–40 m of the street. It falls to 0.65–0.85 at its
    far end. There the pulse arrives early, sharp and short (5–6 ms ahead of open ground at Z 20).
    The higher pressure in the street vents over the roofs within about 40 ms, against open
    ground's 85 ms.
  - Mid-height gauges read up to 0.1 lower in peak than the 1.5 m ones. The centreline reads the
    same as the wall: across the street the pulse is plane.
- **Width over distance hardly matters.** Over w/R of 0.04–0.25, the 10 m and 20 m streets agree
  to within about 0.1. The gain is set by the distance along the street:
  - the peak's rises over the first 40–80 m and then falls;
  - the impulse's falls from the street's mouth.
- **Height matters most.** The same streets with walls 7.5 m and 30 m tall, on 0.5 m cells, peak /
  impulse:
  - **7.5 m:** 0.76–1.23 / 0.94–1.12, the mean log ratio −0.01 to +0.09. Within 1.2× throughout.
  - **30 m:** 1.22–2.04 / 1.28–1.78, the mean log ratio +0.43 to +0.48 in peak and +0.40 to
    +0.46 in impulse. It still grows at the street's far end.
- **The 4 m cells lose the gain with distance.** On 4 m cells the 10 m street is 8 m wide as laid,
  one cell either side of the centreline. Its peak ratio falls from 1.38 to 0.69 along the street,
  against 1.22–1.44 to 1.07 on 0.5 m cells. The impulse ratios stay within 0.15 of the fine
  ones. On open ground at 1 t, 4 m cells are 0.4 m/kg^(1/3) and read 0.36–0.40 of
  Kingery–Bulmash's peak; 0.5 m cells read 0.79–0.88. The impulse comes within 4–9% on every grid.

**What it means for the far field.** The air scales with the cube root of the charge, so this test
at 1 t is a 500 t burst with 80–160 m avenues between walls 120 m tall. The governing group is the
walls' height over W^(1/3), which sets them against the positive phase's length (that too scales
with W^(1/3)):

| H / W^(1/3) | Example | Peak (mean log) | Impulse (mean log) |
|---|---|---|---|
| 3 | 30 m walls, 1 t | 1.22–2.04 (+0.43 to +0.48) | 1.28–1.78 (+0.40 to +0.46) |
| 1.5 | 15 m walls, 1 t | 1.07–1.45 (+0.27 to +0.29) | 0.65–1.35 (−0.05 to +0.01) |
| 0.75 | 7.5 m walls, 1 t | 0.76–1.23 (−0.01 to +0.09) | 0.94–1.12 (−0.01 to +0.01) |
| 0.25 | 20 m walls at 500 t (Beirut) | 0.95–1.04 (−0.02) | 0.99–1.00 (0.00) |

The last row was run at 1 t scaled: walls 2.5 m tall and 5 m deep, streets 2.5 and 5 m wide. On
0.5 m cells, that is 4 m cells at 500 t in both shock and street.

The hybrid hands over at 12 m/kg^(1/3). It is used only when the whole district cannot run in an
hour: mostly for hundreds of tonnes and more, since a smaller charge's district of interest runs
whole. There, ordinary city blocks are at H/W^(1/3) of 0.2–0.4, and at 0.25 the street came within
0.95–1.04 of open ground. That agrees with Beirut's residuals. Channelling does
matter, by 1.2–2 times, for small charges in deep streets (H/W^(1/3) ≥ 1, as for 1 t between
15–30 m buildings). The near run carries those charges in the air.

**Proposed term, not built.** A canyon term for the surrogate, should a far field ever carry a charge
of a few tonnes. emmettl/bombcad-work#4 owns the surrogate's term list.

- **Feature:** for a façade whose line of sight to the charge runs down a street, the street's
  wall height h = H/W^(1/3) and the scaled distance along it, ℓ = L/W^(1/3).
- **Form:** ln(p_canyon/p_open) ≈ 0.5 [1 − exp(−(h − 0.6))] for h > 0.6, and nil below. This
  fits the mean log peaks above to within 0.08. It needs a shape in ℓ: the peak's rises over
  ℓ 2–8, and the impulse's falls from +0.3 at the mouth to −0.2 to −0.4 by ℓ 14 when h = 1.5. It also
  needs the 30 m case's growth to its far end.
- **Fit on:** this bench, for more heights, lengths and angles to the charge. A street not radial
  to the charge (the usual case) was not run.

At kiloton yields it is a correction of 0.01 or less, below the far field's scatter (σ 0.2).

**Built since, in the surrogate** (20 October 2026, emmettl/bombcad-work#4). With mouths at 20 and
120 m as well as 60 m, the gain follows the street's length against the distance to its mouth more
than the walls' height alone. In log peak it is 0.68 u e^(−ℓ/8h), u = ln(Z/Z at the mouth), which
puts 85% of the 146 wall gauges within 1.2× leaving one run out (the form above, 62%; none, 36%). Streets off the
charge were run too. See [the surrogate](surrogate-first-look.md#shielding-streets-and-the-close-in-branch-20-october-2026)
and [protective design](protective-design.md#stage-4-streets).

The results are in `$BOMBCAD_DATA/canyon/`:

- `canyon-m1000-dx4.00_2.00_1.00_0.50.csv`: 15 m walls on 4, 2, 1 and 0.5 m cells;
- `h7`, `h30` and `kt-scaled`: the other heights;
- `hist`: histories on 4 and 0.5 m cells.

[emmettl/bombcad-work#13]: https://github.com/emmettl/bombcad-work/issues/13

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
- **The far edge at the small yield.** Neither holding the trend nor fading it to the surrogate's
  own form (above) closes the 0.2 kt shortfall at 1.75–2.5 km without overshooting the larger
  yields beyond 2.5 km. A trend fitted per yield from the near run's own spread, or a refit of the
  surrogate's distance terms at low scaled distances, is the next thing to try.
- **Far buildings in the app's other views.** They are painted in the viewport and the map, but
  picking, the inspector and the damage table's per-component rows hold only the near buildings.
