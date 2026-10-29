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

### Judged against a clear-top reference (25 October 2026)

The three 4 m runs' 320 m top drained the façade loads beyond about 1.25 km, over the hills south
of the port, at every yield ([the hybrid far field](hybrid-far-field.md#the-full-runs-top-drains-its-far-loads-25-october-2026)).
The chances were judged again against Beirut's runs with their top clear: 8 m air refined once to
4 m under the ceiling, footprints on 4 m cells, a 640 m top
([the reference](hybrid-far-field.md#judged-again-against-a-clear-top-reference-25-october-2026)),
the surrogate predicting for 4 m cells (`glass-calibrate --dx 8 --place-dx 4 --surrogate-dx 4`),
100 draws, the adopted terms:

| | The 4 m runs (23 October) | The refined runs, 320 m top | The refined runs, 640 m top |
|---|---|---|---|
| Blown out, Brier / skill; worst tenth | 0.017 / 0.84; 0.06 | 0.022 / 0.84; 0.11 | 0.038 / 0.64; 0.16 under |
| Thrown past 3b, Brier / skill; worst tenth | 0.032 / 0.73; 0.09 | 0.044 / 0.67; 0.13 | 0.096 / −2.79; 0.45 under |
| Some broken, Brier / skill; worst tenth | 0.028 / 0.66 | 0.022 / 0.53; 0.12 | 0.053 / −5.35; 0.44 under |
| The test (each tenth within 0.1) | all three pass | all three fail narrowly | all three fail |
| Openings blown out against the runs, skill | 0.86 | 0.88 | 0.87 |
| Openings blown out against GEER's W3, Brier / skill | 0.138 / 0.19 | 0.139 / 0.18 | 0.139 / 0.18 |

- **With the top clear the chances read low, the unsafe side.** Where they give a side 0.4–0.5 of
  being blown out, 0.58 of the runs blew it out; where they give 0.45 of a pane thrown past 3b,
  0.82 had one. Nearly every side has some glass broken in all three runs with the top clear, so
  that state's skill is set against a share near one: its Brier of 0.053 is the chances' shortfall
  in the far bands.
- **The refined air's own layout** (strips on 8 m cells, footprints on 4 m) costs the test
  narrowly under the 320 m top; the rest is the top.
- **The openings and GEER do not move**: they use the surrogate's loads alone. The fragility was
  fitted on the 0.5 kt 4 m run's peaks, drained beyond 1.25 km, and has not been refitted.
- **The full-length peak refit** (23 October, not adopted) does better against the clear-top runs
  in every state (Brier 0.030, 0.077 and 0.036), though it fails the test too
  ([judged again](hybrid-far-field.md#judged-again-against-a-clear-top-reference-25-october-2026)).

The glass chances' standing says this since 25 October 2026. Calibrating them again needs the
far terms, or the chances' load scatter, refitted on clear-top runs: a refit, and the user's
decision.

**Refitted on clear-top runs (25 October 2026, adopted the same day).** The surrogate's terms, its rise
share and the chances' load scatter were refitted on its fit runs remade with their tops clear
(emmettl/bombcad-work#98;
[the surrogate](surrogate-first-look.md#refitted-on-clear-top-runs-25-october-2026)). Against the
same clear-top runs:
- blown out passes the test, each tenth within 0.1 (Brier 0.027, skill 0.74, against 0.038 and
  0.64);
- thrown past 3b scores Brier 0.047 against 0.096, and some broken 0.028 against 0.053, both
  still failing, their middle tenths 0.2–0.35 under;
- the openings against GEER do not move (skill 0.17).

The user adopted it on 25 October 2026 (emmettl/bombcad-work#99): the chances draw these terms and
this scatter by default, and the standing quotes them. The terms of 23 October stay by name
(`--terms fitted`; in the app, "Façade terms of 23 October"). On the 4 m layout against GEER, drawn
over the inferred yield, the openings' skill is 0.18 (0.19 on the terms of 23 October), and the glass
blown out at 0.75–1 km 0.96 (0.93); the openings' fragility was not refitted.

### Why some broken and thrown past 3b read low: the pulse's front and the far loads (25 October 2026)

emmettl/bombcad-work#103. On the clear-top terms, blown out passes the test against Beirut's
clear-top runs, but some broken (Brier 0.028) and thrown past 3b (0.047) read 0.2–0.35 low in the
middle tenths. The loads match the reference's by band on the median, so #98 put it down to the
pulse's shape or the spread of load within a side.

**Diagnosed** with `blastmodel glass-diagnose` (Sources/BlastModel/Studies/GlassDiagnosis.swift)
on the same three runs and sides as `glass-calibrate`. Each side's three states were worked out
from its strips' loads taken apart one step at a time, and set beside the chances by tenth. Shares
of runs in the tenths where the gaps are:

| Tenth of chance (sides) | Chance | The run's histories | Positive part; first positive phase | Triangle of each strip's own peak, first impulse and rise | One load for the side | The surrogate's strips moved to the run's side mean | The surrogate's own loads |
|---|---|---|---|---|---|---|---|
| Some broken, 0.4–0.5 (1,181) | 0.46 | 0.77 | 0.77; 0.77 | 0.65 | 0.64 | 0.65 | 0.47 |
| Some broken, 0.5–0.6 (2,125) | 0.56 | 0.83 | 0.83; 0.83 | 0.69 | 0.69 | 0.70 | 0.58 |
| Thrown past 3b, 0.3–0.4 (2,089) | 0.35 | 0.67 | 0.67; 0.67 | 0.48 | 0.43 | 0.49 | 0.40 |
| Thrown past 3b, 0.4–0.5 (2,835) | 0.45 | 0.73 | 0.73; 0.73 | 0.55 | 0.48 | 0.55 | 0.46 |
| Blown out, 0.0–0.1 (8,213) | 0.03 | 0.12 | 0.12; 0.12 | 0.05 | 0.05 | 0.06 | 0.00 |

Read across, the shortfall comes in two parts of about the same size:

- **The pulse's shape: 0.12–0.14 of some broken, 0.18 of the throw.** The surrogate's triangle,
  given each strip's own peak, first impulse and rise, breaks less glass than the strip's own
  history.
  - It is not the negative phase or later shocks: the positive part and the first positive phase
    alone give the history's shares to the digit.
  - Nor is it the rise share: the surrogate's rise in place of the run's moves it by 0.01.
  - The 60 s stress of one pane (4 mm, 0.9 × 1.4 m) under the history, over the triangle's, is
    1.02 within Z 10, 1.04 at Z 10–14, 1.09 at 14–20, 1.14 at 20–28, 1.22 at 28–40 and 1.32
    beyond. It is the same at 0.2, 0.5 and 1.1 kt, and on the fit runs at 2 m (1.06–1.09,
    1.12–1.18, 1.18–1.29, 1.30). With E1300's seventh power, 1.14 in stress is 2.5 times the
    chance of a pane breaking.
  - It is not fast content (the history averaged over 10 ms or 30 ms gives 1.14 and 1.17 at
    Z 20–28) or Brown's integral on the pressure alone (1.04–1.06 at every distance).
  - It is the pulse's front. The run's façade load arrives as a shock, a share of its peak, and
    builds to the peak over about a third of the pulse as the air round the building fills. A pane,
    whose period is far shorter than the load, is struck by that front as by a step, and
    overshoots. The triangle rising from nothing has no step. The same triangle rising at once
    (all front) overshoots far more, 1.5–2 times the history's stress beyond Z 14.
- **The spread within a side: nothing.** One load for the whole side loses 0.07 of the throw, but
  the surrogate's own strips, moved to the run's side mean, give the triangle's shares to 0.01: the
  surrogate's features already carry the spread within a side. About the side's mean, the run's
  strips spread by 0.07–0.13 in the log of the peak beyond Z 7, and over the surrogate's by
  0.06–0.12.
- **The far loads: 0.18 of some broken, 0.09 of the throw.** The middle tenths are the far sides,
  2.2–2.7 km from the charge, and there the surrogate's side peaks are 0.69–0.78 of the run's
  (the log of run over surrogate +0.25 to +0.37 at all three yields). By distance over every side,
  the surrogate reads 6–12% high at 1–2 km and 14–21% low at 2.25–2.75 km, alike at every yield in
  metres, not in scaled distance. It is worst on sides facing away and behind more than 30
  buildings, and least near the box's edges, so it is not the reference's corners. The fit runs
  reach 1.56 km at most, so this is the far terms carried past the city depths they were fitted
  on.

**The option: a front on the glass's pulses** (`FacadeLoadSurrogate.Coefficients.GlassFront`,
in the term set `TermSet.clearTopFront`). The glass chances' pulses arrive with a share of their
peak at once, and rise from there to the peak over the same rise share, their impulse kept. The
share is fitted on the surrogate's own fit runs (#98's clear-top runs: the made-up districts at 20,
100 and 500 t, sparse at 20 t, and Beirut's five near boxes; 2 m air), none of them the judge's.
In each band of scaled distance it is the share at which a triangle of each strip's own peak,
impulse and rise gives its mix's panes the 60 s stress their own history gives them, each run
alike. It is none within Z 8.4, then 0.05 at Z 11.8, 0.10 at 16.7, 0.19 at 23.7, 0.28 at 33.5 and
0.54 at 49.0 (one run beyond Z 40), even in the log of Z between those points. Matching the panes'
mean seventh power instead gives the same shares within 0.02.
- **Only for large charges.** The fit runs' charges are 20 t to 1.3 kt, whose loads last
  0.1–0.5 s, long against a pane's period. A 100 kg charge's loads are short against it, and there
  a front breaks less glass, not more. So the front is whole from 20 t and tapers, evenly in the log
  of the charge, to none at 2 t. Below 20 t it is not fitted; the taper only keeps it without a
  step while a charge is inferred.
- **What takes it**: the glass chances (Quick Estimate's, the far field's and the drag preview's),
  the glass judged by `surrogate-judge` and `hybrid-judge`, and charge inference's glass.
- **What does not**: the walls' and roofs' chances (`forStructures` drops it), the first look's
  loads and its deterministic damage. No load moves.
- **Selected by**: `--terms clear-top-front` in the benches, `--surrogate-terms clear-top-front`
  headless, and Envelope Damage ▸ "Glass pulses with a front (candidate)" in the app.
- **Off by default.** With it off, every output is as before, bit for bit.

**Judged** on Beirut's clear-top references (the surrogate predicting for 4 m cells), as #98's
judges (`$BOMBCAD_DATA/scratch/issue103`: `diag.sh`, `judges.sh`, `near.sh`, `infer.sh`;
`py/fitfront.py`, `py/deciles.py`, `py/hybsum.py`):

| | Clear-top (default) | With the front |
|---|---|---|
| Chances against the runs, some broken: Brier / skill; worst tenth | 0.028 / −2.34; 0.35 under | **0.006 / 0.27**; 0.16 under (fail) |
| … thrown past 3b | 0.047 / −0.85; 0.35 under | **0.017 / 0.32**; 0.23 under (fail) |
| … blown out | 0.027 / 0.74; pass | 0.026 / 0.75; pass, worst 0.07 over |
| The same, with each strip's own peak and impulse in the fronted pulse: some broken; blown out; thrown | 0.009; 0.023; 0.034 (all fail) | 0.001, pass; 0.015, pass; 0.013, fail (0.19 under) |
| First look's glass by side, exact, 0.2 / 0.5 / 1.1 kt | 0.67 / 0.87 / 0.81 | 0.83 / 0.89 / 0.83 |
| … some broken at 1.75–2 / 2–2.5 / 2.5–3 km, 0.2 kt (run 0.91 / 0.75 / 0.51) | 0.66 / 0.28 / 0.09 | 0.90 / 0.63 / 0.43 |
| … blown out at 1.25–1.5 / 1.5–1.75 / 1.75–2 km, 0.5 kt (run 0.83 / 0.24 / 0.06) | 0.76 / 0.25 / 0.05 | 0.93 / 0.43 / 0.18 |
| … blown out at 1.75–2 / 2–2.5 km, 1.1 kt (run 0.78 / 0.57) | 0.81 / 0.24 | 0.98 / 0.57 |
| Hybrid, held (the app's): mean error some broken / blown out, 0.2 kt | 0.224 / 0.024 | **0.101 / 0.004** |
| … 0.5 kt | 0.094 / 0.081 | **0.035 / 0.040** |
| … 1.1 kt | 0.004 / 0.115 | **0.000 / 0.059** |
| … some broken at 1.5–1.75 / 1.75–2 / 2–2.5 km, 0.2 kt (run 0.98 / 0.90 / 0.75) | 0.72 / 0.46 / 0.15 | 0.90 / 0.75 / 0.43 |
| Hybrid, the match carried flat: mean error some broken / blown out, 0.2 / 0.5 / 1.1 kt | 0.166 / 0.015; 0.062 / 0.040; 0.001 / 0.089 | 0.034 / 0.016; 0.012 / 0.030; 0.000 / 0.054 |
| Near boxes (2 m, 440 m top), chances: blown out Brier / skill; test | 0.039 / 0.64; fail | **0.035 / 0.68; pass** |
| … some broken | 0.0004 / −0.80; fail | **0.0001 / 0.76; pass** |
| … first look's glass by side, exact / Heidke | 0.947 / 0.78 | 0.947 / 0.78 |
| GEER: openings blown out against W3, skill | 0.17 | 0.17 |
| … the glass blown out at 1.25–1.5 / 1.5–1.75 / 1.75–2 / 2–2.5 km (GEER W3 0.17 / 0.09 / 0.02 / 0.16) | 0.67 / 0.45 / 0.32 / 0.25 | 0.74 / 0.57 / 0.47 / 0.37 |
| Charge inference, glass alone (GEER on the scene's sides): place free | 0.055 kt, 466 m off | 0.023 kt, 218 m off |
| … place held | 0.030 kt | 0.018 kt |
| Concrete walls' chances, #56's near peaks, the first look's loads | — | the same, bit for bit (no load moves; the walls take no front) |

What it shows:
- **The pulse's part is fixed.** With each strip's own loads, the fronted pulse gives the runs'
  shares of some broken (Brier 0.001, every tenth within 0.04) and blown out (each within 0.06).
  The throw keeps 0.19 of its shortfall: the front gives the right break, but a broken pane's
  throw under a front no longer follows the history's (on the fit runs the triangle throws a broken
  pane more often beyond Z 28 and less at Z 10–20). No one front gives both.
- **The far loads' part is not.** The chances' some broken and thrown still fail the test, their
  middle tenths 0.10–0.23 under. Those tenths are the sides at 2.2–2.7 km, where the surrogate's
  side peaks are 0.69–0.78 of the run's.
- **The hybrid at 0.2 kt** comes from 0.72 / 0.46 / 0.15 to 0.90 / 0.75 / 0.43 at 1.5–2.5 km
  (reference 0.98 / 0.90 / 0.75). The error in some broken halves or better at every yield, held
  or flat; in blown out it halves held, and flat moves by 0.001 at 0.2 kt and falls at the others.
- **The near boxes' chances pass** for the first time, blown out and some broken.
- **The first look's glass blown out over-reads** by up to 0.19 in its transition band: 0.43
  against 0.24 at 1.5–1.75 km at 0.5 kt, 0.98 against 0.78 at 1.75–2 km at 1.1 kt. The surrogate
  reads 6–12% high at 1–2 km, which the triangle's missing front had offset there. The chances'
  blown out passes all the same, its tenths up to 0.07 over.
- **Further from GEER, and charge inference from glass alone reads lower.** More glass breaks per
  kt: the yield from glass alone falls from 0.055 to 0.023 kt with the place free, and from 0.030 to
  0.018 held. That is 22–28 times under the published 0.50–0.64 kt, where it was 9–17 times. The
  place comes nearer the reference (218 m off, from 466 m). GEER's classes are openings seen two
  months on ([above](#why-it-over-breaks-against-geer-19-october-2026)), and the glass model
  already broke more than they counted. A front that brings the glass nearer the runs takes it
  further from that survey. The openings' fragility, fitted to the survey on the peak alone, does
  not move.

**Proposal (the user's decision).** Not to adopt the front as the default yet. It fixes the
pulse's part of the shortfall, and with it the hybrid's far glass and the near boxes' chances, but:
- the chances' some broken and thrown still fail the test, on the far loads;
- the first look's blown out over-reads in its transition band by up to 0.19;
- charge inference from glass alone reads 22–28 times low, against 9–17.

The next step is the far terms past 2 km of city: fit runs that reach 2–3 km across a city. The
front would then be judged again with them. Alternatively the front could be adopted for the
hybrid far field's glass alone, where it halves the error at every yield, if a split default is
wanted.

**With far terms past 2 km of city (25 October 2026).** emmettl/bombcad-work#104 made fit runs
that reach 3 km across two made-up dense districts. It fitted far terms on them (the depth beyond
30 buildings, and faces turned away beyond 1.75 km) and refitted the front alongside, as the
candidates `TermSet.deepCity` and `deepCityFront`
([the surrogate](surrogate-first-look.md#far-terms-past-2-km-of-city-25-october-2026)). Against
the same clear-top runs:
- with the far terms and the front, some broken passes the test for the first time (Brier 0.004,
  skill 0.51, every tenth within 0.08), and blown out passes (0.026);
- thrown past 3b still fails, 0.13 under in its middle tenths (Brier 0.014);
- with the far terms alone, some broken scores 0.019 and thrown 0.038, both failing;
- the first look's blown out with the front still over-reads in its transition band (0.44 against
  0.24 at 1.5–1.75 km at 0.5 kt), where the surrogate reads Beirut high inside the fitted depth;
- glass alone infers 0.026 kt.

**Adopted: the far terms, the front still off (25 October 2026).** The user adopted
`TermSet.deepCity` as the default that evening, and kept the front an option ("Adopt deepCity,
front off", emmettl/bombcad-work#105;
[the surrogate](surrogate-first-look.md#adopted-the-deep-city-terms-25-october-2026)). The glass
chances now take the far terms with the clear-top scatter. Against the clear-top runs, blown out
scores Brier 0.025 against 0.104 giving every side the mean (skill 0.76), each tenth within 0.08
of the share seen, and passes. Some broken (0.019) and thrown past 3b (0.038) still read low and
fail. "Glass pulses with a front" in the app, or `deep-city-front`, gives the fronted set; the
clear-top terms stay by name (`clear-top`, `clear-top-front`).

**On lines balanced by angle to the cells (26 October 2026).** The runs' own glass depends on
the line's angle to the solver's cells (emmettl/bombcad-work#106). So emmettl/bombcad-work#107
judged the chances again on the diagonal lines alone, which the grid takes least off, and
balanced by angle (`glass-calibrate --by-angle`;
[the surrogate](surrogate-first-look.md#glass-judged-on-lines-balanced-by-angle-to-the-cells-26-october-2026)).
- On the diagonals the default's blown out fails the test (Brier 0.026, a tenth 0.12 under), as
  do some broken (0.029) and thrown past 3b (0.052).
- With the front, some broken (0.006) and blown out (0.020, every tenth within 0.02) pass there.
  Thrown past 3b still fails, 0.13 under.
- The proposal there was to adopt the front for the glass, and the standing quoted the diagonal
  figure beside the adopted one.
- **Corrected on 28 October 2026.** With Beirut turned 45° to the cells (emmettl/bombcad-work#108)
  the runs' glass went with the façades, not the line's angle, and on the turned diagonals the
  front read 0.34 over the run. The diagonals were where the surrogate's facing, read off the
  cells' staircase, reads fronts as oblique, not the lines the grid takes least off. The front was
  not adopted and the diagonal figure is retired from the standing
  ([incidence from outlines](surrogate-first-look.md#façade-incidence-from-map-outlines-28-october-2026)).

**Adopted: facing as the outlines, the front still off (28 October 2026).** The user adopted
`TermSet.deepCityOutline` as the default that day: the deep-city terms refitted with each wall
facing as its building's map outline, with their scatter (`Uncertainty.outlineLeaveOneOut`, within
0.01 of the clear-top scatter beyond Z 7; emmettl/bombcad-work#109;
[the surrogate](surrogate-first-look.md#adopted-facing-as-the-outlines-28-october-2026)). The
front is not adopted: in the box turned 45° it read blown out 0.10–0.15 over. Against the
clear-top runs, as Beirut lies, every test keeps its verdict:
- blown out scores Brier 0.025 against 0.104 (skill 0.76), each tenth within 0.07 of the share
  seen, and passes, as on the deep-city terms (0.025, within 0.08);
- some broken (0.020, the worst tenth 0.26 under) and thrown past 3b (0.039, 0.28 under) still
  read low and fail, against 0.019 and 0.038 facing as the cells;
- GEER's openings score Brier 0.142 against 0.141 (climatology 0.170);
- glass alone infers 0.056 kt with the place free and 0.030 kt held, against 0.055 and 0.030 (the
  inference itself stays on the terms of 23 October).

In the box turned 45° the glass comes nearer both runs: blown out by side, by class and band at
1–2 km, the mean error 0.036 on the plain run and 0.041 on the turned one, against 0.042 and 0.064
facing as the cells. A district laid out before 28 October has no outlines, so its walls face as
the cells' faces under the new terms. "Glass pulses with a front" in the app, or
`deep-city-outline-front`, gives the fronted set; the deep-city terms stay by name (`deep-city`,
`deep-city-front`, Envelope Damage ▸ "Façades facing as the cells (earlier estimates)").

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
load's scatter, not the strength's. Since 23 October the references run until the blast passes
their judged corners, not to 3 s. The table held: to the digit for concrete and roofs, and
stone's 0.724 became 0.719
([learned models](learned-models.md#the-near-boxes-run-to-their-corners-23-october-2026)).

| Chance (2,053 buildings × 10 yields) | Settings | Brier skill | Tenths, each within 0.1 of the runs |
|---|---|---|---|
| Concrete walls, moderate or worse | peak ×1.15, impulse ×0.95, the whole scatter (the refit's pair in 9 folds of 10) | 0.60 | pass, narrowly: 0.8–0.9 says 0.84, 0.94 seen |
| The same with field model 1's ground-floor peaks | peak ×1.15, impulse ×0.95, the whole scatter | 0.65 | pass |
| The same with field model 2's peaks at every storey, its own scatter | as field model 1's | 0.65 | pass |
| Concrete walls, heavy or worse (illustrative) | as the first | 0.54 | 0.1–0.5 high by 0.09–0.17 |
| Stone walls, heavy or worse (each building as 0.5 m stone) | loads ×0.85, the whole scatter (since 29 October 2026; the refit's pick in all 10 folds) | 0.75 | pass: every tenth within 0.06 ([adopted](#adopted-stone-085-with-the-whole-scatter-29-october-2026)) |
| Roofs, moderate or worse | loads ×1.3, scatter ×½ | 0.74 | 0.4–0.9 low by 0.11–0.18 |

The table is on the façade terms refitted on clear-top runs and their scatter, adopted on 25
October 2026 (emmettl/bombcad-work#99). On the terms of 23 October concrete at ×1.15 scored 0.61
and passed, the field models 0.654 and 0.656, heavy or worse 0.53 and stone 0.72. On the new terms the walls'
peak keeps ×1.15. Their impulse took ×0.95 on the user's decision of 25 October 2026
(emmettl/bombcad-work#102), as the field models' walls take it. With the impulse at ×1.15 too, one
tenth missed by 0.01 (0.84 against 0.95 seen; skill 0.599, heavy or worse 0.51). Held out, the
refit picks peak ×1.15 with the impulse ×0.95 in nine folds of ten and ×1.3 at 1.5 kt, passing at
skill 0.58. The field models' factors were kept
([learned models](learned-models.md#on-the-clear-top-terms-25-october-2026);
[the walls' impulse](surrogate-first-look.md#the-walls-impulse-095-25-october-2026)).

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

- **Concrete walls' damage is calibrated, narrowly.** Each tenth holding 50 buildings or more is
  within 0.1 of the share of runs, so it passes the protective-design report's test, but the
  0.8–0.9 tenth is at its edge (0.84 against 0.94), on the unsafe side. With the impulse at ×1.15,
  as until 25 October 2026, it was 0.11 under and missed. With a field model it passes too.
- **Roofs' chances are skilful but low in the middle.** That is the unsafe side, even with a load
  factor fitted on these runs (their own terms read low).
- **Stone's chances are calibrated** since 29 October 2026: at ×0.85 with the whole scatter each
  tenth is within 0.06 of the runs. At ×1.0 with ½, as until then, they read high by up to 0.31 on
  the outline's terms, the safe side (0.27 on the clear-top terms, 0.19 on the terms of 23
  October). For masonry, moderate and heavy are one level.
- **No chance of failure is given.** Before the close-in branch the roofs' read far too high
  (skill −0.48), and the walls' were too few to judge. Concrete's heavy damage is illustrative.
- **Counts by distance band** come within about 20% of the runs' where damage is well
  established. At the edge of the damage they are low just inside it and up to three times high
  just outside it
  ([the first look](surrogate-first-look.md#walls-and-roofs-20-october-2026)).
- **The roofs' factor is a calibration, not physics.** It is rejudged whenever the load terms are
  refitted (the judge is scripted:
  `$BOMBCAD_DATA/surrogate-walls/calibrate/judge19.sh`).

### Stone's ×0.8 re-judged, not adopted (28 October 2026)

The user's word of 28 October was to adopt stone's ×0.8, the refit's pick held out on the
clear-top terms (emmettl/bombcad-work#99), if on today's terms it still read safe and its tenths
test was no worse (emmettl/bombcad-work#111). It does not read safe, so it was not adopted: stone
keeps ×1.0 with ½ of the scatter.

**The judge** is #99's: `wall-calibrate --walls stone`, each building as 0.5 m stone against
Beirut's ten 2 m near boxes at 0.15–1.5 kt, 50 draws, the grid peak ×0.8–1.5, scatter ×½ or ×1,
impulse over peak 0.826 or 1, each yield held out in turn, on the CPU (about 30 minutes, 10 GB;
`$BOMBCAD_DATA/scratch/issue111`, `judges.sh`, `judges-mid.sh`). Run on `--terms clear-top` it
gives #99's figures to the digit (0.688 at ×1.0, 0.727 held out). On the default
(deep-city-outline), heavy or worse over 20,530 building-yields:

| Stone walls | Brier / skill | Tenths of 50+, chance minus runs' share | Tenths missed |
|---|---|---|---|
| ×1.0, scatter ×½ (kept) | 0.0680 / 0.687 | +0.03 to +0.31 in 0.1–0.9, high (safe) | 6 (0.3–0.9) |
| ×0.8, scatter ×½ (the factor alone) | 0.0784 / 0.640 | −0.07 to −0.40, low (unsafe) | 7 |
| ×0.8, the whole scatter | 0.0576 / 0.735 | −0.15 to 0.00, low | 3 (0.4–0.7) |
| ×0.8, the whole scatter, impulse ×0.66 (the refit's pick, every fold) | 0.0573 / 0.736 | −0.14 to 0.00, low | 4 (0.4–0.8) |
| ×0.85, the whole scatter | 0.0553 / **0.746** | −0.02 to +0.06 | **none: passes** |
| ×0.9, the whole scatter | 0.0593 / 0.727 | +0.01 to +0.17, high | 5 |
| ×0.9, scatter ×½ | 0.0585 / 0.731 | −0.13 to +0.07 | 2 (0.1–0.3, low) |
| ×1.0, the whole scatter | 0.0831 / 0.618 | +0.01 to +0.37, high | 8 |

- **×0.8 reads low in every form**, by up to 0.14–0.15 in the middle tenths with the whole scatter,
  where today's ×1.0 reads high by up to 0.31. It was so on the clear-top terms too (0.13–0.15 low
  held out): the "safe" of #99 was ×1.0's side, not ×0.8's.
- **×0.85 with the whole scatter passes** the tenths test, every tenth within 0.06 of the runs,
  at skill 0.746 against 0.687, and the refit on a grid with it (×0.85, ×0.9, ×1.0, ×1.3; scatter
  ×½ or ×1) picks it in all ten folds. It was not adopted: it is not the factor the user decided
  on, so it is proposed for their decision.
- Roofs do not move (0.740), and nothing for concrete walls is touched.

#### Adopted: stone ×0.85 with the whole scatter (29 October 2026)

The user adopted the proposal on 29 October (emmettl/bombcad-work#111). In
`FacadeLoadSurrogate.structureCalibration` walls of unreinforced masonry now take peak ×0.85 and
impulse ×0.85 with the whole load scatter, where they took ×1.0 with ½. Its figures are the
table's above: skill 0.746 against 0.687 (Brier 0.0553 against 0.0680), every tenth of 50
buildings or more within 0.06 of the runs where ×1.0 missed six by up to 0.31, and the refit's
pick in all ten folds. The walls' and roofs' standing now says stone passes the tenths test too
(`structureChancesStone`).

What moves is only stone's chances: each building with masonry walls in the quick estimate, its
drag preview and the headless `walls`. Concrete walls, roofs, glass and the estimate's own levels
(which take no factor) do not move; Beirut's map gives its buildings as concrete, so its quick
look does not move either. The earlier setting is not kept by name: it is one factor that only the
chances read, as the concrete walls' impulse of 25 October was not.

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
