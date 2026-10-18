# Cloud report: solver test gap review

Branch `cloud/test-gaps`, written on 18 October 2026 on a Linux box without Swift or Metal.

**None of the drafted tests has been built or run.** Every API they call was checked against the sources by reading, but they may not compile as written, and every tolerance marked `// Unverified tolerance:` (or `// Unverified`) is a guess. The Studio should build them, run them, and fix or loosen what fails before relying on them. A failing drafted test is as likely to be a wrong guess in the test as a fault in the solver.

This is a review of coverage, not a hunt for bugs: the `cloud/shader-mirrors-review` thread reviews last week's solver changes. Nothing in `Sources/` was changed.

## What was added

Five files in `Tests/BlastCoreTests/`, 36 drafted tests in all:

| File | Suites | Tests | What it covers |
|---|---|---|---|
| `MappedStartGapTests.swift` | `MappedStartGapTests` (GPU) | 8 | The mapped start's fallbacks, reach caps, obstacles, soft ground, time limit, products' law and afterburning set-up |
| `RefinementGapTests.swift` | `RefinementGapTests` (GPU) | 6 | The mapped start on refined air, an exhausted pool, the margin, the finer threshold, held bands on two levels, own steps over cut terrain |
| `AirSolverGapTests.swift` | `AirSolverGapTests` (GPU) | 7 | Far-field faces under gravity and their inflow, the density floor, afterburning constants, the start-up ramp and gamma, the limiter, moved gauges |
| `StructureSolverGapTests.swift` | `StructureSolverGapTests` (GPU), `StructureModelGapTests` (CPU) | 7 | Settling after a restart and its guards, soft ground on terrain, cut-cell loads on a wall, steel rate laws, timber classes, per-solid assignments |
| `ShellSolverGapTests.swift` | `ShellSolverHelperTests` (CPU), `ShellSolverGapTests` (GPU) | 8 | One-way shear of shells, the shear buffers' layout, section factors, thickness quadrature, settled shells and runaways, eroded beams |

All are in `BlastCoreTests`, so `make test-core` runs them; the GPU suites carry `.gpuThreads` as their neighbours do. Grids are 16 to 128 cells a side and runs are short, but their run times are unmeasured.

## The most important gaps

Across the areas, these are the gaps most likely to change results without any test noticing, most severe first:

1. **The mapped start on refined air.** Since 18 October `recommended` maps the charge, but every refined test pins `.balloonStart`, so `reseedImpulseBase` (`Refinement.swift:773`, called from `MappedStart.swift:178`) runs in real runs and in no test. If it broke, the impulse inside the mapped radius would fall to near zero under every patch. (`RefinementGapTests.mappedStartKeepsImpulse`)
2. **The mapped start's fallbacks and reach.** No test checks that dissociating air, the afterburning limit, gravity, mixing, radiative cooling or a gas cloud fall back to the balloon (`Scenario.swift:526-529`), or sets either reach cap. (`MappedStartGapTests.disqualified`, `reachCaps`)
3. **What enters through a far-field face.** Every `recommended` run has far-field faces, and no test checks that air flowing in carries ambient oxygen and no products (`Solver.metal:1714`), or that far-field faces copy under gravity (`BlastSolver.swift:3585`). (`AirSolverGapTests.farFieldInflowIsAmbientAir`, `farFieldUnderGravityCopies`)
4. **One-way shear of shells and beams.** `shellSectionShear` is set by no test, and beam section shear is run only with the check off (`ConcreteModelTests.swift:1087`), so no test sees a member checked for shear. (`ShellSolverGapTests.sectionShearBelowStrength`, `sectionLayout`, `sectionFactors`)
5. **Settling again after a restart.** No test settles, restarts and settles again, so a second run could measure its deflections from the first run's sag. (`StructureSolverGapTests.restartSettlesAgain`)
6. **A refined pool that runs out.** Only repeatability is checked when the pool is full, not conservation. (`RefinementGapTests.exhaustedPoolConserves`)
7. **Options set by no test**: `gamma`, `limiterTheta`, `densityFloor`, `afterburnEnergy`, `afterburnTime`, `refinementMargin`, `mappedChargeCells`, `mappedChargeScaledReach` (set by no source either), `mappedChargeBurns`, `debrisReach`, `minimumBalloonCells`, `structureMaskSampling` and `structureMaskFill`. The first nine have drafted tests; the last four do not.

