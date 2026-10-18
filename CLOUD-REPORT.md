# Cloud report: docs against code audit

Branch `cloud/docs-audit`, from `main` at `40665a0`, 18 October 2026.

The numbers, units, symbol names and citations in 22 model documents were checked against
the constants and defaults in `Sources/` by reading. Nothing was built or run: the cloud box is
Linux without Metal, so no Swift or Metal change is claimed to build. No Swift or Metal file was
changed. `docs/validation.md`, `docs/reference-calculations.md` and `docs/blind-tests.md` were
left alone, and nothing under a `blind/` folder was opened.

## What was checked

- Air and fire: `air-blast-model`, `fireball-rise`, `thermal-radiation`, `surface-heating`,
  `deflagration`, `congestion-model`.
- Concrete and structure: `concrete-model`, `structural-model`, `concrete-strategy`,
  `new-materials`, `profiled-sheeting`.
- Shells and envelopes: `shell-model`, `building-envelopes`, `hazards`, `fragments`.
- Ground: `ground-shock`, `ground-shock-outrunning`, `cratering`, `terrain`, `beirut-2020`,
  `freestanding-objects` (`room-acoustics-model` is only a pointer to RoomCAD).
- The READMEs, against `Package.swift` and the ContinuumKit survey
  (`/mnt/project-files/continuumkit-survey/SURVEY.md`).

Several hundred model constants, defaults and derived figures agree with the code, units included.
Among them are the air's γ, the JWL set and TNT's energy, the concrete correlations and rate laws,
bond slip, the hazard and injury criteria, the crater coefficients and the ground-shock defaults.
No constant in the code was found to disagree with the source it cites. Several hundred backticked
symbols and paths resolve, apart from the one renamed below. `python3 Scripts/check-doc-links.py`
passes. No Python was touched, so no Python tests were run.

## Fixed on this branch

### ContinuumKit

- `Packages/SimulationKit/README.md` said both apps pin `0.1.0-alpha.1`. BombCAD pins
  `0.1.0-alpha.28` (`Package.swift:16-18`).
- The README's code layout still credited SimulationKit with `SceneModel` and `SceneView`. It also
  left out the `scenebench`, `RadialBlast` and `rigidboxdemo` targets.
- `new-materials.md` said `TimberFailure` was "merged, not yet released", but the same page says
  alpha.26 released it.

### Concrete and structure

- `concrete-model.md`, three places, described averages over 50 time steps:
  - the confinement factor K said it followed "a running average over 50 time steps";
  - limitation 8 froze the tensile rate factor from a 50-step average;
  - the future-work list asked for "a fixed time rather than 50 steps".

  Both averages now use the 100 µs strain-rate window: `rateFilter = 1 / (strainRateWindow ?? 50·Δt)`
  (`StructureSolver.swift:2038`), with the default window at `StructureTypes.swift:818`.
- `concrete-model.md`, limitation 6: compaction is "used unscaled" only for K ≥ 12 GPa. Softer
  materials are scaled by K / 12 GPa, as the doc's own Compaction section says.
- `concrete-model.md`, limitation 7, said there was "no bond slip" and that inclined bars could
  only be stored as components. `bondSlip`, `inclinedBars` and `discreteBars` exist as options
  (`StructureTypes.swift:707, 797, 803`). "Discrete bars" was dropped from future work.
- `concrete-model.md`, step 9, said `crushBand` "is kept". It is retired (`RetiredKey.crushBand`,
  `StructureTypes.swift:2006`).
- `concrete-model.md`: blockwork's joints show on elements of 112.5 mm or less (the Blockwork wall
  layout uses 75 mm), not on "the layouts' 62.5 mm".
- `concrete-model.md`: the cracking-moment factor is n/(n − 1), which gives 1.14 on 8 elements.
  The doc wrote 1 + 1/n, which gives 1.125.
- `structural-model.md`: a contact cell keeps eight nodes, not four (`StructureSolver.swift:566`).
  The layouts' element sizes are 50, 62.5, 75 and 125 mm, and 0.25 and 0.5 m for shells
  (`Presets.swift`).
