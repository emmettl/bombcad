# Cloud report: second docs audit and the 0.6.0 notes draft

Branch `claude/project-thread-krtmng` (the cloud session can push only to its assigned branch, so
not `cloud/docs-audit-2`), from main at `505eca7`, 19 October 2026. This box is Linux without
Metal: nothing in Swift or Metal was built or run. Every check below is by reading the code,
the records and the fragments, and by running the Python scripts named.

## Part A: what was corrected, and why

Each change rests on the code or a record cited beside it; no measured number was changed
without one.

| Page | Was | Now | Evidence |
|---|---|---|---|
| beirut-2020.md, "What cell size" | refined once and capped, façades' peaks "4–12% lower" | 2–12% lower | the page's own table: 24.5/27.8, 15.4/16.6, 10.4/11.2, 8.4/8.6 kPa (the last is 2% lower) |
| using-the-app.md, "A district from a map" | the same 4–12% | 2–12% | as above |
| release-notes/next/refined-districts.md | the same 4–12% | 2–12% | as above |
| charge-inference.md, Broken glass | each façade placed "at its segment's centre" | at the centre of its segment's bounding box | `Sources/SceneBench/InferCharge.swift` (`readShapeCentres`) takes the bounding box's midpoint |
| charge-inference.md, forward study | BombCAD's shock "up to a sixth sooner" than Kingery–Bulmash | up to a quarter sooner | the same sentence gives arrivals of 0.73 of the curves' at 4 m |
| roadmap.md, Horizons item 3 | "the first step is a ray-traced far field", not marked as landed | first step done, headless, and done without ray tracing: `scenebench district-hybrid` with the surrogate beyond the hand-over, so no channelling yet; not in the app | commit `67f2112`, `Sources/BlastCore/HybridFarField.swift`, hybrid-far-field.md |
| surrogate-first-look.md, the fitted terms | the length inside buildings read as unscaled; the last term "the cell's size over W^(1/3)" | the length is scaled like the others; the last term is the logarithm of the cell's size over W^(1/3) | `FacadeLoadSurrogate.terms` (FacadeLoadSurrogate.swift), `Scripts/fit-surrogate.py` |
| hybrid-far-field.md, Using it | silent on `hybrid-judge`'s trend | `hybrid-judge` fits the trend only with `--trend-from`, otherwise carries the match on flat | `Sources/SceneBench/HybridBench.swift` (no default in `hybrid-judge`; 0.5 × hand-over in `district-hybrid`) |
| using-the-app.md, From architectural plans | windows become "6 mm panes of annealed glass, unless the IFC names another glass" | annealed glass always, 6 mm unless the IFC gives the thickness | `IFCStructure.swift`: the glass is always `.annealedGlass`; only `paneThickness` comes from the IFC |
| terrain.md, Persistence | a terrain project "is scene encoding 8" | 8 or later (9 with a structural IFC import, 10 with an envelope's glass) | `Sources/BombCAD/ImportedSceneCodec.swift` |
| terrain.md, a structure on a sliver | base "within half a metre of the ground" | within the largest of half a metre, an element and an air cell, of the highest ground under the footprint | `structureStandsOnTerrain` in `HillsidePreset.swift` (`max(0.5, elementSize, cellSize)`), changed in `da2179e` |
| terrain.md, Cut cells | silent on New District | New District's refined air lays the ground as a staircase for now | `NewDistrictView.swift` (with `7b6261c`), using-the-app.md, 0.6.0.md |
| terrain.md, Limitations | "Refinement near the surface" | "…, on the staircase" | the patch gain and loss described apply only to the staircase (`Refine.metal`, cut-cell patches return before being kept) |
| air-blast-model.md, lead-in to the reflected-peak table | the reflected impulse "within 6%" beyond 1.5 m/kg^(1/3) on 0.25 m cells | 7–18% high on the table's own (mapped-start) runs; within 6% on the ideal gas and balloon start | `ValidationTables.mappedReflectedImpulse` in `ErrorBands.swift`; validation.md's mapped-start table |
| reference-calculations.md | the two Kingery–Bulmash fits agree "within 0.7%" in incident pressure | within 1.3%, just beyond Z 23.8 | `KingeryBulmash.swift` against `Scripts/reference/kingery_bulmash.py`, evaluated over Z 0.2–40 |
| reference-calculations.md | `validate --histories runs` | `mkdir -p runs` first | `blastbench/main.swift` writes with `try?` and never makes the folder |
| reference-calculations.md | `--self-test` checks "each reader" | two readers (validate's histories, groundmotion's JSON) | `Scripts/reference/compare.py` |
| reference-calculations.md | the street benchmark's control on "today's defaults" | on the bare `SolverConfiguration()` (ideal gas, balloon start, no afterburning, copying faces) | `SceneBench/StreetBenchmark.swift`, `SolverTypes.swift`; the ratios reproduce with `compare.py` |

docs/analytic-oracles.md needed nothing: Toro's star states, the Sedov constants, the scheme's
errors by grid and the Sedov yardstick all reproduce.

## Part A: what could not be verified, or what the pages claim beyond the code

- **No record outside the page.** None of the charge inference's, the surrogate's or the hybrid's
  results appear in validation.md, standing.md, `EvidentialStanding.swift` or
  `StandingFingerprint.swift`: yields, coverage, run times, band shares and match factors rest on
  the pages and fragments alone. The same holds for the plan house's study (126 kPa, 179 of 5,597
  elements, partitions 26–34 mm, pieces 2.6–2.9 m in; the test measures no throw distance, so the
  last cannot come from its report), the "gaps of up to 89 mm", and terrain.md's floor trace
  (44 floors, 3.6 kJ) from `b8e713c`.