One behaviour the Studio may want to confirm is intended: over shaped terrain the ground is not a mirror and its surface counts as an obstacle (`Scenario.swift:563-574`), so a charge sitting on the ground of any scene with non-flat terrain is never mapped, even on a flat stretch of it. `MappedStartGapTests.shapedTerrain` records the behaviour as it is.

## Findings by area

Each gap gives the untested path, how it was checked that no test reaches it, the risk and the drafted test. "Checked and covered" lists leads from the first scan that turned out to be reached.

## Mapped start and scenario loading (Tests/BlastCoreTests/MappedStartGapTests.swift)

The mapped start became the default in `SolverConfiguration.recommended` on 18 October 2026. `MappedChargeTests` checks the one-dimensional solution, mirrors, several charges and that energy is kept on rigid ground. Not reached by any test (checked by grepping Tests/ for `mappings(for`, `mappedChargeCells`, `mappedChargeScaledReach`, `mappedStartLatest`, `mappedChargeProducts`, `mappedChargeBurns`, `afterburnEnergy`, `afterburnTime`, `ventPanels` with `mappedCharge`, and `ground =` with `mappedCharge`):

1. **The fallback guard**, `Scenario.swift:526-529`: dissociating air, the afterburning limit, gravity, mixing, radiative cooling and a gas cloud each disable mapping. A slip here would start such runs from a solution that leaves out what was asked for. Test: `disqualified`.
2. **The reach caps**, `Scenario.swift:587-590`: `mappedChargeCells` and `mappedChargeScaledReach` are set by no test, and the scaled reach by no source either. Test: `reachCaps` (also the under-three-cells cut-off).
3. **Vent panels as obstacles**, `Scenario.swift:579`: only panels with a positive release pressure count. Test: `ventPanels`.
4. **Shaped terrain**, `Scenario.swift:563-574`: the ground is not a mirror and the surface is sampled as an obstacle, so a charge on shaped terrain always falls back to the balloon. The test records that behaviour; the Studio may want to confirm it is intended for a charge on a flat stretch of otherwise shaped ground. Test: `shapedTerrain`.
5. **Soft ground with the mapped start**, `Scenario.swift:360` with `MappedStart.swift:15`: the coupled charge should be what is mapped. Test: `coupledGround`.
6. **`mappedStartLatest`**, `MappedStart.swift:92`: set only by the app (`SimulationModel.swift:2447`). Test: `latestStart` (also checks a reload without mapping clears `mappedRadii` and the clock).
7. **`mappedChargeProducts`** through `depositMapped`, `MappedStart.swift:85`: set only by `blastbench`. Test: `productsOnGrid`.
8. **The afterburning set-up** of the one-dimensional solution, `MappedStart.swift:27-36`: `afterburnEnergy`, `afterburnTime` and `mappedChargeBurns` are set by no test. Test: `afterburnSetup` (CPU only).

Not drafted: envelope panes as obstacles (`Scenario.swift:592-603`), and structures' bounds as obstacles (`Scenario.swift:578`); both need a built envelope or structure in the scene.

## Adaptive refinement (Tests/BlastCoreTests/RefinementGapTests.swift)

1. **Mapped start on refined air**, `MappedStart.swift:174-179`, `Refinement.swift:773-794`, `Refine.metal:1749, 2502-2508`. Patches placed at `restart()` take their cells' impulse before the mapped impulse is written, and `reseedImpulseBase` gives it to them again. No test reaches it: `reseedImpulseBase` and `recordMapped` appear in no test, `mappedCharge = true` appears only in `MappedChargeTests` (no refinement) and `InjuryFieldTests` (`.recommended`, refinement 1), and every refined test that starts from `.recommended` pins `.balloonStart`. `.recommended` now maps the charge, so real refined runs take this path. If it breaks, the impulse inside the mapped radius falls to near zero under every patch. Test: `mappedStartKeepsImpulse(levels: 1, 2)`.
2. **A pool used up with no room to grow**, `Refinement.swift:488`, `BlastSolver.swift:2332-2357`. `repeatableWhenFull` checks repeatability and `refinedTiles == capacity` only; conservation, `ranOut` and `refinementPoolGrewLate` are unchecked. If it breaks, gas leaks at an edge the pool sets rather than the shock, or the second level is not nested where the first ran out. Test: `exhaustedPoolConserves(levels: 1, 2)`.
3. **`refinementMargin`**, `BlastSolver.swift:3599`, `Refine.metal:1858-1871` (`flagAround`, used by every flag kernel). Set by no test, so only the default of 1 has run. Test: `margin()`.
4. **`refinementFinerThreshold`**, `BlastSolver.swift:2393-2398`. Its only test use (`TerrainTests.swift:101`) sets it to the first level's value, so a swapped uniform would pass. Test: `finerThreshold()`.
5. **The held band on the second level**, `BlastSolver.swift:137-143`, `Refine.metal:1890-1895, 2018-2021`. `refinementHoldsStructures` and `refinementHoldsEnvelopes` are each tested with one level only. Test: `heldAboutStructureInTwoLevels()`.
6. **Own steps turned off over cut terrain**, `BlastSolver.swift:2440-2442, 3126`. The own-steps tests have no terrain and the cut-terrain tests never set own steps, though `RunAdvisor.swift:116` turns own steps on by itself. Test: `ownStepsOffOverCutTerrain()`.

