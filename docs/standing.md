# Standing of results

Each result BombCAD produces carries its evidential standing: what it rests on, how close that
came, and what the scene's settings do to it. The [long-term vision](long-term-vision.md#credibility-as-a-product-feature)
asks that users can tell measured agreement from mathematical verification, an approximation and
an illustration, and that assumptions, resolution sensitivity and unsupported effects stay with
the scene and its exported results. This is the first step towards that. It summarises the
[validation record](validation.md) and the [roadmap's limitations](roadmap.md#limitations-most-important-first),
which remain the authority.

## The four levels

| Level | Meaning | Example |
|---|---|---|
| Measured agreement | Compared with measurements, and how close it came | Reflected impulse on a wall within 6% of Kingery–Bulmash on fine enough air |
| Verified against theory | The equations are solved correctly against exact or textbook solutions; no measurement | A steel structure: wave speed, deflection and period within 5% of theory |
| Approximation | A recognised approximation with stated assumptions; nothing says how close it comes here | Structural damage and failure; building surface exposure |
| Illustrative | Plausible-looking, or compared too loosely to rely on | Thermal radiation, the cloud, fragments, ground shock, simplified cars |

Results with a standing of their own: peak overpressure, impulse, structural deflection,
structural damage and failure, building surface exposure, freestanding objects' motion, thermal
radiation, the rise and cloud, fragments and ground shock. A scene has the ones it produces.

## Derived from the scene

The standing is worked out from the scene's actual settings each time they change
(`SceneStanding.init(_:)` in `EvidentialStanding.swift`), not stated once per model:

- **Resolution.** The air's finest cell near the shock, scaled by the cube root of the charge,
  is matched to the open-air comparison's grids (0.5, 0.25 and 0.125 m for 100 kg: 0.108, 0.054
  and 0.027 m/kg^(1/3)), and the agreement of that grid is quoted. Shock refinement counts as the
  grid twice or four times as fine, as the comparison found. Cells coarser than any compared make
  the peaks and impulses an approximation.
- **Close in.** A gauge or structure within 0.75 m/kg^(1/3) of a charge brings in the close-in
  comparison and a note that close-in loading needs cells of about 0.01 W^(1/3), or twice that
  refined by 2, and that spall needs 0.005 W^(1/3) and 12 elements through a slab.
- **Regime.** Each structure's regime (far field, close in, in contact or confined;
  `StructuralRegime`) and its loading pick some of the concrete model's defaults (see the
  [concrete model](concrete-model.md#defaults-by-regime)): pressed interlock in a confined scene,
  and no sectional shear check in beams under a blast or a blow. An option the regime set is a
  default, not the user's choice (`pressedInterlockFromRegime`).
- **Afterburning.** Off, the incident impulse is 13–22% low; on, it is within 4% (6% with hot
  air), with the burning time fitted to it. Reflecting domain faces bring in the closed-room
  comparison, whose agreement depends on both options.
- **Materials.** Reinforced concrete has measured agreement; plain concrete, steel and masonry
  are verified against theory; glass is an approximation. A structure takes its weakest material.
- **Model options.** Each option that changes a result's standing has one entry: what it does,
  which results it touches and the strongest level they keep with it. Pressed interlock, other
  crack axes, design increase factors and rate-independent concrete make structural results an
  approximation; base connections cap them at verified; simplified cars make freestanding motion
  illustrative. Options with their own evidence (shells, bars that slip, footings) add it.
- **What is left out.** Each scene lists what it could involve that nothing here models: a
  rigid ground with no crater, collapse never compared and debris only once, ignition and fire, and so on.

## In the app

A small badge sits beside each result: the gauges' peak overpressure, the structure's chart and
section, and the sections for thermal radiation, the cloud, fragments, ground shock, freestanding
objects and building surfaces. It shows the weakest standing of what that place shows. Clicking
it opens the evidence (which check, how close), the resolution notes, the assumptions and links
to these documents. The Run tab's **Standing of results** section lists every result the scene
produces with its badge, the notes on resolution, and what the scene does not model.

## Kept runs and comparison

A kept run records the standing it was made under (`standing` in its record; see
[save files](save-files.md)), so that a later revision of the table does not rewrite what an old
run was judged by. Runs kept before this open as **Standing not recorded**. The record's format
and fingerprint are otherwise unchanged.

[Comparison](run-comparison.md) badges each selected run beside its name and warns when the
selected runs differ in standing from the reference, by result: two runs whose peaks differ by
10% mean something different when one's impulse is measured agreement and the other's an
approximation.

## Headless runs and exports

`BombCAD run` ends its summary with each result's standing, its notes on resolution and what is
not modelled. `--standing <file.json>` writes the whole standing as JSON. Each model's results
file (`--thermal-results`, `--cloud-results`, `--fragment-results`, `--ground-results`) carries
its own result's standing under a `standing` key beside its other keys, which readers of the
results pass over. The USD scene's `customLayerData` holds a `standing` dictionary (each result's
level and summary, the resolution notes and what is not modelled), and each OpenVDB file has
`bombcad_standing` and `bombcad_standing_table` in its file metadata. See
[Exporting a run for rendering](usd-export.md).

