import simd

/// A shell mesh of a structure whose solids are all walls and slabs.
///
/// Each solid becomes a plate on its midsurface. The plates' nodes lie on one grid shared by the
/// whole structure, a set of breakpoints along each axis, so that plates that meet share the
/// nodes along the line where they meet and are joined rigidly. A plate that ends inside
/// another (a wall under a slab, two walls at a corner) is extended or shortened to end on the
/// other's midsurface.
struct ShellMesh {
    struct Element {
        /// Corners in order around the element: (0, 0), (1, 0), (1, 1), (0, 1) in its own axes.
        var nodes: SIMD4<UInt32>
        /// The axis through the thickness; the element's own axes are the next two, in order.
        var axis: Int
        var material: Int
        var thickness: Float
        /// Side lengths along the element's first and second axes.
        var size: SIMD2<Float>
        /// Bar layers: position through the thickness from -1 to 1, and bar area per unit width
        /// along the element's first and second axes.
        var bars: [SIMD3<Float>]
        /// The solid it was made from.
        var solid: Int
    }

    var positions: [SIMD3<Float>] = []
    var elements: [Element] = []
    /// Breakpoints along each axis.
    var grid: [[Float]] = [[], [], []]

    /// Most bar layers an element can carry.
    static let maxBars = 4

    private struct Plate {
        var solid: Int
        var axis: Int
        var box: Box
        var thickness: Float
        /// Midsurface coordinate along `axis`.
        var mid: Float
        /// In-plane extents, after being made to end on the plates they meet.
        var low: SIMD3<Float>
        var high: SIMD3<Float>
    }

