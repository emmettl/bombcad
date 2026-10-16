# Stationary building envelopes

Building envelopes keep walls, roofs and openings in the shared air simulation without a
structural mesh. They offer a cheaper representation for neighbourhood exposure studies:
each building still shields and reflects the flow, including waves returning from its
neighbours. They remain stationary throughout a run and predict no deformation or failure.

In the structure editor, **Use Exposure-only Envelope** converts the selected local authored
structure. Its object ID, name, solids and openings survive; materials, reinforcement,
supports and mechanical state are discarded. **Undo** restores the detailed structure.
The resulting buildings appear under **Exposure-only buildings**, where they can be removed.
Geometry editing is done before conversion or in a layout JSON; there is no separate envelope
geometry editor yet. Source-owned imports keep their existing import workflow.

`BuildingEnvelope` and its approximation rules belong to BlastCore in BombCAD. It uses the
existing ContinuumKit `Box` geometry; this milestone introduces no shared-core contract or
package release. Openings are subtracted into bounded box fragments using the same half-open
boundary convention as the air rasteriser. Limits are 2,048 solids/fragments per building,
256 openings per building and 2,048 rigid fragments across a scene containing envelopes.
Unlike deformable bodies, envelopes have no sixteen-building mechanics limit. Air memory and
resolution still constrain useful scene size.

## Saving and exporting

Layouts encode `buildingEnvelopes` beside the existing geometry, with durable object ownership.
Projects containing envelopes use scene encoding version 6 so older package readers reject
them instead of silently dropping buildings. Projects without envelopes retain their existing
version 3 or 4 encoding, or version 5 for footings and turned support joints. Prototype
envelope packages written as version 5 remain readable and migrate to version 6 on save.
Existing numerical fingerprints are unchanged; envelope geometry
enters new fingerprints while object names and IDs remain excluded.

The viewport draws the subtracted rigid fragments, and ordinary runs retain gauge histories
and the existing pressure/impulse fields. USD exports put each envelope in a separate mesh
with its object ID, name and stationary-envelope representation attached. Opening geometry
also participates in import placement and picking occlusion.

## Surface exposure and loads

An optional `BlastSolver.configureEnvelopeExposure(objects:)` recorder reports the boundary
that the air grid actually resolves. It accepts envelopes and fully pinned detailed reference
bodies at time zero. Moving-body references are rejected. Loading another scene or replacing
the body set clears the recorder; restarting resets its values.

Every owned solid cell face next to a fluid cell becomes a receiver with area `dx²`, a
position at the voxel face and a normal pointing into air. Interior and exterior surfaces
both contribute. Shared solid faces and domain boundaries contribute nothing, including the
ground attachment. Buildings with overlapping owned solid cells are rejected by the recorder;
every requested building must have at least one resolved face.

After each complete fluid step, a receiver reads the pressure at its adjacent coarse fluid
cell centre, including restricted fine state. This is a cell-pressure approximation to
surface loading, not the solver's wall Riemann flux or a calculated structural reaction.
The initial pressure participates in the peak; temporal integrals use right endpoints for
every accepted fluid interval, including a clipped final interval. Time-limit no-op steps add
nothing. A changed solid/fluid pair marks the receiver invalid.

Snapshots retain current overpressure (Pa), peak positive overpressure (Pa), positive pressure
impulse (Pa s) and signed pressure impulse (Pa s). Summing `-normal × area × overpressure`
gives an estimated force in N; using signed impulse gives an estimated vector impulse in N s.
Signed accumulation preserves suction and cancellation between opposite faces. The core
recorder is opt-in. The app automatically enables it for scenes containing envelopes without
deformable structures; other ordinary scenes allocate no surface recorder. Mixed scenes
continue to run, with the inspection restriction shown in the sidebar.

The Run tab's **Building surface exposure** section selects an owner and shows its recorded
window, resolved area, maximum surface overpressure, area-weighted mean positive impulse,
summed positive loading, current force vector and signed impulse vector. The positive scalar
sum integrates pressure impulse over every resolved interior/exterior face; it is not the
resultant vector impulse. Readouts refresh alongside the chart, up to ten times a second.
The GPU still records every fluid endpoint, so display cadence does not skip integrals.

Pause a run to **Export surface records…** as JSON, with individual face locations, normals,
areas and pressure exposure. Exports are snapshots of the current finite observation window.
Reset clears the live results. The viewport continues to show the existing pressure and
impulse fields; the numerical surface inspector does not add a separate surface colour map.

