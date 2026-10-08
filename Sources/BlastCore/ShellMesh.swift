import simd

/// A mesh of shells and beams for a structure whose solids are all walls, slabs and columns.
///
/// Each wall or slab becomes a plate of shells on its midsurface, and each column a line of
/// beams on its centreline. Their nodes lie on one grid shared by the whole structure, a set of
/// breakpoints along each axis, so that members that meet share the nodes where they meet and
/// are joined rigidly. A member that ends inside another (a wall under a slab, two walls at a
/// corner, a column under a slab, a panel between columns) is extended or shortened to end on
/// the other's midsurface or centreline.
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
        /// The elements of the same plate beyond its edges at -first, +first, -second and +second,
        /// or -1 where there is none.
        var neighbours = SIMD4<Int32>(repeating: -1)
    }

    struct Beam {
        var nodes: SIMD2<UInt32>
        /// The axis along the beam; its section's sides are along the next two, in order.
        var axis: Int
        var material: Int
        /// Sides of the section along the next two axes.
        var section: SIMD2<Float>
        var length: Float
        /// Bars along the beam: position across the section (-1 to 1 along each side) and area.
        var bars: [SIMD3<Float>]
        /// Area of ties per unit area of concrete, for confinement.
        var tieRatio: Float
        var solid: Int
    }

    var positions: [SIMD3<Float>] = []
    var elements: [Element] = []
    var beams: [Beam] = []
    /// Nodes tied rigidly to another: the slab nodes within a column's footprint, tied to the
    /// column's node where it meets the slab, so that the column bears on the slab over its whole
    /// section instead of at one point.
    var ties: [(slave: UInt32, master: UInt32)] = []
    /// For each element beside a column head, the mean shear stress through its thickness at
    /// which the connection punches (see `punchingStrength`); zero for the rest.
    var punching: [Float] = []
    /// The ring of elements around each column head, which punches as one.
    var punchingRings: [[Int]] = []
    /// Elements of a slab within two effective depths of a column's face, where the shear is
    /// two-way and punching, not the one-way strength of a section, decides it.
    var punchingZone: [Bool] = []
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

    private struct Column {
        var solid: Int
        var axis: Int
        var box: Box
        /// Centreline: the middle of the section, along the other two axes.
        var centre: SIMD3<Float>
        /// Ends along `axis`, after being made to end on the plates they meet.
        var low: Float
        var high: Float
    }

    /// Cover from a column's face to the centre of its corner bars.
    static let columnCover: Float = 0.04
    /// Most bar groups a beam can carry.
    static let maxBeamBars = 8

    init(model: StructureModel) throws {
        let size = model.elementSize
        let tolerance: Float = 1e-4
        var plates: [Plate] = []
        var columns: [Column] = []
        for (index, box) in model.solids.enumerated() {
            let extent = box.size
            let axis = (0..<3).min { extent[$0] < extent[$1] } ?? 0
            let others = (0..<3).filter { $0 != axis }
            let long = (0..<3).max { extent[$0] < extent[$1] } ?? 2
            let across = (0..<3).filter { $0 != long }
            if extent[axis] > 0, !others.allSatisfy({ extent[axis] <= 0.5 * extent[$0] }) {
                // Not a wall or slab: a column if it is at least twice as long as it is wide.
                guard across.allSatisfy({ extent[$0] > 0 && 2 * extent[$0] <= extent[long] }) else {
                    throw BlastError.notPlateLike(index)
                }
                columns.append(
                    Column(
                        solid: index, axis: long, box: box, centre: 0.5 * (box.min + box.max),
                        low: box.min[long], high: box.max[long]))
                continue
            }
            guard extent[axis] > 0 else { throw BlastError.notPlateLike(index) }
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
        func boxesTouch(_ a: Box, _ b: Box, along k: Int) -> Bool {
            (0..<3).allSatisfy { j in
                j == k || (a.max[j] >= b.min[j] - tolerance && b.max[j] >= a.min[j] - tolerance)
            }
        }
        for n in plates.indices {
            for k in 0..<3 where k != plates[n].axis {
                for q in plates
                where q.axis == k && q.solid != plates[n].solid && touches(plates[n], q, along: k) {
                    let within = (q.box.min[k] - tolerance)...(q.box.max[k] + tolerance)
                    if within.contains(plates[n].box.min[k]) { plates[n].low[k] = q.mid }
                    if within.contains(plates[n].box.max[k]) { plates[n].high[k] = q.mid }
                }
                // A panel that ends against a column ends on its centreline.
                for column in columns
                where column.axis != k && boxesTouch(plates[n].box, column.box, along: k) {
                    let within = (column.box.min[k] - tolerance)...(column.box.max[k] + tolerance)
                    if within.contains(plates[n].box.min[k]) { plates[n].low[k] = column.centre[k] }
                    if within.contains(plates[n].box.max[k]) { plates[n].high[k] = column.centre[k] }
                }
            }
        }
        // A column that ends inside a slab ends on its midsurface.
        for n in columns.indices {
            let k = columns[n].axis
            for plate in plates where plate.axis == k && boxesTouch(columns[n].box, plate.box, along: k) {
                let within = (plate.box.min[k] - tolerance)...(plate.box.max[k] + tolerance)
                if within.contains(columns[n].box.min[k]) { columns[n].low = plate.mid }
                if within.contains(columns[n].box.max[k]) { columns[n].high = plate.mid }
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
            // A column's centreline within half an element of a midsurface moves onto it (cladding
            // flush with a column's face would otherwise leave a sliver of elements, and a time
            // step to match); parallel plates never merge.
            for column in columns where column.axis != k { offer(column.centre[k], spacing: 0.5 * size) }
            // Column faces, so that slabs have nodes around a column's footprint to tie to it.
            for column in columns where column.axis != k {
                offer(column.box.min[k], spacing: 0.5 * size + tolerance)
                offer(column.box.max[k], spacing: 0.5 * size + tolerance)
            }
            for column in columns where column.axis == k {
                offer(column.low, spacing: 0.5 * size + tolerance)
                offer(column.high, spacing: 0.5 * size + tolerance)
            }
            for plate in plates where plate.axis != k {
                offer(plate.low[k], spacing: 0.5 * size + tolerance)
                offer(plate.high[k], spacing: 0.5 * size + tolerance)
            }
            for opening in model.openings {
                let cuts = plates.contains { plate in
                    plate.axis != k
                        && (0..<3).allSatisfy { j in
                            opening.max[j] > plate.box.min[j] && opening.min[j] < plate.box.max[j]
                        }
                }
                if cuts {
                    offer(opening.min[k], spacing: 0.5 * size + tolerance)
                    offer(opening.max[k], spacing: 0.5 * size + tolerance)
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
        for column in columns {
            let k = column.axis
            let first = (k + 1) % 3
            let second = (k + 2) % 3
            let material = materials.firstIndex(of: model.material(of: column.solid)) ?? 0
            let section = SIMD2(column.box.size[first], column.box.size[second])
            // Bars from the reinforcement regions that cross the section: a region filling the
            // section (a column's smeared steel) becomes four corner bars at the cover; one
            // filling part of it (a mat near one face) becomes a bar at its middle. Ties come from
            // the ratios across the beam.
            var bars: [SIMD3<Float>] = []
            var ties: Float = 0
            if materials[material].steel != nil {
                let cover = min(Self.columnCover, 0.25 * section.min())
                let inset = SIMD2(1 - 2 * cover / section.x, 1 - 2 * cover / section.y)
                for layer in model.reinforcement {
                    let region = layer.region
                    guard region.min[k] <= column.centre[k], column.centre[k] <= region.max[k] else {
                        continue
                    }
                    let low = SIMD2(
                        max(region.min[first], column.box.min[first]),
                        max(region.min[second], column.box.min[second]))
                    let high = SIMD2(
                        min(region.max[first], column.box.max[first]),
                        min(region.max[second], column.box.max[second]))
                    let overlap = high - low
                    guard overlap.x > 0, overlap.y > 0, layer.ratio[k] > 0 else { continue }
                    ties = max(ties, max(layer.ratio[first], layer.ratio[second]))
                    let area = layer.ratio[k] * overlap.x * overlap.y
                    if overlap.x >= 0.99 * section.x && overlap.y >= 0.99 * section.y {
                        for corner in 0..<4 where bars.count < Self.maxBeamBars {
                            let sign = SIMD2<Float>(corner & 1 == 0 ? -1 : 1, corner & 2 == 0 ? -1 : 1)
                            bars.append(SIMD3(sign * inset, area / 4))
                        }
                    } else if bars.count < Self.maxBeamBars {
                        let middle = 0.5 * (low + high)
                        let centre = SIMD2(column.centre[first], column.centre[second])
                        let position = simd_clamp(2 * (middle - centre) / section, -inset, inset)
                        bars.append(SIMD3(position, area))
                    }
                }
            }
            var key = SIMD3<Int32>(repeating: 0)
            key[first] = Int32(nearest(column.centre[first], first))
            key[second] = Int32(nearest(column.centre[second], second))
            for w in nearest(column.low, k)..<nearest(column.high, k) {
                var lower = key
                var upper = key
                lower[k] = Int32(w)
                upper[k] = Int32(w + 1)
                beams.append(
                    Beam(
                        nodes: SIMD2(node(lower), node(upper)), axis: k, material: material, section: section,
                        length: grid[k][w + 1] - grid[k][w], bars: bars, tieRatio: ties, solid: column.solid))
            }
        }
        // Column heads: where a column meets a slab, the slab's nodes within the column's footprint
        // are tied to the column's node there.
        var tied = Set<UInt32>()
        var heads: [(master: UInt32, column: Column)] = []
        let masters = Set(beams.flatMap { [$0.nodes.x, $0.nodes.y] })
        for column in columns {
            let k = column.axis
            let first = (k + 1) % 3
            let second = (k + 2) % 3
            let half = 0.5 * SIMD2(column.box.size[first], column.box.size[second]) + tolerance
            let ends = Set(
                beams.filter { $0.solid == column.solid }.flatMap { [$0.nodes.x, $0.nodes.y] })
            for master in ends {
                let level = positions[Int(master)][k]
                guard
                    plates.contains(where: {
                        $0.axis == k && abs(grid[k][nearest($0.mid, k)] - level) < tolerance
                    })
                else { continue }
                heads.append((master, column))
                let centre = positions[Int(master)]
                for (n, position) in positions.enumerated() {
                    let node = UInt32(n)
                    guard node != master, !masters.contains(node), !tied.contains(node),
                        abs(position[k] - level) < tolerance,
                        abs(position[first] - centre[first]) <= half.x,
                        abs(position[second] - centre[second]) <= half.y
                    else { continue }
                    ties.append((node, master))
                    tied.insert(node)
                }
            }
        }
        let punchingHeads = heads.map { (master: $0.master, axis: $0.column.axis, box: $0.column.box) }
        let strengths = Self.punchingStrengths(
            elements: elements, heads: punchingHeads, ties: ties, materials: materials)
        punching = strengths.strengths
        punchingRings = strengths.rings
        punchingZone = [Bool](repeating: false, count: elements.count)
        for head in punchingHeads {
            let k = head.axis
            let level = positions[Int(head.master)][k]
            let centre = positions[Int(head.master)]
            for (index, element) in elements.enumerated() where element.axis == k {
                let middle = (0..<4).reduce(SIMD3<Float>.zero) { $0 + positions[Int(element.nodes[$1])] } / 4
                guard abs(middle[k] - level) < tolerance else { continue }
                let reach = 0.5 * head.box.size + SIMD3(repeating: 2 * 0.8 * element.thickness)
                let inside = (0..<3).allSatisfy { $0 == k || abs(middle[$0] - centre[$0]) <= reach[$0] }
                if inside { punchingZone[index] = true }
            }
        }
        for (key, index) in claimed {
            let offsets: [SIMD4<Int32>] = [
                SIMD4(0, 0, -1, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, -1), SIMD4(0, 0, 0, 1),
            ]
            for (side, offset) in offsets.enumerated() {
                elements[index].neighbours[side] = Int32(claimed[key &+ offset] ?? -1)
            }
        }
    }

    /// The punching strength of the slab elements around each column head, as the mean shear
    /// stress through their thickness at which the connection punches, and the ring of elements
    /// around each head.
    ///
    /// Eurocode 2 (EN 1992-1-1, 6.4.4) gives the punching strength of a slab without shear
    /// reinforcement as v = 0.18 k (100 rho f_c)^(1/3) MPa, at least 0.035 k^1.5 f_c^0.5, with
    /// k = 1 + sqrt(200 / d) (d in mm) no more than 2, on a control perimeter u1 two effective
    /// depths d from the column's face: u1 = 2 (c1 + c2) + 4 pi d. The ring of elements touching
    /// the column's footprint carries the same force through a perimeter u through their
    /// centres, 2 (c1 + c2) + 4 s for elements of side s, and the slab's whole thickness t, so
    /// they punch at a mean shear of v u1 d / (u t). The tension face is taken as the top (the
    /// face towards +axis), where a slab hogs over its column; d is to its outermost bars and rho
    /// the geometric mean of its bars each way, at most 2%. This is a characteristic strength,
    /// below the mean of tests.
    static func punchingStrengths(
        elements: [Element], heads: [(master: UInt32, axis: Int, box: Box)],
        ties: [(slave: UInt32, master: UInt32)], materials: [StructureMaterial]
    ) -> (strengths: [Float], rings: [[Int]]) {
        var strengths = [Float](repeating: 0, count: elements.count)
        var rings: [[Int]] = []
        var claimed = Set<Int>()
        for head in heads {
            var ring: [Int] = []
            var footprint = Set(ties.filter { $0.master == head.master }.map(\.slave))
            footprint.insert(head.master)
            let first = (head.axis + 1) % 3
            let second = (head.axis + 2) % 3
            let c1 = head.box.size[first]
            let c2 = head.box.size[second]
            for (index, element) in elements.enumerated() where element.axis == head.axis {
                let inside = (0..<4).filter { footprint.contains(element.nodes[$0]) }.count
                let material = materials[element.material]
                guard inside > 0, inside < 4, material.model == .concrete else { continue }
                let t = element.thickness
                let top = element.bars.filter { $0.x > 0 }
                let face = top.isEmpty ? element.bars.map { SIMD3(-$0.x, $0.y, $0.z) } : top
                let outermost = face.map(\.x).max() ?? 0.6
                let d = 0.5 * t * (1 + outermost)
                let areas = face.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.y, $1.z) }
                let ratio = min((areas.x * areas.y).squareRoot() / d, 0.02)
                let fc = material.compressiveStrength / 1e6
                let k = min(1 + (0.2 / d).squareRoot(), 2)
                let v =
                    max(0.18 * k * pow(100 * ratio * fc, 1 / 3), 0.035 * pow(k, 1.5) * fc.squareRoot()) * 1e6
                let s = 0.5 * (element.size.x + element.size.y)
                let u1 = 2 * (c1 + c2) + 4 * Float.pi * d
                let perimeter = 2 * (c1 + c2) + 4 * s
                let strength = v * u1 * d / (perimeter * t)
                // An element in two rings (columns closer than two elements) stays in the first.
                guard !claimed.contains(index) else { continue }
                claimed.insert(index)
                strengths[index] = strength
                ring.append(index)
            }
            if !ring.isEmpty { rings.append(ring) }
        }
        return (strengths, rings)
    }

    /// Each node's volume as loose debris: its share of the elements it belongs to.
    func debrisVolumes() -> [Float] {
        var volumes = [Float](repeating: 0, count: max(positions.count, 1))
        for element in elements {
            for corner in 0..<4 {
                volumes[Int(element.nodes[corner])] += element.size.x * element.size.y * element.thickness / 4
            }
        }
        for beam in beams {
            for end in 0..<2 {
                volumes[Int(beam.nodes[end])] += beam.section.x * beam.section.y * beam.length / 2
            }
        }
        return volumes
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

    /// Where each node on the ground carries its share of a connection to it (`Anchorage`): points
    /// of the footprint as (offset x, offset y from the node, area, 0). A wall's node carries
    /// `across` points through the wall's thickness, over half of each element edge it ends; a
    /// column's, `across` × `across` over its section. The points run from face to face with the
    /// trapezoid rule's weights, so that a base rocking on its toe bears at the face, as solid
    /// elements' corner nodes do. Nodes of neither carry none.
    func baseFibres(across: Int, selecting: (SIMD3<Float>) -> Bool = { abs($0.z) < 1e-4 }) -> [[SIMD4<Float>]]
    {
        var fibres = [[SIMD4<Float>]](repeating: [], count: positions.count)
        let intervals = Float(across - 1)
        func onGround(_ node: UInt32) -> Bool { selecting(positions[Int(node)]) }
        // Position from -1/2 to 1/2 and weight, summing to one, of point k.
        func point(_ k: Int) -> (offset: Float, weight: Float) {
            (Float(k) / intervals - 0.5, (k == 0 || k == across - 1 ? 0.5 : 1) / intervals)
        }
        for element in elements where element.axis != 2 {
            // A wall: its thickness is horizontal, along `axis`; its base edge runs along the
            // other horizontal axis, the element's first unless that is vertical.
            let edge = (element.axis + 1) % 3 == 2 ? element.size.y : element.size.x
            var normal = SIMD2<Float>.zero
            normal[element.axis] = 1
            let bottom = (0..<4).map { positions[Int(element.nodes[$0])].z }.min()!
            for corner in 0..<4
            where onGround(element.nodes[corner])
                && abs(positions[Int(element.nodes[corner])].z - bottom) < 1e-4
            {
                for k in 0..<across {
                    let (fraction, weight) = point(k)
                    let offset: SIMD2<Float> = fraction * element.thickness * normal
                    let area: Float = weight * element.thickness * edge / 2
                    fibres[Int(element.nodes[corner])].append(SIMD4(offset.x, offset.y, area, 0))
                }
            }
        }
        for beam in beams where beam.axis == 2 {
            let bottom = min(positions[Int(beam.nodes[0])].z, positions[Int(beam.nodes[1])].z)
            for end in 0..<2
            where onGround(beam.nodes[end]) && abs(positions[Int(beam.nodes[end])].z - bottom) < 1e-4 {
                for i in 0..<across {
                    for j in 0..<across {
                        let (u, wu) = point(i)
                        let (v, wv) = point(j)
                        let offset: SIMD2<Float> = SIMD2(u, v) * beam.section
                        let area: Float = wu * wv * beam.section.x * beam.section.y
                        fibres[Int(beam.nodes[end])].append(SIMD4(offset.x, offset.y, area, 0))
                    }
                }
            }
        }
        // Points that elements meeting at a node both give are one point, with both shares.
        return fibres.map { list in
            var merged: [SIMD4<Float>] = []
            for point in list {
                if let k = merged.firstIndex(where: {
                    simd_distance(SIMD2($0.x, $0.y), SIMD2(point.x, point.y)) < 1e-6
                }) {
                    merged[k].z += point.z
                } else {
                    merged.append(point)
                }
            }
            return merged
        }
    }
}
