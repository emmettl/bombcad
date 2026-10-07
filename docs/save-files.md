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
and uses SwiftUI FileDocument for coordinated package export. FileDocument supports directory
wrappers as document packages; see [Apple's documentation](https://developer.apple.com/documentation/swiftui/filedocument).

The manifest contains:

| Key | Meaning |
|---|---|
| `format` | `dev.simulationkit.project` |
| `schemaVersion` | Integer `1`, independent of the application release |
| `documentID` | UUID retained on save/reopen; selecting a built-in layout starts a new identity |
| `documentType` | `bombcad`; future RoomCAD documents use their own application codec |
| `producer` | Producer name, currently `BombCAD` |
| `assets` | Array of asset records containing a UUID `id`, relative `path` and lowercase hex `sha256` |

Every file under `assets/` must have a manifest entry. Assets are embedded and checksum-checked
on load, so reading them never requires the original external path. Source-mesh encoding and
references from scene parts remain for the importer integration; this first foundation does
not claim to have converted imported meshes into asset files.

`scene.json` is the current Codable Scenario representation, including structural geometry,
openings, materials and reinforcement. Coordinates are in metres, z up. Retaining this payload
initially keeps the in-flight importer integration small; a common scene/part schema will be
introduced with GeometryImport rather than inventing a second mesh representation now.

`settings.json` stores resolution (`coarse`, `medium`, `fine`), `detailedCharge`, `sharpShocks`,
`solidElementSize` (the size restored when switching from shells to solids), and `duration`
in seconds. The scenario itself holds the charge, atmosphere and structural settings.

`view.json` stores camera target, distance, azimuth, elevation and field of view, plus display
mode, scales, decades, wave visibility/opacity and charge visibility. It does not store the
current selection, undo stack, elapsed simulation time or GPU state. Opening restores a
fresh run and clears undo across documents.

## Open and save behaviour

- Open Project accepts `.bombcad` and plain Scenario JSON. JSON support is a direct reader;
  no historical migration framework is maintained. Opening does not write to the source.
- Save Project captures a snapshot when the save button is pressed and exports a `.bombcad`
  package. The document retains its ID and any already embedded assets and optional files.
- Export Layout JSON remains available for scene interchange. It omits run/view settings.
- Unsupported schema versions and other applications' project types are rejected before
  changing the current model. Known version 1 payloads must include scene and run settings;
  absent view settings use scenario framing and normal display defaults.
- Container validation rejects invalid relative paths, symbolic links, conflicting file/directory
  paths, case/Unicode collisions, missing/corrupt assets and oversized inputs. Limits are
  64 MiB per file, 256 MiB total and 4,096 entries. The URL reader checks sizes before loading.
- BombCAD validates numerical settings and bounds its saved air grid to 128 million cells
  before constructing Grid; the existing GPU memory-budget check still applies during loading.

The application uses the system exporter for writing rather than implementing in-place
directory updates. Tests also exercise Foundation's atomic wrapper replacement and confirm
that validation failures leave the previous saved document readable. This is not a test of
power-loss durability or a simulation checkpoint facility.

## Next integration steps

1. Finish and integrate the importer, then verify its source geometry, stable part IDs,
   material assignments, attachment status and authoritative detached edits round-trip through
   scene.json. Add those cases to ProjectDocumentTests.
2. Move large source meshes to embedded asset files using a documented, versioned mesh
   encoding. Add scene references and importer reconstruction, preserving stable identities.
   Decide schema changes explicitly before files are released to users.
3. Key regenerable voxel previews by source, transform, settings and generator version;
   detached local edits remain authoritative. Optional results need input hashes and provenance
   before the app offers to reuse them.
4. Add RoomCAD's codec when its scene/source/receiver model exists. WAV impulse responses are
   standalone exports, not project documents.
5. Consider a DocumentGroup-based editor for normal Save, Save As, dirty-state prompts and
   autosave after the initial exporter workflow is established. Those lifecycle features are
   not implemented by this foundation.

## Checks

```sh
swift test --package-path Packages/SimulationKit
swift test --filter 'ProjectDocumentTests|SimulationModelTests'
```

These cover container integrity, moved files, atomic replacement, asset preservation, every
built-in scene, settings/view restoration and app-model regressions.
