import Foundation
import GeometryImport
import simd

/// Geometry-only OBJ and STL reader. Imported surfaces must enclose a volume.
public struct ImportedMesh: Sendable, Hashable, Codable {
    public struct Triangle: Sendable, Hashable, Codable {
        public var a: SIMD3<Float>
        public var b: SIMD3<Float>
        public var c: SIMD3<Float>
    }
    public private(set) var triangles: [Triangle]
    public private(set) var parts: [Part] = []
    private var faceLabels: [FaceLabel]?
    public private(set) var buildingElements: [BuildingElement]?
    public private(set) var buildingNotes: [String]?
    public private(set) var buildingOrigin: SIMD3<Double>?
    public private(set) var buildingSourceData: Data?
    public private(set) var buildingSelection: BuildingSelection?
    private enum CodingKeys: String, CodingKey {
        case triangles, faceLabels, buildingElements, buildingNotes, buildingOrigin, buildingSourceData,
            buildingSelection
    }
    public var bounds: Box {
        let points = triangles.flatMap { [$0.a, $0.b, $0.c] }
        return Box(
            min: points.reduce(SIMD3<Float>(repeating: .infinity), simd_min),
            max: points.reduce(SIMD3<Float>(repeating: -.infinity), simd_max))
    }
    public enum ImportError: LocalizedError {
        case invalid(String)
        case geometry(message: String, triangleIndices: [Int], bounds: Box)
        public var errorDescription: String? {
            switch self {
            case .invalid(let reason): reason
            case .geometry(let message, _, _): message
            }
        }
    }
    public init(data: Data, fileExtension: String) throws {
        try self.init(data: data, fileExtension: fileExtension, validating: true)
    }
    private init(data: Data, fileExtension: String, validating: Bool) throws {
        try Task.checkCancellation()
        // The shared reader parses the file; what makes an importable solid is decided here.
        let file: MeshFile
        do {
            file = try MeshFile(data: data, fileExtension: fileExtension)
        } catch let MeshFile.ReadError.invalid(reason) {
            throw ImportError.invalid(reason)
        }
        var result: [Triangle] = []
        var labels: [FaceLabel]? = fileExtension.lowercased() == "obj" ? [] : nil
        let vertices = file.vertices
        for face in file.faces {
            let indices = face.corners
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
                labels?.append(FaceLabel(object: face.object, group: face.group))
                result.append(
                    Triangle(a: vertices[indices[0]], b: vertices[indices[n]], c: vertices[indices[n + 1]]))
            }
        }
        guard !result.isEmpty, result.count <= 100_000 else {
            throw ImportError.invalid("Models must have between 1 and 100,000 triangles.")
        }
        if validating {
            for t in result {
                guard [t.a, t.b, t.c].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                    simd_length_squared(simd_cross(t.b - t.a, t.c - t.a)) > 1e-20
                else { throw ImportError.invalid("Model contains non-finite or degenerate triangles.") }
            }
        }
        triangles = result
        faceLabels = labels
        if validating {
            try validateGeometry()
            parts = try MeshParts.make(triangles, labels: labels)
        }
    }
    /// Invalid geometry is available only as inspection data, never as an importable mesh.
    public struct Inspection: Sendable {
        public var triangles: [Triangle]
        public var validatedMesh: ImportedMesh?
        public var issues: [InspectionIssue]
        public var omittedTriangles: Int
    }
    public var inspection: Inspection {
        Inspection(triangles: triangles, validatedMesh: self, issues: [], omittedTriangles: 0)
    }
    public struct InspectionIssue: Sendable, Hashable, Identifiable {
        public var message: String
        public var triangleIndices: [Int]
        public var bounds: Box?
        public var id: Self { self }
    }
    public static func inspect(data: Data, fileExtension: String) throws -> Inspection {
        var candidate = try ImportedMesh(data: data, fileExtension: fileExtension, validating: false)
        do {
            let bad = candidate.triangles.indices.filter { n in
                let t = candidate.triangles[n]
                return
                    !([t.a, t.b, t.c].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    && simd_length_squared(simd_cross(t.b - t.a, t.c - t.a)) > 1e-20)
            }
            if !bad.isEmpty {
                let points = bad.flatMap { n in
                    [candidate.triangles[n].a, candidate.triangles[n].b, candidate.triangles[n].c]
                }
                .filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                let message =
                    "Model contains \(bad.count) non-finite or degenerate triangles. Repair the source and export again."
                if points.isEmpty { throw ImportError.invalid(message) }
                throw ImportError.geometry(
                    message: message, triangleIndices: bad,
                    bounds: Box(
                        min: points.reduce(SIMD3(repeating: .infinity), simd_min),
                        max: points.reduce(SIMD3(repeating: -.infinity), simd_max)))
            }
            try candidate.validateGeometry()
            candidate.parts = try MeshParts.make(candidate.triangles, labels: candidate.faceLabels)
            return Inspection(
                triangles: candidate.triangles, validatedMesh: candidate, issues: [], omittedTriangles: 0)
        } catch is CancellationError { throw CancellationError() } catch {
            let visible = candidate.triangles.filter { t in
                [t.a, t.b, t.c].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    && simd_length_squared(
                        simd_cross(
                            SIMD3<Double>(t.b) - SIMD3<Double>(t.a), SIMD3<Double>(t.c) - SIMD3<Double>(t.a)))
                        > 0
            }
            var issue = InspectionIssue(message: error.localizedDescription, triangleIndices: [], bounds: nil)
            if case ImportError.geometry(let message, let indices, let bounds) = error {
                issue = InspectionIssue(message: message, triangleIndices: indices, bounds: bounds)
            }
            // Preserve indices for highlighting; omit non-finite triangles only in the renderer.
            return Inspection(
                triangles: candidate.triangles, validatedMesh: nil, issues: [issue],
                omittedTriangles: candidate.triangles.count - visible.count)
        }
    }
    private func validateGeometry(coordinateUnits: String = "source units") throws {
        if let buildingElements {
            for element in buildingElements {
                try MeshValidation.validate(element.mesh.triangles, coordinateUnits: coordinateUnits)
            }
        } else {
            try MeshValidation.validate(triangles, coordinateUnits: coordinateUnits)
        }
    }
    public func transformed(scale: Float, yUp: Bool, corner: SIMD3<Float>) throws -> ImportedMesh {
        guard scale.isFinite, scale > 0, (0..<3).allSatisfy({ corner[$0].isFinite && corner[$0] >= 0 }) else {
            throw ImportError.invalid("Scale must be positive and placement must be finite and above ground.")
        }
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> { (yUp ? SIMD3(p.x, -p.z, p.y) : p) * scale }
        if let buildingElements {
            let low = triangles.flatMap { [rotate($0.a), rotate($0.b), rotate($0.c)] }.reduce(
                SIMD3<Float>(repeating: .infinity), simd_min)
            let moved = try buildingElements.map { element in
                var copy = element
                let elementLow = element.mesh.triangles.flatMap {
                    [rotate($0.a), rotate($0.b), rotate($0.c)]
                }
                .reduce(SIMD3<Float>(repeating: .infinity), simd_min)
                copy.mesh = try element.mesh.transformed(
                    scale: scale, yUp: yUp, corner: simd_max(.zero, elementLow - low + corner))
                return copy
            }
            return try ImportedMesh(
                buildingElements: moved, notes: buildingNotes ?? [], origin: buildingOrigin,
                sourceData: buildingSourceData, selection: buildingSelection)
        }
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
        // Float placement/scaling can merge previously distinct vertices. Revalidate the actual
        // coordinates used by the sampler rather than assuming the transform preserved topology.
        try mesh.validateGeometry(coordinateUnits: "metres in simulation coordinates")
        return mesh
    }

    public struct Diagnostic: Sendable, Hashable, Codable, Identifiable {
        public enum Kind: String, Sendable, Codable { case thin, gap, missing }
        public var kind: Kind
        public var bounds: Box
        public var axis: Int?
        public var minimumSize: Float?
        public var partIDs: [Int]? = nil
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
        /// Aligned to boxes. Absent in layouts saved before source part ownership was retained.
        public var boxPartIDs: [Int]? = nil
        public var sourceNotes: [String]? = nil
        public var buildingSampling: [BuildingSampling]? = nil
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
            return messages + (sourceNotes ?? [])
        }
    }
    /// Rasterise closed volumes and diagnose continuous spans along all three axes.
    /// Empty previews are useful for visualising features lost at coarse resolutions.
    public func preview(cellSize h: Float, domain: SIMD3<Float>, allowEmpty: Bool = false) throws -> Preview {
        if buildingElements != nil {
            return try buildingPreview(cellSize: h, domain: domain, allowEmpty: allowEmpty)
        }
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
        func add(
            _ kind: Diagnostic.Kind, _ region: Box, axis: Int? = nil, minimum: Float? = nil,
            owners: [Int] = []
        ) {
            var issue = Diagnostic(
                kind: kind, bounds: region, axis: axis, minimumSize: minimum, partIDs: owners)
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
                    issue.partIDs = Array(Set((issue.partIDs ?? []) + (old.partIDs ?? []))).sorted()
                    diagnostics.remove(at: n)
                    n = 0
                } else {
                    n += 1
                }
            }
            if diagnostics.count < 128 { diagnostics.append(issue) } else { truncated = true }
        }
        // Orient neighbouring faces consistently without changing the retained source or cavity
        // semantics. Half-open projected edges count a diagonal once; signed events cancel tangencies.
        let orientations = try MeshValidation.orientations(triangles)
        let partIDs = trianglePartIDs
        func intersections(axis: Int, first: Float, second: Float) throws -> (
            hits: [Float], owners: [Int], boundaries: [Int]
        ) {
            let j = (axis + 1) % 3
            let k = (axis + 2) % 3
            var hits: [(position: Double, sign: Int, part: Int)] = []
            let point = SIMD2<Double>(Double(first), Double(second))
            func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double { a.x * b.y - a.y * b.x }
            for (index, t) in triangles.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                let a = SIMD3<Double>(t.a)
                let b = SIMD3<Double>(t.b)
                let c = SIMD3<Double>(t.c)
                let pa = SIMD2(a[j], a[k])
                var pb = SIMD2(b[j], b[k])
                var pc = SIMD2(c[j], c[k])
                let determinant = cross(pb - pa, pc - pa)
                if determinant == 0 { continue }
                if determinant < 0 { swap(&pb, &pc) }
                func containsEdge(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Bool {
                    let value = cross(b - a, point - a)
                    // One owner for an exact shared edge, regardless of face winding.
                    return value > 0 || (value == 0 && (b.y > a.y || (b.y == a.y && b.x < a.x)))
                }
                guard containsEdge(pa, pb), containsEdge(pb, pc), containsEdge(pc, pa) else { continue }
                let u = b - a
                let v = c - a
                let dy = Double(first) - a[j]
                let dz = Double(second) - a[k]
                let beta = (dy * v[k] - dz * v[j]) / determinant
                let gamma = (u[j] * dz - u[k] * dy) / determinant
                hits.append(
                    (
                        a[axis] + beta * u[axis] + gamma * v[axis],
                        (determinant > 0 ? 1 : -1) * orientations[index], partIDs[index]
                    ))
            }
            hits.sort { $0.position < $1.position }
            var unique: [Float] = []
            var crossingParts: [Int] = []
            var n = 0
            while n < hits.count {
                let position = hits[n].position
                let part = hits[n].part
                let tolerance = max(abs(position).ulp * 32, Double(h) * 1e-14)
                var sign = 0
                repeat {
                    sign += hits[n].sign
                    n += 1
                } while n < hits.count && abs(hits[n].position - position) <= tolerance
                if sign != 0 {
                    guard abs(sign) == 1 else {
                        throw ImportError.invalid(
                            "Ambiguous mesh crossings. Repair intersecting or touching surfaces before importing."
                        )
                    }
                    unique.append(Float(position))
                    crossingParts.append(part)
                }
            }
            guard unique.count % 2 == 0 else {
                throw ImportError.invalid(
                    "Ambiguous mesh intersections. Repair intersecting surfaces or simplify the model.")
            }
            var active: [Int] = []
            var owners: [Int] = []
            for (n, part) in crossingParts.enumerated() {
                if let index = active.firstIndex(of: part) {
                    active.remove(at: index)
                } else {
                    active.append(part)
                }
                if n % 2 == 0 {
                    guard let owner = active.last else {
                        throw ImportError.invalid("Ambiguous source part boundaries.")
                    }
                    owners.append(owner)
                }
            }
            guard active.isEmpty else { throw ImportError.invalid("Unclosed source part crossings.") }
            return (unique, owners, crossingParts)
        }
        var occupied = Set<SIMD3<Int>>()
        var thin = 0
        var gaps = 0
        struct Run: Hashable {
            var part: Int
            var first: Int
            var end: Int
        }
        var boxes: [Box] = []
        var boxParts: [Int] = []
        for axis in 0..<3 {
            let jAxis = (axis + 1) % 3
            let kAxis = (axis + 2) % 3
            for k in low[kAxis]..<high[kAxis] {
                try Task.checkCancellation()
                var previous: [Run: Int] = [:]
                for j in low[jAxis]..<high[jAxis] {
                    let crossings = try intersections(
                        axis: axis, first: (Float(j) + 0.5) * h, second: (Float(k) + 0.5) * h)
                    let hits = crossings.hits
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
                                .gap, region(hits[n], hits[n + 1]), axis: axis,
                                minimum: hits[n + 1] - hits[n],
                                owners: Array(
                                    Set([
                                        crossings.owners[(n - 1) / 2], crossings.owners[(n + 1) / 2],
                                        crossings.boundaries[n], crossings.boundaries[n + 1],
                                    ])
                                ).sorted()
                            )
                        }
                    }
                    var current: [Run: Int] = [:]
                    for n in stride(from: 0, to: hits.count, by: 2) {
                        let a = hits[n]
                        let b = hits[n + 1]
                        if b - a < 2 * h {
                            thin += 1
                            add(
                                .thin, region(a, b), axis: axis, minimum: b - a,
                                owners: Array(
                                    Set([
                                        crossings.owners[n / 2], crossings.boundaries[n],
                                        crossings.boundaries[n + 1],
                                    ])
                                ).sorted())
                        }
                        guard axis == 0 else { continue }
                        let first = max(low.x, Int(ceil(a / h - 0.5)))
                        let end = min(high.x, Int(ceil(b / h - 0.5)))
                        guard first < end else { continue }
                        for i in first..<end { occupied.insert(SIMD3(i, j, k)) }
                        let owner = crossings.owners[n / 2]
                        let run = Run(part: owner, first: first, end: end)
                        if let index = previous[run] {
                            boxes[index].max.y = Float(j + 1) * h
                            current[run] = index
                        } else {
                            current[run] = boxes.count
                            boxes.append(region(Float(first) * h, Float(end) * h))
                            boxParts.append(owner)
                        }
                    }
                    previous = current
                }
            }
        }
        var merged: [Box] = []
        var mergedParts: [Int] = []
        struct Footprint: Hashable {
            var part: Int
            var min: SIMD2<Float>
            var max: SIMD2<Float>
        }
        var last: [Footprint: Int] = [:]
        for (index, box) in boxes.enumerated() {
            let key = Footprint(
                part: boxParts[index], min: SIMD2(box.min.x, box.min.y), max: SIMD2(box.max.x, box.max.y))
            if let n = last[key], abs(merged[n].max.z - box.min.z) < h * 1e-4 {
                merged[n].max.z = box.max.z
            } else {
                last[key] = merged.count
                merged.append(box)
                mergedParts.append(boxParts[index])
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
                    Box(min: simd_min(t.a, simd_min(t.b, t.c)), max: simd_max(t.a, simd_max(t.b, t.c))),
                    owners: [partIDs[index]])
            }
        }
        return Preview(
            boxes: merged, occupiedCells: occupied.count, missedTriangles: missed, thinSpans: thin,
            smallGaps: gaps, uncertainTriangles: 0, cellSize: h, bounds: bounds, diagnostics: diagnostics,
            diagnosticsTruncated: truncated, boxPartIDs: mergedParts)
    }
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let elements = try container.decodeIfPresent([BuildingElement].self, forKey: .buildingElements) {
            guard !container.contains(.triangles), !container.contains(.faceLabels) else {
                throw ImportError.invalid("Saved IFC source contains conflicting geometry encodings.")
            }
            self = try ImportedMesh(
                buildingElements: elements,
                notes: container.decodeIfPresent([String].self, forKey: .buildingNotes) ?? [],
                origin: container.decodeIfPresent(SIMD3<Double>.self, forKey: .buildingOrigin),
                sourceData: container.decodeIfPresent(Data.self, forKey: .buildingSourceData),
                selection: container.decodeIfPresent(BuildingSelection.self, forKey: .buildingSelection))
            return
        }
        triangles = try container.decode([Triangle].self, forKey: .triangles)
        faceLabels = try container.decodeIfPresent([FaceLabel].self, forKey: .faceLabels)
        guard !triangles.isEmpty, triangles.count <= 100_000,
            triangles.allSatisfy({ t in
                [t.a, t.b, t.c].allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
                    && simd_length_squared(simd_cross(t.b - t.a, t.c - t.a)) > 1e-20
            })
        else { throw ImportError.invalid("Saved source mesh is invalid or too large.") }
        try validateGeometry()
        parts = try MeshParts.make(triangles, labels: faceLabels)
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let buildingElements {
            try container.encode(buildingElements, forKey: .buildingElements)
            try container.encodeIfPresent(buildingNotes, forKey: .buildingNotes)
            try container.encodeIfPresent(buildingOrigin, forKey: .buildingOrigin)
            try container.encodeIfPresent(buildingSourceData, forKey: .buildingSourceData)
            try container.encodeIfPresent(buildingSelection, forKey: .buildingSelection)
        } else {
            try container.encode(triangles, forKey: .triangles)
            try container.encodeIfPresent(faceLabels, forKey: .faceLabels)
        }
    }

    public init(
        buildingElements elements: [BuildingElement], notes: [String] = [], origin: SIMD3<Double>? = nil,
        sourceData: Data? = nil, selection: BuildingSelection? = nil
    ) throws {
        guard !elements.isEmpty, elements.count <= 1024,
            Set(elements.map(\.globalID)).count == elements.count,
            (sourceData?.count ?? 0) <= 20_000_000,
            notes.count <= 100, notes.allSatisfy({ $0.count <= 2000 }),
            origin.map({ [$0.x, $0.y, $0.z].allSatisfy(\.isFinite) }) ?? true
        else { throw ImportError.invalid("IFC source metadata is invalid or too large.") }
        triangles = []
        parts = []
        let sorted = elements.sorted { $0.globalID < $1.globalID }
        for element in sorted {
            try Task.checkCancellation()
            guard element.globalID.count == 22,
                element.globalID.allSatisfy({
                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$")
                }),
                element.name.count <= 200, element.ifcClass.count <= 100,
                (element.storey?.count ?? 0) <= 200,
                element.mesh.buildingElements == nil,
                triangles.count + element.mesh.triangles.count <= 100_000
            else {
                throw ImportError.invalid("Invalid IFC element or model exceeds the 100,000-triangle limit.")
            }
            try element.mesh.validateGeometry()
            let start = triangles.count
            triangles.append(contentsOf: element.mesh.triangles)
            parts.append(
                Part(
                    id: element.partID, name: element.name, objectName: element.name,
                    groupName: element.ifcClass,
                    triangleIndices: Array(start..<triangles.count), ifcGlobalID: element.globalID,
                    ifcClass: element.ifcClass, storey: element.storey))
        }
        guard Set(parts.map(\.id)).count == parts.count else {
            throw ImportError.invalid("IFC element identifiers collide; cannot preserve part ownership.")
        }
        if let selection { try selection.validate(converted: Set(sorted.map(\.globalID))) }
        buildingSelection = selection
        buildingElements = sorted
        buildingNotes = notes
        buildingOrigin = origin
        buildingSourceData = sourceData
        faceLabels = nil
    }

}
