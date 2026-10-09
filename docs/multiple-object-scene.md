# Multiple object scene architecture

BombCAD needs persistent scene objects whose identity and authored geometry remain stable
when their simulation representation changes. This proposal defines the first step toward
the [long-term vision](long-term-vision.md): multiple independently owned obstacles and
structures in one conventional blast scene, with explicit boundaries between BombCAD and
ContinuumKit.

The initial implementation should preserve existing single-structure results and import
editing behaviour. New inter-object contact, moving-component connections, thermal models
and large-area response approximations are separate capabilities. This proposal defines
requirements and ownership; the conceptual names below are not committed public APIs.

## Implemented ownership foundation

The first stage is implemented in BombCAD. `Scenario.objects` owns local fixed blocks and
the existing deformable body as `SceneObject` values. Objects have stable IDs and names;
structural solids, openings and supports have references containing their owning object ID,
component ID and kind. Editor rows, geometry/property bindings and component removal resolve
these references rather than retaining array positions. Fixed blocks can be duplicated from
their context menu, with a fresh ID. Undo restores the original identities.

`Scenario.boxes` and `Scenario.structure` remain compatibility adapters to the existing
solver. That stage preserved the single-body solver path. Attached rigid imports
retain their existing instance identities and preview path; they are not duplicated into
local fixed objects. The deformable object's source reference survives regeneration and
detachment. A resampled generated region can acquire a new component ID when its geometry
changes topology; source-part identity remains the stable reference across sampling grids.

The persisted geometry keeps its existing shape, with a versioned `objectOwnership` record
carrying names, IDs, source ownership and object order. Project scene encoding advances to
version 3; versions 1 and 2 and flat legacy layouts remain readable. Presets and legacy
inputs receive deterministic IDs scoped to the scene, while authored additions and copies
receive fresh UUIDs. No ContinuumKit extraction or release is needed for this stage.

Saved-run fingerprints exclude ownership metadata and retain the original numerical input
encoding. Historical solver provenance is preserved. Verification covers legacy presets,
project and historical-run migration, malformed ownership, duplicate geometry, stale
references, undo/redo, independent import preservation and exact GPU air-field parity.
The native editor has also been checked for block duplication, deletion, undo and saving.

## Implemented shared air mechanics

A scene can now contain up to sixteen independently owned deformable objects. Each
`StructuralBody` compiles its own solid, shell or mixed mechanics, including its material
table, reinforcement, supports and mesh sizes. The bodies read one air solution and cover
the same fluid interval with substeps respecting their own stability limits. The parent
bounds the air step by the smallest structural stability limit. Legacy single-body accessors
remain available; multi-body code addresses a runtime body by its object ID.

Boundary contributions are composed before updating the air mask. Each body's coarse and
fine occupancy is evaluated against its own mesh-dependent threshold, then the qualifying
cells are combined. Moving-wall velocities retain the contributing body's mean velocity,
with fixed-point rounding in the composition pass. A body cannot clear another body's mask.
All bodies' loose-debris areas are collected before any body's substeps, and their summed
momentum and energy exchange is returned to the air once. Runtime ordering is deterministic
by object ID and independent of the editor's object order.

**Add Independent Structure** creates another editable body. **Editing structure** selects
the owner for materials, element formulation, openings, supports and member edits. Changing
between solid and shell formulations retains each object's preferred solid element size.
Deformable imports create separate bodies; replacing, resampling or detaching a source
targets its owner. Rendering and camera framing include every body.

Current summaries and saved runs retain per-object response histories. The existing overall
history records the largest displacement across the intact structures; summary element
counts are summed and maximum damage/displacement are maxima. CSV adds separately identified
object series. USD combines the visible surfaces while preserving a per-face owner index and
stable object ID/name tables.

Multi-body scenes use project scene encoding version 4, with the additional models and their
ownership stored in `additionalStructures`. Single-body scenes continue to use version 3;
versions 1 and 2 remain readable. Multi-body saved-run records use version 2. The first
shared-air implementation used `blast-solver-3`; local coupling uses `blast-solver-4`.
Historical records retain their provenance. Single-body records and numerical fingerprints
retain their previous semantics. No ContinuumKit package changes are required.

