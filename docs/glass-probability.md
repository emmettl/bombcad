# Glass by chance: each building side's probability of broken glass

The [first look](surrogate-first-look.md) gives one answer for each building side's glass. This
gives a chance instead: the chance that some pane of the side breaks (GEER's W1 or worse), the
chance that it is blown out (nine in ten of its panes broken, against GEER's W3), and the chance
that some pane is thrown worse than GSA's condition 3b (its glass beyond 3 m into the room), which
protective design ranks plans by. It draws
the first look a hundred times over what is not known, in 20–65 s for a city's 29,000 sides on
the Studio (the more so the more other jobs share it).
It is the first step of [Horizons](roadmap.md#horizons) item 4, "Uncertainty by default".

**For the glass only.** The first look's walls and roofs are not to be relied on (fewer than
three in ten of the damaged components take the run's level), so no chance is given for them,
and the app and `--surrogate`'s output say so.

## What holds and what does not

- **Holds: the spread of the runs.** Drawn over the yields of Beirut's three full runs (0.2, 0.5
  and 1.1 kt), the chances match how often those runs broke each side's glass, and passed the
  protective-design report's test (each tenth of chance within 0.1 of the share seen) for all
  three: some broken, blown out, and thrown past condition 3b (skill 0.73, each tenth within 0.09).
  Blown out: Brier score 0.017, against 0.108 for giving every side the mean chance (a skill of
  0.84), and each tenth of chance within 0.06 of the share of runs. Some broken: skill 0.66, the
  middle chances 0.03–0.08 high. Without the surrogate's own scatter the blown-out skill is 0.80,
  so the scatter earns its place. These are on the façade terms refitted on 23 October 2026
  ([below](#judged-again-on-the-refitted-terms-23-october-2026)); on the terms before, blown out
  scored 0.81 and the throw 0.72.
- **Not judged against the event's survey.** GEER's classes of Beirut's façades are openings
  (frames and doors with the windows), photographed two months on, not glass broken
  ([traced below](#why-it-over-breaks-against-geer-19-october-2026)): the glass chances' blown out
  0.93 at 0.75–1 km where GEER saw 0.27 compares unlike things. Read them as the spread of what a
  run would give.
- **Openings blown out**, a fourth chance fitted to that survey (one event, at 4 m cells; not
  physics), is judged against it: 0.34 at 0.75–1 km where GEER saw 0.27, inside the draws' 90%
  range in four bands of seven, skill 0.19 (0.31 and 0.15 on the terms before).

## What is drawn

For each draw (`FacadeLoadSurrogate.Uncertainty`):

- **The yield**: from a posterior's samples (`scenebench infer-charge --samples`, its first column
  the log10 of the mass), or log-normal about the scene's charge. In the app, "Yield known to
  within" sets the factor it lies within nine times in ten (×1.5 by default); headless,
  `--surrogate-yields samples.csv` or `--surrogate-yield-within 1.5`.
- **Each building's glass strength**: log-normal about the flaw model's median, with a standard
  deviation of 0.25 in its logarithm, for its panes' age, make and fixing. One pane's scatter about
  another's is already in each pane's own chance (E1300's flaw model, `GlassStrength`).
- **The surrogate's scatter**: for each building side, shared by its strips, its peak and impulse
  off the fit by a correlated log-normal error whose spread depends on the scaled distance. The
  spread is how far each of the four fitted runs falls from a fit to the other three: 0.23–0.41
  for the peak and 0.16–0.26 for the impulse (bias and spread together), correlated 0.26–0.67.
  It is not taken from Beirut, so the check against Beirut's runs is not circular.

A side's chance that some pane breaks is the draws' mean of that chance; its chance of being
blown out is the share of draws in which nine in ten of its panes are expected broken. Its chance
of glass thrown past condition 3b is the draws' mean chance that some pane both breaks and is
thrown that far (`GlazingHazard`: the glass flying as one piece from the pane's middle, 0.9 m
sill), judged on a pane breaking at the draw's strength, or just under the stress the load
reaches where that is less, since the panes that break are the weaker.

A pane type's response to the surrogate's pulses depends only on the pulse, so it is tabulated
by the rounded peak, impulse and rise (the 60 s stress it reaches, or that it lets go), and each
draw's strength turns that into a chance without integrating again.

## Judged

`scenebench glass-calibrate` (Sources/BlastModel/Studies/GlassCalibration.swift), on the strips of
Beirut's runs within 0.85 of their half-side, matched as for the
[first look](surrogate-first-look.md#judged-against-beirut).

**(a) Against the runs.** Each side's share of the three runs in which it was blown out (or the
mean of its chance of some pane breaking, or of a pane thrown worse than condition 3b), against
its chance drawn over those three yields, with the scatter and without strength scatter (the runs
judge every pane at the median). The test is the protective-design report's (cloud report of
19 October, §4, stage 1): it passes if every tenth of chance holding 200 sides or more lies within
0.1 of the share seen. All three pass; without the surrogate's scatter the throw fails (sides
given 0.04 had a pane thrown in 21% of runs).

| Chance | Blown out: sides | mean chance | share of runs | Thrown past 3b: sides | mean chance | share of runs |
|---|---|---|---|---|---|---|
| 0–0.1 | 13,190 | 0.03 | 0.02 | 140 | 0.08 | 0.04 |
| 0.1–0.2 | 3,794 | 0.14 | 0.09 | 1,341 | 0.16 | 0.15 |
| 0.2–0.3 | 2,441 | 0.24 | 0.19 | 2,520 | 0.25 | 0.24 |
| 0.3–0.4 | 1,761 | 0.34 | 0.34 | 3,629 | 0.35 | 0.30 |
| 0.4–0.5 | 1,516 | 0.44 | 0.42 | 4,050 | 0.45 | 0.39 |
| 0.5–0.6 | 1,464 | 0.54 | 0.52 | 3,290 | 0.55 | 0.51 |
| 0.6–0.7 | 1,314 | 0.64 | 0.65 | 3,200 | 0.65 | 0.65 |
| 0.7–0.8 | 1,019 | 0.74 | 0.73 | 2,613 | 0.75 | 0.78 |
| 0.8–0.9 | 904 | 0.85 | 0.83 | 1,846 | 0.85 | 0.91 |
| 0.9–1 | 1,588 | 0.96 | 0.96 | 6,362 | 0.98 | 0.99 |

Brier scores: blown out 0.020 (0.108 giving every side the mean; skill 0.81), thrown past 3b 0.033
(0.116; skill 0.72), some broken 0.032 (0.084; skill 0.62).

There is no ensemble of runs over a district's other unknowns (the validation ensemble samples
structural tests' inputs, not a city's), so the runs check only the yield and the surrogate's
scatter, not the strength.

**(b) Against GEER** (as it was, before the trace below; the glass states are no longer judged
against the survey). Each of GEER's 9,183 street façades (DesignSafe PRJ-3030, its shapefile's
segment centres and `Azimuth_N` normals, in degrees) is matched to the side of a map building
within 25 m that faces within 60° of it: 8,227 are. By distance band, the share seen against the
draws' mean and 90% range:

| Distance | Façades | W1+ seen | Chance some broken | W3 seen | Chance blown out |
|---|---|---|---|---|---|
| 0.5–0.75 km | 722 | 0.84 | 1.00 (1.00–1.00) | 0.76 | 0.97 (0.93–1.00) |
| 0.75–1 km | 1,279 | 0.62 | 1.00 (1.00–1.00) | 0.27 | 0.91 (0.84–0.98) |
| 1–1.25 km | 1,716 | 0.38 | 1.00 (1.00–1.00) | 0.17 | 0.76 (0.61–0.92) |
| 1.25–1.5 km | 2,302 | 0.35 | 1.00 (0.99–1.00) | 0.17 | 0.56 (0.38–0.77) |
| 1.5–1.75 km | 1,312 | 0.37 | 0.98 (0.94–1.00) | 0.09 | 0.35 (0.18–0.59) |
| 1.75–2 km | 386 | 0.28 | 0.96 (0.91–1.00) | 0.02 | 0.22 (0.07–0.51) |
| 2–2.5 km | 510 | 0.27 | 0.93 (0.82–1.00) | 0.15 | 0.13 (0.00–0.35) |

**What a stronger glass would do.** As a diagnostic only, with every building's glass a multiple
of the flaw model's median strength and a wider spread: at four times (a log standard deviation
of 0.75) the share with some glass broken falls inside the 90% range in six bands of seven, but
the share blown out falls below it in six of seven (0.31 against 0.76 at 0.5–0.75 km); at twice
(0.5) the blown-out share is inside in four bands but some broken is too high in all. No one
strength fits both: the model's façades go from a pane broken to blown out over a shorter
distance than GEER's did. GEER's photographs were taken two months on, some façades repaired,
and its W3 counts frames and doors, which the model has none of.

## Why it over-breaks against GEER (19 October 2026)

Traced on the three 4 m Beirut runs' saved loads (`glass-calibrate --trace`, Scripts/glass-trace):
each of GEER's façades matched to its side (4,836 with the side's strips saved), and what GEER saw
set against that side's own peak net load in the run, at 0.5 kt.

