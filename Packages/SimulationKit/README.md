# SimulationKit moved to ContinuumKit

The shared CAD foundations now live in [ContinuumKit](https://github.com/emmettl/ContinuumKit).
They moved there at `0.1.0-alpha.1`. BombCAD now pins `0.1.0-alpha.28` exactly (`Package.swift`)
and links more of ContinuumKit than the CAD foundations; the adoption notes list what it uses.

The module names SceneModel, SceneView, SceneRender, GeometryImport and DocumentKit remain
unchanged. This directory is a historical documentation pointer, not a Swift package.
See [adoption notes](../../docs/continuumkit-adoption.md) for resource packaging and verification.
