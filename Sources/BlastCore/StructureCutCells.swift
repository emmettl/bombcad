import Foundation
import simd

/// Structures' outlines as cut cells (`SolverConfiguration.structureCutCells`): for every cell a
/// structure's elements, as built, cross, the share of its volume that is air (alpha) and of each low
/// face open to the air (the apertures), with the wall's normal, so that the air sees a wall where
/// it stands within a cell rather than at the nearest cell face. The air updates these cells as the
/// terrain's cut cells (`cutCellUpdate` in Solver.metal) and shares out each step's differences
/// along the wall's normal (`redistributeStructureCut`).
///
/// A record is kept for every cell within a cell of a solid that is part air and part solid, or
/// that has a face partly closed or closed against another cell of air, so that the cells either
/// side of every face read the same aperture; a cell without one has every face open but those
/// against solid cells, as without cut cells (so a structure on the lattice has no records, and the
/// air is as without them). A cell under `minimumShare` air is solid, and its faces closed. A face
/// closed between two cells of air is a wall to the sweep's stencil (`structureClosedBelow`).
struct StructureCutGeometry {
    /// Per record: its cell (x fastest), its air share and its low faces' apertures (x, y, z).
    var cells: [UInt32] = []
    var records: [SIMD4<Float>] = []
    /// Per record: the wall's unit normal, out of the air into the solid, and its area over a face's.
    var walls: [SIMD4<Float>] = []
    /// Per record: the cell that takes the rest of its difference (at least half air, the first
    /// along the wall's normal into the air, or else a neighbour through an open face), or -1 to keep
    /// it all (only a cell at least `receivingShare` air, which then grows it by at most 2).
    var targets: [Int32] = []
    /// The cells that take others' differences, the share of air each holds, and the records whose
    /// differences each takes (`receiverStarts` into `contributors`, one more than receivers).
    var receivers: [UInt32] = []
    var receiverShares: [Float] = []
    var receiverStarts: [UInt32] = [0]
    var contributors: [UInt32] = []
    /// Per cell of the grid: its record, or -1.
    var index: [Int32] = []

    /// Cells with less air than this are solid.
    static let minimumShare: Float = 0.05
    /// A cell this full or more takes others' differences.
    static let receivingShare: Float = 0.5

