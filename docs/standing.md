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

- **A summary, not the evidence.** The standing quotes the validation record's ranges; it does
  not rerun or interpolate them, and the documents remain the authority.
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
