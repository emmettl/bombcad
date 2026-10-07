import Foundation
import simd

/// Geometry-only OBJ and STL reader. Imported surfaces must enclose a volume.
public struct ImportedMesh: Sendable, Hashable, Codable {
    public struct Triangle: Sendable, Hashable, Codable {
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

    public struct Diagnostic: Sendable, Hashable, Codable, Identifiable {
        public enum Kind: String, Sendable, Codable { case thin, gap, missing }
        public var kind: Kind
        public var bounds: Box
        public var axis: Int?
        public var minimumSize: Float?
        public var id: Self { self }
        public var title: String {
            switch kind {
            case .thin: "Thin feature"
            case .gap: "Narrow gap"
            case .missing: "Potentially missing surface"
            }
        }
        public var detail: String {
            let size = bounds.size
            let extent = String(format: "%.3g × %.3g × %.3g m", size.x, size.y, size.z)
            let position = String(format: "%.3g, %.3g, %.3g m", bounds.min.x, bounds.min.y, bounds.min.z)
            if let minimumSize, let axis {
                return String(
                    format: "Minimum sampled %@ dimension %.3g m. Region %@ at %@.", ["X", "Y", "Z"][axis],
                    minimumSize, extent, position)
            }
            return "Approximate region \(extent) at \(position)."
        }
    }
    public struct Preview: Sendable, Hashable, Codable {
        public var boxes: [Box]
        public var occupiedCells: Int
        public var missedTriangles: Int
        public var thinSpans: Int
        public var smallGaps: Int
        public var uncertainTriangles: Int
        public var cellSize: Float
        public var bounds: Box
        public var diagnostics: [Diagnostic]
        public var diagnosticsTruncated: Bool
        public var warnings: [String] {
            var messages = [
                "Geometry is sampled at cell centres. Highlighted regions are approximate diagnostics, not a mesh convergence check. Inspect the overlay and compare finer grids."
            ]
            if thinSpans > 0 {
                messages.append(
                    "Thin regions have sampled dimensions below two cells (\(2 * cellSize) m); walls can disappear or have the wrong thickness."
                )
            }
            if smallGaps > 0 {
                messages.append(
                    "Narrow gaps were found below two cells in X, Y or Z. Openings may close or transmit the wrong blast load."
                )
            }
            if missedTriangles > 0 {
                messages.append(
                    "\(missedTriangles) triangles have no nearby occupied cell at the tested surface points. Inspect the red regions for potentially missing geometry."
                )
            }
            if diagnosticsTruncated {
                messages.append(
                    "The preview shows up to 128 affected regions. Additional regions were found; highlighting is incomplete."
                )
            }
            if occupiedCells == 0 {
                messages.append(
                    "No occupied cells remain. Choose a finer grid or increase the model scale before importing."
                )
            }
            return messages
        }
    }
    /// Rasterise closed volumes and diagnose continuous spans along all three axes.
    /// Empty previews are useful for visualising features lost at coarse resolutions.
    public func preview(cellSize h: Float, domain: SIMD3<Float>, allowEmpty: Bool = false) throws -> Preview {
        let bounds = self.bounds
        guard h.isFinite, h > 0,
            (0..<3).allSatisfy({
                bounds.min[$0] >= 0 && bounds.max[$0] <= domain[$0] && bounds.max[$0] / h < 1_000_000
            })
        else {
            throw ImportError.invalid(
                "Model lies outside the simulation domain or exceeds coordinate limits. Reduce its scale or move its corner."
            )
        }
        let low = SIMD3<Int>((bounds.min / h).rounded(.down))
        let high = SIMD3<Int>((bounds.max / h).rounded(.up))
        let size = high &- low
        let scanWork =
            (Double(size.x) * Double(size.y) + Double(size.y) * Double(size.z) + Double(size.z)
                * Double(size.x)) * Double(triangles.count)
        guard size.x > 0, size.y > 0, size.z > 0,
            Double(size.x) * Double(size.y) * Double(size.z) <= 2_000_000, scanWork <= 90_000_000
        else {
            throw ImportError.invalid("Preview is too large. Use a coarser grid or simplify the model.")
        }
        var diagnostics: [Diagnostic] = []
        var truncated = false
        func add(_ kind: Diagnostic.Kind, _ region: Box, axis: Int? = nil, minimum: Float? = nil) {
            var issue = Diagnostic(kind: kind, bounds: region, axis: axis, minimumSize: minimum)
            // Adjacent scan samples form an approximate affected region. Merge to a fixed point.
            var n = 0
            while n < diagnostics.count {
                let old = diagnostics[n]
                let pad = SIMD3<Float>(repeating: h * 0.01)
                if old.kind == kind && old.axis == axis && all(old.bounds.min .<= issue.bounds.max + pad)
                    && all(issue.bounds.min .<= old.bounds.max + pad)
                {
                    issue.bounds = Box(
                        min: simd_min(old.bounds.min, issue.bounds.min),
                        max: simd_max(old.bounds.max, issue.bounds.max))
                    if let value = old.minimumSize {
                        issue.minimumSize = min(value, issue.minimumSize ?? value)
                    }
                    diagnostics.remove(at: n)
                    n = 0
                } else {
                    n += 1
                }
            }
            if diagnostics.count < 128 { diagnostics.append(issue) } else { truncated = true }
        }
        func intersections(axis: Int, first: Float, second: Float) throws -> [Float] {
            let j = (axis + 1) % 3
            let k = (axis + 2) % 3
            var hits: [Float] = []
            for (index, t) in triangles.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                let u = t.b - t.a
                let v = t.c - t.a
                let determinant = u[j] * v[k] - u[k] * v[j]
                if abs(determinant) < 1e-12 { continue }
                let dy = first - t.a[j]
                let dz = second - t.a[k]
                let b = (dy * v[k] - dz * v[j]) / determinant
                let c = (u[j] * dz - u[k] * dy) / determinant
                if b >= -1e-6 && c >= -1e-6 && b + c <= 1 + 1e-6 {
                    hits.append(t.a[axis] + b * u[axis] + c * v[axis])
                }
            }
            hits.sort()
            var unique: [Float] = []
            for x in hits where unique.last.map({ abs(x - $0) > h * 1e-5 }) ?? true { unique.append(x) }
            guard unique.count % 2 == 0 else {
                throw ImportError.invalid(
                    "Ambiguous mesh intersections. Repair intersecting surfaces or simplify the model.")
            }
            return unique
        }
        var occupied = Set<SIMD3<Int>>()
        var thin = 0
        var gaps = 0
        struct Run: Hashable {
            var first: Int
            var end: Int
        }
        var boxes: [Box] = []
        for axis in 0..<3 {
            let jAxis = (axis + 1) % 3
            let kAxis = (axis + 2) % 3
            for k in low[kAxis]..<high[kAxis] {
                try Task.checkCancellation()
                var previous: [Run: Int] = [:]
                for j in low[jAxis]..<high[jAxis] {
                    let hits = try intersections(
                        axis: axis, first: (Float(j) + 0.5) * h, second: (Float(k) + 0.5) * h)
                    func region(_ a: Float, _ b: Float) -> Box {
                        var min = SIMD3<Float>.zero
                        var max = SIMD3<Float>.zero
                        min[axis] = a
                        max[axis] = b
                        min[jAxis] = Float(j) * h
                        max[jAxis] = Float(j + 1) * h
                        min[kAxis] = Float(k) * h
                        max[kAxis] = Float(k + 1) * h
                        return Box(min: min, max: max)
                    }
                    if hits.count >= 4 {
                        for n in stride(from: 1, to: hits.count - 1, by: 2)
                        where hits[n + 1] - hits[n] < 2 * h {
                            gaps += 1
                            add(
                                .gap, region(hits[n], hits[n + 1]), axis: axis, minimum: hits[n + 1] - hits[n]
                            )
                        }
                    }
                    var current: [Run: Int] = [:]
                    for n in stride(from: 0, to: hits.count, by: 2) {
                        let a = hits[n]
                        let b = hits[n + 1]
                        if b - a < 2 * h {
                            thin += 1
                            add(.thin, region(a, b), axis: axis, minimum: b - a)
                        }
                        guard axis == 0 else { continue }
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
                            boxes.append(region(Float(first) * h, Float(end) * h))
                        }
                    }
                    previous = current
                }
            }
        }
        var merged: [Box] = []
        struct Footprint: Hashable {
            var min: SIMD2<Float>
            var max: SIMD2<Float>
        }
        var last: [Footprint: Int] = [:]
        for box in boxes {
            let key = Footprint(min: SIMD2(box.min.x, box.min.y), max: SIMD2(box.max.x, box.max.y))
            if let n = last[key], abs(merged[n].max.z - box.min.z) < h * 1e-4 {
                merged[n].max.z = box.max.z
            } else {
                last[key] = merged.count
                merged.append(box)
            }
        }
        if occupied.isEmpty && !allowEmpty {
            throw ImportError.invalid(
                "No solid cells remain at this resolution. Choose a finer grid or enlarge the model.")
        }
        guard merged.count <= 2048 else {
            throw ImportError.invalid(
                "Model needs more than 2,048 voxel regions. Simplify it or use a coarser grid.")
        }
        var missed = 0
        // Inspect seven actual surface points rather than a triangle's potentially enormous AABB.
        // Adjacent cells can mask a nearby missing feature, so this remains explicitly approximate.
        for (index, t) in triangles.enumerated() {
            if index % 256 == 0 { try Task.checkCancellation() }
            let points = [
                t.a, t.b, t.c, (t.a + t.b) * 0.5, (t.b + t.c) * 0.5, (t.c + t.a) * 0.5, (t.a + t.b + t.c) / 3,
            ]
            let found = points.contains { point in
                let cell = SIMD3<Int>((point / h).rounded(.down))
                for dz in -1...1 {
                    for dy in -1...1 {
                        for dx in -1...1 {
                            if occupied.contains(cell &+ SIMD3(dx, dy, dz)) { return true }
                        }
                    }
                }
                return false
            }
            if !found {
                missed += 1
                add(
                    .missing,
                    Box(min: simd_min(t.a, simd_min(t.b, t.c)), max: simd_max(t.a, simd_max(t.b, t.c))))
            }
        }
        return Preview(
            boxes: merged, occupiedCells: occupied.count, missedTriangles: missed, thinSpans: thin,
            smallGaps: gaps, uncertainTriangles: 0, cellSize: h, bounds: bounds, diagnostics: diagnostics,
            diagnosticsTruncated: truncated)
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        triangles = try container.decode([Triangle].self, forKey: .triangles)
        guard !triangles.isEmpty, triangles.count <= 100_000,
            triangles.allSatisfy({ t in
                [t.a, t.b, t.c].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    && simd_length_squared(simd_cross(t.b - t.a, t.c - t.a)) > 1e-20
            })
        else { throw ImportError.invalid("Saved source mesh is invalid or too large.") }
        try validateClosed()
    }
}
