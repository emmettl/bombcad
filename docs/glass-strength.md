# Glass strength: the evidence for a decision

**Decided 20 October 2026: today's E1300 strength stays the default, and new or tested glass is a
construction's option** ([below](#the-option-new-or-tested-glass)). Two lines of work pointed towards
stronger glass than today's:
- the [calibration](calibration.md) favoured glass 1.2–1.6 times as strong;
- the model breaks more glass at Beirut than GEER's survey saw ([glass by
  chance](glass-probability.md)).

This note reruns every judged glass comparison at today's strength and at 1.2, 1.4 and 1.6 times
it, and asks two questions of each factor:
- whether the safe side holds: does the model ever predict glass holding where tests broke it;
- what each factor does to protective-design plans and hazards.

(20 October 2026, emmettl/bombcad-work#49.)

**Recommendation: keep today's strength (×1) as the default.**
- At ×1 every comparison is on the safe side.
- From ×1.2 two cross to the unsafe side: Beirut beyond 2.5 km, and plans at the edge of the
  damage if the glass in place is weathered.
- From ×1.4 E1300's threshold crosses too.
- At ×1.6 Osnes's panes cross as well, and a plan misses on its own run.

The comparisons that favour stronger glass are of new glass. E1300's strength is meant for glass
weathered in service, which is what a scene's buildings hold. If new glass is wanted, it belongs
as an option of a construction (new or tested glazing, about ×1.6, Osnes's 1.55–1.85), not as the
default.

## How

`GlassStrength.studyStrengthFactor` multiplies every pane's strength by the environment's
`BOMBCAD_GLASS_STRENGTH`, for studies only. It is read once a process, and is 1 unless set.
- It divides E1300's flaw constant by the factor's seventh power, so it reaches every judge: the
  single panes, laminated and filmed glass, the glazing mixes, the façade surrogate, glass by
  chance and protective design.
- Two Python scripts keep their own constants and were not rerun: `Scripts/glass-trace/gtrace.py`
  and the protective prototype `Scripts/protective/model.py`.
- Outputs: StudioData `bombcad/glass-strength`.

## Per comparison

| Comparison | ×1 (today) | ×1.2 | ×1.4 | ×1.6 | Safe side |
|---|---|---|---|---|---|
| Monk and Clubley, 4 mm annealed, break time over measured (4 aspect ratios) | 0.82–1.07 | 0.86–1.13 | 0.91–1.20 | 0.95–1.26 | Every pane breaks at every factor. From ×1.4, two aspect ratios (1:1.7, 1:2) break later than every measured pane |
| ASTM E1300's load resistance (panes A, D, T, CC), model over E1300 | 0.57–0.65 | 0.73–0.85 | 0.89–1.10 | 1.02–1.40 | Below 1, the model breaks under less than the design load. **Pane CC crosses at ×1.4, all four at ×1.6** |
| Osnes's laminated panes, 15 shots, cracked or held as measured (the open benchmark's glazing case) | 7 of 15 | 7 of 15 | 11 of 15 | 14 of 15 | Up to ×1.4 every miss cracks a pane that held. **At ×1.6 the one miss is a pane that cracked (C-02) held** |
| Beirut 0.5 kt, sides with some glass broken (the run's saved loads), against GEER W1+ by band | ≥ GEER in every band to 3 km (2–2.5 km: 0.66 against 0.26) | **under at 2.5–3 km** (0.06 against 0.11) | under beyond 2.5 km | **under from 2 km** (0.17 against 0.26 at 2–2.5 km) | See below |
| Beirut, sides blown out, against GEER W3 | over to 1.5 km; under at 2–2.5 km at every factor | about equal at 1.25–1.5 km | **under from 1.25 km** (0.02 against 0.18) | under from 1 km | W3 is frames and openings, not glass ([#77](glass-probability.md)): read it loosely |
| The façade surrogate's glass against the run's, 0.5 kt | 0.72 exact, 1.00 within one | 0.70, 1.00 | 0.70, 1.00 | 0.71, 1.00 | Unaffected: both judge with the same glass |
| The openings state (fitted, skill 0.15 against GEER) | unchanged | | | | It holds no glass |

**Beirut.** The survey's classes are not pane breakage:
- W1+ counts damage still visible two months on;
- W3 counts frames and openings;
- strength alone would have to be ×2.1 to ×4.4 to match them ([glass by chance](glass-probability.md)).

So Beirut cannot set the strength. But it does say where a stronger default stops being safe: once
the model predicts fewer damaged sides than GEER found, by 2–3 km from ×1.2 on.

## What it does to plans and hazards

**Protective design** (`scenebench protect`, the sparse made-up district, target: no pane thrown
worse than 3b except with a chance under 10%; film, toughened, laminated and infill at the
documentation's costs):

| Threat | ×1 | ×1.2 | ×1.4 | ×1.6 |
|---|---|---|---|---|
| 20 t at its centre: cheapest plan's cost | 49,551 | 49,509 | 49,486 | 49,478 (−0.15%) |
| On the 20 t run's own loads, judged at the same strength | meets (worst 0%) | meets (3%) | meets (6%) | **misses: 5 sides over 10%, worst 16%** |
| 2 t at its centre: cheapest plan's cost | 31,938 | 23,980 (−25%) | 20,078 (−37%) | 17,300 (−46%) |
| That plan if the glass is today's: sides left over the target | 0 (worst 9%) | **32 (worst 36%)** | **57 (worst 45%)** | **78 (worst 84%)** |
| Sides expected to fail, of those left | 1.5 | 7.7 | 15.4 | 25.3 |

- **Close in nearly every side needs film** whatever the strength, so a stronger default saves
  little.
- **At the edge of the damage it saves a quarter to a half** of the cost by leaving sides
  untreated. If the glass in place is weathered, as E1300 assumes, those sides fail: up to 78 over
  the target at ×1.6.
- **A cheaper plan is cheaper only if the strength is true.** The plans' standing cannot show this,
  because the confirmation judges with the same strength.

**Hazards.**
- `blastbench hazards` (K-factor rings, minimum safe distance, injury radii) holds no glass, so
  the rings do not move.
- Glass enters the hazards through broken panes thrown. At Beirut the sides blown out at
  1–1.25 km fall from 0.96 at ×1 to 0.72, 0.35 and 0.10: a stronger default draws the thrown-glass
  hazard in by hundreds of metres.

## If the user wants stronger glass

- **Not as the default.** At ×1.2 the cost is small on the tests (E1300 0.73–0.85, Osnes
  unchanged, Monk 0.86–1.13). But Beirut's far bands go under the survey, and plans at the edge
  cost a quarter less while leaving 32 sides over target if the glass is weathered.
- **As a construction's option.** "New or tested glazing, ×1.6", for a building whose glass is
  known to be new: Osnes's panes were 1.55–1.85 times E1300's median. The default stays E1300's.
- **The data that would settle it** are panes held beside panes broken near the threshold, of
  known age (Beauchamp and Matalucci; Johns and Clubley). The calibration ranks them first
  ([calibration](calibration.md#the-answers), [data wanted](data-wanted.md#to-fetch)).

## The option: new or tested glass

The user's decision: keep E1300's strength as the default, and offer new or tested glazing as an
option (emmettl/bombcad-work#49).

**The factor, 1.55.** It is the least of Osnes et al.'s (2019) measured new glass, 1.55 to 1.85
times E1300's median.
- **Osnes's panes.** At 1.55 their fifteen panes crack or hold as measured in 14 of 15. The miss
  cracks a pane that held: the safe side. From 1.58 a pane that cracked (C-02) holds, so the
  factor stops short of it. "About 1.6" in the note above means this.
- **E1300.** At 1.55 E1300's own load resistance is exceeded (1.00–1.32 of it), as it should be
  for glass stronger than the standard's.
- **Monk and Clubley's panes** break at 0.94–1.24 of the measured times.

**What it is.** `GlassCondition`: `.asDesigned`, weathered, E1300's (the default, written as
nothing in a project); or `.newOrTested`, every pane's strength times 1.55.
- **Where it is set.** On an envelope's construction (`EnvelopeConstruction.glassCondition`, set
  with `setGlassCondition`), which gives its windows' mixes (`GlazingMix.condition`) the same. A
  mix with new glass is named for it, so that what is kept by a mix's name keeps the two apart.
- **Where it applies:**
  - envelope damage's panes (annealed, toughened, filmed and laminated alike);
  - the façade mixes' glass, and so the quick estimate's and the glass chances';
  - charge inference from the scene's glass;
  - protective design, both the scene as built and a plan's change.
- **In the app**, the construction editor's **Glass** picker: as designed, or new or tested.
- **In protective design**, re-glazing a side with new annealed glass in the same panes is a
  change of its own (`reglazed`), with the user's cost. The app offers it, not allowed until
  ticked.

**Its standing** (`ModelOption.newGlass`, an approximation): new or tested glass, from Osnes's
panes, 1.55–1.85 times E1300's. The note warns:
- from 1.58 one of Osnes's panes that cracked (C-02) holds;
- at 1.55 Beirut's sides with broken glass fall below GEER's beyond 2 to 2.5 km;
- glass weathers towards E1300's in service, so a plan that relies on new glass holds only while
  it is new.

**At the default nothing changes.** On this branch's build, the 2 t protective plans and Beirut's
façade-surrogate judgement came out byte for byte as before. The air solver is untouched.
