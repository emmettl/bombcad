# Standing of results

Each result BombCAD produces carries its evidential standing: what it rests on, how close that
came, and what the scene's settings do to it. The [long-term vision](long-term-vision.md#credibility-as-a-product-feature)
asks that users can tell a comparison with measurement from mathematical verification, an approximation and
an illustration, and that assumptions, resolution sensitivity and unsupported effects stay with
the scene and its exported results. This is the first step towards that. It summarises the
[validation record](validation.md) and the [roadmap's limitations](roadmap.md#limitations-most-important-first),
which remain the authority.

## The four levels

| Level | Meaning | Example |
|---|---|---|
| Compared with measurement | Compared with measurements, and how close it came, which way and how far it errs; not that it agrees | Reflected impulse on a wall within 6% either way of Kingery–Bulmash on fine enough air; a close-in slab left a third to a half as far down as measured |
| Verified against theory | The equations are solved correctly against exact or textbook solutions; no measurement | A steel structure: wave speed, deflection and period within 5% of theory |
| Approximation | A recognised approximation with stated assumptions; nothing says how close it comes here | Structural damage and failure; building surface exposure; fragments from a casing of given dimensions |
| Illustrative | Plausible-looking, or compared too loosely to rely on | Thermal radiation, the cloud, fragments of a chosen number, ground shock, simplified cars |

Until 11 October 2026 the top level's name spoke of agreement; it names a kind of evidence, not
agreement, and a result compared with measurement can be far off it. Standings saved with the old
value, `measured`, read as the new, `compared`. Wherever a standing is summarised, in the popover, the headless summary,
the [validation record's summary](validation.md#summary), the README and the roadmap, the
direction of the error comes first, and the unsafe side (too little damage, too much strength) is
named.

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
  and no sectional shear check in beams under a blast or a blow, and, loaded slowly, hourglass
  control that softens with cracking. An option the regime set is a default, not the user's
  choice (`pressedInterlockFromRegime`, `hourglassFromRegime`).
- **Afterburning.** On by default since 15 October 2026, with hot air and far-field faces: the
  incident impulse within 6% beyond 1 m/kg^(1/3) on 0.25 m cells, with the burning time fitted to
  it, and the reflected impulse 6–13% high; off, the incident impulse is 13–22% low. A band
  derived without it is withheld under it until derived again (Hupfauf's debris). Reflecting
  domain faces bring in the closed-room comparison, whose agreement depends on both options.
- **Materials.** Reinforced concrete has been compared with measurement; plain concrete, steel and masonry
  are verified against theory; glass is an approximation. A structure takes its weakest material.
- **Model options.** Each option that changes a result's standing has one entry: what it does,
  which results it touches and the strongest level they keep with it. Pressed interlock, other
  crack axes, design increase factors and rate-independent concrete make structural results an
  approximation; base connections cap them at verified; simplified cars make freestanding motion
  illustrative. Options with their own evidence (shells, bars that slip, footings) add it.
- **What is left out.** Each scene lists what it could involve that nothing here models: a
  rigid ground with no crater (or, on earth or rock, a crater estimated but not modelled), collapse compared once (blind, and missed) and debris only once, ignition and fire, and so on.

## Collapse

Since 19 October 2026 a structure's collapse is a result of its own (`ResultKind.collapse`,
"Collapse: storeys lost, structures down"), listed wherever a scene has a structure.
- **What it covers:** parts of a structure losing their support and falling. That is, members
  and elements failing, joints and connections letting go, and what they carried coming down: a
  storey lost, a structure down, collapse spreading through a block of panels or a frame.
  `structuralDamage` keeps the members' and elements' own damage: cracking, yielding, breach,
  a member failing.
- **Its standing: illustrative,** whatever the failing members' material reads, and with no
  error band, so that it never borrows the local damage's. Before this, the large-panel flats
  coming down read as an approximation, the concrete band.
- **What would raise it.** A structural system's collapse may rise to an approximation only when
  a compared collapse case of that system agrees within its band. None does yet:
  - **Slabs:** Mendonça's, blind, the two that collapsed left standing (the unsafe side).
  - **Brick houses** against the Second World War's bomb surveys: the right category at 0.1 s,
    but the cracked front walls topple after, one or two categories too severe beyond 11 m (the
    safe side). Masonry structures are illustrative anyway.
  - **Beirut's 0.5 m stone:** falls in 8 of 293 buildings where 7 of GEER's 13 partly collapsed.
    It is not converged, and was once matched by an error.
  - **Alsubaei's blockwork wall** under 125 kg collapses as the test's did: one wall, not a
    structure.
  - **Steel connections** take their fracture from slow column-removal tests (NIST TN 1669,
    Weigand and Berman): a calibration. No frame has been compared losing a column.
  - **Large-panel flats:** against the Ronan Point inquiry's estimates only, not measurement.

  The office tower on fin plates and the large-panel flats coming down are the model's alone.

The app gives it its own badge in the structure section ("Collapse"); the structure's other
badges keep the deflection's and the damage's standing.

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
10% mean something different when one's impulse was compared with measurement and the other's an
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

**Estimates beside a run** (the quick estimate and its glass chances, the hybrid far field and
charge inference) are
not scenes, so they carry no `SceneStanding`; each prints a few lines of standing in the app, its
JSON and its command, worded from the same table's figures
([estimates beside a run](validation.md#estimates-beside-a-run)), and those lines are part of the
table's identity.

## Error bands

Where the validation record supports it, a result also carries a numeric band: model over
measured (or over the reference), the way the model errs and whether that is the safe or the
unsafe side, where the band holds, and the section it comes from (`ErrorBand` in
`Sources/BlastModel/ErrorBands.swift`). Outside what was compared there is no band, and the
standing says why.

- **Each gauge** has its own band, from its scaled distance and whether it sits on a face (the
  reflected comparison) or in the open (the incident one). Kingery–Bulmash's tables give the
  ratio per distance and grid; the band spans the compared distances either side of the gauge,
  and between grids it is interpolated in the logarithm of the scene's scaled cell, refinement
  counted as the finer grid. Close in (0.3 to 0.75 m/kg^(1/3)) the close-in table is used, for
  gauges on a surface. With afterburning and hot air, today's defaults, their own tables apply
  ([re-run](validation.md#the-defaults-since-15-october) on all three grids, reflected peaks
  included, and close in). Gauges beyond
  6 m/kg^(1/3), closer than 0.3, shielded from the charge, over terrain, or on cells coarser than
  any compared grid get none.
- **Structures** take the slab test's 79–119% on 4 to 32 solid elements through in the far
  field, either way by load (104–115% under the contest's load, rising with the mesh towards
  119%; 79–88% under its lower shot), with the contest's repeat, 3%, as the tests' scatter (124%
  on shells). That band came from a shock tube's long, uniform load. It is withheld within
  1.5 m/kg^(1/3) of a charge: there, blind test 2's open-air slabs
  ([Mendonça](validation.md#blind-test-2-mendonças-slabs-under-an-open-air-charge)): the two nearest
  collapsed where the model's stood, and the rest read a tenth to a quarter of meters that likely
  include the supports' movement; the model's slab responds as its own load would have it, and
  that load's large suction was the harness's copying faces, not today's far-field ones, so what
  remains lies outside the slab's bending. Blind in the contest's own rig (test 3), high-strength slabs
  read 0.77–1.06 where they held; open in it, the 8 in normal-strength slabs (RSCR4–6) 0.91–1.06.
  The low edge, the lower shot's 79%, may be its scaled record's shape: on another shot's shape it
  reads 97%. It is left as recorded, since that rests on a borrowed shape. No structural result converges on today's defaults
  ([convergence](validation.md#convergence-on-todays-defaults)): the meshes that agree are the
  coarse end, and the bands say so; close in, Wu's slabs (40–70% under charges to 0.8 kg, −20% to +7% to
  2 kg) and, from 2 kg, Chiquito's deflection left (a third to a half); confined, the chamber's
  wall pressures (0.9 to 1.6 times). Strength in shear follows OA1 on 12 to 48 elements through, 32% strong on 12 and 4–11% on 24 to 48, spanning the meshes either side of the scene's. Any structural option the tests were not run with
  removes the band. Footings, debris under contact charges, a closed room's gas, the fireball's
  radiated energy and the cloud's top have bands of their own. The debris band, after failure,
  is widened by its spread across roundings of the same arithmetic (`roundingSpread`, ±10% from
  Hupfauf's far faces).
- **In the app** the popover gives each band and, for the value shown, where the measurement
  would lie; under each gauge's peak and the structure's largest deflection a line says what to
  expect, rounded to two figures: "68 mm: expect 59–65 mm (model reads high: too flexible)".
  Comparison marks a difference narrower than the band, which cannot be told apart against
  measurement. Kept runs, `BombCAD run --standing` and the USD layer carry the bands; standings
  recorded before them open with "not recorded".

**The mesh a structural band holds on.** No structural result converges on today's defaults
([convergence](validation.md#convergence-on-todays-defaults)): where one settles it settles above
the measurement, and the meshes that agree are the coarse end. So each structural band records the
mesh, and where it matters the step, it was derived on (`derivedMesh`), and holds only there:
Wu's slabs on 8 elements through, Chiquito's on 6 to 12 (on 16 the slab holes), Hupfauf's debris
on 12, the chamber on 0.1 m elements, OA1's strength on 12 to 48, spanning the meshes either side
of the scene's, and the contest slab on 4 to 32, reaching the 119% its peak rises towards. On any
other mesh the band is withheld and the standing says why; the popover, the headless summary and
the USD layer give the mesh. The advisor varies the air only, and says that a finer structural
mesh is not shown to bring a structure closer to its test. A safe side found on one mesh is not
claimed for another: the shells' 124% is the slab test's one mesh.

**Uncertain inputs.** Where the ensemble ran a band's case with its inputs sampled (see
[the model's spread from uncertain inputs](validation.md#the-models-spread-from-uncertain-inputs)),
the band carries that spread: the slab's 12%, Wu's 4%, the close-in gauges' 7% (8% before 18 October), and 2% for a
wall's peak and its impulse (rerun 18 October; the impulse 1% before). The expected range adds the inputs' 5–95% range (1.645 coefficients of
variation) to the band's half-width in quadrature, since the model's error and its spread from
uncertain inputs are separate, and comparison uses the combined width. Elsewhere the band stands
alone.

**The reference's own scatter.** A band compares the model with a reference's mean; a single test
scatters about it. Where the record gives that scatter, the band carries it, one standard
deviation: Kingery's tests about Kingery–Bulmash's fit, 6.4% in incident peak and 6.7% in incident
impulse; for reflected values, which Kingery and Bulmash calculated rather than fitted, modern
repeats' 6–8% (8% taken); UFC 3-340-02's rooms, 11%. Each band says plainly whether the model's
error lies inside that scatter, where it cannot be told apart from the tests (the reflected
impulse within 6% without afterburning, a closed room's 98–108% with afterburning and hot air), or outside it, where
the difference is the model's (the incident impulse 13–22% low, peaks under-resolved, a room's
default gas; arrival times, 2–10% early against about ±2%, have no band). The expected range adds
the scatter at 5–95% as it does the inputs' spread, and comparison uses the combined width. Close in, where repeats differed
by up to 40%, the band says so instead of carrying a figure; Kinney–Graham has none known.

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
`Sources/BlastModel/EvidentialStanding.swift`. When the validation record or the limitations table
changes, change the table with it.

**Its identity is derived, not numbered** (`StandingFingerprint`, since 18 October 2026). It is a
hash of every option's entry, the fields' roles, the figures, scatters, spreads and roundings the
bands are read from, and the standing of every sample scene on the shipped air, written
canonically. Dictionaries and sets are sorted, fields are taken in label order, and numbers are
written to six significant figures, so the same content gives the same identity on any Mac. A kept
run records it as `standing-` and eight hexadecimal digits, shown as "standing a1b2c3d4". Runs kept
before carry "standing-table-1" to "standing-table-36", shown as "standing table 36", and read as
judged by a different table. Two changes made apart now merge without renumbering. A change on a
code path no sample scene reaches leaves the identity as it was, until the next change that one
does reach.

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
  collapse named as compared once, blind, and missed, and debris as compared once; it does not tell a spall from a
  breach. Results after failure move with any change to how their arithmetic rounds (a changed
  model, compiler or GPU), so the standing gives them as one draw among roundings
  ([convergence](validation.md#convergence-on-todays-defaults)). Beams broken by an impact also
  follow the strain-rate window's length, steeply and not monotonically (Ando's at 90 to 105 µs),
  far more than rounding moves them, and the standing says so.
- **Building surface records** exported as JSON are a list and carry no standing of their own;
  `--standing` covers them.
- **Blind tests judge the defaults frozen for them.** Tests 1 (`1c85774`) and 2 (`047cee3`) were
  frozen before the 100 µs strain-rate window became the default on 12 October 2026, so their
  results apply to the 50-step average it replaced, and the standing says so beside them
  ([convergence](validation.md#convergence-on-todays-defaults)). Test 3 judged v0.3.0 (`b524a9d`),
  with the window and afterburning and hot air.
- **The sleeping air.** Once the air is quiet, or late, it sleeps. Since 15 October 2026 its
  outline follows the structure ([freezing the air](air-blast-model.md#freezing-the-air)), so a
  structure moving on is loaded by the frozen air beside where it is; before, the frozen outline
  drove blind test 2's landing slabs down at about 11 g. It still feels no new flow, and loose
  debris feels no air while it sleeps, so the standing notes it on every scene with a structure;
  keep the air awake for debris in flight or anything thrown far.
- **Bands hold on the air they were found on.** Since afterburning, hot air and far-field faces
  became the default on 15 October 2026, Kingery–Bulmash's tables close in and out, the rooms,
  Wang's and Wu's slabs, Chiquito's, Hupfauf's debris and the chamber's wall pressures have been
  run again on them, and the fireball's radiation and Church's clouds were compared on them
  already. Each takes its own band on its own air; afterburning without hot air, compared only
  on 0.25 m cells, takes few.
- **Not a judgement of safety.** Nothing here is validated for engineering decisions or for
  judging the safety of a real structure, and the standing says so.