Inter-object contact and moving-component connections remain unsupported. Initial touching
or intersecting body envelopes are rejected. During a run, GPU checks collect node envelopes
at the start of the fluid step and after mechanical substeps, including loose nodes and
conservative section/debris radii. They also detect overlapping resolved boundary cells.
A detected interaction stops further steps and prevents a completed run capture.
Envelope checks are conservative: a stop identifies a potentially unsupported interaction,
not a prediction that detailed surfaces have collided. Paths through the same space at
different times can also trigger this conservative screen; it applies no contact force.
Contact between parts of one existing mixed body remains supported.

Coarse coupling can now use compact pages of four by four by four air cells. Occupancy,
wall velocity, debris area and momentum/energy exchange share a world-tile mapping.
Automatic selection retains dense storage where its buffers are smaller; a single body
retains its dense path. The bounded pool reserves twice a conservative initial padded
footprint. Programmatic callers can set a tile capacity in `SolverConfiguration`.

Allocation follows current and swept node envelopes with four metres of horizontal and
three metres of vertical padding. Pages remain available for reopening vacated outlines,
including after restart; replacing the body set frees the pool. Storage exhaustion or
motion outside allocated coverage stops the run and prevents completed-run capture.
Frozen-air mechanics continue without allocating new coupling pages.

The air grid and refinement pool remain separate allocations. Memory reporting includes
the map, pool, all structures and refinement composition storage. See the
[scaling benchmark and neighborhood example](multi-object-scaling.md).

Verification includes differently meshed stationary bodies against equivalent fixed
geometry, coarse and refined air, exact invariance under object reorder for solid and shell
responses, independent prescribed-load mechanics, interaction stopping, mixed-body surface
export, renderer pixels, source isolation, per-object capture and package round trips.
The native editor was checked by adding a second structure, changing its material,
switching back to the first structure and saving both in a version-4 project.
These checks establish numerical behaviour; no measured multi-building experiment has been
reproduced.

The [street-interaction study](street-interaction.md) compares isolated, paired and street
layouts with matched sources, physical observation points and structural meshes. Spatial
recording and diagnostic stage profiling remain in BlastCore; this introduces no new
ContinuumKit contracts or release.

## Implemented stationary envelopes

Local authored structures can be converted into stationary `BuildingEnvelope` objects with
their name, object ID, wall/roof solids and openings retained. They use the fixed-obstacle
air path and allocate no mechanics or moving-boundary state. Projects containing envelopes
use scene encoding version 6; versions 3 and 4 remain unchanged for earlier representations,
and version 5 remains the footing/turned-joint encoding. Prototype envelope version-5 packages
migrate without losing geometry or ownership.
Undo restores the original structure. Source-owned imports retain their import workflow.

The [building-envelope study](building-envelopes.md) checks surface pressure, signed and
positive impulse, and shared-flow maps against fully pinned solid-element references.
Its fourteen representation comparisons agree exactly and its computational scaling runs
reach sixty-four envelopes. Shell-reference diagnostics retain differences at junctions
and openings instead of treating their changed boundaries as equivalent geometry.
Approximation rules, loading diagnostics and these fixtures remain in BombCAD.

## Implemented shared query extraction

