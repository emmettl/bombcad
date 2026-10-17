import Foundation
import Metal
import simd

/// Envelope buildings whose glazing breaks in the air (stage 3c of envelope damage,
/// building-envelopes.md "Venting"): each pane's glass is the one-way model's single degree of
/// freedom (`EnvelopePanel.largeDeflectionGlass`), stepped on the GPU with the air from the pane's
/// own net pressure in the component recorder; when it breaks, the pane's cells leave the air's mask and
/// the blast flows into the building. Each building's interior, the air its walls, roof and closed
/// openings enclose, is followed as rooms (its connected parts), their mean overpressure's peak and
/// positive impulse recorded every step.
final class EnvelopeVenting {
    /// A pane's glass, for the GPU: `K_LM m` (kg/m²); the integration step it takes at most (s), a
    /// 200th of the shortest period its backbone reaches; its strength (Pa), held for the reference
    /// duration (s), and the fatigue exponent (0 to break at the strength itself); the deflection
    /// past which its edges let go (m); and its backbone's points in `table`.
    struct Glass {
        var mass: Float
        var substep: Float
        var strength: Float
        var reference: Float
        var exponent: Float
        var letsGo: Float
        var first: UInt32
        var count: UInt32
    }

    /// One pane: the component whose net pressure drives it, its owner's index and its glass.
    struct Pane {
        var component: UInt32
        var owner: UInt32
    }

    /// A wall, roof or slab's failure (`EnvelopeWallFailure`) for the GPU: `EnvelopeWallSystem` in
    /// Solver.metal, one a system, its backbone's points in `wallTableBuffer`.
    struct WallSystem {
        var mass: Float
        var loadMassElastic: Float
        var loadMassPlastic: Float
        var span: Float
        var reboundFactor: Float
        var damping: Float
        var substep: Float
        var stiffness: Float
        var yieldPast: Float
        var rotationPast: Float
        var lostPast: Float
        var sign: Float
        var first: UInt32
        var count: UInt32
        var pad0: UInt32 = 0
        var pad1: UInt32 = 0
    }

    /// A room: its owner's index, and its cells' range in `roomCells`.
    struct Room {
        var owner: UInt32
        var first: UInt32
        var count: UInt32
        var pad: UInt32 = 0
    }

    let components: [EnvelopeComponent]
    let paneComponents: [Int]
    let owners: [UUID]
    let rooms: [Room]
    let roomVolumes: [Double]
    /// The cells that open, the panes' then the walls' (`paneCellBuffer`).
    private(set) var paneCellCount: Int
    /// The walls, roofs and slabs that can fail, as indices into `components`: in `statusBuffer`
    /// after the panes.
    let wallComponents: [Int]
    /// Each: (component, owner, first system, systems | cantilever << 16).
    let wallBuffer: MTLBuffer
    let wallSystemBuffer: MTLBuffer
    /// (deflection m, resistance Pa, 0, 0) a point.
    let wallTableBuffer: MTLBuffer
    /// Each system: (deflection, velocity, permanent set, peak inward) and (rebound, yielded,
    /// resistance, failed).
    let wallStateBuffer: MTLBuffer
    /// Each wall: (its clock, when it failed or -1, the largest net pressure yet, the smallest).
    let wallClockBuffer: MTLBuffer
    let wallSystemCount: Int
    let wallPipeline: MTLComputePipelineState
    let glassBuffer: MTLBuffer
    /// Every pane's backbone, (deflection m, resistance Pa, largest principal stress Pa, 0) a point,
    /// deflection increasing, from (0, 0) at the start.
    let tableBuffer: MTLBuffer
    let paneBuffer: MTLBuffer
    /// Each pane: (deflection, velocity, Brown's integral so far, 0) and (its clock, s since the
    /// start, when it broke, s or -1, 0, 0).
    let stateBuffer: MTLBuffer
    /// Each pane, then each wall: 0 whole, 1 broken in the step just taken (its cells open), 2 open.
    private(set) var statusBuffer: MTLBuffer
    /// Each pane: when a fragment holes it, in ticks of the run's clock (`StepControl.tick`), low
    /// and high words; all ones for never (`setHoles`).
    let holeBuffer: MTLBuffer
    /// (cell, opener) for each cell a pane holds solid, then each a failing wall, roof or slab does,
    /// its opener its index in `statusBuffer` (a cell may be both a pane's and its wall's).
    private(set) var paneCellBuffer: MTLBuffer
    /// The same sorted by cell, for refined air to look a fine cell's coarse cell up in, with the
    /// grid it lies on (`PaneLookup`).
    private(set) var sortedPaneCellBuffer: MTLBuffer
    private(set) var paneLookup: PaneLookup
    /// The panes' and walls' cells, before any holes (`setBreaches`).
    private let standingCells: [SIMD2<UInt32>]
    /// Holes through walls, roofs and slabs (`setBreaches`), each an opener after the walls in
    /// `statusBuffer`: (opener, owner, when it opens in the run's ticks, low and high words).
    private(set) var breachBuffer: MTLBuffer
    private(set) var breaches: [(component: Int, owner: Int, cells: Int, ticks: UInt64, cause: String)] = []
    /// Each concrete component's close-in outcome by UFC 3-340-02's threshold curves, by id
    /// (`BlastSolver.setEnvelopeCloseIn`).
    var closeIn: [String: UFCSpallBreach.Outcome] = [:]
    let breachPipeline: MTLComputePipelineState
    private let device: MTLDevice
    /// Each owner: 1 once a pane of it has broken, when its rooms start to be read.
    let openedBuffer: MTLBuffer
    let roomBuffer: MTLBuffer
    let roomCellBuffer: MTLBuffer
    /// Each room: peak mean overpressure (Pa), positive impulse (Pa s), current mean (Pa).
    let roomResults: MTLBuffer
    /// Each owner's rooms, (first, count); the rooms of buildings opened so far; and their count, as
    /// the room kernel's indirect dispatch (threadgroups, 1, 1).
    let ownerRooms: MTLBuffer
    let roomList: MTLBuffer
    let roomDispatch: MTLBuffer
    let stepPipeline: MTLComputePipelineState
    let openPipeline: MTLComputePipelineState
    let roomPipeline: MTLComputePipelineState

