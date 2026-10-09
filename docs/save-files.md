# Project save files

Implemented foundation, October 2026. BombCAD saves `.bombcad` document packages. A package
is a directory shown as a single document by macOS; its files can also be inspected with
Show Package Contents. Saving captures inputs and view preferences, not the running GPU state.

## Version 1

```text
Example.bombcad/
  manifest.json
  scene.json
  settings.json
  fragments.json         # Optional: a cased charge's fragments to fly alongside each run
  view.json              # Optional
  assets/                # Optional embedded assets
  results/               # Optional retained files; no simulation results are generated here yet
```

The Foundation-only `DocumentKit` target in ContinuumKit handles the container. It depends on
neither BlastCore nor either app. BombCAD's `ProjectDocument` owns its scene and settings codecs
and uses SwiftUI DocumentGroup/FileDocument for coordinated saves, autosave, document windows and
close/quit handling. FileDocument supports directory
wrappers as document packages; see Apple's [FileDocument](https://developer.apple.com/documentation/swiftui/filedocument)
and [DocumentGroup](https://developer.apple.com/documentation/swiftui/documentgroup) documentation.

The manifest contains:

| Key | Meaning |
|---|---|
| `format` | `dev.simulationkit.project` |
| `schemaVersion` | Integer `1`, independent of the application release |
| `documentID` | UUID retained on save/reopen and scene replacement; New Project starts a new identity |
| `documentType` | `bombcad`; RoomCAD documents use `roomcad` and their own codec ([RoomCAD documents](https://github.com/emmettl/RoomCAD/blob/main/docs/roomcad-app.md#document-format)) |
| `producer` | Producer name, currently `BombCAD` |
| `assets` | Array of asset records containing a UUID `id`, relative `path` and lowercase hex `sha256` |

Every file under `assets/` must have a manifest entry. Assets are embedded and checksum-checked
on load, so reading them never requires the original external path. Imported meshes are stored
as versioned JSON assets at `assets/<id>.mesh.json`. Identical sources share one asset;
content-derived IDs stay stable across repeated saves, and existing asset IDs are retained.

`scene.json` has format `dev.bombcad.scene`. Single-body saves use encoding version 3, which requires
durable object/component ownership; multiple-body saves use version 4 and scenes containing
stationary building envelopes use version 6. Version 5 supports footings and turned support
joints; prototype envelope version-5 packages migrate on save. Versions 1 and 2 remain readable; version 2 originally
introduced finite support-region laws. Older readers reject version 3 rather than discard
ownership; readers predating multi-body support reject version 4. Its `scenario` contains
structural geometry, openings, materials and reinforcement in metres, z up. Its `imports`
contains instance IDs, source asset references, names, transforms, behavior, attachment status,
part material assignments and retained previews. Source triangles are not duplicated per instance.

The versioned `scenario.objectOwnership` record stores fixed-block and structural-object IDs
and names, structural component IDs, an optional retained source reference and object order.
It accompanies the existing geometry without duplicating numerical inputs. Legacy inputs
acquire deterministic scene-scoped identities; subsequent additions and duplicates use
fresh UUIDs. IDs persist on save/reopen and undo. Invalid counts, duplicate IDs, stale source
references and unsupported ownership versions are rejected. This is the
[multiple-object ownership foundation](multiple-object-scene.md#implemented-ownership-foundation);
up to sixteen independent deformable objects are supported. `scenario.structure` and its
ownership remain the first body for compatibility. `scenario.additionalStructures` carries
the other models with their own ownership; the recorded object order includes them all.
Ownership may also retain a preferred solid element size for an object's formulation switch.

Saved-run numerical fingerprints omit this ownership record, preserving compatibility with
historical inputs and solver provenance.

Multi-body saved-run records use encoding version 2 and `blast-solver-4` provenance for
local coupling. Historical `blast-solver-3` records remain readable without relabelling. Their
`bodyResponses` entries carry object IDs, names and individual histories alongside the
overall structural history. Missing/duplicate response owners and incompatible record
versions are rejected. Existing single-body records retain their encoding and provenance.

Saved runs containing compact `envelopeExposure` summaries use record encoding version 3,
with owner IDs/names, window, air spacing, resolved surface area, peak pressure, positive
loading and signed vector loads. Validation checks ownership, units/grid, finite values,
consistent surface counts/areas and the absence of invalid faces. Earlier records remain readable; records without these summaries
retain version 1 or 2. Full per-face arrays are separate JSON exports. Surface diagnostics
are excluded from input fingerprints and retain the existing blast solver provenance.

Mesh assets have format `dev.simulationkit.source-mesh`, `encodingVersion: 1` and
`coordinateSpace: source`. They retain original coordinates and face labels, plus a part identity
table checked against the reconstructed mesh. Scale, up-axis conversion and placement are applied
once by the importer. Integer part IDs belong to their source asset; they are not voxel IDs.
Original OBJ/STL files are unnecessary for reopening the project.

The optional `scenario.rigidObjects` array stores experimental independent rigid-object inputs.
Older scenarios omit it and decode with no objects; an explicitly empty array also remains
empty on save/reopen. Each definition retains a UUID `id`, `name`, `shape`, `position`,
`orientation`, `mass`, `centreOfMass`, optional `inertia`, `staticFriction` and `slidingFriction`.
Currently `shape` supports only a box, encoded as `{"box":{"size":[x,y,z]}}` with full dimensions
in metres. Position refers to its geometric centre in world coordinates; orientation is a
body-to-world unit quaternion `[x,y,z,w]`. Centre of mass is a local offset from the geometric
centre. Inertia gives principal moments about the centre of mass in kg m², with axes aligned
to the box axes. Omitted inertia assumes a uniform centred box; a nonzero offset requires
explicit inertia. Friction must satisfy static ≥ sliding ≥ 0. Invalid geometry, mass, pose,
inertia, friction or initial ground penetration is rejected during decoding.

The app's renderer and normal blast-solver loading do not consume rigid objects. An explicit
standalone experimental driver can couple one box to uniform or refined ideal-gas air; it is not enabled
by opening a saved scenario. These inputs are separate from static scenery boxes and imported models marked `rigid`, which
remain stationary obstacles. Runtime motion is not saved; conversion starts a fresh body at
rest. See the [freestanding-object roadmap](roadmap.md#freestanding-objects-and-supports).

Each preview carries a provenance key containing the source checksum, transform, cell size,
domain size and sampler version. Loading rejects mismatched keys. Resolution changes use the
importer's normal resampling path and preserve part assignments. Detached scene boxes and the
full structural model, including supports, openings and reinforcement, remain authoritative;
opening a document never silently regenerates them from the source.

`fragments.json`, when present, holds the Run tab's fragment description (see
[Fragments](fragments.md#in-the-app)); fields left out take their defaults. `groundShock.json`,
when present, holds the Run tab's ground points and soil (see
[Ground shock](ground-shock.md#in-the-app)), likewise.

`settings.json` stores resolution (`coarse`, `medium`, `fine`), `detailedCharge`, `sharpShocks`,
`solidElementSize` (the size restored when switching from shells to solids), and `duration`
in seconds. The scenario itself holds the charge, atmosphere and structural settings.

`view.json` stores camera target, distance, azimuth, elevation and field of view, plus display
mode, scales, decades, wave visibility/opacity and charge visibility. It does not store the
current selection, undo stack, elapsed simulation time or GPU state. Opening restores a
fresh run and clears undo across documents.

## Open and save behaviour

- New/Open use the native document workflow. Each project has its own window and simulation.
  Open Project accepts `.bombcad`; Import Layout JSON in the More menu opens a separate new,
  untitled project. Legacy JSON geometry gains object ownership when decoded.
  JSON originals are never the target of autosave.
  Missing required layout JSON fields, incorrect value types and null values are reported with
  their field paths; malformed JSON is reported as a syntax error. These diagnostics do not
  change which layouts are accepted.
- Save Project and Command-S save to the document's current location, asking for a name and
  location on the first save. Save As is in the More menu. Native File-menu commands provide
  New, Open, recent documents, Duplicate and Revert where supported by macOS.
- DocumentGroup tracks snapshots of geometry, numerical settings, duration, camera and display
  preferences. Time, gauge histories, GPU state, selection and playback pacing do not dirty a
  document. New/opened projects start clean; named projects autosave edits through the system.
- Closing/quitting a changed untitled document asks whether to save, discard or cancel. Named
  projects normally save automatically instead of prompting after each edit; errors are handled
  by the native document controller. This follows macOS document conventions rather than
  maintaining a second timer or custom close/quit alert.
- When a document editor disappears, its live run pauses and any sweep is cancelled. Other
  document windows continue independently. A paused editor can resume with Run if it returns;
  pausing does not change the saved project inputs. An already submitted GPU batch may finish.
- The document retains its ID and embedded assets across scene replacement and resaving. Retained
  assets remain available for undo. New documents/windows receive independent identities.
- Export Layout JSON remains available for scene interchange. It omits run/view settings.
- Unsupported schema versions and other applications' project types are rejected before
  changing the current model. Known version 1 payloads must include scene and run settings;
  absent view settings use scenario framing and normal display defaults.
- Container validation rejects invalid relative paths, symbolic links, conflicting file/directory
  paths, case/Unicode collisions, missing/corrupt assets and oversized inputs. Limits are
  64 MiB per file, 256 MiB total and 4,096 entries. The URL reader checks sizes before loading.
- BombCAD validates numerical settings and bounds its saved air grid to 128 million cells
  before constructing Grid; the existing GPU memory-budget check still applies during loading.

The application uses the system document lifecycle for writing rather than implementing in-place
directory updates. Tests also exercise Foundation's atomic wrapper replacement and confirm
that validation failures leave the previous saved document readable. This is not a test of
power-loss durability or a simulation checkpoint facility.

## Application defaults

BombCAD → Settings (Command-comma) sets the initial grid, afterburning/hot-air option and shock
refinement for newly created projects. These preferences are stored locally in UserDefaults,
not added to the project format. Changing defaults leaves current and saved projects untouched;
new projects capture those choices as their own numerical settings.

The Settings window also selects the starting playback speed for new windows. Playback speed
is a presentation preference rather than a saved simulation input, and can still be changed in
each window's Run tab. Restore Defaults returns the app defaults to medium grid, both numerical
options off, and 100× slow motion.

## Remaining work

Importer source assets, part assignments, transforms, attachment status and detached edits now
round-trip through the package. The scene codec remains BombCAD-specific for 0.2; extract a
shared scene contract when RoomCAD has a concrete consumer. Measure large-mesh storage before
introducing a binary encoding. Optional results need input hashes and provenance before the app
offers reuse. WAV impulse responses remain standalone exports, not project documents.

## Checks

```sh
swift test --package-path /path/to/ContinuumKit
swift test --filter 'AppPreferencesTests|ProjectSessionTests|ProjectDocumentTests|ImportedProjectTests|SimulationModelTests'
```

These cover container integrity, moved files, atomic replacement, asset preservation, every
built-in scene, embedded imports, stable source identities, detached edits, part assignments,
settings/view restoration, independent windows, revert, simulation progress not
marking projects changed, and app-model regressions. Native UI checks cover New, close/cancel,
Save, Save As and autosave of numerical and display edits.
