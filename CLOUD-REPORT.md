# Cloud report: shader mirror lint and solver review (18 October 2026)

Branch `cloud/shader-mirrors-review`. This was done on Linux by reading the code. Nothing in Swift
or Metal was built or run, and no solver code was changed.

## Part A: the struct mirror lint

`Scripts/check-shader-mirrors.py` lays out GPU structs on both sides, using the languages' rules
rather than a compiler:

- each Swift struct uploaded to a Metal buffer, against the shader struct that reads it;
- each shader struct that the renderer copies from a solver's.

It fails when a size, a stride, a field offset or a field kind differs (a `float` read as a `uint`
counts). It also reports:

- a shader `static_assert(sizeof...)` that disagrees with its own layout;
- a Swift stride constant that disagrees with the struct it describes (`size` lines);
- a Swift struct that is used on a buffer but paired with nothing.

It finds pairs in three ways: identical names, a Swift doc comment that names the shader struct in
backticks, and `pair` lines in `Scripts/shader-mirrors-allow.txt`. That file also lists every
deliberate difference with its reason. An allow-list line that no longer matches anything is an
error, so a fixed bug's line has to be deleted along with the bug.

- **Tests:** `Scripts/test-check-shader-mirrors.py` has 25 tests: the layout rules, made-up
  mismatches (among them the `ShellElement` copy left behind on 18 October and a `SIMD3` pad that
  moves a stride), pairing, copies and the allow-list. All 25 pass.
- **Wiring:** both scripts run in `make ci-test`, because it holds the Python checks and runs on
  any machine. `make lint` is swift-format.
- **Documentation:** a paragraph in docs/continuous-integration.md describes the check.
- **Pre-push checks:** `python3 Scripts/check-doc-links.py`, the new test and
  `Scripts/test-check-affected.py` all pass.

### What it finds on today's tree

It checks 38 Swift/Metal pairs and 4 renderer copies, and it lays out all 76 shader structs.

- **One true mismatch: `PaneLookup`, a bug.** Details are in finding 1 below. It is allowed in the
  allow-list with a `BUG` reason so that `ci-test` stays green. Delete that line in the commit that
  fixes the bug.
- **One deliberate difference.** `BeamMeshElement` in Render.metal keeps `padding0` where the
  solver's `BeamElement` now has `bowed`. The layout is the same, and the renderer doesn't draw the
  bow, so it is allowed with that reason.
- **One false positive, fixed in the allow-list.** `SceneRenderer.OrientedBox` has the same name as
  the shader's `OrientedBox`, but `setFreestanding` converts each box to three `float4`s, so it is
  `unpair`ed.
- **Parser gaps found on the first run and fixed in the parser:**
  - type inference from defaults such as `SIMD4<Float>(…)` and `SIMD3<Float>.zero`;
  - typealiases that span lines (`DeflagrationUniforms.SpeedTable`);
  - nested type names resolved within their own file (`FootingSystem.State`).

### Self-checks

- The script's Metal layout of `ElementState` agrees with the shader's own
  `static_assert(sizeof(ElementState) == 196)`.
- The strides `StructureSolver.stateStride` (196), `forceStride` (96), `ShellSolver.layerStride`
  (40) and `barStride` (36) all agree with the computed sizes of `ElementState`, `ElementForces`,
  `ShellLayerStore` and `ShellBar`.

### Not covered

- The shader source ContinuumKit compiles in (`MetalContactSearch.functionSource()`) lives in
  another package and is not read.
- Some buffers are written as raw words, with no struct or stride constant to compare:
  `InterfaceLink` (MixedStructure.swift, 35 words, which matches the 140 bytes by hand),
  `MarchTile` and `MarchReceiver` (MetalThermalMarch.swift), and `DiscreteBarNode` and
  `DiscreteBarSegment`. Each could be guarded by a `size` line once its stride is kept as a named
  constant.
- Preprocessor conditionals are ignored.

## Part B: review of the solver changes since 12 October