| Side's peak load (run) | Façades | GEER W0 / W1 / W2 / W3 | Model: panes broken |
|---|---|---|---|
| 3–5 kPa | 431 | 0.71 / 0.16 / 0.03 / 0.10 | 0.33 |
| 5–7 kPa | 1,203 | 0.67 / 0.10 / 0.18 / 0.06 | 0.75 |
| 7–10 kPa | 1,304 | 0.67 / 0.19 / 0.03 / 0.11 | 0.96 |
| 10–15 kPa | 1,018 | 0.52 / 0.16 / 0.08 / 0.24 | 0.99 |
| 15–20 kPa | 391 | 0.24 / 0.10 / 0.14 / 0.53 | 1.00 |
| 20–30 kPa | 278 | 0.17 / 0.08 / 0.09 / 0.66 | 1.00 |
| 30–50 kPa | 75 | 0.00 / 0.03 / 0.03 / 0.95 | 1.00 |

The four candidates, in turn:

- **Stronger glass in place: no.** For the chance of some pane broken to fall to GEER's W1+, the
  glass would need 4.4 times E1300's median strength at 0.5–0.75 km, 3.8 at 1–1.25 km and 2.1–2.2
  beyond 1.5 km: no one factor, and more than any glass has. Glass ages weaker, not stronger, and
  the model's 60 s stresses already allow for the blast's short load (Brown's integral, n = 16).
  The model's glass edge, half the panes broken at 1.5–1.75 km at 0.5 kt, is where Rigby et al.'s
  check with Viper put old annealed façades' (about 1.86 km at 465 t).
- **The frame's bite and the panes' sizes: not at 1 km.** Panes letting go of their frames are
  0.53 of them at 0.5–0.75 km, 0.15 at 0.75–1 km and none beyond 1.25 km; and a side's dozens of
  panes make some pane break at loads every mix's panes reach, so no mix changes W1+.
- **Facing and shielding: alike in both.** At 0.75–1.75 km GEER's façades facing the charge, side
  on and facing away were damaged alike (0.63, 0.65 and 0.61 W1+ at 0.75–1 km), and the model's
  loads on them were alike too (14.7, 14.4 and 13.8 kPa): in a city this dense few façades see the
  charge, and most take a wave led round and down the streets. The loads are 0.7–0.8 of Kingery–
  Bulmash's at 4 m, as the [Beirut page](beirut-2020.md#peak-overpressure) found; they are not
  too high.
- **The survey: yes.** GEER classed openings, not glass, from street-level photographs taken on 8
  and 15 October, two months on, noting repairs (GEER-070, §4.4). Its W3 is "nearly complete
  blow-out of windows, doors and their frames": frames, which need more load than glass. Against
  the side's peak it is a fragility, median 18.5 kPa and log standard deviation 0.75 (fitted at
  0.5 kt), which follows GEER by distance at 0.5 kt (0.59, 0.38, 0.20, 0.11, 0.05, 0.02 against
  0.78, 0.30, 0.17, 0.07, 0.12, 0.03 from 0.5 to 2 km) where nine panes in ten broken gives 1.00,
  1.00, 0.95, 0.54, 0.05, 0.00. Its W1, "some windows broken", carries a break rate of 10–20% of
  windows (the median by band), and W1 or worse against load is shallow (median 10.8 kPa, log
  standard deviation 1.1), with 17% of façades at 20–30 kPa showing nothing, where every pane
  breaks. That is what was visible two months on, not what broke.

