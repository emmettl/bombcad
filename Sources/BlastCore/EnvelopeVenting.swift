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
    let paneCellCount: Int
    let glassBuffer: MTLBuffer
    /// Every pane's backbone, (deflection m, resistance Pa, largest principal stress Pa, 0) a point,
    /// deflection increasing, from (0, 0) at the start.
    let tableBuffer: MTLBuffer
    let paneBuffer: MTLBuffer
    /// Each pane: (deflection, velocity, Brown's integral so far, 0) and (its clock, s since the
    /// start, when it broke, s or -1, 0, 0).
    let stateBuffer: MTLBuffer
    /// Each pane: 0 whole, 1 broken in the step just taken (its cells open), 2 open.
    let statusBuffer: MTLBuffer
    /// Each pane: when a fragment holes it, in ticks of the run's clock (`StepControl.tick`), low
    /// and high words; all ones for never (`setHoles`).
    let holeBuffer: MTLBuffer
    /// (cell, pane) for each cell only a pane holds solid.
    let paneCellBuffer: MTLBuffer
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
        statusBuffer = try make([UInt32](repeating: 0, count: panes.count), "pane status")
        holeBuffer = try make(
            [SIMD2<UInt32>](repeating: SIMD2(repeating: .max), count: panes.count), "pane holes")
        paneCellBuffer = try make(paneCells, "pane cells")
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
    }

    var paneCount: Int { paneComponents.count }

    var memoryFootprint: Int {
        [
            glassBuffer, tableBuffer, paneBuffer, stateBuffer, statusBuffer, holeBuffer, paneCellBuffer,
            openedBuffer,
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
        let roomList = rooms.enumerated().map { r, room in
            EnvelopeVentingSnapshot.Room(
                owner: owners[Int(room.owner)], volumeM3: roomVolumes[r], peakPa: Double(results[r].x),
                impulsePaS: Double(results[r].y))
        }
        return EnvelopeVentingSnapshot(panes: panes, rooms: roomList)
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

    public var panes: [Pane]
    public var rooms: [Room]

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
