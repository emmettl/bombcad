# A first look in seconds: the façade load surrogate

A district run takes tens of minutes: Beirut's 125 million cells and 738,000 envelope components
took 25–28 minutes each on the CI mini for the [Beirut page](beirut-2020.md#cost)'s runs at 0.2,
0.5 and 1.1 kt, and 27–41 minutes (1,604–2,464 s) when the same runs were timed again for the
[hybrid comparison](hybrid-far-field.md). The surrogate gives a first look at the same buildings'
damage in about half a minute, without running the air. It predicts each component's load from
where the component stands, then judges that load with the same damage model a run uses. It is
the first step of [Horizons](roadmap.md#horizons) item 2, "Answers in seconds", and it is an
estimate, never a run: it is fitted to BombCAD's own runs and inherits their limits as well as its
own.

## What holds and what does not

Judged against Beirut's full 4 m runs at 0.2, 0.5 and 1.1 kt, which it was not fitted to:

- **Holds: the glass across the district.** Each building side's glass state (none broken, some,
  blown out, as GEER classed façades) agrees with the run's for 75–84% of the 28,991 sides, and is
  never two states apart. By distance band, the share of sides with some glass broken and the
  share blown out come within about 0.1 of the run's to 2 km (and up to 0.16 for 0.5 kt's blown
  out at 1.25–1.5 km).
- **Holds: the speed.** The whole first look over Beirut's 724,512 components takes 22–28 s on
  the Studio while other jobs share it: 7–10 s for the loads, 14–22 s for the damage, against
25–41 minutes for a full run on the CI mini. On a
  made-up district of 7,235 buildings it takes 2–3 s against the run's 69–105 s on the same Mac.