    /// The cells of the grid inside each envelope's walls and roof, its openings and panes taken as
    /// closed, as rooms: cells not reached from outside the building's bounds through the air.
    static func interiors(grid: Grid, mask: UnsafeBufferPointer<UInt8>, envelopes: [BuildingEnvelope])
        -> [[[Int]]]
    {
        let (nx, ny, nz) = (grid.nx, grid.ny, grid.nz)
        let dx = grid.cellSize
        func index(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }
        return envelopes.map { envelope in
            guard !envelope.solids.isEmpty else { return [] }
            let low = envelope.solids.map(\.min).reduce(SIMD3<Float>(repeating: .infinity)) {
                simd_min($0, $1)
            }
            let high = envelope.solids.map(\.max).reduce(SIMD3<Float>(repeating: -.infinity)) {
                simd_max($0, $1)
            }
            // The bounds' cells and one more each way, within the grid.
            let lo = SIMD3<Int>(
                max(Int(floor(low.x / dx)) - 1, 0), max(Int(floor(low.y / dx)) - 1, 0),
                max(Int(floor(low.z / dx)) - 1, 0))
            let hi = SIMD3<Int>(
                min(Int(ceil(high.x / dx)) + 1, nx - 1), min(Int(ceil(high.y / dx)) + 1, ny - 1),
                min(Int(ceil(high.z / dx)) + 1, nz - 1))
            let size = hi &- lo &+ 1
            func local(_ p: SIMD3<Int>) -> Int {
                (p.x - lo.x) + size.x * ((p.y - lo.y) + size.y * (p.z - lo.z))
            }
            // Closed: solid in the air, or in an opening or a pane of this building.
            let closing = envelope.openings + envelope.panes
            var closed = [Bool](repeating: false, count: size.x * size.y * size.z)
            for k in lo.z...hi.z {
                for j in lo.y...hi.y {
                    for i in lo.x...hi.x {
                        let centre = grid.cellCentre(i, j, k)
                        let shut =
                            mask[index(i, j, k)] != 0
                            || closing.contains { box in
                                (0..<3).allSatisfy { centre[$0] >= box.min[$0] && centre[$0] <= box.max[$0] }
                            }
                        closed[local(SIMD3(i, j, k))] = shut
                    }
                }
            }
            // Flood the outside in from the region's faces (the domain's own faces count as
            // outside too, but the ground: a building stands on it).
            var outside = [Bool](repeating: false, count: closed.count)
            var stack: [SIMD3<Int>] = []
            for k in lo.z...hi.z {
                for j in lo.y...hi.y {
                    for i in lo.x...hi.x {
                        let onFace =
                            i == lo.x || i == hi.x || j == lo.y || j == hi.y || (k == hi.z)
                            || (k == lo.z && lo.z > 0)
                        let p = SIMD3(i, j, k)
                        if onFace && !closed[local(p)] && !outside[local(p)] {
                            outside[local(p)] = true
                            stack.append(p)
                        }
                    }
                }
            }
            let steps = [
                SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1),
                SIMD3(0, 0, -1),
            ]
            while let p = stack.popLast() {
                for step in steps {
                    let q = p &+ step
                    guard all(q .>= lo), all(q .<= hi), !closed[local(q)], !outside[local(q)] else {
                        continue
                    }
                    outside[local(q)] = true
                    stack.append(q)
                }
            }
            // What is left is inside: its connected parts are the rooms, in the order of their cells.
            var room = [Int](repeating: -1, count: closed.count)
            var rooms: [[Int]] = []
            for k in lo.z...hi.z {
                for j in lo.y...hi.y {
                    for i in lo.x...hi.x {
                        let start = SIMD3(i, j, k)
                        guard !closed[local(start)], !outside[local(start)], room[local(start)] < 0 else {
                            continue
                        }
                        var cells: [Int] = []
                        room[local(start)] = rooms.count
                        var queue = [start]
                        while let p = queue.popLast() {
                            cells.append(index(p.x, p.y, p.z))
                            for step in steps {
                                let q = p &+ step
                                guard all(q .>= lo), all(q .<= hi), !closed[local(q)], !outside[local(q)],
                                    room[local(q)] < 0
                                else { continue }
                                room[local(q)] = rooms.count
                                queue.append(q)
                            }
                        }
                        rooms.append(cells.sorted())
                    }
                }
            }
            return rooms
        }
    }

    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, mask: UnsafeBufferPointer<UInt8>,
        objects: [SceneObject], components: [EnvelopeComponent], rigidBoxes: [Box],
        constructions: (UUID) -> EnvelopeConstruction
    ) throws {
        self.components = components
        let envelopes = objects.compactMap(\.envelope)
        let ownerIDs = objects.map(\.id)
        owners = ownerIDs
        func ownerIndex(_ id: UUID) -> Int { ownerIDs.firstIndex(of: id) ?? 0 }
        // The panes and their glass, as the one-way model builds it.
        var panes: [Pane] = []
        var glass: [Glass] = []
        var table: [SIMD4<Float>] = []
        var paneIndices: [Int] = []
        for (n, component) in components.enumerated() where component.kind == .pane {
            let construction = constructions(component.owner)
            let spans = component.spans
            let a = min(Double(min(spans.x, spans.y)), EnvelopeDamageAssessment.largestSpan)
            let b = min(Double(max(spans.x, spans.y)), EnvelopeDamageAssessment.largestSpan)
            // As the one-way model judges it (`EnvelopeDamageAssessment.assess`).
            let system = EnvelopePanel.largeDeflectionGlass(
                thickness: Double(construction.glassThicknessM), material: .annealedGlass, a: a, b: b)
            let brittle = system.brittle!
            // A 200th of the shortest period the backbone reaches, as `SDOFSystem.response` takes.
            var steepest = system.stiffness
            for (p, q) in zip(system.backbone, system.backbone.dropFirst()) where q.y > p.y {
                steepest = max(steepest, (q.y - p.y) / (q.x - p.x))
            }
            let shortest = min(
                system.period, 2 * .pi * (system.loadMassElastic * system.massPerArea / steepest).squareRoot()
            )
            glass.append(
                Glass(
                    mass: Float(system.loadMassElastic * system.massPerArea), substep: Float(shortest / 200),
                    strength: Float(brittle.strength), reference: Float(brittle.referenceDuration),
                    exponent: Float(brittle.fatigueExponent ?? 0), letsGo: Float(system.backbone.last!.x),
                    first: UInt32(table.count), count: UInt32(system.backbone.count)))
            for point in system.backbone {
                table.append(SIMD4(Float(point.x), Float(point.y), Float(brittle.stress(at: point.x)), 0))
            }
            panes.append(Pane(component: UInt32(n), owner: UInt32(ownerIndex(component.owner))))
            paneIndices.append(n)
        }
        paneComponents = paneIndices
        // Each pane's cells, as the air holds them (`BuildingEnvelope.paneCells`).
        var paneCells: [SIMD2<UInt32>] = []
        for (p, n) in paneIndices.enumerated() {
            let owner = ownerIndex(components[n].owner)
            guard envelopes.indices.contains(owner),
                envelopes[owner].panes.indices.contains(components[n].source)
            else { continue }
            for cell in envelopes[owner].paneCells(components[n].source, grid: grid) where mask[cell] != 0 {
                paneCells.append(SIMD2(UInt32(cell), UInt32(p)))
            }
        }
        // The walls, roofs and slabs that can fail, as the one-way model judges them, and their cells.
        var walls: [SIMD4<UInt32>] = []
        var wallSystems: [WallSystem] = []
        var wallTable: [SIMD4<Float>] = []
        var wallIndices: [Int] = []
        let dx = grid.cellSize
        let counts = [grid.nx, grid.ny, grid.nz]
        func range(_ low: Float, _ high: Float, _ axis: Int) -> Range<Int> {
            // As the mask's rasteriser: a cell whose centre lies in [low, high).
            let lower = min(max(Int((low / dx - 0.5).rounded(.up)), 0), counts[axis])
            let upper = min(max(Int((high / dx - 0.5).rounded(.up)), lower), counts[axis])
            return lower..<upper
        }
        for (n, component) in components.enumerated() {
            let load = EnvelopeComponentLoad(
                id: component.id, owner: component.owner,
                kind: EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue) ?? .wall,
                region: component.region, axis: component.axis, binS: 1e-4, outerPa: [], innerPa: [],
                supportEdges: component.supportEdges)
            guard let failure = EnvelopeWallFailure.make(load, construction: constructions(component.owner))
            else { continue }
            let w = UInt32(paneIndices.count + wallIndices.count)
            let region = component.region.holdingCells(of: dx)
            let (ri, rj, rk) = (
                range(region.min.x, region.max.x, 0), range(region.min.y, region.max.y, 1),
                range(region.min.z, region.max.z, 2)
            )
            var held = 0
            for k in rk {
                for j in rj {
                    for i in ri where mask[grid.index(i, j, k)] != 0 {
                        paneCells.append(SIMD2(UInt32(grid.index(i, j, k)), w))
                        held += 1
                    }
                }
            }
            guard held > 0 else { continue }
            walls.append(
                SIMD4(
                    UInt32(n), UInt32(ownerIndex(component.owner)), UInt32(wallSystems.count),
                    UInt32(failure.systems.count) | (failure.cantilever ? 1 << 16 : 0)))
            for system in failure.systems {
                let sdof = system.sdof
                let damping =
                    2 * sdof.dampingRatio
                    * (sdof.loadMassElastic * sdof.massPerArea * sdof.stiffness).squareRoot()
                wallSystems.append(
                    WallSystem(
                        mass: Float(sdof.massPerArea), loadMassElastic: Float(sdof.loadMassElastic),
                        loadMassPlastic: Float(sdof.loadMassPlastic), span: Float(sdof.span ?? 0),
                        reboundFactor: Float(sdof.reboundFactor), damping: Float(damping),
                        substep: Float(sdof.period / 200), stiffness: Float(sdof.stiffness),
                        yieldPast: Float(min(system.yieldPast, 1e30)),
                        rotationPast: Float(min(system.rotationPast, 1e30)),
                        lostPast: Float(min(system.lostPast, 1e30)), sign: Float(system.sign),
                        first: UInt32(wallTable.count), count: UInt32(sdof.backbone.count)))
                wallTable += sdof.backbone.map { SIMD4(Float($0.x), Float($0.y), 0, 0) }
            }
            wallIndices.append(n)
        }
        wallComponents = wallIndices
        wallSystemCount = wallSystems.count
        paneCellCount = paneCells.count
        // The rooms of every building.
        var rooms: [Room] = []
        var roomCells: [UInt32] = []
        var volumes: [Double] = []
        let cellVolume = Double(grid.cellSize * grid.cellSize * grid.cellSize)
        for (owner, list) in Self.interiors(grid: grid, mask: mask, envelopes: envelopes).enumerated() {
            for cells in list {
                rooms.append(
                    Room(owner: UInt32(owner), first: UInt32(roomCells.count), count: UInt32(cells.count)))
                roomCells += cells.map { UInt32($0) }
                volumes.append(Double(cells.count) * cellVolume)
            }
        }
        self.rooms = rooms
        roomVolumes = volumes
        var ranges = [SIMD2<UInt32>](repeating: .zero, count: ownerIDs.count)
        for (n, room) in rooms.enumerated() {
            let owner = Int(room.owner)
            if ranges[owner].y == 0 { ranges[owner].x = UInt32(n) }
            ranges[owner].y += 1
        }

        func make<T>(_ values: [T], _ label: String, minimum: Int = 16) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, minimum)
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed(label)
            }
            values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            return buffer
        }
        glassBuffer = try make(glass, "envelope panes' glass")
        tableBuffer = try make(table, "envelope panes' backbones")
        paneBuffer = try make(panes, "envelope panes")
        stateBuffer = try make(
            (0..<panes.count).flatMap { _ in [SIMD4<Float>.zero, SIMD4<Float>(0, -1, 0, 0)] }, "pane states")
        statusBuffer = try make([UInt32](repeating: 0, count: panes.count + walls.count), "pane status")
        wallBuffer = try make(walls, "envelope walls")
        wallSystemBuffer = try make(wallSystems, "envelope walls' systems")
        wallTableBuffer = try make(wallTable, "envelope walls' backbones")
        wallStateBuffer = try make(
            [SIMD4<Float>](repeating: .zero, count: 2 * wallSystems.count), "envelope walls' states")
        wallClockBuffer = try make(
            [SIMD4<Float>](repeating: SIMD4(0, -1, -1e30, 1e30), count: walls.count), "envelope walls' clocks"
        )
        holeBuffer = try make(
            [SIMD2<UInt32>](repeating: SIMD2(repeating: .max), count: panes.count), "pane holes")
        paneCellBuffer = try make(paneCells, "pane cells")
        standingCells = paneCells
        breachBuffer = try make([SIMD4<UInt32>](), "envelope holes")
        breachPipeline = try ShaderLibrary.pipeline("openEnvelopeBreaches", in: library)
        self.device = device
        paneLookup = PaneLookup(
            count: UInt32(paneCells.count), nx: UInt32(grid.nx), ny: UInt32(grid.ny), nz: UInt32(grid.nz),
            coarseDx: grid.cellSize)
        // Led by its header (4 entries of (cell, pane)'s size).
        let header = withUnsafeBytes(of: paneLookup) { Array($0.bindMemory(to: SIMD2<UInt32>.self)) }
        sortedPaneCellBuffer = try make(header + paneCells.sorted { $0.x < $1.x }, "pane cells by cell")
        openedBuffer = try make([UInt32](repeating: 0, count: ownerIDs.count), "opened envelopes")
        roomBuffer = try make(rooms, "envelope rooms")
        roomCellBuffer = try make(roomCells, "envelope rooms' cells")
        roomResults = try make(
            [SIMD4<Float>](repeating: .zero, count: rooms.count), "envelope rooms' results")
        ownerRooms = try make(ranges, "envelopes' rooms")
        roomList = try make([UInt32](repeating: 0, count: rooms.count), "opened rooms")
        roomDispatch = try make([UInt32(0), 1, 1], "opened rooms' dispatch")
        stepPipeline = try ShaderLibrary.pipeline("stepEnvelopePanes", in: library)
        openPipeline = try ShaderLibrary.pipeline("openEnvelopePanes", in: library)
        roomPipeline = try ShaderLibrary.pipeline("sampleEnvelopeRooms", in: library)
        wallPipeline = try ShaderLibrary.pipeline("stepEnvelopeWalls", in: library)
    }

    var wallCount: Int { wallComponents.count }

    var paneCount: Int { paneComponents.count }

    var memoryFootprint: Int {
        [
            glassBuffer, tableBuffer, paneBuffer, stateBuffer, statusBuffer, holeBuffer, paneCellBuffer,
            sortedPaneCellBuffer, breachBuffer, openedBuffer, wallBuffer, wallSystemBuffer, wallTableBuffer,
            wallStateBuffer,
            wallClockBuffer,
            roomBuffer,
            roomCellBuffer,
            roomResults, ownerRooms, roomList, roomDispatch,
        ].reduce(0) { $0 + $1.length }
    }

    /// When fragments hole the panes, by component id, s from the start: each opens on the step the
    /// run's clock reaches it (rounded down to a tick), whatever its glass. Kept across restarts;
    /// panes not named are never holed.
    func setHoles(_ holes: [String: Double]) {
        let words = holeBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: max(paneCount, 1))
        for (p, n) in paneComponents.enumerated() {
            guard let time = holes[components[n].id] else {
                words[p] = SIMD2(repeating: .max)
                continue
            }
            let ticks = UInt64(max(time, 0) / StepControl.tick)
            words[p] = SIMD2(UInt32(truncatingIfNeeded: ticks), UInt32(truncatingIfNeeded: ticks >> 32))
        }
    }

    /// Holes through walls, roofs and slabs: each `cells` of a component of `owner` (index), opening
    /// at `time` s on the run's clock (rounded down to a tick). Replaces any set before; the
    /// cells' lists and the panes' status are rebuilt, so call it before the run, and give the
    /// refined levels the new lookup (`BlastSolver.setEnvelopeWallHoles`).
    func setBreaches(_ list: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)]) throws
    {
        let first = UInt32(paneCount + wallCount)
        var cells = standingCells
        var entries: [SIMD4<UInt32>] = []
        breaches = []
        for (b, breach) in list.enumerated() {
            let opener = first + UInt32(b)
            let ticks = UInt64(max(breach.time, 0) / StepControl.tick)
            cells += breach.cells.map { SIMD2(UInt32($0), opener) }
            entries.append(
                SIMD4(
                    opener, UInt32(breach.owner), UInt32(truncatingIfNeeded: ticks),
                    UInt32(truncatingIfNeeded: ticks >> 32)))
            breaches.append((breach.component, breach.owner, breach.cells.count, ticks, breach.cause))
        }
        func make<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
            guard
                let buffer = device.makeBuffer(
                    length: max(values.count * MemoryLayout<T>.stride, 16), options: .storageModeShared)
            else { throw BlastError.allocationFailed(label) }
            values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            return buffer
        }
        paneCellCount = cells.count
        paneCellBuffer = try make(cells, "pane cells")
        statusBuffer = try make([UInt32](repeating: 0, count: Int(first) + list.count), "pane status")
        paneLookup.count = UInt32(cells.count)
        let header = withUnsafeBytes(of: paneLookup) { Array($0.bindMemory(to: SIMD2<UInt32>.self)) }
        sortedPaneCellBuffer = try make(header + cells.sorted { $0.x < $1.x }, "pane cells by cell")
        breachBuffer = try make(entries, "envelope holes")
    }

    /// What has broken and what each room has seen.
    func snapshot() -> EnvelopeVentingSnapshot {
        let state = stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(2 * paneCount, 1))
        let results = roomResults.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(rooms.count, 1))
        let panes = paneComponents.enumerated().map { p, n in
            EnvelopeVentingSnapshot.Pane(
                component: components[n].id, owner: components[n].owner,
                brokenAtS: state[2 * p + 1].y >= 0 ? Double(state[2 * p + 1].y) : nil,
                deflectionM: Double(state[2 * p].x))
        }
        let clocks = wallClockBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(wallCount, 1))
        let walls = wallComponents.enumerated().map { w, n in
            EnvelopeVentingSnapshot.Wall(
                component: components[n].id, owner: components[n].owner,
                failedAtS: clocks[w].y >= 0 ? Double(clocks[w].y) : nil)
        }
        let roomList = rooms.enumerated().map { r, room in
            EnvelopeVentingSnapshot.Room(
                owner: owners[Int(room.owner)], volumeM3: roomVolumes[r], peakPa: Double(results[r].x),
                impulsePaS: Double(results[r].y))
        }
        let status = statusBuffer.contents().bindMemory(
            to: UInt32.self, capacity: max(paneCount + wallCount + breaches.count, 1))
        let holes = breaches.enumerated().map { b, breach in
            EnvelopeVentingSnapshot.Hole(
                component: components[breach.component].id, owner: owners[breach.owner], cells: breach.cells,
                openedAtS: status[paneCount + wallCount + b] != 0
                    ? Double(breach.ticks) * StepControl.tick : nil,
                cause: breach.cause)
        }
        return EnvelopeVentingSnapshot(
            panes: panes, rooms: roomList, walls: walls, holes: holes, closeIn: closeIn.mapValues(\.rawValue))
    }
}