    /// `scenery` says whether a cell (by grid index) is solid without the structures (the terrain
    /// below its cut cells, rigid blocks), `terrainCut` whether the terrain's cut cells hold it: a
    /// solid one is solid here, and a terrain cut cell is neither a record nor a cell that takes
    /// one's difference, as the terrain's own update and redistribution are its.
    init(
        models: [StructureModel], grid: Grid, scenery: (Int) -> Bool = { _ in false },
        terrainCut: (Int) -> Bool = { _ in false }
    ) {
        let dx = grid.cellSize
        let dims = SIMD3(grid.nx, grid.ny, grid.nz)
        index = Array(repeating: -1, count: grid.cellCount)
        guard !models.isEmpty else { return }
        // The air sees a body where it has elements: they fill the cells of a lattice of
        // `elementSize` whose centres lie inside it (see `StructureSolver`), so its faces lie on
        // that lattice, not where the model's solids do. The shares and apertures are the exact
        // overlaps of the cells and their faces with those elements.
        let lattices = models.map { ElementLattice(model: $0) }
        var low = SIMD3<Int>(repeating: .max)
        var high = SIMD3<Int>(repeating: .min)
        for lattice in lattices {
            low = simd_min(low, SIMD3<Int>((lattice.low / dx).rounded(.down)) &- 1)
            high = simd_max(high, SIMD3<Int>((lattice.high / dx).rounded(.down)) &+ 1)
        }
        low = simd_max(low, .zero)
        high = simd_min(high, dims &- 1)
        guard all(low .<= high) else { return }
        let span = high &- low &+ 1
        // Air shares over the band, and each cell's low faces' apertures, one cell more along
        // each axis so the band's high faces have theirs.
        func local(_ c: SIMD3<Int>) -> Int {
            (c.x - low.x) + (span.x + 1) * ((c.y - low.y) + (span.y + 1) * (c.z - low.z))
        }
        let count = (span.x + 1) * (span.y + 1) * (span.z + 1)
        var share = Array(repeating: Float(1), count: count)
        var apertures = Array(repeating: SIMD3<Float>(1, 1, 1), count: count)
        for k in low.z...min(high.z + 1, dims.z - 1) {
            for j in low.y...min(high.y + 1, dims.y - 1) {
                for i in low.x...min(high.x + 1, dims.x - 1) {
                    let cell = SIMD3(i, j, k)
                    let origin = SIMD3<Float>(cell) * dx
                    if all(cell .<= high) {
                        let solid = lattices.reduce(Float(0)) {
                            $0 + $1.solidVolume(from: origin, to: origin + dx)
                        }
                        share[local(cell)] = max(0, 1 - solid / (dx * dx * dx))
                    }
                    var open = SIMD3<Float>(repeating: 0)
                    for axis in 0..<3 {
                        let closed = lattices.reduce(Float(0)) {
                            $0 + $1.closedArea(axis: axis, at: origin, size: dx)
                        }
                        open[axis] = max(0, 1 - closed / (dx * dx))
                    }
                    apertures[local(cell)] = open
                }
            }
        }
        // Slivers are solid, and a face against a solid cell (or one out of the band, whole) closed.
        // So is a cell under `receivingShare` air with no cell to take the rest of its difference
        // (in a corner, or against another solid), which would otherwise keep it all and grow it
        // by 1 / alpha each step: making it solid can leave others without one, so this repeats.
        var solidified = Set<Int>()
        func shareOf(_ c: SIMD3<Int>) -> Float {
            guard all(c .>= 0), all(c .< dims) else { return 0 }
            if scenery(grid.index(c.x, c.y, c.z)) { return 0 }
            guard all(c .>= low), all(c .<= high) else { return 1 }
            let s = share[local(c)]
            return s < Self.minimumShare || solidified.contains(local(c)) ? 0 : s
        }
        func aperture(_ c: SIMD3<Int>, _ axis: Int) -> Float {
            var below = c
            below[axis] -= 1
            if shareOf(c) == 0 || shareOf(below) == 0 { return 0 }
            guard all(c .>= low), all(c .<= high &+ 1) else { return 1 }
            return apertures[local(c)][axis]
        }
        var keep: [(cell: SIMD3<Int>, record: SIMD4<Float>, wall: SIMD4<Float>)] = []
        var targetCells: [Int32] = []
        while true {
            keep = []
            for k in low.z...high.z {
                for j in low.y...high.y {
                    for i in low.x...high.x {
                        let c = SIMD3(i, j, k)
                        let alpha = shareOf(c)
                        guard alpha > 0, !terrainCut(grid.index(c.x, c.y, c.z)) else { continue }
                        let lowFaces = SIMD3((0..<3).map { aperture(c, $0) })
                        let highFaces = SIMD3(
                            (0..<3).map { axis -> Float in
                                var up = c
                                up[axis] += 1
                                return up[axis] < dims[axis] ? aperture(up, axis) : 1
                            })
                        // A face closed against a solid cell is a wall to the air without a record, as
                        // with no cut cells; one partly open, or closed against air, needs one.
                        func needs(_ face: Float, _ across: SIMD3<Int>) -> Bool {
                            face > 0 && face < 1 || face == 0 && shareOf(across) > 0
                        }
                        let needed = (0..<3).contains { axis in
                            var below = c
                            below[axis] -= 1
                            var above = c
                            above[axis] += 1
                            return needs(lowFaces[axis], below) || needs(highFaces[axis], above)
                        }
                        guard alpha < 1 || needed else { continue }
                        // The wall's area along each axis is the difference of the cell's apertures; it
                        // faces from the more open face to the less (out of the air into the solid).
                        let area = lowFaces - highFaces
                        let size = simd_length(area)
                        let normal = size > 1e-6 ? area / size : .zero
                        keep.append(
                            (c, SIMD4(alpha, lowFaces.x, lowFaces.y, lowFaces.z), SIMD4(normal, size)))
                    }
                }
            }
            // Each record's receiver: along the normal's largest component, into the air, the first of
            // two cells at least half air; failing that, the neighbour through an open face most
            // nearly into the air that is.
            targetCells = []
            var orphans: [SIMD3<Int>] = []
            for entry in keep {
                var target: Int32 = -1
                let normal = SIMD3(entry.wall.x, entry.wall.y, entry.wall.z)
                if entry.record.x < 1 {
                    if simd_length(normal) > 0 {
                        let axis =
                            abs(normal.x) >= max(abs(normal.y), abs(normal.z))
                            ? 0 : (abs(normal.y) >= abs(normal.z) ? 1 : 2)
                        var step = SIMD3<Int>(repeating: 0)
                        step[axis] = normal[axis] > 0 ? -1 : 1
                        var c = entry.cell
                        for _ in 0..<2 {
                            c &+= step
                            guard all(c .>= 0), all(c .< dims) else { break }
                            if shareOf(c) >= Self.receivingShare && !terrainCut(grid.index(c.x, c.y, c.z)) {
                                target = Int32(grid.index(c.x, c.y, c.z))
                                break
                            }
                            if shareOf(c) == 0 { break }
                        }
                    }
                    if target < 0 {
                        var best: (cell: SIMD3<Int>, along: Float)?
                        for axis in 0..<3 {
                            for side in [-1, 1] {
                                var c = entry.cell
                                c[axis] += side
                                guard all(c .>= 0), all(c .< dims), shareOf(c) >= Self.receivingShare,
                                    !terrainCut(grid.index(c.x, c.y, c.z))
                                else { continue }
                                let face = side < 0 ? entry.record[1 + axis] : aperture(c, axis)
                                guard face > 0 else { continue }
                                let along = -Float(side) * normal[axis]
                                if best == nil || along > best!.along { best = (c, along) }
                            }
                        }
                        if let best { target = Int32(grid.index(best.cell.x, best.cell.y, best.cell.z)) }
                    }
                    // Under half air with no wall across it (a solid thinner than a cell inside it,
                    // air either side): it cannot stand for both, and is solid, as without cut cells.
                    let walled = simd_length(normal) > 0
                    if (target < 0 || !walled) && entry.record.x < Self.receivingShare {
                        orphans.append(entry.cell)
                    }
                }
                targetCells.append(target)
            }
            guard !orphans.isEmpty else { break }
            for c in orphans { solidified.insert(local(c)) }
        }
        for (n, entry) in keep.enumerated() {
            index[grid.index(entry.cell.x, entry.cell.y, entry.cell.z)] = Int32(n)
            cells.append(UInt32(grid.index(entry.cell.x, entry.cell.y, entry.cell.z)))
            records.append(entry.record)
            walls.append(entry.wall)
        }
        var takes: [Int: [UInt32]] = [:]
        for (n, target) in targetCells.enumerated() {
            targets.append(target)
            if target >= 0 { takes[Int(target), default: []].append(UInt32(n)) }
        }
        for target in takes.keys.sorted() {
            receivers.append(UInt32(target))
            let r = index[target] >= 0 ? records[Int(index[target])].x : 1
            receiverShares.append(r)
            contributors += takes[target]!
            receiverStarts.append(UInt32(contributors.count))
        }
    }
}