- **Does not: walls and roofs.** Against Beirut's near boxes rerun with uncapped loads, of the
  components either the run or the surrogate calls damaged, 28–49% of the concrete, 36–45% of the
  stone and, on the roofs' own terms, 29–64% of the roofs take the run's level ([below](#walls-and-roofs-20-october-2026)).
  The few damaged components lie close in, where one wrong factor of 1.3 moves a wall across a
  level. Run the scene for the structure.
- **Does not: the far edge.** Beyond Z = 20 m/kg^(1/3) (1.6 km at 0.5 kt), over Beirut's hills
  and toward its run's open faces, the surrogate's loads are 1.1–1.6 times the run's on the
  median, and at 2.5–3 km it breaks glass on 0.48 of sides where the run broke 0.18.

## How it predicts a load

For each envelope component with a face on the air (`FacadeLoadSurrogate`):

1. **Its features.** From the middle of its outer face: its distance from the charge; how
   squarely it faces it (the cosine of the angle between its outward normal and the direction to
   the charge); and, along a line from the charge to it that keeps an even height above the
   ground (a surface burst's wave follows the ground), the other buildings it passes through, how
   far inside them, and how far the ground between rises above the straight line from ground to
   ground (a hill in the way). Also its height above its own ground and the ground's rise from the
   charge's. The buildings sit on a plan grid of the run's cells, so a district's lines take a few
   seconds on the CPU.
2. **Its base.** Kingery–Bulmash for a hemispherical surface burst (Swisdak's fits, as
   `KingeryBulmash`): the incident peak and impulse, raised toward the reflected ones by the square
   of its facing, at its scaled distance Z = R / W^(1/3).
3. **The fitted terms.** The logarithm of its peak (and of its impulse) over the base is a sum
   of eleven terms: a constant, facing, facing away, log(1 + buildings crossed), log Z and its
   square, the length inside them, height, ridge and ground rise (each over W^(1/3)), and the
   logarithm of the cell's size over W^(1/3) (`FacadeLoadSurrogate.terms`). A run's loads depend
   on its cells (a shock spans several of them), so the surrogate gives the loads of a run on the project's cells, not converged ones.
   Two more terms carry a street the line runs down, measured on fine runs rather than fitted to the
   districts ([below](#shielding-streets-and-the-close-in-branch-20-october-2026)).
4. **Close in**, below Z = 4.6 m/kg^(1/3), a branch takes over from the fitted terms: the base
   times the ratio fine runs give an open façade, carried to the project's cells by the fitted
   cell term, and blended into the fitted terms between Z 4.6 and 8.
5. **Its pulse.** A triangle of that peak and impulse, lasting twice the impulse over the peak,
   rising to its peak over a fitted share of that time (0.2–0.35 on 4 m cells: behind buildings
   the load builds up over tens of milliseconds as the streets fill). On its own training district
   a pulse that rose at once blew out 8,188 of the 11,805 sides the run left partly glazed, and
   53% of sides agreed; with the rise, 85% agree.
6. **Its damage.** The pulses go into `EnvelopeDamageAssessment` as a run's histories do: the same
   panels, panes, glazing mixes and levels. Peaks and impulses are rounded to 3% so that a
   district's components share pulses, and the SDOF responses are remembered by system and load
   (`SDOFResponseMemo`): over Beirut 4.0 million responses are asked for and 115,000 integrated.

## How it was fitted

To two made-up districts on 4 m cells, the recommended air and saturated ground, each run with
`scenebench district-compare --save-loads` (which now saves each strip's box) and extracted with
`scenebench surrogate-extract`:

- **Dense** (`make_dense.py`, kept with the runs): 7,235 buildings on a 2.4 km square, perimeter
  blocks of terraces with courtyards, towers in plazas, parks, a 40 m avenue, a quarter turned
  30°, a 70 m hill and a 30 m ridge; charges of 20, 100 and 500 t at its middle. Cells over W^(1/3)
  run 0.15 to 0.05, Beirut's 0.07 to 0.04.
- **Sparse**: the New District test fixture (Fixtures/SyntheticDistrict), 49 buildings 100 m
  apart, at 20 t.

`Scripts/fit-surrogate.py` fits the terms by least squares, each run weighted alike, leaving out
strips near a run's open faces (beyond 0.85 of its half-side), beyond the curves, or under 100 Pa.
About the fit the peaks scatter by a factor of 1.27 (the standard deviation of the logarithm
0.24) and the impulses 1.18 (0.17).

Beirut was held out of the fit. Its residuals did shape the model's form, though: the line over
the ground and the ridge and ground-rise terms were added after its loads on the hills south of
the port were seen to fall below the straight-line model's. With them, a fit to Beirut itself
scatters by 1.22–1.28; the made-up districts' fit, applied to Beirut, does as well within Z = 20.

## Judged against Beirut

`scenebench surrogate-judge` takes the run's saved façade strips (`beirut/mix/loads-*`, from the
Beirut page's runs) and judges each strip twice through the same SDOF: once on its recorded
history, once on the surrogate's pulse. Concrete is the default 0.2 m wall and stone 0.5 m
unreinforced masonry; glass is each building's mix, summed over its side. The saved strips carry no
positions, so the scene is laid out again and 465,671 of the 694,611 strips are matched to theirs
(buildings whose strips cannot be matched one for one are left out); 315,637 lie within 0.85 of
the run's half-side.

The loads, the surrogate's over the run's (median, and the standard deviation of the
logarithm), at 0.5 kt:

| Z, m/kg^(1/3) | Strips | Peak | Impulse |
|---|---|---|---|
| 0–3 | 287 | 8.28 (0.79) | 4.10 (0.67) |
| 3–5 | 209 | 0.68 (0.27) | 0.81 (0.13) |
| 5–7 | 1,492 | 0.77 (0.29) | 0.78 (0.14) |
| 7–10 | 9,008 | 0.85 (0.26) | 0.81 (0.15) |
| 10–14 | 27,155 | 0.96 (0.23) | 0.89 (0.14) |
| 14–20 | 62,928 | 1.00 (0.23) | 1.01 (0.16) |
| 20–28 | 124,465 | 1.09 (0.38) | 1.28 (0.28) |
| 28–40 | 90,093 | 1.36 (0.60) | 1.63 (0.79) |

Within Z = 3 (238 m; 287 strips, all outside the fitted range and marked so) the surrogate gives
eight times the run's peak, but that comparison does not stand: the saved loads it reads were
stored as 16-bit floats, which clipped every peak at 65.5 kPa (fixed in 983409a8, after these
runs), and every strip there is at that cap. The cap reaches 540 m at 0.5 kt (Z ≈ 7) and 670 m
at 1.1 kt; in the made-up districts it held the fit's targets down within 555 m at 500 t (2% of
its strips). On the near boxes' uncapped loads (the table is the full runs', capped), the fitted
terms held close in gave 0.66 of the run's peak at Z 3–5 and 0.78 at Z 5–7; with the close-in
branch of 20 October those are 1.11 and 0.88
([below](#shielding-streets-and-the-close-in-branch-20-october-2026)).

Glass by building side, against the run's and GEER's shares (as the
[Beirut page](beirut-2020.md#glass-as-a-mix-of-panes) compares them), at 0.5 kt:

| Distance | Some broken: run / surrogate | GEER W1+ | Blown out: run / surrogate | GEER W3 |
|---|---|---|---|---|
| 0.5–0.75 km | 1.00 / 1.00 | 0.84 | 1.00 / 1.00 | 0.77 |
| 0.75–1 km | 1.00 / 1.00 | 0.62 | 1.00 / 1.00 | 0.28 |
| 1–1.25 km | 1.00 / 1.00 | 0.39 | 0.96 / 0.93 | 0.17 |
| 1.25–1.5 km | 1.00 / 1.00 | 0.35 | 0.59 / 0.43 | 0.18 |
| 1.5–1.75 km | 0.99 / 1.00 | 0.38 | 0.07 / 0.17 | 0.09 |
| 1.75–2 km | 0.91 / 0.98 | 0.28 | 0.01 / 0.01 | 0.02 |
| 2–2.5 km | 0.66 / 0.77 | 0.26 | 0.00 / 0.00 | 0.15 |
| 2.5–3 km | 0.18 / 0.48 | 0.11 | 0.00 / 0.00 | 0.04 |

At 0.2 kt the shares with some broken come within 0.1 everywhere (0.84 / 0.82 at 1.5–1.75 km,
0.62 / 0.53 at 1.75–2 km); at 1.1 kt they match to 2 km and run high beyond (0.65 / 0.97 at
2.5–3 km). Against GEER the surrogate inherits the run's verdict: too much glass broken close in,
the far edge about right.

Each strip or side's state, rows the run and columns the surrogate, at 0.5 kt:

| Glass (sides) | W0 | W1–2 | W3 |
|---|---|---|---|
| W0 | 3,411 | 4,322 | 0 |
| W1–2 | 1,067 | 12,797 | 785 |
| W3 | 0 | 993 | 5,616 |

| Concrete (strips) | None | Moderate | Heavy | Hazardous | Failed |
|---|---|---|---|---|---|
| None | 315,115 | 0 | 0 | 0 | 1 |
| Moderate | 199 | 3 | 0 | 0 | 126 |
| Heavy | 15 | 18 | 0 | 0 | 99 |
| Hazardous | 0 | 0 | 0 | 0 | 59 |
| Failed | 0 | 0 | 0 | 0 | 2 |

Glass's misses are mostly one way at each end: sides the run left whole that the surrogate breaks
far out (4,322), and sides the run blew out that it leaves with some panes whole close in. In
sight of the charge and behind one to three buildings, 89–97% of sides agree; deep in the
district, 75–84%.

### Walls and roofs (20 October 2026)

The first judgement of walls was against Beirut's full runs, whose saved loads were capped at
65.5 kPa (16-bit floats) inside about Z = 7, where walls are damaged: it put the concrete at
0–10%. Beirut's near boxes (to 1,320 m, 4 m cells, 3 s) were run again with every load uncapped,
the walls and roofs saved beside the façades (`district-compare --save-loads` writes them to
components.json since 20 October). `surrogate-judge` then sets each component judged on the run's
history against the surrogate's pulse, and against an oracle: a triangle with the run's own peak,
first impulse and rise. The oracle shows what the pulse's shape alone loses. Of the components
either side calls damaged, the share at the run's level, and within one:

| | 0.2 kt | 0.5 kt | 1.1 kt |
|---|---|---|---|
| Concrete walls, oracle | 0.86, 1.00 | 0.76, 1.00 | 0.66, 1.00 |
| Concrete walls, surrogate | 0.47, 0.60 | 0.35, 0.78 | 0.15, 0.74 |
| Stone walls, oracle / surrogate | 0.92 / 0.41 | 0.90 / 0.33 | 0.92 / 0.38 |
| Concrete walls, with the close-in branch (20 October) | 0.49, 0.58 | 0.44, 0.81 | 0.28, 0.83 |
| Stone walls, with the close-in branch | 0.42 | 0.36 | 0.45 |
| Roofs, oracle | 0.81, 1.00 | 0.70, 1.00 | 0.55, 1.00 |
| Roofs, on the façades' terms | 0.42, 1.00 | 0.06, 0.98 | 0.11, 0.91 |
| Roofs, on their own terms | 0.64, 1.00 | 0.29, 1.00 | 0.37, 0.99 |

- **Three numbers carry the load.** The oracle takes most levels and is never two apart, so a
  triangular pulse is not what loses walls; the predicted peak and impulse are. The cap explained
  most of the first judgement's misses: the 126 concrete strips the run left moderate and the
  surrogate failed are 46 on the uncapped loads.
- **Roofs on their own terms.** Fitted to the roofs of the dense made-up district at 20, 100 and
  500 t, rerun uncapped (`fit-surrogate.py --drop facing`: a roof faces a charge on the ground only
  by a sliver of a cosine, and fitting that term runs away), with Beirut and the sparse fixture
  held out. Their peaks were already near the run's (×1.03–1.11 on the façades' terms, ×0.96–0.99
  on their own), but the façades' terms left them a level light.
- **What is left is the tail.** The components a run damages are its loads' upper tail; a single
  estimate, scattered by about ×1.3 either way, puts fewer of them over a level than the run does.
  Counts by band need the scatter drawn, as the glass's chances draw it (Horizons 4).

**Counts by band, drawn** (the band test, after the close-in branch;
`scenebench wall-calibrate --bands`). Each building's chances at the run's own yield, as the quick
estimate gives them ([walls and roofs](glass-probability.md#walls-and-roofs)), summed by distance
band, against the run's count of buildings it damages moderately or worse:

| Whole box (to 1,320 m) | 0.2 kt | 0.5 kt | 1.1 kt |
|---|---|---|---|
| Concrete walls: run / chances' sum | 3 / 2.3 | 24 / 11.5 | 114 / 107.9 |
| Stone walls (each as 0.5 m stone) | 79 / 47.7 | 449 / 509.1 | 1,125 / 1,273.3 |
| Roofs | 10 / 11.2 | 123 / 110.3 | 470 / 412.3 |

- **Where damage is well established, the counts come within about 20%.** Stone comes within 0–7%
  once most of a band is damaged, and roofs within 20% in most bands with 50 or more damaged. At
  0.5 kt the point estimates had 287 concrete wall components where the run had 511, and 83 roofs
  where it had 236.
- **At the edge of the damage they miss both ways.** The chances spread that edge over more
  distance than the runs, which switch on sharply.
  - Just inside the edge they are low: concrete at 400–700 m reads 0.33–0.65 of the run at
    0.5–0.85 kt, and stone 0.36–0.57 at 0.15–0.2 kt.
  - Just outside they are high: stone at 1,000–1,320 m reads 1.8–2.9 times the run at 0.85–1.1 kt,
    and concrete at 700–1,000 m 1.7–2.5 times at 1.1–1.5 kt.
  - The test's allowance is the larger of 20% and the difference between 4 m and 3 m cells
    ([Beirut](beirut-2020.md), up to +45% for concrete), so the edge bands fail it.
- **So the walls' chances suit a building's chance and a district's total, not a count by
  distance near the edge of the damage.** Wall and roof damage keep their "not to be relied on"
  standing for a building's level.

### The rise share's fit (20 October 2026)

The fit read the ground rise where it meant the rise time. `surrogate-extract` wrote both as
`rise`, and `fit-surrogate.py` found each column by its first match. The peak's and impulse's
terms were fitted as meant: replaying the mistake reproduces them, and fitting the rise time
leaves them bit for bit. The rise share's terms were fitted to the ground rise over the pulse's
length, clipped to 0–1. The extract now names the column `risetime`, and the fit refuses a file
that names a column twice.

Refitted to the same four made-up runs on the rise time, the rise share follows Beirut's runs,
which none of its fits saw:

| Beirut, uncapped near boxes | 0.2 kt | 0.5 kt | 1.1 kt |
|---|---|---|---|
| The runs' rise share, mean | 0.37 | 0.35 | 0.33 |
| As fitted (by the ground rise), mean / rms error | 0.91 / 0.57 | 0.91 / 0.59 | 0.91 / 0.60 |
| Refitted on the rise time | 0.31 / 0.18 | 0.29 / 0.19 | 0.27 / 0.18 |

But the slow rise the mistake gave every pulse had been offsetting loads the surrogate
overpredicts deep in the district, where its impulses run 1.26–1.50 times the full runs'. With
the refitted rise, more glass breaks. The glass chances against the runs fall from a Brier
score of 0.020 to 0.024 (skill 0.81 to 0.78) for blown out, and from 0.72 to 0.68 skill for glass
thrown past 3b. Both then fail the report's test, each tenth of chance within 0.1. Sides agreeing
deep in the district go from 75–84% to 74–83%. Concrete walls take the run's level a little more
often (17–46% against 15–47%).

So the coefficients the app uses keep the fitted rise share for now, its standing as judged. The
refitted rise terms go in with the next refit of the load terms (the shielding and near-field
refit), which must bring the far impulses down with them; judged against the glass chances'
test before they are taken. The refitted terms, the judgements and the calibration are in
`$BOMBCAD_DATA/rise-fix`.

### Shielding, streets and the close-in branch (20 October 2026)

Fitted and judged on fine runs at 1 t (emmettl/bombcad-work#4; the numbers in
[protective design](protective-design.md#shielding-barriers-streets-and-close-in-loads-on-fine-cells-20-october-2026)):

- **The features.** `Raster.sight` now also gives the knife edge in the way (the highest top over
  the line for its distances), its distances, how far it reaches to the side, and the last
  building's top; `Raster.canyon` walks a street back from the façade while walls stand on both
  sides within 25 m. `surrogate-extract` writes them (columns `edge` to `edgeside`).
- **Streets the line runs down** (two terms, held at the fine canyon runs' values): log peak gains
  0.68 u e^(−ℓ/8h) and log impulse 1.33 u e^(−ℓ/3h) (1 − e^(−(h − 0.6))), u the log of Z over the
  mouth's, ℓ and h the street's length and walls' height over W^(1/3). Leaving one run out, 85%
  of the canyon gauges' peaks come within 1.2× (36% without), 75% of the impulses (49%). At Beirut's
  yields the terms are a few per cent at most.
- **The close-in branch**, Z 1.5–4.6, blended into the fitted terms by Z 8: Kingery–Bulmash's
  base times the open façades' ratio on 0.5 m cells, a quadratic in log Z. Leaving one layout out,
  peaks scatter by 0.11 about it; on 1 m cells through the cell term the median is +0.01.
- **Shielding: measured, not adopted.** A knife-edge factor passes on the fine layouts pooled
  (log-SD 0.232 leaving one layout out), but over-credits barrier walls by 20% and is absent from
  the district runs (a multiplier of +0.05 when fitted with their terms).
- **The district terms are unchanged.** A refit of them on the made-up runs with their clipped
  strips mended moved Beirut's glass by −0.02 and was not kept. Beirut's glass, side by side
  and by band, is as it was (0.841, 0.754 and 0.813 of sides; every band within 0.005).
- **The next refit's starting point: the rise share fitted with the load terms.** Fitted on the
  same four made-up runs, f3065fca's corrected rise share goes in together with the load terms and
  a bounded (log(1 + crossed))² term (impulse −0.040; the districts' impulse scatter 0.168 → 0.163).
  - It brings Beirut's far impulses down: at 0.5 kt, Z 28–40, from 1.63 to 1.41 times the run's;
    at 1.1 kt, Z 20–28, from 1.86 to 1.60.
  - It takes the glass chances back through their test with the load scatter: blown out Brier
    0.021, skill 0.80; thrown past 3b, skill 0.71. As landed they are 0.020, 0.81 and 0.72; with
    the rise alone 0.024, 0.78 and 0.68, failing.
  - It costs 0.005–0.008 in side agreement at 0.2 and 1.1 kt (0.833 and 0.809, against 0.841 and
    0.814). The faster rise blows out too many sides at 1–1.25 km at 0.2 kt and at 1.5–1.75 km at
    1.1 kt.

  So it is held, not landed. Its coefficients are in
  `$BOMBCAD_DATA/protective/refit/fit-sq.json` (`gate/` holds its judgements) and
  its term in `terms` at nothing
  ([protective design](protective-design.md#stage-5-the-refit-and-what-it-changes-for-a-plan)).
- **Two limitations found.**
  - Behind a row, the lee walls of a street that does not point at the charge are read up to ×1.6
    low in peak (×1.7 in impulse).
  - The close-in branch's impulse moves 17% between 1 m and 0.5 m cells: not converged.

### Close in among buildings (21 October 2026)

The field-model judge (emmettl/bombcad-work#33) found the surrogate 1.3–2.1 times high within
350 m of charges among Beirut's buildings, and no better there than Kingery–Bulmash's incident
values (emmettl/bombcad-work#56). Its runs are on the mapped start, the recommended one since 18
October; the terms were fitted on the balloon start. Three causes were traced with
`surrogate-judge --strips-out`, which writes each strip's run and surrogate loads. The runs:
- Beirut's near box at Warehouse 12 (0.5 kt);
- four of the judge's held-out runs with the recorder's strips saved: two charges in Beirut's
  streets (115 and 355 t) and two made-up districts.

- **Not the start.** Beirut's near box run on both starts gives the same strips: the line's
  gauges agree to 0.1 kPa, and the surrogate's ratio to the run is the same to two places in every
  band of scaled distance.
- **Not the comparison.** The judge took ground-floor strips only. Upper storeys read higher still
  (1.38 against 1.20 at Z 3–5 for the 355 t charge).
- **The close-in branch on shielded façades.** The branch (emmettl/bombcad-work#4, Z 1.5–4.6) puts Kingery–Bulmash
  times the open façades' ratio in place of every fitted term but the street's. That drops the
  shielding, and a street raises it further. Peak, the surrogate's over the run's, at Z under 5:

| Strips at Z < 5 | Beirut's two street charges | Made-up districts | Warehouse 12 |
|---|---|---|---|
| In sight of the charge | 1.13 (log-SD 0.66) | 1.18 (0.55) | 1.31 (0.79) |
| Behind buildings, with the branch | 1.72 (0.54) | 1.41 (0.43) | 0.98 (0.30) |
| Behind buildings, without it | 1.10 (0.59) | 0.88 (0.50) | 0.61 (0.25) |
| Down a street, with the branch | 1.73 (0.52) | 1.34 (0.42) | – |

  - Behind buildings close in, the branch reads 1.4–1.7 times the runs' among buildings.
  - At Warehouse 12 the façades behind buildings close in are 83 strips, nearly all in the lee of
    the grain silos, a tall narrow obstacle round which the blast wraps. There the branch is right.
  - No feature the surrogate has tells the silos from a city block: the knife edge's height and
    its reach to the side are alike for both.
- **Keeping the shielding terms in the branch does little** (1.72 → 1.65 behind buildings in
  Beirut's streets). The fitted terms take only a few per cent off for shielding.
- **emmettl/bombcad-work#4's held refit (option B, fit-sq.json) is no different here**: 1.62 against 1.63 at Z 3–5
  in Beirut's streets.

**A candidate, not proposed for adoption: the branch for components in sight of the charge only**
(`CloseIn.inSightOnly`, built and off; `surrogate-coefficients --in-sight-close-in` writes it):

| | Fitted (as landed) | Branch in sight only |
|---|---|---|
| Beirut's streets, peak at Z < 7 | 1.38 (log-SD 0.53) | 1.02 (0.51) |
| Beirut's streets, impulse at Z < 7 | 1.10 (0.37) | 0.93 (0.29) |
| Beirut's streets, every strip: peak / impulse | 1.07 (0.34) / 0.91 (0.24) | 1.03 (0.32) / 0.89 (0.19) |
| Made-up districts, peak at Z < 7 | 1.16 (0.42) | 0.86 (0.41) |
| Made-up districts, every strip: peak / impulse | 0.98 (0.35) / 1.00 (0.21) | 0.89 (0.32) / 0.98 (0.17) |
| Warehouse 12's near box, peak at Z < 7 | 0.92 (0.46) | 0.86 (0.47) |
| Beirut's glass sides, full runs 0.2 / 0.5 / 1.1 kt | 0.84 / 0.75 / 0.81 | the same |
| Near boxes' concrete walls at the run's level, 0.2 / 0.5 / 1.1 kt | 0.49 / 0.43 / 0.28 | 0.49 / 0.40 / 0.22 |
| Near boxes' stone walls at the run's level | 0.43 / 0.36 / 0.45 | 0.41 / 0.34 / 0.41 |
| Walls' chances, concrete moderate or worse (each yield held out) | skill 0.56, tenths pass, load ×1.0 in 9 folds | skill 0.55, tenths fail (0.60–0.70 seen at 0.78), load ×1.15–1.30 |
| Walls' chances, stone heavy or worse / roofs moderate or worse | skill 0.71 / 0.75 | 0.71 / 0.75 |

- **For:** Beirut's streets and the made-up districts close in. Over every strip, the peak's
  scatter falls below Kingery–Bulmash's incident values' on these runs (0.37–0.38), and the
  impulse's to theirs (0.17–0.18).
- **Against:** Warehouse 12, where Beirut's standing and the walls' chances were measured. The
  façades behind the silos read 0.6, the near boxes' walls lose 0.02–0.06 at the run's level, and
  the concrete walls' chances fail their test. On the made-up districts, shielded façades at Z 3–7
  read 0.84, the unsafe side. The glass, judged far out, is unchanged.
- **So nothing is changed.** The terms stay as landed, and the standing now says the surrogate
  reads high close in behind buildings. A fix needs a feature that tells a narrow obstacle from a
  wide one (the obstacle's width across the line), or a refit on charges among buildings. On 23
  October the width proved not to tell them apart, and how open the charge's surroundings are did
  ([below](#the-refit-on-post-fix-and-2-m-runs-and-shielding-by-the-charges-surroundings-23-october-2026)).
- **Caveats.** The strength draws were keyed by envelope ids that are new each time a scene is
  laid out (fixed since), so the before and after differ by sampling as well. That is in the third
  decimal, far less than the concrete chances' failure. The data, scripts and judgements are in
  `$BOMBCAD_DATA/start-bias`.

### Dragging the charge (20 October 2026)

With a quick estimate on screen and Place Charge on, the charge can be dragged across the ground
and the estimate follows it (emmettl/bombcad-work#34). The goal was a frame within about a second
on Beirut's district, with its standing still shown.

**What a frame does.**
- **Laid out once.** `FacadeLoadSurrogate.Prepared` builds the raster and every building's
  components on the air once. On Beirut that is 724,512 components in 0.2 s. For any place of the
  charge, `Prepared.estimate` then gives what `estimate(scene:)` and `glassSides(scene:)` give, to
  the bit (`scenebench drag-time --check`). The quick estimate itself now runs this way, which
  also stops it working out the glass's sight lines twice.
- **A preview while dragging.** Of each building's components of one kind on one side, only the
  one nearest the charge is judged; a glazed side's nearest strip stands for the side's whole
  area. On Beirut that is 67,699 components, 9% of them. Only the colouring shown is worked out:
  - the damage;
  - the glass's chances, on 10 draws;
  - the walls' and roofs' chances, on 20 draws.

  The yields are spread evenly over their distribution, and each building's strength and each
  side's scatter over theirs in an order of their own (a Latin hypercube). Drawn at random, a few
  yields shared one error across the whole district: at 10 draws the glass's chances read 0.075
  low on average.
- **Kept between frames.** The SDOF and pane responses a preview meets are kept for the next
  frame; both are exact. The memo now hashes every sixteenth bin of a pulse, not all of them. A
  full estimate keeps its own only while it runs, since on Beirut they would hold several GB.
- **When you let go,** the scene is loaded again (once, as one edit) and the full estimate is made
  where the charge stopped.

**Against the full estimate** (Beirut's 4 m layout, 0.5 kt, yield within ×1.5, 100 draws; the
charge where it was and 60 m east):
- The glass's chances came within 0.1 of the full estimate's on 88–93% of sides: blown out 88%,
  some broken 93%, with a mean difference of 0.04 and a bias of +0.02. The openings' came within
  0.1 on all of them.
- The walls' and roofs' chances came within 0.1 on 98.9–100% of buildings.
- The damage's colour was the same for 99.7% of buildings, and never more than one colour apart.

**Time a frame**, on the Studio while other sessions loaded it (load average 18–34 on 14 cores):

| Colouring | First frame | Later frames | Full estimate, once let go |
|---|---|---|---|
| Damage | 3.2 s | 1.5–1.7 s (0.9 s at load 5–18) | 97–104 s |
| Glass's chances | 8.8 s | 1.2–1.7 s | |
| Walls' and roofs' chances | 1.8 s | 0.8–1.4 s | |

- The first frame fills the response tables.
- The sight lines are 0.4–0.7 s of every frame, and the rest grows with the load on the machine.
- So **the second's bar is met only on a lightly loaded Studio**, for the damage and the walls.
  The glass's chances need about 1.2 s even then. Fewer components would not help them much: each
  side is already one strip.
- What would: a pane table interpolated rather than looked up per rounded pulse (as the charge
  inference's `BreakTable` is), or the draws on the GPU.

**Faster frames (21 October 2026).** A profile of a glass drag on Beirut found where a later frame
went:
- **About two-fifths in SDOF integrations.** As the charge moves, most strips' rounded pulses
  change, so their pane responses are missing from the table frame after frame. The thrown panes'
  conditions miss most, keyed as they are by the strength each draw cracks at.
- **A fifth in one conversion.** `SIMD2<Int>` of a float vector takes Swift's generic, slow path,
  in the raster's cell index and the terrain's height: most of the sight lines' time.
- **A sixth in waiting on the table's locks,** much of the rest in hashing.

Two changes, chosen by those numbers (neither the GPU nor a new interpolated table was needed):
- **The conversion lane by lane** (`Raster.cellIndex`, `Terrain.height(at:)`): the same integers,
  the sight lines 0.38–0.40 s to 0.16–0.24 s a frame.
- **A coarser pane table for previews** (`Prepared.previewQuantum`, `previewStrengthSteps`):
  - pulses rounded to 10% of their peak and impulse, against a full estimate's 3%;
  - a cracked pane's strength rounded to a fifth of a unit of its log, against a twentieth.

  Both are far finer than the surrogate's scatter (0.2–0.3 in the log) and the strength's (0.25).
  A charge moved a few metres then finds most of its panes' responses already worked out. A full
  estimate keeps its own, finer table.

**Still as right.** Against the full estimate, as above (0.5 kt, 10 preview draws, 100 full ones,
the charge where it was and 60 m east):

| Pane table | Some broken within 0.1 | Blown out within 0.1 | Blown out bias | Damage colour the same |
|---|---|---|---|---|
| A full estimate's (3%, a twentieth) | 0.929 | 0.881 | +0.009 | 0.997 |
| 6%, a tenth | 0.928 | 0.881–0.882 | +0.009 | 0.997 |
| **The preview's (10%, a fifth)** | **0.928** | **0.880–0.882** | **+0.006** | **0.997** |

Two runs of the same build differed in the third decimal. Each building's strength draws were
keyed by its place among the scene's objects sorted by their identifiers, which are new each time
a scene is built, so these figures agree within their own noise. Since 21 October the draws are
keyed by each building's geometry (`SceneObject.drawKey`), and the same scene gives the same
chances to the bit (`EstimateReproducibilityTests`).

**Faster** (Beirut, 21 frames 5 m apart; the Studio shared, load 2–14):

| Colouring | First frame | Later frames, median (range) | Before (load 18–34) |
|---|---|---|---|
| Glass's chances (10 draws) | 1.8 s | **0.43 s** (0.43–0.48) | 1.2–1.7 s |
| Damage | 1.5 s | **0.69 s** (0.62–0.76) | 1.5–1.7 s (0.9 at load 5–18) |
| Walls' and roofs' chances (20 draws) | 0.7 s | **0.53 s** (0.51–0.57) | 0.8–1.4 s |

At a load of 112 the glass's later frames took 0.31–0.44 s and the whole frame at most 0.70 s. So
every colouring now meets the second's bar, loaded or not.

### Close calls refined by the solver (21 October 2026)

Once the full estimate is in, after a drag is let go or Quick Estimate is pressed, the app can run
the air on the buildings where the estimate is least sure (emmettl/bombcad-work#34). Their run
results then replace the estimate's, outlined in green in the view and marked *refined* in the
sidebar's list. It hooks in after the estimate and changes nothing in how the estimate is made.

**What it runs** (`ThresholdRefinement`, `ThresholdRefinementRun`):
- **The close calls.** These are the buildings with a chance between 0.2 and 0.8, where a threshold
  falls within what the estimate does not know: the yield, the surrogate's scatter and the
  strengths. The chance judged is the one the view is coloured by. Under the damage colouring it
  is the walls' (moderate, heavy), the roof's and the windows blown out; glass merely broken is
  left out, since nearly every building has some side near even on it. The nearest eight are taken.
- **A scene cut round them.** This is a square about the charge, out to the farthest of them and
  4 m/kg^(1/3) beyond, as the hybrid near run takes its clearance
  ([hybrid far field](hybrid-far-field.md)). It is on the scene's own cells, so every building
  voxelises as it does in the whole scene. Buildings wholly inside are kept, blocks are clipped,
  and the terrain is cut with them. Scenes with structures, gas clouds, vents, free objects or more
  than one charge are not offered it.
- **Finer air along the way to each.** The air is refined to half the cells in corridors from the
  charge to each building ([refine toward buildings](refinement-steering.md)), with the scene's air
  settings and the mapped start.
- **Each building judged as the blast passes it.** A building is ready at Kingery–Bulmash's arrival
  at its far corner, a tenth later for the streets, plus a hold of 6 ms/kg^(1/3) (at least 30 ms).
  Its recorded loads are judged on a queue of their own while the air steps on:
  - its damage, as a run judges it;
  - its sides' glass chances and its walls' and roof's, drawn as the estimate draws them over each
    building's strength, on the same draws (`SceneObject.drawKey`).

  These are at the scene's charge, so neither the yield's spread nor the surrogate's scatter is
  drawn.
- **Within a budget.** The budget is 30 s to 10 min of wall-clock time, 2 min by default, shown with
  a progress bar and a Cancel button. A building passed by then keeps its run result; the rest keep
  the estimate's. A new drag, an edit or a run stops it.

**Beirut, 0.5 kt** (the 4 m layout within 1 km, 1,554 buildings, yield within ×1.5; `scenebench
threshold-refine`; the Studio shared):

| Run | Near scene | Close calls refined | First answer | All answers | Settled (no chance left at 0.2–0.8) |
|---|---|---|---|---|---|
| 8 nearest, refined corridors | 1,512 m square, 11.4 M cells, 607 buildings, to 1.74 s | 8 of 1,051 | 12.5 s | **22 s** | 5 of 8 |
| 16 nearest, refined corridors | 1,632 m, 13.3 M cells, 834 buildings, to 1.90 s | 16 | 15 s | **43 s** | 8 of 16 |
| 8 nearest, 4 m air only | as the first | 8 | 4 s | 14 s | 2 of 8 |

- **Judging away from the stepping** took the eight from 91 s to 22 s. Judged in line, the glass's
  draws on every strip held the GPU idle for several seconds a building.
- **The refined corridors matter.** At 4 m alone, five of the eight walls' chances stayed between
  0.43 and 0.87. With the corridors at 2 m, seven were 0.98–1.00. That matches what refining toward
  buildings found: the coarse air got two of three buildings wrong.
- **The estimate's walls read low against the refined runs at 400–600 m.** It gave 0.21–0.52
  where the refined runs gave 0.98–1.00, on 9 of the 16. The walls' chances were calibrated
  against Beirut's runs on 4 m air ("Walls and roofs" above); against air twice as fine they would
  need a larger load factor. This is recorded here, and nothing has been refitted.
- **The glass is not where the doubt lies** within 600 m of 0.5 kt: every side's glass was 1.00
  either way. For a car bomb, or under a glass colouring, it is.


### Walls at 400–600 m against finer air (21 October 2026)

The close calls' refined runs called walls damaged at 400–600 m of 0.5 kt, on 9 of 16 buildings,
where the estimate gave 0.21–0.52. At the scene's exact yield the estimate still gives 0.03–0.48,
so the yield's spread is not the cause. The question was whether the refined runs are right, or
whether they overshoot (`scenebench wall-convergence`, emmettl/bombcad-work#19 and emmettl/bombcad-work#34).

**Five of those buildings, 494–603 m** (Beirut's 4 m layout, the threshold refinement's cut scene).
Each front wall's median peak, positive-phase impulse (the most its running integral reaches) and
SDOF support rotation:

| Air | Peak, × 4 m | Impulse, × 4 m | Front walls' median rotation | Worst wall's rotation |
|---|---|---|---|---|
| 4 m | 32–47 kPa | 4.2–4.5 kPa s | 0.11–0.19° | 0.17–0.78° |
| 2 m corridors | ×1.07–1.19 | ×0.89–0.96 | 0.16–0.62° | 0.33–2.02° |
| 1 m corridors | ×1.00–1.19 | ×0.79–0.85 | 0.18–0.63° | 0.33–1.75° |
| 2 m corridors, whole scene (no cut) | as the cut, to 0.3% | as the cut | as the cut | as the cut |

**One block in the open, its front 500 m from 0.5 kt** (a quarter model: the charge in a corner on
two mirror planes, 320 m up, the open faces 4 m/kg^(1/3) beyond):

| Air | Incident at 500 m, no block | Front wall's peak | Front walls' median rotation |
|---|---|---|---|
| 4 m | 26.0 kPa, 4.18 kPa s | 50.0 kPa | 0.19° |
| 2 m | 28.1 kPa, 4.00 kPa s | 58.5 kPa | 0.49° |
| 4 m, 2 m and 1 m corridors | | 65.0 kPa | 1.91° |
| 2 m, 1 m and 0.5 m corridors | 30.8 kPa, 4.06 kPa s | 68.2 kPa | 1.16° |
| Kingery–Bulmash | 29.4 kPa, 3.81 kPa s | 65.4 kPa reflected | |

- **The finer runs do not overshoot.** On 0.5 m the incident peak is within 5% of
  Kingery–Bulmash. The reflected peak is 2% under the Rankine–Hugoniot reflection of that
  incident (69.3 kPa) and 4% over Kingery–Bulmash's reflected value.
- **4 m reads the reflected peak low.** It is 27% low for the block in the open and 13–19% low
  against 1–2 m in the district, whose fronts are partly shielded. The incident peak is 8–12% low.
  The impulse holds within about 5% in the open.
- **These walls go by the peak.** 0.5 kt's positive phase (about 0.3 s) is long against a wall's
  period, so the rotation follows the peak. The 13–19% higher peak multiplies the rotations 1.3–3
  and takes the run's wall chances from 0.43–0.74 to 0.98–1.00.
- **Converged at 2 m in the district.** 1 m changes the peaks by −6% to +3% against 2 m, the front
  walls' rotations by −5% to +13% and the worst wall's by −13% to +10%. The block in the open still gains 4% in peak from 1 m to 0.5 m. Its strips are cut by the coarse cells, so its rotations are compared only on the same coarse cells.
- **Neither the cut nor the corridors bend the incident wave.** The cut and whole scenes read the
  same at every gauge, to the digit. The corridors take the incident peak toward Kingery–Bulmash.
- **One thing left open.** In the district the 1 m level reads the incident positive-phase impulse
  12–17% below 4 m and Kingery–Bulmash; the block's 1 m and 0.5 m levels do not. That would lower
  the refined loads, not raise them. It may come from the terrain's cut cells on a second refined
  level, which the block does not have.

**So the 4 m runs' wall loads are biased low at 400–600 m of 0.5 kt.** Their peaks are 13–19% low
on Beirut's façades and 27% low in the open. The walls' chances (emmettl/bombcad-work#19) were calibrated on those
runs. The proposal, not made here: run `wall-calibrate`'s reference again on air refined to 2 m
near the walls. The interim alternative is a wall peak factor of about ×1.15 with the impulse
×0.95, in place of ×1.0 on both.


### The walls' chances re-judged on 2 m references (22 October 2026)

Beirut's ten near boxes (0.15–1.5 kt, the 4 m layout to 1,320 m, 3 s) were run again with the air
refined to 2 m below the buildings' tops (`district-compare --refine 2 --ceiling auto`). They took
24–168 s of air each, and no pool ran out. The walls' and roofs' chances were then re-judged
against them (`wall-calibrate`, each yield held out, 50 draws).

The choices judged:
- **today's:** concrete walls ×1.0, scatter ×1; stone ×1.0, scatter ×0.5; roofs ×1.3, scatter ×0.5;
- **the interim:** walls' peak ×1.15 with the impulse ×0.95;
- **a refit:** over loads ×0.8–1.5, scatters ×0.5 and 1, and the impulse's own ×0.83 or 1.

Each was judged with the learned field model's ground-floor peaks off and on (#67,
`--learned`).

**Concrete walls, moderate or worse** (2,053 buildings × 10 yields; Brier, skill, the tenths test):

| References | Model | Today's | Interim | Refit (its choice) |
|---|---|---|---|---|
| 4 m | surrogate | 0.013, 0.57, fail | 0.014, 0.51, fail | 0.013, 0.56, fail (×1.0, 8 of 10) |
| 4 m | field model | 0.012, 0.59, fail | 0.019, 0.36, fail | 0.010, 0.64, fail (×1.0, scatter ×0.5, impulse ×0.83) |
| 2 m | surrogate | 0.028, 0.48, fail | 0.024, 0.56, fail | **0.023, 0.59**, fail (**×1.3**, 9 of 10) |
| 2 m | field model | 0.021, 0.62, fail | **0.018, 0.66, pass** | 0.019, 0.66, fail (**×1.3**, scatter ×0.5, impulse ×0.83) |

- **The 2 m runs damage about twice as many concrete walls.** The Brier of giving each building
  the mean is 0.055 against 0.029. At 1.5 kt they fail 43 walls where the 4 m runs fail 32.
- **Against them, both models' walls want a load about 30% higher.** The surrogate's refit takes
  ×1.3 where it took ×1.0 against the 4 m runs. The field model's peak needs the same correction:
  ×1.3 against ×1.0, because it learned 4 m fields.
- **Concrete heavy or worse barely moves:** 0.53 today, 0.56 interim and 0.51 refit for the
  surrogate; 0.60 for the field model.
- **Stone walls don't move:** the refit keeps ×1.0 with scatter ×0.5 against both references
  (skill 0.70–0.71), and the interim's ×1.15 makes them worse (0.47–0.51). Stone is damaged at
  both resolutions alike.
- **Roofs don't move:** ×1.3 with scatter ×0.5 against both (skill 0.74–0.75).

The proposal, for the user to decide (no default changed):
- concrete walls' load ×1.3 on the surrogate;
- with the field model on, its walls ×1.3 with scatter ×0.5 and the impulse ×0.83;
- stone walls and roofs as they are.

Refined runs over terrain read the impulse a little low ([#78](https://github.com/emmettl/bombcad-work/issues/78): 3–6% at 2 m). These walls go by the peak, so ×1.3 is if anything a lower bound.

**Adopted on 22 October 2026** (the user's decision):
- concrete walls ×1.3 on the surrogate. Taken every yield alike, it scores Brier 0.022 and skill
  0.59, and passes the tenths test;
- with the field model, its walls' peak ×1.15 and impulse ×0.95;
- stone walls and roofs as they were.

The standing's figures are re-derived from the 2 m references
([validation](validation.md#the-walls-and-roofs-chances-against-beiruts-runs)).

**Re-judged on the mapped start (22 October 2026).** Every one of these references had started its
charge as the balloon, because a charge on terrain was never mapped (emmettl/bombcad-work#78,
fixed in aff21dff). Rerun on the mapped start, the judge holds to the second decimal:
- concrete walls moderate or worse at ×1.3: 0.023 / 0.59, tenths pass;
- the field model at the peak ×1.15, impulse ×0.95: 0.018 / 0.66, tenths pass;
- the refit takes ×1.3 in nine folds of ten;
- roofs 0.74.

The walls go by the peak, which the start barely moved.

### The refit on post-fix and 2 m runs, and shielding by the charge's surroundings (23 October 2026)

emmettl/bombcad-work#56. Since the terms were fitted, three things changed under them: the mapped
start on terrain (aff21dff), the 4 m runs' resolution bias
([learned models, round 3](learned-models.md#round-3-the-4-m-runs-resolution-bias-21-october-2026)),
and #19's 2 m references (14707293). This refits the terms on runs after the fix, on 2 m air where
it exists, and looks again for the feature [above](#close-in-among-buildings-21-october-2026) found
missing: what tells the silos at Warehouse 12 from a city block. **Nothing is changed**: the result
is a proposal, its coefficients a file.

**The runs.** All are after aff21dff, with every storey's strips:
- the fit set rerun on main 8b393c81, on 4 m air and on air refined to 2 m below the tops
  (`--refine 2 --ceiling auto`): dense at 20, 100 and 500 t, sparse at 20 t;
- Beirut's ten 2 m near boxes at Warehouse 12 (#19's, 0.15–1.5 kt);
- the field-model judge's 50 Beirut charges among buildings on 4 m cells (ten places, p0 at
  Warehouse 12, five yields each, 56 t–1.9 kt), and its two made-up districts.

On the made-up districts the refined runs' peaks are 10–16% above the 4 m runs' within Z 7 and
the same beyond Z 10 (the refinement follows the strong shock). The impulses match to a few per
cent.

**Two features, measured and off.**
- `Features.edgeWidthM` (eager-jang-174d10's): the knife edge's obstruction's width across the line
  of sight. It does not separate the silos from a city block. Behind buildings at Z 1.5–5, the
  branch reads Warehouse 12's façades 1.05–1.18 of the run at every width (0–1 W^(1/3)), and
  Beirut's streets 1.68–1.76.
- `Features.chargeOpenM` (`Raster.openReach`): how open the charge's surroundings are, as the
  median over 72 directions of how far a line from the charge runs before a building or the
  ground (up to 400 m). It is the same for every component, so the estimates measure it once per
  charge. This is what separates them:

| Charges | Open / W^(1/3) | Strips behind, Z 1.5–5 | Branch over run, today | Proposed |
|---|---|---|---|---|
| Warehouse 12, 2 m (ten yields) | 3.5–7.5 | 2,936 | 1.09 | 1.06 |
| Warehouse 12, 4 m (p0) | 3.5–8.5 | 1,223 | 1.18 | 1.15 |
| p4, p1 (a square, a wide street) | 0.6–3.1 | 100,267 | 1.36–1.51 | 1.10–1.11 |
| p2, p3, p5, p7, p8 | 0.1–1.4 | 619,319 | 1.61–1.76 | 1.13–1.21 |
| p6 | 0.3–0.9 | 138,007 | 1.93 | 1.32 |
| p9 | 0.5–1.1 | 38,191 | 1.31 | 0.93 |
| Made-up mixed / perimeter (4 m) | 2.4 / 0.2 | 2,039 / 15,211 | 1.36 / 1.40 | 1.18 / 0.96 |
| Dense fit set, 2 m | 2.6–7.6 | 4,596 | 1.32 | 1.16 |

**The proposal** (`$BOMBCAD_DATA/refit56/takeover/co/bs.json`):
- **The peak's terms** refitted on the 2 m runs: the fit set and five of the ten near boxes (150,
  300, 500, 850 and 1,300 t), each run alike. The impulse's terms are refitted on the fit set's 2 m
  runs alone: beyond Z 10 the near boxes' first-phase impulses scatter by a log-SD of 0.8–1.5, as
  the 3 s boxes cut their phase short.
- **Kept as they are:** the rise share, the canyon terms, the close-in branch, the range (4.6–38.7)
  and the scatter (0.240, 0.168). The chances draw the scatter, and the refit's own residual (0.31
  with Warehouse 12's strips in, 0.25 without) is a separate decision.
- **Shielding behind buildings in the branch** (`CloseIn.Shielding`). For a component with a
  building in the way, the log peak gains −0.486 e^(−open / 2 W^(1/3)), and the log impulse −0.265
  times the same. It is fitted on log(run / branch) over Z 1.5–8, weighted by the branch's share
  there, on:
  - Beirut's charges at p1, p3, p5, p7 and p9, their 4 m peaks raised by ×1.13 (the fit set's
    2 m over 4 m behind buildings within Z 5);
  - the five near boxes;
  - the fit set at 2 m.

  The scale was chosen on the same fit; 1–3 W^(1/3) fit about as well, and a constant fits worse.

Its peaks, predicted over recorded (median, log-SD), every storey inside 0.85 of each box:

| | Today | Terms refitted | Today + shielding | Proposed |
|---|---|---|---|---|
| **Streets held out (p2, p4, p6, p8; 4 m; 3.5 M strips)**: all | 1.08 (0.39) | 1.08 (0.38) | 1.03 (0.34) | 1.03 (0.32) |
| … Z < 5, in sight | 1.09 (0.82) | 1.07 (0.82) | 1.09 (0.82) | 1.07 (0.82) |
| … Z < 5, behind buildings | 1.76 (0.56) | 1.78 (0.56) | 1.24 (0.56) | 1.22 (0.55) |
| … Z < 5, behind, ground floor / upper storeys | 1.49 / 1.82 | 1.51 / 1.84 | 1.05 / 1.28 | 1.04 / 1.26 |
| … Z 5–7 / 7–10 / 10–14 / 14–20 / 20–40 | 1.14 / 0.98 / 1.03 / 1.07 / 1.02 | 1.24 / 1.06 / 1.02 / 1.00 / 0.95 | 0.96 / 0.97 / 1.03 / 1.07 / 1.02 | 1.04 / 1.04 / 1.02 / 1.00 / 0.95 |
| **Warehouse 12, 2 m, the five yields no fit saw**: all | 0.93 (0.37) | 0.97 (0.34) | 0.93 (0.37) | 0.97 (0.34) |
| … Z < 5, in sight / behind | 1.06 / 1.09 | 1.11 / 1.14 | 1.06 / 1.02 | 1.11 / 1.06 |
| … Z 5–7 / 7–10 / 10–14 / 14–20 | 0.82 / 0.87 / 0.95 / 1.02 | 0.95 / 0.97 / 0.97 / 0.98 | 0.80 / 0.86 / 0.95 / 1.02 | 0.93 / 0.97 / 0.97 / 0.98 |
| **Warehouse 12, 4 m (p0)**: Z < 5 behind; Z 5–7 | 1.18; 0.87 | 1.24; 1.01 | 1.10; 0.85 | 1.15; 0.98 |
| **Made-up held out (4 m)**: Z < 5 behind; Z 5–7; all | 1.41; 1.01; 0.98 | 1.47; 1.13; 1.05 | 0.98; 0.84; 0.90 | 0.99; 0.93; 0.96 |
| **Fit set, 2 m**: Z < 5 behind; Z 5–7; all | 1.32; 0.98; 1.05 | 1.31; 1.06; 1.02 | 1.18; 0.93; 1.04 | 1.16; 1.00; 1.01 |

- **Close in behind buildings, 1.7–1.8 times high becomes 1.2**, against 4 m runs on held-out
  street charges. A 2 m reference would read about ×1.13 above those, so the proposal is within
  about 10% of it. Warehouse 12 keeps its loads: behind the silos 1.09 becomes 1.06.
- **Upper storeys behind buildings are still high** (1.26 in the held-out streets, against 1.04 for
  the ground floor). Neither feature carries height.
- **The impulses** behind buildings close in go from 1.21 to 0.99 in the held-out streets, from
  1.10 to 1.06 at Warehouse 12, and from 1.12 to 0.92 on the made-up held-out pair.
- **The terms refitted lift Warehouse 12 at Z 5–10** from 0.82–0.87 to 0.93–0.97 of the 2 m runs.
  That is the band whose low walls made #19 take ×1.3. They take the made-up districts at Z 5–7
  from 0.98 to 1.06, and the street charges beyond Z 14 from 1.07 to 1.00.

**Glass, through the app's estimate.**
- **By side, on the ten 2 m near boxes** (`field-refs`): the proposal changes none of it.
  - every storey: 0.904 / 0.54 → 0.903 / 0.55 (exact / Heidke);
  - ground floor: 0.911 / 0.51 → 0.910 / 0.51;
  - upper storeys: 0.903 / 0.54 → 0.902 / 0.55.

  At 50–700 m the peaks by storey go from 0.77–0.92 of the 2 m runs to 0.88–1.05, as round 4 of
  the field model has them at the upper storeys.
- **On Beirut's full 4 m runs to 3 km** (`surrogate-judge`), sides at the run's state at 0.2 / 0.5 /
  1.1 kt: 0.84 / 0.75 / 0.81 → 0.84 / 0.78 / 0.83. The blown-out share at 0.5 kt comes closer at
  1.5–1.75 km (0.17 → 0.06, run 0.07), and further off at 1.25–1.5 km (0.43 → 0.36, run 0.59).
- **The glass chances' calibration** (`glass-calibrate`, against the full runs, with the load
  scatter; Brier / skill, every decile of 200+ within 0.1 either way): some broken 0.031 / 0.63 →
  0.028 / 0.66; blown out 0.020 / 0.81 → 0.017 / 0.84; thrown past 3b 0.033 / 0.72 → 0.032 / 0.73;
  openings blown out 0.003 / 0.82 → 0.002 / 0.86. All pass, as today's do. Against GEER's
  openings, seen two months on, the skill goes from 0.15 to 0.19, still failing its deciles.

**#19's walls and roofs on the 2 m references** (`wall-calibrate`, 2,053 buildings × 10 yields, 50
draws; Brier / skill / the tenths test):

| | Today | Proposed |
|---|---|---|
| Concrete moderate or worse, the adopted ×1.3 | 0.023 / 0.59 / pass | 0.023 / 0.59 / fail |
| … ×1.15 | | **0.021 / 0.61 / pass** |
| … the refit, each yield held out (its choice) | 0.023 / 0.59 / fail (×1.3) | 0.021 / 0.61 / fail (×1.15, impulse ×0.83, every fold) |
| Concrete heavy or worse, ×1.3; ×1.15 | 0.009 / 0.49 / fail | 0.011 / 0.38 / fail; 0.008 / 0.53 / fail |
| Roofs moderate or worse | 0.029 / 0.74 | 0.029 / 0.74 |
| The five yields no fit saw: concrete moderate or worse, ×1.3; the refit | 0.025 / 0.60; 0.026 / 0.60 | 0.026 / 0.59; 0.027 / 0.58 |

- **With the proposal the walls want ×1.15, not ×1.3.** The terms now give the 2 m runs' peaks at
  Warehouse 12, so most of #19's factor is in them. Kept at ×1.3, the proposal counts it twice:
  heavy or worse falls to 0.38.
- **On all ten yields** the proposal at ×1.15 is a little better than today's at ×1.3, and passes.
  But five of the ten were in its fit. **On the five it never saw** it is about the same (0.026 /
  0.59 against 0.025 / 0.60). The walls gain nothing out of sample: Warehouse 12's walls stand in
  the open, where the shielding does nothing.
- Roofs keep their own terms and do not move.

**The decision for the user.** Adopt the proposal (`bs.json`) as `Coefficients.fitted`, with the
walls' factor ×1.3 → ×1.15 and the roofs as they are; or keep today's.
- **For:** close in behind buildings among streets, today's worst error (1.7–1.8 times high), comes
  to within about 10% of a 2 m reference. Beirut's full-run glass gains 0.02–0.03 of sides, and
  every one of the glass chances' scores improves.
- **Against:** walls and glass on the 2 m near boxes don't move out of sample. Two places go to the
  low side: made-up perimeter blocks (0.96 at 4 m) and Beirut's p9 (0.93).
- **With it:** the standing's close-in figure (`surrogateCloseInShielded`, 1.4–1.7) is re-derived.

The fit, the judges and their scripts are in `$BOMBCAD_DATA/refit56/takeover` (`py/` for the fits
and strip tables, `judges.sh` and `judges2.sh` for the benches).

## Using it

- **In the app**: Simulation ▸ Quick Estimate of Envelope Damage colours the envelope buildings
  by the estimate and fills the damage section, headed as a quick estimate with this standing,
  until a run's damage replaces it. With Place Charge on, drag the charge and the estimate follows
  as a preview, marked as one ([above](#dragging-the-charge-20-october-2026)).
- **Headless**: `BombCAD run project.bombcad --surrogate first-look.json` writes the buildings'
  damage as `--envelope-damage` would, marked as an estimate with its method and standing, and
  does not run (`--resolution` and `--mass` change the inputs as for a run).
- **Beyond a near run**: the [hybrid far field](hybrid-far-field.md) carries a district past a 3-D
  run of its near field with these loads, matched to the run where they meet.
- **Bench**: `scenebench drag-time` times a drag and judges the preview (Sources/SceneBench/DragTime.swift,
  outputs under `bombcad/drag`); `scenebench surrogate-extract` and `surrogate-judge` (Sources/BlastModel/Studies/SurrogateBench.swift)
  with `Scripts/fit-surrogate.py`; the runs, extracts, fits and judgements are on StudioData under
  `bombcad/surrogate`. The fine runs behind the canyon terms, the close-in branch
  (`Scripts/fit-close-in.py`) and the shielding study are under `bombcad/protective/refit` and
  `bombcad/canyon` (`blastbench canyon`, `blastbench barrier`).

## Limitations

- **Fitted to two made-up districts on 4 m cells.** Other cells are reached only through the
  cell term, fitted over 0.05–0.15 of W^(1/3); other building types (thin walls, panes) are
  given the façade strips' terms, roofs their own (`Coefficients.roofs`).
- **Only between Z = 1.5 and 38.7 m/kg^(1/3).** The fitted terms hold over 4.6–38.7, the
  distances they were fitted over (the fit's 2nd to 98th percentiles), and the close-in branch over
  1.5–4.6. Beyond those the terms are held at the range's end, so that the correction cannot fall
  away as a fitted quadratic would, while Kingery–Bulmash's base still follows the distance. Those
  components are marked as extrapolated: counted in the app's status and in `--surrogate`'s
  `outsideFit`. The close-in impulse moves 17% between 1 m and 0.5 m cells: not converged.
- **It copies the runs, artefacts and all.** On 4 m cells a run's façade peaks are 0.45–0.57 of
  Kingery–Bulmash's reflected ones even in sight of the charge; the surrogate gives those, not the
  reflected peak a finer run would.
- **Beirut shaped its form.** See above: the terms for terrain were chosen after Beirut's
  residuals were seen, though fitted without it.
- **Streets only along the line of sight.** A street the line runs down raises the loads by the
  fine canyon runs' terms. A street off the charge, behind a row, is seen as a row crossed, though
  fine runs put its lee walls up to ×1.6 in peak and ×1.7 in impulse over that.
- **Shielding is the districts'.** A building or barrier in front takes 2–3% off, as the 4 m
  district runs show. Fine runs take half or more off within a couple of its heights behind it; a
  factor fitted on them did not hold for the districts or the barriers
  ([below](#shielding-streets-and-the-close-in-branch-20-october-2026)).
- **Isolated façades at tonne scale** beyond Z 8 are read 0.6–0.8 of a fine run's: the fitted
  terms are the districts', where nearly every façade stands behind something.
- **Single charges on the ground**, as Kingery–Bulmash's surface burst; no deflagrations, no
  charges in or on buildings.

## Sources

- C. N. Kingery and G. Bulmash, *Airblast parameters from TNT spherical air burst and
  hemispherical surface burst*, ARBRL-TR-02555, 1984; M. M. Swisdak, *Simplified Kingery
  airblast calculations*, 1994 (the fits `KingeryBulmash` uses).
- GEER, *Beirut port explosion* reconnaissance (GEER-070, 2021), the façade survey the Beirut page
  compares with.
- The Beirut runs and their inputs: [Beirut, 4 August 2020](beirut-2020.md).

## Future work

- A finer reference: fitting to refined or 3 m runs, so that the first look gives converged loads
  rather than a 4 m run's.
- Thin walls and panes, from runs of the presets with detailed envelopes.
- Chances for walls and roofs, drawn over the scatter as the glass's are, so that counts by band
  can match a run's.
- Streets off the charge (the lee walls behind a row), and shielding that holds for barriers on
  fine cells and for districts on 4 m cells at once; a learned model if the linear terms stop
  improving.
- Probabilities from the scatter: done for the glass, [glass by chance](glass-probability.md).