History starts on 17 October 2026: commit 8fc1145 imports the whole tree. So the review covered
`git diff 8fc1145 HEAD` for Solver.metal, BlastSolver.swift, Shell.metal, ShellSolver.swift,
Refine.metal, Refinement.swift, Structure.metal, StructureSolver.swift and the smaller shaders
(Deflagration, Extract, Rubble). That is about 5,000 changed lines across about 120 commits.

The findings are below, most severe first. Each was traced in the code. None was run.

### 1. High: `PaneLookup` is 48 bytes in Swift and 32 in Metal, so refined air loses two pane cells and opens the domain corner

- **Where:**
  - The Swift struct is at `Sources/BlastCore/Refinement.swift:1973`. Its `var pad = SIMD3<Float>.zero`
    sits at offset 32 and is 16 bytes long.
  - The Metal struct is at `Sources/BlastCore/Shaders/Refine.metal:2312`, with three float pads.
  - The header is written at `Sources/BlastCore/EnvelopeVenting.swift:431-433` and again at
    `:514-516`, using `withUnsafeBytes(of: paneLookup)`. That gives 6 `uint2` entries, although the
    comment there says 4.
  - It is read at `Refine.metal:2327` (`inOpenedPane`) and `:2833` (`refineOpenPanes`), both as
    `(uint2 *)(lookup + 1)`, which starts at byte 32.
- **Introduced:** 459e15f, "Glazing vents in refined air", which reached main through b418939.
- **Trigger:** any refined run (refinement above 1) with envelope venting. Venting broken glazing is
  the default for new projects.
- **Expected wrong output:**
  - The kernels read the zeroed pad as two extra entries, (cell 0, pane 0) twice. All their loops and
    searches stop at `count`, so the two highest-index pane or wall cells are never seen. Their fine
    cells stay solid after the pane breaks, while the coarse grid opens them (`openEnvelopePanes`
    uses the buffer without a header). A window can therefore vent on the coarse grid and not on the
    fine one.
  - When pane 0 breaks, the fine cells of coarse cell (0, 0, 0) become still air, even where they are
    ground or a block.
- **Fix:** three `Float` pads, so the Swift struct is 32 bytes. Then delete the `PaneLookup` line
  from the allow-list.
- **Confidence:** high. The lint and an independent reading both found it.

### 2. High: the GPU run clock ignores the mapped start's offset

