import Foundation
import Metal
import RadialBlast
import simd

/// GPU finite-volume solver for the compressible Euler equations around rigid obstacles.
///
/// The solver is not thread-safe: drive it from one isolation domain. Stepping is split into
/// `encodeBatch` / `completeBatch` so an app can commit work without blocking, while
/// `advance(steps:)` and `advance(until:)` wrap the pair synchronously for tools and tests.
public final class BlastSolver {
    public static let maxStepsPerBatch = 256
    /// With a body, how many steps apart the decisions that change what is encoded are taken:
    /// how many structural substeps each step may need (which caps the air's step), whether the
    /// air has gone quiet enough to freeze, and whether the body has failed (which brings in
    /// contact and debris). Batches end at these checkpoints, so that the decisions depend only
    /// on the step count, never on how the steps were batched.
    public static let checkpointInterval = 64
    public static let maxGauges = 64

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let grid: Grid
    public var configuration: SolverConfiguration

    /// Simulated time in seconds since the last `restart()`.
    public private(set) var time: Double = 0
    public private(set) var stepCount = 0
    /// The run's clock on the GPU, in ticks of 2^-40 s (`StepControl.clock`), carried from batch to
    /// batch: the steps' times it gives are the same however the run is batched.
    private var clockTicks: UInt64 = 0
    private var exposurePlane: ExposurePlane?
    /// The one-dimensional solution a charge was mapped from, where it was and how far it reached,
    /// for an exposure plane set up after it (`configureExposurePlane`); nil otherwise.
    var mappedStart:
        [(blast: SphericalBlast, centre: SIMD3<Float>, radius: Float, charge: Charge, mirrors: Int)] =
            []
    /// How far out each mapped charge was laid from its one-dimensional solution, m; empty for the
    /// balloon.
    public var mappedRadii: [Float] { mappedStart.map(\.radius) }
    /// The latest a mapped start may begin, s: its one-dimensional solution stops there should the
    /// shock not have reached its radius yet, so that a short run still steps the grid. Nil for no
    /// limit; the app sets half the run's duration. Takes effect at the next `load`.
    public var mappedStartLatest: Double?
    private var exposureNeedsInitialSample = false
    private(set) var envelopeExposure: EnvelopeExposure?
    private var envelopeNeedsInitialSample = false
    private(set) var envelopeComponentRecorder: EnvelopeComponentRecorder?
    private(set) var envelopeVenting: EnvelopeVenting?
    private var componentsNeedInitialSample = false
    private var gpuProfiler: BatchGPUProfiler?
    public private(set) var lastBatchGPUProfile: BatchGPUProfile?

    /// Records stationary voxel-face exposure. Deformable reference bodies observed must be fully
    /// pinned; other bodies may move, and never take the air beside the faces recorded (see
    /// `keepAir`). Must be configured before the first step after loading. Ordinary runs allocate no
    /// recorder.
    public func configureEnvelopeExposure(objects: [SceneObject]) throws {
        let mask = try stationaryMask(observing: objects)
        let exposure = try EnvelopeExposure(
            device: device, library: library, grid: grid,
            mask: mask, objects: objects)
        envelopeExposure = exposure
        try keepAir(exposure.faces.map(\.fluid))
        envelopeNeedsInitialSample = true
    }

    /// Records each envelope component's load through the run (`EnvelopeComponent`,
    /// `EnvelopeComponentHistory`), on the same terms as `configureEnvelopeExposure`; it can run
    /// beside it or alone. Ordinary runs allocate no recorder.
    public func configureEnvelopeComponents(objects: [SceneObject], options: EnvelopeHistoryOptions) throws {
        let mask = try stationaryMask(observing: objects)
        let recorder = try EnvelopeComponentRecorder(
            device: device, library: library, grid: grid, mask: mask, objects: objects, options: options)
        envelopeComponentRecorder = recorder
        try keepAir(recorder.faces.map(\.fluid))
        componentsNeedInitialSample = true
        facadeBand = nil
        applyFacadeBand()
    }

    /// The air beside the component recorder's faces (their fluid cells and a cell round them),
    /// and about each structure's solids (a cell beyond them), in which refinement is held while
    /// loaded (`SolverConfiguration.refinementHoldsEnvelopes`, `refinementHoldsStructures`).
    private var facadeBand: MTLBuffer?

    /// Sets the band on each refined level, or takes it off. The structures' part follows their
    /// solids as built, not as they move: it is made afresh whenever the levels are.
    private func applyFacadeBand() {
        let envelopes = configuration.refinementHoldsEnvelopes.flatMap { threshold in
            envelopeComponentRecorder.map { ($0, threshold) }
        }
        let structures = configuration.refinementHoldsStructures.flatMap { threshold in
            bodies.isEmpty ? nil : (bodies.map(\.model), threshold)
        }
        guard envelopes != nil || structures != nil, !refinementLevels.isEmpty else {
            facadeBand = nil
            for level in refinementLevels {
                level.facadeBand = nil
                level.facadeBandParameters.on = 0
            }
            return
        }
        let threshold = min(envelopes?.1 ?? .infinity, structures?.1 ?? .infinity)
        if facadeBand == nil {
            facadeBand = device.makeBuffer(length: max(1, grid.cellCount), options: .storageModeShared)
        }
        if let buffer = facadeBand {
            let band = buffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
            memset(band, 0, grid.cellCount)
            for model in structures?.0 ?? [] {
                for solid in model.solids {
                    // The cells whose centres lie within a cell of the solid.
                    let low = simd_max(SIMD3<Int>(((solid.min / grid.cellSize) - 1.5).rounded(.up)), .zero)
                    let high = simd_min(
                        SIMD3<Int>(((solid.max / grid.cellSize) + 0.5).rounded(.down)),
                        SIMD3(grid.nx, grid.ny, grid.nz) &- 1)
                    guard all(low .<= high) else { continue }
                    for k in low.z...high.z {
                        for j in low.y...high.y {
                            for i in low.x...high.x { band[grid.index(i, j, k)] = 1 }
                        }
                    }
                }
            }
            for face in envelopes?.0.faces ?? [] {
                let index = Int(face.fluid)
                let cell = SIMD3(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
                for dz in -1...1 {
                    for dy in -1...1 {
                        for dx in -1...1 where grid.contains(cell.x + dx, cell.y + dy, cell.z + dz) {
                            band[grid.index(cell.x + dx, cell.y + dy, cell.z + dz)] = 1
                        }
                    }
                }
            }
            facadeBand = buffer
        }
        for level in refinementLevels {
            level.facadeBand = facadeBand
            level.facadeBandParameters = FacadeBandParameters(
                nx: UInt32(grid.nx), ny: UInt32(grid.ny), nz: UInt32(grid.nz),
                ratio: UInt32(level.parentScale),
                threshold: threshold, ambient: configuration.ambientPressure, on: facadeBand == nil ? 0 : 1)
        }
    }

    /// Lets the envelopes' glazing break in the air (building-envelopes.md, "Venting"): each pane of
    /// the components recorded (`configureEnvelopeComponents`, which must come first) takes the glass
    /// of its building's construction, steps it with the air, and opens in the air when it breaks;
    /// each wall, roof and slab likewise takes its one-way systems (`EnvelopeWallFailure`) and
    /// opens when its damage is failed; each building's rooms are followed. In refined air the
    /// finer cells under an opened component open too, in the patches placed and those placed
    /// later; under gravity an opened cell holds the background at rest at its height.
    public func configureEnvelopeVenting(
        objects: [SceneObject], constructions: (UUID) -> EnvelopeConstruction
    )
        throws
    {
        guard let recorder = envelopeComponentRecorder else {
            throw BlastError.allocationFailed("envelope venting without the component recorder")
        }
        let mask = try stationaryMask(observing: objects)
        envelopeVenting = try EnvelopeVenting(
            device: device, library: library, grid: grid, mask: mask, objects: objects,
            components: recorder.components, rigidBoxes: rigidBoxes ?? [], constructions: constructions,
            equivalents: zip(recorder.plateEntry, recorder.stripEntry).map { ($0, $1) })
        for level in refinementLevels { level.setPanes(ventedPanes) }
    }

    /// Venting's panes as the refined levels take them.
    private var ventedPanes: (cells: MTLBuffer, status: MTLBuffer, lookup: PaneLookup)? {
        envelopeVenting.map { ($0.sortedPaneCellBuffer, $0.statusBuffer, $0.paneLookup) }
    }

    /// When fragments hole envelope panes, by component id, s from the start (`FragmentCloud.paneHoles`):
    /// with venting on, each opens in the air on the step the run's clock reaches it, before its
    /// glass would break. Kept across restarts.
    public var ventsGlazing: Bool { envelopeVenting != nil }

    public func setEnvelopePaneHoles(_ holes: [String: Double]) {
        precondition(!batchInFlight, "Cannot set pane holes during a batch")
        envelopeVenting?.setHoles(holes)
    }

    /// Holes through envelope walls, roofs and slabs, with venting on: each `(owner, time s,
    /// position m, area m²)`, as fragments perforate them (`FragmentCloud.envelopeHoles`). Each goes
    /// through the wall, roof or slab of `owner` whose region holds its position (within a cell),
    /// as the column of its cells there; a column opens on the run's clock when the holes in it
    /// reach half its face (a cell's face, dx²), and a hole larger than that opens every column
    /// whose centre lies within its radius, the one it strikes among them. Replaces any set before;
    /// call before the run.
    public func setEnvelopeWallHoles(
        _ holes: [(owner: UUID, time: Double, position: SIMD3<Float>, areaM2: Float)]
    )
        throws
    {
        precondition(!batchInFlight, "Cannot set wall holes during a batch")
        guard let venting = envelopeVenting else { return }
        let dx = grid.cellSize
        let face = dx * dx
        let counts = [grid.nx, grid.ny, grid.nz]
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        func range(_ low: Float, _ high: Float, _ axis: Int) -> Range<Int> {
            let lower = min(max(Int((low / dx - 0.5).rounded(.up)), 0), counts[axis])
            let upper = min(max(Int((high / dx - 0.5).rounded(.up)), lower), counts[axis])
            return lower..<upper
        }
        let components = venting.components
        let candidates = components.indices.filter {
            [.wall, .roof, .slab].contains(components[$0].kind)
        }
        struct Column: Hashable {
            var component: Int
            var u: Int
            var v: Int
        }
        var area: [Column: Float] = [:]
        var opens: [Column: Double] = [:]
        for hole in holes.sorted(by: { $0.time < $1.time }) {
            // The component struck: of its owner, its region (grown by a cell) holding the point,
            // the nearest through its thickness.
            let struck = candidates.filter { components[$0].owner == hole.owner }.compactMap {
                n -> (Int, Float)? in
                let region = components[n].region
                let grown = Box(
                    min: region.min - SIMD3(repeating: dx), max: region.max + SIMD3(repeating: dx))
                guard grown.contains(hole.position) else { return nil }
                let axis = components[n].axis
                let middle = (region.min[axis] + region.max[axis]) / 2
                return (n, abs(hole.position[axis] - middle))
            }.min { $0.1 < $1.1 }
            guard let n = struck?.0 else { continue }
            let (u, v) = components[n].inPlaneAxes
            let at = Column(
                component: n, u: Int(floor(hole.position[u] / dx)), v: Int(floor(hole.position[v] / dx)))
            if hole.areaM2 > face / 2 {
                // A hole larger than half a face: every column within its radius, and its own.
                let radius = (hole.areaM2 / .pi).squareRoot()
                let reach = Int((radius / dx).rounded(.up))
                for i in (at.u - reach)...(at.u + reach) {
                    for j in (at.v - reach)...(at.v + reach) {
                        let du = (Float(i) + 0.5) * dx - hole.position[u]
                        let dv = (Float(j) + 0.5) * dx - hole.position[v]
                        let column = Column(component: n, u: i, v: j)
                        if column == at || du * du + dv * dv <= radius * radius, opens[column] == nil {
                            opens[column] = hole.time
                        }
                    }
                }
                continue
            }
            area[at, default: 0] += hole.areaM2
            if area[at]! >= face / 2, opens[at] == nil { opens[at] = hole.time }
        }
        var list: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] = []
        for (column, time) in opens.sorted(by: {
            ($0.value, $0.key.component, $0.key.u, $0.key.v) < (
                $1.value, $1.key.component, $1.key.u, $1.key.v
            )
        }) {
            let component = components[column.component]
            let region = component.region.holdingCells(of: dx)
            let (u, v) = component.inPlaneAxes
            guard (0..<counts[u]).contains(column.u), (0..<counts[v]).contains(column.v) else { continue }
            var cells: [Int] = []
            for k in range(region.min[component.axis], region.max[component.axis], component.axis) {
                var c = [0, 0, 0]
                c[component.axis] = k
                c[u] = column.u
                c[v] = column.v
                let index = grid.index(c[0], c[1], c[2])
                if mask[index] != 0 { cells.append(index) }
            }
            guard !cells.isEmpty, let owner = venting.owners.firstIndex(of: component.owner) else { continue }
            list.append((column.component, owner, cells, time, "fragments"))
        }
        fragmentOpenings = list
        try applyEnvelopeOpenings()
    }