    init(model: StructureModel) throws {
        let size = model.elementSize
        let tolerance: Float = 1e-4
        var plates: [Plate] = []
        for (index, box) in model.solids.enumerated() {
            let extent = box.size
            let axis = (0..<3).min { extent[$0] < extent[$1] } ?? 0
            let others = (0..<3).filter { $0 != axis }
            guard extent[axis] > 0, others.allSatisfy({ extent[axis] <= 0.5 * extent[$0] }) else {
                throw BlastError.notPlateLike(index)
            }
            let mid = 0.5 * (box.min[axis] + box.max[axis])
            var low = box.min
            var high = box.max
            low[axis] = mid
            high[axis] = mid
            plates.append(
                Plate(
                    solid: index, axis: axis, box: box, thickness: extent[axis], mid: mid, low: low,
                    high: high))
        }

        // A plate edge that lies within (or on the face of) another plate it touches ends on that
        // plate's midsurface instead.
        func touches(_ p: Plate, _ q: Plate, along k: Int) -> Bool {
            for j in 0..<3 where j != k {
                if p.box.max[j] < q.box.min[j] - tolerance || q.box.max[j] < p.box.min[j] - tolerance {
                    return false
                }
            }
            return true
        }
        for n in plates.indices {
            for k in 0..<3 where k != plates[n].axis {
                for q in plates
                where q.axis == k && q.solid != plates[n].solid && touches(plates[n], q, along: k) {
                    let within = (q.box.min[k] - tolerance)...(q.box.max[k] + tolerance)
                    if within.contains(plates[n].box.min[k]) { plates[n].low[k] = q.mid }
                    if within.contains(plates[n].box.max[k]) { plates[n].high[k] = q.mid }
                }
            }
        }

        // Breakpoints, most important first: midsurfaces, then plate edges, then the edges of
        // openings. A point closer than half an element to one already kept is dropped, so that
        // no element is much smaller than the rest.
        for k in 0..<3 {
            var kept: [Float] = []
            func offer(_ value: Float, spacing: Float) {
                if !kept.contains(where: { abs($0 - value) < spacing }) { kept.append(value) }
            }
            for plate in plates where plate.axis == k { offer(plate.mid, spacing: tolerance) }
            for plate in plates where plate.axis != k {
                offer(plate.low[k], spacing: 0.5 * size)
                offer(plate.high[k], spacing: 0.5 * size)
            }
            for opening in model.openings {
                let cuts = plates.contains { plate in
                    plate.axis != k
                        && (0..<3).allSatisfy { j in
                            opening.max[j] > plate.box.min[j] && opening.min[j] < plate.box.max[j]
                        }
                }
                if cuts {
                    offer(opening.min[k], spacing: 0.5 * size)
                    offer(opening.max[k], spacing: 0.5 * size)
                }
            }
            kept.sort()
            // Then each interval is split into equal parts no longer than an element.
            var points: [Float] = []
            for (a, b) in zip(kept, kept.dropFirst()) {
                let parts = max(1, Int(((b - a) / size - 1e-3).rounded(.up)))
                for part in 0..<parts { points.append(a + (b - a) * Float(part) / Float(parts)) }
            }
            if let last = kept.last { points.append(last) }
            grid[k] = points
        }
        // Plate edges that were dropped move to the nearest breakpoint kept.
        func nearest(_ value: Float, _ k: Int) -> Int {
            grid[k].indices.min { abs(grid[k][$0] - value) < abs(grid[k][$1] - value) } ?? 0
        }

        let materials = model.materials
        var nodeIndex: [SIMD3<Int32>: UInt32] = [:]
        func node(_ key: SIMD3<Int32>) -> UInt32 {
            if let index = nodeIndex[key] { return index }
            let index = UInt32(positions.count)
            nodeIndex[key] = index
            positions.append(SIMD3(grid[0][Int(key.x)], grid[1][Int(key.y)], grid[2][Int(key.z)]))
            return index
        }
        // Coplanar plates that overlap give one element, of the later plate's material.
        var claimed: [SIMD4<Int32>: Int] = [:]
        for plate in plates {
            let k = plate.axis
            let first = (k + 1) % 3
            let second = (k + 2) % 3
            let level = Int32(nearest(plate.mid, k))
            let range1 = nearest(plate.low[first], first)..<nearest(plate.high[first], first)
            let range2 = nearest(plate.low[second], second)..<nearest(plate.high[second], second)
            for u in range1 {
                for v in range2 {
                    let a = grid[first][u + 1] - grid[first][u]
                    let b = grid[second][v + 1] - grid[second][v]
                    var centre = SIMD3<Float>(repeating: 0)
                    centre[k] = plate.mid
                    centre[first] = 0.5 * (grid[first][u] + grid[first][u + 1])
                    centre[second] = 0.5 * (grid[second][v] + grid[second][v + 1])
                    if model.openings.contains(where: { $0.contains(centre) }) { continue }
                    var keys: [SIMD3<Int32>] = []
                    for (du, dv) in [(0, 0), (1, 0), (1, 1), (0, 1)] {
                        var key = SIMD3<Int32>(repeating: 0)
                        key[k] = level
                        key[first] = Int32(u + du)
                        key[second] = Int32(v + dv)
                        keys.append(key)
                    }
                    let corners = SIMD4(node(keys[0]), node(keys[1]), node(keys[2]), node(keys[3]))
                    let material = materials.firstIndex(of: model.material(of: plate.solid)) ?? 0
                    var bars: [SIMD3<Float>] = []
                    if materials[material].steel != nil {
                        bars = Self.bars(in: plate, at: centre, model: model)
                    }
                    let element = Element(
                        nodes: corners, axis: k, material: material, thickness: plate.thickness,
                        size: SIMD2(a, b), bars: bars, solid: plate.solid)
                    let key = SIMD4(Int32(k), level, Int32(u), Int32(v))
                    if let existing = claimed[key] {
                        elements[existing] = element
                    } else {
                        claimed[key] = elements.count
                        elements.append(element)
                    }
                }
            }
        }
    }

    /// The bar layers of the reinforcement regions that cross a plate at `centre`. A region is
    /// taken as a mat at its centre, of its own thickness; its ratios along the plate's axes
    /// give the bar area per unit width.
    private static func bars(in plate: Plate, at centre: SIMD3<Float>, model: StructureModel) -> [SIMD3<
        Float
    >] {
        let k = plate.axis
        let first = (k + 1) % 3
        let second = (k + 2) % 3
        var layers: [SIMD3<Float>] = []
        for layer in model.reinforcement {
            let region = layer.region
            guard
                region.min[first] <= centre[first], centre[first] <= region.max[first],
                region.min[second] <= centre[second], centre[second] <= region.max[second]
            else { continue }
            let depth = 0.5 * (region.min[k] + region.max[k])
            guard plate.box.min[k] <= depth, depth <= plate.box.max[k] else { continue }
            let band = region.max[k] - region.min[k]
            let zeta = max(-1, min(1, 2 * (depth - plate.mid) / plate.thickness))
            let areas = SIMD2(layer.ratio[first], layer.ratio[second]) * band
            guard areas.x + areas.y > 0 else { continue }
            if let same = layers.firstIndex(where: { abs($0.x - zeta) < 1e-3 }) {
                layers[same].y += areas.x
                layers[same].z += areas.y
            } else if layers.count < maxBars {
                layers.append(SIMD3(zeta, areas.x, areas.y))
            }
        }
        return layers
    }
}