/// Envelope venting's results so far (`BlastSolver.envelopeVentingSnapshot()`).
public struct EnvelopeVentingSnapshot: Codable, Sendable {
    public struct Pane: Codable, Sendable {
        public var component: String
        public var owner: UUID
        /// When its glass broke and its cells opened, s; nil while whole.
        public var brokenAtS: Double?
        /// Its deflection now (at breaking, once broken), m, positive inward.
        public var deflectionM: Double
    }

    public struct Room: Codable, Sendable {
        public var owner: UUID
        public var volumeM3: Double
        /// The room's mean overpressure: its peak (Pa) and positive impulse (Pa s).
        public var peakPa: Double
        public var impulsePaS: Double
    }

    /// A wall, roof or slab that can fail, and when it did and its cells opened (nil while it stands).
    public struct Wall: Codable, Sendable {
        public var component: String
        public var owner: UUID
        public var failedAtS: Double?
    }

    public var panes: [Pane]
    public var rooms: [Room]
    public var walls: [Wall] = []
    /// A hole through a wall, roof or slab (a column of its cells), and when it opened; `cause`
    /// "fragments" (perforated) or "breach" (UFC 3-340-02's breach threshold).
    public struct Hole: Codable, Sendable {
        public var component: String
        public var owner: UUID
        public var cells: Int
        public var openedAtS: Double?
        public var cause: String
    }