- `concrete-strategy.md`: the E-FEM paper is by Simo, Oliver and Armero (1993), in that order.

### Shells, envelopes and fragments

- `shell-model.md`: Jones's mild-steel law gives 1.03 at 10⁻³ /s, as the text above the table says.
  The table said 1.04. The 400 MPa row at 0.3 /s rounds to 1.25, not 1.24. The test comment
  `Tests/BlastCoreTests/BucklingTests.swift:46` also says 1.04 and is left for the Studio.
- `shell-model.md`: bolted end plates loaded fast were 11–29% weaker (90/127 and 87/98), not 13–41%.
- `fragments.md`: Mott's 8 g mean gives 18,800 fragments of a 150 kg casing, not 18,400
  (M_K = 0.0937 lb^½, mean 7.96 g). Limitations still gave the old "a sixth to a half" short of
  DoD; the current figure is up to two-fifths.
- `building-envelopes.md`: the scene limit is 262,144 rigid blocks (`Scenario.maximumRigidBoxes`).
  The doc said "2,048 fragments in a scene".
- `building-envelopes.md`: the measured slab peak lies between the bounds on seven of the eight
  slabs; HSCV3 reads 0.97. The fixed bound reaches a sixth of the measured peak (HSCV4 and HSCV6
  read 0.16), not "a tenth or less".
- `building-envelopes.md`: 6.7% is the cracked laminate's deflection over its span; the 1.2%
  membrane strain is the yield strain (`LaminatedGlass.swift:180-185`). The doc called the 6.7%
  a strain.

### Ground

- `cratering.md` and `ground-shock-outrunning.md`: Prairie Flat was 500 short tons. The 67.7 m
  diameter follows from 453.6 t; 500 t would give 69.9 m (`Crater.swift:206-209`).
- `cratering.md`, Minor Scale: the dry rule's 18.5 m depth is ANFO's K (diameter 74 m). The ratio
  is 1.30, not 1.32. With TNT's K, which the doc chose for the diameter, the depth is 29.5 m and
  the measured 24 m is 0.81 of it.
- `ground-shock-outrunning.md`: the ground's share of a surface burst's energy is a third
  (`Crater.swift:164-166`), not 0.1. At 200 Hz in 2,000 m/s soil the wavelength is 10 m, which is
  a hundred 0.1 m cells, not ten.
- `ground-shock.md`: the window of 12 steps × 50 µs takes about 3% off the 10.9 ms pulse at 21 m,
  not 5%. The pulse is about 5–12 m long in the soil, not 7–14 m.

### Air, fire and deflagration

- `deflagration.md`: hydrogen's wrinkling grows as (R/R₀)^0.243 out to about a metre
  (`FlammableGas.instabilityGrowth`, `Deflagration.swift:155-158`). The doc gave the methane
  form, (R/R₀)^(1/3) to four onset radii. The limitation now says the same.
- `thermal-radiation.md`: gravity is an option (`--gravity`), as the next section says. Two places
  said "the air model has no gravity".
- `air-blast-model.md`: a doubled "Skipping still air" heading was removed.
  `Refinement.reseedImpulseBase` is `AirRefinement.reseedImpulseBase`.

## For the Studio: the code or a rerun decides

Most severe first.

1. **The car's balance angle** (`freestanding-objects.md:44, 56, 73`). The tables head a column
   "past the 35.3° balance angle". The code's balance angle is atan(t/2h) = atan(1.55 / 1.10) =
   **54.6°** (`RigidCarDefinition.swift:119`, `ExperimentalRigidCarStudy.swift:184`). Tilt is
   measured from the vertical (`tiltDegrees`). 35.3° is the complement, atan(2h/t). The column's
   times precede tilts of 46–47°, so they were probably taken against 35.3°. If so, the times and
   any "overturns" read off them need rerunning against 54.6°. Left unchanged for that reason.
   Confidence: high that 35.3° is wrong.