- **Where:** `Sources/BlastCore/BlastSolver.swift:1911`. `startClock(at:)` sets only `time`.
  `clockTicks`, set to 0 by `restart()` at `:2050`, goes into `StepControl` at `:2526`. The GPU clock
  is read at:
  - `Solver.metal:2650` (`record.z = runClockSeconds(control)`, the exposure plane's arrivals);
  - the hole test in `stepEnvelopePanes` (about `:3105`);
  - `openEnvelopeBreaches` (about `:3330`).
- **Introduced:** the run-clock change, which arrived through b418939. Before it, these times were
  taken from `time`, which includes the offset.
- **Trigger:** any scenario with a mapped start. `Scenario.swift:501` calls `startClock(at:
  blast.time)`, and the mapped start is the app's default.
- **Expected wrong output:**
  - **Exposure plane:** arrivals beyond the mapped radius read early by t0, against seeded absolute
    times inside it, so the arrival map has a step at the mapped radius.
  - **Holes and breaches:** fragment holes and close-in breaches open t0 late. `setHoles` and
    `setBreaches` convert times since detonation into ticks, but the clock started at the restart.
  - **Envelope component histories:** `histories(elapsed: time)` uses the absolute time against bins
    counted from the restart. That gives about t0/binS extra trailing zero bins, a `windowStartS`
    that is off by t0, and a possibly false `truncated`.
- **Fix:** `clockTicks = UInt64(start / StepControl.tick)` in `startClock`.
- **Confidence:** high. Every write of `clockTicks` was traced.

### 3. High: `ShellSolver.reset()` leaves spring supports, fastener links and steel hinges as the last run left them

- **Where:** `Sources/BlastCore/ShellSolver.swift:938-1014` (`reset()`).
  - The state of these supports, links and hinges is kept in `loadTableBuffer`. The CPU writes it
    only in `init`, at `:655`, `:680` and `:724`.
  - The GPU updates it each substep: springs at `Shell.metal:2476-2477`, links at `:2213-2215` and
    hinges at `:2292-2296`.
  - `reset()` rewrites the nodes, layers, bars, pairs and failure gate, and re-applies spring
    restraints to the nodes. It never rewrites these records.
- **Introduced:** 4e7623a (springs), f280d2f (links) and 0fd0d10 (hinges).
- **Trigger:** `BlastSolver.restart()` calls `body.reset()` at `:2065`. So does a self-weight
  settle that does not converge, at `:2023`.
- **Expected wrong output:** after a fin-plate office run with 334 of 480 hinges fractured, a
  restart begins with those 334 already gone, and `hingesReleased` reads 334 at t = 0. Links stay
  pulled through. Springs keep their plastic offsets and their released flags, so
  `releasedSpringShare()` is above 0 before anything happens.
- **Fix:** re-copy the three record ranges from the mesh in `reset()`, as `init` does.
- **Confidence:** high.

### 4. Medium: the NaN wave-speed guard may be compiled out under fast math

- **Where:** `Solver.metal:2507`, `if (!(fastest >= 0.0f) || isinf(fastest))`. Introduced in
  3caa3e4.
- **Why:** `ShaderLibrary.make` compiles with `options: nil` (`StructureTypes.swift:1718`), which
  turns fast math on. The compiler may then fold `isinf` to false and rewrite `!(x >= 0)` as
  `x < 0`.
- **Expected wrong output:** a NaN speed slips through. `max(NaN, 1e-6)` gives 1e-6, so dt is
  `cfl·dx/1e-6`, the 0.6 s step the comment there warns of. `maxOverpressure` does not go NaN
  either, so the host's stability check may miss it. The same file already notes that fast math may
  drop a NaN test (`brokenFace`).
- **Fix:** test the bits, for example `as_type<uint>(fastest) >= 0x7F800000u` (the speed is never
  negative).
- **Confidence:** medium, because it depends on the compiler.

### 5. Medium: a failed pool growth leaves the second refinement level split between old and new buffers

- **Where:** `Sources/BlastCore/Refinement.swift:832-913`. The first level swaps its shared buffers
  (`fineMask`, `fineOccupancy`, `fine[0]`) at `:872`, before the per-level buffers are regrown at
  `:877-903`. `growPools` (`BlastSolver.swift:2361-2379`) silently catches a throw.
- **Introduced:** b402210, "Refined pools grow as they are used".
- **Trigger:** a run with two refinement levels where a `makeBuffer` call after `:872` returns nil,
  for example on low memory.
- **Expected wrong output:** the second level keeps writing to the old buffers at the old offset.
  Kernels that reach it through the first level's buffers then read the new, zero-filled block:
  - the structure's deep-air loads (`BlastSolver.swift:1241-1256`) read ρ = 0, giving NaN or minus
    the ambient pressure;
  - the next successful growth copies the stale child region and loses what the second level
    computed in between.

  The comment that a failure part way does no harm holds only when there is no second level.
- **Fix:** allocate everything first and swap at the end, or roll back on failure.
- **Confidence:** medium. The mechanism is clear by reading, but it needs an allocation failure.

### 6. Medium: a timber material anywhere changes the through-thickness rule of every shell

- **Where:** `ShellSolver.swift:1765-1780` (`thicknessRule`). Introduced in 42c7d1c.
- **What happens:** if any material is timber, every shell element uses 3- to 5-point Gauss–Lobatto
  pieces instead of `gaussLegendre(shellLayers)` (8 points by default). That includes concrete slabs
  and models where only a beam is timber.
- **Expected wrong output:** adding one glulam beam to a concrete-slab model moves the slabs from 8
  Gauss points to 5 Lobatto points through the depth. Their cracking and yield shift when an
  unrelated material is added.
- **Fix:** choose the rule per element from its own material, or apply it only when a shell is
  timber.
- **Confidence:** medium. The code clearly does this, and the doc comment suggests the rule was
  partly deliberate, but it does not say the rule should apply when no shell is timber.

### 7. Low: autoreleased command buffers pile up while structures settle

- **Where:** `settleStructures` in `BlastSolver.swift`, at about `:733`. It loops up to 1 s of body
  time per body, through `advanceAlone`, which commits and waits on command buffers
  (`StructureSolver.swift:1979`, `ShellSolver.swift:1734`). It also reads node buffers through
  `contents()` (`motion()`, `displacements()`). There is no `autoreleasepool` around the loop.
- **Expected wrong output:** memory grows during settling, by millions of substeps' worth of
  command buffers when the critical step is about 1e-7 s. Results are not affected. Of the callers
  checked, only `ValidationEnsemble` wraps the call in a pool.
- **Confidence:** medium.

### 8. Low: a torn laminated-glass interlayer still counts as a dowel bar across the second axis

- **Where:** `Shell.metal:1083-1093` and `:1172-1218`. Introduced in 3009f7e.
- **What happens:** the interlayer's state lives only in `bars[..*2 + 0]`, but the crossing loop also
  reads `bars[..*2 + 1].plastic`, which is never set. So `crossing.y` keeps the film's area after it
  tears (`plastic = 1e9`).
- **Expected wrong output:** cracked glass keeps a small shear capacity across its second axis after
  the film has gone. The capacity is small, because it is set by the interlayer's stresses of a few
  MPa.
- **Confidence:** medium.

### 9. Low: an anchorage friction exponent of 1 or more makes shear capacity jump near zero pressure

- **Where:** `Structure.metal:2967-2970` (`anchorTraction`). The limit is `μ·(p/p_ref)^(−n)·p`, and
  `Anchorage.validate` only requires n ≥ 0. Introduced in 68c2327.
- **Expected wrong output:**
  - for n = 1, the limit stays at μ·p_ref as p tends to 0 but is 0 at p = 0;
  - for n above 1, it grows without bound.

  The built-in 0.20 is fine; only a value a user enters can hit this.
- **Fix:** require n < 1 in `validate`.
- **Confidence:** high on the mathematics, low on how much it matters.

### Design note, not a bug

The structure's cut-cell geometry (`setUpStructureCut`) is fixed at each `restart()` from the models
as built. Closed faces and kept-air cells stay where a wall stood even after it erodes or moves.
The documentation says the geometry is as built, so this may be intended for this stage.

### Checked and found sound

- **Function constants:** every index is set with its declared type: 2 (`.uint`); 5, 6, 7, 13, 14
  and 15 in Solver.metal; 0, 1, 3, 8 and 9 in Structure.metal; 22, 23 and 24 in Shell.metal.
- **Struct mirrors:** these match in the changes: `StepControl` with the clock words,
  `ComponentRecording`, `ShellUniforms` (82 fields), `ShellElement` (52 bytes) and the renderer's
  copy since de75bae, `MaterialParameters`, `StructureUniforms`, `CouplingUniforms`,
  `DeflagrationUniforms`, `AnchorLaw`, `FacadeBand` and `TerrainUniforms`. The lint agrees.
- **Zero steps:** every new kernel returns early on `dt <= 0`. The envelope clock cannot spin,
  because `binS > 0` is checked.
- **NaN guards:**
  - the congested flame floors k, ε and porosity;
  - `reflectedPressure` keeps p ≥ 1 and ρ ≥ 1e-6;
  - `flattened` catches NaN;
  - `cutMean` and `refineRestrict` keep the old state when every fine cell is solid;
  - the shells' rate, buckling and spring laws guard their divisions and logarithms.
- **Races:** the structure-cut redistribution, links, hinges and pairs sum in a fixed order with no
  float atomics. The glass gate is written in one pass and read in the next. Only lane 0 touches
  `starts` in `finishComponent`.
- **Units:** Kingery–Bulmash arrival is in seconds and impulse in Pa·s. `arrivalPa` is compared with
  overpressure in Pa. The 2° rotation is converted to radians. The facade-band threshold is in Pa.
- **Already present at 8fc1145:** the non-congested flame computes `sqrt(turbulent/laminar)`
  unclamped and relies on `max(NaN, 1)`, which fast math does not guarantee. It is not new this
  week, but it is the same class of issue as finding 4.

The branch is ready for the Studio to review.
