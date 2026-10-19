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
- **Does not: walls and roofs.** Of the components either the run or the surrogate calls damaged,
  0–10% of the concrete and 35–42% of the stone take the run's level; on its own training
  districts the share is 12–17% and 42–53%. The few damaged components lie close in, where one
  wrong factor of 1.3 moves a wall across a level. Run the scene for the structure.
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
4. **Its pulse.** A triangle of that peak and impulse, lasting twice the impulse over the peak,
   rising to its peak over a fitted share of that time (0.2–0.35 on 4 m cells: behind buildings
   the load builds up over tens of milliseconds as the streets fill). On its own training district
   a pulse that rose at once blew out 8,188 of the 11,805 sides the run left partly glazed, and
   53% of sides agreed; with the rise, 85% agree.
5. **Its damage.** The pulses go into `EnvelopeDamageAssessment` as a run's histories do: the same
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
its strips). The near-field terms and these near bands wait for a refit on loads saved without
the cap.

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
  `bombcad/surrogate`.

## Limitations

- **Fitted to two made-up districts on 4 m cells.** Other cells are reached only through the
  cell term, fitted over 0.05–0.15 of W^(1/3); other building types (thin walls, panes, roofs) are
  given the façade strips' terms. Roofs' loads are not fitted at all.
- **Only between Z = 4.6 and 38.7 m/kg^(1/3)**, the distances it was fitted over (the fit's 2nd
  to 98th percentiles). Beyond them the terms in log Z are held at the range's end, so that close
  in the correction cannot fall away as the fitted quadratic would (to a few hundredths of the
  base at Z = 1), while Kingery–Bulmash's base still follows the distance. Those components are
  marked as extrapolated: counted in the app's status and in `--surrogate`'s `outsideFit`.
- **It copies the runs, artefacts and all.** On 4 m cells a run's façade peaks are 0.45–0.57 of
  Kingery–Bulmash's reflected ones even in sight of the charge; the surrogate gives those, not the
  reflected peak a finer run would.
- **Beirut shaped its form.** See above: the terms for terrain were chosen after Beirut's
  residuals were seen, though fitted without it.
- **No channelling as such.** A street running from the charge is seen only as a line with no
  building in it; a long canyon's loads are not raised beyond that.
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
- Roofs, thin walls and panes, from runs of the presets with detailed envelopes.
- A street-canyon term, and a learned model if the linear terms stop improving.
- Probabilities from the scatter: done for the glass, [glass by chance](glass-probability.md).
