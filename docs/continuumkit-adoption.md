# ContinuumKit adoption

BombCAD pins [ContinuumKit `0.1.0-alpha.13`](https://github.com/emmettl/ContinuumKit/releases/tag/0.1.0-alpha.13)
and commits the resolved Git revision. Source picking and fragment segments use the
shared closed-box query in `SceneModel`; application ownership and mechanical
coupling remain in BombCAD.

## Document diagnostics adoption — 9 October 2026

The exact `0.1.0-alpha.5` pin resolves to
`7d5ef9d0ca7b415d3fef86b5400017bb43111a3c`. Shared project errors now identify malformed
payload filenames and missing, mistyped or invalid manifest fields, including asset array
paths. Unsupported package versions still fail before other metadata is decoded.

The [exact-tag release workflow](https://github.com/emmettl/ContinuumKit/actions/runs/37974874568)
passed on the physical Mac mini before publication, including 141 independent tests,
verified Metal compute and the clean optimized Git consumer. BombCAD's 15 selected
document-integration tests cover the shared errors, application settings/view diagnostics
and project round trips. Its optimized app build and packaged CLI checks also pass;
malformed settings and missing manifest metadata fail before starting a simulation.

App-linked CAD module source is identical to alpha.4 except DocumentKit. The prerelease
also contains acoustic reference/conformance additions in BenchmarkSupport and a bounded
linear-wave extraction design checkpoint; these do not extract a shared wave-update solver.

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

## Planar ideal-gas wall reference — 10 October 2026

The exact alpha.13 dependency resolves to
`b6ff3ca28eb96bbac23ec15d93a13afda99b2be9`. The public CompressibleFlow product
now supplies the stateless wall-pressure relation through BombCAD's internal bridge.
The bridge preserves the application's result shape and invalidState failure
category. Geometry, signed wall-frame velocity, reconstruction, gas transport,
timestep selection and accepted wall impulse/work integration remain app-owned.
CAD foundation source is unchanged from alpha.5.

Ordinary-state operation order and the incident-state signal estimate are preserved.
Near gamma = 1, the shared rarefaction uses log1p/exp; invalid or unrepresentable
intermediates and non-vacuum pressure underflow now fail explicitly. Two application
bridge tests cover these deliberate numerical adaptations. The signal estimate is
not an exact shock-front speed or a universal downstream-characteristic certificate.

The reproducible comparison uses immutable pre-adoption commit
`089d0a25475a3de8c541dd1a6531c7503e60163c`, with the identical benchmark fixture
copied into its disposable build. The baseline retains its original source and
existing compiler warnings. Both variants use the same release build flags.
The benchmark requires byte-identical complete reports for 360 ordinary wall cases,
twelve piston runs (three spacings, both wall directions, both reconstruction modes),
33 native field clocks per piston and every accepted wall-load interval, plus eight
public wall-reflection histories and the eight-case wall-pressure study. Reflection
records expose their complete public history, rather than every interior field.
Independent postconditions check clocks, case identity and mass/momentum/energy
accounting; deliberate corruption controls test completeness and rejection.

Run `bash Scripts/check-wall-adoption.sh /absolute/output/path` from a clean
committed candidate, or dispatch Check with suite `wall-adoption` on the physical
Mac mini. Reports retain original/shared values, resolved Git pins, source hashes
and host/toolchain identity. Full app CI remains separate and verifies the packaged
app signature after lint, script checks, build and tests.

[Acceptance record](wall-adoption-verification.json) records the measured producers,
application gates and source equivalence across the integration checkpoint. This
adoption establishes numerical preservation for the declared cases. Measured blast
accuracy and bulk gas/moving-geometry extraction remain separate tasks.