- **Reflected-peak table, N = 37 at Z 4–6:** the page reads 102% and 101–102%; validation.md and
  `ValidationTables.mappedReflectedPeak` read 95, 97 and 97. The fragment's "full with 37" rests on
  the page's figure. A Mac run decides; left as it is.
- **The wall read's figures** (46–80%, 69–93%, 48–61%, 82–96%, the impulse overshoots and the N = 20
  column) are recorded only in commit `3f2bb8c`'s message. Tyndall test 1 with the wall read gives
  a free field of 9.8 kPa on the page and 12.3 kPa in validation.md; the runs may differ in
  refinement.
- **Standing of the wall read:** `EvidentialStanding.swift` classes `gaugesReadWallPressure` as
  `.numerical` (no effect on the standing), though it moves reflected peaks a great deal.
- **`Azimuth_N`** is read as radians clockwise from north (`ChargeInference.swift`). The GEER data
  are not in the repository, so whether that field is in degrees, which would misclassify facing
  and side-on glass under `--glass`, could not be checked.
- **charge-inference.md's forward-study rows** are listed as 0.5, 1, 2, 5 t; the code runs 500,
  2,000, 5,000, 1,000 kg. The reordering could not be checked.
- **beirut-2020.md, peak at 1 km:** "0.76 of Kingery–Bulmash at every yield" sits beside 13 against
  15 kPa at 1.1 kt (about 0.87) and 0.84 further down. It predates 18 October; which is right needs
  the run.
- **Full-run times:** hybrid-far-field.md gives Beirut's full 4 m runs as 1,604, 2,017 and 2,464 s
  (27–41 minutes, 34 at 0.5 kt); the surrogate page, its fragment and beirut-2020.md say 25–28
  minutes. Only the first fits.
- **Surrogate far field:** `FacadeLoadSurrogate.standing`, shown in the app and the JSON, says the
  loads beyond Z 20 run "up to ×1.6–2 high"; the page says 1.1–1.6 on the median, its table
  topping at 1.63.
- **Small mismatches:** "49 buildings" in the surrogate's fitting and "51 blocks" in the charge
  inference's forward study, where the fixture holds 49 grid blocks, a warehouse and a courtyard
  block; band shares 0.01 apart between the surrogate and hybrid pages.
- **Horizons item 1, "(started)":** no code for an error estimate driving refinement was found.
- **A code comment** in `FacadeLoadSurrogate.swift` cites `scenebench surrogate-fit`, which does not
  exist; the fit is `Scripts/fit-surrogate.py`. Not changed (code, not docs).