So the glass is not what over-breaks: it is set against classes that are not glass. W3 compares
with frames blown out, and W1 or worse with damage visible two months on.

**What was done.** The glass states (some broken, blown out as nine panes in ten, thrown past
condition 3b) stay as they are, judged against the runs, not the survey. A fourth chance is added
beside them:

- **Openings blown out** (`FacadeLoadSurrogate.OpeningsFragility`): a map building side's chance
  by the fragility above on its peak, drawn with the others (`SideGlass.openingsBlownOut`), median
  18.5 kPa and log standard deviation 0.75, fitted on the 0.5 kt run's loads at 4 m cells (whose
  peaks are 0.7–0.8 of Kingery–Bulmash's, so the curve is tied to that resolution). It is the only
  chance judged against GEER's W3. Fitted to one event's survey: illustrative elsewhere.
- **Judged** (`glass-calibrate`, drawn over the inferred yield as above): skill 0.15 against GEER's
  W3 (Brier 0.144, against 0.169 giving every side the mean), where the glass's blown out had
  −1.0. By band, against GEER's W3:

| Distance | Façades | GEER W3 | Openings blown out (90% range) |
|---|---|---|---|
| 0.5–0.75 km | 722 | 0.76 | 0.48 (0.40–0.58) |
| 0.75–1 km | 1,279 | 0.27 | 0.31 (0.25–0.42) |
| 1–1.25 km | 1,716 | 0.17 | 0.19 (0.14–0.28) |
| 1.25–1.5 km | 2,302 | 0.17 | 0.12 (0.08–0.19) |
| 1.5–1.75 km | 1,312 | 0.09 | 0.08 (0.05–0.13) |
| 1.75–2 km | 386 | 0.02 | 0.04 (0.02–0.08) |
| 2–2.5 km | 510 | 0.15 | 0.02 (0.01–0.05) |

  Inside the 90% range from 0.75 to 1.75 km; under it close in, where the first look's peaks fall
  short of the run's (its fit ends near Z 4.6), and at 2–2.5 km, where nothing in any run reached
  GEER's 0.15. The middle tenths of chance sit 0.1–0.16 under GEER's shares, so the decile test
  fails. The same curve on the 0.2 and 1.1 kt runs' own loads gives 0.17 and 0.60 at 0.75–1 km,
  bracketing GEER's 0.27 with the yield; it is fitted and judged on one event.


