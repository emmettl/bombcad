import Foundation
import simd

extension ImportedMesh {
    /// A source inventory and explicit GUID choices, retained independently of converted geometry.
    public struct BuildingSourceElement: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var name: String
        public var ifcClass: String
        public var buildingID: String?
        public var building: String?
        public var storeyID: String?
        public var storey: String?
        public var supported: Bool
        public var hasChildren: Bool
        /// The element it is aggregated into, where it is a part of one (a wall's blocks, a
        /// slab's precast planks); nil for one in a storey or building directly.
        public var parentID: String?
        /// Whether it was found in the IFC's entities but not in its spatial structure.
        public var uncontained: Bool?
        public init(
            id: String, name: String, ifcClass: String, buildingID: String? = nil,
            building: String? = nil, storeyID: String? = nil, storey: String? = nil,
            supported: Bool = true, hasChildren: Bool = false, parentID: String? = nil,
            uncontained: Bool? = nil
        ) {
            self.id = id
            self.name = name
            self.ifcClass = ifcClass
            self.buildingID = buildingID
            self.building = building
            self.storeyID = storeyID
            self.storey = storey
            self.supported = supported
            self.hasChildren = hasChildren
            self.parentID = parentID
            self.uncontained = uncontained
        }
    }
    public struct BuildingSelection: Sendable, Hashable, Codable {
        public var inventory: [BuildingSourceElement]
        public var includedIDs: [String]
        public init(inventory: [BuildingSourceElement], includedIDs: Set<String>) {
            self.inventory = inventory.sorted { $0.id < $1.id }
            self.includedIDs = includedIDs.sorted()
        }
        func validate(converted: Set<String>) throws {
            func validID(_ id: String) -> Bool {
                id.count == 22
                    && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "$") }
            }
            let eligible = Set(inventory.filter(\.supported).map(\.id))
            let chosen = Set(includedIDs)
            guard inventory.count <= 20_000, Set(inventory.map(\.id)).count == inventory.count,
                !chosen.isEmpty, chosen.count <= 1024, chosen.count == includedIDs.count,
                chosen.isSubset(of: eligible), converted.isSubset(of: chosen),
                inventory.allSatisfy({ e in
                    validID(e.id) && e.name.count <= 200 && e.ifcClass.count <= 100
                        && (e.building?.count ?? 0) <= 200 && (e.storey?.count ?? 0) <= 200
                        && (e.buildingID.map(validID) ?? true) && (e.storeyID.map(validID) ?? true)
                })
            else { throw ImportError.invalid("Saved IFC inventory or element choices are invalid.") }
        }
    }
    /// Keep the simulation coordinates of surviving products unchanged when the subset is rebased.
    /// A negative result deliberately remains staged: it must not silently shift the building.
    public static func preservingBuildingPlacement(
        from previous: ImportedMesh, to replacement: ImportedMesh,
        corner: SIMD3<Double>
    ) throws -> SIMD3<Double> {
        guard let oldElements = previous.buildingElements, let newElements = replacement.buildingElements
        else {
            throw ImportError.invalid("IFC building sources are needed to preserve placement.")
        }
        let oldMinimum = SIMD3<Double>(previous.bounds.min)
        let newMinimum = SIMD3<Double>(replacement.bounds.min)
        let delta: SIMD3<Double>
        if let oldOrigin = previous.buildingOrigin, let newOrigin = replacement.buildingOrigin {
            delta =
                (newOrigin - oldOrigin)
                + (newMinimum - oldMinimum)
        } else {
            // Earlier or externally created sources can lack the original IFC origin. A surviving
            // product establishes the relative frame; verify all shared products agree.
            let old = Dictionary(uniqueKeysWithValues: oldElements.map { ($0.globalID, $0.mesh.bounds) })
            let offsets = newElements.compactMap { e -> SIMD3<Double>? in
                guard let bounds = old[e.globalID] else { return nil }
                return (SIMD3<Double>(bounds.min) - oldMinimum)
                    - (SIMD3<Double>(e.mesh.bounds.min) - newMinimum)
            }
            guard let reference = offsets.first,
                offsets.allSatisfy({ simd_length($0 - reference) < 0.00001 })
            else {
                throw ImportError.invalid(
                    "This earlier IFC source has no coordinate origin. Keep at least one shared element while changing choices to preserve its position."
                )
            }
            delta = reference
        }
        let point = corner + delta
        guard [point.x, point.y, point.z].allSatisfy(\.isFinite) else {
            throw ImportError.invalid("The changed IFC selection has invalid placement coordinates.")
        }
        return point
    }

    /// Separate source omissions from sampling loss and deterministic overlap ownership.
    public struct BuildingSampling: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        public var sampledCells: Int
        public var assignedCells: Int
        public var status: String {
            if sampledCells == 0 { return "No solid cells on this grid" }
            if assignedCells == 0 { return "Fully covered by other elements" }
            if assignedCells < sampledCells { return "Partly overlaps other elements" }
            return "Represented on this grid"
        }
    }

    /// IFC products are independent solids. Nested shells within a product still represent cavities.
    public struct BuildingElement: Sendable, Hashable, Codable {
        /// The element a part belongs to: a wall built of blocks, a slab of planks, whose own
        /// entity has no geometry of its own.
        public struct Assembly: Sendable, Hashable, Codable {
            public var id: String
            public var name: String
            public var ifcClass: String
            public init(id: String, name: String, ifcClass: String) {
                self.id = id
                self.name = name
                self.ifcClass = ifcClass
            }
        }
        public var globalID: String
        public var name: String
        public var ifcClass: String
        public var storey: String?
        /// For a part of an element, that element.
        public var assembly: Assembly?
        public var mesh: ImportedMesh
        /// Its material layers as the IFC gives them (for meshing it as a structure,
        /// `IFCStructure`); nil where none were read.
        public var materials: [IFCStructure.Layer]?
        public init(
            globalID: String, name: String, ifcClass: String, storey: String?, assembly: Assembly? = nil,
            mesh: ImportedMesh, materials: [IFCStructure.Layer]? = nil
        ) {
            self.globalID = globalID
            self.name = name
            self.ifcClass = ifcClass
            self.storey = storey
            self.assembly = assembly
            self.mesh = mesh
            self.materials = materials
        }
        /// Stable across ordering and tessellation changes; explicitly check collisions on construction.
        public var partID: Int {
            var value: UInt64 = 14_695_981_039_346_656_037
            for byte in globalID.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
            return Int(value & 0x001f_ffff_ffff_ffff)
        }
    }

    func buildingPreview(cellSize h: Float, domain: SIMD3<Float>, allowEmpty: Bool) throws -> Preview {
        let bounds = bounds
        guard h.isFinite, h > 0,
            (0..<3).allSatisfy({
                bounds.min[$0] >= 0 && bounds.max[$0] <= domain[$0] && bounds.max[$0] / h < 1_000_000
            })
        else {
            throw ImportError.invalid("IFC building lies outside the domain. Move it or expand the domain.")
        }
        let low = SIMD3<Int>((bounds.min / h).rounded(.down))
        let high = SIMD3<Int>((bounds.max / h).rounded(.up))
        let size = high &- low
        guard Double(size.x) * Double(size.y) * Double(size.z) <= 2_000_000 else {
            throw ImportError.invalid(
                "IFC preview is too large. Choose a coarser grid or a smaller building.")
        }
        var work = 0.0
        var cells: [SIMD3<Int>: Int] = [:]
        var diagnostics: [Diagnostic] = []
        var sampling: [BuildingSampling] = []
        var gapScan = BuildingGapScan()
        var thin = 0
        var gaps = 0
        var missed = 0
        var truncated = false
        for element in buildingElements ?? [] {
            try Task.checkCancellation()
            let s = (element.mesh.bounds.max / h).rounded(.up) - (element.mesh.bounds.min / h).rounded(.down)
            work +=
                (Double(s.x) * Double(s.y) + Double(s.y) * Double(s.z) + Double(s.z) * Double(s.x))
                * Double(element.mesh.triangles.count)
            guard work <= 90_000_000 else {
                throw ImportError.invalid(
                    "IFC preview exceeds its sampling-work budget. Simplify the building or choose a coarser grid."
                )
            }
            let preview = try element.mesh.sampledPreview(
                cellSize: h, domain: domain, allowEmpty: true,
                onRay: { axis, j, k, spans in
                    gapScan.record(axis: axis, j: j, k: k, spans: spans, owner: element.partID)
                })
            thin += preview.thinSpans
            gaps += preview.smallGaps
            missed += preview.missedTriangles
            truncated = truncated || preview.diagnosticsTruncated
            for var issue in preview.diagnostics {
                issue.partIDs = [element.partID]
                if diagnostics.count < 128 { diagnostics.append(issue) } else { truncated = true }
            }
            var assigned = 0
            for box in preview.boxes {
                let a = SIMD3<Int>((box.min / h).rounded(.toNearestOrAwayFromZero))
                let b = SIMD3<Int>((box.max / h).rounded(.toNearestOrAwayFromZero))
                for z in a.z..<b.z {
                    try Task.checkCancellation()
                    for y in a.y..<b.y {
                        for x in a.x..<b.x {
                            let cell = SIMD3(x, y, z)
                            if cells[cell] == nil {
                                cells[cell] = element.partID
                                assigned += 1
                            }
                        }
                    }
                }
            }
            sampling.append(
                BuildingSampling(
                    id: element.globalID, sampledCells: preview.occupiedCells, assignedCells: assigned))
        }
        let crossingGaps = try gapScan.diagnostics(cellSize: h)
        gaps += crossingGaps.samples
        truncated = truncated || crossingGaps.truncated || diagnostics.count + crossingGaps.issues.count > 128
        diagnostics = Array((crossingGaps.issues + diagnostics).prefix(128))
        let count = cells.count
        guard count > 0 || allowEmpty else {
            throw ImportError.invalid("No occupied IFC cells remain. Choose a finer grid.")
        }
        let ordered = cells.keys.sorted { a, b in
            if a.z != b.z { return a.z < b.z }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
        var boxes: [Box] = []
        var owners: [Int] = []
        for a in ordered {
            guard let owner = cells[a] else { continue }
            try Task.checkCancellation()
            var b = a &+ SIMD3(repeating: 1)
            while b.x < high.x && cells[SIMD3(b.x, a.y, a.z)] == owner { b.x += 1 }
            while b.y < high.y && (a.x..<b.x).allSatisfy({ cells[SIMD3($0, b.y, a.z)] == owner }) { b.y += 1 }
            while b.z < high.z
                && (a.y..<b.y).allSatisfy({ y in
                    (a.x..<b.x).allSatisfy { cells[SIMD3($0, y, b.z)] == owner }
                })
            { b.z += 1 }
            for z in a.z..<b.z {
                for y in a.y..<b.y { for x in a.x..<b.x { cells.removeValue(forKey: SIMD3(x, y, z)) } }
            }
            boxes.append(Box(min: SIMD3<Float>(a) * h, max: SIMD3<Float>(b) * h))
            owners.append(owner)
            guard boxes.count <= 2048 else {
                throw ImportError.invalid(
                    "IFC building exceeds the 2,048 sampled-region limit. Simplify it or choose a coarser grid."
                )
            }
        }
        var gridNotes: [String] = []
        let lost = sampling.filter { $0.sampledCells == 0 }.count
        let covered = sampling.filter { $0.sampledCells > 0 && $0.assignedCells == 0 }.count
        if lost > 0 {
            gridNotes.append(
                "\(lost) converted IFC elements have no solid cells on this grid. These are sampling losses, not converter omissions. Check IFC completeness and compare finer grids."
            )
        }
        if covered > 0 {
            gridNotes.append(
                "\(covered) converted IFC elements are fully covered by other sampled elements. Their source geometry is retained, but they have no separately assigned cells. Check IFC completeness."
            )
        }
        return Preview(
            boxes: boxes, occupiedCells: count, missedTriangles: missed, thinSpans: thin, smallGaps: gaps,
            uncertainTriangles: 0, cellSize: h, bounds: bounds, diagnostics: diagnostics,
            diagnosticsTruncated: truncated, boxPartIDs: owners,
            sourceNotes: (buildingNotes ?? []) + gridNotes + [
                "IFC elements are rigid obstacles. Overlapping sampled cells count once and use the first GlobalId for selection; geometric contact does not establish a structural connection.",
                gapScan.incomplete
                    ? "The cross-element gap check exceeded its interval budget and is incomplete. No cross-element clearances are reported from partial data. Inspect Source against Simulation and compare grids."
                    : "IFC gaps between separate elements are checked using solid unions along X/Y/Z grid-centre rays. These approximate checks can miss off-ray or oblique clearances; inspect Source against Simulation and compare grids.",
            ], buildingSampling: sampling, crossElementGapSamples: crossingGaps.samples,
            crossElementChecksIncomplete: gapScan.incomplete)
    }
}
