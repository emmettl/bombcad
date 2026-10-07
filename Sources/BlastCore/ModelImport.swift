import Foundation
import simd

/// Geometry-only OBJ and STL reader. Imported surfaces must enclose a volume.
public struct ImportedMesh: Sendable {
    public struct Triangle: Sendable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var c: SIMD3<Float>
    }
    public var triangles: [Triangle]
    public var bounds: Box {
        let points = triangles.flatMap { [$0.a, $0.b, $0.c] }
        return Box(
            min: points.reduce(SIMD3<Float>(repeating: .infinity), simd_min),
            max: points.reduce(SIMD3<Float>(repeating: -.infinity), simd_max))
    }
    public enum ImportError: LocalizedError {
        case invalid(String)
        public var errorDescription: String? {
            switch self {
            case .invalid(let reason): reason
            }
        }
    }
    public init(data: Data, fileExtension: String) throws {
        guard data.count <= 20_000_000 else { throw ImportError.invalid("Model exceeds the 20 MB limit.") }
        var result: [Triangle] = []
        if fileExtension.lowercased() == "obj" {
            guard let source = String(data: data, encoding: .utf8) else {
                throw ImportError.invalid("OBJ must be UTF-8 text.")
            }
            var vertices: [SIMD3<Float>] = []
            for line in source.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                    .split(whereSeparator: \.isWhitespace)
                guard let first = fields.first else { continue }
                if first == "v" {
                    guard fields.count >= 4, let x = Float(fields[1]), let y = Float(fields[2]),
                        let z = Float(fields[3])
                    else { throw ImportError.invalid("Invalid OBJ vertex.") }
                    vertices.append(SIMD3(x, y, z))
                } else if first == "f" {
                    guard fields.count >= 4 else {
                        throw ImportError.invalid("OBJ face needs at least three vertices.")
                    }
                    let indices = try fields.dropFirst().map { field -> Int in
                        guard let token = field.split(separator: "/").first, let raw = Int(token), raw != 0
                        else { throw ImportError.invalid("Invalid OBJ face index.") }
                        let index = raw > 0 ? raw - 1 : vertices.count + raw
                        guard vertices.indices.contains(index) else {
                            throw ImportError.invalid("OBJ face references a missing vertex.")
                        }
                        return index
                    }
                    // Reject polygons for which fan triangulation would change the volume.
                    if indices.count > 3 {
                        let points = indices.map { vertices[$0] }
                        let normal = simd_cross(points[1] - points[0], points[2] - points[0])
                        let magnitude = simd_length(normal)
                        guard magnitude > 1e-10 else {
                            throw ImportError.invalid("Triangulate OBJ polygons before importing.")
                        }
                        let tolerance = max(1e-6, simd_length(points[1] - points[0]) * 1e-5)
                        guard
                            points.allSatisfy({
                                abs(simd_dot($0 - points[0], normal) / magnitude) < tolerance
                            }),
                            points.indices.allSatisfy({ n in
                                let a = points[n]
                                let b = points[(n + 1) % points.count]
                                let c = points[(n + 2) % points.count]
                                return simd_dot(simd_cross(b - a, c - b), normal) > 0
                            })
                        else {
                            throw ImportError.invalid(
                                "OBJ polygons must be planar and convex. Export triangulated faces.")
                        }
                    }
                    for n in 1..<(indices.count - 1) {
                        result.append(
                            Triangle(
                                a: vertices[indices[0]], b: vertices[indices[n]], c: vertices[indices[n + 1]])
                        )
                    }
                }
            }
        } else if fileExtension.lowercased() == "stl" {
            func uint(_ offset: Int) -> UInt32 {
                UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
                    | UInt32(data[offset + 3]) << 24
            }
            if data.count >= 84, 84 + UInt64(uint(80)) * 50 == UInt64(data.count) {
                func point(_ offset: Int) -> SIMD3<Float> {
                    SIMD3(
                        Float(bitPattern: uint(offset)), Float(bitPattern: uint(offset + 4)),
                        Float(bitPattern: uint(offset + 8)))
                }
                for n in 0..<Int(uint(80)) {
                    let offset = 84 + n * 50 + 12
                    result.append(Triangle(a: point(offset), b: point(offset + 12), c: point(offset + 24)))
                }
            } else {
                guard let source = String(data: data, encoding: .utf8) else {
                    throw ImportError.invalid("Invalid STL file.")
                }
                var points: [SIMD3<Float>] = []
                for line in source.split(whereSeparator: \.isNewline) {
                    let fields = line.split(whereSeparator: \.isWhitespace)
                    if fields.first == "vertex" {
                        guard fields.count == 4, let x = Float(fields[1]), let y = Float(fields[2]),
                            let z = Float(fields[3])
                        else { throw ImportError.invalid("Invalid STL vertex.") }
                        points.append(SIMD3(x, y, z))
                    }
                }
                guard points.count % 3 == 0 else { throw ImportError.invalid("Incomplete STL triangle.") }
                for n in stride(from: 0, to: points.count, by: 3) {
                    result.append(Triangle(a: points[n], b: points[n + 1], c: points[n + 2]))
                }
            }
        } else {
            throw ImportError.invalid("Choose an OBJ or STL file.")
        }
        guard !result.isEmpty, result.count <= 100_000 else {
            throw ImportError.invalid("Models must have between 1 and 100,000 triangles.")
        }
        for t in result {
            guard [t.a, t.b, t.c].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                simd_length_squared(simd_cross(t.b - t.a, t.c - t.a)) > 1e-20
            else { throw ImportError.invalid("Model contains non-finite or degenerate triangles.") }
        }
        triangles = result
        try validateClosed()
    }
    private func validateClosed() throws {
        struct Edge: Hashable {
            var a: SIMD3<Float>
            var b: SIMD3<Float>
        }
        func less(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool {
            for k in 0..<3 where a[k] != b[k] { return a[k] < b[k] }
            return false
        }
        var edges: [Edge: Int] = [:]
        for t in triangles {
            for (a, b) in [(t.a, t.b), (t.b, t.c), (t.c, t.a)] {
                edges[less(a, b) ? Edge(a: a, b: b) : Edge(a: b, b: a), default: 0] += 1
            }
        }
        guard edges.values.allSatisfy({ $0 == 2 }) else {
            throw ImportError.invalid(
                "The mesh has open or non-manifold edges. Export a watertight, triangulated solid; open surfaces cannot reliably block the blast."
            )
        }
    }
    public func transformed(scale: Float, yUp: Bool, corner: SIMD3<Float>) throws -> ImportedMesh {
        guard scale.isFinite, scale > 0, (0..<3).allSatisfy({ corner[$0].isFinite && corner[$0] >= 0 }) else {
            throw ImportError.invalid("Scale must be positive and placement must be finite and above ground.")
        }
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> { (yUp ? SIMD3(p.x, -p.z, p.y) : p) * scale }
        let low = triangles.flatMap { [rotate($0.a), rotate($0.b), rotate($0.c)] }.reduce(
            SIMD3<Float>(repeating: .infinity), simd_min)
        var mesh = self
        mesh.triangles = triangles.map {
            Triangle(
                a: rotate($0.a) - low + corner, b: rotate($0.b) - low + corner, c: rotate($0.c) - low + corner
            )
        }
        guard (0..<3).allSatisfy({ mesh.bounds.max[$0].isFinite }) else {
            throw ImportError.invalid("Scaled coordinates are too large.")
        }
        return mesh
    }

    public struct Preview: Sendable {
        public var boxes: [Box]
        public var occupiedCells: Int
        public var missedTriangles: Int
        public var thinSpans: Int
        public var smallGaps: Int
        public var uncertainTriangles: Int
        public var cellSize: Float
        public var bounds: Box
        public var warnings: [String] {
            var messages = [
                "Geometry is sampled at cell centres. Small openings and thin features can disappear; this preview is an approximation, not a mesh convergence check."
            ]
            if thinSpans > 0 {
                messages.append(
                    "\(thinSpans) sampled spans or cells indicate features thinner than two cells (\(2 * cellSize) m). Refine the grid to resolve these features."
                )
            }
            if smallGaps > 0 {
                messages.append(
                    "\(smallGaps) sampled gaps are narrower than two cells. Small openings may close or transmit the wrong blast load."
                )
            }
            if uncertainTriangles > 0 {
                messages.append(
                    "\(uncertainTriangles) triangle checks reached the diagnostic budget. Missing-feature detection is incomplete; inspect the preview and compare a finer import."
                )
            }
            if missedTriangles > 0 {
                messages.append(
                    "\(missedTriangles) triangles have no occupied cell found in their sampled bounding region. Parts of the model may be absent from the simulation."
                )
            }
            return messages
        }
    }
    /// Rasterise closed volumes with scanlines, then coalesce adjacent runs into boxes.
    public func preview(cellSize h: Float, domain: SIMD3<Float>) throws -> Preview {
        let bounds = self.bounds
        guard h.isFinite, h > 0, (0..<3).allSatisfy({ bounds.min[$0] >= 0 && bounds.max[$0] <= domain[$0] })
        else {
            throw ImportError.invalid(
                "Model lies outside the simulation domain. Reduce its scale or move its corner.")
        }
        guard (0..<3).allSatisfy({ bounds.max[$0] / h < 1_000_000 }) else {
            throw ImportError.invalid("Coordinates are too large for this grid.")
        }
        let low = SIMD3<Int>((bounds.min / h).rounded(.down))
        let high = SIMD3<Int>((bounds.max / h).rounded(.up))
        let size = high &- low
        guard size.x > 0, size.y > 0, size.z > 0,
            Double(size.x) * Double(size.y) * Double(size.z) <= 2_000_000,
            Double(size.y) * Double(size.z) * Double(triangles.count) <= 30_000_000
        else { throw ImportError.invalid("Preview is too large. Use a coarser grid or simplify the model.") }
        struct Run: Hashable {
            var first: Int
            var end: Int
        }
        var boxes: [Box] = []
        var occupied = Set<SIMD3<Int>>()
        var thin = 0
        var smallGaps = 0
        for k in low.z..<high.z {
            var previous: [Run: Int] = [:]
            for j in low.y..<high.y {
                let y = (Float(j) + 0.5) * h
                let z = (Float(k) + 0.5) * h
                var hits: [Float] = []
                for t in triangles {
                    let u = t.b - t.a
                    let v = t.c - t.a
                    let determinant = u.y * v.z - u.z * v.y
                    if abs(determinant) < 1e-12 { continue }
                    let dy = y - t.a.y
                    let dz = z - t.a.z
                    let b = (dy * v.z - dz * v.y) / determinant
                    let c = (u.y * dz - u.z * dy) / determinant
                    if b >= -1e-6 && c >= -1e-6 && b + c <= 1 + 1e-6 {
                        hits.append(t.a.x + b * u.x + c * v.x)
                    }
                }
                hits.sort()
                var unique: [Float] = []
                for x in hits where unique.last.map({ abs(x - $0) > h * 1e-5 }) ?? true { unique.append(x) }
                guard unique.count % 2 == 0 else {
                    throw ImportError.invalid(
                        "Ambiguous mesh intersections. Repair intersecting surfaces or simplify the model.")
                }
                if unique.count >= 4 {
                    for n in stride(from: 1, to: unique.count - 1, by: 2)
                    where unique[n + 1] - unique[n] < 2 * h { smallGaps += 1 }
                }
                var current: [Run: Int] = [:]
                for n in stride(from: 0, to: unique.count, by: 2) {
                    let a = unique[n]
                    let b = unique[n + 1]
                    if b - a < 2 * h { thin += 1 }
                    let first = max(low.x, Int(ceil(a / h - 0.5)))
                    let end = min(high.x, Int(ceil(b / h - 0.5)))
                    guard first < end else { continue }
                    for i in first..<end { occupied.insert(SIMD3(i, j, k)) }
                    let run = Run(first: first, end: end)
                    if let index = previous[run] {
                        boxes[index].max.y = Float(j + 1) * h
                        current[run] = index
                    } else {
                        current[run] = boxes.count
                        boxes.append(
                            Box(
                                min: SIMD3(Float(first), Float(j), Float(k)) * h,
                                max: SIMD3(Float(end), Float(j + 1), Float(k + 1)) * h))
                    }
                }
                previous = current
            }
        }
        // Merge identical rectangles in consecutive Z layers.
        var merged: [Box] = []
        struct Footprint: Hashable {
            var min: SIMD2<Float>
            var max: SIMD2<Float>
        }
        var last: [Footprint: Int] = [:]
        for box in boxes {
            let key = Footprint(min: SIMD2(box.min.x, box.min.y), max: SIMD2(box.max.x, box.max.y))
            if let index = last[key], abs(merged[index].max.z - box.min.z) < h * 1e-4 {
                merged[index].max.z = box.max.z
            } else {
                last[key] = merged.count
                merged.append(box)
            }
        }
        guard !occupied.isEmpty else {
            throw ImportError.invalid(
                "No solid cells remain at this resolution. Choose a finer grid or enlarge the model.")
        }
        guard merged.count <= 2048 else {
            throw ImportError.invalid(
                "Model needs more than 2,048 voxel regions. Simplify it or use a coarser grid.")
        }
        // Detect single-cell thickness in all directions, including walls parallel to the scanline.
        for cell in occupied {
            if (0..<3).contains(where: { axis in
                var a = cell
                var b = cell
                a[axis] -= 1
                b[axis] += 1
                return !occupied.contains(a) && !occupied.contains(b)
            }) {
                thin += 1
            }
        }
        var missed = 0
        var uncertain = 0
        for t in triangles {
            let a = SIMD3<Int>((simd_min(t.a, simd_min(t.b, t.c)) / h).rounded(.down))
            let b = SIMD3<Int>((simd_max(t.a, simd_max(t.b, t.c)) / h).rounded(.down))
            var found = false
            var examined = 0
            search: for k in max(low.z, a.z - 1)..<min(high.z, b.z + 2) {
                for j in max(low.y, a.y - 1)..<min(high.y, b.y + 2) {
                    for i in max(low.x, a.x - 1)..<min(high.x, b.x + 2) {
                        if occupied.contains(SIMD3(i, j, k)) {
                            found = true
                            break search
                        }
                        examined += 1
                        if examined >= 256 { break search }
                    }
                    if found { break }
                }
                if found { break }
            }
            if !found {
                if examined >= 256 { uncertain += 1 } else { missed += 1 }
            }
        }
        if (0..<3).contains(where: { bounds.size[$0] < 2 * h }) { thin = max(thin, 1) }
        return Preview(
            boxes: merged, occupiedCells: occupied.count, missedTriangles: missed, thinSpans: thin,
            smallGaps: smallGaps, uncertainTriangles: uncertain, cellSize: h, bounds: bounds)
    }
}