/// A body's elements as the air sees them: which cells of its lattice of `elementSize` hold one.
private struct ElementLattice {
    let origin: SIMD3<Float>
    let h: Float
    let counts: SIMD3<Int>
    let present: [Bool]

    init(model: StructureModel) {
        // As `StructureSolver` lays its elements out.
        h = model.elementSize
        let bounds = model.bounds
        origin = (bounds.min / h + 1e-3).rounded(.down) * h
        let extent = ((bounds.max - origin) / h - 1e-3).rounded(.up)
        counts = simd_max(SIMD3<Int>(extent), SIMD3(repeating: 1))
        var present = Array(repeating: false, count: counts.x * counts.y * counts.z)
        for k in 0..<counts.z {
            for j in 0..<counts.y {
                for i in 0..<counts.x {
                    let centre = origin + (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * h
                    present[i + counts.x * (j + counts.y * k)] = model.occupies(centre)
                }
            }
        }
        self.present = present
    }

    var low: SIMD3<Float> { origin }
    var high: SIMD3<Float> { origin + SIMD3<Float>(counts) * h }

    func holds(_ e: SIMD3<Int>) -> Bool {
        all(e .>= 0) && all(e .< counts) && present[e.x + counts.x * (e.y + counts.y * e.z)]
    }

    /// The elements' lattice indices a span of space overlaps along one axis, and each's overlap.
    private func overlaps(_ a: Float, _ b: Float, axis: Int) -> [(index: Int, length: Float)] {
        let first = max(0, Int(((a - origin[axis]) / h).rounded(.down)))
        let last = min(counts[axis] - 1, Int(((b - origin[axis]) / h).rounded(.up)) - 1)
        guard first <= last else { return [] }
        return (first...last).compactMap { e in
            let lo = origin[axis] + Float(e) * h
            let length = min(b, lo + h) - max(a, lo)
            return length > 1e-7 * h ? (e, length) : nil
        }
    }

    /// The volume of elements within the box from `a` to `b`.
    func solidVolume(from a: SIMD3<Float>, to b: SIMD3<Float>) -> Float {
        let xs = overlaps(a.x, b.x, axis: 0)
        let ys = overlaps(a.y, b.y, axis: 1)
        let zs = overlaps(a.z, b.z, axis: 2)
        var volume: Float = 0
        for z in zs {
            for y in ys {
                for x in xs where holds(SIMD3(x.index, y.index, z.index)) {
                    volume += x.length * y.length * z.length
                }
            }
        }
        return volume
    }

    /// The area of the square face of side `size` at `corner`, normal to `axis`, that elements
    /// close: those it passes through, or, where it lies between two layers of them, those either
    /// side.
    func closedArea(axis: Int, at corner: SIMD3<Float>, size: Float) -> Float {
        let a = (axis + 1) % 3
        let b = (axis + 2) % 3
        let position = (corner[axis] - origin[axis]) / h
        let nearest = position.rounded()
        let layers: [Int] =
            abs(position - nearest) < 1e-3
            ? [Int(nearest) - 1, Int(nearest)] : [Int(position.rounded(.down))]
        var area: Float = 0
        for u in overlaps(corner[a], corner[a] + size, axis: a) {
            for v in overlaps(corner[b], corner[b] + size, axis: b) {
                let closed = layers.contains { layer in
                    var e = SIMD3<Int>(repeating: 0)
                    e[axis] = layer
                    e[a] = u.index
                    e[b] = v.index
                    return holds(e)
                }
                if closed { area += u.length * v.length }
            }
        }
        return area
    }
}