The headless standing covers the models fed alongside the run; the run it keeps covers what that
run keeps, which does not include those models' results.

## Error bands

Where the validation record supports it, a result also carries a numeric band: model over
measured (or over the reference), the way the model errs and whether that is the safe or the
unsafe side, where the band holds, and the section it comes from (`ErrorBand` in
`Sources/BlastCore/ErrorBands.swift`). Outside what was compared there is no band, and the
standing says why.

- **Each gauge** has its own band, from its scaled distance and whether it sits on a face (the
  reflected comparison) or in the open (the incident one). Kingery–Bulmash's tables give the
  ratio per distance and grid; the band spans the compared distances either side of the gauge,
  and between grids it is interpolated in the logarithm of the scene's scaled cell, refinement
  counted as the finer grid. Close in (0.3 to 0.75 m/kg^(1/3)) the close-in table is used, for
  gauges on a surface. With afterburning and hot air their own tables apply. Gauges beyond
  6 m/kg^(1/3), closer than 0.3, shielded from the charge, over terrain, or on cells coarser than
  any compared grid get none.
- **Structures** take the slab test's 105–115% on 4 to 32 solid elements through (125% on
  shells) in the far field; close in, Wu's slabs (40–70% under charges to 0.8 kg, −20% to +7% to
  2 kg) and, from 2 kg, Chiquito's deflection left (a third to a half); confined, the chamber's
  wall pressures (0.9 to 1.6 times). Strength in shear is 37% strong on 12 elements through and
  11–15% on 24 or more, interpolated between. Any structural option the tests were not run with
  removes the band. Footings, debris under contact charges, a closed room's gas, the fireball's
  radiated energy and the cloud's top have bands of their own.
- **In the app** the popover gives each band and, for the value shown, where the measurement
  would lie; under each gauge's peak and the structure's largest deflection a line says what to
  expect, rounded to two figures: "68 mm: expect 59–65 mm (model reads high: too flexible)".
  Comparison marks a difference narrower than the band, which cannot be told apart against
  measurement. Kept runs, `BombCAD run --standing` and the USD layer carry the bands; standings
  recorded before them open with "not recorded".

**Regimes.** The scene is placed as in contact (under 0.15 m/kg^(1/3) from a structure), close
in (under 0.75), far field, or confined (a closed room or a charge inside a structure), and the
options the record shows to be right in one regime and wrong in another are checked against it:
bars that slip (right only for a beam split under a light drop), pressed interlock (right only for
the chamber), fragment removal (holes slabs that held as well as those that did not), elements
through (8 enough for bending, about 24 for shear, 6 for the close-in slab), afterburning and hot
air (needed in a closed room), the shells' shear check and other rate laws. Each gives a
suggestion; no default changes.

**Kept in step.** `ErrorBandTests` parses the record's Kingery–Bulmash, afterburning and close-in
tables and checks them cell for cell against the code's; every other figure is hand-mirrored with
the quote it is read from, which must lie under its heading and hold the figure's numbers. A
change to the record fails the test until the table follows.

## The table and keeping it current

The content is one reviewed table in code, `StandingTable` in
`Sources/BlastCore/EvidentialStanding.swift`. When the validation record or the limitations table
changes, change the table with it and advance `SceneStanding.currentTable`.

`EvidentialStandingTests` keep it honest:

- Every stored property of the input types it reads (the scenario, the charge, the solver's
  configuration, the structure, its materials and connections, and the specifications of the
  thermal radiation, the cloud, fragments and ground shock) must be listed as a model option, an
  input or a numerical control. A new model option landing anywhere fails the test until it has
  an entry. The app's own settings map onto the solver's configuration in one place
  (`ProjectRunSettings.configureAir`), used by the solver and the standing alike.
- Every option must be set by some input and have a title, a note and the results it touches.
- Every link must reach a heading in these documents.

## Limitations

- **A summary, not the evidence.** The standing quotes the validation record's ranges and
  interpolates only between its compared grids; the documents remain the authority.
- **Bands from few tests.** Most bands rest on one test or one series; a band is where the model
  has been, not a confidence interval.
- **Scaled by the primary charge.** Resolution is judged against the comparisons' grids by the
  first charge's mass; several charges are noted, not judged separately.
- **One standing per result per scene,** not per gauge or per element. A gauge close in and one
  far out share a peak-overpressure standing, with the nearest gauge's distance among its notes.
- **Damage is coarse.** Structural damage and failure is an approximation throughout, with
  collapse named as never compared and debris as compared once; it does not tell a spall from a
  breach.
- **Building surface records** exported as JSON are a list and carry no standing of their own;
  `--standing` covers them.
- **Not a judgement of safety.** Nothing here is validated for engineering decisions or for
  judging the safety of a real structure, and the standing says so.