    public var holes: [Hole] = []
    /// Each concrete component's worst close-in outcome by UFC 3-340-02's threshold curves
    /// ("spalled", "breached"), by id; none listed where neither.
    public var closeIn: [String: String] = [:]

    /// Whether `history` is still the component's load though its faces changed: a pane's, or a
    /// failed wall's, whose faces open with it (its history up to then is its load); or a holed
    /// one's, whose faces round the hole read the air going through.
    public func keeps(_ history: EnvelopeComponentHistory) -> Bool {
        history.component.kind == .pane
            || walls.contains { $0.component == history.component.id && $0.failedAtS != nil }
            || holes.contains { $0.component == history.component.id && $0.openedAtS != nil }
    }

    /// Each building's inside: the worst of its rooms by peak, or nil without rooms.
    public func inside(of owner: UUID) -> Room? {
        rooms.filter { $0.owner == owner }.max { $0.peakPa < $1.peakPa }
    }
}

extension EnvelopeVenting {
    /// Back to every pane whole and every room unread: their cells closed again in the masks.
    func reset(mask: MTLBuffer, rigidMask: MTLBuffer) {
        let state = stateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(2 * paneCount, 1))
        for n in 0..<paneCount {
            state[2 * n] = .zero
            state[2 * n + 1] = SIMD4(0, -1, 0, 0)
        }
        memset(statusBuffer.contents(), 0, statusBuffer.length)
        memset(wallStateBuffer.contents(), 0, wallStateBuffer.length)
        let clocks = wallClockBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(wallCount, 1))
        for w in 0..<wallCount { clocks[w] = SIMD4(0, -1, -1e30, 1e30) }
        memset(openedBuffer.contents(), 0, openedBuffer.length)
        memset(roomResults.contents(), 0, roomResults.length)
        roomDispatch.contents().storeBytes(of: 0, as: UInt32.self)
        let cells = paneCellBuffer.contents().bindMemory(
            to: SIMD2<UInt32>.self, capacity: max(paneCellCount, 1))
        let solid = mask.contents().bindMemory(to: UInt8.self, capacity: mask.length)
        let rigid = rigidMask.contents().bindMemory(to: UInt8.self, capacity: rigidMask.length)
        for n in 0..<paneCellCount {
            solid[Int(cells[n].x)] = 1
            rigid[Int(cells[n].x)] = 1
        }
    }
}
