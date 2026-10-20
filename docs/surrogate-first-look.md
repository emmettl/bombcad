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
/Volumes/StudioData/bombcad/rise-fix.

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
  `/Volumes/StudioData/bombcad/protective/refit/fit-sq.json` (`gate/` holds its judgements) and
  its term in `terms` at nothing
  ([protective design](protective-design.md#stage-5-the-refit-and-what-it-changes-for-a-plan)).
- **Two limitations found.**
  - Behind a row, the lee walls of a street that does not point at the charge are read up to ×1.6
    low in peak (×1.7 in impulse).
  - The close-in branch's impulse moves 17% between 1 m and 0.5 m cells: not converged.

## Using it

- **In the app**: Simulation ▸ Quick Estimate of Envelope Damage colours the envelope buildings
  by the estimate and fills the damage section, headed as a quick estimate with this standing,
  until a run's damage replaces it.
- **Headless**: `BombCAD run project.bombcad --surrogate first-look.json` writes the buildings'
  damage as `--envelope-damage` would, marked as an estimate with its method and standing, and
  does not run (`--resolution` and `--mass` change the inputs as for a run).
- **Beyond a near run**: the [hybrid far field](hybrid-far-field.md) carries a district past a 3-D
  run of its near field with these loads, matched to the run where they meet.
- **Bench**: `scenebench surrogate-extract` and `surrogate-judge` (Sources/SceneBench/SurrogateBench.swift)
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
