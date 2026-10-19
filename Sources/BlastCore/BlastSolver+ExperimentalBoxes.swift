import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's freestanding objects in the air (experimental boxes): their cells, the air's
// conservative remap as they move, and the loads on them.

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
        if hasBody {
            // Objects beside a structure, in stage 1 on the coarse grid alone: the structure's
            // coupling is laid over the whole grid so that its wall velocities and the objects'
            // share one buffer, a cell's at 3 × its index.
            guard refinement == nil, finerRefinement == nil, stepCount == 0 else {
                throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
            }
            bodyCouplingWholeGrid = true
            try layOutBodyCoupling()
        }
        experimentalBoxMask = try allocate(grid.cellCount)
        experimentalBoxImpulse = try allocate(grid.cellCount * 6 * MemoryLayout<Float>.stride)
        if !hasBody { wallVelocityBuffer = try allocate(grid.cellCount * 3 * MemoryLayout<Float>.stride) }
        experimentalBoxes = []
        try updateExperimentalBoxes(bodies.map { $0 }, initial: true)
    }

    /// The velocity the air sees a moving solid cell at, with freestanding objects in the air (the
    /// whole grid's buffer); for the tests.
    func experimentalWallVelocity(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        let n = grid.index(i, j, k)
        let walls = wallVelocityBuffer.contents().bindMemory(to: Float.self, capacity: 3 * grid.cellCount)
        return SIMD3(walls[3 * n], walls[3 * n + 1], walls[3 * n + 2])
    }

    /// Which object holds each cell (its index plus one, or zero); for the tests.
    func experimentalBoxOwner(_ i: Int, _ j: Int, _ k: Int) -> Int {
        Int(experimentalBoxMask?.contents().load(fromByteOffset: grid.index(i, j, k), as: UInt8.self) ?? 0)
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
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let scenery = rigidMaskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        // The cells a structure holds, solid but neither scenery nor an object's: the remap keeps
        // them and their wall velocities (the structure's remask moves them).
        let structureHeld: (Int) -> Bool
        if hasBody, let boxes = experimentalBoxMask {
            let ownMask = boxes.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
            structureHeld = { mask[$0] != 0 && scenery[$0] == 0 && ownMask[$0] == 0 }
        } else {
            structureHeld = { _ in false }
        }
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
                next[$0] = structureHeld($0) ? 1 : scenery[$0]
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
        var kept = Set<Int>()
        eachCell { n in
            if structureHeld(n) { kept.insert(n) }
        }
        eachCell { n in
            ownMask[n] = 0
            guard !kept.contains(n) else { return }
            mask[n] = scenery[n]
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
