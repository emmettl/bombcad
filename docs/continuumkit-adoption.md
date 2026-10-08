# ContinuumKit adoption — 8 October 2026

BombCAD and the nested RoomCAD package now depend on the public ContinuumKit repository,
exactly pinned to `0.1.0-alpha.1`. Each package commits its `Package.resolved`.

The original five module names remain: SceneModel, SceneView, SceneRender, GeometryImport
and DocumentKit. Their implementations and Scene.metal originated at BombCAD commit
ad130448dc8a3d8b3181ad0107defcd38c29aef3 and are byte-identical in this release.
The original local package is retired after both consumers' dependency transitions.

Keep the compatibility aliases in BlastCore/BlastRender. Saved documents still use
`dev.simulationkit.project`; no data migration or schema change is introduced.

SwiftPM names resource bundles after the package: application packaging and RoomCAD's
release checks now include `ContinuumKit_SceneRender.bundle`. Test the packaged app's
shader/resource lookup as well as executable compilation.

Library verification belongs to ContinuumKit's independent tests and clean Git consumer.
Applications retain their integration, model, measured-scene and UI checks. The observed
RoomCAD full-suite calibration discrepancy remains a separate issue; this migration
does not adjust its assertions or change acoustic behavior.
