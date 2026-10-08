# ContinuumKit adoption

BombCAD pins [ContinuumKit `0.1.0-alpha.4`](https://github.com/emmettl/ContinuumKit/releases/tag/0.1.0-alpha.4)
and commits the resolved Git revision. Source picking and fragment segments use the
shared closed-box query in `SceneModel`; application ownership and mechanical
coupling remain in BombCAD.

## CAD foundations transition — 8 October 2026

The initial transition moved BombCAD and the then-nested RoomCAD package to the public
ContinuumKit repository, exactly pinned to `0.1.0-alpha.1`. Each package committed its
`Package.resolved`.

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

## Spatial query adoption — 9 October 2026

The closed-box queries from [ContinuumKit PR #7](https://github.com/emmettl/ContinuumKit/pull/7)
are released at `0.1.0-alpha.4`, commit `d3c7367ba43940155f7e33da738e6f5058723fd5`.
Source picking and fragment segments use the
shared geometry while retaining their original parallel thresholds and stationary
contact convention. The shared product needs no renderer or application schema.

Core verification passes all 57 tests, the optimized fetched Git consumer, actual
Metal compute and offscreen rendering, and adiabatic/acoustic reference reports on
M4 Max. The [exact-tag release workflow](https://github.com/emmettl/ContinuumKit/actions/runs/37854603915)
verifies the fetched version on the physical Mac mini before publication.
BombCAD retains application source-picking, multiple-owner,
fragment streaming/worker, import/document and headless-run checks. Its optimized
application build also succeeds. The manifest uses an exact version requirement,
and `Package.resolved` retains the reviewed release revision for reproducibility.

After integration with the current application branch, 188 selected tests and eleven
release/nightly script checks pass. The optimized app package passes deep strict
signature verification. Its bundled executable completes a headless two-structure
scene, writes a version-4 project retaining both response histories, and exports CSV
and USD with object attribution. These application checks preserve the documented
model scope; they do not establish new physical validation.