- **terrain.md, "on cut cells (refined once) none of this arises"** looks stale now that cut cells
  are conservative refined twice as well; left for whoever knows the current behaviour.
- **Pitched roofs** have not landed: the terraced houses' roof is still a flat roof at the eaves
  (shell-model.md, `TerracedHousesPreset.swift`), so the notes do not list them.

## Part B: the 0.6.0 notes

`python3 Scripts/release-notes.py check`: 20 fragments well formed (the request expected about
21). `assemble` was not run. The draft is
[docs/release-notes/0.6.0-draft-assembled.md](docs/release-notes/0.6.0-draft-assembled.md): what
assemble would make of 0.6.0.md and the fragments, edited for a reader, user-visible changes
first (material visuals, plans import, the quick estimate, the city in minutes, charge inference,
refined districts), each entry a sentence or two with its link, and limitations listed plainly.

### Fragment problems

1. **Duplicates of entries already in 0.6.0.md**, which assemble would print twice:
   - `refined-districts.md` repeats "New District offers refined air", and contradicts 0.6.0.md's
     "Beirut refined" ("refinement does not yet save a district's run", 3.2 times the run time),
     which the ceiling has since superseded (0.44 of the run time).
   - `freestanding-coupling-speed.md` (kind `changed`) repeats Fixed's "Freestanding objects in
     refined air" (the same remap, the L-corner box, the 5 mm and the summing order), with
     different timings (whole run against the first 0.1 s).
   - `footing-joint-settles.md` repeats Fixed's "A structure on footings never settled", and gives
     a different cause: the joint worked out from positions rounded to microns, where 0.6.0.md
     names only the settling test.
   - `office-fin-plates-3s.md` carries on 0.6.0.md's office bullet (334 fractured by 1 s, 428 by
     3 s); they read best merged.
2. **Promised for a 0.5.1 that does not exist.** 0.5.0.md lists four limitations "fixed in 0.5.1";
   there is no 0.5.1 tag or notes. `refined-venting-pane-lookup.md` and `shell-rule-per-material.md`
   are two of them. The hand-over timing fix landed in `2337523` with no fragment (the draft adds
   it under Fixed). No fix was found for "restarting a run with shells" (the draft carries it as
   a limitation). 0.5.0.md's line needs amending, or a 0.5.1 made.
3. **`solver-memory-in-loops.md`** fixes 0.5.0's known limitation of parameter sweeps, but does not
   say so, and 0.6.0.md still lists "the command-buffer leak in sweeps" under "To consider"; the
   fragment puts the cause in autorelease pools, not command buffers. It overlaps
   `cell-reads-without-autorelease.md` (both autorelease, both `SolverMemoryTests`); grouped in the
   draft.
4. **`surrogate-first-look.md`**: "against a run's 25–28" has no unit (minutes).
5. **`reflected-peaks-at-walls.md`** (kind `limitation`) also announces a new option (`--wall-read`);
   "full with 37" rests on the disputed N = 37 figure above, and the 19–43% overshoot is the 0.02 m
   cells' figure (13–31% on 0.05 m) without saying so.
6. **`hybrid-far-field.md`** is one unwrapped line, unlike the rest, and its "about another minute"
   for judging is the Studio's time beside the CI mini's run times.
7. **`nearby-connection-deadlines.md`** ends with a sentence about the tests' own hang, which is not
   for a user.
8. **The assemble script's layout.** It appends after 0.6.0.md's last section, which is "To consider
   before 0.6.0", so the fragments would land under it; and 0.6.0.md's own bold group headings
   ("Fixed", "Defaults changed") would sit beside assemble's "## Fixed" and "## Changed". Resolve
   the "To consider" section and fold 0.6.0.md's groups into the kinds before assembling.

## Tests run

`python3 Scripts/check-doc-links.py` passes. `python3 Scripts/release-notes.py check`: 20 well
formed. `Scripts/test-release-notes.py`, `Scripts/reference/test-kingery-bulmash.py`,
`test-sdof.py`, `test-blast1d.py`, `test-compare.py`, `Scripts/test-analytic-oracles.py` and both
`compare.py --self-test` runs pass. No Python was changed.