**Keep Run** stores compact per-building summaries with stable owner IDs. They appear in
saved-run inspection and CSV exports, where their values are labelled at the end of the
recorded window. Individual face arrays are exported separately rather than embedded in
every kept result. Results containing these summaries use saved-run encoding version 3;
earlier records remain readable and retain their encoding when they lack surface results.
These diagnostics do not enter the numerical input fingerprint.

Headless runs collect the same summaries. To write full surface records alongside a kept run:

```sh
.build/release/BombCAD run envelope-layout.json --duration 0.12 --out envelope-run.bombcad --envelope-results surfaces.json --csv exposure.csv
```

`--envelope-results` requires a scene containing only stationary envelopes and at least one
resolved exposed face per owner. It refuses a pre-existing destination. Unavailable surface
recording does not prevent ordinary blast runs, but an explicitly requested surface export
fails with its reason instead of writing absent results as zeros.

## Envelope components and their pressure histories

For damage estimates on envelope buildings ([future work](#future-work-damage-for-envelope-buildings)),
`BlastSolver.configureEnvelopeComponents(objects:options:)` records the load on each part of a
building that responds on its own: stage 1 of that work. The definitions are agreed with the
damage model that reads them (`/Volumes/StudioData/bombcad/envelope-damage/component-spec.md`, v1.2).

**Components** (`BuildingEnvelope.components(owner:cellSize:)`, from the geometry alone):

- A solid whose smallest size is at most 1 m and at most half its middle one is a **wall** (thin
  in x or y) or a **slab** or **roof** (thin in z; a roof when nothing of the building stands
  above it). It is cut at its supports first: a wall where a slab crosses its height or another
  wall meets it inside its length, a slab or roof where walls meet it from below. Then each piece
  is cut into equal panels at most 6 m wide, and 3 m tall where no slab or roof holds the wall;
  slabs and roofs at most 6 × 6 m. Cuts are snapped to the air grid. Each panel is a component,
  with which of its four edges are supported (on another solid or the ground).
- Other solids are **blocks** (map buildings): each side in **façade** strips a storey (3 m) tall,
  a remainder under a metre joining the strip below, and a **roof**. Columns are left out.
- **Panes** (`BuildingEnvelope.panes`, new) are glazing, solid in the air: a one-way damage model
  takes a pane as closed until it fails, so it records the reflected load the glass carries. Each
  is one component, held on four edges. A detailed structure's annealed glass becomes panes when it
  is converted to an envelope, and scenes with panes save at scene encoding 10.

Ids are `<owner>/<kind>/<source>.<panel>`. The street study's buildings come out as one panel a
wall and one roof panel.

**Histories** (`envelopeComponentHistories()`): after every complete fluid step, each component's
two sides, the faces whose normal points outward and those pointing in, are averaged over their
faces (the surface recorder's cell-centre pressures, by one GPU thread a component in a fixed
order). Each step's value is integrated into 0.1 ms bins by its overlap with them, so the impulse is
exact whatever the step; the peak of each side, and of the net (outer less inner, pushing inward),
is kept from every step. Options: the bin width; the window; a memory budget (256 MB by default)
that widens the bins to a whole multiple when needed and says so; per-bin maxima (twice the
memory); and openings recorded as panes in the open opening, for what the inside sees once glass
has gone. Steps past the window are not binned and the history says `truncated`.

Headless runs write them with `--envelope-histories <file.json>`; kept runs do not store them yet.
Recording leaves the air bit-identical, and each side's binned impulse equals the mean of its faces'
own integrals (tests in `EnvelopeComponentTests.swift`).

**Cost.** Memory is components × bins × 8 bytes, plus about 13 bytes a face: at 0.25 m, the
street's 4 buildings (20 components, 120 ms) take 0.37 MB, the 64-building neighbourhood
(320 components, 60 ms) 4.4 MB. Each step, a SIMD group a component reads the flags of the tiles of
air its faces lie in. A component whose air is all still is finished there, from the still air's
pressure added as its faces would be (the same bits, tested). The awake ones are listed for two
indirect dispatches: a threadgroup of 256 a component reading its faces (a face in a still tile reads
the still air), then a SIMD group a component summing them in a fixed order. A step with nothing
awake runs only the first pass. The surface recorder skips faces in still air the same way, with
the same bits, which every envelope run gains from.

Timed with `scenebench envelope-histories --dx 0.25 --rounds 7`, interleaved, on a quiet M4 Max
(every GPU slot free, load under 4; 16 October 2026), as the median of seven rounds:

| | Street, 120 ms | Neighbourhood, 60 ms |
|---|---|---|
| Surface recorder skipping still air, against reading every face | 1.00 | 0.81 |
| Histories too, against the surface recorder as now | 1.07 | 1.10 |
| Histories too, against the surface recorder as it was | 1.07 | 0.90 |

Earlier versions of the histories, against the surface recorder reading every face: a thread a
component, +80–130% (timed under load); a thread a face, then summed, with still components
skipped, +5.2% and +14.4%.

What remains is about 20 µs a step, on steps of 0.27 ms (the street) and 0.19 ms (the
neighbourhood): three small dispatches when anything is awake. Sharing the surface recorder's face
reads would not remove it: only awake components read cells, and they are a small part of it.

## Matched building study

```sh
swift build -c release --product scenebench
.build/release/scenebench envelopes /tmp/envelope-study --source-revision=$(git rev-parse HEAD)
python3 Scripts/check-building-envelopes.py /tmp/envelope-study --summary /tmp/envelope-study/summary.json
python3 Scripts/plot-building-envelopes.py /tmp/envelope-study --out /tmp/envelope-study/figures
```

`--quick` runs six 12 ms smoke cases. It establishes operation and initial boundary matching;
the full study is needed to follow the wave through the buildings.

The full matrix uses the [street study's](street-interaction.md) isolated, paired and
four-building layouts, with a conventional 2 kg TNT-equivalent source, fixed 1 m deposition
radius and a 120 ms observation window. The detailed references use 0.5 m solid elements,
with every node restrained. Comparing
against freely responding buildings would confound the cost of the representation with the
physics deliberately removed by an envelope.

Each layout runs at 0.5, 0.25 and 0.125 m uniform air spacing and at 0.5 m refined by two.
Additional cases exercise a doorway and roof opening, source-normalised conservation with
closed boundaries, half CFL at 0.25 m, separate stage profiling and unrecorded replays.
The fixed spatial probes remain 0.5 m apart at 1.5 m height. Comparisons exclude the union
of solid-touching probes across both representations and all resolutions, a 3 m source
radius and a 1 m domain-edge margin. Surface comparisons match physical voxel-face positions
and normals, retaining any unmatched-face count.

Representation gates require matching boundary classifications and surface faces, peak
relative L1 differences below 10% and positive-impulse differences below 5%, both on maps and
surfaces, total surface positive loading differences below 5% and vector impulse differences
below 10%. Total-load comparisons include every resolved face, including any unmatched faces.
These gates assess the approximation against the pinned numerical reference;
they do not establish physical accuracy. Spatial sensitivity uses the finest grid as a
reference. The finest grid itself has no finer or half-CFL companion here.

Load histories sample force at eight-step batch endpoints. Their cumulative signed impulse
includes every accepted fluid step, while force extrema between batch endpoints can be missed.
Gauge histories retain every fluid endpoint. The metadata report stays readable; raw maps,
surface records, gauge/body histories and load histories are separate lossless gzip files.

The retained M4 Max [report](../Benchmarks/BuildingEnvelopes/m4-max/report.json) contains 57
runs produced by revision `6710af3952c14bb263fe2c3de0279d09613ee09f`; its
[checked summary](../Benchmarks/BuildingEnvelopes/m4-max/summary.json) contains 14 representation
comparisons, 20 sensitivity comparisons and four scaling sizes. Every representation pair
has identical spatial maps and surface records, including the opening fixture. The matched
faces, total surface positive loading and vector impulse therefore have zero differences.
The unrecorded and profiled replays also retain identical maps.

![Matched detailed and envelope street exposure](building-envelopes/exposure.png)

The plot uses common square-root colour scales, omits the 3 m source neighbourhood and shows
stencils touching solids in grey. Enclosed air remains visible inside the buildings.

Envelope equality does not remove air-grid sensitivity. For the street's 4,272 common probes:

| Air setting | Peak relative L1 | Impulse relative L1 | Mean arrival difference |
| --- | ---: | ---: | ---: |
| Uniform 0.5 m versus 0.125 m | 46.48% | 12.78% | 1.006 ms |
| Uniform 0.25 m versus 0.125 m | 19.76% | 1.87% | 0.391 ms |
| 0.5 m refined by two versus 0.125 m | 22.75% | 9.43% | 0.553 ms |
| Uniform 0.25 m, half CFL versus nominal CFL | 2.62% | 1.34% | 0.097 ms |

The detailed and envelope curves coincide because their resolved boundaries and air fields
match. Adaptive maps read restricted coarse state, rather than the sharpest fine-cell peak.
The finest result is a numerical reference, not a converged or measured answer.

![Air resolution sensitivity of both representations](building-envelopes/sensitivity.png)

Closed companions have identical conservation residuals: mass drift is 0.02755% of injected
source mass and energy drift is 0.00107% of source energy, both below the 0.3% gate.

## Scaling study

The scaling runs compare 1, 4 and 16 pinned detailed buildings with matching envelopes, then
run 64 envelopes. Air spacing is 0.5 m and the cutoff is 60 ms. Domain extent grows with the
building count, so total air-cell count grows too. The largest scene need not have exposed
every building by that cutoff; this is a computational scaling study, not complete loading
of a neighbourhood.

Each paired size has three repeats with alternating execution order. Surface recording is
disabled for scaling, and spatial recording remains enabled on both representations.
The report retains each wall/GPU timing, setup time and solver GPU-buffer footprint.
Stage-profile replays separate air, mechanics, coupling and observation; their stage sum
omits encoder gaps and profiling adds overhead. Repeated local timings still vary with
background work and hardware.

Measured medians of three runs on M4 Max, with memory in decimal MB:

| Buildings | Detailed buffers | Envelope buffers | Detailed wall time | Envelope wall time | Detailed GPU time | Envelope GPU time |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 3.80 MB | 2.51 MB | 0.363 s | 0.134 s | 0.295 s | 0.057 s |
| 4 | 9.59 MB | 4.81 MB | 1.201 s | 0.140 s | 1.122 s | 0.062 s |
| 16 | 28.62 MB | 11.64 MB | 5.031 s | 0.143 s | 4.877 s | 0.066 s |
| 64 | — | 34.21 MB | — | 0.158 s | — | 0.075 s |

![Computational scaling with the building count](building-envelopes/scaling.png)

The 16-building short-window wall-time ratio is 35.1, but it includes the different amount
of still-air work as well as removed mechanics and coupling. Detailed boundaries keep nearby
air awake for moving-mask/debris processing; envelopes can skip untouched tiles. Extending
the window until distant buildings are exposed would change this balance.

The finer four-building street offers a longer-window comparison. At 0.125 m, a single
120 ms run took 51.79 s wall and 50.55 s GPU with detailed buildings, versus 18.92 s wall and
17.95 s GPU with envelopes. Reported solver buffers fell from 514.84 to 301.22 MB. These are
single local observations; the full-resolution air remains a substantial cost.

The separate 0.25 m profiled replays recorded 2.01 s of mechanics and 0.91 s of coupling for
the detailed scene, both zero for envelopes. Recorded air time was 0.77 s and 0.51 s,
respectively, and observation was 0.12–0.13 s. Stage sums omit encoder gaps, and their
profiled command times (8.34 s and 3.83 s) include extra encoder overhead; use the ordinary
runs for throughput comparisons.

## Shell geometry diagnostics

The earlier shell-reference matrix is retained separately in
[`Benchmarks/BuildingEnvelopes/shell-reference`](../Benchmarks/BuildingEnvelopes/shell-reference).
It does not satisfy the matching-boundary acceptance gates. Diagnose it with:

```sh
python3 Scripts/check-building-envelopes.py Benchmarks/BuildingEnvelopes/shell-reference --diagnostic --summary /tmp/envelope-shell-summary.json
```

The shell mesh joins panels on midsurfaces and its sampled boundaries differ from the authored
box union at some junctions and opening rims. Closed-building probe masks match, but resolved
surface faces differ on the finer grids. In the doorway/roof-opening fixture, one horizontal
probe changes solid classification and the surface sets have 16 unmatched faces at 0.5 m
air spacing and 131 at 0.25 m. Treating those runs as a strict check of envelope geometry
would hide the shell approximation.

The opening fixture's far-field map impulse differs by 1.23% at 0.5 m and 0.83% at 0.25 m,
while the total surface positive loading differs by 11.73% and 6.68%, respectively. The
corresponding vector impulse differences are 24.13% and 34.94%. Far-field agreement therefore
does not establish agreement in surface loading. The matched-solid study isolates the cost
of removing mechanics; this diagnostic matrix records the consequences of changing the
resolved boundary as well.

## Envelopes from imports and map data

Envelopes can also come from geometry made elsewhere, so that a neighbourhood of real buildings
costs what its blocks cost. The code is `Sources/BlastCore/EnvelopeImport.swift`,
`MapBuildings.swift` and, for IFC windows and doors, `Sources/BombCAD/IFCOpenings.swift`. Each
envelope made this way records where it came from (`Scenario.envelopeSources`), which sets its
[standing](standing.md): an approximation for imports, illustrative for map data.

### IFC and other imports

**Use as Exposure-only Envelope** (Run ▸ Imported geometry), or **Use All as Exposure-only
Envelopes** for a group of them, turns an attached rigid import into a building of its own:

- its sampled boxes become the envelope's solids: walls, slabs, roofs, columns and every other
  element the import kept;
- IFC windows and doors become openings, cut as their placed bounding boxes from every solid they
  cross. Windows and doors the importer left out, because their meshes are not closed (the usual
  case: all 24 windows and 14 doors of the duplex fixture fail its watertight check), are read back
  from the retained IFC bytes for their bounds alone. An OBJ or STL import has no elements, so no
  openings;
- the import is removed, so that its geometry is not counted twice, and its note says what was
  kept. Element identities, materials and the link to the source are not kept; Undo restores the
  import.

Limits are the envelopes': 2,048 solids and 256 openings a building, 2,048 fragments in a scene.

**Checked against the same building as rigid obstacles** (`EnvelopeImportStudyTests`, run with
`BOMBCAD_ENVELOPE_STUDY=<folder>`; 10 kg 8 m in front, 80 ms, surfaces recorded on both, the
rigid import through an observer built from its boxes):

| Building, cells | Envelope against the rigid import | With the left-out windows and doors cut |
|---|---|---|
| House, 0.5 m | identical: 278 solid cells, 824 faces | no windows or doors: identical |
| House, 0.25 m | identical: 2,181 cells, 4,087 faces | identical |
| Duplex, 0.5 m | identical: 2,391 cells, 4,880 faces | 29 cells cut; maps 0.10% (peak), 0.51% (impulse); surface loading 0.74% |
| Duplex, 0.25 m | identical: 23,512 cells, 24,941 faces | 100 cells cut; maps 0.06%, 0.24%; surface loading 0.35% |

The envelope is the rigid import to the bit: the same cells in the mask, the same maps and the
same face-by-face surface records. Cutting the windows' and doors' bounds opens a little more
than the holes the converter cut in the walls (frames, sills, reveals): under 0.6% on the maps and
0.8% on the summed surface loading. The net vector impulse changes by 4% and 17%, a small
residual of large opposing face loads, as in the matched study above. Converting takes
milliseconds; reading the 38 windows' and doors' bounds back from the IFC 0.4 s; runs take what
the rigid import's do (0.6 and 3.6 s). Openings raise the duplex's fragments from 63 to 148 at
0.5 m and from 142 to 332 at 0.25 m, which is what limits how many such buildings a scene holds.

### Buildings from map data

**Map buildings** (Run tab) reads building footprints from an OpenStreetMap extract (`.osm`) or
GeoJSON that you supply; BombCAD downloads nothing. Closed ways tagged `building`, and
multipolygon relations (their outer and inner ways joined into rings, inner rings as courtyards),
are buildings; `building:part` is left out, as it lies within its building. GeoJSON Polygons and
MultiPolygons with a `building` property are buildings, or every feature where none has it.

- **Placement.** Longitude and latitude become scene metres by a local equirectangular mapping
  about the scene's corner (the buildings' south-west corner by default). A footprint is
  rasterised on the grid's cells, a cell in where its centre is inside (even–odd over the rings,
  so courtyards stay open), and merged into rectangles: the 13 synthetic buildings make 17
  boxes. Each stands on the lowest point of the [terrain](terrain.md) under it, if there is one,
  and is a solid block: no interior, openings or roof shape.
- **Heights.** `height` (metres, or feet as `40 ft` or `40'6"`), else `building:levels` plus
  `roof:levels` at 3 m a level, else an assumed two levels (6 m); `min_height` or
  `building:min_level` lifts the bottom. The report counts each source.
- **What is left out**, and said: footprints with fewer than three distinct corners or no area,
  those outside the scene or smaller than a cell, and a later building's cells where an earlier
  one already stands (overlaps go to the first). A roof above the domain is lowered to it.
- **Credit.** OpenStreetMap data is under the Open Database Licence: placing buildings adds
  "Buildings © OpenStreetMap contributors, ODbL 1.0" to the scene's attributions, which the
  Map buildings section shows, and the USD export (`customLayerData.attributions`) and the
  results' CSV carry. Only a small synthetic fixture is bundled
  (`Samples/MapBuildings/synthetic-neighbourhood.geojson`), made up rather than taken from a map.

![Thirteen synthetic map buildings on a 5° slope, 60 ms after 20 kg in the open square](building-envelopes/map-neighbourhood.png)

**Checked** by `EnvelopeImportTests` (footprints where their coordinates put them to a cell, each
height fallback, courtyards, the degenerate cases, overlaps and placement on a slope) and **costed**
by `blastbench terrain --study buildings`: placing the 13 buildings takes 1–3 ms; a run with them
takes no longer than the empty scene (0.75–1.0 times as long: they take cells out of the air), on
flat ground or a slope; recording their 26,000 (0.5 m) or 106,000 (0.25 m) faces costs nothing
measurable.

What is lost against the real buildings: openings, interiors, roof shapes, eaves and anything
under a cell; heights where the map has no tag; and positions and heights only as good as the
map's. They shield and reflect the blast as solid blocks of their footprint, nothing more.

## Scope and verification

Tests compare surface integration with independent per-step CPU pressure accumulation,
including suction, check uniform-pressure cancellation, final-interval clipping and restart,
and verify bit-identical air fields with recording enabled on coarse and refined grids.
Project tests cover mixed scenes, version rejection and Undo/Redo restoring the original
structure. Existing ownership, project and multi-body checks cover compatibility.

The envelopes inherit the existing idealised blast model and grid-dependent geometry.
Unresolved openings and thin walls can disappear. Fixed geometry cannot represent broken
windows, collapse, debris or evolving shielding. This establishes stationary exposure
behaviour and its computational cost; it does not validate invented buildings against
measurements or establish kilogram-to-kiloton physical coverage.

## Damage references

For a damage model on envelope buildings (below), the street study's layouts are run with the
detailed buildings free to respond: `scenebench envelope-damage`, which records each component (wall,
roof, glazing pane) under the ids the envelope's components will have. The buildings and the charge's
standoff are the street study's, in a domain enlarged to 56 × 48 × 16 m so that afterburning products
are not trapped, on the recommended air at 0.25 m. Each building's walls are 0.2 m reinforced concrete
(one central mesh, 0.3% each way), 0.215 m brick (smeared masonry: shells have no units and joints),
or the concrete with a 6 mm annealed pane 1.5 × 1.25 m in each wall, under a 0.2 m concrete roof, as
shells of 0.125 m in 8 layers, settled under their weight before the blast. Each component records its
deflection history relative to its support edges, rotation, residual, failed share and, for a pane,
when it broke; and, under the same rules on the detailed run and on its envelope twin (the same scene
with each building exposure-only), the area-mean pressure on each face of it, binned as impulse.

```sh
swift build -c release --product scenebench
.build/release/scenebench envelope-damage <dir> --layouts=isolated,street --walls=rc,brick,glass \
    --charges=2,10,50 --representations=detailed,envelope
python3 Scripts/summarize-envelope-damage.py <dir> --out Benchmarks/EnvelopeDamage/summary.json
```

The 19 runs of 16 October 2026 (isolated building at 2 to 500 kg, the four-building street at 10 and
50 kg, the pair at 50 kg) are summarised in [`Benchmarks/EnvelopeDamage/summary.json`](../Benchmarks/EnvelopeDamage/summary.json);
the records, with their histories, geometry and material inputs, are kept off the repository. On the
isolated building, the wall facing the charge:

| Charge | Concrete: peak, rotation | Brick | Glass (the facing pane) | Inside, detailed / envelope |
| ---: | --- | --- | --- | --- |
| 2 kg | 1.3 mm, 0.04° | 2.9 mm, 0.08° | broken at 27 ms | 0.1–0.2 kPa / 0 |
| 10 kg | 3.4 mm, 0.10° | 10.9 mm, 0.31° | broken at 20 ms | 0.2–1.0 kPa / 0 |
| 50 kg | 15 mm, 0.43° | 52 mm, 1.49° | broken at 13 ms | 0.4–2.6 kPa / 0 |
| 200 kg | 73 mm, 2.1° | | broken at 8 ms | 1.6–11 kPa / 0 |
| 500 kg | 209 mm, 6.0° | | broken at 6 ms | 6.5–22 kPa / 0 |

Before anything breaks, the envelope twin's loads on each component match the detailed run's within
about 2% (peak net pressure and positive impulse on the facing wall within 0.5–1.6%), so the one-way
model's input is the detailed building's own. The envelope stays sealed: its inside stays at ambient,
where the detailed buildings' insides rise as panes break and walls move, which is the error a one-way
model makes by not venting. The shells' junctions erode first (the walls' top rows at the roof, a
corner column), even at 0.4°; the panels themselves lose no interior element up to 6°, so rotation,
not erosion, marks a concrete wall's damage here. These are references on one mesh and one air grid,
not measured damage, and the brick walls after cracking are the least trustworthy of them
([brick walls](validation.md#brick-walls-debris)).

## One-way damage: single degree of freedom

Each component of an envelope (a wall panel, a roof, a glazing pane) can be given an equivalent
single degree of freedom driven by the load the air puts on it, the air still seeing the building
whole: `SDOFSystem` integrates K_LM m ẍ + R(x) = p(t) per unit area after Biggs (1964) as UFC
3-340-02 (2008) gives it, with a multi-linear resistance, elastic unloading, rebound, and UFC's
load–mass factors through yield. `EnvelopePanel` builds the systems:

- **Reinforced concrete**: the yield-line resistance of a two-way panel on the bars' and concrete's
  dynamic strengths (UFC Table 4-1: 1.17 and 1.19), the stiffness of a clamped or simply supported
  plate (Timoshenko) on the mean of the gross and cracked sections, elastic–perfectly plastic.
- **Unreinforced masonry**: elastic until the largest moment reaches f_t t²/6, then rocking with
  the resistance falling to nothing at a deflection of its thickness; no arching.
- **Annealed glass**: elastic until the largest bending stress reaches its strength (the same 45 MPa
  as the detailed model's), then nothing; membrane stiffening is left out, so it breaks early.

It matches UFC's worked examples 3A-5, 3A-6(a) and 4A-1 within 1% (`EnvelopeSDOFTests`).

```sh
swift build -c release --product scenebench
.build/release/scenebench envelope-sdof <damage references> [--edges=fixed|simple] [--out=<file.json>]
```

Driven by each component's load on the envelope twins of the [damage references](#damage-references)
and set against the same component of the detailed building free to respond (summaries in
[`Benchmarks/EnvelopeDamage/sdof-fixed.json`](../Benchmarks/EnvelopeDamage/sdof-fixed.json) and
[`sdof-simple.json`](../Benchmarks/EnvelopeDamage/sdof-simple.json)), 16 October 2026:

- **The loads are not the error.** SDOF on the envelope's loads and on the detailed run's own give
  the same rotation (median ratio 1.02 over 87 components past 0.05°); they part only on the side
  and back walls of buildings already breached.
- **Glass**: of 52 panes, SDOF breaks the 45 the detailed buildings break, a median 1.7 ms early
  (0.59–1.20 of the detailed time), and 7 more that the detailed buildings keep, all under the
  lightest loads (a peak net pressure of 7.3 kPa at most): wrong on the safe side.
- **Concrete walls** (34 past 0.1°): with fixed edges SDOF gives a median 0.59 of the detailed
  rotation, unsafe; with simply supported edges 1.19. The facing wall lies between the two
  (at 50, 200 and 500 kg: 0.61/1.19, 0.70/1.24 and 1.03/1.87 of the detailed); side walls of a
  building whose front fails, and roofs under heavy loads (0.16–0.37 at 200–500 kg fixed, 0.27–0.60
  simple), go further than either, as the frame acts and its junctions erode, which no single panel
  sees.
- **Brick walls** (14 past 0.1°): a median 1.10 of the detailed rotation (0.82–2.54), 2.5 times on the facing
  wall at 50 kg where the shells hold on longer than the rocking mechanism (which the masonry
  references after cracking are least trusted on anyway).
- **Under 0.1°** the detailed panels sit on a floor of 0.02–0.04° that SDOF does not have.
- **Cost**: the detailed building adds 14–35 s a building to a 150 ms event on the M4 Max (the
  air alone takes 10–15 s); SDOF takes under 1 ms a building.
- **Not venting**: the envelope's inside stays at ambient, where the detailed buildings' rise to
  0.1–0.4 kPa with concrete walls whole (1.0 kPa behind cracked brick at 50 kg), 1–2.6 kPa once panes break at 10–50 kg and 11–22 kPa at 200–500 kg.
  A one-way fill (each pane an orifice into the room once SDOF breaks it, driven by its outer
  pressure, the room's air compressing adiabatically) gives 2.1, 5.7, 11.3 and 19.5 kPa against
  the detailed gauges' 1.0, 2.6, 11.0 and 22.4 at 10, 50, 200 and 500 kg (0.87–2.23 times the
  detailed peaks), mostly above. It cannot see a breached concrete wall (1.6 and 6.5 kPa at 200 and 500 kg).

**In the app.** Runs of envelope-only scenes record each component's load (the
[recorder](#surface-exposure-and-loads) keeps both sides' histories at 0.1 ms) and judge every building
one way as the run goes, at most once a second and again when it stops:

- **Construction.** Each envelope's walls are reinforced concrete or unreinforced masonry, with a
  thickness, a concrete roof, a reinforcement ratio and annealed glass. These are read from an IFC
  import's material layers or a map building's `building:material` tag; otherwise the default is
  assumed (0.2 m concrete, 0.3% each way, 6 mm glass) and the standing says how many were assumed.
  The editor's Exposure-only buildings section changes them, and projects save them.
- **Levels.**
  - Concrete is a range of support rotation between fixed and simply supported edges, judged by
    ASCE/SEI 59-11's limits for single-reinforced slabs: moderate to 2°, heavy to 5°, hazardous to
    10°, failed beyond.
  - Brick is cracked or fallen (deflected past its thickness). No citable limits for unreinforced
    masonry without arching were found.
  - Glass is broken or whole, with the time it broke; the fragments' hazard is not graded.
  - A building with a panel past 2° is flagged as beyond the one-way model.
- **Shown.**
  - The sidebar's Envelope building damage section lists each building's levels, its panes broken
    and when, and the inside through them, with the result's standing. Export damage writes it as
    JSON.
  - The view colours each envelope by the worse end of its range: green none, blue glass broken
    alone, yellow moderate, orange heavy, red hazardous, purple failed.
  - Headless, `BombCAD run … --envelope-damage <file.json>` writes the same JSON and prints a line
    for each building.

These are comparisons with the detailed model on one mesh, not with measurement: open tests of
window glass under blast are listed in [data wanted](data-wanted.md#3h-window-glass-breaking-under-a-blast)
but not yet read. Freestanding walls (Alsubaei's, Keys's) would need cantilever systems, and remain
to be compared.

## Future work: damage for envelope buildings

Envelopes make district-scale scenes possible: the air is cheap at that scale (a 3.3 km domain of
145 million cells ran a 500 t burst in 137 s on an unloaded M4 Max; see
[large scenes](large-scenes.md)), but a scene holds at most 16 deformable bodies. Every other
building is a rigid, exposure-only envelope that never breaks, so a district run says what each
building is loaded with and nothing about what happens to it.

A cheaper damage model would give envelope buildings a damage estimate from the loads already
recorded on their faces, one way at first, with the air still seeing a rigid building:

- **Per component, single degree of freedom** (in the manner of UFC 3-340-02 and the PDC's SBEDS):
  each wall panel, storey or glazing pane an equivalent spring-mass driven by the pressure history
  on its faces, giving its peak deflection or support rotation and so a damage level.
- **Pressure–impulse curves**: each component's peak overpressure and impulse placed against
  curves of equal damage, cheaper still and needing no time history.
- **Fragility curves**: a probability of each damage state from the same loads, where published.

What decides whether it is worth building, to answer before any of it is:

1. **Its error against the detailed model.** The matched pairs above use pinned detailed
   references, so they compare loads, not damage; the [damage references](#damage-references) run
   the same layouts with the detailed buildings free to respond, for the reduced model's damage per
   component to be set against theirs.
2. **Its error against measurement**, where data exist: the [perimeter walls](validation.md#perimeter-walls-under-field-blasts)
   (Alsubaei), the [brick walls](validation.md#brick-walls-debris) (Keys), and UFC 3-340-02's
   charts as they are digitised in `UFC340.swift`.
3. **The error from not venting.** Glazing or walls that fail while the air still sees them whole
   leave the inside loads wrong; set against the detailed run's internal loads, this says how far
   a one-way model can be trusted, and whether failed openings must be opened in the air.
4. **Its cost per building against the air's**, which should be small: the recorder's faces
   already hold peak and impulse, and a single-degree-of-freedom model's pressure histories are
   now kept per component ([above](#envelope-components-and-their-pressure-histories)).

Until those comparisons are made, its results would stand as an approximation where a chart or
curve applies and as illustrative otherwise (see [standing](standing.md)).
