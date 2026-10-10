# BombCAD

An interactive blast simulator for simple building layouts, written to answer one question:
how close to real time can a physically based simulation of blast on structures run on a
current Mac?

It has two solvers, both on the GPU:

- an **air-blast solver** that propagates the blast wave around obstacles and records peak
  overpressure and impulse on every surface;
- a **structural solver** for reinforced concrete, brick, concrete block, steel and glass that cracks,
  crushes, yields its reinforcement and breaks under those pressures. Broken pieces collide,
  fall and come to rest, and the air flows through the gaps they leave. Structures are meshed with solid elements, or
  with much faster shell elements for walls and slabs and beam elements for columns, or with
  both in one body, tied where they meet.

It is a study of the numerics and the performance, not a design tool.

![Blast wave in a street canyon 45 ms after detonation](docs/street-canyon-45ms.png)

![A three-storey concrete frame clad in masonry, 150 ms after a charge in front of it](docs/three-storey.png)

![A two-storey frame's glass façade breaking up 100 ms after 20 kg in the street](docs/glass-facade.png)

![A twelve-storey tower 2 s after 4 tonnes beside it: its floors punching off their columns](docs/twelve-storey.png)

## Download

A signed, notarized build for Apple silicon Macs running macOS 15 or later is on the
[Releases](https://github.com/emmettl/bombcad/releases) page. Expand the ZIP and move
`BombCAD.app` to Applications; the `.sha256` file beside it checks the download.

## Running it

To build from source instead: macOS 15 or later, Swift 6.4 and a Metal GPU.

```bash
swift run -c release BombCAD
```

```bash
make app
```

The second command builds `dist/BombCAD.app`, which can be launched from Finder.
The first app build downloads a checksum-pinned native IFC converter into `.build/ifc-converter`
and bundles it with the app; later builds verify and reuse the cache. When using `swift run`,
run `python3 Scripts/prepare-ifc-converter.py` first to enable IFC import.
[Releasing](docs/releasing.md) describes signed, notarized builds for other Macs.

In the view: drag or two-finger scroll to orbit, shift-drag or right-drag to pan, pinch or mouse
wheel to zoom. Space runs and pauses, ⌘R resets.

The sidebar has two tabs. **Run** picks a built-in layout, the grid, the charge and the display.
The layouts are open ground, a single building, a street canyon and a courtyard (rigid blocks);
a cantilever wall, a single-storey building, the same building behind a blast wall, a two-storey
frame (bare, infilled with masonry, or glazed with glass panes), a three-storey clad building,
an eight-storey frame and a twelve-storey tower with a concrete core (both shells and beams,
for collapse over several seconds), an
open-sided car park with a charge inside, an underpass, a column close to a charge, a
two-storey house of concrete blockwork meshed with shells, a blockwork boundary wall meshed
block by block with its mortar joints, and the internal-explosion test
(deformable). The close-in column wants the fine grid: on coarser air it
is less than a cell or two across. The sidebar shows a structure's deflection now and the
largest it has reached.
**Edit layout** adds, moves, resizes and removes rigid blocks, deformable walls, openings and
pressure gauges, sets each wall's material and reinforcement, and has undo (⌘Z). You can move
the charge, or the selected gauge, by clicking the ground. Save Project writes a `.bombcad`
document containing the scene, simulation settings, camera and embedded import sources. Projects
reopen without the original OBJ/STL files. Named projects autosave; each
project has its own window, and closing an edited untitled project asks whether to save.
BombCAD → Settings (⌘,) sets defaults for new projects and playback windows.
The More menu offers Save As and Import Layout JSON. Export Layout JSON saves just the scene. See [Save files](docs/save-files.md).

**Import Model…** reads watertight OBJ/STL geometry and IFC buildings. Confirm source units, up axis and
placement, then prepare a preview of the actual occupied simulation volumes. Imports can be
rigid obstacles, or a new deformable solid body with a material preset and editable density,
stiffness and strength. Deformable imports require a layout without an existing structure,
use solid elements at the air cell size, and start without reinforcement. Fixing the base
holds nodes at the imported body's lowest plane; review that assumption before running.

**Help → Importing models** provides an offline walkthrough of scale, placement, feature-size
warnings, material assignment, repair, and saving or reopening imported sources.

Repository-only [importer sample files](Samples/Importer/README.md) cover named parts,
STL components, units, cavities, thin features, narrow gaps, and the repair workflow.
They are not bundled with the app. The [real CAD fixtures](Samples/Importer/RealCAD/README.md)
add unchanged FreeCAD library exports, pinned provenance and current acceptance/resolution expectations;
their STEP counterparts are references for future support.

IFC imports use the bundled IfcOpenShell converter locally and create **rigid obstacles**.
Physical walls, slabs/roofs, columns, beams, members, plates, footings, stairs, railings, doors
and windows can be chosen; spaces, furnishings, proxy/site markers and other types are excluded.
Before geometry conversion, choose exact elements using building, storey, type and text filters
and inclusion checkboxes. Filters only change the list; Include/Exclude matching changes the
import. Up to 1,024 supported elements can be chosen from a 20,000-entry decomposition inventory.
Choose IFC elements in the preview or source inspector to revise choices from retained IFC bytes.
Each subset is rebased to its own bounds; review placement after changing choices.
The Parts browser retains element names, types, storey labels and GlobalIds, searchable by any
of these. Source units and world placements are converted to metres, Z up, then rebased from
large coordinates before Float conversion. The original coordinate origin remains recorded.

Each IFC element is validated independently. Existing segmented edge junctions are made
conforming without creating faces, and coordinates are canonicalised at 0.1 micrometre.
Touching and overlapping elements produce a union of occupied cells; overlaps count once and
use the first sorted GlobalId for selection. Element diagnostics do not certify gaps between
separate elements. Geometry omissions, converter diagnostics and unsupported material metadata
remain explicit import notes. IFC completeness and exported reports list intentional exclusions,
unsupported types, missing converted geometry, complete grid losses and overlapping cell ownership
separately. Inventory follows the decomposition tree; uncontained products may be absent. Invalid
selected solids block conversion with their name and GlobalId; excluding one is an explicit action.
Undetermined converter units block import to prevent incorrect scale. Structural materials, supports and connections are not inferred.

Projects retain original IFC bytes and converted sources; reopening and grid resampling need
neither the original file nor the converter. Version 2 source assets hold IFC element metadata, inclusion choices and source inventories,
while OBJ/STL assets retain version 1. See the repository-only
[whole-building IFC fixture](Samples/Importer/Buildings/README.md) for a small house, matching
raw OBJ reference, a two-storey duplex, structural beams, an imperial column, a unit-failure case,
expected behaviour and reproducible provenance. IFCZIP/IFCXML and
conversion to deformable shells or beams are outside this first milestone.

The importer retains each source mesh, its units/orientation and placement in the saved layout.
**Inspect / edit source…** in Edit layout reopens an import without its original file. Changing
the air grid regenerates retained geometry in the background; the simulation pauses until the
new geometry is ready. Source edits replace that model rather than adding another copy.

Click an imported model in the main viewport to select it and open its source, placement and
material inspector. Selection follows occupied volumes, respects openings and nearer geometry,
and outlines the selected model. Turn off Place Charge to select models; charge/gauge placement
continues to take priority. Viewport selection uses the initial layout, so reset after running
the simulation before selecting a model. Detached geometry remains independently editable and
its retained source is accessible from the sidebar.

The import inspector keeps its 3D preview visible beside independently scrolling, collapsible
controls. Detailed material properties live under Advanced. Dimensions in metres remain visible
while units and placement change; unusually small or large models offer explicit unit corrections.
A labelled reference grid helps judge scale. Corrections are never applied automatically.

Drop one local OBJ/STL/IFC file into the viewport or use Import Model. Reading and geometry checking
run in the background with a Cancel checking action; cancelled or superseded work cannot open a
stale result. Rejected geometry opens a separate inspection view with red defect surfaces, source
triangle numbers, repair guidance, and a text repair report. Collapsed/non-finite triangles remain
blocked even when they cannot be drawn. Choose repaired file retries validation after the inspection
closes; invalid inspection data cannot enter the simulation. Syntax errors report OBJ line numbers.

The source inspector includes a searchable Parts browser. OBJ object and group names label
complete connected shells; STL components and unnamed sources receive stable component names.
Face groups within one shell do not define separate material volumes. Select a part to highlight
its source surface in green and focus the preview; the browser reports its sampled solid cells.
A shell with no cells may represent a cavity or a feature lost at the selected resolution.

Part checkboxes support multi-selection, Select matching, and bulk material assignment/reset.
Copy and paste a material between selections. Isolate selected parts and material colours affect
only the preview; every source part still imports. The model default remains linked to parts
without an override. Geometry warnings can be filtered by source part IDs, including cavity
boundaries; placement filtering uses overlapping sampled regions.

Compare grids samples coarse, medium and fine without changing the chosen grid or live layout.
The table shows cells, sampled volume changes, parts absent at one grid but present at a finer
one, and estimated air-memory cost. Measured thin features/gaps suggest a grid when two cells
fit across the smallest sampled dimension; unresolved finest-grid features are called out.
Stable volume or a suggested grid is not a completeness or convergence guarantee. Checks can
be cancelled, and changes to source placement/units invalidate comparisons. Apply is blocked
when estimated air memory or active material counts exceed their limits. Export import report
records all warnings and assignments, regardless of the current warning filter.

Reusable import profiles save units, up axis, behavior, base support choice, default material and
part overrides matched by name. Loading a profile is explicit, reports matched overrides, and
stages settings until Apply. Placement, domain and grid stay specific to the current import.
Existing imports retain their rigid/deformable behavior. Profiles can be updated or removed;
up to 20 are stored locally.

For deformable imports, each part can use the model's default material or a custom preset with
editable properties. Assignments are saved against source part IDs and survive grid, unit,
orientation and placement changes, including a thin part disappearing and later returning at a
finer grid. Sampling keeps different parts in separate generated regions even when a coarse grid
closes their gap. Cavity walls use the enclosing solid's material; a solid island within a cavity
uses its own. The solver supports eight distinct active materials, including the model default;
imports or refinements exceeding that limit fail before changing the layout. Rigid parts remain
obstacles and ignore structural materials. Material textures and external OBJ material files are
not imported.

Placement checks in the preview highlight overlaps with existing geometry (orange), charge
locations inside the candidate model (red), and floating or disconnected sampled components
(purple). Selecting a placement issue focuses the camera on its region, with surrounding volume
for a blocked charge and a ground reference for an elevated component. The Context layer shows
existing geometry and ground and can be toggled off. Checks exclude the
model being edited and subtract structural openings. Separate buildings and intentional joints
can produce advisory warnings; geometric contact does not establish a structural connection
or validate supports. Fixed-base explanations distinguish the lowest plane from elevated,
disconnected components. Checks use the sampled geometry of the rebuilt layout and do not
track moving debris. Work/highlight limits are explicitly reported when checks are incomplete.

The preview refreshes automatically after a short pause when units, orientation, position or
grid change. Pending updates keep the previous geometry dimmed and clearly marked; Apply is
disabled until the current preview is ready and its warnings have been reviewed. Previewing
does not change the simulation.

Placement shortcuts centre the footprint without changing its height, put the base on the
ground without moving X/Y, or expand the domain with clearance. Expansion preserves existing
domain extents and checks the estimated air-memory budget; it takes effect only on Apply and
can be undone in the sheet before applying.

The interactive 3D preview overlays the source wireframe (cyan) and sampled simulation volumes
(blue). Orange regions identify thin features or narrow gaps sampled along X, Y and Z; red
regions identify potentially missing surfaces. Toggle layers, orbit and zoom, or select a
region to focus the camera, or reset the view. Warnings group potentially missing surfaces
separately from resolution risks. **Preview finer grid** advances to the next available grid;
the finest grid is explicitly identified, since refinement does not guarantee resolution.
Region descriptions include approximate position, extent and the
minimum sampled feature dimension. Empty previews show geometry lost on a coarse grid, but
cannot be imported until a finer grid or larger scale produces occupied cells.

Warnings persist with retained models. Review them before applying an import, and compare
resolutions to assess accuracy: highlights are approximate sampling diagnostics, not a
convergence or completeness guarantee. Up to 128 affected regions are highlighted; the UI
reports when this limit is reached. Features not crossed by scanlines and missing surfaces
near other occupied geometry can escape detection.

Deformable regeneration preserves the body's main material and source part assignments. Changes to individual generated regions,
openings, reinforcement or supports block regeneration to avoid overwriting local edits.
**Detach geometry** keeps the current geometry and edits while stopping source regeneration.
The mesh remains saved and available for inspection; detached geometry is independent. Grid
changes cannot then restore lost features. Layouts saved by the earlier importer remain
readable, but their discarded sources cannot be recovered automatically.

Textures and OBJ visual materials are ignored; export triangulated faces or convex polygons.
Open/non-manifold meshes, self-intersections, overlapping solids and ambiguous contacts are
rejected before sampling, including defects smaller than a grid cell. Intersection errors
identify triangle numbers and an approximate region in source units. Boolean-union overlapping
solids or repair the indicated surfaces in your CAD tool before exporting again. Separate nested
shells are interpreted as cavities, with further nested shells becoming solid islands; a completely
contained part therefore needs a Boolean union if it is intended to fill material. Face winding
is normalized internally for sampling without rewriting the source. Rays on triangulation edges
use one face owner and tangent contacts cancel.

Limits are 20 MB, 100,000 triangles, 2 million sampled cells, and 2,048 coalesced regions.
A spatial hierarchy limits intersection checking to overlapping triangle bounds, with a
2 million candidate-pair limit, a traversal budget and cancellation. Models that exceed
validation limits must be simplified; they are not imported with incomplete checks. A scanline-work budget also limits
expensive previews.

Gauge and deflection histories export
as CSV from beside the chart.

```bash
swift test
```

```bash
swift run -c release blastbench throughput
```

```bash
swift run -c release blastbench slab --sensitivity
```

`blastbench` also has `structure`, `validate`, `gas`, `chamber` and `snapshot` commands; see
[Performance](docs/performance.md) and [Validation](docs/validation.md). `blastbench anchorage`
compares a freestanding wall on a clamped base with one on starter bars, a construction joint,
friction alone, soil or a footing on soil (see [base connections](docs/structural-model.md#base-connections)
and [footings](docs/structural-model.md#footings)).

`BombCAD run Example.bombcad --out Example-run.bombcad` runs a saved project without a window and
keeps the result as a saved run, for scripts and other Macs; see
[headless runs](docs/run-comparison.md#headless-runs). Add `--usd Example.usda` and `--vdb Example.volumes` to
write the scene, the structure and the blast over time for rendering elsewhere
([USD export](docs/usd-export.md)). Sweeps can share their cases with other Macs over SSH,
in the app or with `BombCAD sweep`; see
[sharing a sweep](docs/run-comparison.md#sharing-a-sweep-with-another-mac).

For the isolated rigid-object mechanics demo, run `swift run rigidboxdemo`, then open
`.build/rigid-box-demo.html` in a browser. The self-contained replay shows resting, friction
holding, sliding, lift-off, rocking and tipping, with playback and a time slider. It records
the Swift reference mechanics. The app's layout editor places freestanding boxes and cars and
computes their motion after the blast; see [freestanding objects](docs/freestanding-objects.md).

`swift run -c release rigidboxdemo --blast` generates `.build/rigid-box-blast-demo.html`, a
slow-motion comparison of a held and free box under the same blast. This experimental path
uses one box on uniform ideal-gas air and reports reference timings. Chemistry and deformable
structures are unsupported; whole-cell boundary updates can introduce pressure
artefacts. It does not enable rigid-object simulation in the app.

`swift run -c release rigidboxdemo --convergence` writes `.build/rigid-box-convergence.json`
and prints resolution, timestep, impulse, motion, mass-conservation and timing comparisons.
It includes held/free uniform-grid references and factor-two adaptive held/free runs.
`swift run -c release rigidboxdemo --refined` generates `.build/rigid-box-refined-demo.html`,
showing held and moving boxes with fine masks and wall velocities. Translation, rotation and
ground-gap opening/closure use conservative fine-cell remapping. Free-motion results are
still sensitive to spatial resolution. The synchronous remapper operates within the swept
box bounds plus a donor margin; the convergence report includes remapping phase timings.
Add `--extended` to the convergence command for 0.025 m uniform grids at both timesteps
and adaptive comparisons with 0.05 m fine cells. This writes
`.build/rigid-box-convergence-extended.json`, including initial gas mass/energy and final
orientation/angular momentum; each completed case prints its timing.

`swift run -c release rigidboxdemo --diagnostics` writes `.build/rigid-box-diagnostics.json`:
prescribed remapping in ambient air without gas evolution, suspended-box loading in uniform
flow without gravity/contact, and contact-only mechanics under a known force pulse. These
separate boundary sensitivity from contact sensitivity; the remap-only pressure changes
are a numerical stress diagnostic, not a prediction of blast error.
Add `--transport` to compare an opt-in connected-path remapper, writing
`.build/rigid-box-diagnostics-transport.json`. It preserves uniform states for balanced
occupancy changes; unequal voxel volumes still use redistribution. The usual driver and
app keep their existing behaviour while this alternative is evaluated.
`--convergence --transport` applies the same alternative to the matched blast study and
writes `.build/rigid-box-convergence-transport.json` (add `--extended` for the longer study).
Reports record the remapper and separate air and ground impulses. Completed cases are saved
incrementally; a failed run can leave a partial report.
`swift run -c release rigidboxdemo --geometry` writes `.build/rigid-box-geometry.json`, a
CPU-only reference for fractional cell volumes and open face areas. It compares translation,
rotation and sub-cell ground gaps on three grids without changing air masks or simulation.
The report also measures clipped wall areas/centroids, uniform-pressure force/torque and
cell surface/volume balances. Ground cases use virtual cells below the plane to check the
complete box surface; those loads are geometry identities, not ground-pressure predictions.
`--motion-geometry` writes `.build/rigid-box-motion-geometry.json`, comparing endpoint cell
volume changes with temporally integrated wall motion and equal/opposite pressure work.
It includes cell crossings, rotation and thin-gap opening at three temporal resolutions.
It also compares event-split integration for constant translation of axis-aligned boxes,
recording the integration method and actual temporal evaluation count in each result.
All results also record the six open face areas integrated over time
(m² s). For axis-aligned constant translation, crossing events split the area into quadratic
pieces integrated exactly by the Gaussian reference. These areas still need a gas flux to
determine transported mass, momentum and energy. The adaptive rotated reference checks
coarse/fine Gaussian and endpoint-inclusive estimates of each face integral, with a separate
area-time tolerance and error indicator. These indicators are not certified error bounds.
Rotated translation and rotation use an adaptive reference checked against endpoint volume
changes and coarse/fine quadrature. The 48-case report includes volume tolerances and error
indicators. This reference does not certify force impulses or detect every brief grazing event.
`--grazing-geometry` writes `.build/rigid-box-grazing-geometry.json`, comparing analytical
cell-pressure impulses for 1 ms, 100 µs and 10 µs corner encounters against midpoint and
adaptive sampling. Adaptive refinement now also checks force/torque quadrature and uses
separation bounds to investigate intervals whose samples could miss a complete encounter.
`--fractional-gas` writes `.build/fractional-gas-compression.json`, checking ideal-gas pressure
work in prescribed fractional volumes. The CPU transport reference conserves extensive mass,
momentum and energy for supplied transfers; it does not yet derive face fluxes or choose a
stable timestep, and is separate from the air solver.
`--fractional-remap` writes `.build/fractional-remap.json`, deriving conservative adjacent
transfers from a translating box's fractional volumes and sampled face openings. The network
limits outgoing volume to each donor's old gas inventory. This is remapping, not physical
air fluxes; dry relays and insufficient transit capacity are rejected.
`--fractional-substeps` writes `.build/fractional-substeps.json`, automatically bisecting
prescribed motion intervals when the remap exceeds a cell's gas-volume capacity. Passing
0.02 m³ through transit cells of 0.004, 0.001 and 0.00025 m³ takes 8, 32 and 128 steps,
preserving mass, momentum, energy and uniform pressure to floating-point precision.
The controller has bounded refinement and returns a complete result only on success.
This capacity limit is separate from acoustic timestep stability; physical face fluxes still
need integration with the moving apertures before fractional blast coupling.
`--fractional-flux` writes `.build/fractional-flux.json`, a CPU-only periodic pressure-pulse
study using a first-order ideal-gas Rusanov flux in stationary positive gas volumes. Each
interface exchanges equal/opposite mass, momentum and total energy. The timestep is limited
by each cell's volume divided by its summed face acoustic rates; oversized steps and
nonphysical states are rejected. Smaller cells require 10, 35 and 138 steps over 0.5 ms
in this study. This periodic study uses stationary volumes; the wall and piston references
below add boundary impulse and pressure work.
`--fractional-walls` writes `.build/fractional-walls.json`, replacing the periodic endpoints
with reflecting stationary slip walls. The report includes accumulated wall impulse and
the gas-plus-wall momentum residual; no mass or energy crosses a fixed wall. Its three
pressure-pulse cases require 11, 38 and 141 steps over 0.5 ms. Wall pressure now uses the
exact planar ideal-gas shock/rarefaction relations, including zero load at vacuum onset.
Prescribed moving walls are exercised by the piston reference below.
`--wall-pressure` writes `.build/wall-pressure.json`, checking incident normal Mach numbers
from -6 to +3 against the wall law. Positive velocity points toward the wall. The acoustic
wall timestep rate includes the compressive shock speed.
`--piston` writes `.build/piston.json`, prescribing constant-speed planar motion at one
end of a closed four-cell tube. The same wall velocity changes gas volume and supplies
equal/opposite pressure work and impulse. Six cases compress or expand total volume by
10% at 0.25, 0.5 and 1 m/s, checking conservation and approach to the quasi-static
adiabatic pressure. This reference keeps constant wall area and fixed cell topology;
cell crossings and general time-varying apertures remain to be coupled.
`--piston-crossings` writes `.build/piston-crossings.json`, advancing a planar piston
through three or six grid boundaries on two grids. A quarter-volume end cell merges
with its neighbour before closure and splits during expansion. Piecewise-constant
repartitioning conserves extensive mass, momentum and energy. This bounds end-cell
stiffness but changes spatial diffusion; general box geometry and varying apertures
are not yet coupled to the physical flux reference.
`--piston-sensitivity` writes `.build/piston-sensitivity.json`, comparing matched 20 m/s
compression/expansion on two grids, two CFL limits and three merge fractions (24 cases).
It records wall work, conservation budgets and 64 pressure/velocity samples along the
final tube. Changing merge thresholds has a small effect on mean pressure in this study,
but local profiles and grid spacing still matter; the comparison is not blast validation.
`--piston-transients` writes `.build/piston-transients.json`, with profiles at 0.5, 2, 5
and 15 ms on 0.1, 0.05 and 0.025 m grids at two CFL limits. Complete cell profiles are
included alongside 64 samples. `python3 Scripts/summarize-piston-transients.py` compares
pressure by exact overlaps of the piecewise-constant profiles, using the finest run as a
numerical reference. Snapshot times split integration steps, and budgets are recorded at
every snapshot. Early wave profiles remain more grid-sensitive than final mean pressure.
`--piston-wave` writes `.build/piston-wave.json`, comparing numerical conserved cell averages
against an analytical initial piston shock or rarefaction at 0.5 and 0.8 ms, before wall
reflections. Four grids down to 0.0125 m and two CFL limits expose pressure, density,
momentum, energy and wall-work errors. Refinement reduces pressure error, but first-order
wave diffusion remains appreciable; conservation alone is not an accuracy validation.
Adding `--limited` to `--piston-wave` writes `.build/piston-wave-limited.json`, using
minmod primitive reconstruction on the nonuniform tube cells and a two-stage conservative
time update. It preserves gas/wall impulse and work accounting and records accepted steps
and retries. Finest-grid pressure errors roughly halve in the wave study, at extra cost;
the constant-state reference remains the default.
The reconstructed mode now takes a 1% margin below the first-stage limit and retries at
the reported second-stage limit, rather than always halving. `--piston-wave --limited
--halving` reproduces the previous controller in `.build/piston-wave-limited-halving.json`.
The report records which controller was used. Stage-limit selection substantially reduces
compression retries while retaining analytical accuracy and gas/wall budgets.
`--piston-wave --strong --merge-study` compares 100 m/s waves across three merge fractions;
adding `--limited` produces the reconstructed comparison. Each mode writes 48 cases with
analytical errors and gas/wall budgets. `python3 Scripts/summarize-piston-strong.py` reports
pressure accuracy, wall-work error and computational work at CFL 0.2. Refinement improves
the stronger waves, while merge thresholds have a larger effect than in the slow studies.
`--connected-gas` writes `.build/connected-gas.json`, grouping small fractional gas cells
through shared open faces around a static axis-aligned or rotated box. It checks surface
closure and centroid/volume identities before and after grouping, then verifies uniform
gas through a grouped flux update and conservative splitting. Rotated-box cases permit
128–162× larger acoustic timesteps; these are timestep limits, not measured speedups.
Moving geometry, nonuniform transport accuracy and angular-momentum transport remain open.
`--connected-loads` writes `.build/connected-loads.json`, evolving a smooth pressure pulse
around a held box for 0.5 ms. Boundary ownership keeps box loads separate from domain-wall
loads; the report records box impulse, centroid-based angular impulse and complete gas/wall
linear-momentum budgets. Fixed walls do no work. Load predictions remain grid-sensitive,
and gas angular momentum is not audited by this reference.
Adding `--convergence` compares 0.2, 0.1 and 0.05 m grids at CFL 0.2 and 0.1, normalizing
each pulse to 6400 J of excess energy. It writes `.build/connected-loads-convergence.json`;
`python3 Scripts/summarize-connected-loads.py` reports spatial and timestep load differences.
Peak amplitude is recorded because energy matching changes it. Finer-grid impulse differences
remain appreciable even though timestep differences and conservation residuals are small.

Adding `--volume-average` initializes pressure from positive quadrature over each cell's gas
volume. Full cells use tensor Gauss nodes; cut cells use degree-two tetrahedral quadrature
on disjoint convex gas pieces. This samples gas rather than a potentially solid cell centre.
Combined with `--convergence`, it writes `.build/connected-loads-convergence-volume-average.json`;
pass that path to the summary script to compare with the original point sampling. Energy
matching and gas-volume checks still apply; this changes initialization only.

Adding `--limited` to the held-box study enables weighted least-squares primitive
reconstruction with one-ring extrema limiting at face and wall centroids, and SSPRK2 time
integration. Reconstruction uses gas-volume centroids computed by the quadrature, even
when point pressure initialization is selected. Rank-deficient stencils retain constant
states; failed updates are retried at shorter steps without pressure or density floors.
`swift run -c release rigidboxdemo --connected-loads --convergence --volume-average --limited`
writes `.build/connected-loads-convergence-volume-average-limited.json`. Pass this file to
`Scripts/summarize-connected-loads.py` for the same grid/CFL comparisons.
`python3 Scripts/check-grouped-gas-reference.py` copies the bounded reference sources and
tests into a temporary CPU-only package and verifies them without application or Metal
imports. This is preparation for extraction, not a released ContinuumKit product check.

Adding `--surface-quadrature` samples each body-wall patch with positive degree-two triangle
quadrature. Sample locations enter the reconstruction limiter and CFL calculation; the
same sample impulses update gas momentum and integrate body torque. Domain walls continue
to use their centroids. With the flags above, the report name gains `-surface-quadrature`
before `.json`, and records the patch and evaluation-point counts. Affine pressure force
and torque are checked analytically; nonlinear wall-Riemann traction is still approximate.

`swift run -c release rigidboxdemo --wall-reflection` compares transient wall loads against
an independent normal-shock reflection reference; add `--limited` for grouped reconstruction
and SSPRK2. The reports are `.build/wall-reflection.json` and
`.build/wall-reflection-limited.json`. `python3 Scripts/summarize-wall-reflection.py` compares
both sixteen-case reports (four grids, two CFL settings and Mach 1.2/2 incident shocks).
The reference applies [normal-shock jump relations](https://www.grc.nasa.gov/WWW/k-12/airplane/normal.html)
to an incident and reflected shock, without calling the numerical wall solver. It records
pressure-history error and excess-impulse error at four times, and rejects times after the
opposite boundary can interact with the reflected shock. This planar slip-wall channel
checks transport and wall-load timing; it does not validate oblique cut cells or free bodies.

`--wall-reflection --limited --refined` adds 6.25 and 3.125 mm grids at CFL 0.2, writing
`.build/wall-reflection-limited-refined.json`. Regenerate the ordinary limited report with
the current driver, then run `python3 Scripts/summarize-wall-reflection.py --refined` to
compare all six grids. Reports now include first 10/50/90% pressure-rise times interpolated
from accepted-step mean tractions. Unreached thresholds remain absent; already-exceeded
initial thresholds are zero. These diagnostics distinguish load-arrival bias from numerical
shock smearing. Finer cases retain the original shock strengths and boundary-interaction cutoff.

`swift run -c release rigidboxdemo --moving-reflection` checks a translating planar piston
against a mirrored, Galilean-transformed shock reference. Unshocked gas initially moves
with the piston, avoiding an unrelated initial piston wave. Reports in
`.build/moving-reflection.json` cover four grids, two shock strengths, velocities −20/+20 m/s
and CFL 0.2/0.1. Add `--constant` for `.build/moving-reflection-constant.json`, then run
`python3 Scripts/summarize-moving-reflection.py` to compare pressure-history, impulse and
signed-work errors. The reference predicts `W = v I`. The numerical driver uses the existing
conservative end-cell merge/split tube, now with optional conservative initial profiles
and accepted-interval load observations. This verifies prescribed 1D motion; it does not
enable moving clipped boxes or independently moving objects in ordinary app simulations.

`swift run -c release rigidboxdemo --translating-box-geometry` writes
`.build/translating-box-geometry.json`: an aligned and rotated 0.8 m box translating
through 0.2/0.1 m grids. Plane-intersection events split motion into intervals on which
two-node time quadrature integrates open-face areas, first moments, wall loads and gas
volume. The study checks shared faces, local area/moment closure, swept-volume conservation
and whole-box pressure impulse/torque/work, including wet/dry and transient intersections.
An exact uniform Euler-trace probe supplies gas moving with the box and matching outer
inflow/outflow. It verifies conservation identities without evolving gas states or choosing
states for newly exposed cells. Near-parallel plane triples are rejected; contacts at the
geometry/time tolerances are not certified. Rotation during motion remains subsequent work.

`swift run -c release rigidboxdemo --moving-groups` writes `.build/moving-groups.json`.
Eight short intervals straddle cells becoming wet or dry on aligned/rotated 0.2/0.1 m
grids. Groups cover gas present at any time in the interval and must have at least
0.25 nominal cell volume at both endpoints. Existing gas inventories feed paired
Rusanov and moving-wall fluxes; accepted group packets scatter to final wet members,
with empty final members receiving zero. Prescribed outer reservoirs supply matching
comoving gas and report their inventory exchange. An excessive acoustic timestep is
rejected and the interval geometry rebuilt. Thin corner volumes and face measures
are integrated directly to avoid cancellation. This verifies a single numerical
interval; the sustained driver below extends the constant-state check over a trajectory.

`swift run -c release rigidboxdemo --moving-trajectory --halving` writes
`.build/moving-trajectory-halving.json`. Eight aligned/rotated, 0.2/0.1 m grid and
CFL 0.2/0.1 cases carry accepted gas inventories through a prescribed 0.24 m translation.
Gas and box move together at (300,100,-40) m/s for 0.8 ms, retaining ambient density
and pressure. This stresses repeated grid crossings; the trajectory is prescribed.
Add `--ambient-window` for repeated 64-microsecond crossing windows at the original
(3,1,-0.4) m/s, writing `.build/moving-trajectory-ambient-window-halving.json`.
`python3 Scripts/summarize-moving-trajectory.py` checks both complete matrices, matched
snapshot times, cumulative conservation/positivity, and wet/dry counts against an
independent corner-containment oracle. Rejected trials retain the accepted pose and gas;
roundoff contacts use consistent geometric volume/face predicates. Nonuniform moving-load
accuracy, free-body feedback, rotation and gas angular momentum remain subsequent work.

`swift run -c release rigidboxdemo --moving-entropy` writes `.build/moving-entropy.json`.
A quadratic density profile is advected with the prescribed box while pressure and velocity
remain constant. Degree-two gas quadrature gives exact clipped-cell reference averages,
and an independent whole-domain integral checks their mass. Spatial/time-averaged outer
states drive the numerical reservoirs. Twelve cases cover 0.4/0.2/0.1 m grids, aligned/rotated
boxes and CFL 0.2/0.1. `python3 Scripts/summarize-moving-entropy.py` checks the complete
matrix, budgets, reference integrals and spatial/CFL sensitivity. Density L1 error falls
from about 30% to 18% to 10%, normalized by the imposed excess density mass; CFL halving
changes it by less than 0.27% relative. This exposes first-order spatial diffusion and
group mixing. It tests nonuniform density transport; pressure-load accuracy remains a
separate benchmark.

Add `--limited` to the moving-entropy command for `.build/moving-entropy-limited.json`,
then run `python3 Scripts/summarize-moving-entropy.py --limited` to compare both methods.
Primitive face/wall reconstruction uses old gas-volume centroids and supplied exterior
stencil points. Conservative member reconstruction uses final gas centroids, bounds slopes
and checks Euler positivity while preserving group packets. Density L1 errors fall to
about 2.9%, 1.0–1.1% and 0.3–0.4% on the three grids, with fine-grid newly exposed-cell
density errors around 1%. This mode uses Euler time integration. The same `--limited`
flag applies to moving trajectories; `python3 Scripts/summarize-moving-trajectory.py --limited`
checks their fast and original-speed reports.

Add `--heun` to `--moving-entropy --limited` for a separate two-stage report, and
run `python3 Scripts/summarize-moving-entropy.py --heun` to compare its CFL sensitivity.
The update averages extensive gas inventories and paired wall/reservoir exchanges, checks
both stage limits and splits members only after acceptance. Old/final gas centroids and
exterior stencil states belong to their respective stages; prescribed flux reservoirs keep
the same interval-average states. `--heun` also applies to moving trajectories; run
`python3 Scripts/summarize-moving-trajectory.py --limited --heun` after generating both
halving reports. A local expanding-piston test checks second-order time convergence
independently of clipping and regrouping. Maximum relative L1 change under CFL halving
falls from 5.81% to 0.087% in the twelve density-advection cases. Moving pressure-load
accuracy remains a separate gate.

`swift run -c release rigidboxdemo --moving-pressure` writes `.build/moving-pressure.json`.
`python3 Scripts/summarize-moving-pressure.py` checks twelve known-pressure load cases against
independent box integrals. Positive surface/time quadrature follows the moving wall and
centre of mass through clipping events; it recovers impulse, torque and work to roundoff.
Centroid evaluation loses pressure/lever-arm covariance and temporal variance. This probe
prescribes affine pressure with a quadratic time envelope; it does not evolve gas or validate
a blast. Add `--surface-quadrature` to the moving-entropy or moving-trajectory commands to use
these wall samples in the numerical update. With `--heun`, each sample interpolates the
two stage pressure packets at its actual time; the same correction reaches gas momentum
and energy. Torque uses each sample's position relative to the translating centre of mass.
The corresponding summary scripts accept `--surface-quadrature` (and the trajectory summary
also needs `--limited --heun` for that report). A nonuniform-pressure interval test checks
paired loads.

`swift run -c release rigidboxdemo --moving-loads` writes `.build/moving-loads.json`;
`python3 Scripts/summarize-moving-loads.py` audits it and reports load changes under grid/CFL
refinement. A 6.4 kJ smooth pressure pulse evolves over 200 microseconds around a prescribed
translating box. Positive gas-volume averages and per-grid amplitude normalization match
the initial excess internal energy. Twelve cases cover 0.2/0.1/0.05 m cells, aligned/rotated
boxes and CFL 0.2/0.1. The study reports impulse and angular impulse at four matched times,
positive states and complete gas/reservoir/body budgets. Pressure and velocity departures
are physical responses, not errors against an exact solution. The finest grid is a numerical
comparison; this is not blast validation or free-body motion.

`swift run -c release rigidboxdemo --initial-wall-traces` writes `.build/initial-wall-traces.json`.
`python3 Scripts/summarize-initial-wall-traces.py` compares known supplied pressure, constant
traces and the actual limited traces against independent integrals over the uncut box faces.
The initial Gaussian load exposes substantial coarse-grid reconstruction error before any
gas update; supplied-pressure quadrature errors are much smaller. Tiny-duration halving
checks the instantaneous limit. This diagnoses initial traces, not the evolved load history.

Add `--decompose` to write `.build/initial-wall-traces-decomposition.json`, then run
`python3 Scripts/summarize-initial-wall-traces.py --decompose`. Nine diagnostic comparisons
retain or replace group averages, fitted gradients and bounds, including an analytic
Gaussian gradient. They identify gradient accuracy and unresolved local curvature as
further gates; removing the limiter or substituting centroid pressure worsens coarse loads.
These read-only comparisons do not change gas inventories or enable alternative transport
policies, and their differences are not an additive error budget.

`swift run -c release rigidboxdemo --initial-wall-traces --volume-fit` writes
`.build/initial-wall-traces-volume-fit.json`; audit it with
`python3 Scripts/summarize-initial-wall-traces.py --volume-fit`. Three raw diagnostic fits
share a two-ring stencil and distance weights: linear, quadratic treating averages as
centroid values, and quadratic using actual gas-volume second moments. Two further modes
bound the last polynomial at wall samples or at wall/face/volume control points by scaling
its deviation from the group average. Both retain that average, with direct volume-sample
audits. Bounds hold at the audited points; they do not establish bounds everywhere between
them. The study reports the resulting load errors and limiter factors. All five modes
remain outside gas evolution.

Add `--stencil-sweep` to `--initial-wall-traces` to write
`.build/initial-wall-traces-stencil-sweep.json`. Audit it with
`python3 Scripts/summarize-initial-wall-traces.py --stencil-sweep`. The 36 cases cover
one-, two- and three-ring connected group stencils, rotations 0/0.1/0.23/0.4 radians and
the same three grids. Reported rank fallbacks, local pressure errors and load errors
show sensitivity to stencil extent; matched initial packets and baseline loads stay fixed.

`swift run -c release rigidboxdemo --moving-loads --conserved-quadratic` runs the experimental
transport with quadratic fits of all five conserved densities and writes
`.build/moving-loads-conserved.json`. Audit the complete matrix with
`python3 Scripts/summarize-moving-loads.py --conserved-quadratic`. The fit retains group
averages, uses distinct old/final gas-volume moments, and applies a common component/EOS
bound at volume, face and wall samples. Accepted gas inventories are never floored.

The same fit is available in the independent stationary shock benchmark through
`swift run -c release rigidboxdemo --wall-reflection --conserved-quadratic`, producing
`.build/wall-reflection-conserved.json`.
`python3 Scripts/summarize-wall-reflection.py --conserved` compares it with the existing
constant and limited reports. These options
leave the existing transport defaults in place; the full load/shock audits determine
accuracy and cost before broader use.

## Headline results

Measured on an Apple M4 Max (32-core GPU, 36 GB).

| Case                                                        | Speed                        |
|-------------------------------------------------------------|------------------------------|
| Air blast, street scene, 8.4 million cells of 0.25 m        | 17× slower than real time    |
| Concrete building, 225,000 elements, coupled to the air     | 70× slower                   |
| The same building as 3,700 shell elements                   | 7× slower (2× on 0.5 m air)  |
| Three-storey building as shells and beams                   | 31× slower (17× on 0.5 m air) |
| The building with its front wall solid, the rest shells     | 24× slower                   |
| Three-storey frame with masonry cladding, 160,000 elements  | 60× slower                   |
| Two-storey frame collapsing over 3 s                        | 11× slower                   |
| Eight-storey frame collapsing over 4 s, 31,000 shells and beams, 0.5 m air | 21× slower    |
| Twelve-storey tower collapsing over 4 s, 95,000 shells and beams, 0.5 m air | 56× slower   |

Seven comparisons with the outside world, all in the [validation notes](docs/validation.md):

- **Blast loads.** On air cells of 0.25 m or finer, the impulse on a rigid wall is within 6% of
  the Kingery–Bulmash curves beyond 1.5 m/kg^(1/3), and within 5% everywhere checked on
  0.125 m cells. Peak pressures are under-resolved, more so close to the charge; refining the
  air near the shock gives the peaks of a grid twice as fine at a sixth to a third of its cost,
  or, in two levels, of one four times as fine at a twelfth to a fourth.
  The incident impulse is 13–22% low by default, or within 6% with afterburning and hot air
  switched on, which also bring the gas pressure in a closed room within 8% of the US design
  manual's.
- **Structural response.** Against a published blast test of a reinforced-concrete slab, the
  model predicts peak deflections of 114, 113, 121 and 124 mm with 4, 8, 16 and 32 elements
  through the thickness, where 108 mm was measured, with no material constant fitted to the test, and
  follows the record within 4–8 mm root-mean-square. The rebound after it is larger than the
  measured one, and the result is sensitive to the load, to how the supports are modelled and
  to the strain-rate laws. Shell elements give 135 mm in about a second.
- **Beam bent to failure.** A reinforced beam with no stirrups, loaded slowly in four-point
  bending, carries 98–99% of its measured peak moment on two meshes, with nothing fitted; it
  fails at 57 mm on one, and holds to 60 mm on the other, against 42 mm measured.
- **Beam failing in shear.** A beam without stirrups fails suddenly in diagonal tension, as
  the test beam did, at 11–15% above the measured load on fine meshes; on coarse ones (twelve
  elements through the depth) it is a third too strong.
- **Beams struck by a falling weight.** Seven drop-weight impacts on beams that differ only in
  their stirrups: with stirrups, the peaks are within 12–24% under the light drops and within
  5% under the heavy ones, which leave them nearly as far down as the tests' did; the beam without
  stirrups is broken by the heavy drop, as in the test, and damaged by the light one, which it
  survived. Ando et al.'s beams without stirrups, struck at rising speeds, peak within 15% up
  to 3 m/s and 15% on average beyond on one mesh, but go too far on a finer one.
- **Slabs under close-in charges.** Full-scale slabs under 2–15 kg hung 0.5 and 1 m above
  them: the impulse under the charge is 86–95% of the empirical curves' on fine cells (and
  within 8% from 0.3 m/kg^(1/3) on a rigid surface), and light charges
  leave the slab undamaged as in the tests, but the heavy ones leave it a third to a half as far down,
  barely spalled and not punched through, where the tests' slabs spalled and were holed.
- **Internal explosion.** In a full-scale reinforced concrete chamber loaded by 200 kg of TNT,
  the peak pressures on the walls are 0.9 to 1.6 times those measured. With the structure as
  built, so far as the paper says, the roof is about twice as stiff as the paper's own model
  and springs back to 7 mm where 95 mm was measured; its joints stay whole where the test's
  were cut through. The test exposed missing mechanisms in the concrete model, errors in it,
  in contact and in the time step, and an error in the test's own set-up, all now dealt with.

Collapse and debris have not been compared with anything.

## Documentation

| Document                                    | Contents                                                        |
|---------------------------------------------|-----------------------------------------------------------------|
| [Air-blast model](docs/air-blast-model.md)  | Equations, numerical scheme, charge model, boundaries           |
| [Structural model](docs/structural-model.md) | Elements, time stepping, contact, coupling to the air           |
| [Concrete model](docs/concrete-model.md)    | Cracking, crushing, shear, reinforcement, strain-rate effects   |
| [Shell model](docs/shell-model.md)          | Shells for walls and slabs, beams for columns                   |
| [Validation](docs/validation.md)            | The slab test, empirical blast curves, verification tests       |
| [Performance](docs/performance.md)          | Benchmarks and where the time goes                              |
| [Street interactions](docs/street-interaction.md) | Matched neighbourhood comparisons, spatial exposure maps and resolution sensitivity |
| [Building envelopes](docs/building-envelopes.md) | Stationary exposure-only buildings, surface loading, matched detailed references and scaling through 64 buildings |
| [Distributed computing](docs/distributed-computing.md) | Whether one run could use several Macs' GPUs, and when it would pay |
| [Fragments](docs/fragments.md) | A cased charge's fragments flown one way through the blast and drawn over it, here or on another Mac |
| [Thermal radiation](docs/thermal-radiation.md) | The fireball's radiant heat on the ground and the scene's faces, frame by frame, from the air model's hot gas, drawn over the blast, here or on another Mac |
| [The fireball's rise and cloud](docs/fireball-rise.md) | The hot gas left after the blast, followed as a rising, entraining cloud that spreads once it stops, carried by the wind, for minutes after |
| [Ground shock](docs/ground-shock.md) | An illustrative estimate of the ground's shaking away from the charge, or a layered soil column, fed the overpressure on the ground |
| [USD export](docs/usd-export.md) | Writing a run over time as USD and OpenVDB volumes, for rendering in Blender and elsewhere |
| [Ray tracing](docs/ray-tracing.md) | Notes for other projects: adopting Metal ray tracing for precomputed simulations |
| [Roadmap](docs/roadmap.md)                  | Known limitations in order of importance, and planned work      |
| [RoomCAD](https://github.com/emmettl/RoomCAD)   | Independent room acoustics app, impulse responses and convolution reverb   |
| [Save files](docs/save-files.md)            | Versioned project packages, assets and persisted settings       |
| [Data wanted](docs/data-wanted.md)          | Sources that need fetching by hand, and what each would add     |
| [Releasing](docs/releasing.md)              | Signed, notarized builds                                        |
| [Continuous integration](docs/continuous-integration.md) | The Mac mini runner, nightly validation and benchmarks |

Each model document lists its sources, its limitations and the work that would address them.

## Code layout

| Target        | Contents                                                             |
|---------------|----------------------------------------------------------------------|
| `SceneModel` / `SceneView` | Shared geometry and camera in [SimulationKit](Packages/SimulationKit/README.md) |
| `BlastCore`   | Air and structural solvers, materials, scenarios, benchmark data     |
| `BlastRender` | Scene renderer, orbit camera, offscreen snapshots                    |
| `BombCAD`     | SwiftUI app with the layout editor                                   |
| `blastbench`  | Command-line throughput, validation and snapshot tool                |

## Licence

MIT; see [LICENSE](LICENSE).