Found but not drafted: `growPools` failing for want of memory (`BlastSolver.swift:2366-2377`, `Refinement.swift:872`), which needs a way to make allocation fail; experimental boxes forcing one level (`BlastSolver.swift:2262`); both held bands at once (`BlastSolver.swift:102`); ratio 4 with two levels or with own steps, never run, including the half-cell ghost reach `nestReach` (`Refine.metal:2039`); conservation when panes open in refined air (peaks only are compared, and opening adds air by design).

Checked and covered: pool growth (`growingPool`), terrain on refined air (`TerrainTests`, `TerrainCutCellTests`), boxes and their face impulses (`ExperimentalRigidBoxTests`, `ExperimentalRigidWorldTests`), two levels with own steps conserving gas (`RefinementOwnStepsTests`, in a room without blocks).

Unsure in the draft: the mapped test assumes the scene maps the charge (guarded by `#require(solver.time > 0)`) and its 1e-6 slack is a guess; `held == capacity` once the pool runs out is a guess; the margin test assumes the starting state does not depend on the margin; the two-level hold assumes the second level is still held at 20 ms. Two `@Test` lines exceed the formatter's width.

## Air solver core (Tests/BlastCoreTests/AirSolverGapTests.swift)

Area: `BlastSolver.swift`, `SolverTypes.swift`, `Shaders/Solver.metal`, refinement aside. Checked by grepping Tests/ for each field and API, reading any test that matched, and tracing callers in Sources/.