### Judged again on the refitted terms (23 October 2026)

The façade terms were refitted on air refined to 2 m, with shielding behind buildings close in
(emmettl/bombcad-work#56; [the first look](surrogate-first-look.md#adopted-23-october-2026)). The
same judge (`glass-calibrate`, 100 draws), against the runs and GEER, before and after:

| | Before | Adopted |
|---|---|---|
| Blown out, Brier / skill; worst tenth | 0.020 / 0.81; 0.05 | 0.017 / 0.84; 0.06 |
| Thrown past 3b, Brier / skill; worst tenth | 0.033 / 0.72; 0.06 | 0.032 / 0.73; 0.09 |
| Some broken, Brier / skill | 0.031 / 0.63 | 0.028 / 0.66 |
| Openings blown out against GEER's W3, Brier / skill | 0.144 / 0.15 | 0.138 / 0.19 |
| … by band, 0.5–0.75 / 0.75–1 / 1–1.25 / 1.25–1.5 / 1.5–1.75 / 1.75–2 / 2–2.5 km (GEER 0.76 / 0.27 / 0.17 / 0.17 / 0.09 / 0.02 / 0.15) | 0.49 / 0.32 / 0.19 / 0.12 / 0.08 / 0.04 / 0.02 | 0.55 / 0.34 / 0.19 / 0.11 / 0.07 / 0.04 / 0.03 |
| The glass's blown out at those bands (not judged) | 0.98 / 0.92 / 0.76 / 0.55 / 0.35 / 0.23 / 0.14 | 0.99 / 0.93 / 0.76 / 0.52 / 0.31 / 0.20 / 0.17 |

All three glass states still pass the test against the runs; the openings still fail their
deciles against GEER, the middle tenths 0.09–0.16 under its shares.

## Walls and roofs

Since 20 October 2026 the quick estimate also gives each building three chances:
- that its worst wall is damaged moderately or worse;
- that its worst wall is damaged heavily or worse, illustrative for concrete;
- that its roof is damaged moderately or worse.

They are drawn as the glass's are, over the yield and each side's load scatter, and over an assumed
scatter in what the walls and roof can bear. That scatter is a log-normal on the resistance, about
15% for concrete and 30% for masonry; no survey gives it. A single estimate undercounts the
components a run damages, which are its loads' upper tail; drawn, the counts can follow the run's
([the first look](surrogate-first-look.md#walls-and-roofs-20-october-2026)).

**Calibrated** against Beirut's near boxes (to 1,320 m, uncapped loads) at ten yields from 0.15
to 1.5 kt, on air refined to 2 m below the buildings' tops since 22 October 2026
(`scenebench wall-calibrate`; emmettl/bombcad-work#19). Each yield is taken at its own yield with
the settings below. The judgement uses the façade terms refitted on 2 m air on 23 October 2026,
with their close-in branch and its shielding (emmettl/bombcad-work#4, #56). The runs judge every wall at its nominal strength, so they check the
load's scatter, not the strength's.

| Chance (2,053 buildings × 10 yields) | Settings | Brier skill | Tenths, each within 0.1 of the runs |
|---|---|---|---|
| Concrete walls, moderate or worse | loads ×1.15, the whole scatter (the refit's load in 10 folds of 10) | 0.61 | pass |
| The same with field model 1's ground-floor peaks | peak ×1.15, impulse ×0.95, the whole scatter | 0.65 | pass |
| The same with field model 2's peaks at every storey, its own scatter | as field model 1's | 0.66 | pass |
| Concrete walls, heavy or worse (illustrative) | as the first | 0.53 | 0.1–0.5 high by 0.11–0.23 |
| Stone walls, heavy or worse (each building as 0.5 m stone) | loads ×1.0, scatter ×½ | 0.72 | 0.4–0.9 high by up to 0.19 |
| Roofs, moderate or worse | loads ×1.3, scatter ×½ | 0.74 | 0.4–0.9 low by 0.11–0.18 |

On the façade terms before 23 October, fitted on 4 m cells, concrete took ×1.3 (skill 0.59), stone
0.70 and heavy damage 0.49. The refitted terms give the 2 m runs' peaks at 5–10 m/kg^(1/3), so
most of that ×1.3 is in them; kept at ×1.3 they would count it twice (heavy or worse 0.38). The
field model's factors were judged again on the refitted terms and kept: the refit chose them in
every fold for field model 2, whose walls now pass the tenths test, and ×1.15 for field model 1,
whose skill falls from 0.66 to 0.65
([the first look](surrogate-first-look.md#adopted-23-october-2026)).

**Why the walls' factor changed.** The 4 m runs the chances were first calibrated on read the walls'
peaks 13–19% low at 400–600 m of 0.5 kt; the 2 m runs damage about twice as many concrete walls.
Against the 4 m runs concrete took ×1.0 (skill 0.55); against the 2 m runs ×1.3, and ×1.15 once
the façade terms were refitted on 2 m air (23 October 2026). Stone and roofs took the same settings
against both
([the first look](surrogate-first-look.md#the-walls-chances-re-judged-on-2-m-references-22-october-2026)).

- **Concrete walls' damage is calibrated.** It passes the protective-design report's test, each
  tenth holding 50 buildings or more within 0.1 of the share of runs.
- **Roofs' chances are skilful but low in the middle.** That is the unsafe side, even with a load
  factor fitted on these runs (their own terms read low).
- **Stone's chances are high** by up to 0.19, the safe side. For masonry, moderate and heavy are
  one level.
- **No chance of failure is given.** Before the close-in branch the roofs' read far too high
  (skill −0.48), and the walls' were too few to judge. Concrete's heavy damage is illustrative.
- **Counts by distance band** come within about 20% of the runs' where damage is well
  established. At the edge of the damage they are low just inside it and up to three times high
  just outside it
  ([the first look](surrogate-first-look.md#walls-and-roofs-20-october-2026)).
- **The roofs' factor is a calibration, not physics.** It is rejudged whenever the load terms are
  refitted (the judge is scripted:
  `$BOMBCAD_DATA/surrogate-walls/calibrate/judge19.sh`).

## Using it

- **In the app**: Simulation ▸ Quick Estimate of Envelope Damage now also draws the glass chances.
  In the damage section "Colour by" shows each building side by its chance that glass breaks,
  that it is blown out, that glass is thrown past 3 m (GSA 3b), or that its openings are blown out
  (fitted to Beirut), in eighths from light yellow to dark purple (viridis), the roof by its
  worst side; each building's row lists its sides' chances. "Yield known to within" sets the
  yield's spread for the next estimate.
- **Headless**: `BombCAD run project --surrogate first-look.json [--surrogate-yields samples.csv |
  --surrogate-yield-within 1.5]` adds `glass`, each side's chances, and what they were drawn over,
  and `walls`, each building's walls' and roof's chances.
- **Bench**: `scenebench glass-calibrate`; the runs' judgements and the posterior are on StudioData
  under `bombcad/uncertainty`. `scenebench wall-calibrate` for the walls and roofs, its ensemble
  under `bombcad/surrogate-walls`.
- **In the app, walls and roofs**: "Colour by" also offers the chance of walls damaged (moderate
  or worse), of walls heavy or worse (illustrative for concrete), and of the roof damaged, each
  building in one colour; each building's row lists them.

## Limitations

- **The chances are a run's, not the event's**, as above: they carry the glass model's and the
  4 m runs' biases.
- **Map buildings' façades only**: sides whose construction has a glazing mix. Panes drawn as
  components (detailed envelopes) are not given chances.
- **The runs' loads were capped at 65.5 kPa** within about Z = 7 (16-bit floats when saved, fixed in
  983409a8, after them). Glass there breaks either way; the throw close in may be understated in
  the runs, and so in the check against them.
- **The strength spread (0.25) is assumed**, not fitted: no survey of a city's glass by building
  was found.
- **The surrogate's scatter is drawn per side**, wholly shared by its strips and independent
  between sides; neighbouring sides' errors are surely correlated, which would widen the band
  shares' ranges.

## Sources

- GEER, *Beirut port explosion* reconnaissance (GEER-070, 2021) and its façade dataset (DesignSafe
  PRJ-3030).
- ASTM E1300's glass flaw model as `GlassStrength` uses it ([building envelopes](building-envelopes.md)).
- The yield posterior: [charge inference](charge-inference.md).
- G. W. Brier, "Verification of forecasts expressed in terms of probability", *Monthly Weather
  Review* 78, 1950 (the score).
- E. K. Beauchamp and R. V. Matalucci, *Dynamics of Window Glass Fracture in Explosions*,
  SAND98-0598, Sandia, 1998 (OSTI 658184; obtained 21 October 2026). Not used for the chances:
  eleven of its twelve panes broke, most weakened on purpose, so it gives no threshold. Its
  filmed speeds are compared in [validation](validation.md#sandias-windows).

## Future work

- Fit the strength spread, or a strength by building age, to a survey with panes counted.
- Correlated scatter between neighbouring sides.
- Chances of failure for walls and roofs, once the surrogate's pulse escalates past moderate as
  a run's does, or from a few full runs drawn where the first look is least sure.