    /// The holes fragments make and the breaches close-in charges make, as venting opens them.
    private var fragmentOpenings: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] =
        []
    private var breachOpenings: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] = []

    private func applyEnvelopeOpenings() throws {
        guard let venting = envelopeVenting else { return }
        try venting.setBreaches(fragmentOpenings + breachOpenings)
        for level in refinementLevels { level.setPanes(ventedPanes) }
    }

    /// Close-in charges against envelope concrete, with venting on: each wall, roof and slab of
    /// reinforced concrete or blockwork judged by UFC 3-340-02's threshold spall and breach curves
    /// (`UFCSpallBreach`) column by column across its face, at the range from the charge's centre
    /// to the column's middle on the face nearer it; the columns past the breach threshold open
    /// when the blast reaches them (Kingery–Bulmash's arrival at that range, at once within 0.2
    /// m/kg^(1/3)). `casing` kg of steel round the charge (a cased charge's, from its fragments).
    /// The burst counts as on the surface when the charge touches the slab or sits within two of
    /// its radii of the ground, and in free air otherwise. Each component's worst outcome is kept
    /// for its damage (`EnvelopeVentingSnapshot.closeIn`); spalling opens nothing, as it does not
    /// go through. Replaces any set before; call before the run.
    @discardableResult
    public func setEnvelopeCloseIn(
        charges: [(charge: Charge, casing: Float)], constructions: (UUID) -> EnvelopeConstruction
    ) throws -> [String: UFCSpallBreach.Outcome] {
        precondition(!batchInFlight, "Cannot set breaches during a batch")
        guard let venting = envelopeVenting else { return [:] }
        let dx = grid.cellSize
        let counts = [grid.nx, grid.ny, grid.nz]
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        func range(_ low: Float, _ high: Float, _ axis: Int) -> Range<Int> {
            let lower = min(max(Int((low / dx - 0.5).rounded(.up)), 0), counts[axis])
            let upper = min(max(Int((high / dx - 0.5).rounded(.up)), lower), counts[axis])
            return lower..<upper
        }
        var outcomes: [String: UFCSpallBreach.Outcome] = [:]
        var list: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] = []
        for (charge, casing) in charges where charge.mass > 0 {
            let mass = Double(charge.mass)
            let radius = cbrt(3 * mass / (4 * .pi * 1_600))
            let centre = SIMD3<Double>(charge.position)
            for (n, component) in venting.components.enumerated()
            where [.wall, .roof, .slab].contains(component.kind) {
                let construction = constructions(component.owner)
                let isRoof = component.kind != .wall
                let kind = isRoof ? construction.roof : construction.walls
                guard kind == .reinforcedConcrete || kind == .reinforcedBlockwork,
                    let owner = venting.owners.firstIndex(of: component.owner)
                else { continue }
                let thickness = Double(isRoof ? construction.roofThicknessM : construction.wallThicknessM)
                let material = isRoof ? StructureMaterial.reinforcedConcrete : construction.wallMaterial
                let region = component.region.holdingCells(of: dx)
                let axis = component.axis
                let (u, v) = component.inPlaneAxes
                // The face nearer the charge.
                let face =
                    abs(Double(region.min[axis]) - centre[axis])
                        < abs(Double(region.max[axis]) - centre[axis])
                    ? region.min[axis] : region.max[axis]
                var worst = UFCSpallBreach.Outcome.none
                for i in range(region.min[u], region.max[u], u) {
                    for j in range(region.min[v], region.max[v], v) {
                        var point = SIMD3<Double>(repeating: 0)
                        point[axis] = Double(face)
                        point[u] = (Double(i) + 0.5) * Double(dx)
                        point[v] = (Double(j) + 0.5) * Double(dx)
                        let distance = simd_distance(point, centre)
                        let contact = distance <= radius * 1.01
                        let surface = contact || centre.z <= 2 * radius
                        let outcome = UFCSpallBreach.outcome(
                            thickness: thickness, range: max(distance, radius),
                            strength: Double(material.compressiveStrength),
                            charge: mass, casing: Double(casing), surface: surface, contact: contact)
                        worst = max(worst, outcome)
                        guard outcome == .breached else { continue }
                        var cells: [Int] = []
                        for k in range(region.min[axis], region.max[axis], axis) {
                            var c = [0, 0, 0]
                            c[axis] = k
                            c[u] = i
                            c[v] = j
                            let index = grid.index(c[0], c[1], c[2])
                            if mask[index] != 0 { cells.append(index) }
                        }
                        guard !cells.isEmpty else { continue }
                        let arrival =
                            KingeryBulmash.point(at: distance / cbrt(mass))?.arrival(mass: mass) ?? 0
                        list.append((n, owner, cells, arrival, "breach"))
                    }
                }
                if worst != .none { outcomes[component.id] = max(outcomes[component.id] ?? .none, worst) }
            }
        }
        venting.closeIn = outcomes
        breachOpenings = list
        try applyEnvelopeOpenings()
        return outcomes
    }

    /// The same from the fragments' perforations of walls, roofs and slabs (those without a pane).
    public func setEnvelopeWallHoles(_ holes: [EnvelopeHole]) throws {
        try setEnvelopeWallHoles(
            holes.filter { $0.pane == nil }.map { ($0.owner, $0.time, $0.position, $0.areaM2) })
    }

    /// The panes broken so far and what each building's rooms have seen, with venting on.
    public func envelopeVentingSnapshot() -> EnvelopeVentingSnapshot? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeVenting?.snapshot()
    }

    /// Cells of air a moving body's outline may not take: beside the stationary envelopes' recorded
    /// faces, which the recorders read; nil when no body moves beside them.
    private var keptAirBuffer: MTLBuffer?

    /// Marks `cells` as kept air (see `remaskPrepare`), where a body can move.
    private func keepAir(_ cells: [UInt32]) throws {
        guard hasBody, !cells.isEmpty else { return }
        if keptAirBuffer == nil {
            guard let buffer = device.makeBuffer(length: grid.cellCount, options: .storageModeShared) else {
                throw BlastError.allocationFailed("kept air beside envelopes")
            }
            memset(buffer.contents(), 0, grid.cellCount)
            buffer.label = "kept air"
            keptAirBuffer = buffer
        }
        let kept = keptAirBuffer!.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        for cell in cells where Int(cell) < grid.cellCount { kept[Int(cell)] = 1 }
    }

    /// The cells kept air beside the envelopes' recorded faces, or nil.
    var keptAirCells: [Int]? {
        guard let keptAirBuffer else { return nil }
        let kept = keptAirBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        return (0..<grid.cellCount).filter { kept[$0] != 0 }
    }

    /// The components recorded, in the order of their histories.
    public func envelopeComponents() -> [EnvelopeComponent]? { envelopeComponentRecorder?.components }

    /// Each component's history up to now.
    public func envelopeComponentHistories() -> [EnvelopeComponentHistory]? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeComponentRecorder?.histories(elapsed: time)
    }

    /// The air's mask before the first step, for the envelope recorders observing `objects`.
    /// Envelopes are stationary; a detailed structure observed as one (a damage reference's) must be pinned, with
    /// every other body, while beside envelopes alone other bodies may move.
    private func stationaryMask(observing objects: [SceneObject]) throws -> UnsafeBufferPointer<UInt8> {
        precondition(!batchInFlight, "Cannot configure observers during a batch")
        let observesStructures = objects.contains { $0.structure != nil }
        // Before the first step: a mapped start's clock starts at its solution's time.
        guard stepCount == 0, experimentalBoxes.isEmpty,
            !observesStructures
                || bodies.allSatisfy({ body in
                    var fixed = true
                    if let solid = body.solids {
                        let nodes = UnsafeBufferPointer(
                            start: solid.nodeBuffer.contents().bindMemory(
                                to: StructureNode.self, capacity: solid.nodeCount), count: solid.nodeCount)
                        fixed = fixed && nodes.allSatisfy { $0.mass == 0 || $0.isFixed }
                    }
                    if let shell = body.shells {
                        let nodes = UnsafeBufferPointer(
                            start: shell.nodeBuffer.contents().bindMemory(
                                to: ShellNode.self, capacity: shell.nodeCount), count: shell.nodeCount)
                        fixed = fixed && nodes.allSatisfy { $0.mass == 0 || $0.isClamped }
                    }
                    return fixed
                })
        else { throw BlastError.allocationFailed("stationary envelope observation before the first step") }
        return UnsafeBufferPointer(
            start: maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount),
            count: grid.cellCount)
    }

    public func envelopeExposureSnapshot() -> [EnvelopeExposureSnapshot]? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeExposure?.snapshot(grid: grid, elapsed: time)
    }

    /// Whether the envelope recorders read a face whose air is in a still tile as the still air
    /// (the default; the same bits) or from its cell, for measuring what that saves.
    public var envelopeStillTileSkipping: Bool {
        get { envelopeExposure?.skipStillTiles ?? envelopeComponentRecorder?.skipStillTiles ?? true }
        set {
            envelopeExposure?.skipStillTiles = newValue
            envelopeComponentRecorder?.skipStillTiles = newValue
        }
    }

    public func envelopeExposureSummaries() -> [EnvelopeExposureSummary]? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeExposure?.summaries(grid: grid, elapsed: time)
    }

    func clearEnvelopeExposure() {
        envelopeExposure = nil
        envelopeNeedsInitialSample = false
        envelopeComponentRecorder = nil
        componentsNeedInitialSample = false
        envelopeVenting = nil
        for level in refinementLevels { level.setPanes(nil) }
        keptAirBuffer = nil
    }

    /// Enables fixed spatial probes before stepping. Does not change the air solution.
    /// Snapshot arrays are x-fast; stencils touching solids and unreached arrivals are null.
    /// Probe spacing defaults to the air grid and must divide both horizontal domain extents.
    public func configureExposurePlane(heightM: Float, arrivalThresholdPa: Float, spacingM: Float? = nil)
        throws
    {
        precondition(!batchInFlight && stepCount == 0, "Configure probes before stepping")
        let plane = try ExposurePlane(
            device: device, library: library, grid: grid, height: heightM,
            threshold: arrivalThresholdPa, spacing: spacingM)
        // A charge mapped from one dimension has already passed the plane within its mapped radius:
        // there it takes the solution's own peak, impulse and arrival.
        for mappedStart in mappedStart {
            plane.seed(mappedStart.blast, centre: mappedStart.centre, radius: mappedStart.radius)
        }
        exposurePlane = plane
        exposureNeedsInitialSample = true
    }

    public func exposureSnapshot() -> ExposurePlaneSnapshot? {
        precondition(!batchInFlight, "Cannot read probes while a batch is in flight")
        return exposurePlane?.snapshot(grid: grid, elapsed: time)
    }

    /// Splits compute encoders at stage boundaries for diagnostic GPU timestamps.
    /// Run throughput benchmarks separately with this disabled.
    /// With `detailed`, the air's stages each get an encoder of their own too (see
    /// `BatchGPUProfile.stages`); keep batches to a few steps, as a batch times at most 2,048
    /// encoders.
    public func enableGPUProfiling(_ enabled: Bool, detailed: Bool = false) throws {
        precondition(!batchInFlight)
        gpuProfiler = enabled ? try BatchGPUProfiler(device: device, detailed: detailed) : nil
        lastBatchGPUProfile = nil
    }
    /// One pressure history per gauge, in the order passed to `setGauges`.
    public private(set) var gaugeHistories: [[GaugeSample]] = []
    /// `rgba16Float` volume: overpressure and peak overpressure (both in units of ambient
    /// pressure), positive impulse (Pa s) and a solid flag. Refreshed on request.
    public let visualizationTexture: MTLTexture
    public private(set) var bodies: [StructuralBody] = []
    /// Compatibility views for single-body clients. Multi-body clients use `bodies` or IDs.
    public var structure: StructureSolver? { bodies.first?.solids }
    public var shells: ShellSolver? { bodies.first?.shells }
    public var mixed: MixedStructure? { bodies.first?.mixed }
    public var hasBody: Bool { !bodies.isEmpty }
    /// The most patches the first level's pool may grow to.
    public var refinementPatchCapacity: Int { refinement?.capacity ?? 0 }
    /// Each refined level's pool since the run's start: the most patches it may hold, those it
    /// holds now, the most in use at once, and whether it ran out, so that some blocks the shock
    /// wanted refined were not (a larger `refinementMemory` gives the run its full refinement).
    public var refinementPools: [(capacity: Int, held: Int, most: Int, ranOut: Bool)] {
        precondition(!batchInFlight, "Cannot read the refinement's pool during a batch")
        return refinementLevels.map { ($0.capacity, $0.maxPatches, $0.poolUse.most, $0.poolUse.ranOut) }
    }
    /// Whether a pool ran out while it could still have grown, so that the run refined less than
    /// one whose pools were made at full size would have: it grew too late, which its room ahead
    /// (`makeRefinementRoom`) is meant never to allow.
    public private(set) var refinementPoolGrewLate = false
    /// The patches the second level's pool may grow to (0 without one).
    public var finerRefinementPatchCapacity: Int { finerRefinement?.capacity ?? 0 }
    /// The patches each refined level holds after the last regrid, the first level first.
    public var refinementPatchesInUse: [Int] { refinementLevels.map(\.patchCount) }
    private var bodyStep: Float? { bodies.map(\.criticalTimeStep).min() }
    public func body(id: UUID) -> StructuralBody? { bodies.first { $0.id == id } }
    public var couplingStatistics: CouplingStatistics {
        let cells = denseCouplingCells
        let active =
            tiledCoupling.map { min(Int(wallVelocityBuffer.contents().load(as: UInt32.self)), $0.capacity) }
            ?? 0
        return CouplingStatistics(
            layout: tiledCoupling == nil ? "dense" : "tiled", denseCells: cells,
            capacityCells: tiledCoupling?.capacityCells ?? cells,
            activeTiles: active, tileCapacity: tiledCoupling?.capacity ?? 0,
            bytes: (occupancyBuffer?.length ?? 0) + (combinedOccupancyBuffer?.length ?? 0)
                + (debrisExchangeBuffer?.length ?? 0) + (debrisAreaBuffer?.length ?? 0)
                + (couplingTiles?.length ?? 0) + (hasBody ? wallVelocityBuffer.length : 0))
    }

    /// Measures only repeated boundary composition/remasking on the current geometry.
    /// For benchmark drivers: does not advance time; run on a separate, stationary fixture.
    public func measureCouplingGPU(repetitions: Int) throws -> Double {
        precondition(!batchInFlight && repetitions > 0)
        guard let command = commandQueue.makeCommandBuffer(),
            let encoder = command.makeComputeCommandEncoder()
        else { throw BlastError.allocationFailed("coupling benchmark") }
        for _ in 0..<repetitions { encodeRemask(encoder) }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        return (command.gpuEndTime - command.gpuStartTime) / Double(repetitions)
    }
    /// Independent bodies' envelopes or resolved cells overlap.
    public var bodyEnvelopesOverlap: Bool {
        interactionBuffer?.contents().load(as: UInt32.self) != nil
            && interactionBuffer!.contents().load(as: UInt32.self) & 1 != 0
    }
    /// Bodies came close with contact between them switched off: the run cannot go on.
    public var interObjectContactDetected: Bool { bodyEnvelopesOverlap && !configuration.interBodyContact }
    /// Independent bodies came close, and from then on are encoded a substep at a time, side by
    /// side, in contact with each other.
    public private(set) var bodiesInContact = false
    /// For timing contact between bodies alone: with true, bodies in contact are encoded a
    /// substep at a time as usual but the pairs between them are not (`blastbench
    /// contact-profile`). Never for a result.
    public var bodyContactPairsSkipped = false
    /// Each body's own step overrides from before contact, which shares one step among them all.
    private var stepsBeforeContact: [(solids: Float?, shells: Float?)] = []
    private var bodyContactPipelines: [String: MTLComputePipelineState] = [:]
    private var tiledCoupling: TiledCoupling?
    private var couplingTiles: MTLBuffer?
    private var denseCouplingCells = 0
    private let allocateCouplingPipeline: MTLComputePipelineState
    private let wakeCouplingPipeline: MTLComputePipelineState
    private let haltCouplingPipeline: MTLComputePipelineState
    public var couplingCapacityExceeded: Bool {
        guard tiledCoupling != nil else { return false }
        return wallVelocityBuffer.contents().load(fromByteOffset: 4, as: UInt32.self) != 0
    }
    private var combinedOccupancyBuffer: MTLBuffer?
    private var interactionBuffer: MTLBuffer?
    private var bodyEnvelopeBuffer: MTLBuffer?
    private let bodyComposePipeline: MTLComputePipelineState
    private let haltInteractionPipeline: MTLComputePipelineState
    private let clearEnvelopesPipeline: MTLComputePipelineState
    private let solidEnvelopePipeline: MTLComputePipelineState
    private let shellEnvelopePipeline: MTLComputePipelineState
    private let validateEnvelopesPipeline: MTLComputePipelineState
    /// Sound speed of the undisturbed air, used to bound the fluid time step.
    var ambientSoundSpeed: Float = 340
    var ambientDensity: Float = 1.225
    /// Cells of the air grid, around the structure, whose solid flag follows the structure.
    private var couplingRegion: (origin: SIMD3<Int>, dims: SIMD3<Int>)?
    private var occupancyBuffer: MTLBuffer?
    /// What loose debris takes from the air in each cell of the coupling region during one air step.
    private var debrisExchangeBuffer: MTLBuffer?
    /// The frontal area of the loose debris in each cell of the coupling region.
    private var debrisAreaBuffer: MTLBuffer?
    /// Velocity of the solid in each cell of the coupling region, three floats per cell. A
    /// single zero cell stands in when there is no structure.
    private var wallVelocityBuffer: MTLBuffer
    private let stillWallBuffer: MTLBuffer
    private var experimentalBoxDefinition: MTLBuffer?
    private var experimentalBoxMask: MTLBuffer?
    private var experimentalBoxImpulse: MTLBuffer?
    /// The experimental rigid boxes, as last placed; nil for one taken out of the air.
    private var experimentalBoxes: [RigidBoxBody?] = []
    private var experimentalBoxMaxStep: Float = 0
    var experimentalBoxRemapMode: ExperimentalBoxRemap = .redistribution

    let library: MTLLibrary
    /// The kernels that run on every cell, compiled for one gas model so that the other models'
    /// code is left out of them (see `airModelOf` in Solver.metal).
    private struct CellKernels {
        var sweep: MTLComputePipelineState
        var sweepTiles: MTLComputePipelineState
        var collectTiles: MTLComputePipelineState
        var redistributeCutDefects: MTLComputePipelineState
        var keepStructureCut: MTLComputePipelineState
        var takeStructureCut: MTLComputePipelineState
    }
    /// Structures' outlines as cut cells, when `configuration.structureCutCells` laid them at the
    /// last restart (`StructureCutGeometry`): per cell its record, the records, their walls,
    /// differences and what each sets aside, and the cells that take what is set aside.
    struct StructureCutBuffers {
        var geometry: StructureCutGeometry
        var index: MTLBuffer
        var cells: MTLBuffer
        var records: MTLBuffer
        var walls: MTLBuffer
        var targets: MTLBuffer
        var defects: MTLBuffer
        var passed: MTLBuffer
        var receivers: MTLBuffer
        var shares: MTLBuffer
        var starts: MTLBuffer
        var contributors: MTLBuffer
    }
    private(set) var structureCut: StructureCutBuffers?
    /// The terrain's cut cells, when `configuration.terrainCutCells` laid them at the last load.
    var terrainCut: TerrainCutBuffers?
    /// `CellKernels` for each gas model used so far, with gravity compiled in or not.
    private var cellKernelsByModel: [Int: CellKernels] = [:]
    private let wakeTilesPipeline: MTLComputePipelineState
    private let preparePipeline: MTLComputePipelineState
    private let sampleGaugesPipeline: MTLComputePipelineState
    /// Kernels compiled with gravity in the air, by name, made when first needed.
    private var gravityPipelines: [String: MTLComputePipelineState] = [:]
    private let measurePipeline: MTLComputePipelineState
    private let visualizationPipeline: MTLComputePipelineState
    private let splatPipeline: MTLComputePipelineState
    private let remaskPreparePipeline: MTLComputePipelineState
    private let remaskApplyPipeline: MTLComputePipelineState
    /// Shuts in the terrain's cut slivers under a structure standing on them (`remaskCapSlivers`).
    private let remaskCapSliversPipeline: MTLComputePipelineState
    /// Per column with cut cells, its lowest cell shut in under a structure, plus one (`remaskCapSlivers`).
    var cappedSliverBuffer: MTLBuffer?
    private let debrisExchangePipeline: MTLComputePipelineState
    private let shellSplatPipeline: MTLComputePipelineState
    /// The shells' splat with elements at a pitch compiled in, for bodies that have them.
    private lazy var inclinedShellSplatPipeline: MTLComputePipelineState? = {
        let constants = MTLFunctionConstantValues()
        var pitched = true
        constants.setConstantValue(&pitched, type: .bool, index: 25)
        return try? ShaderLibrary.pipeline("shellSplat", in: library, constants: constants)
    }()
    private let beamSplatPipeline: MTLComputePipelineState

    private let stateBuffers: [MTLBuffer]
    /// Densities of unburnt detonation products and of oxygen in each cell, kept alongside the
    /// state for afterburning; made when the air is filled with afterburning on. Until then a
    /// one-cell stand-in is bound.
    private var speciesBuffers: [MTLBuffer] = []
    private let noSpecies: MTLBuffer
    /// Whether the air carries fuel and oxygen, so that its charges burn.
    private var hasSpecies: Bool { !speciesBuffers.isEmpty }
    /// The current fuel and oxygen, or a placeholder without them.
    private var currentSpecies: MTLBuffer { hasSpecies ? speciesBuffers[current] : noSpecies }
    /// Mass fraction of oxygen in air, and the oxygen TNT's products need to burn completely
    /// (C7H5N3O6 + 5.25 O2 -> 7 CO2 + 2.5 H2O + 1.5 N2), per kilogram.
    static let oxygenInAir: Float = 0.232
    static let oxygenPerFuel: Float = 5.25 * 32 / 227.13
    private var current = 0
    let maskBuffer: MTLBuffer
    /// Solid flags of the rigid blocks alone, which never change.
    private let rigidMaskBuffer: MTLBuffer
    private var needsRigidMaskCapture = true
    private let peakBuffer: MTLBuffer
    private let impulseBuffer: MTLBuffer
    private let controlBuffer: MTLBuffer
    private let maxSpeedBuffer: MTLBuffer
    private let gaugeLogBuffer: MTLBuffer
    private let gaugeCellBuffer: MTLBuffer
    private var gaugeCount = 0
    /// Still air: one flag per tile of 8 x 8 x 8 cells (still, awake, or woken during the last
    /// step), the list of awake tiles, its length, and the sweeps' threadgroup counts.
    static let tileSize = 8
    let tileDims: SIMD3<Int>
    private let tileFlagBuffer: MTLBuffer
    private let tileListBuffer: MTLBuffer
    private let tileCountBuffer: MTLBuffer
    private let tileDispatchBuffer: MTLBuffer
    /// Whether still air is being skipped since the last restart.
    private var tilesEnabled = false
    /// The largest charge deposited since the air was last filled, kg, which sets how fast its
    /// products burn.
    var largestCharge: Float = 0
    /// The deflagration laid down by `load`, if the scenario has one: its flame front and vent
    /// panels (see `Deflagration.metal`). Its unburnt mixture is the species' x.
    var deflagrationStage: DeflagrationStage?
    /// Whether a deflagration's flame burns in the air (rather than only vent panels standing).
    var hasFlame: Bool { deflagrationStage?.deflagration != nil }
    /// Whether the species hold afterburning's detonation products and oxygen (rather than a
    /// deflagration's unburnt mixture, or nothing).
    public var speciesHoldDetonationProducts: Bool { hasSpecies && !hasFlame }
    /// The uniform state the air was last filled with: air still in it is not swept.
    private var stillCell = CellState(Primitive(density: 1.225, pressure: 101_325), gamma: 1.4)
    private var batchInFlight = false
    /// True once the blast has left and the air has been frozen; only the structure advances.
    public private(set) var airIsAsleep = false
    /// The air's last time step (before any clipping to a time limit), which at a checkpoint
    /// sizes the substeps of the steps up to the next.
    private var lastFluidStep: Float = 0
    /// Structural substeps encoded per air step until the next checkpoint.
    private var checkpointSubsteps = 0
    /// The substeps each step of the batch being encoded may take, set with its first part.
    private var batchSubsteps = 0
    /// The finer level of the air, while it is refined (see `SolverConfiguration.refinement`).
    private(set) var refinement: AirRefinement?
    /// The second finer level, refining the first, with `SolverConfiguration.refinementLevels` 2.
    private(set) var finerRefinement: AirRefinement?
    /// With detailed GPU profiling, while a batch is encoded: the encoder now open.
    private var liveEncoder: (() -> MTLComputeCommandEncoder)?
    /// The refined levels, finest last.
    var refinementLevels: [AirRefinement] { [refinement, finerRefinement].compactMap { $0 } }
    /// Per refined level, for the room its pool keeps ahead (`makeRefinementRoom`): the most
    /// patches a step has added, the patches in use at the last look, and whether the pool could
    /// still grow then; and the steps encoded since.
    private var poolGrowth: [Double] = []
    private var poolLive: [Int] = []
    private var poolCouldGrow: [Bool] = []
    private var stepsSincePoolLook = 0
    /// Bound in place of the refinement's buffers while the air is not refined.
    private let refinementPlaceholder: MTLBuffer
    /// The radiative cooling's kernels and buffers while it is on, what the gas has radiated since
    /// the restart, J, and that total at the end of each batch (see `RadiativeCooling`).
    var radiativeCoolingStage: RadiativeCoolingStage?
    /// The air at the ground when it was last filled, from which gravity's hydrostatic background
    /// rises (see `AirGravity`).
    var gravityGround = Primitive(density: 1.225, pressure: 101_325)
    /// Gravity's background for each level, by its cells along a coarse cell's edge, made when
    /// the air is filled or a level first needs one.
    private var gravityTables: [Int: MTLBuffer] = [:]
    /// Sub-grid mixing's eddy viscosity in each coarse cell, worked out before each step's sweeps,
    /// and its kernel, while the air has sub-grid mixing.
    private var viscosityBuffer: MTLBuffer?
    private var viscosityPipeline: MTLComputePipelineState?
    private var periodicPipeline: MTLComputePipelineState?
    public internal(set) var radiatedEnergy = 0.0
    public internal(set) var radiationHistory: [(time: Double, energy: Double)] = []
    /// Per gauge: the finest cell of its cell that holds its point, as x + R (y + R z) for R
    /// finest cells along a coarse cell's edge, or `UInt32.max` to read the coarse cell.
    private let gaugeChildBuffer: MTLBuffer
    /// Each gauge's point (w 1) or none (w 0): a gauge whose cell turns solid reads the fluid cell
    /// beside it nearest the point.
    private let gaugePointBuffer: MTLBuffer
    private var gaugePoints: [SIMD3<Float>?] = []
    /// The congestion's per-cell fields and the turbulence its obstacles make; nil without
    /// congestion, whose code is then left out of the kernels.
    var congestion: CongestionBuffers?
    /// Its per-cell porosity and drag (`CongestionField.porosityDrag`).
    var congestionBuffer: MTLBuffer? { congestion?.porosityDrag }
    /// The scenario's rigid blocks, whose outline the refined air follows at its own resolution;
    /// What to cut out of the air on the GPU at the end of each batch that reaches its time limit,
    /// as one landing on a frame does, for `airSlice(region:stride:)` and
    /// `fireball(luminousTemperature:)` to return then instead of reading the state on the CPU
    /// while the GPU waits. Set it before encoding a batch that may end on a frame.
    public var frameRequest = FrameRequest()
    /// Built the first time a request is made.
    private(set) var frameExtractor: FrameExtractor?
    /// nil once the mask has been edited by hand.
    var rigidBoxes: [Box]?
    /// The ground's shape the mask was made with; nil for flat ground or once the mask has been
    /// edited by hand. The fine cells follow it as they follow `rigidBoxes`.
    public internal(set) var terrain: Terrain?
    /// The first cell of air above the terrain in each column, x fastest; nil for flat ground.
    public internal(set) var terrainSurface: [Int32]?
    /// Charges laid down in fine cells for refined air (see `deposit`): what each fine cell gained,
    /// density and energy per volume, over the uniform state the air was filled with. Given to the
    /// fine cells at the next `restart()`; forgotten when the air is filled or edited by hand.
    var fineDeposit: [SIMD3<Int>: SIMD2<Float>] = [:]

    public init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue? = nil,
        grid: Grid,
        configuration: SolverConfiguration = SolverConfiguration()
    ) throws {
        self.device = device
        self.grid = grid
        self.configuration = configuration
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw BlastError.allocationFailed("command queue")
        }
        self.commandQueue = queue

        let library = try ShaderLibrary.make(device: device)
        self.library = library
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library)
        }
        wakeTilesPipeline = try pipeline("wakeTiles")
        preparePipeline = try pipeline("prepareStep")
        sampleGaugesPipeline = try pipeline("sampleGauges")
        measurePipeline = try pipeline("measureWaveSpeed")
        visualizationPipeline = try pipeline("updateVisualization")
        splatPipeline = try pipeline("splatStructure")
        bodyComposePipeline = try pipeline("composeBodyOccupancy")
        allocateCouplingPipeline = try pipeline("allocateCouplingTiles")
        wakeCouplingPipeline = try pipeline("wakeCouplingTiles")
        haltCouplingPipeline = try pipeline("haltCouplingCapacity")
        haltInteractionPipeline = try pipeline("haltBodyInteraction")
        clearEnvelopesPipeline = try pipeline("clearBodyEnvelopes")
        solidEnvelopePipeline = try pipeline("solidBodyEnvelope")
        shellEnvelopePipeline = try pipeline("shellBodyEnvelope")
        validateEnvelopesPipeline = try pipeline("validateBodyEnvelopes")
        remaskPreparePipeline = try pipeline("remaskPrepare")
        remaskCapSliversPipeline = try pipeline("remaskCapSlivers")
        remaskApplyPipeline = try pipeline("remaskApply")
        debrisExchangePipeline = try pipeline("debrisExchange")
        shellSplatPipeline = try pipeline("shellSplat")
        beamSplatPipeline = try pipeline("beamSplat")

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let cells = grid.cellCount
        let stateLength = cells * MemoryLayout<CellState>.stride
        stateBuffers = [try buffer(stateLength, "state A"), try buffer(stateLength, "state B")]
        noSpecies = try buffer(MemoryLayout<SIMD2<Float>>.stride, "no species")
        maskBuffer = try buffer(cells, "solid mask")
        rigidMaskBuffer = try buffer(cells, "rigid mask")
        stillWallBuffer = try buffer(3 * MemoryLayout<Float>.stride, "still wall")
        memset(stillWallBuffer.contents(), 0, stillWallBuffer.length)
        wallVelocityBuffer = stillWallBuffer
        peakBuffer = try buffer(cells * MemoryLayout<Float>.stride, "peak overpressure")
        impulseBuffer = try buffer(cells * MemoryLayout<Float>.stride, "impulse")
        controlBuffer = try buffer(MemoryLayout<StepControl>.stride, "step control")
        // The fastest wave and the largest overpressure; with refined levels' own steps, each
        // level's fastest wave.
        maxSpeedBuffer = try buffer(4 * MemoryLayout<UInt32>.stride, "max wave speed and overpressure")
        gaugeLogBuffer = try buffer(
            (Self.maxStepsPerBatch + 1) * (Self.maxGauges + 1) * MemoryLayout<Float>.stride, "gauge log")
        gaugeCellBuffer = try buffer(Self.maxGauges * MemoryLayout<UInt32>.stride, "gauge cells")
        gaugeChildBuffer = try buffer(Self.maxGauges * MemoryLayout<UInt32>.stride, "gauge fine cells")
        memset(gaugeChildBuffer.contents(), 0xFF, gaugeChildBuffer.length)
        gaugePointBuffer = try buffer(Self.maxGauges * MemoryLayout<SIMD4<Float>>.stride, "gauge points")
        refinementPlaceholder = try buffer(64, "no refinement")
        memset(refinementPlaceholder.contents(), 0xFF, refinementPlaceholder.length)
        let tile = Self.tileSize
        tileDims = SIMD3(
            (grid.nx + tile - 1) / tile, (grid.ny + tile - 1) / tile, (grid.nz + tile - 1) / tile)
        let tiles = tileDims.x * tileDims.y * tileDims.z
        tileFlagBuffer = try buffer(tiles, "tile flags")
        tileListBuffer = try buffer(tiles * MemoryLayout<UInt32>.stride, "awake tiles")
        tileCountBuffer = try buffer(MemoryLayout<UInt32>.stride, "awake tile count")
        tileDispatchBuffer = try buffer(3 * MemoryLayout<UInt32>.stride, "tile dispatch")

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = grid.nx
        descriptor.height = grid.ny
        descriptor.depth = grid.nz
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw BlastError.allocationFailed("visualization texture")
        }
        texture.label = "visualization"
        visualizationTexture = texture

        memset(maskBuffer.contents(), 0, cells)
        memset(rigidMaskBuffer.contents(), 0, cells)
        fill(uniform: Primitive(density: 1.225, pressure: configuration.ambientPressure))
    }

    // MARK: - Initial conditions

    /// Sets every cell to the same state and restarts the clock.
    public func fill(uniform primitive: Primitive) {
        let cell = cellState(primitive)
        stillCell = cell
        largestCharge = 0
        fineDeposit = [:]
        for buffer in stateBuffers {
            buffer.contents().bindMemory(to: CellState.self, capacity: grid.cellCount)
                .update(repeating: cell, count: grid.cellCount)
        }
        let wantsSpecies = configuration.afterburning || hasFlame
        if wantsSpecies && !hasSpecies {
            let length = grid.cellCount * MemoryLayout<SIMD2<Float>>.stride
            if let first = device.makeBuffer(length: length, options: .storageModeShared),
                let second = device.makeBuffer(length: length, options: .storageModeShared)
            {
                speciesBuffers = [first, second]
            }
        } else if !wantsSpecies {
            speciesBuffers = []
        }
        // A deflagration's cloud is laid down afterwards (see `depositCloud`).
        let air = SIMD2<Float>(0, hasFlame ? 0 : Self.oxygenInAir * primitive.density)
        for buffer in speciesBuffers {
            buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: grid.cellCount)
                .update(repeating: air, count: grid.cellCount)
        }
        gravityGround = primitive
        if configuration.gravity != nil { fillHydrostatic() }
        restart()
    }

    /// Fills both state buffers, and the oxygen with afterburning, with gravity's hydrostatic
    /// background, on the GPU, as the sweeps work it out (see `AirGravity`).
    private func fillHydrostatic() {
        gravityTables = [:]
        let constants = MTLFunctionConstantValues()
        var model = configuration.airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        guard
            let table = gravityTable(scale: 1),
            let pipeline = try? ShaderLibrary.pipeline("fillHydrostatic", in: library, constants: constants),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        var uniforms = makeUniforms()
        var oxygen: Float = hasSpecies ? Self.oxygenInAir : 0
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&oxygen, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.setBuffer(table, offset: 0, index: 4)
        for n in 0..<2 {
            encoder.setBuffer(stateBuffers[n], offset: 0, index: 0)
            encoder.setBuffer(hasSpecies ? speciesBuffers[n] : noSpecies, offset: 0, index: 1)
            dispatchGrid(encoder, pipeline: pipeline)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// `base`, kernel `name`, or with gravity in the air compiled in while the air has gravity.
    private func gravityVariant(_ base: MTLComputePipelineState, _ name: String) -> MTLComputePipelineState {
        guard configuration.gravity != nil else { return base }
        if let pipeline = gravityPipelines[name] { return pipeline }
        guard
            let pipeline = try? ShaderLibrary.pipeline(
                name, in: library, constants: ShaderLibrary.withGravity(MTLFunctionConstantValues()))
        else { return base }
        gravityPipelines[name] = pipeline
        return pipeline
    }

    /// The eddy viscosity's buffer while the air has sub-grid mixing, made when first needed.
    func mixingViscosity() -> MTLBuffer? {
        guard configuration.mixing != nil else { return nil }
        if let viscosityBuffer { return viscosityBuffer }
        viscosityBuffer = device.makeBuffer(
            length: grid.cellCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        viscosityBuffer?.label = "eddy viscosity"
        if let viscosityBuffer { memset(viscosityBuffer.contents(), 0, viscosityBuffer.length) }
        return viscosityBuffer
    }

    /// Encodes the eddy viscosity of every coarse cell from the state at the start of the step.
    private func encodeEddyViscosity(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms) {
        guard let viscosity = mixingViscosity() else { return }
        if viscosityPipeline == nil {
            viscosityPipeline = try? ShaderLibrary.pipeline("eddyViscosity", in: library)
        }
        guard let pipeline = viscosityPipeline else { return }
        var uniforms = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(viscosity, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.setBuffer(controlBuffer, offset: 0, index: 4)
        dispatchGrid(encoder, pipeline: pipeline)
    }

    /// Refills the periodic halo of the current state (see `SolverConfiguration.periodicSides`),
    /// then restores the sweep's own pipeline and buffers.
    private func encodePeriodicHalo(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms) {
        if periodicPipeline == nil {
            periodicPipeline = try? ShaderLibrary.pipeline("periodicHalo", in: library)
        }
        guard let pipeline = periodicPipeline, let kernels = try? cellKernels() else { return }
        var uniforms = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 1)
        dispatchGrid(encoder, pipeline: pipeline)
        encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
        encoder.setBuffer(maskBuffer, offset: 0, index: 2)
    }

    /// Gives each refined level gravity's background at its resolution and its parent's.
    func assignGravityTables() {
        for level in refinementLevels {
            level.gravityTable = gravityTable(scale: level.parentScale * level.ratio)
            level.parentGravityTable = gravityTable(scale: level.parentScale)
            level.viscosity = mixingViscosity()
            level.burnLimit = configuration.afterburnLimit != nil
        }
    }

    /// Gravity's background for the level with `scale` cells along a coarse cell's edge: a row a
    /// cell of its height, from 4 below the ground to 4 above the top (see `gravityCellOf`).
    func gravityTable(scale: Int) -> MTLBuffer? {
        guard configuration.gravity != nil else { return nil }
        if let table = gravityTables[scale] { return table }
        let constants = MTLFunctionConstantValues()
        var model = configuration.airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        var rows = UInt32(grid.nz * scale + 8)
        var dz = grid.cellSize / Float(scale)
        guard
            let pipeline = try? ShaderLibrary.pipeline("gravityTable", in: library, constants: constants),
            let table = device.makeBuffer(
                length: 2 * Int(rows) * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        table.label = "gravity's background"
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(table, offset: 0, index: 0)
        encoder.setBytes(&rows, length: MemoryLayout<UInt32>.stride, index: 1)
        encoder.setBytes(&dz, length: MemoryLayout<Float>.stride, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: Int(rows), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(Int(rows), 256), height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        gravityTables[scale] = table
        return table
    }

    /// Direct access to the densities of unburnt detonation products (x) and oxygen (y).
    func mutateSpecies(_ body: (UnsafeMutableBufferPointer<SIMD2<Float>>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit state while a batch is in flight")
        guard hasSpecies else { return }
        let pointer = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// The densities of unburnt detonation products (x) and oxygen (y) to read, or nil without
    /// afterburning.
    public func readSpecies<R>(_ body: (UnsafeBufferPointer<SIMD2<Float>>?) throws -> R) rethrows -> R {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        guard hasSpecies else { return try body(nil) }
        let pointer = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        return try body(UnsafeBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Total unburnt detonation products (kg) and oxygen (kg) in the air.
    public func speciesTotals() -> (fuel: Double, oxygen: Double) {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        guard hasSpecies else { return (0, 0) }
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let species = speciesBuffers[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinedGas()
        var total = SIMD2<Double>.zero
        for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
            total += SIMD2(Double(species[index].x), Double(species[index].y)) * openShare(index)
        }
        total = total * volume + (fine?.species ?? .zero)
        return (total.x, total.y)
    }

    /// Sets every cell from a closure and restarts the clock. Intended for small grids.
    public func fill(_ body: (_ i: Int, _ j: Int, _ k: Int) -> Primitive) {
        mutateState { cells in
            for k in 0..<grid.nz {
                for j in 0..<grid.ny {
                    for i in 0..<grid.nx {
                        cells[grid.index(i, j, k)] = cellState(body(i, j, k))
                    }
                }
            }
        }
        restart()
    }

    /// The conserved state of air in `primitive` state, by the configured equation of state.
    public func cellState(_ primitive: Primitive) -> CellState {
        var cell = CellState(primitive, gamma: configuration.gamma)
        let kinetic = 0.5 * primitive.density * simd_length_squared(primitive.velocity)
        cell.energy =
            configuration.airModel.internalEnergy(
                density: primitive.density, pressure: primitive.pressure, gamma: configuration.gamma)
            + kinetic
        return cell
    }

    /// The primitive state of a cell, by the configured equation of state.
    public func primitive(of cell: CellState) -> Primitive {
        Self.primitive(of: cell, gamma: configuration.gamma, airModel: configuration.airModel)
    }

    static func primitive(of cell: CellState, gamma: Float, airModel: AirModel) -> Primitive {
        var primitive = cell.primitive(gamma: gamma)
        let kinetic = 0.5 * primitive.density * simd_length_squared(primitive.velocity)
        primitive.pressure = airModel.pressure(
            density: primitive.density, internalEnergy: cell.energy - kinetic, gamma: gamma)
        return primitive
    }

    /// Direct access to the current conserved state. Call `restart()` after editing.
    public func mutateState(_ body: (UnsafeMutableBufferPointer<CellState>) throws -> Void) rethrows {
        fineDeposit = [:]
        try editState(body)
    }

    /// The same, keeping any charge laid down in fine cells.
    func editState(_ body: (UnsafeMutableBufferPointer<CellState>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit state while a batch is in flight")
        frameExtractor?.invalidate()
        let pointer = stateBuffers[current].contents().bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Keeps `cells`, just made solid in the mask with structures already in place (the vent
    /// panels, placed after them), in the rigid mask their remasking starts from too, rather than
    /// leaving them to be lost at the first remask or recapturing a mask that holds their outlines.
    func keepInRigidMask(_ cells: [Int]) {
        guard !bodies.isEmpty else { return }
        let rigid = rigidMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        for index in cells { rigid[index] = 1 }
        needsRigidMaskCapture = false
    }

    /// Direct access to the solid mask (non-zero marks a rigid cell). Call `restart()` after editing.
    public func mutateMask(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit the mask while a batch is in flight")
        frameExtractor?.invalidate()
        rigidBoxes = nil
        terrain = nil
        terrainSurface = nil
        terrainCut = nil
        needsRigidMaskCapture = true
        let pointer = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// The same, keeping the terrain's state (its cut cells, surface and heights): for cells that do
    /// not change the ground, such as a vent panel's.
    func editMaskKeepingTerrain(_ body: (UnsafeMutableBufferPointer<UInt8>) throws -> Void) rethrows {
        precondition(!batchInFlight, "Cannot edit the mask while a batch is in flight")
        frameExtractor?.invalidate()
        rigidBoxes = nil
        needsRigidMaskCapture = true
        let pointer = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        try body(UnsafeMutableBufferPointer(start: pointer, count: grid.cellCount))
    }

    /// Chooses the cells whose pressure is recorded every step. Clears existing histories. With
    /// `points`, one per cell, a gauge whose cell is refined reads the fine cell holding its point.
    public func setGauges(cells: [(i: Int, j: Int, k: Int)], points: [SIMD3<Float>]? = nil) {
        precondition(cells.count <= Self.maxGauges, "At most \(Self.maxGauges) gauges are supported")
        let pointer = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for (n, cell) in cells.enumerated() {
            precondition(grid.contains(cell.i, cell.j, cell.k), "Gauge outside the grid")
            pointer[n] = UInt32(grid.index(cell.i, cell.j, cell.k))
        }
        gaugeCount = cells.count
        gaugeHistories = Array(repeating: [], count: gaugeCount)
        gaugePoints = (0..<cells.count).map { points?[$0] }
        let placed = gaugePointBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxGauges)
        for n in 0..<Self.maxGauges {
            placed[n] = n < gaugePoints.count ? gaugePoints[n].map { SIMD4($0, 1) } ?? .zero : .zero
        }
        updateGaugeChildren()
    }

    /// Moves the gauges set by `setGauges` to new cells and points, keeping what they have recorded:
    /// for gauges that follow a moving face.
    public func moveGauges(cells: [(i: Int, j: Int, k: Int)], points: [SIMD3<Float>]) {
        precondition(cells.count == gaugeCount && points.count == gaugeCount, "Move every gauge")
        let pointer = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        let placed = gaugePointBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxGauges)
        for (n, cell) in cells.enumerated() {
            precondition(grid.contains(cell.i, cell.j, cell.k), "Gauge outside the grid")
            pointer[n] = UInt32(grid.index(cell.i, cell.j, cell.k))
            placed[n] = SIMD4(points[n], 1)
        }
        gaugePoints = points
        updateGaugeChildren()
    }

    /// Binds the refined levels for a surface reader (`RefinedAir` in Solver.metal) at `first`
    /// and the five indices after it: the first level's patches, fine state and outline, then the
    /// second level's; placeholders where there is no such level.
    private func bindRefinedAir(_ encoder: MTLComputeCommandEncoder, from first: Int) {
        encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: first)
        encoder.setBuffer(refinement?.fine[0] ?? refinementPlaceholder, offset: 0, index: first + 1)
        encoder.setBuffer(refinement?.fineMask ?? refinementPlaceholder, offset: 0, index: first + 2)
        if let deep = finerRefinement, let parent = deep.parent {
            encoder.setBuffer(parent.patchOfTile, offset: deep.patchOffset * 4, index: first + 3)
            encoder.setBuffer(
                parent.fine[0], offset: deep.cellOffset * MemoryLayout<CellState>.stride, index: first + 4)
            encoder.setBuffer(parent.fineMask, offset: deep.cellOffset, index: first + 5)
        } else {
            for index in first + 3...first + 5 {
                encoder.setBuffer(refinementPlaceholder, offset: 0, index: index)
            }
        }
    }

    /// Binds the second level's patches, cells and outline for the gauges (any buffer without).
    private func encodeFinerGaugeBuffers(_ encoder: MTLComputeCommandEncoder) {
        if let deep = finerRefinement, let parent = deep.parent {
            encoder.setBuffer(parent.patchOfTile, offset: deep.patchOffset * 4, index: 12)
            encoder.setBuffer(
                parent.fine[0], offset: deep.cellOffset * MemoryLayout<CellState>.stride, index: 13)
            encoder.setBuffer(parent.fineMask, offset: deep.cellOffset, index: 14)
        } else {
            for index in 12...14 { encoder.setBuffer(refinementPlaceholder, offset: 0, index: index) }
        }
    }

    /// Which finest cell of its cell each gauge reads, for the current refinement.
    private func updateGaugeChildren() {
        let pointer = gaugeChildBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        let cells = gaugeCellBuffer.contents().bindMemory(to: UInt32.self, capacity: Self.maxGauges)
        for n in 0..<Self.maxGauges {
            pointer[n] = .max
            guard refinement != nil, n < gaugePoints.count, let point = gaugePoints[n] else { continue }
            let index = Int(cells[n])
            let cell = SIMD3(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
            let r = refinementLevels.reduce(1) { $0 * $1.ratio }
            let within = simd_clamp(
                point / grid.cellSize - SIMD3<Float>(cell), .zero, SIMD3(repeating: 0.999))
            var child = SIMD3<Int>((within * Float(r)).rounded(.down))
            if let terrain, let cut = refinement?.coarseCut {
                // On cut cells, a fine cell at least half air, as on the coarse grid (`surfaceCells`).
                let fine = { cell &* r &+ child }
                while child.z < r - 1,
                    TerrainCutGeometry.share(
                        of: fine(), cellSize: grid.cellSize / Float(r), terrain: terrain,
                        samples: max(cut.geometry.samples / r, 1))
                        < TerrainCutGeometry.receivingShare
                {
                    child.z += 1
                }
            }
            pointer[n] = UInt32(child.x + r * (child.y + r * child.z))
        }
    }

    /// Replaces the deformable body, preserving scenery authored through `mutateMask`.
    /// The new outline is added at the next `restart()`; old body masks are removed.
    public func setStructure(_ model: StructureModel?) throws {
        try setStructures(model.map { [SceneObject.legacyStructure($0)] } ?? [])
    }

    public func setStructures(_ objects: [SceneObject]) throws {
        precondition(!batchInFlight, "Cannot change structures while a batch is in flight")
        guard objects.count <= Scenario.maximumStructures, Set(objects.map(\.id)).count == objects.count,
            objects.allSatisfy({ $0.structure != nil })
        else { throw SceneObjectError.invalidOwnership }
        try SceneObject.validateSeparation(objects)
        let ordered = objects.count > 1 ? objects.sorted { $0.id.uuidString < $1.id.uuidString } : objects
        let compiled = try ordered.map {
            try StructuralBody(object: $0, device: device, queue: commandQueue, library: library)
        }
        clearEnvelopeExposure()
        bodies = compiled
        couplingRegion = nil
        tiledCoupling = nil
        couplingTiles = nil
        denseCouplingCells = 0
        occupancyBuffer = nil
        combinedOccupancyBuffer = nil
        interactionBuffer = nil
        bodyEnvelopeBuffer = nil
        debrisExchangeBuffer = nil
        debrisAreaBuffer = nil
        wallVelocityBuffer = stillWallBuffer
        if needsRigidMaskCapture {
            memcpy(rigidMaskBuffer.contents(), maskBuffer.contents(), grid.cellCount)
            needsRigidMaskCapture = false
        }
        // Replacing/removing bodies must clear their old outline outside the new coupling region.
        memcpy(maskBuffer.contents(), rigidMaskBuffer.contents(), grid.cellCount)
        guard let first = compiled.first else { return }
        let model = first.model
        // Follow the structure within a few metres of where it starts.
        let bounds = compiled.dropFirst().reduce(model.bounds) { bounds, body in
            Box(
                min: simd_min(bounds.min, body.model.bounds.min),
                max: simd_max(bounds.max, body.model.bounds.max))
        }
        let margin = configuration.debrisReach
        let low = grid.cell(containing: bounds.min - margin)
        let high = grid.cell(containing: bounds.max + margin)
        var origin = SIMD3(low.i, low.j, low.k)
        var dims = SIMD3(high.i - low.i + 1, high.j - low.j + 1, high.k - low.k + 1)
        // Four counters per cell: the number of elements in it and the sum of their velocities.
        denseCouplingCells = dims.x * dims.y * dims.z
        if bodies.count > 1, configuration.bodyCouplingLayout != .dense {
            let plan = try TiledCoupling(
                grid: grid, bodies: bodies, requestedCapacity: configuration.bodyCouplingTileCapacity)
            if configuration.bodyCouplingLayout == .tiled || plan.bytes < denseCouplingCells * 80 {
                tiledCoupling = plan
                origin = .zero
                dims = SIMD3(grid.nx, grid.ny, grid.nz)
            }
        }
        let regionCells = tiledCoupling?.capacityCells ?? denseCouplingCells
        let wallWords = 3 * regionCells + (tiledCoupling?.wallHeaderWords ?? 0)
        guard
            let occupancy = device.makeBuffer(
                length: 4 * regionCells * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let wallVelocity = device.makeBuffer(
                length: wallWords * MemoryLayout<Float>.stride, options: .storageModeShared),
            // Momentum and energy per cell, each a 64-bit sum in two words.
            let exchange = device.makeBuffer(
                length: 8 * regionCells * MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let debrisArea = device.makeBuffer(
                length: regionCells * MemoryLayout<Int32>.stride, options: .storageModeShared)
        else {
            throw BlastError.allocationFailed("coupling occupancy")
        }
        memset(occupancy.contents(), 0, occupancy.length)
        memset(wallVelocity.contents(), 0, wallVelocity.length)
        memset(exchange.contents(), 0, exchange.length)
        couplingRegion = (origin, dims)
        occupancyBuffer = occupancy
        if bodies.count > 1 {
            guard let combined = device.makeBuffer(length: occupancy.length, options: .storageModeShared),
                let interaction = device.makeBuffer(length: 4, options: .storageModeShared),
                let envelopes = device.makeBuffer(length: bodies.count * 6 * 4, options: .storageModeShared)
            else { throw BlastError.allocationFailed("multi-body coupling") }
            memset(combined.contents(), 0, combined.length)
            memset(interaction.contents(), 0, interaction.length)
            combinedOccupancyBuffer = combined
            interactionBuffer = interaction
            bodyEnvelopeBuffer = envelopes
        }
        wallVelocityBuffer = wallVelocity
        if let plan = tiledCoupling {
            guard let tiles = device.makeBuffer(length: plan.capacity * 4, options: .storageModeShared)
            else { throw BlastError.allocationFailed("coupling page table") }
            memset(tiles.contents(), 0xFF, tiles.length)
            couplingTiles = tiles
            memset(wallVelocity.contents().advanced(by: 8), 0xFF, plan.mapCount * 4)
        }
        debrisExchangeBuffer = exchange
        debrisAreaBuffer = debrisArea
        resetDebrisExchange()
    }

    private func resetDebrisExchange() {
        if let debrisExchangeBuffer {
            memset(debrisExchangeBuffer.contents(), 0, debrisExchangeBuffer.length)
        }
        if let debrisAreaBuffer { memset(debrisAreaBuffer.contents(), 0, debrisAreaBuffer.length) }
    }

    private func couplingUniforms(
        _ region: (origin: SIMD3<Int>, dims: SIMD3<Int>), body: StructuralBody? = nil
    ) -> CouplingUniforms {
        var uniforms = CouplingUniforms(
            regionX: UInt32(region.origin.x), regionY: UInt32(region.origin.y),
            regionZ: UInt32(region.origin.z),
            regionNx: UInt32(region.dims.x), regionNy: UInt32(region.dims.y), regionNz: UInt32(region.dims.z),
            fluidNx: UInt32(grid.nx), fluidNy: UInt32(grid.ny), fluidNz: UInt32(grid.nz),
            // A cell any shell passes through is solid.
            threshold: 1, ex: 0, ey: 0, fluidCell: grid.cellSize, h: 0, originX: 0, originY: 0, originZ: 0,
            gamma: configuration.gamma, ambientDensity: ambientDensity,
            ambientPressure: configuration.ambientPressure, airModel: configuration.airModel.rawValue)
        uniforms.couplingMapCount = UInt32(tiledCoupling?.mapCount ?? 0)
        uniforms.couplingTileCapacity = UInt32(tiledCoupling?.capacity ?? 0)
        if let refinement {
            uniforms.refineRatio = UInt32(refinement.ratio)
            uniforms.blocksX = UInt32(refinement.tileDims.x)
            uniforms.blocksY = UInt32(refinement.tileDims.y)
        }
        if let deep = finerRefinement {
            uniforms.deepRatio = UInt32(deep.parentScale * deep.ratio)
            uniforms.deepBlocksX = UInt32(deep.tileDims.x)
            uniforms.deepBlocksY = UInt32(deep.tileDims.y)
            uniforms.deepPatchOffset = UInt32(deep.patchOffset)
            uniforms.deepCellOffset = UInt32(deep.cellOffset)
        }
        if let structure = body?.solids ?? (bodies.count == 1 ? structure : nil) {
            let h = structure.model.elementSize
            // A cell is solid when at least a third of it is filled with intact elements. Elements
            // larger than the cells are sampled at points no further apart than a cell.
            let sampling = Float(configuration.structureMaskSampling ?? 1)
            let fill = configuration.structureMaskFill
            let coarse = max(1, Int((sampling * h / grid.cellSize - 1e-3).rounded(.up)))
            uniforms.coarseSamples = UInt32(coarse)
            let perCell = pow(grid.cellSize * Float(coarse) / h, 3)
            // As boxes, a sample counts `units` when wholly inside a cell.
            let units: UInt32 = configuration.structureMaskOverlap ? 16 : 0
            uniforms.overlapUnits = units
            uniforms.maskHysteresis = configuration.structureMaskOverlap ? 1 : 0
            uniforms.keepsAir = keptAirBuffer == nil ? 0 : 1
            let scale = Float(max(units, 1))
            uniforms.threshold = UInt32(
                max(1, (fill.map { perCell * scale * $0 } ?? perCell * scale / 3).rounded(.up)))
            if let refinement {
                // For the fine cells, each element is sampled at points no further apart than a
                // cell of the finest level, and a fine cell of each level is solid when a third
                // of it is covered.
                let finest = grid.cellSize / Float(refinementLevels.reduce(1) { $0 * $1.ratio })
                let samples = max(1, Int((sampling * h / finest - 1e-3).rounded(.up)))
                func threshold(_ cell: Float) -> UInt32 {
                    let perCell = pow(cell * Float(samples) / h, 3)
                    return UInt32(
                        max(1, (fill.map { perCell * scale * $0 } ?? perCell * scale / 3).rounded(.up)))
                }
                uniforms.fineSamples = UInt32(samples)
                uniforms.fineThreshold = threshold(grid.cellSize / Float(refinement.ratio))
                if finerRefinement != nil { uniforms.deepThreshold = threshold(finest) }
            }
            uniforms.ex = UInt32(structure.ex)
            uniforms.ey = UInt32(structure.ey)
            uniforms.h = h
            (uniforms.originX, uniforms.originY, uniforms.originZ) =
                (structure.origin.x, structure.origin.y, structure.origin.z)
        }
        return uniforms
    }

    private func regionThreads(_ pipeline: MTLComputePipelineState) -> MTLSize {
        let width = pipeline.threadExecutionWidth
        return MTLSize(width: width, height: max(1, pipeline.maxTotalThreadsPerThreadgroup / width), depth: 1)
    }

    private func encodeBodyEnvelopes(_ encoder: MTLComputeCommandEncoder, clear: Bool) {
        guard let bounds = bodyEnvelopeBuffer else { return }
        var count = UInt32(bodies.count)
        if clear {
            encoder.setComputePipelineState(clearEnvelopesPipeline)
            encoder.setBuffer(bounds, offset: 0, index: 0)
            encoder.setBytes(&count, length: 4, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: bodies.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        for index in bodies.indices { encodeBodyEnvelope(encoder, index: index) }
    }

    private func encodeBodyEnvelope(_ encoder: MTLComputeCommandEncoder, index: Int, substep: Int? = nil) {
        guard let bounds = bodyEnvelopeBuffer else { return }
        let body = bodies[index]
        var timing = SIMD2<Float>(substep == nil ? 0 : body.criticalTimeStep, Float(substep ?? 0))
        if let solids = body.solids, solids.nodeCount > 0 {
            var layout = SIMD4<UInt32>(
                UInt32(index), UInt32(solids.ex + 1), UInt32(solids.ey + 1), UInt32(solids.nodeCount))
            var origin = SIMD4<Float>(solids.origin, solids.model.elementSize)
            encoder.setComputePipelineState(solidEnvelopePipeline)
            encoder.setBuffer(solids.nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(solids.nodeListBuffer, offset: 0, index: 1)
            encoder.setBuffer(bounds, offset: 0, index: 2)
            encoder.setBytes(&layout, length: 16, index: 3)
            encoder.setBytes(&origin, length: 16, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBytes(&timing, length: 8, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: solids.nodeCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: solidEnvelopePipeline.threadExecutionWidth, height: 1, depth: 1))
        }
        if let shells = body.shells, shells.nodeCount > 0 {
            var layout = SIMD4<UInt32>(UInt32(index), 0, 0, UInt32(shells.nodeCount))
            var parameters = SIMD4<Float>(0, 0, 0, body.shellEnvelopeMargin)
            encoder.setComputePipelineState(shellEnvelopePipeline)
            encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 1)
            encoder.setBuffer(bounds, offset: 0, index: 2)
            encoder.setBytes(&layout, length: 16, index: 3)
            encoder.setBytes(&parameters, length: 16, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBytes(&timing, length: 8, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: shells.nodeCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: shellEnvelopePipeline.threadExecutionWidth, height: 1, depth: 1))
        }
    }

    private func encodeWakeCoupling(_ encoder: MTLComputeCommandEncoder) {
        guard tiledCoupling != nil, tilesEnabled else { return }
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(wakeCouplingPipeline)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 0)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: tileDims.x * tileDims.y * tileDims.z, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: wakeCouplingPipeline.threadExecutionWidth, height: 1, depth: 1))
    }
    private func encodeAllocateCoupling(_ encoder: MTLComputeCommandEncoder) {
        guard let plan = tiledCoupling, let couplingTiles, let bodyEnvelopeBuffer, let region = couplingRegion
        else { return }
        var uniforms = couplingUniforms(region)
        var count = UInt32(bodies.count)
        encoder.setComputePipelineState(allocateCouplingPipeline)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 0)
        encoder.setBuffer(couplingTiles, offset: 0, index: 1)
        encoder.setBuffer(bodyEnvelopeBuffer, offset: 0, index: 2)
        encoder.setBytes(&count, length: 4, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<CouplingUniforms>.stride, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: plan.mapCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: allocateCouplingPipeline.threadExecutionWidth, height: 1, depth: 1))
        encodeWakeCoupling(encoder)
    }
    private func couplingSize(_ region: (origin: SIMD3<Int>, dims: SIMD3<Int>)) -> MTLSize {
        tiledCoupling.map { MTLSize(width: $0.capacityCells, height: 1, depth: 1) }
            ?? MTLSize(width: region.dims.x, height: region.dims.y, depth: region.dims.z)
    }
    private func couplingThreads(_ pipeline: MTLComputePipelineState) -> MTLSize {
        tiledCoupling == nil
            ? regionThreads(pipeline)
            : MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1)
    }

    private func encodeInteractionCheck(_ encoder: MTLComputeCommandEncoder) {
        guard let interactionBuffer, let bounds = bodyEnvelopeBuffer else { return }
        var count = UInt32(bodies.count)
        // With contact, bodies within one of their widest spheres of each other start it, before
        // any spheres can touch.
        var margin: Float =
            configuration.interBodyContact
            ? bodies.map { max($0.model.elementSize, 2 * $0.shellEnvelopeMargin) }.max() ?? 0 : 0
        encoder.setComputePipelineState(validateEnvelopesPipeline)
        encoder.setBuffer(bounds, offset: 0, index: 0)
        encoder.setBytes(&count, length: 4, index: 1)
        encoder.setBuffer(interactionBuffer, offset: 0, index: 2)
        encoder.setBytes(&margin, length: 4, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: bodies.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        if tiledCoupling != nil {
            encoder.setComputePipelineState(haltCouplingPipeline)
            encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 0)
            encoder.setBuffer(interactionBuffer, offset: 0, index: 1)
            encoder.setBuffer(controlBuffer, offset: 0, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        // Once in contact, bodies coming close is no reason to stop.
        var halting: UInt32 = bodiesInContact ? ~1 : ~0
        encoder.setComputePipelineState(haltInteractionPipeline)
        encoder.setBuffer(interactionBuffer, offset: 0, index: 0)
        encoder.setBuffer(controlBuffer, offset: 0, index: 1)
        encoder.setBytes(&halting, length: 4, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    /// Encodes `count` substeps of every body a substep at a time, side by side, with contact
    /// between them: each body fills its own contact table and finds its own contacts, then each
    /// pair of bodies meets (`encodeBodyContact`), and only then does any body move.
    private func encodeBodiesInContact(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: StructureSolver.FluidBinding
    ) {
        for substep in 0..<count {
            func nest(_ index: Int, _ parts: [(body: Int, part: StructuralBody.ContactPart)]) {
                guard index < bodies.count else {
                    encodeBodyContact(encoder, parts, control: fluid.control)
                    return
                }
                bodies[index].encodeSubsteps(
                    encoder, substeps: substep..<(substep + 1), prelude: substep == 0, fluid: fluid,
                    beforeNodes: { found in nest(index + 1, parts + found.map { (index, $0) }) },
                    afterSubstep: { [self] step in encodeBodyEnvelope(encoder, index: index, substep: step) })
            }
            nest(0, [])
        }
    }

    private func bodyContactPipeline(_ name: String) -> MTLComputePipelineState? {
        if let pipeline = bodyContactPipelines[name] { return pipeline }
        let pipeline = try? ShaderLibrary.pipeline(name, in: library)
        bodyContactPipelines[name] = pipeline
        return pipeline
    }

    /// Each part of each body against each part of every other, both ways round, with the same
    /// spring, damper and friction from both sides: the softer spring, less damping and less
    /// friction of the two.
    private func encodeBodyContact(
        _ encoder: MTLComputeCommandEncoder, _ parts: [(body: Int, part: StructuralBody.ContactPart)],
        control: MTLBuffer
    ) {
        guard let bounds = bodyEnvelopeBuffer, !bodyContactPairsSkipped else { return }
        struct Side {
            var width: Float
            var stiffness: Float
            var damping: Float
            var friction: Float
            var nodes: Int
        }
        func side(_ part: StructuralBody.ContactPart) -> Side {
            switch part {
            case .solid(let solver, let u):
                Side(
                    width: u.h, stiffness: u.contactStiffness, damping: u.contactDamping,
                    friction: u.contactFriction, nodes: solver.nodeCount)
            case .shell(let solver, let u):
                Side(
                    width: u.contactRadius, stiffness: u.contactStiffness, damping: u.contactDamping,
                    friction: u.contactFriction, nodes: solver.nodeCount)
            }
        }
        for a in parts.indices {
            for b in parts.indices where parts[a].body != parts[b].body {
                let own = side(parts[a].part)
                let other = side(parts[b].part)
                guard own.nodes > 0, other.nodes > 0 else { continue }
                var contact = StructuralBody.ContactParameters(
                    reach: 0.5 * (own.width + other.width), stiffness: min(own.stiffness, other.stiffness),
                    damping: min(own.damping, other.damping), friction: min(own.friction, other.friction),
                    own: UInt32(parts[a].body), other: UInt32(parts[b].body))
                let name: String
                switch (parts[a].part, parts[b].part) {
                case (.solid, .solid): name = "bodyContactSolidFromSolid"
                case (.solid, .shell): name = "bodyContactSolidFromShell"
                case (.shell, .solid): name = "bodyContactShellFromSolid"
                case (.shell, .shell): name = "bodyContactShellFromShell"
                }
                guard let pipeline = bodyContactPipeline(name) else { continue }
                encoder.setComputePipelineState(pipeline)
                switch parts[a].part {
                case .solid(let solver, var u):
                    encoder.setBuffer(solver.nodeListBuffer, offset: 0, index: 0)
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 1)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 2)
                    encoder.setBytes(&u, length: MemoryLayout<StructureUniforms>.stride, index: 3)
                    encoder.setBuffer(solver.contactForceBuffer, offset: 0, index: 5)
                case .shell(let solver, var u):
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 0)
                    encoder.setBuffer(solver.referenceBuffer, offset: 0, index: 1)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 2)
                    encoder.setBytes(&u, length: MemoryLayout<ShellUniforms>.stride, index: 3)
                    encoder.setBuffer(solver.contactForceBuffer, offset: 0, index: 5)
                }
                encoder.setBuffer(control, offset: 0, index: 4)
                switch parts[b].part {
                case .solid(let solver, var u):
                    encoder.setBuffer(solver.nodeListBuffer, offset: 0, index: 6)
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 7)
                    encoder.setBuffer(solver.contactHeadBuffer, offset: 0, index: 8)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 9)
                    encoder.setBytes(&u, length: MemoryLayout<StructureUniforms>.stride, index: 10)
                case .shell(let solver, var u):
                    encoder.setBuffer(solver.nodeBuffer, offset: 0, index: 6)
                    encoder.setBuffer(solver.referenceBuffer, offset: 0, index: 7)
                    encoder.setBuffer(solver.contactHeadBuffer, offset: 0, index: 8)
                    encoder.setBuffer(solver.contactSlotBuffer, offset: 0, index: 9)
                    encoder.setBytes(&u, length: MemoryLayout<ShellUniforms>.stride, index: 10)
                }
                encoder.setBytes(
                    &contact, length: MemoryLayout<StructuralBody.ContactParameters>.stride, index: 11)
                encoder.setBuffer(bounds, offset: 0, index: 12)
                encoder.dispatchThreads(
                    MTLSize(width: own.nodes, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            }
        }
    }

    /// Encodes the return to the air of what loose debris took from it during the substeps.
    private func encodeDebrisExchange(_ encoder: MTLComputeCommandEncoder) {
        guard hasBody, let region = couplingRegion, let debrisExchangeBuffer else { return }
        var uniforms = couplingUniforms(region)
        encoder.setComputePipelineState(debrisExchangePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(debrisExchangeBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<CouplingUniforms>.stride, index: 2)
        encoder.setBuffer(debrisAreaBuffer, offset: 0, index: 3)
        encoder.setBuffer(couplingTiles ?? refinementPlaceholder, offset: 0, index: 4)
        encoder.dispatchThreads(
            couplingSize(region), threadsPerThreadgroup: couplingThreads(debrisExchangePipeline))
    }

    /// Encodes one update of the solid mask from the structure's current shape, and of the fine
    /// cells' outline too where the air is refined, unless `fine` is false.
    /// With `allocate` false (the air asleep), only the coupling pages already allocated follow the
    /// structure: frozen-air mechanics take no new pages.
    private func encodeRemask(_ encoder: MTLComputeCommandEncoder, fine: Bool = true, allocate: Bool = true) {
        guard hasBody, let region = couplingRegion, let occupancyBuffer else { return }
        // A refined level's call may move detailed profiling on to another encoder.
        var encoder = encoder
        if allocate { encodeAllocateCoupling(encoder) }
        var uniforms = couplingUniforms(region)
        uniforms.quietCoverage = allocate ? 0 : 1
        if !fine { (uniforms.refineRatio, uniforms.deepRatio) = (0, 0) }
        let length = MemoryLayout<CouplingUniforms>.stride
        let patches = refinement?.patchOfTile ?? refinementPlaceholder
        let fineOccupancy = refinement?.fineOccupancy ?? refinementPlaceholder

        for body in bodies {
            uniforms = couplingUniforms(region, body: body)
            uniforms.quietCoverage = allocate ? 0 : 1
            if !fine { (uniforms.refineRatio, uniforms.deepRatio) = (0, 0) }
            if let structure = body.solids {
                encoder.setComputePipelineState(splatPipeline)
                encoder.setBuffer(structure.instanceBuffer, offset: 0, index: 0)
                encoder.setBuffer(structure.flagBuffer, offset: 0, index: 1)
                encoder.setBuffer(structure.nodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 3)
                encoder.setBytes(&uniforms, length: length, index: 4)
                encoder.setBuffer(structure.nodeMapBuffer, offset: 0, index: 5)
                encoder.setBuffer(patches, offset: 0, index: 6)
                encoder.setBuffer(fineOccupancy, offset: 0, index: 7)
                encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
                encoder.dispatchThreads(
                    MTLSize(width: structure.elementCount, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: splatPipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
            }
            if let shells = body.shells {
                // In a mixed body, one shell point fills a cell, as a third of it in solid elements does.
                uniforms.splatWeight = body.solids != nil ? uniforms.threshold : 1
                if shells.beamCount > 0 {
                    var beams = UInt32(shells.beamCount)
                    encoder.setComputePipelineState(beamSplatPipeline)
                    encoder.setBuffer(shells.beamBuffer, offset: 0, index: 0)
                    encoder.setBuffer(shells.beamFlagBuffer, offset: 0, index: 1)
                    encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 2)
                    encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 3)
                    encoder.setBuffer(occupancyBuffer, offset: 0, index: 4)
                    encoder.setBytes(&uniforms, length: length, index: 5)
                    encoder.setBytes(&beams, length: 4, index: 6)
                    encoder.setBuffer(patches, offset: 0, index: 7)
                    encoder.setBuffer(fineOccupancy, offset: 0, index: 8)
                    encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 9)
                    encoder.dispatchThreads(
                        MTLSize(width: shells.beamCount, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(
                            width: beamSplatPipeline.threadExecutionWidth, height: 1, depth: 1))
                }
                var count = UInt32(shells.elementCount)
                let splat =
                    body.model.hasInclinedSolids
                    ? inclinedShellSplatPipeline ?? shellSplatPipeline : shellSplatPipeline
                encoder.setComputePipelineState(splat)
                encoder.setBuffer(shells.elementBuffer, offset: 0, index: 0)
                encoder.setBuffer(shells.flagBuffer, offset: 0, index: 1)
                encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(shells.referenceBuffer, offset: 0, index: 3)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 4)
                encoder.setBytes(&uniforms, length: length, index: 5)
                encoder.setBytes(&count, length: 4, index: 6)
                encoder.setBuffer(patches, offset: 0, index: 7)
                encoder.setBuffer(fineOccupancy, offset: 0, index: 8)
                encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 9)
                if shells.elementCount > 0 {
                    encoder.dispatchThreads(
                        MTLSize(width: shells.elementCount, height: 1, depth: 1),
                        threadsPerThreadgroup: MTLSize(
                            width: splat.threadExecutionWidth, height: 1, depth: 1))
                }
            }

            if let combined = combinedOccupancyBuffer, let interactionBuffer {
                var threshold = uniforms.threshold
                var cells = UInt32(tiledCoupling?.capacityCells ?? denseCouplingCells)
                encoder.setComputePipelineState(bodyComposePipeline)
                encoder.setBuffer(occupancyBuffer, offset: 0, index: 0)
                encoder.setBuffer(combined, offset: 0, index: 1)
                encoder.setBytes(&threshold, length: 4, index: 2)
                encoder.setBytes(&cells, length: 4, index: 3)
                encoder.setBuffer(interactionBuffer, offset: 0, index: 4)
                encoder.dispatchThreads(
                    MTLSize(width: Int(cells), height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: bodyComposePipeline.threadExecutionWidth, height: 1, depth: 1))
                if fine {
                    refinement?.encodeComposeBody(
                        encoder, threshold: uniforms.fineThreshold,
                        interaction: interactionBuffer, uniforms: makeUniforms())
                    if let deep = finerUniforms(makeUniforms()) {
                        finerRefinement?.encodeComposeBody(
                            encoder, threshold: uniforms.deepThreshold, interaction: interactionBuffer,
                            uniforms: deep)
                    }
                    encoder = liveEncoder?() ?? encoder
                }
            }
        }
        uniforms = couplingUniforms(region)
        uniforms.quietCoverage = allocate ? 0 : 1
        if !fine { (uniforms.refineRatio, uniforms.deepRatio) = (0, 0) }
        let composed = combinedOccupancyBuffer ?? occupancyBuffer
        if fine, bodies.count > 1 {
            refinement?.encodePublishBodies(encoder, uniforms: makeUniforms())
            if let deep = finerUniforms(makeUniforms()) {
                finerRefinement?.encodePublishBodies(encoder, uniforms: deep)
            }
            encoder = liveEncoder?() ?? encoder
        }

        let size = couplingSize(region)
        let width = remaskPreparePipeline.threadExecutionWidth
        let group =
            tiledCoupling == nil
            ? MTLSize(
                width: width, height: max(1, remaskPreparePipeline.maxTotalThreadsPerThreadgroup / width),
                depth: 1) : couplingThreads(remaskPreparePipeline)
        encoder.setComputePipelineState(remaskPreparePipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 1)
        encoder.setBuffer(composed, offset: 0, index: 2)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: length, index: 4)
        encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 5)
        encoder.setBuffer(couplingTiles ?? refinementPlaceholder, offset: 0, index: 6)
        encoder.setBuffer(keptAirBuffer ?? refinementPlaceholder, offset: 0, index: 7)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        // A structure standing on the terrain's cut cells shuts in the slivers under it.
        if let terrainCut, !terrainCut.geometry.cutColumns.isEmpty,
            bodies.contains(where: { $0.model.ground != nil })
        {
            var dims = SIMD4<UInt32>(
                UInt32(grid.nx), UInt32(grid.ny), UInt32(grid.nz),
                UInt32(terrainCut.geometry.cutColumns.count))
            encoder.setComputePipelineState(remaskCapSliversPipeline)
            encoder.setBuffer(maskBuffer, offset: 0, index: 0)
            encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 1)
            encoder.setBuffer(terrainCut.columns, offset: 0, index: 2)
            encoder.setBuffer(terrainCut.cutColumns, offset: 0, index: 3)
            encoder.setBuffer(terrainCut.defects, offset: 0, index: 4)
            encoder.setBytes(&dims, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 5)
            if cappedSliverBuffer == nil {
                cappedSliverBuffer = device.makeBuffer(
                    length: 4 * terrainCut.geometry.cutColumns.count, options: .storageModeShared)
                if let cappedSliverBuffer {
                    memset(cappedSliverBuffer.contents(), 0, cappedSliverBuffer.length)
                }
            }
            encoder.setBuffer(cappedSliverBuffer, offset: 0, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: terrainCut.geometry.cutColumns.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: remaskCapSliversPipeline.threadExecutionWidth, height: 1, depth: 1))
        }

        encoder.setComputePipelineState(remaskApplyPipeline)
        encoder.setBuffer(maskBuffer, offset: 0, index: 0)
        encoder.setBuffer(composed, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: length, index: 2)
        encoder.setBuffer(couplingTiles ?? refinementPlaceholder, offset: 0, index: 3)
        encoder.dispatchThreads(size, threadsPerThreadgroup: group)

        if fine, let refinement {
            // Bit 31 asks the fine outline for the coarse one's hysteresis.
            let hysteresis: UInt32 = uniforms.maskHysteresis != 0 ? 1 << 31 : 0
            refinement.encodeRemask(
                encoder, parent: coarseView(species: currentSpecies),
                threshold: uniforms.fineThreshold | hysteresis, uniforms: makeUniforms())
            if let finerRefinement, let deep = finerUniforms(makeUniforms()) {
                finerRefinement.encodeRemask(
                    encoder, parent: refinement.view(), threshold: uniforms.deepThreshold | hysteresis,
                    uniforms: deep)
            }
        }
    }

    /// Sets the clock without touching the state, after `restart()`: for a blast laid down as it
    /// is some time after detonation.
    func startClock(at start: Double) {
        time = start
    }

    /// Direct access to the peak overpressure and impulse fields.
    func setFields(_ body: (UnsafeMutableBufferPointer<Float>, UnsafeMutableBufferPointer<Float>) -> Void) {
        let peak = peakBuffer.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        let impulse = impulseBuffer.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        body(
            UnsafeMutableBufferPointer(start: peak, count: grid.cellCount),
            UnsafeMutableBufferPointer(start: impulse, count: grid.cellCount))
    }

    /// Puts `samples` in front of gauge `index`'s history.
    func prependGaugeHistory(_ index: Int, _ samples: [GaugeSample]) {
        guard gaugeHistories.indices.contains(index) else { return }
        gaugeHistories[index] = samples + gaugeHistories[index]
    }

    /// How one body was brought to rest under its own weight before the blast.
    public struct Settlement: Sendable {
        public var name: String
        /// Whether its motion died away; if not, it starts undeformed, as without settling.
        public var settled: Bool
        /// Time it was given, s, and the steps that took.
        public var time: Double
        public var steps: Int
        /// The wall-clock time it took, s.
        public var seconds: Double
        /// Its mean (mass-weighted root-mean-square) speed at the end, as a share of the largest
        /// on the way, and its largest displacement then, m.
        public var residualSpeed: Double
        public var displacement: Float
    }

    /// The bodies' settlements since the last `restart()`, once `settleStructures()` has run.
    public private(set) var settlements: [Settlement] = []
    /// Whether `settleStructures()` has run since the last `restart()`.
    public private(set) var structuresSettled = false

    /// Settling's mass-proportional damping (1/s), the least time it gives a body, the time it
    /// gives a body at most, and how still a body must be, as its mean speed's share of the
    /// largest on the way.
    public static let settleDamping: Float = 50
    public static let settleMinimum = 0.02
    public static let settleLimit = 1.0
    public static let settleTolerance = 0.01

    /// Brings each body to rest under its own weight, alone and without the air, before the
    /// first step (the first batch does it if no one has): heavily damped until its motion has
    /// died away, then stopped where it is, its clock back at zero. Its deformation, stresses and
    /// any cracking from its own weight stay. A body that does not come to rest within
    /// `settleLimit` (one falling, or not standing) is put back undeformed and starts as it
    /// would without settling. Nothing is done with `configuration.settlesStructures` off (or
    /// `BOMBCAD_SETTLE=off` in the environment, for benches), once the run has started, or for a
    /// body without gravity, with motion set by the scene, or no longer as loaded (moved, set
    /// moving or broken since).
    public func settleStructures() {
        guard configuration.settlesStructures, !structuresSettled, stepCount == 0,
            ProcessInfo.processInfo.environment["BOMBCAD_SETTLE"] != "off"
        else { return }
        precondition(!batchInFlight, "Cannot settle while a batch is in flight")
        structuresSettled = true
        var moved = false
        for body in bodies where body.gravity > 0 && !body.hasSetMotion && body.isAsLoaded {
            let start = Date()
            let step = Double(body.criticalTimeStep)
            let chunk = max(1, Int((0.005 / step).rounded(.up)))
            let damping = body.damping
            body.damping = Self.settleDamping
            var elapsed = 0.0
            var steps = 0
            var peak = 0.0
            var speed = 0.0
            var settled = false
            var before: [(displacement: SIMD3<Float>, mass: Float)] = []
            while elapsed < Self.settleLimit {
                if elapsed + Double(chunk) * step >= Self.settleLimit { before = body.displacements() }
                body.advanceAlone(steps: chunk)
                steps += chunk
                elapsed += Double(chunk) * step
                let (energy, mass) = body.motion()
                speed = mass > 0 ? (2 * energy / mass).squareRoot() : 0
                peak = max(peak, speed)
                if elapsed >= Self.settleMinimum && speed <= Self.settleTolerance * peak {
                    settled = true
                    break
                }
            }
            if !settled, !before.isEmpty {
                // Still moving at the limit: settled all the same if it has come to rest over its last
                // chunk, its mean speed over it (its displacement's change) within the tolerance. A
                // joint on a footing chatters at rest, its nodes' speed never falling to 1% of the
                // sag's, its displacement still (`StructureOnTerrainTests`).
                let after = body.displacements()
                var squares = 0.0
                var mass = 0.0
                for (old, new) in zip(before, after) {
                    let moved = Double(simd_length(new.displacement - old.displacement))
                    squares += Double(new.mass) * moved * moved
                    mass += Double(new.mass)
                }
                let mean = mass > 0 ? (squares / mass).squareRoot() / (Double(chunk) * step) : 0
                if mean <= Double(Self.settleTolerance) * peak {
                    settled = true
                    speed = mean
                }
            }
            body.damping = damping
            if settled {
                body.holdStill()
            } else {
                body.reset()
            }
            moved = true
            settlements.append(
                Settlement(
                    name: body.name, settled: settled, time: elapsed, steps: steps,
                    seconds: Date().timeIntervalSince(start), residualSpeed: peak > 0 ? speed / peak : 0,
                    displacement: body.summary()?.selfWeightSag ?? 0))
        }
        guard moved, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        // Mark the settled structure in the solid mask.
        encodeBodyEnvelopes(encoder, clear: true)
        encodeRemask(encoder, fine: false)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    /// Resets time, histories and the peak/impulse fields, treating the current state as initial.
    /// The structure, if any, returns to its undeformed state.
    public func restart() {
        precondition(!batchInFlight, "Cannot restart while a batch is in flight")
        frameExtractor?.invalidate()
        time = 0
        stepCount = 0
        clockTicks = 0
        // The slivers a structure shut in are found again from where it stands (`remaskCapSlivers`).
        if let cappedSliverBuffer { memset(cappedSliverBuffer.contents(), 0, cappedSliverBuffer.length) }
        exposurePlane?.reset()
        exposureNeedsInitialSample = exposurePlane != nil
        envelopeExposure?.reset()
        envelopeNeedsInitialSample = envelopeExposure != nil
        envelopeComponentRecorder?.reset()
        componentsNeedInitialSample = envelopeComponentRecorder != nil
        envelopeVenting?.reset(mask: maskBuffer, rigidMask: rigidMaskBuffer)
        lastBatchGPUProfile = nil
        lastFluidStep = 0
        checkpointSubsteps = 0
        congestion?.reset()
        setUpRadiativeCooling()
        for body in bodies { body.reset() }
        settlements = []
        structuresSettled = false
        if let plan = tiledCoupling {
            let header = wallVelocityBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)
            header[0] = min(header[0], UInt32(plan.capacity))
            header[1] = 0
            if let occupancyBuffer { memset(occupancyBuffer.contents(), 0, occupancyBuffer.length) }
            if let combinedOccupancyBuffer {
                memset(combinedOccupancyBuffer.contents(), 0, combinedOccupancyBuffer.length)
            }
        }
        if let interactionBuffer { memset(interactionBuffer.contents(), 0, interactionBuffer.length) }
        if bodiesInContact {
            for (body, steps) in zip(bodies, stepsBeforeContact) {
                body.solids?.stepOverride = steps.solids
                body.shells?.stepOverride = steps.shells
            }
            bodiesInContact = false
        }

        // Structures' cut cells, kept as air before the remask marks the structure.
        try? setUpStructureCut()
        if hasBody, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        {
            // Mark the undeformed structure in the solid mask.
            encodeBodyEnvelopes(encoder, clear: true)
            encodeRemask(encoder, fine: false)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
        }
        gaugeHistories = Array(repeating: [], count: gaugeCount)
        resetDebrisExchange()
        memset(peakBuffer.contents(), 0, peakBuffer.length)
        memset(impulseBuffer.contents(), 0, impulseBuffer.length)
        maxSpeedBuffer.contents().storeBytes(of: 0, as: UInt64.self)
        airIsAsleep = false
        // Both state buffers start alike, so that a tile never swept holds the same state in each.
        memcpy(
            stateBuffers[1 - current].contents(), stateBuffers[current].contents(),
            stateBuffers[current].length)
        if hasSpecies {
            memcpy(
                speciesBuffers[1 - current].contents(), speciesBuffers[current].contents(),
                speciesBuffers[current].length)
        }
        // A deflagration's flame is advanced everywhere, its burning starts slowly, and vent panels
        // open where the air may not yet be awake.
        tilesEnabled = configuration.skipStillAir && deflagrationStage == nil
        memset(tileFlagBuffer.contents(), 0, tileFlagBuffer.length)
        tileCountBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        if tilesEnabled, tiledCoupling == nil, let region = couplingRegion {
            // Around the structure the mask moves and debris trades with the air, so those
            // tiles are always swept.
            let reach = 2
            let low = simd_max(region.origin &- reach, .zero) / Self.tileSize
            let high =
                simd_min(region.origin &+ region.dims &+ (reach - 1), SIMD3(grid.nx, grid.ny, grid.nz) &- 1)
                / Self.tileSize
            let flags = tileFlagBuffer.contents().bindMemory(to: UInt8.self, capacity: tileFlagBuffer.length)
            for z in low.z...high.z {
                for y in low.y...high.y {
                    for x in low.x...high.x { flags[x + tileDims.x * (y + tileDims.y * z)] = 1 }
                }
            }
        }

        setUpRefinement()
        assignGravityTables()

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        var uniforms = makeUniforms()
        encodeWakeCoupling(encoder)
        encoder.setComputePipelineState(measurePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        dispatchGrid(encoder, pipeline: measurePipeline)
        if tilesEnabled {
            let wake = gravityVariant(wakeTilesPipeline, "wakeTiles")
            encoder.setComputePipelineState(wake)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
            encoder.setBuffer(maskBuffer, offset: 0, index: 1)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
            encoder.setBuffer(hasSpecies ? speciesBuffers[current] : noSpecies, offset: 0, index: 4)
            // Not read without gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 5)
            dispatchGrid(encoder, pipeline: wake)
        }
        var placed = 0
        if refinement != nil {
            // Refine around the charge from the start; the regrid acts only on a step that
            // advances, so the clock is given one.
            var control = StepControl()
            control.dt = 1
            controlBuffer.contents().storeBytes(of: control, as: StepControl.self)
            encodeRegrid(encoder, species: currentSpecies, uniforms: uniforms, tiles: nil)
            // The structure's own outline in the new patches.
            encodeRemask(encoder)
            placed = 1
        }
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        depositFine(level: 0)
        // A level beneath another is placed from its parent's cells, once they hold the charge,
        // and the first level is kept around it.
        while placed < refinementLevels.count {
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return }
            encodeRegrid(encoder, species: currentSpecies, uniforms: uniforms, tiles: nil)
            encodeRemask(encoder)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            depositFine(level: placed)
            placed += 1
        }
        // A pool too small for the patches around the charge at the start grows fourfold, and
        // the run starts again, from the start, so that it is placed whole.
        let short = refinementLevels.map { $0.poolUse.ranOut && $0.maxPatches < $0.capacity }
        if short.contains(true) {
            growPools(to: zip(refinementLevels, short).map { $1 ? $0.maxPatches * 4 : $0.maxPatches })
            restart()
            return
        }
        poolLive = []
        refinementPoolGrewLate = false
    }

    /// Gives the cells of refinement level `level` (0 the first) their share of the charges laid
    /// down in the finest cells (`fineDeposit`): every cell of the coarse cells they touch, each
    /// the mean of the finest cells in it, whose mean the coarse cells already hold. With
    /// afterburning, the products are all unburnt fuel, and the air keeps its oxygen.
    private func depositFine(level: Int) {
        guard level < refinementLevels.count, !fineDeposit.isEmpty else { return }
        let target = refinementLevels[level]
        let finest = refinementLevels.reduce(1) { $0 * $1.ratio }
        let r = target.parentScale * target.ratio
        let below = finest / r
        let stillOxygen = Self.oxygenInAir * stillCell.density
        var cells: [SIMD3<Int>: (state: CellState, species: SIMD2<Float>)] = [:]
        for coarse in Set(fineDeposit.keys.map { $0 / finest }) {
            for n in 0..<(r * r * r) {
                let fine = coarse &* r &+ SIMD3(n % r, (n / r) % r, n / (r * r))
                var cell = stillCell
                var species = SIMD2<Float>(0, stillOxygen)
                if let table = gravityTable(scale: r) {
                    // Under gravity, the air at rest at the fine cell's height.
                    let row = table.contents().bindMemory(
                        to: SIMD4<Float>.self, capacity: 2 * (grid.nz * r + 8))[2 * (fine.z + 4)]
                    cell.density = row.x
                    (cell.momentumX, cell.momentumY, cell.momentumZ) = (0, 0, 0)
                    cell.energy = row.y
                    species.y = stillOxygen / stillCell.density * row.x
                }
                // The mean of its finest cells, summed in double precision, so that it does not
                // depend on their order.
                var added = SIMD2<Double>.zero
                for m in 0..<(below * below * below) {
                    let finer = fine &* below &+ SIMD3(m % below, (m / below) % below, m / (below * below))
                    added += SIMD2<Double>(fineDeposit[finer] ?? .zero)
                }
                if added != .zero {
                    let mean = SIMD2<Float>(added / Double(below * below * below))
                    cell.density += mean.x
                    cell.energy += mean.y
                    species.x += mean.x
                }
                cells[fine] = (cell, species)
            }
        }
        target.setFine(cells)
    }

    /// Of the refinement's memory, the share each level takes when there are two: the second
    /// level's blocks are an eighth the volume of the first's, so the shell of them around a
    /// shock takes several times as many.
    static let levelMemoryShares: [Double] = [1.0 / 3, 2.0 / 3]

    /// Makes, keeps or drops the finer levels for the configuration, and releases their patches.
    private func setUpRefinement() {
        let ratio = configuration.refinement
        guard ratio > 1 else {
            refinement = nil
            finerRefinement = nil
            updateGaugeChildren()
            return
        }
        let levels = configuration.refinementLevels > 1 && experimentalBoxes.isEmpty ? 2 : 1
        let total = configuration.refinementMemory
        let memory =
            levels == 1 ? [total] : Self.levelMemoryShares.map { Int(Double(total) * $0) }
        let startTotal = min(configuration.refinementStartMemory ?? total, total)
        let startMemory =
            levels == 1 ? [startTotal] : Self.levelMemoryShares.map { Int(Double(startTotal) * $0) }
        let composition = bodies.count > 1
        let cut = terrainCut != nil
        let first = AirRefinement.layout(
            grid: grid, ratio: ratio, parentScale: 1, memory: memory[0], species: hasSpecies,
            bodyComposition: composition, cut: cut)
        let second =
            levels > 1
            ? AirRefinement.layout(
                grid: grid, ratio: ratio, parentScale: ratio, memory: memory[1], species: hasSpecies,
                bodyComposition: composition, cut: cut) : nil
        // Each pool starts small and grows ahead of the patches in use (`makeRefinementRoom`);
        // one that has grown keeps its size.
        let start = (0..<levels).map { level in
            AirRefinement.layout(
                grid: grid, ratio: ratio, parentScale: level == 0 ? 1 : ratio, memory: startMemory[level],
                species: hasSpecies, bodyComposition: composition, cut: cut
            ).maxPatches
        }
        let side = AirRefinement.patchSize * ratio
        let reserve =
            second.map { ($0.tileDims.x * $0.tileDims.y * $0.tileDims.z, start[1] * side * side * side) }
            ?? (0, 0)
        let layoutChanged =
            refinement?.ratio != ratio || refinement?.species != hasSpecies
            || refinement?.bodyComposition != composition || refinement?.capacity != first.maxPatches
            || refinement?.cutTerrain != cut
            || finerRefinement?.capacity != second?.maxPatches
            || (refinement?.patchOfTile.length ?? 0)
                != max(16, (first.tileDims.x * first.tileDims.y * first.tileDims.z + reserve.0) * 4)
        if layoutChanged {
            refinement = nil
            finerRefinement = nil
            refinement = try? AirRefinement(
                device: device, library: library, grid: grid, ratio: ratio, memory: memory[0],
                species: hasSpecies, bodyComposition: composition, reserve: (reserve.0, reserve.1), cut: cut,
                start: start[0])
            if levels > 1, let refinement {
                finerRefinement = try? AirRefinement(
                    device: device, library: library, grid: grid, ratio: ratio, memory: memory[1],
                    species: hasSpecies, bodyComposition: composition, parent: refinement, cut: cut,
                    start: start[1])
            }
        }
        for level in refinementLevels {
            level.reset()
            let fine = grid.cellSize / Float(level.parentScale * level.ratio)
            level.setBoxes(rigidBoxes?.map { $0.holdingCells(of: fine) })
            level.setTerrain(rigidBoxes == nil ? nil : terrain)
            level.setPanes(ventedPanes)
        }
        for level in refinementLevels { level.coarseCut = cut ? terrainCut : nil }
        applyFacadeBand()
        updateGaugeChildren()
    }

    /// Grows each refined level's pool, while the GPU is idle, to keep room ahead of the patches
    /// in use: eight steps of the most a step has added, a quarter of those in use, and 64 at
    /// least, growing by a quarter at a time or more. As a patch keeps its slot and the pool
    /// hands out slots in the same order at any size (`AirRefinement.grow`), a pool that never
    /// fills steps exactly as one made at its full size, in a fraction of the memory: the 500 t
    /// burst refined twice to 2 m used 28% and 39% of the pools it would have held. Notes, too,
    /// whether a pool ran out since the last look while it could still have grown
    /// (`refinementPoolGrewLate`).
    private func makeRefinementRoom() {
        let levels = refinementLevels
        guard !levels.isEmpty else { return }
        if poolLive.count != levels.count {
            poolLive = levels.map(\.livePatches)
            poolGrowth = poolLive.map { max(Double($0) / 2, 16) }
            poolCouldGrow = levels.map { $0.maxPatches < $0.capacity }
            stepsSincePoolLook = 0
        }
        var targets: [Int] = []
        for (n, level) in levels.enumerated() {
            let live = level.livePatches
            if stepsSincePoolLook > 0 {
                poolGrowth[n] = max(poolGrowth[n], Double(live - poolLive[n]) / Double(stepsSincePoolLook))
            }
            if poolCouldGrow[n] && level.poolUse.ranOut { refinementPoolGrewLate = true }
            poolLive[n] = live
            let room = max(Int((8 * poolGrowth[n]).rounded(.up)), live / 4, 64)
            targets.append(
                live + room > level.maxPatches
                    ? min(max(live + room, level.maxPatches + level.maxPatches / 4), level.capacity)
                    : level.maxPatches)
        }
        stepsSincePoolLook = 0
        growPools(to: targets)
        poolCouldGrow = levels.map { $0.maxPatches < $0.capacity }
    }

    /// Grows the refined levels' pools to `targets` patches, the first level first.
    private func growPools(to targets: [Int]) {
        guard let refinement, zip(refinementLevels, targets).contains(where: { $1 > $0.maxPatches }) else {
            return
        }
        do {
            if let finer = finerRefinement, targets.count > 1 {
                let cells = finer.side * finer.side * finer.side
                let child = (finer.maxPatches * cells, min(targets[1], finer.capacity) * cells)
                try refinement.grow(to: targets[0], child: child)
                finer.adopt()
                try finer.grow(to: targets[1])
            } else {
                try refinement.grow(to: targets[0])
            }
        } catch {
            // Out of memory: the pools stay as they are, and refine no more than they hold.
        }
    }

    /// The most steps the next command buffer may take, so that no pool that could still grow
    /// fills before the next look: half its free slots at the most a step has added.
    private var poolStepLimit: Int {
        var limit = Int.max
        for (n, level) in refinementLevels.enumerated()
        where n < poolLive.count && level.maxPatches < level.capacity {
            let free = Double(level.maxPatches - poolLive[n])
            limit = min(limit, max(1, Int(free / (2 * max(poolGrowth[n], 1)))))
        }
        return limit
    }

    /// The uniforms of the second level, from the coarse grid's.
    private func finerUniforms(_ base: SolverUniforms) -> SolverUniforms? {
        finerRefinement?.levelUniforms(
            from: base,
            threshold: configuration.refinementFinerThreshold ?? configuration.refinementThreshold,
            grid: grid)
    }

    /// The coarse grid as the first level sees it.
    private func coarseView(species: MTLBuffer) -> AirRefinement.ParentView {
        AirRefinement.ParentView(
            state: stateBuffers[current], species: species, mask: maskBuffer,
            rigid: (hasBody || !experimentalBoxes.isEmpty) ? rigidMaskBuffer : maskBuffer,
            wallVelocity: wallVelocityBuffer, impulse: impulseBuffer, placeholder: refinementPlaceholder)
    }

    /// Step 7 for every level: flags each level's blocks (the second level's from the first
    /// level's cells, before the first is placed afresh), keeps the first level around the
    /// second, and places each level's patches, coarsest first.
    private func encodeRegrid(
        _ encoder: MTLComputeCommandEncoder, species: MTLBuffer, uniforms: SolverUniforms,
        tiles: (list: MTLBuffer, dispatch: MTLBuffer, threads: MTLSize)?
    ) {
        guard let refinement else { return }
        let deep = finerUniforms(uniforms)
        if let finerRefinement, let deep {
            finerRefinement.encodeFlagFromParent(encoder, control: controlBuffer, uniforms: deep)
        }
        refinement.encodeFlag(
            encoder, coarse: stateBuffers[current], mask: maskBuffer, control: controlBuffer, tiles: tiles,
            grid: grid, uniforms: uniforms, boxDefinition: experimentalBoxDefinition)
        if let finerRefinement, let deep {
            finerRefinement.encodeNest(encoder, control: controlBuffer, uniforms: deep)
        }
        refinement.encodePlace(
            encoder, parent: coarseView(species: species), control: controlBuffer, tileFlags: tileFlagBuffer,
            uniforms: uniforms, boxDefinition: experimentalBoxDefinition, maxSpeed: maxSpeedBuffer)
        if let finerRefinement, let deep {
            finerRefinement.encodePlace(
                encoder, parent: refinement.view(), control: controlBuffer, tileFlags: tileFlagBuffer,
                uniforms: deep, maxSpeed: maxSpeedBuffer)
        }
    }

    /// Whether each refined level takes only the substeps its own waves need
    /// (`SolverConfiguration.refinementOwnSteps`); not with the experimental box, which follows
    /// the first level's substeps itself, nor with the terrain's cut cells, whose differences are
    /// shared out after every substep's final sweep.
    private var ownLevelSteps: Bool {
        configuration.refinementOwnSteps && experimentalBoxes.isEmpty && refinement?.cutTerrain != true
    }

    // MARK: - Stepping

    /// The most steps the next batch may take: `steps`, limited to `maxStepsPerBatch` and, with
    /// a body, to the next checkpoint.
    public func batchSteps(_ steps: Int) -> Int {
        var steps = min(max(steps, 1), Self.maxStepsPerBatch)
        if hasBody {
            steps = min(steps, Self.checkpointInterval - stepCount % Self.checkpointInterval)
        }
        return steps
    }

    /// Encodes up to `steps` time steps into a new, uncommitted command buffer.
    ///
    /// Commit the buffer, wait for it to complete, then call `completeBatch()` before encoding
    /// another. Steps that would pass `timeLimit` (absolute simulation time) become no-ops, and
    /// with a body the batch ends at the next checkpoint (see `batchSteps`).
    public func encodeBatch(
        steps: Int, timeLimit: Double? = nil, updateVisualization: Bool = false
    ) -> MTLCommandBuffer? {
        makeRefinementRoom()
        let steps = min(batchSteps(steps), poolStepLimit)
        return encodeBatchPart(
            steps: steps, range: 0..<steps, timeLimit: timeLimit, updateVisualization: updateVisualization)
    }

    /// Encodes steps `range` of a batch of `steps` into a new, uncommitted command buffer: the
    /// batch's setup with its first part, its sampling and drawing with its last, as `encodeBatch`
    /// does all at once. The parts share the batch's state on the GPU (its clock and its time
    /// limit among it), so the steps are the same however the batch is cut; commit each and wait
    /// for it before encoding the next, and call `completeBatch()` after the last.
    func encodeBatchPart(
        steps: Int, range: Range<Int>, timeLimit: Double?, updateVisualization: Bool
    ) -> MTLCommandBuffer? {
        let first = range.lowerBound == 0
        let last = range.upperBound == steps
        if first {
            precondition(!batchInFlight, "completeBatch() must be called before encoding another batch")
            guard !interObjectContactDetected && !couplingCapacityExceeded else { return nil }
            settleStructures()
            assignGravityTables()
            gpuProfiler?.beginBatch()
        }
        guard let kernels = try? cellKernels(),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let initialEncoder = gpuProfiler?.encoder(command: commandBuffer, phase: "observation")
                ?? commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        var encoder = initialEncoder
        var currentPhase = "observation"
        func phase(_ name: String) {
            guard let gpuProfiler, name != currentPhase || !gpuProfiler.detailed else { return }
            encoder.endEncoding()
            encoder = gpuProfiler.encoder(command: commandBuffer, phase: name)!
            currentPhase = name
        }
        // With detailed profiling, a stage of the air of its own encoder.
        func airStage(_ name: String) {
            if gpuProfiler?.detailed == true { phase("air/" + name) }
        }
        if gpuProfiler?.detailed == true {
            for level in refinementLevels {
                level.stage = { name in
                    airStage(name)
                    return encoder
                }
            }
            liveEncoder = { encoder }
        }
        defer {
            for level in refinementLevels { level.stage = nil }
            liveEncoder = nil
        }
        // In flight from the first part's encoding until `completeBatch()`.
        defer { if first { batchInFlight = true } }
        stepsSincePoolLook += range.count

        if first {
            var control = StepControl()
            if let timeLimit {
                control.timeLimit = Float(max(timeLimit - time, 0))
            }
            control.clockLow = UInt32(truncatingIfNeeded: clockTicks)
            control.clockHigh = UInt32(truncatingIfNeeded: clockTicks >> 32)
            controlBuffer.contents().storeBytes(of: control, as: StepControl.self)
            if exposureNeedsInitialSample {
                encodeExposure(encoder, initial: true)
                exposureNeedsInitialSample = false
            }
            if envelopeNeedsInitialSample {
                encodeEnvelopeExposure(encoder, initial: true)
                envelopeNeedsInitialSample = false
            }
            if componentsNeedInitialSample {
                encodeEnvelopeComponents(encoder, initial: true)
                componentsNeedInitialSample = false
            }
        }

        let extents = [grid.nx, grid.ny, grid.nz]
        let tileThreads = Self.tileThreads(for: kernels.sweepTiles)
        if first {
            if stepCount % Self.checkpointInterval == 0 || checkpointSubsteps == 0 {
                checkpointSubsteps = structureSubsteps
                if let bodyStep, lastFluidStep > 0 {
                    let likely = Int((1.25 * lastFluidStep / bodyStep).rounded(.up)) + 1
                    checkpointSubsteps = max(likely, 1)
                }
                for body in bodies { body.checkpoint() }
            }
            batchSubsteps = min(checkpointSubsteps, structureSubsteps)
        }
        let substeps = batchSubsteps
        for step in range {
            phase("coupling")
            encodeBodyEnvelopes(encoder, clear: true)
            if !airIsAsleep { encodeAllocateCoupling(encoder) }
            if tiledCoupling != nil { encodeInteractionCheck(encoder) }
            phase("air")
            airStage("prepare")
            let globalStep = stepCount + step
            let ramp = min(1, Float(globalStep + 1) / Float(max(configuration.startupSteps, 1)))
            var uniforms = makeUniforms(cfl: configuration.cfl * ramp)
            // With the air asleep, each step is exactly as long as the structure's substeps cover.
            let asleep = airIsAsleep && hasBody
            if asleep, let bodyStep {
                uniforms.forcedStep = 0.999 * Float(structureSubsteps) * bodyStep
            } else if let bodyStep {
                // Only the substeps this step is likely to need are encoded, a quarter more than
                // the step before the last checkpoint took; the air may step no further than
                // they cover.
                uniforms.maxStep = 0.999 * Float(substeps) * bodyStep
            }

            if asleep {
                uniforms.tileNx = 0
            } else if tilesEnabled {
                let tiles = tileDims.x * tileDims.y * tileDims.z
                encoder.setComputePipelineState(kernels.collectTiles)
                encoder.setBuffer(tileFlagBuffer, offset: 0, index: 0)
                encoder.setBuffer(tileListBuffer, offset: 0, index: 1)
                encoder.setBuffer(tileCountBuffer, offset: 0, index: 2)
                encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 3)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
                // Not read without gravity.
                encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 5)
                encoder.dispatchThreads(
                    MTLSize(width: tiles, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: min(tiles, kernels.collectTiles.maxTotalThreadsPerThreadgroup), height: 1,
                        depth: 1))
            }

            encoder.setComputePipelineState(gravityVariant(preparePipeline, "prepareStep"))
            // Not read without gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 15)
            encoder.setBuffer(controlBuffer, offset: 0, index: 0)
            encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 1)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 2)
            encoder.setBuffer(gaugeLogBuffer, offset: 0, index: 3)
            encoder.setBuffer(gaugeCellBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.setBuffer(tileCountBuffer, offset: 0, index: 6)
            encoder.setBuffer(tileDispatchBuffer, offset: 0, index: 7)
            encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: 8)
            encoder.setBuffer(refinement?.fine[0] ?? refinementPlaceholder, offset: 0, index: 9)
            encoder.setBuffer(gaugeChildBuffer, offset: 0, index: 10)
            encoder.setBuffer(refinement?.fineMask ?? refinementPlaceholder, offset: 0, index: 11)
            encodeFinerGaugeBuffers(encoder)
            encoder.setBuffer(maskBuffer, offset: 0, index: 16)
            encoder.setBuffer(gaugePointBuffer, offset: 0, index: 17)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

            if !asleep { encodeEddyViscosity(encoder, uniforms: uniforms) }
            let refining = refinement != nil && !asleep
            if let refinement, refining, ownLevelSteps {
                refinement.encodeLevelSteps(
                    encoder, control: controlBuffer, maxSpeed: maxSpeedBuffer, uniforms: uniforms,
                    child: finerRefinement)
            }
            if let refinement, refining {
                refinement.encodeSaveHalo(
                    encoder, parent: coarseView(species: currentSpecies), uniforms: uniforms,
                    control: controlBuffer)
            }

            // Alternate the sweep order each step so the splitting error stays second order.
            let order = globalStep.isMultiple(of: 2) ? [0, 1, 2] : [2, 1, 0]
            // An axis with a single cell has identical fluxes on both faces and can be skipped,
            // but at least one sweep must run to keep the bookkeeping kernels going.
            var axes = order.filter { extents[$0] > 1 }
            if axes.isEmpty { axes = [0] }

            airStage("coarse sweeps")
            encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBuffer(peakBuffer, offset: 0, index: 3)
            encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
            encoder.setBuffer(controlBuffer, offset: 0, index: 5)
            encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
            encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
            encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
            encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: 13)
            encoder.setBuffer(refinement?.coarseFlux ?? refinementPlaceholder, offset: 0, index: 14)
            encoder.setBuffer(refinement?.coarseSpeciesFlux ?? refinementPlaceholder, offset: 0, index: 15)
            encoder.setBuffer(experimentalBoxMask ?? noSpecies, offset: 0, index: 16)
            encoder.setBuffer(experimentalBoxImpulse ?? noSpecies, offset: 0, index: 17)
            // Not read without gravity, or without mixing.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 18)
            encoder.setBuffer(mixingViscosity() ?? noSpecies, offset: 0, index: 19)
            encoder.setBuffer(terrainCut?.columns ?? noSpecies, offset: 0, index: 20)
            encoder.setBuffer(terrainCut?.records ?? noSpecies, offset: 0, index: 21)
            encoder.setBuffer(terrainCut?.walls ?? noSpecies, offset: 0, index: 22)
            encoder.setBuffer(terrainCut?.defects ?? noSpecies, offset: 0, index: 23)
            encoder.setBuffer(terrainCut?.ceilings ?? noSpecies, offset: 0, index: 24)
            // Not read without congestion.
            encoder.setBuffer(congestionBuffer ?? noSpecies, offset: 0, index: 25)
            // Not read without structures' cut cells.
            encoder.setBuffer(structureCut?.index ?? noSpecies, offset: 0, index: 26)
            encoder.setBuffer(structureCut?.records ?? noSpecies, offset: 0, index: 27)
            encoder.setBuffer(structureCut?.walls ?? noSpecies, offset: 0, index: 28)
            encoder.setBuffer(structureCut?.defects ?? noSpecies, offset: 0, index: 29)
            for (n, axis) in axes.enumerated() where !asleep {
                if configuration.periodicSides { encodePeriodicHalo(encoder, uniforms: uniforms) }
                uniforms.axis = UInt32(axis)
                uniforms.finalSweep = n == axes.count - 1 ? 1 : 0
                encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
                encoder.setBuffer(stateBuffers[1 - current], offset: 0, index: 1)
                encoder.setBuffer(hasSpecies ? speciesBuffers[current] : noSpecies, offset: 0, index: 11)
                encoder.setBuffer(hasSpecies ? speciesBuffers[1 - current] : noSpecies, offset: 0, index: 12)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 7)
                if tilesEnabled {
                    encoder.dispatchThreadgroups(
                        indirectBuffer: tileDispatchBuffer, indirectBufferOffset: 0,
                        threadsPerThreadgroup: tileThreads)
                } else {
                    dispatchGrid(encoder, pipeline: kernels.sweep)
                }
                // Where the air is refined, after refluxing instead (below).
                if let terrainCut, n == axes.count - 1, !terrainCut.geometry.cutColumns.isEmpty,
                    !(refinement != nil && refining)
                {
                    encodeCutRedistribution(
                        encoder, cut: terrainCut, pipeline: kernels.redistributeCutDefects,
                        uniforms: uniforms,
                        state: stateBuffers[1 - current],
                        species: hasSpecies ? speciesBuffers[1 - current] : noSpecies)
                    // The merge took over the encoder's pipeline and some of its buffers.
                    encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
                    encoder.setBuffer(maskBuffer, offset: 0, index: 2)
                    encoder.setBuffer(peakBuffer, offset: 0, index: 3)
                    encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
                    encoder.setBuffer(controlBuffer, offset: 0, index: 5)
                    encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
                    encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
                    encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
                    encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
                }
                if let structureCut, n == axes.count - 1, refinement == nil {
                    encodeStructureCutRedistribution(
                        encoder, cut: structureCut, kernels: kernels, uniforms: uniforms,
                        state: stateBuffers[1 - current],
                        species: hasSpecies ? speciesBuffers[1 - current] : noSpecies)
                    encoder.setComputePipelineState(tilesEnabled ? kernels.sweepTiles : kernels.sweep)
                    encoder.setBuffer(maskBuffer, offset: 0, index: 2)
                    encoder.setBuffer(peakBuffer, offset: 0, index: 3)
                    encoder.setBuffer(impulseBuffer, offset: 0, index: 4)
                    encoder.setBuffer(controlBuffer, offset: 0, index: 5)
                    encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 6)
                    encoder.setBuffer(wallVelocityBuffer, offset: 0, index: 8)
                    encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
                    encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
                }
                current = 1 - current
            }
            if let congestion, !asleep {
                // The congestion's drag after the step's sweeps, then the turbulence its obstacles
                // make (see `congestionDrag` and `obstacleTurbulence`).
                var fields = uniforms
                encoder.setComputePipelineState(congestion.drag)
                encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
                encoder.setBuffer(congestion.porosityDrag, offset: 0, index: 1)
                encoder.setBuffer(maskBuffer, offset: 0, index: 2)
                encoder.setBuffer(controlBuffer, offset: 0, index: 3)
                encoder.setBytes(&fields, length: MemoryLayout<SolverUniforms>.stride, index: 4)
                encoder.setBuffer(congestion.parallel, offset: 0, index: 5)
                encoder.setBuffer(congestion.turbulence[congestion.current], offset: 0, index: 6)
                dispatchGrid(encoder, pipeline: congestion.drag)
                encoder.setComputePipelineState(congestion.turbulenceUpdate)
                encoder.setBuffer(congestion.generation, offset: 0, index: 2)
                encoder.setBuffer(congestion.parallel, offset: 0, index: 3)
                encoder.setBuffer(maskBuffer, offset: 0, index: 4)
                encoder.setBuffer(controlBuffer, offset: 0, index: 5)
                encoder.setBytes(&fields, length: MemoryLayout<SolverUniforms>.stride, index: 6)
                encoder.setBuffer(congestion.turbulence[congestion.current], offset: 0, index: 7)
                encoder.setBuffer(congestion.turbulence[1 - congestion.current], offset: 0, index: 8)
                dispatchGrid(encoder, pipeline: congestion.turbulenceUpdate)
                congestion.current = 1 - congestion.current
            }
            if let refinement, refining {
                let coarse = coarseView(species: currentSpecies)
                refinement.encodeSubsteps(
                    encoder, axes: axes, parent: coarse, peak: peakBuffer, control: controlBuffer,
                    maxSpeed: maxSpeedBuffer, uniforms: uniforms,
                    child: finerRefinement.flatMap { level in finerUniforms(uniforms).map { (level, $0) } })
                refinement.encodeRefluxAndRestrict(
                    encoder, axes: axes, parent: coarse, control: controlBuffer, uniforms: uniforms
                ) { encoder in
                    guard let terrainCut = self.terrainCut, !terrainCut.geometry.cutColumns.isEmpty else {
                        return
                    }
                    self.encodeCutRedistribution(
                        encoder, cut: terrainCut, pipeline: kernels.redistributeCutDefects,
                        uniforms: uniforms,
                        state: self.stateBuffers[self.current],
                        species: self.currentSpecies)
                    // What reached first-level cells the second level covers is carried down to it.
                    if let finer = self.finerRefinement, let deep = self.finerUniforms(uniforms) {
                        finer.encodeSync(
                            encoder, parent: refinement.view(), control: self.controlBuffer, uniforms: deep)
                    }
                }
            }
            airStage("other")
            if let radiativeCoolingStage, !asleep {
                // Every few steps, and at the batch's end, the luminous gas loses what it has
                // radiated since, in the coarse cells; the fine cells under them each lose as much a
                // volume, as they gain what debris trades with the air.
                let take =
                    step == steps - 1
                    || (globalStep + 1).isMultiple(of: max(radiativeCoolingStage.settings.interval, 1))
                radiativeCoolingStage.encode(
                    encoder, take: take, state: stateBuffers[current], mask: maskBuffer,
                    species: hasSpecies && configuration.afterburning ? speciesBuffers[current] : nil,
                    placeholder: noSpecies,
                    control: controlBuffer, uniforms: uniforms,
                    tiles: tilesEnabled ? (tileListBuffer, tileDispatchBuffer, tileThreads) : nil)
                if take, let refinement, refining {
                    refinement.encodeSync(
                        encoder, parent: coarseView(species: currentSpecies), control: controlBuffer,
                        uniforms: uniforms)
                    if let finerRefinement, let deep = finerUniforms(uniforms) {
                        finerRefinement.encodeSync(
                            encoder, parent: refinement.view(), control: controlBuffer, uniforms: deep)
                    }
                }
            }
            if let deflagrationStage, !asleep {
                deflagrationStage.encodeStep(
                    encoder, state: stateBuffers[current],
                    species: hasSpecies ? speciesBuffers[current] : nil,
                    mask: maskBuffer,
                    rigidMask: rigidMaskBuffer, viscosity: mixingViscosity(), control: controlBuffer,
                    congestion: congestion)
            }

            phase("mechanics")
            if hasBody {
                // The structure covers the same interval in several smaller steps, loaded by the
                // pressure the air has just reached (the fine cells', where it is refined). While
                // the air is frozen it cannot take back what debris would take from it, so debris
                // then moves on without it.
                var binding = StructureSolver.FluidBinding(
                    state: stateBuffers[current], mask: maskBuffer, control: controlBuffer, grid: grid,
                    gamma: configuration.gamma, ambientPressure: configuration.ambientPressure,
                    airModel: configuration.airModel,
                    exchange: asleep ? nil : debrisExchangeBuffer, debrisArea: debrisAreaBuffer,
                    exchangeRegion: couplingRegion)
                binding.couplingMap = tiledCoupling == nil ? nil : wallVelocityBuffer
                binding.couplingMapCount = UInt32(tiledCoupling?.mapCount ?? 0)
                binding.readsCutCells = structureCut != nil
                if let refinement {
                    binding.refinement = (
                        refinement.patchOfTile, refinement.fine[0], refinement.fineMask, refinement.ratio,
                        refinement.tileDims
                    )
                }
                if let deep = finerRefinement {
                    binding.deepRefinement = (
                        deep.parentScale * deep.ratio, deep.tileDims, deep.patchOffset, deep.cellOffset
                    )
                }
                let count = asleep ? structureSubsteps : substeps
                if bodies.count > 1 {
                    for body in bodies { body.prepareDebrisAreas(encoder, fluid: binding) }
                    binding.debrisAreasPrepared = true
                }
                if bodiesInContact {
                    encodeBodiesInContact(encoder, count: count, fluid: binding)
                }
                for (index, body) in bodies.enumerated() where !bodiesInContact {
                    if bodies.count > 1 {
                        body.encodeSubsteps(
                            encoder, count: count, fluid: binding,
                            afterSubstep: { [self] substep in
                                encodeBodyEnvelope(encoder, index: index, substep: substep)
                            })
                    } else {
                        body.encodeSubsteps(encoder, count: count, fluid: binding)
                    }
                }
                phase("coupling")
                encodeBodyEnvelopes(encoder, clear: false)
                encodeInteractionCheck(encoder)
                if !asleep {
                    encodeDebrisExchange(encoder)
                }
                // The solid outline follows the structure even while the air sleeps: the air is frozen,
                // but a body still moving reads the frozen air beside where it now is. Frozen where
                // it was when the air went to sleep, a face that had moved back through that outline
                // read solid cells, and no air, on one side and frozen air on the other (Mendonça's
                // slabs, thrown up and landing, were pushed down at about 11 g). Where nothing
                // crosses a cell's centre the outline and the air are left exactly as they were.
                // Asleep, it takes no new coupling pages, and the interaction check above stands.
                if configuration.twoWayCoupling {
                    encodeRemask(encoder, allocate: !asleep)
                    if !asleep { encodeInteractionCheck(encoder) }
                }
                if let refinement, refining {
                    refinement.encodeSync(
                        encoder, parent: coarseView(species: currentSpecies), control: controlBuffer,
                        uniforms: uniforms)
                    if let finerRefinement, let deep = finerUniforms(uniforms) {
                        finerRefinement.encodeSync(
                            encoder, parent: refinement.view(), control: controlBuffer, uniforms: deep)
                    }
                }
            }
            phase("air")
            if refining {
                encodeRegrid(
                    encoder, species: currentSpecies, uniforms: uniforms,
                    tiles: tilesEnabled ? (tileListBuffer, tileDispatchBuffer, tileThreads) : nil)
            }
            phase("observation")
            encodeExposure(encoder, initial: false)
            encodeEnvelopeExposure(encoder, initial: false)
            encodeEnvelopeComponents(encoder, initial: false)
            encodeEnvelopeVenting(encoder)
        }
        guard last else {
            encoder.endEncoding()
            return commandBuffer
        }
        if gaugeCount > 0 {
            var uniforms = makeUniforms()
            encoder.setComputePipelineState(gravityVariant(sampleGaugesPipeline, "sampleGauges"))
            // Not read without gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? noSpecies, offset: 0, index: 15)
            encoder.setBuffer(controlBuffer, offset: 0, index: 0)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 2)
            encoder.setBuffer(gaugeLogBuffer, offset: 0, index: 3)
            encoder.setBuffer(gaugeCellBuffer, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.setBuffer(refinement?.patchOfTile ?? refinementPlaceholder, offset: 0, index: 8)
            encoder.setBuffer(refinement?.fine[0] ?? refinementPlaceholder, offset: 0, index: 9)
            encoder.setBuffer(gaugeChildBuffer, offset: 0, index: 10)
            encoder.setBuffer(refinement?.fineMask ?? refinementPlaceholder, offset: 0, index: 11)
            encodeFinerGaugeBuffers(encoder)
            encoder.setBuffer(maskBuffer, offset: 0, index: 16)
            encoder.setBuffer(gaugePointBuffer, offset: 0, index: 17)
            encoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        }
        if !frameRequest.isEmpty, frameExtractor == nil {
            frameExtractor = try? FrameExtractor(library: library)
        }
        frameExtractor?.encode(
            encoder, request: frameRequest, grid: grid, state: stateBuffers[current], mask: maskBuffer,
            species: currentSpecies, hasSpecies: speciesHoldDetonationProducts, control: controlBuffer,
            uniforms: makeUniforms())
        if updateVisualization || frameRequest.viewField != nil {
            encodeVisualization(encoder)
        }
        // After the visualisation, which it is cut down from, in the same encoder.
        if let stride = frameRequest.viewField {
            frameExtractor?.encodeViewField(
                encoder, stride: stride, grid: grid, field: visualizationTexture, control: controlBuffer,
                always: false)
        }
        encoder.endEncoding()
        return commandBuffer
    }

    /// Folds the results of the last completed batch into `time`, `stepCount` and the gauges.
    @discardableResult
    public func completeBatch() -> BatchResult {
        precondition(batchInFlight, "No batch to complete")
        batchInFlight = false
        lastBatchGPUProfile = gpuProfiler?.resolve()
        let control = controlBuffer.contents().load(as: StepControl.self)
        clockTicks = control.clock
        // A row per step, and one for the state the batch ended in.
        let rows = Int(control.stepIndex) + (gaugeCount > 0 ? 1 : 0)
        let rowStride = gaugeCount + 1
        let log = gaugeLogBuffer.contents().bindMemory(to: Float.self, capacity: rows * rowStride)
        // The clock adds up the steps one by one, so that it reads the same however they were
        // batched.
        let start = time
        var lastStep: Float = 0
        for row in 0..<rows {
            let step = log[row * rowStride]
            for gauge in 0..<gaugeCount {
                // A step that did nothing, and the batch's last row, repeat a sample at a time
                // already recorded; skip them.
                if let last = gaugeHistories[gauge].last, last.time >= time { continue }
                gaugeHistories[gauge].append(
                    GaugeSample(time: time, pressure: log[row * rowStride + 1 + gauge]))
            }
            time += Double(step)
            if step > 0 { lastStep = step }
        }
        let elapsed = time - start
        deflagrationStage?.complete()
        for body in bodies {
            body.time = time
            if bodies.count > 1 {
                body.solids?.time = time
                body.shells?.time = time
            }
        }
        stepCount += Int(control.activeSteps)
        if let radiativeCoolingStage {
            radiatedEnergy += radiativeCoolingStage.collect(rows: Int(control.stepIndex))
            radiationHistory.append((time, radiatedEnergy))
        }
        // Once the blast has left and the air is close to ambient everywhere, stop advancing it.
        // This is decided only at a checkpoint, from the step before it.
        if hasBody, !airIsAsleep, control.activeSteps > 0, stepCount % Self.checkpointInterval == 0 {
            let quiet =
                configuration.airSleepThreshold > 0
                && control.maxOverpressure < configuration.airSleepThreshold * configuration.ambientPressure
            let crossing = Double(simd_length(grid.size) / ambientSoundSpeed)
            let late =
                configuration.airSleepCrossings > 0
                && time > Double(configuration.airSleepCrossings) * crossing
            // A deflagration's pressure rises slowly from nothing, and lasts many crossings.
            airIsAsleep = (quiet || late) && !hasFlame
        }
        if control.activeSteps > 0 { lastFluidStep = control.lastStep }
        var swept = 1.0
        if tilesEnabled {
            let tiles = Double(tileDims.x * tileDims.y * tileDims.z)
            swept =
                control.activeSteps > 0
                ? Double(control.tileSweeps) / (Double(control.activeSteps) * tiles) : 0
        }
        frameExtractor?.complete(reachedLimit: control.stopped == 2, time: time, steps: stepCount)
        // Bodies that came close stopped the batch; from the next, they meet in contact.
        var contactStarted = false
        if bodyEnvelopesOverlap, configuration.interBodyContact, !bodiesInContact, !couplingCapacityExceeded {
            bodiesInContact = true
            contactStarted = true
            // In contact, every body takes the shortest of their steps, so that the two sides of
            // each pair push for the same time and their impulses are equal and opposite.
            let common = bodies.map(\.criticalTimeStep).min()!
            stepsBeforeContact = bodies.map { ($0.solids?.stepOverride, $0.shells?.stepOverride) }
            for body in bodies {
                body.solids?.stepOverride = common
                body.shells?.stepOverride = common
            }
        }
        return BatchResult(
            steps: Int(control.activeSteps), elapsed: elapsed, lastTimeStep: Double(lastStep),
            // A NaN anywhere in the air makes the wave speed NaN, which the step's maximum
            // passes over, so the step itself stays finite: the overpressure says it.
            isStable: control.batchTime.isFinite && control.dt.isFinite && !control.maxOverpressure.isNaN,
            maxOverpressure: control.maxOverpressure, sweptFraction: swept,
            refinedTiles: refinement?.patchCount ?? 0, finerRefinedTiles: finerRefinement?.patchCount ?? 0,
            firstLevelSubsteps: levelSubsteps(control, level: 0),
            secondLevelSubsteps: levelSubsteps(control, level: 1),
            stoppedShort: control.stopped == 1,
            reachedLimit: control.stopped == 2, unsupportedInteraction: interObjectContactDetected,
            contactStarted: contactStarted, couplingCapacityExceeded: couplingCapacityExceeded)
    }

    /// Advances by `steps` time steps, blocking until the GPU has finished.
    @discardableResult
    public func advance(steps: Int, timeLimit: Double? = nil) -> BatchResult {
        var total = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        var remaining = steps
        var stoppedShort = false
        while remaining > 0 {
            // A batch that stopped just short of the limit is nearly always one step from it.
            let count = batchSteps(stoppedShort ? 1 : remaining)
            // The batch in command buffers of about `commandBufferTarget` of the GPU's time each,
            // so that none holds the GPU long enough to starve the window server; the steps are
            // the same however it is cut (`encodeBatchPart`).
            var encoded = 0
            var failed = false
            while encoded < count {
                makeRefinementRoom()
                let part = min(
                    gpuProfiler == nil ? gpuSteps.part(count - encoded) : count - encoded, poolStepLimit)
                guard
                    let commandBuffer = encodeBatchPart(
                        steps: count, range: encoded..<(encoded + part), timeLimit: timeLimit,
                        updateVisualization: false)
                else {
                    failed = true
                    break
                }
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                failed = failed || commandBuffer.error != nil
                gpuSteps.measure(commandBuffer, steps: part)
                encoded += part
            }
            // Nothing encoded: no batch to complete.
            if encoded == 0 { break }
            let result = completeBatch()
            total.sweptFraction = Self.mergeSwept(total, result)
            (total.firstLevelSubsteps, total.secondLevelSubsteps) = Self.mergeSubsteps(total, result)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable && !failed
            total.refinedTiles = result.refinedTiles
            total.finerRefinedTiles = result.finerRefinedTiles
            remaining -= result.steps
            stoppedShort = result.stoppedShort
            if result.contactStarted { continue }
            if result.steps == 0 || result.reachedLimit || (result.steps < count && !result.stoppedShort)
                || !result.isStable
            {
                break
            }
        }
        total.unsupportedInteraction = interObjectContactDetected
        total.couplingCapacityExceeded = couplingCapacityExceeded
        return total
    }

    /// The GPU time a command buffer of `advance` aims at, in seconds: well under the second or
    /// so after which the window server, starved of the GPU, is killed by the system's watchdog,
    /// and long enough that committing and waiting cost a fraction of a percent.
    /// `BOMBCAD_COMMAND_BUFFER_SECONDS` in the environment sets another, to check that the steps
    /// are the same however they are cut.
    public static let commandBufferTarget =
        ProcessInfo.processInfo.environment["BOMBCAD_COMMAND_BUFFER_SECONDS"].flatMap(Double.init) ?? 0.075

    /// The GPU's time for a step lately, from the buffers `advance` has waited for.
    private var gpuSteps = GPUStepRate()

    /// The GPU time each of `advance`'s command buffers aims at, `commandBufferTarget` unless
    /// set; the steps are the same whatever it is.
    public var commandBufferSeconds: Double {
        get { gpuSteps.target }
        set { gpuSteps.target = newValue }
    }

    /// Advances until simulation time reaches `endTime`, blocking until the GPU has finished.
    @discardableResult
    public func advance(until endTime: Double) -> BatchResult {
        var total = BatchResult(steps: 0, elapsed: 0, lastTimeStep: 0, isStable: true)
        while endTime - time > 1e-7 * max(endTime, 1e-3) {
            let result = advance(steps: 64, timeLimit: endTime)
            total.sweptFraction = Self.mergeSwept(total, result)
            (total.firstLevelSubsteps, total.secondLevelSubsteps) = Self.mergeSubsteps(total, result)
            total.steps += result.steps
            total.elapsed += result.elapsed
            total.lastTimeStep = result.lastTimeStep
            total.maxOverpressure = result.maxOverpressure
            total.isStable = total.isStable && result.isStable
            total.refinedTiles = result.refinedTiles
            total.finerRefinedTiles = result.finerRefinedTiles
            if result.steps == 0 || !result.isStable { break }
        }
        total.unsupportedInteraction = interObjectContactDetected
        total.couplingCapacityExceeded = couplingCapacityExceeded
        return total
    }

    /// The substeps each refined level took per step in the last batch (see `BatchResult`).
    private func levelSubsteps(_ control: StepControl, level: Int) -> Double {
        let levels = refinementLevels
        guard level < levels.count, let ratio = refinement?.ratio else { return 0 }
        guard ownLevelSteps, control.activeSteps > 0 else {
            return Double(level == 0 ? ratio : ratio * ratio)
        }
        let sum = level == 0 ? control.levelSubstepSum0 : control.levelSubstepSum1
        return Double(sum) / Double(control.activeSteps)
    }

    /// The levels' substeps per step of two runs of steps together, weighted by their steps.
    private static func mergeSubsteps(_ total: BatchResult, _ result: BatchResult) -> (Double, Double) {
        let steps = Double(total.steps + result.steps)
        guard steps > 0 else { return (result.firstLevelSubsteps, result.secondLevelSubsteps) }
        let (a, b) = (Double(total.steps), Double(result.steps))
        return (
            (total.firstLevelSubsteps * a + result.firstLevelSubsteps * b) / steps,
            (total.secondLevelSubsteps * a + result.secondLevelSubsteps * b) / steps
        )
    }

    /// The swept fraction of two runs of steps together, weighted by their steps.
    private static func mergeSwept(_ total: BatchResult, _ result: BatchResult) -> Double {
        let steps = total.steps + result.steps
        guard steps > 0 else { return result.sweptFraction }
        return (total.sweptFraction * Double(total.steps) + result.sweptFraction * Double(result.steps))
            / Double(steps)
    }

    /// The visualisation field every `stride`-th cell along each axis (`viewFieldSize`), each texel
    /// its block's extremes, as `rgba16Float` texels, eight bytes each, x fastest: for a view of
    /// the run drawn elsewhere. Cut out at the end of the batch that ended now if `frameRequest`
    /// asked for it, so the GPU need not be waited for again; otherwise worked out now, blocking
    /// until done. Call it only while no batch is in flight.
    public func viewField(stride: Int) throws -> Data {
        precondition(!batchInFlight, "Cannot read the view field while a batch is in flight")
        precondition(stride >= 1)
        if let field = frameExtractor?.viewField(stride: stride, grid: grid, time: time, steps: stepCount) {
            return field
        }
        if frameExtractor == nil { frameExtractor = try FrameExtractor(library: library) }
        guard let frameExtractor, let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { throw BlastError.allocationFailed("view field") }
        encodeVisualization(encoder)
        frameExtractor.encodeViewField(
            encoder, stride: stride, grid: grid, field: visualizationTexture, control: controlBuffer,
            always: true)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let field = frameExtractor.viewFieldData(viewFieldSize(stride: stride)) else {
            throw BlastError.allocationFailed("view field")
        }
        return field
    }

    /// The view field's texels along each axis at `stride`, rounded up.
    public func viewFieldSize(stride: Int) -> SIMD3<Int> {
        FrameExtractor.viewFieldSize(grid, stride: stride)
    }

    /// Rebuilds `visualizationTexture` from the current state, blocking until done.
    public func refreshVisualization() {
        precondition(!batchInFlight, "Cannot refresh while a batch is in flight")
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }
        encodeVisualization(encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    // MARK: - Reading results

    private func encodeEnvelopeExposure(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let observer = envelopeExposure else { return }
        var uniforms = makeUniforms()
        // Faces in still tiles read the still air; under gravity it is not uniform.
        var parameters = SIMD4<UInt32>(
            UInt32(observer.faces.count), initial ? 1 : 0,
            observer.skipStillTiles && configuration.gravity == nil ? 1 : 0, 0)
        encoder.setComputePipelineState(observer.pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(controlBuffer, offset: 0, index: 2)
        encoder.setBuffer(observer.faceBuffer, offset: 0, index: 3)
        encoder.setBuffer(observer.values, offset: 0, index: 4)
        encoder.setBuffer(observer.signed, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 6)
        encoder.setBytes(&parameters, length: 16, index: 7)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 8)
        // Where the air is refined, its finest cells against each face.
        bindRefinedAir(encoder, from: 9)
        encoder.dispatchThreads(
            MTLSize(width: observer.faces.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: observer.pipeline.threadExecutionWidth, height: 1, depth: 1)
        )
    }

    private func encodeEnvelopeComponents(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let recorder = envelopeComponentRecorder, !recorder.faces.isEmpty else { return }
        var uniforms = makeUniforms()
        var parameters = recorder.parameters(initial: initial)
        // Faces in still tiles read the still air; under gravity it is not uniform.
        parameters.skipStill = recorder.skipStillTiles && configuration.gravity == nil ? 1 : 0
        parameters.readsRefined = recorder.readsRefinedAir && refinement != nil ? 1 : 0
        let perGroup = EnvelopeComponentRecorder.componentsPerGroup
        let length = MemoryLayout<EnvelopeComponentRecorder.Parameters>.stride
        // Which components' air has woken; those still asleep finished there, the rest listed
        // (Solver.metal). With nothing awake this is the step's only work.
        encoder.setComputePipelineState(recorder.markPipeline)
        encoder.setBuffer(controlBuffer, offset: 0, index: 2)
        encoder.setBuffer(recorder.tileRanges, offset: 0, index: 3)
        encoder.setBuffer(recorder.tiles, offset: 0, index: 4)
        encoder.setBuffer(recorder.sideBuffer, offset: 0, index: 5)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 7)
        encoder.setBuffer(recorder.awake, offset: 0, index: 8)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 9)
        encoder.setBytes(&parameters, length: length, index: 10)
        encoder.setBuffer(recorder.faceDispatch, offset: 0, index: 11)
        encoder.setBuffer(recorder.faceList, offset: 0, index: 12)
        encoder.setBuffer(recorder.sumDispatch, offset: 0, index: 13)
        encoder.setBuffer(recorder.sumList, offset: 0, index: 14)
        encoder.setBuffer(recorder.stillPressure, offset: 0, index: 15)
        encoder.setBuffer(recorder.peaks, offset: 0, index: 16)
        encoder.setBuffer(recorder.bins, offset: 0, index: 17)
        // Not written without maxima.
        encoder.setBuffer(recorder.maxima ?? recorder.bins, offset: 0, index: 18)
        encoder.setBuffer(recorder.flags, offset: 0, index: 19)
        encoder.setBuffer(recorder.clock, offset: 0, index: 20)
        encoder.setBuffer(recorder.starts, offset: 0, index: 21)
        encoder.setBuffer(recorder.current, offset: 0, index: 22)
        encoder.dispatchThreadgroups(
            MTLSize(width: (recorder.entryCount + perGroup - 1) / perGroup, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32 * perGroup, height: 1, depth: 1))
        // The listed components' faces: a threadgroup each (and at the first sample one for the
        // still air's row).
        encoder.setComputePipelineState(recorder.facePipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(recorder.faceBuffer, offset: 0, index: 3)
        encoder.setBuffer(recorder.pressures, offset: 0, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
        encoder.setBytes(&parameters, length: length, index: 6)
        encoder.setBuffer(recorder.sideBuffer, offset: 0, index: 8)
        encoder.setBuffer(recorder.faceList, offset: 0, index: 9)
        encoder.setBuffer(recorder.stillPressure, offset: 0, index: 10)
        // The refined air, for faces in it (`readsRefinedAir`); the second level's as the gauges'.
        bindRefinedAir(encoder, from: 11)
        encoder.setBuffer(recorder.weightBuffer, offset: 0, index: 17)
        encoder.dispatchThreadgroups(
            indirectBuffer: recorder.faceDispatch, indirectBufferOffset: 0,
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        // And their sums, a SIMD group each.
        encoder.setComputePipelineState(recorder.pipeline)
        encoder.setBuffer(recorder.pressures, offset: 0, index: 0)
        encoder.setBuffer(recorder.awake, offset: 0, index: 1)
        encoder.setBuffer(recorder.sideBuffer, offset: 0, index: 3)
        encoder.setBuffer(recorder.sumList, offset: 0, index: 4)
        encoder.setBuffer(recorder.peaks, offset: 0, index: 5)
        encoder.setBuffer(recorder.bins, offset: 0, index: 6)
        encoder.setBuffer(recorder.maxima ?? recorder.bins, offset: 0, index: 7)
        encoder.setBuffer(recorder.flags, offset: 0, index: 8)
        encoder.setBuffer(recorder.current, offset: 0, index: 9)
        encoder.setBytes(&parameters, length: length, index: 10)
        encoder.setBuffer(recorder.stillPressure, offset: 0, index: 11)
        encoder.setBuffer(recorder.faceDispatch, offset: 0, index: 12)
        encoder.setBuffer(recorder.sumDispatch, offset: 0, index: 13)
        encoder.setBuffer(recorder.clock, offset: 0, index: 14)
        encoder.setBuffer(recorder.starts, offset: 0, index: 15)
        encoder.dispatchThreadgroups(
            indirectBuffer: recorder.sumDispatch, indirectBufferOffset: 0,
            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        // The clock moves on by the step, once every component has it.
        encoder.setComputePipelineState(recorder.clockPipeline)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    /// Steps the envelopes' panes on the step's loads, opens those that broke, and reads the rooms
    /// of buildings opened (EnvelopeVenting.swift).
    private func encodeEnvelopeVenting(_ encoder: MTLComputeCommandEncoder) {
        guard let venting = envelopeVenting, let recorder = envelopeComponentRecorder else { return }
        var uniforms = makeUniforms()
        if venting.paneCount > 0 {
            var count = UInt32(venting.paneCount)
            encoder.setComputePipelineState(venting.stepPipeline)
            encoder.setBuffer(recorder.current, offset: 0, index: 0)
            encoder.setBuffer(venting.paneBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.glassBuffer, offset: 0, index: 2)
            encoder.setBuffer(venting.stateBuffer, offset: 0, index: 3)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 4)
            encoder.setBuffer(venting.openedBuffer, offset: 0, index: 5)
            encoder.setBuffer(controlBuffer, offset: 0, index: 6)
            encoder.setBytes(&count, length: 4, index: 7)
            encoder.setBuffer(venting.ownerRooms, offset: 0, index: 8)
            encoder.setBuffer(venting.roomDispatch, offset: 0, index: 9)
            encoder.setBuffer(venting.roomList, offset: 0, index: 10)
            encoder.setBuffer(venting.tableBuffer, offset: 0, index: 11)
            encoder.setBuffer(venting.holeBuffer, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: venting.paneCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        if venting.wallCount > 0 {
            var counts = SIMD2<UInt32>(UInt32(venting.wallCount), UInt32(venting.paneCount))
            encoder.setComputePipelineState(venting.wallPipeline)
            encoder.setBuffer(recorder.current, offset: 0, index: 0)
            encoder.setBuffer(venting.wallBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.wallSystemBuffer, offset: 0, index: 2)
            encoder.setBuffer(venting.wallTableBuffer, offset: 0, index: 3)
            encoder.setBuffer(venting.wallStateBuffer, offset: 0, index: 4)
            encoder.setBuffer(venting.wallClockBuffer, offset: 0, index: 5)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 6)
            encoder.setBuffer(venting.openedBuffer, offset: 0, index: 7)
            encoder.setBuffer(controlBuffer, offset: 0, index: 8)
            encoder.setBytes(&counts, length: 8, index: 9)
            encoder.setBuffer(venting.ownerRooms, offset: 0, index: 10)
            encoder.setBuffer(venting.roomDispatch, offset: 0, index: 11)
            encoder.setBuffer(venting.roomList, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: venting.wallCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        if !venting.breaches.isEmpty {
            var count = UInt32(venting.breaches.count)
            encoder.setComputePipelineState(venting.breachPipeline)
            encoder.setBuffer(venting.breachBuffer, offset: 0, index: 0)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.openedBuffer, offset: 0, index: 2)
            encoder.setBuffer(controlBuffer, offset: 0, index: 3)
            encoder.setBytes(&count, length: 4, index: 4)
            encoder.setBuffer(venting.ownerRooms, offset: 0, index: 5)
            encoder.setBuffer(venting.roomDispatch, offset: 0, index: 6)
            encoder.setBuffer(venting.roomList, offset: 0, index: 7)
            encoder.dispatchThreads(
                MTLSize(width: venting.breaches.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        if venting.paneCellCount > 0 {
            var count = UInt32(venting.paneCellCount)
            encoder.setComputePipelineState(venting.openPipeline)
            encoder.setBuffer(venting.paneCellBuffer, offset: 0, index: 0)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 1)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 3)
            encoder.setBuffer(stateBuffers[0], offset: 0, index: 4)
            encoder.setBuffer(stateBuffers[1], offset: 0, index: 5)
            encoder.setBuffer(hasSpecies ? speciesBuffers[0] : noSpecies, offset: 0, index: 6)
            encoder.setBuffer(hasSpecies ? speciesBuffers[1] : noSpecies, offset: 0, index: 7)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 8)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 9)
            encoder.setBuffer(controlBuffer, offset: 0, index: 10)
            encoder.setBytes(&count, length: 4, index: 11)
            // Read only under gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? venting.statusBuffer, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: venting.paneCellCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            // And the refined levels' cells under them.
            if let refinement {
                refinement.encodeOpenPanes(
                    encoder,
                    uniforms: refinement.levelUniforms(
                        from: uniforms, threshold: configuration.refinementThreshold, grid: grid),
                    control: controlBuffer)
            }
            if let finerRefinement, let finer = finerUniforms(uniforms) {
                finerRefinement.encodeOpenPanes(encoder, uniforms: finer, control: controlBuffer)
            }
        }
        if !venting.rooms.isEmpty {
            encoder.setComputePipelineState(venting.roomPipeline)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
            encoder.setBuffer(venting.roomBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.roomCellBuffer, offset: 0, index: 2)
            encoder.setBuffer(venting.roomList, offset: 0, index: 3)
            encoder.setBuffer(venting.roomResults, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.setBuffer(controlBuffer, offset: 0, index: 6)
            encoder.setBuffer(gravityTable(scale: 1) ?? venting.roomResults, offset: 0, index: 7)
            encoder.dispatchThreadgroups(
                indirectBuffer: venting.roomDispatch, indirectBufferOffset: 0,
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
    }

    private func encodeExposure(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let plane = exposurePlane else { return }
        var uniforms = makeUniforms()
        var probe = SIMD4<Float>(Float(plane.layer), plane.threshold, Float(time), initial ? 1 : 0)
        var weight = plane.weight
        var sampling = SIMD4<Float>(Float(plane.nx), Float(plane.ny), plane.spacing, 0)
        encoder.setComputePipelineState(plane.pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(controlBuffer, offset: 0, index: 2)
        encoder.setBuffer(plane.buffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setBytes(&probe, length: 16, index: 5)
        encoder.setBytes(&weight, length: 4, index: 6)
        encoder.setBytes(&sampling, length: 16, index: 7)
        // Where the air is refined, the finest cell holding each point.
        bindRefinedAir(encoder, from: 8)
        encoder.dispatchThreads(
            MTLSize(width: plane.nx, height: plane.ny, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    /// Read-only view of the current conserved state. Solid cells hold stale values.
    public func withState<R>(_ body: (UnsafeBufferPointer<CellState>) throws -> R) rethrows -> R {
        precondition(!batchInFlight, "Cannot read state while a batch is in flight")
        let pointer = stateBuffers[current].contents().bindMemory(
            to: CellState.self, capacity: grid.cellCount)
        return try body(UnsafeBufferPointer(start: pointer, count: grid.cellCount))
    }

    public func primitive(_ i: Int, _ j: Int, _ k: Int) -> Primitive {
        withState { primitive(of: $0[grid.index(i, j, k)]) }
    }

    public func isSolid(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        maskBuffer.contents().load(fromByteOffset: grid.index(i, j, k), as: UInt8.self) != 0
    }

    /// Largest overpressure (Pa) seen so far in a cell.
    public func peakOverpressure(_ i: Int, _ j: Int, _ k: Int) -> Float {
        peakBuffer.contents().load(
            fromByteOffset: grid.index(i, j, k) * MemoryLayout<Float>.stride, as: Float.self)
    }

    /// Positive-phase impulse (Pa s) accumulated so far in a cell.
    public func impulse(_ i: Int, _ j: Int, _ k: Int) -> Float {
        impulseBuffer.contents().load(
            fromByteOffset: grid.index(i, j, k) * MemoryLayout<Float>.stride, as: Float.self)
    }

    /// The gas the refined levels hold, each cell counted at the finest level that holds it: the
    /// coarse cells the first level covers, and the mass, energy, momentum and fuel and oxygen.
    private func refinedGas() -> (
        covered: Set<Int>, mass: Double, energy: Double, momentum: SIMD3<Double>, species: SIMD2<Double>
    )? {
        guard let refinement else { return nil }
        guard let finerRefinement else { return refinement.gas(in: grid) }
        let deep = finerRefinement.gas(in: grid)
        let first = refinement.gas(in: grid, excluding: deep.covered)
        return (
            first.covered, first.mass + deep.mass, first.energy + deep.energy, first.momentum + deep.momentum,
            first.species + deep.species
        )
    }

    /// Total mass (kg) and energy (J) of the gas, summed over fluid cells; under the patches of
    /// refined air, over their fluid fine cells.
    public func totals() -> (mass: Double, energy: Double) {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinedGas()
        return withState { cells in
            var mass = 0.0
            var energy = 0.0
            for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
                let share = openShare(index)
                mass += Double(cells[index].density) * share
                energy += Double(cells[index].energy) * share
            }
            return (mass * volume + (fine?.mass ?? 0), energy * volume + (fine?.energy ?? 0))
        }
    }

    /// The share of cell `index` that holds air: its cut cell's (the terrain's or a structure's), or
    /// one.
    func fluidShare(_ index: Int) -> Double {
        if let structure = structureCut?.geometry, structure.index[index] >= 0,
            terrainCut?.geometry.alpha(
                index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
                ?? 1 >= 1
        {
            return Double(structure.records[Int(structure.index[index])].x)
        }
        guard let cut = terrainCut?.geometry else { return 1 }
        let i = index % grid.nx
        let j = (index / grid.nx) % grid.ny
        return Double(cut.alpha(i, j, index / (grid.nx * grid.ny)))
    }

    /// Total momentum of the gas in kg m/s, counted as `totals()` is.
    public func momentum() -> SIMD3<Double> {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        let fine = refinedGas()
        return withState { cells in
            var total = SIMD3<Double>.zero
            for index in 0..<grid.cellCount where mask[index] == 0 && fine?.covered.contains(index) != true {
                total +=
                    SIMD3(
                        Double(cells[index].momentumX), Double(cells[index].momentumY),
                        Double(cells[index].momentumZ)) * openShare(index)
            }
            return total * volume + (fine?.momentum ?? .zero)
        }
    }

    public var fluidCellCount: Int {
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var count = 0
        for index in 0..<grid.cellCount where mask[index] == 0 { count += 1 }
        return count
    }

    /// Damage and deflection of the deformable body, both parts of it if mixed.
    public func bodySummary() -> StructureSummary? {
        bodies.compactMap { $0.summary() }.reduce(nil) { total, summary in
            total.map { $0.combined(with: summary) } ?? summary
        }
    }

    /// Bytes of GPU memory held by the solver's fields.
    public var memoryFootprint: Int {
        let buffers = stateBuffers + speciesBuffers + [maskBuffer, peakBuffer, impulseBuffer]
        return buffers.reduce(0) { $0 + $1.length } + grid.cellCount * 8
            + (exposurePlane?.buffer.length ?? 0)
            + (envelopeExposure?.memoryFootprint ?? 0)
            + (envelopeComponentRecorder?.memoryFootprint ?? 0) + (envelopeVenting?.memoryFootprint ?? 0)
            + bodies.reduce(0) { $0 + $1.memoryFootprint }
            + refinementLevels.reduce(0) { $0 + $1.memoryFootprint }
            + (experimentalBoxDefinition?.length ?? 0) + (experimentalBoxMask?.length ?? 0)
            + (experimentalBoxImpulse?.length ?? 0) + (congestion?.memoryFootprint ?? 0)
            + (hasBody
                ? wallVelocityBuffer.length + (occupancyBuffer?.length ?? 0)
                    + (debrisExchangeBuffer?.length ?? 0) + (debrisAreaBuffer?.length ?? 0) : 0)
            + (combinedOccupancyBuffer?.length ?? 0) + (couplingTiles?.length ?? 0)
            + (interactionBuffer?.length ?? 0)
            + (bodyEnvelopeBuffer?.length ?? 0)
            + (experimentalBoxes.isEmpty ? 0 : wallVelocityBuffer.length)
    }

    /// Structural substeps encoded per fluid step. The fluid step never exceeds the CFL limit
    /// for (slightly cooled) ambient air, which bounds how many are needed.
    public var structureSubsteps: Int {
        guard let bodyStep else { return 0 }
        let bound = configuration.cfl * grid.cellSize / (0.8 * ambientSoundSpeed)
        return min(max(Int((bound / bodyStep).rounded(.up)), 1), 96)
    }

    // MARK: - Encoding helpers

    private func makeUniforms(cfl: Float? = nil) -> SolverUniforms {
        var uniforms = SolverUniforms(
            nx: UInt32(grid.nx), ny: UInt32(grid.ny), nz: UInt32(grid.nz),
            dx: grid.cellSize,
            gamma: configuration.gamma,
            cfl: cfl ?? configuration.cfl,
            ambientPressure: configuration.ambientPressure,
            densityFloor: configuration.densityFloor,
            pressureFloor: configuration.pressureFloor,
            limiterTheta: configuration.limiterTheta,
            riemannSolver: configuration.riemannSolver.rawValue,
            boundaryFlags: configuration.reflectiveFaces.rawValue
                | (configuration.openFaces == .farField && configuration.gravity == nil ? farFieldFlag : 0),
            gaugeCount: UInt32(gaugeCount))
        if tilesEnabled {
            uniforms.tileNx = UInt32(tileDims.x)
            uniforms.tileNy = UInt32(tileDims.y)
            uniforms.tileNz = UInt32(tileDims.z)
        }
        uniforms.stillRho = stillCell.density
        uniforms.stillMx = stillCell.momentumX
        uniforms.stillMy = stillCell.momentumY
        uniforms.stillMz = stillCell.momentumZ
        uniforms.stillEnergy = stillCell.energy
        uniforms.airModel = configuration.airModel.rawValue
        refinement?.configure(&uniforms, threshold: configuration.refinementThreshold)
        uniforms.refineMargin = UInt32(max(configuration.refinementMargin, 0))
        uniforms.gaugeWalls = configuration.gaugesReadWallPressure ? 1 : 0
        if let finerRefinement {
            uniforms.childTileNx = UInt32(finerRefinement.tileDims.x)
            uniforms.childTileNy = UInt32(finerRefinement.tileDims.y)
            uniforms.childTileNz = UInt32(finerRefinement.tileDims.z)
        }
        if refinement != nil, ownLevelSteps {
            uniforms.ownSteps = 1
            uniforms.refineLevel = 1
            uniforms.sweepAxes = UInt32(max(1, [grid.nx, grid.ny, grid.nz].filter { $0 > 1 }.count))
        }
        if hasFlame {
            uniforms.deflagration = 1
        } else if hasSpecies {
            uniforms.afterburnEnergy = configuration.afterburnEnergy
            uniforms.oxygenPerFuel = Self.oxygenPerFuel
            uniforms.stillOxygen = Self.oxygenInAir * stillCell.density
            uniforms.afterburnRate =
                1 / max(configuration.afterburnTime * cbrt(max(largestCharge, 1e-3)), 1e-9)
        }
        if let region = couplingRegion, configuration.movingWalls {
            uniforms.couplingMapCount = UInt32(tiledCoupling?.mapCount ?? 0)
            uniforms.regionX = UInt32(region.origin.x)
            uniforms.regionY = UInt32(region.origin.y)
            uniforms.regionZ = UInt32(region.origin.z)
            uniforms.regionNx = UInt32(region.dims.x)
            uniforms.regionNy = UInt32(region.dims.y)
            uniforms.regionNz = UInt32(region.dims.z)
        }
        if !experimentalBoxes.isEmpty {
            uniforms.experimentalBox = UInt32(experimentalBoxes.count)
            uniforms.regionX = 0
            uniforms.regionY = 0
            uniforms.regionZ = 0
            uniforms.regionNx = UInt32(grid.nx)
            uniforms.regionNy = UInt32(grid.ny)
            uniforms.regionNz = UInt32(grid.nz)
            uniforms.maxStep = experimentalBoxMaxStep
        }
        if let limit = configuration.afterburnLimit {
            uniforms.ignitionTemperature = limit.ignitionTemperature
            uniforms.limitFlameTemperature = limit.limitFlameTemperature
        }
        if let mixing = configuration.mixing {
            uniforms.mixingCoefficient = mixing.coefficient
            uniforms.mixingPrandtl = mixing.prandtl
            uniforms.mixingModel = mixing.model == .sigma ? 1 : 0
        }
        if let gravity = configuration.gravity {
            uniforms.gravity = gravity.acceleration
            uniforms.gravityLapse = gravity.lapseRate
            uniforms.gravityT0 = gravityGround.pressure / (gravityGround.density * AirGravity.gasConstant)
            uniforms.gravityP0 = gravityGround.pressure
        }
        return uniforms
    }

    /// The per-cell kernels for the configured gas model, compiled the first time it is used.
    private func cellKernels() throws -> CellKernels {
        let model = configuration.airModel
        let gravity = configuration.gravity != nil
        let mixing = configuration.mixing != nil
        let limit = configuration.afterburnLimit != nil
        let cut = terrainCut != nil
        let porous = congestionBuffer != nil
        let structureCutOn = structureCut != nil
        let key =
            16 * Int(model.rawValue) + (gravity ? 1 : 0) + (mixing ? 2 : 0) + (limit ? 4 : 0) + (cut ? 8 : 0)
            + (porous ? 1024 : 0) + (structureCutOn ? 2048 : 0)
        if let kernels = cellKernelsByModel[key] { return kernels }
        var constants = MTLFunctionConstantValues()
        var value = model.rawValue
        constants.setConstantValue(&value, type: .uint, index: ShaderLibrary.airModelConstant)
        if gravity { constants = ShaderLibrary.withGravity(constants) }
        if mixing { constants = ShaderLibrary.withMixing(constants) }
        if limit { constants = ShaderLibrary.withBurnLimit(constants) }
        if cut { constants = ShaderLibrary.withCutCells(constants) }
        if porous { constants = ShaderLibrary.withPorousAir(constants) }
        if structureCutOn { constants = ShaderLibrary.withStructureCut(constants) }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library, constants: constants)
        }
        let kernels = CellKernels(
            sweep: try pipeline("sweep"), sweepTiles: try pipeline("sweepTiles"),
            collectTiles: try pipeline("collectTiles"),
            redistributeCutDefects: try pipeline("redistributeCutDefects"),
            keepStructureCut: try pipeline("keepStructureCut"),
            takeStructureCut: try pipeline("takeStructureCut"))
        cellKernelsByModel[key] = kernels
        return kernels
    }

    /// Shares each structure cut cell's difference over the step out along its wall's normal, in
    /// `state` just swept (`keepStructureCut`, then `takeStructureCut`, in Solver.metal).
    private func encodeStructureCutRedistribution(
        _ encoder: MTLComputeCommandEncoder, cut: StructureCutBuffers, kernels: CellKernels,
        uniforms: SolverUniforms, state: MTLBuffer, species: MTLBuffer
    ) {
        var uniforms = uniforms
        var count = UInt32(cut.geometry.cells.count)
        guard count > 0 else { return }
        encoder.setComputePipelineState(kernels.keepStructureCut)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(species, offset: 0, index: 1)
        encoder.setBuffer(cut.cells, offset: 0, index: 2)
        encoder.setBuffer(cut.records, offset: 0, index: 3)
        encoder.setBuffer(cut.targets, offset: 0, index: 4)
        encoder.setBuffer(cut.defects, offset: 0, index: 5)
        encoder.setBuffer(cut.passed, offset: 0, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 7)
        encoder.setBuffer(controlBuffer, offset: 0, index: 8)
        encoder.setBuffer(peakBuffer, offset: 0, index: 9)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 10)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 11)
        encoder.setBytes(&count, length: 4, index: 12)
        encoder.dispatchThreads(
            MTLSize(width: Int(count), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(Int(count), 256), height: 1, depth: 1))
        var receivers = UInt32(cut.geometry.receivers.count)
        guard receivers > 0 else { return }
        encoder.setComputePipelineState(kernels.takeStructureCut)
        encoder.setBuffer(cut.receivers, offset: 0, index: 2)
        encoder.setBuffer(cut.shares, offset: 0, index: 3)
        encoder.setBuffer(cut.starts, offset: 0, index: 4)
        encoder.setBuffer(cut.contributors, offset: 0, index: 5)
        encoder.setBytes(&receivers, length: 4, index: 12)
        encoder.dispatchThreads(
            MTLSize(width: Int(receivers), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: min(Int(receivers), 256), height: 1, depth: 1))
    }

    /// Lays structures' outlines as cut cells (`configuration.structureCutCells`) from the bodies'
    /// models as built, and keeps their cells of air from the remask; none with refinement.
    private func setUpStructureCut() throws {
        guard configuration.structureCutCells, hasBody, configuration.refinement <= 1 else {
            structureCut = nil
            return
        }
        // Solid elements only: shells' outlines are their midsurfaces, which a cut cell's air share
        // does not describe.
        let solids = bodies.map(\.model).filter { model in
            model.elementKind == .solid && model.solidElementKind.allSatisfy { ($0 ?? .solid) == .solid }
        }
        // The scene's own solids (the terrain below its cut cells, rigid blocks) as they stand before
        // the structures are counted in.
        let scenery = rigidMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let terrainGeometry = terrainCut?.geometry
        let grid = grid
        let geometry = StructureCutGeometry(
            models: solids, grid: grid, scenery: { scenery[$0] != 0 },
            terrainCut: { index in
                guard let terrainGeometry else { return false }
                return terrainGeometry.alpha(
                    index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny)) < 1
            })
        // With no cell cut (a structure on the lattice), the air is as without cut cells, kernels
        // and all: specialised for them, fast math may round the same sums differently.
        guard !geometry.cells.isEmpty else {
            structureCut = nil
            return
        }
        func buffer<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, 16)
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed(label)
            }
            _ = values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
            buffer.label = label
            return buffer
        }
        let zeros = [SIMD4<Float>](repeating: .zero, count: 2 * max(geometry.cells.count, 1))
        structureCut = StructureCutBuffers(
            geometry: geometry, index: try buffer(geometry.index, "structure cut index"),
            cells: try buffer(geometry.cells, "structure cut cells"),
            records: try buffer(geometry.records, "structure cut records"),
            walls: try buffer(geometry.walls, "structure cut walls"),
            targets: try buffer(geometry.targets, "structure cut targets"),
            defects: try buffer(zeros, "structure cut differences"),
            passed: try buffer(zeros, "structure cut passed"),
            receivers: try buffer(geometry.receivers, "structure cut receivers"),
            shares: try buffer(geometry.receiverShares, "structure cut receivers' shares"),
            starts: try buffer(geometry.receiverStarts, "structure cut receivers' starts"),
            contributors: try buffer(geometry.contributors, "structure cut contributors"))
        for body in bodies { try body.solids?.readStructureCutCells() }
        // A cell the terrain's cut cells hold is theirs, and the remask's rules for it stand (a thin
        // one under a structure turns solid): only the structure's own are kept air.
        let terrain = terrainCut?.geometry
        try keepAir(
            geometry.cells.filter { cell in
                let index = Int(cell)
                return
                    (terrain?.alpha(index % grid.nx, (index / grid.nx) % grid.ny, index / (grid.nx * grid.ny))
                    ?? 1)
                    >= 1
            })
    }

    /// Shares each cut cell's difference over the step out up its column, in `state` just swept (see
    /// `redistributeCutDefects` in Solver.metal).
    private func encodeCutRedistribution(
        _ encoder: MTLComputeCommandEncoder, cut: TerrainCutBuffers, pipeline: MTLComputePipelineState,
        uniforms: SolverUniforms, state: MTLBuffer, species: MTLBuffer
    ) {
        var uniforms = uniforms
        var count = UInt32(cut.geometry.cutColumns.count)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(species, offset: 0, index: 1)
        encoder.setBuffer(cut.columns, offset: 0, index: 2)
        encoder.setBuffer(cut.records, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setBuffer(controlBuffer, offset: 0, index: 5)
        encoder.setBuffer(peakBuffer, offset: 0, index: 6)
        encoder.setBuffer(maxSpeedBuffer, offset: 0, index: 7)
        encoder.setBuffer(cut.defects, offset: 0, index: 8)
        encoder.setBuffer(cut.cutColumns, offset: 0, index: 9)
        encoder.setBytes(&count, length: 4, index: 10)
        encoder.setBuffer(gravityTable(scale: 1) ?? cut.columns, offset: 0, index: 11)
        encoder.setBuffer(maskBuffer, offset: 0, index: 12)
        // Not read without refinement.
        let refined = refinement?.coarseCut != nil ? refinement : nil
        encoder.setBuffer(refined?.patchOfTile ?? cut.columns, offset: 0, index: 13)
        encoder.setBuffer(refined?.fine[0] ?? cut.columns, offset: 0, index: 14)
        encoder.setBuffer(refined?.fineCutBuffer ?? cut.columns, offset: 0, index: 15)
        encoder.setBuffer(refined?.fineSpecies[0] ?? cut.columns, offset: 0, index: 16)
        encoder.setBuffer(refined?.fineMask ?? cut.columns, offset: 0, index: 17)
        encoder.setBuffer(refined?.gravityTable ?? cut.columns, offset: 0, index: 18)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 19)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 64)
        encoder.dispatchThreads(
            MTLSize(width: Int(count), height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }

    /// Threads per tile in the tiled sweep: a column through the tile for each, or several if the
    /// pipeline cannot hold a whole tile's worth.
    private static func tileThreads(for sweepTiles: MTLComputePipelineState) -> MTLSize {
        var depth = Self.tileSize
        while depth > 1
            && Self.tileSize * Self.tileSize * depth > sweepTiles.maxTotalThreadsPerThreadgroup
        {
            depth /= 2
        }
        return MTLSize(width: Self.tileSize, height: Self.tileSize, depth: depth)
    }

    private func dispatchGrid(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState) {
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }

    private func encodeVisualization(_ encoder: MTLComputeCommandEncoder) {
        var uniforms = makeUniforms()
        encoder.setComputePipelineState(visualizationPipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(maskBuffer, offset: 0, index: 1)
        encoder.setBuffer(peakBuffer, offset: 0, index: 2)
        encoder.setBuffer(impulseBuffer, offset: 0, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
        encoder.setTexture(visualizationTexture, index: 0)
        dispatchGrid(encoder, pipeline: visualizationPipeline)
    }
}

// Only the explicit ExperimentalRigidBox/Car/WorldSimulation drivers call this synchronous
// reference path. Several boxes may be in the air at once; each cell of a box belongs to the
// first box that holds it, and each face's load goes to the box beyond it.
extension BlastSolver {
    func installExperimentalBox(_ body: RigidBoxBody) throws { try installExperimentalBoxes([body]) }

    func installExperimentalBoxes(_ bodies: [RigidBoxBody]) throws {
        precondition(!bodies.isEmpty && bodies.count < 255, "1 to 254 boxes")
        func allocate(_ length: Int) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed("experimental rigid box")
            }
            memset(buffer.contents(), 0, length)
            return buffer
        }
        experimentalBoxDefinition = try allocate(
            bodies.count * ExperimentalBoxGeometry.vectorCount * MemoryLayout<SIMD4<Float>>.stride)
        experimentalBoxMask = try allocate(grid.cellCount)
        experimentalBoxImpulse = try allocate(grid.cellCount * 6 * MemoryLayout<Float>.stride)
        wallVelocityBuffer = try allocate(grid.cellCount * 3 * MemoryLayout<Float>.stride)
        experimentalBoxes = []
        try updateExperimentalBoxes(bodies.map { $0 }, initial: true)
    }

    func updateExperimentalBox(_ body: RigidBoxBody, initial: Bool = false) throws {
        try updateExperimentalBoxes([body], initial: initial)
    }

    /// The coarse cells from `low` to `high` (m), grown by `margin` cells and clipped to the grid.
    private func experimentalCellRange(_ low: SIMD3<Float>, _ high: SIMD3<Float>, margin: Int)
        -> (low: SIMD3<Int>, high: SIMD3<Int>)
    {
        let dims = SIMD3(grid.nx, grid.ny, grid.nz)
        return (
            simd_max(SIMD3<Int>((low / grid.cellSize).rounded(.down)) &- margin, .zero),
            simd_min(SIMD3<Int>((high / grid.cellSize).rounded(.up)) &+ margin, dims &- 1)
        )
    }

    /// The boxes remapped together, from each one's region of coarse cells (nil for a box out of
    /// the air before and after): those whose regions meet, and then any group whose span, the
    /// box around its members' regions, meets another's, since each group is remapped over its
    /// span and two would otherwise write the same cells (an L of boxes and one in its corner).
    /// No two groups' spans meet. Each group's members are in order, the groups by their first.
    static func experimentalRemapGroups(_ regions: [(low: SIMD3<Int>, high: SIMD3<Int>)?]) -> [[Int]] {
        let slots = regions.indices.filter { regions[$0] != nil }
        var groups: [[Int]] = []
        var group = Array(regions.indices)
        func overlap(_ a: (low: SIMD3<Int>, high: SIMD3<Int>), _ b: (low: SIMD3<Int>, high: SIMD3<Int>))
            -> Bool
        {
            all(a.low .<= b.high) && all(b.low .<= a.high)
        }
        for b in slots where group[b] == b {
            var members = [b]
            var next = 0
            while next < members.count {
                for c in slots where group[c] == c && c != b && overlap(regions[members[next]]!, regions[c]!)
                {
                    group[c] = b
                    members.append(c)
                }
                next += 1
            }
            groups.append(members.sorted())
        }
        func span(_ members: [Int]) -> (low: SIMD3<Int>, high: SIMD3<Int>) {
            members.compactMap { regions[$0] }.reduce(
                (SIMD3<Int>(repeating: .max), SIMD3<Int>(repeating: .min))
            ) { (simd_min($0.low, $1.low), simd_max($0.high, $1.high)) }
        }
        var merged = true
        while merged {
            merged = false
            search: for a in groups.indices {
                for b in groups.indices where b > a && overlap(span(groups[a]), span(groups[b])) {
                    groups[a] = (groups[a] + groups[b]).sorted()
                    groups.remove(at: b)
                    merged = true
                    break search
                }
            }
        }
        return groups.sorted { $0[0] < $1[0] }
    }

    /// Conservative local redistribution when whole cells change occupancy. This is a coarse
    /// reference remap, not a cut-cell method; local pressure artefacts must be checked on
    /// refinement. Every box moves at once, and nothing is changed if any of them fails. A box
    /// given as nil leaves the air for good: its cells open and it takes no more load.
    func updateExperimentalBoxes(_ bodies: [RigidBoxBody?], initial: Bool = false) throws {
        precondition(!batchInFlight)
        precondition(initial || bodies.count == experimentalBoxes.count, "the boxes installed")
        precondition(
            initial || zip(bodies, experimentalBoxes).allSatisfy { $0.0 == nil || $0.1 != nil },
            "none returns")
        let domain = SIMD3<Double>(Double(grid.size.x), Double(grid.size.y), Double(grid.size.z))
        let h = Double(grid.cellSize)
        for body in bodies.compactMap({ $0 }) {
            guard
                body.corners.allSatisfy({
                    $0.x >= h && $0.y >= h && $0.z >= -1e-8
                        && $0.x <= domain.x - h && $0.y <= domain.y - h && $0.z <= domain.z - h
                })
            else { throw ExperimentalRigidBoxSimulation.Failure.outsideDomain }
        }
        // The experimental box is resolved by one finer level only.
        guard finerRefinement == nil else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        let geometries = bodies.map(ExperimentalBoxGeometry.init)
        let previous = initial ? geometries : experimentalBoxes.map(ExperimentalBoxGeometry.init)
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let scenery = rigidMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        // The coarse cells each box holds now, the first box taking a cell two share.
        var owner: [Int: Int] = [:]
        var held = [[Int]](repeating: [], count: bodies.count)
        for (b, body) in bodies.enumerated() {
            guard let body else { continue }
            let range = experimentalCellRange(geometries[b].low, geometries[b].high, margin: 1)
            for k in range.low.z...range.high.z {
                for j in range.low.y...range.high.y {
                    for i in range.low.x...range.high.x {
                        let n = grid.index(i, j, k)
                        let point = h * (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5)
                        let local = body.orientation.inverse.act(point - body.position) + body.centreOfMass
                        guard all(abs(local) .<= body.size / 2), owner[n] == nil else { continue }
                        guard scenery[n] == 0 else {
                            throw ExperimentalRigidBoxSimulation.Failure.sceneryCollision
                        }
                        owner[n] = b
                        held[b].append(n)
                    }
                }
            }
            guard !held[b].isEmpty || configuration.refinement > 1 else {
                throw ExperimentalRigidBoxSimulation.Failure.unresolvedBox
            }
        }
        // Each box's cells before and after, grown by a cell for the donors beside them; none for
        // a box out of the air before and after.
        let regions = bodies.indices.map { b -> (low: SIMD3<Int>, high: SIMD3<Int>)? in
            guard !geometries[b].isAbsent || !previous[b].isAbsent else { return nil }
            return experimentalCellRange(
                simd_min(geometries[b].low, previous[b].low), simd_max(geometries[b].high, previous[b].high),
                margin: 1)
        }
        func eachCell(_ body: (Int) -> Void) {
            for range in regions.compactMap({ $0 }) {
                for k in range.low.z...range.high.z {
                    for j in range.low.y...range.high.y {
                        for i in range.low.x...range.high.x { body(grid.index(i, j, k)) }
                    }
                }
            }
        }
        var commits: [(UnsafeMutableBufferPointer<CellState>) -> Void] = []
        if !initial, let refinement {
            // Boxes whose regions overlap share one remap; the rest are remapped apart.
            var groups: [[Int]] = []
            let slots = bodies.indices.filter { regions[$0] != nil }
            if refinement.useLocalBoxRemap {
                groups = Self.experimentalRemapGroups(regions)
            } else if !slots.isEmpty {
                groups = [slots]
            }
            // Preparing writes nothing and the groups' regions are apart, so they are prepared
            // side by side (in turn when the remap's phases are being timed).
            typealias Commit = (UnsafeMutableBufferPointer<CellState>) -> Void
            var prepared = [Result<Commit, Error>?](repeating: nil, count: groups.count)
            let grid = grid
            func prepare(_ g: Int) -> Result<Commit, Error> {
                let members = groups[g]
                let low = members.map { simd_min(geometries[$0].low, previous[$0].low) }.reduce(
                    SIMD3<Float>(repeating: .infinity), simd_min)
                let high = members.map { simd_max(geometries[$0].high, previous[$0].high) }.reduce(
                    SIMD3<Float>(repeating: -.infinity), simd_max)
                return Result {
                    try refinement.prepareBoxRemap(
                        members.map { geometries[$0] }, low: low, high: high, grid: grid)
                }
            }
            if groups.count > 1 && !refinement.measureBoxRemap {
                prepared.withUnsafeMutableBufferPointer { results in
                    let slots = results
                    concurrently(iterations: groups.count) { slots[$0] = prepare($0) }
                }
            } else {
                for g in groups.indices { prepared[g] = prepare(g) }
            }
            commits = try prepared.map { try $0!.get() }
        }
        if !initial && refinement == nil {
            let old = Array(UnsafeBufferPointer(start: mask, count: grid.cellCount))
            var next = old
            var inRegion = [Bool](repeating: false, count: grid.cellCount)
            eachCell {
                next[$0] = scenery[$0]
                inRegion[$0] = true
            }
            for n in owner.keys { next[n] = 1 }
            func neighbours(_ n: Int) -> [Int] {
                let i = n % grid.nx
                let j = (n / grid.nx) % grid.ny
                let k = n / (grid.nx * grid.ny)
                return [
                    (i - 1, j, k), (i + 1, j, k), (i, j - 1, k), (i, j + 1, k), (i, j, k - 1), (i, j, k + 1),
                ]
                .filter {
                    $0.0 >= 0 && $0.0 < grid.nx && $0.1 >= 0 && $0.1 < grid.ny && $0.2 >= 0 && $0.2 < grid.nz
                }
                .map { grid.index($0.0, $0.1, $0.2) }
                .filter { experimentalBoxRemapMode == .redistribution || inRegion[$0] }
            }
            let cells = try ConservativeCellRemap.apply(
                withState { Array($0) }, oldSolid: old.map { $0 != 0 }, newSolid: next.map { $0 != 0 },
                mode: experimentalBoxRemapMode, neighbours: neighbours)
            editState { _ = $0.update(from: cells) }
        }
        for commit in commits { editState(commit) }
        let count = ExperimentalBoxGeometry.vectorCount
        let definition = experimentalBoxDefinition!.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: count * bodies.count)
        for (b, geometry) in geometries.enumerated() {
            (definition + count * b).update(from: geometry.vectors, count: count)
        }
        let ownMask = experimentalBoxMask!.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let walls = wallVelocityBuffer.contents().bindMemory(to: Float.self, capacity: 3 * grid.cellCount)
        eachCell { n in
            mask[n] = scenery[n]
            ownMask[n] = 0
            for a in 0..<3 { walls[3 * n + a] = 0 }
        }
        for (b, body) in bodies.enumerated() {
            guard let body else { continue }
            for n in held[b] {
                let i = n % grid.nx
                let j = (n / grid.nx) % grid.ny
                let k = n / (grid.nx * grid.ny)
                let point = h * (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5)
                let velocity = body.linearVelocity + simd_cross(body.angularVelocity, point - body.position)
                mask[n] = 1
                ownMask[n] = UInt8(b + 1)
                for a in 0..<3 { walls[3 * n + a] = Float(velocity[a]) }
            }
        }
        experimentalBoxes = bodies
        let speed =
            bodies.compactMap { $0 }.map {
                simd_length($0.linearVelocity) + simd_length($0.angularVelocity) * simd_length($0.size)
            }.max() ?? 0
        experimentalBoxMaxStep = Float(
            min(0.001, 0.2 * h / Double(max(configuration.refinement, 1)) / max(speed, 1)))
    }

    func clearExperimentalBoxImpulse() throws {
        try refinement?.clearBoxImpulse()
        // Coarse writes lie beside a box's cells and are zeroed as they are read; any left from
        // before are cleared here.
        let values = experimentalBoxImpulse!.contents().bindMemory(
            to: Float.self, capacity: 6 * grid.cellCount)
        for body in experimentalBoxes.compactMap({ $0 }) {
            let geometry = ExperimentalBoxGeometry(body)
            let range = experimentalCellRange(geometry.low, geometry.high, margin: 2)
            for k in range.low.z...range.high.z {
                for j in range.low.y...range.high.y {
                    let row = grid.index(range.low.x, j, k)
                    (values + 6 * row).update(repeating: 0, count: 6 * (range.high.x - range.low.x + 1))
                }
            }
        }
    }

    /// The pool slots of the first level's patches over the boxes' cells and the cells beside them.
    private func experimentalBoxPatches(_ refinement: AirRefinement) -> [Int] {
        let blocks = experimentalBoxes.compactMap { $0 }.map { body -> (low: SIMD3<Int>, high: SIMD3<Int>) in
            let geometry = ExperimentalBoxGeometry(body)
            let range = experimentalCellRange(geometry.low, geometry.high, margin: 2)
            return (range.low / AirRefinement.patchSize, range.high / AirRefinement.patchSize)
        }
        return refinement.patches(inBlocks: blocks)
    }

    /// The air's impulse and its moment about the centre of mass on all the boxes together.
    func experimentalBoxImpulses() -> (linear: SIMD3<Double>, angular: SIMD3<Double>) {
        experimentalBoxLoads().reduce((SIMD3<Double>.zero, SIMD3<Double>.zero)) {
            ($0.0 + $1.linear, $0.1 + $1.angular)
        }
    }

    /// The air's impulse on each box, and its moment about the box's centre of mass, since the
    /// last call: each face's impulse goes to the box on its far side. Zeroes what it reads.
    func experimentalBoxLoads() -> [(linear: SIMD3<Double>, angular: SIMD3<Double>)] {
        var loads = [(linear: SIMD3<Double>, angular: SIMD3<Double>)](
            repeating: (.zero, .zero), count: experimentalBoxes.count)
        func record(_ b: Int, face: SIMD3<Double>, axis: Int, impulse: Double) {
            var vector = SIMD3<Double>.zero
            vector[axis] = impulse
            loads[b].linear += vector
            loads[b].angular += simd_cross(face - experimentalBoxes[b]!.position, vector)
        }
        let h = Double(grid.cellSize)
        let values = experimentalBoxImpulse!.contents().bindMemory(
            to: Float.self, capacity: 6 * grid.cellCount)
        let ownMask = experimentalBoxMask!.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        // Writes lie in air beside a box's cells, so within a cell of its bounds.
        for body in experimentalBoxes.compactMap({ $0 }) {
            let geometry = ExperimentalBoxGeometry(body)
            let range = experimentalCellRange(geometry.low, geometry.high, margin: 2)
            for k in range.low.z...range.high.z {
                for j in range.low.y...range.high.y {
                    for i in range.low.x...range.high.x {
                        let n = grid.index(i, j, k)
                        for slot in 0..<6 where values[6 * n + slot] != 0 {
                            let axis = slot / 2
                            var across = SIMD3(i, j, k)
                            across[axis] += slot % 2 == 0 ? -1 : 1
                            var face = h * (SIMD3<Double>(Double(i), Double(j), Double(k)) + 0.5)
                            face[axis] += (slot % 2 == 0 ? -0.5 : 0.5) * h
                            let b = Int(ownMask[grid.index(across.x, across.y, across.z)]) - 1
                            if b >= 0 {
                                record(b, face: face, axis: axis, impulse: Double(values[6 * n + slot]))
                            }
                            values[6 * n + slot] = 0
                        }
                    }
                }
            }
        }
        if let refinement {
            let geometries = experimentalBoxes.map(ExperimentalBoxGeometry.init)
            let dx = grid.cellSize / Float(refinement.ratio)
            refinement.takeBoxFaceImpulses(
                in: experimentalBoxPatches(refinement),
                owner: { cell, axis, side in
                    var across = cell
                    across[axis] += side == 0 ? -1 : 1
                    let point = (SIMD3<Float>(across) + 0.5) * dx
                    return ExperimentalBoxGeometry.owner(of: point, among: geometries, cellSize: dx)
                        ?? geometries.indices.min {
                            simd_distance(geometries[$0].centre, point)
                                < simd_distance(geometries[$1].centre, point)
                        }!
                },
                face: { b, cell, axis, side, impulse in
                    var face = Double(dx) * (SIMD3<Double>(cell) + 0.5)
                    face[axis] += (side == 0 ? -0.5 : 0.5) * Double(dx)
                    record(b, face: face, axis: axis, impulse: impulse)
                })
        }
        return loads
    }

    func checkExperimentalBoxRefinement() throws {
        guard let refinement, experimentalBoxes.contains(where: { $0 != nil }) else { return }
        let patches = refinement.patchOfTile.contents().bindMemory(
            to: Int32.self, capacity: refinement.patchOfTile.length / 4)
        let dims = refinement.tileDims
        for body in experimentalBoxes.compactMap({ $0 }) {
            let geometry = ExperimentalBoxGeometry(body)
            let range = experimentalCellRange(geometry.low, geometry.high, margin: 1)
            for k in range.low.z...range.high.z {
                for j in range.low.y...range.high.y {
                    for i in range.low.x...range.high.x {
                        let tile = SIMD3(i, j, k) / AirRefinement.patchSize
                        guard patches[tile.x + dims.x * (tile.y + dims.y * tile.z)] >= 0 else {
                            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
                        }
                    }
                }
            }
        }
        guard refinement.hasBoxCells(in: experimentalBoxPatches(refinement)) else {
            throw ExperimentalRigidBoxSimulation.Failure.unresolvedBox
        }
    }
}

/// How long the GPU has lately taken for a step, from the command buffers waited for, to size
/// the next so that it takes about `target` of the GPU's time.
struct GPUStepRate {
    /// The GPU time a buffer aims at, in seconds.
    var target = BlastSolver.commandBufferTarget
    /// Seconds a step, smoothed over the buffers; nil until the first.
    private(set) var seconds: Double?

    /// How many of `remaining` steps the next buffer takes: at least one, and four to begin
    /// with, to measure the rate.
    func part(_ remaining: Int) -> Int {
        guard let seconds, seconds > 0 else { return min(remaining, 4) }
        return min(max(Int(min(target / seconds, Double(Int.max / 2))), 1), remaining)
    }

    mutating func measure(_ commandBuffer: MTLCommandBuffer, steps: Int) {
        measure(gpuSeconds: commandBuffer.gpuEndTime - commandBuffer.gpuStartTime, steps: steps)
    }

    mutating func measure(gpuSeconds: Double, steps: Int) {
        guard gpuSeconds > 0, steps > 0 else { return }
        let rate = gpuSeconds / Double(steps)
        seconds = seconds.map { 0.7 * $0 + 0.3 * rate } ?? rate
    }
}
