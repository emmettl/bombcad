# SimulationKit

Shared SwiftPM foundations for BombCAD and a future RoomCAD. This package builds and tests
independently and has no dependency on BlastCore, Metal, SwiftUI or either app.

| Product / module | Contents |
|---|---|
| SceneModel | Axis-aligned `Box` bounds and uniform Cartesian `Grid`, in metres with z up |
| SceneView | `OrbitCamera`, bounds framing, view rays, ground picking, orbit, pan and zoom |

Consume the package with `.package(path: "Packages/SimulationKit")` (adjust the relative path
for the consuming manifest), then add the required `.product` dependencies to each target.
Import `SceneModel` and/or `SceneView` explicitly in new consumers.

BombCAD retains `BlastCore.Box`, `BlastCore.Grid` and `BlastRender.OrbitCamera` as public
type aliases for compatibility with existing clients and the ongoing importer work. Its
scenario-specific camera framing remains in BlastRender; shared bounds framing has no
knowledge of charges or structures. `Box` keeps its original Codable representation.

The root BombCAD package remains the app package. Shared shaders, import readers, audio and
structural modules have not been extracted. Add those when a second consumer establishes
the required interface rather than creating empty targets ahead of it.

```sh
swift test --package-path Packages/SimulationKit
```

Root `swift test` checks BombCAD integration; run the command above as well to check this
dependency package's own tests.