1. **Far-field faces copy under gravity**, `BlastSolver.swift:3585` (`openFaces == .farField && gravity == nil`). Only `FarFieldFacesTests` sets `openFaces`, without gravity; `GravityTests` never sets it. If the guard broke, the far-field ghost would stand the ground's state at every height and a resting atmosphere would start to move. Test: `farFieldUnderGravityCopies` (copy and far field bit-identical under gravity, different without).
2. **The species beyond a far-field face are ambient air's**, `Solver.metal:1714` and the inflow branch of `farFieldGhost` (`:508-532`). `FarFieldFacesTests` checks late overpressure only. A slip would starve an open fireball of oxygen or bring products back in, in every `recommended` run. Test: `farFieldInflowIsAmbientAir`.
3. **The density floor and the positivity fallback**, `Solver.metal:666, 900-916, 1795`. No test sets `densityFloor` or reaches a vacuum. Test: `vacuumHeldAtFloor` (two streams pulled apart at ±2,000 m/s).
4. **`afterburnEnergy` and `afterburnTime` away from their defaults**, `BlastSolver.swift:3612-3617`, `Solver.metal:1310, 1778-1782`. No test sets either. Test: `afterburnEnergyAndTime` (4 MJ/kg released per kilogram burnt; a shorter time burns more).
5. **The start-up Courant ramp and a gamma other than 1.4**, `BlastSolver.swift:2565, 3577`. Tests only set `startupSteps = 1`, and none sets `gamma`. Test: `startupRampAndGamma`.
6. **`limiterTheta`**, `Solver.metal:627, 800, 939`. Never set in a test. Test: `limiterSteepness` (Sod's tube with minmod and monotonised-central slopes).
7. **`moveGauges` and `prependGaugeHistory`**, `BlastSolver.swift:1218, 1925`. Called by no test (`MendoncaSlabTest.swift:480` and `MappedStart.swift:205` only). Test: `movedGauges`.

Found but not drafted: `minimumBalloonCells` and `deposit`'s conservation with solid cells near the charge (`Scenario.swift:615-680`); `debrisReach` (`BlastSolver.swift:1334`); `structureMaskSampling` and `structureMaskFill` (`BlastSolver.swift:1431-1462`); supersonic flow across a far-field face and its pressure clamp (`Solver.metal:510-527`); a disturbance crossing the `periodicSides` seam (only uniform streams in `CongestionTests`); afterburning on with `afterburnEnergy = 0`, where `carriesSpecies` (`Solver.metal:127`) turns species advection off although the species are still reported, which may be intended.

Checked and covered: air sleep (`StructureCouplingTests`, `TiledCouplingTests`), `editMaskKeepingTerrain` and `keepInRigidMask` (`TerrainCutCellTests.ventPanelsKeepCutCells`, `DeflagrationTests`), copy against far field without gravity (`FarFieldFacesTests`), HLL (`sodShockTube` over every Riemann solver).

Unsure in the draft: five tolerances marked `// Unverified tolerance:`; bitwise equality of two identical GPU runs (as `StructureCouplingTests` assumes); a still-air step exactly equal to CFL × cell size / sound speed (with `skipStillAir = false`); `try #require` inside the `readSpecies` closure (it is `rethrows`).

## Solid structures (Tests/BlastCoreTests/StructureSolverGapTests.swift)

Checked by grepping Tests/ (both targets) for each function, the flag or configuration that turns it on, and any preset that reaches it.

1. **Settling again after `restart()`**, `BlastSolver.swift:2043-2067`, `StructureSolver.swift:873-875` (`reset()` clears `settledDisplacements`), `StructuralBody.swift:56-64`. Eleven test files call `restart()`, but none settles first; `selfWeightSag` and `settledDisplacements` appear only in `SettleTests`, which never restarts. If it breaks, a second run measures its deflections from the first run's sag. Test: `restartSettlesAgain`.
2. **The settling guards**, `BlastSolver.swift:1975` (`!body.hasSetMotion && body.isAsLoaded`), `StructuralBody.swift:70-91`. `SettleTests` covers only the weightless and falling cases. If it breaks, settling zeroes the velocities of prescribed or pushed nodes. Test: `guardsLeaveBodiesAlone`.
3. **Soft ground on terrain**, `Structure.metal:4301-4312` (`structureTerrainLanding`). `groundStiffness` is set only in `SoftGroundTests` (passed through) and `MasonryDebrisTestsTests` (the floor at z = 0); no terrain test sets it. Test: `softGroundOnTerrain` (a block on a 1-in-50 slope sinks about 3.8 mm; 15% tolerance unverified).
4. **Cut-cell pressure on a wall**, `StructureSolver.swift:1081-1095` and `cutFaceOverpressure`. The cut-cell tests check only gas conservation, so a kernel reading zero pressure would pass. Test: `cutCellsLoadTheWall` (deflection within a factor of 2 of the run without cut cells; band unverified).
5. **The steel rate law by grade**, `StructureTypes.swift:521-527, 2185-2189`, `StructureSolver.swift:2177-2185`. `byGrade`, `resolvingRateLaw` and `rateTestFactor` appear in no test. Test: `rateLawByGrade` (CPU).
6. **Timber strength classes and CLT panels**, `StructureTypes.swift:129-185`, `StructureSolver.swift:2193-2227`. `strengthFactor`, `lognormalMean` and `weibullMean` appear in no test; `TimberTests` gives its own strengths. Test: `timberClasses` (expected ratios computed in Python).
7. **`solidNear` and per-solid buckling curves**, `StructureTypes.swift:1041-1058, 979-990`. Neither appears in a test; `setBucklingCurve` is used only by the transport hub preset, whose test checks no curve. Test: `perSolidAssignments`.

Found but not drafted: the read-backs `crackingFactor`, `confinementGain`, `crackPlanes`, `hourglassForces`, `discreteBarPlastic`, `barSlip`, `barForce`, `crackOpening` and `footingBedSurface` (`StructureSolver.swift:765-1420`), read only by `blastbench` and benches no test runs (the Reynolds and Hrynyk benches use `crackOpening` as a pass criterion; a cheap check would compare it with a pulled bar's elongation); `discreteBar` is reached through `TieBenchmark` but never asserted; no test settles a mixed body (`StructuralBody.swift:106`); soft ground without friction is never run.

Checked and covered: `isResolved` (`MasonryTests.runningBond`), `recordSettledShape`, `holdStill` and `advanceAlone` (`SettleTests`), soft ground on the floor (`MasonryDebrisTestsTests`).

Unsure in the draft: tuple element access `parameters.lamellaTop.0`; internal statics called through `@testable` (`TimberProperties.lognormalMean`, `weibullMean`, `StructureSolver.parameters(for:elementSize:)`); a `check` helper taking a closure first.

## Shells and beams (Tests/BlastCoreTests/ShellSolverGapTests.swift)


### Gaps, most important first

1. **One-way (sectional) shear check of shells is never switched on.**
   - Path: `ShellSolver.swift:433-435` passes `model.shellSectionShear` to `MemberShearBuffers`; `ShellSolver.swift:2014-2027` fills shell section factors only when it is true; kernel `Shell.metal:1294-1322` (shear ratio vs SMCFT strength) and `Shell.metal:1420-1435` (time-averaged ratio, sets punched bits 1/2), then `Shell.metal:519-522` (failed section carries no concrete shear); accessor `hasShearFailed` (`ShellSolver.swift:1129`).
   - Checked: `grep -rn shellSectionShear Tests` gives nothing; default is `false` (`StructureTypes.swift:777`); `hasShearFailed` named only in SceneBench.
   - Risk: an option that changes the answer (members failing in shear) has no test at all; a bug in its layout or in the averaging would change results, or quietly change them when the option is off.
   - Covered by: `sectionShearBelowStrength` (on vs off, bit-for-bit equal below strength, no bits set). Not covered: a section that **does** fail in shear (see undrafted).

2. **Beam sectional shear: never asserted.**
   - Path: `ShellSolver.swift:2035-2047` (beam factors with `tieRatio` as stirrups, skipped when `checksBeams` false); kernel `Shell.metal:1908-2008`; `beamHasShearFailed` (`ShellSolver.swift:1140`).
   - Checked: the only test call, `ConcreteModelTests.swift:1087`, runs `ImpactBenchmark.runBeams(..., sectionShear: false)`; `StructuralRegimeTests` checks the flag `appliesBeamSectionShear` but never a solver. `beamHasShearFailed` is read only in `ImpactBenchmark.swift:548`. Default-loading concrete beam models (frames) reach the kernel, but nothing checks the outcome.
   - Risk: regime switch wired wrongly (beams checked under impulsive defaults or not checked under quasi-static) goes unseen.
   - Covered by: `sectionLayout` checks the CPU layout only (beam factors > 0 with `checksBeams` true, all zero with false). The GPU failure is not drafted.

3. **`MemberShearBuffers` layout: punching-zone exclusion, `reset()`, `disableSectionShear()`.**
   - Path: `ShellSolver.swift:2016` (`guard shells, material.model == .concrete, !mesh.punchingZone[e]`); `ShellMesh.swift:502-525` (zone within two effective depths of a column face); `reset()` `ShellSolver.swift:2056-2061` (clears odd vectors only); `disableSectionShear()` 2065.
   - Checked: `punchingZone`, `punchingRings`, `MemberShearBuffers` not named in Tests; `disableSectionShear` used only in `PunchingTests.slide` on a single element (no zone).
   - Risk: a section checked for one-way shear in the punching zone would fail it before punching; a `reset()` that left averaged shear would carry failure across a restart.
   - Covered by: `sectionLayout`.

4. **`sectionFactors` (d_v and size factor) has no direct test.**
   - Path: `ShellSolver.swift:1956-1971`: branches for bars nil (0.6), d_v floor 0.72 h, minimum stirrups (`enough`), steel absent, fc > 70 MPa (aggregate taken as zero), s_ze floor 0.85 d_v.
   - Checked: name not in Tests; only reached through the beam layout of default-loading concrete beams, never asserted.
   - Risk: pure arithmetic deciding every concrete section's shear strength.
   - Covered by: `sectionFactors` (hand values, each branch).

5. **Thickness quadrature rules.**
   - Path: `gaussLegendre` 1807, `gaussLobatto` 1791, `thicknessRule` 1768-1788 (non-timber branch, single-lamella clamp `min(max(layers,3),5)`, deduplication of lamella tops across materials, face nudging).
   - Checked: `TimberTests.swift:386` asserts only a 5-ply CLT rule's count (15) and weight sum. Legendre is reached by every shell test but never checked for exactness; the clamp and dedupe branches are not reached by any assertion.
   - Risk: a wrong rule mis-integrates bending stiffness for every shell.
   - Covered by: `gaussLegendre`, `gaussLobatto`, `thicknessRule`.

6. **`recordSettledShape` on shells and `runaway(beyond:)`.**
   - Path: `ShellSolver.swift:1299` (called from `StructuralBody.swift:167`), `runaway` 1306-1346 (by material, "stretched:", "beam:", non-finite incl. spin > 1e4 and non-unit quaternion), `summary()` measuring from the settled shape, `reset()` clearing it (`ShellSolver.swift:941`).
   - Checked: `SettleTests` and `TerracedHousesTests` settle; SettleTests uses solid elements (default `elementKind`), TerracedHouses only checks `settled` flags. `runaway` is used only by `blastbench`. `settledDisplacements` not named in Tests.
   - Risk: deflections of settled shell structures reported from the wrong datum; a diagnostic tool that silently miscounts.
   - Covered by: `runawayAndSettledShape`.

7. **`erode(where:)` on beams, `beamCentre`, `beamFlag`, and `reset()` restoring beam flags.**
   - Path: `ShellSolver.swift:1188-1207`, reset 946-950.
   - Checked: `ShellCouplingTests.swift:90,126` erode shell-only bodies; no test with beams erodes or reads `beamFlag`/`beamCentre`.
   - Risk: low/moderate; used by hand removal scenarios and the failure gate that switches contact on.
   - Covered by: `erodeBeams`.

### Leads checked and found reached (not gaps)
- `hasFragmented`, `releasedSpringShare`: reached via `LaminatedShellTest.run` (`LaminatedShellTest.swift:184,188`), asserted by `LaminatedShellTests` (`crackedAt`, the silicone tear-out test at line 63-71).
- `isPunched`: accessor not named, but the punching path it reads is exercised by `PunchingTests.punchingStrength` (load drop, elements removed). Drafted test only reads it as a "stays clear" guard.
- `beamFlag` is reached through `summary()`/`nodalForce` by any beam test; only its use with erosion was unexercised.

### Gaps found but not drafted
- A shell section that actually fails in one-way shear (deep, short, lightly reinforced strip, no stirrups), checking `hasShearFailed` sets and only the stirrup share remains; and the same for a beam (`ImpactBenchmark.runBeams(..., sectionShear: true)` should report `sheared > 0` per its doc comment at `ImpactBenchmark.swift:487-491`, but is a 0.2 s run). Loads would need calibrating on a Mac.
- `reset()` clearing `punching.punched` / `beamSheared` after a failure (needs a failed run first).
- `MemberShearBuffers` ring layout (`ringStart`/`ringMember`) for more than one column head.
- `hasFragmented` index guard (out-of-range index returns false) and `releasedSpringShare` with no spring supports (returns 0): trivial.

### Unsure in the draft
- `sectionShearBelowStrength`: bit-for-bit equality assumes GPU determinism across two solvers and that the averaged shear ratio stays below 1 at clamped ends (marked `// Unverified`). If it flakes, the load can be lowered or the comparison given a tolerance.
- `erodeBeams` assumes the 1 m beam is meshed into even 0.1 m elements (marked).
- `sectionLayout` assumes the 0.3 m column stub meshes as beam elements (it is guarded by `#require`) and reads `MemberShearBuffers.section`/`beamSection` raw; the struct is top-level internal, `init` internal with `checksBeams` label, so it should compile.
- `(0..<beams).map(solver.beamCentre)` uses an unapplied method reference; should compile in Swift 6 but could be written as a closure if not.
- `thicknessRule` uses `StructureMaterial.timber(.c24)` / `.timber(.c16, lamellae: 3)` (exist at `StructureTypes.swift:422`).

## How the gaps were found

Functions not named in any test were listed for `BlastSolver`, `SolverTypes`, `StructureSolver`, `StructureTypes`, `ShellSolver`, `Scenario`, `MappedStart`, `Refinement`, `StructuralBody`, `DeflagrationSolver` and `RadialBlast/SphericalBlast`, together with the `SolverConfiguration` fields no test sets. Being unnamed is not being untested, so each lead was traced: a gap is listed only where no test reaches the branch through the flag, enum case, preset or call that turns it on. Nothing under a `blind/` folder was opened.

Not reviewed: the deflagration solver beyond its use in the mapped start's fallback, the footing, soil and ground-shock solvers, and the application's tests.

## Checks run here

- `python3 Scripts/check-doc-links.py` passed.
- No Python was touched, so no Python tests were run. No Swift or Metal was built or run.

The branch is ready for the Studio to build and run the drafted tests.
