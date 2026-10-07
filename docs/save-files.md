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
  view.json              # Optional
  assets/                # Optional embedded assets
  results/               # Optional retained files; no simulation results are generated here yet
```

The Foundation-only `DocumentKit` target in SimulationKit handles the container. It depends on
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
| `documentType` | `bombcad`; future RoomCAD documents use their own application codec |
| `producer` | Producer name, currently `BombCAD` |
| `assets` | Array of asset records containing a UUID `id`, relative `path` and lowercase hex `sha256` |

Every file under `assets/` must have a manifest entry. Assets are embedded and checksum-checked
on load, so reading them never requires the original external path. Imported meshes are stored
as versioned JSON assets at `assets/<id>.mesh.json`. Identical sources share one asset;
content-derived IDs stay stable across repeated saves, and existing asset IDs are retained.

`scene.json` has format `dev.bombcad.scene` and `encodingVersion: 1`. Its `scenario` contains
structural geometry, openings, materials and reinforcement in metres, z up. Its `imports`
contains instance IDs, source asset references, names, transforms, behavior, attachment status,
part material assignments and retained previews. Source triangles are not duplicated per instance.

Mesh assets have format `dev.simulationkit.source-mesh`, `encodingVersion: 1` and
`coordinateSpace: source`. They retain original coordinates and face labels, plus a part identity
table checked against the reconstructed mesh. Scale, up-axis conversion and placement are applied
once by the importer. Integer part IDs belong to their source asset; they are not voxel IDs.
Original OBJ/STL files are unnecessary for reopening the project.

Each preview carries a provenance key containing the source checksum, transform, cell size,
domain size and sampler version. Loading rejects mismatched keys. Resolution changes use the
importer's normal resampling path and preserve part assignments. Detached scene boxes and the
full structural model, including supports, openings and reinforcement, remain authoritative;
opening a document never silently regenerates them from the source.

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
  untitled project. JSON support is a direct reader, without a historical migration framework.
  JSON originals are never the target of autosave.
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
swift test --package-path Packages/SimulationKit
swift test --filter 'AppPreferencesTests|ProjectSessionTests|ProjectDocumentTests|ImportedProjectTests|SimulationModelTests'
```

These cover container integrity, moved files, atomic replacement, asset preservation, every
built-in scene, embedded imports, stable source identities, detached edits, part assignments,
settings/view restoration, independent windows, revert, simulation progress not
marking projects changed, and app-model regressions. Native UI checks cover New, close/cancel,
Save, Save As and autosave of numerical and display edits.