[ContinuumKit PR #7](https://github.com/emmettl/ContinuumKit/pull/7) adds a bounded
`SceneModel.Box.intersection` contract for ray and segment queries. It returns a closed
parameter interval with explicit clipping and a caller-selected parallel-component
tolerance. It uses metre coordinates in one frame and needs no renderer or application
object model. The library retains independent analytic, boundary, transform and
face-plane-oracle tests plus a fetched Git-consumer check.

BombCAD uses that query for source picking and one-way fragment
intersections. Picking retains its historical strictly-below `1e-8` threshold and
fragments their `1e-12` segment threshold. Stationary-particle contact, object ownership,
openings, selection and impact interpretation remain in BlastCore. Additional adapter
tests preserve the exact threshold boundary, closed-face and stationary-segment cases.
No mechanical coupling or numerical solver moves in this extraction.

The application pins the independently verified `0.1.0-alpha.4` release exactly and
commits its resolved revision. The [adoption record](continuumkit-adoption.md) links
the core release verification and describes application compatibility checks.

## Constraints at the planning baseline

- `Scenario` stores static `boxes`, optional imported models, experimental `rigidObjects`
  and one optional `structure`. These collections do not form a common object model.
- `ImportedModel` already has a UUID, source-part identities, placement and regeneration
  state. Deformable regeneration and installation operate on the single structure.
- `StructureModel` owns regions, openings, materials, reinforcement and supports. Some
  assignments are arrays indexed by region; source ownership uses imported instance and
  source-part IDs.
- `Scenario.load` installs one structural model. Independent rigid objects are saved inputs
  for an experimental driver and are not generally simulated by ordinary scene loading.
- Project validation, duration defaults and editor workflows inspect `scenario.structure`.
- ContinuumKit supplies geometry bounds and grids, camera helpers, rendering, import and
  document containers. BombCAD pins its CAD release at `0.1.0-alpha.1`; numerical physics
  remains application-owned.

An array of structures alone would leave import ownership, editing references, result
attribution and runtime state ambiguous. These contracts should be settled together.

## Initial scene requirements

### Persistent identity and ownership

Each scene object has a stable ID, a user-visible name and owned geometry. IDs survive
editing, save/reopen, regeneration and simulation. Duplicating an object creates a new ID;
reordering objects does not change identity or references.

Components and local regions need identity wherever edits or results refer to them. A
reference must identify both its owning object and its local component. Array positions,
renderer pick numbers and GPU indices are transient implementation details.

Imported instance and source-part IDs remain distinct from generated region IDs. A region
can retain its source reference after detachment. Regeneration of one imported object must
not replace another object's geometry or discard independent edits.

### Geometry and placement

Authored geometry, source provenance and simulation geometry are separate records.
Geometry has an explicit coordinate frame; the initial scene uses metres and z up.
Placement and bounds must be well defined even when rendering and simulation use different
representations.

The first implementation may retain the current axis-aligned simulation geometry and
supported import transforms. Arbitrary object rotation must not be accepted as a physical
capability until conversion and boundary handling support it. A richer visual mesh cannot
silently imply that the solver resolves its features.

### Simulation representation

An object's representation is an explicit run input. The first supported choices are a
fixed obstacle and a detailed deformable structure using existing supported formulations.
Experimental moving rigid bodies remain explicitly experimental until their scene
integration is verified. Simplified building response is a later model, not an inert
placeholder that appears to simulate.

The object retains identity when its representation is edited. Representation-specific
settings belong to that representation rather than to a universal material record.
Changing representation must preserve authored geometry and report any assignments that
cannot be carried over.

### Multiple structures and interactions

Several deformable objects can share one air domain while retaining separate structural
settings, material tables, supports and result attribution. Air resolution and structural
element sizes remain explicit inputs; the scene must not silently force all bodies onto
one structural mesh size.

Nearby objects interact through the common air solution. They are not automatically bonded
because their bounds touch. The initial capability excludes inter-object contact and
connections between moving objects. Construction and run validation must reject unsupported
initial overlaps and configurations requiring those interactions.

If independently owned bodies collide during a run, that run has left the supported
regime. Detect and report this limitation where supported; do not describe the resulting
motion as a verified collision response. A later contact implementation needs its own
verification before removing the restriction.

### Editing and persistence

Selection, materials, openings, supports, delete, duplicate and undo target an owning
object explicitly. Openings affect their own structure; a support region does not attach
another object by accidental spatial overlap. Editing or removing one object cannot
invalidate another object's array-index bindings.

The project schema belongs to BombCAD. Introduce a versioned migration from existing
`boxes`, imports and the single `structure`, preserving their current effective geometry,
ownership, ordering rules and physical settings. Define how attached rigid import previews
are represented so they are not counted twice. Keep existing experimental rigid-object
semantics rather than promoting them through migration.

Assign missing IDs once during migration and persist them. New object scenes require an
encoding version that older readers reject instead of silently dropping extra objects.
Saved legacy runs retain their original inputs and provenance; conversion must not relabel
old results as outputs of the new solver.

### Runtime and results

Keep authored objects separate from compiled solver state. A run has an immutable input
snapshot and mappings from object/component IDs to its numerical and rendering indices.
These mappings are regenerated when needed, not used as durable document identity.

The combined air-boundary representation must have unambiguous ownership and compose
contributions from all participating objects. Updating one body must not erase another
body's boundary contribution. Loads and motion must be attributed to the correct body;
shared air fields must not duplicate momentum or energy exchange.

Per-object histories and scene observations identify their quantity, units, location,
sampling convention and model provenance. Existing point gauges continue to work.
Aggregate deflection or damage summaries must state their aggregation rule rather than
silently replacing per-object results.

## Minimum ContinuumKit contracts

The scene schema, IDs, editing policy and run coordinator remain in BombCAD. The following
are candidate shared contracts, to be added only when an implemented consumer requires
them and independent verification is ready.

| Contract | Minimum responsibility | Boundary |
| --- | --- | --- |
| Geometry placement | Explicit local/world point and direction conversion, bounds and units | No building semantics or simulation mode selection |
| Boundary geometry | Model geometry usable without constructing a renderer; explicit normals and feature references | Do not treat `SceneRender.SceneGeometry` colour/pick vertices as the physics contract |
| Spatial queries | Deterministic containment, intersection and nearest-hit behaviour with declared tolerances | Object ownership and overlap policy remain in BombCAD |
| Mechanical body state | A verified body model's pose, velocity, inertia and force/work conventions | Extract only with the actual mechanics implementation and independent cases |
| Boundary exchange | Defined pressure/traction, motion, orientation, time and exchanged work for a specific supported coupling | Begin with existing bounded reference cases; no universal coupling framework |

Existing `Box` and `Grid` should be reused wherever they suffice. A contract that is only
needed to connect BombCAD's current solvers can start as a BlastCore adapter. Promotion to
ContinuumKit follows its extraction gates, including a clean fetched consumer and
application parity checks. One independently useful consumer is sufficient; speculative
reuse is not.

No new mechanics module is required merely to introduce object identity and multiple
authored structures. Sharing a moving-body or boundary implementation is a later,
independently reviewable extraction.

## Implementation sequence and acceptance

### Object ownership and legacy compatibility

Introduce the BombCAD object schema, stable references and legacy conversion. Keep a
single-object adapter to existing solver behaviour while updating selection, import
regeneration and project validation.

Acceptance: legacy scenes retain effective inputs; save/reopen retains IDs and settings;
duplication has distinct identity; reorder and undo preserve references; import regeneration
changes only its owner; unsupported representations and stale references fail explicitly.

### Multiple fixed objects

Use independently owned fixed objects to produce the existing combined static air mask.
This establishes geometry composition and selection without new mechanics.

Acceptance: an equivalent legacy block scene has unchanged air inputs and results; attached
imports are included once; deleting or resampling one object preserves all other objects.

### Multiple deformable objects

Add separately owned structural runtime state and a coordinator for their shared air
boundary and loading. Choose batching or separate solver instances based on measured cost
and correctness, rather than making GPU allocation layout part of the scene schema.

Acceptance: the one-body path preserves current results within documented tolerances;
isolated prescribed-load tests remain independent of another body's presence; a stationary
multi-body air-boundary case agrees with equivalent fixed geometry; coupled exchange has
explicit accounting; unsupported contact configurations are reported; histories remain
attributed correctly after editor reorder.

### Shared extraction when ready

Extract only the geometry or model contracts demonstrated by the preceding work. Each
component needs units, frames, assumptions, independent references and relevant refinement
checks. Verify it through ContinuumKit's clean Git consumer, release deliberately and pin
BombCAD to the tested version. Keep extraction separate from numerical changes.

## Decisions before implementation

The first implementation proposal should settle object/component ID granularity, the exact
legacy migration rules, source-to-object ownership and unsupported overlap handling. It
should also measure whether multiple structural instances fit the current resource and
dispatch design.

Keep thermal physics, deformable terrain, general moving-body contact and reusable building
response models as separate proposals. Their future presence should not require changing
the meaning of a persistent scene object.