2. **Fragment penetration treats every wall that is not reinforced concrete as 8 MPa masonry**
   (`FragmentCloud.swift:246-253`). That includes reinforced blockwork, profiled sheeting and CLT.
   `fragments.md:356` names only concrete and masonry. Steel sheeting and timber penetrated as
   masonry looks wrong. Confidence: medium.
3. **AICC pressure: an absolute figure or a ratio?** `deflagration.md:104` gives methane's AICC as
   "8.9 bar … from 1.013 bar". The code treats 8.9 as a multiple of the initial pressure
   (`stoichiometricAICCRatio`, `Deflagration.swift:199-211`; `heatShare`, 454-459), so a closed
   vessel peaks at 9.02 bar, which the doc's own vessel table shows. If 8.9 bar is absolute, the
   code over-scales by 1.3%; if it is a ratio, the table's unit is wrong. The same applies to
   propane's 9.4, hydrogen's 8.01 and town gas's 8.44. Confidence: medium.
4. **Beirut's building count** (`beirut-2020.md:41`): 14,169 placed plus 342 left out is 14,511,
   not the 14,502 found. One of the three numbers is off. The 1 km ratio is also given as 0.84 at
   line 330 and 0.76 at line 122. Both need the run's output.
5. **Stale code comments, no value wrong:**
   - `Structure.metal:900-902` names Malvar–Ross and Malvar–Crawford, but the code is MC2010 and
     CEB.
   - `StructureSolver.swift:184` says "four node slots", but the code allocates eight.
   - `Structure.metal:1256` says "an eighth of the depth"; it is a sixteenth, 1/(2n).
   - `Shell.metal:155-156` says ε_x comes from the element, but `sectionStrain` takes it from the
     section's forces.
   - `SolverTypes.swift:129` says the mapped start takes one charge, but several are mapped
     (`MappedStart.swift:74` on).
   - `SolverTypes.swift:132-134` gives 99–117% of Kingery–Bulmash where the doc table gives 83–117%.
   - `HalfSpaceGroundShock.swift:198-203` says "a seventh", but the code multiplies by 1.15.
6. **Citations to check against the sources (not available here):**
   - `hazards.md` cites DDESB TP-21 (2017) for the 79 J per 55.7 m² criterion, but the code and
     `fragments.md` cite DoD 6055.09-M, FAA 437.53-1 and TP-12. The values agree.
   - `BlastInjury.swift:107-109` labels DoD 4145.26-M's table with 6055.09-M-style equation numbers.
   - `thermal-radiation.md` spells the author both "Pattmann" (three times) and "Pattman" (once).
   - `HalfSpaceGroundShock.swift:66` puts loose dry sand at n = 2.75. TM 5-855-1, as recalled, gives
     3–3.25. Only the comment is affected; the value used for dense sand is right.

## Left for a human to judge (small, or depends on run results)

- `air-blast-model.md:792` gives the incident impulse "within 4%"; lines 343 and 368 say 6% and
  94–100%.
- `air-blast-model.md:224` and `:823` read "off by default" or "by default γ = 1.4", though
  `SolverConfiguration.recommended` turns hot air and afterburning on.
- `deflagration.md`: the methane range "0.64–1.35 of its 55" works out to 0.67–1.35. The 15%
  hydrogen onset is given as 23 mm where the table interpolates to 22 mm. The Molkov bound is
  "a seventh" where the numbers give nearer a sixth. The source of the Lewis numbers 0.38–0.49 is
  not named.
- `concrete-model.md:320` (a retired option): the doc's own formulas give 0.096 at 0.2 mm, where it
  says 0.07.
- `concrete-strategy.md:99, 103` say seven retired flags; nine are listed.
- `beirut-2020.md:115`: 30 °C air is 2.6% faster in sound than 15 °C air; the doc says 2%.
- `terrain.md:367`: the staircase's mean errors recompute to 2.7, 2.1 and 1.5°, against 2.6, 2.0 and
  1.5° in the doc.
- `cratering.md:18`: 0.4 s for 100 kg holds only with D as the radius.
- `fragments.md:22-37`: the JSON example's casing mass, count and tracers are not the defaults
  (0); readers may take them for defaults.

The branch is ready for the Studio to review.
