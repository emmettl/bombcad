import Foundation
import simd

/// A building from IFC as a structure of shells and beams (`StructureModel` meshed with shells),
/// with every inference stated.
///
/// The building is first turned about the vertical, if its walls are not already square to the
/// axes, so that they lie along the lattice the shell mesh is built on. Then, element by element:
/// - walls, slabs, roofs and plates that are flat, square to the axes and thin become shells on
///   their midsurfaces (a plate no thicker than half its other sides), their thickness and
///   material from the IFC's structural material layer where it has one, else from the geometry;
///   holes through them (the converter cuts openings out) become openings of the structure;
/// - columns, beams and members square to the axes and at least twice as long as they are wide
///   become beams of their bounding section, its width scaled to keep the element's volume;
/// - windows of glass become panes of annealed glass in the wall's opening, 6 mm thick unless the
///   IFC says otherwise; doors leave their opening open;
/// - footings become rigid footings on soil under the walls and columns that stand on them, set
///   into the soil by their own depth, and the building stands with its base on the ground;
/// - anything else (inclined elements, stairs, railings, shapes that are not plates or members)
///   stays a rigid obstacle, as an IFC import otherwise is.
/// Members that meet are tied where they meet, sharing the shell mesh's nodes; gaps up to
/// `Options.gap` between them are closed first. Materials come from the IFC's names where they
/// can be read (concrete with its grade, concrete block, masonry, steel, glass); otherwise the
/// stated default, flagged. Reinforcement is never inferred.
public struct IFCStructure: Sendable {
    /// One material layer of an element, outside to in, as the IFC lists it; its thickness in
    /// metres where given.
    public struct Layer: Sendable, Hashable, Codable {
        public var name: String
        public var thickness: Float?
        public init(name: String, thickness: Float? = nil) {
            self.name = name
            self.thickness = thickness
        }
    }

    public enum Role: String, Sendable, Hashable, Codable {
        /// A wall, slab or roof meshed as shells.
        case shell
        /// A column, beam or member meshed as beams.
        case beam
        /// A window's glass, as a shell pane.
        case pane
        /// A footing under the structure, on soil.
        case footing
        /// A door: its opening is left open.
        case opening
        /// Kept as a rigid obstacle, not part of the structure.
        case rigid
    }

    /// What became of one element.
    public struct Member: Sendable, Hashable, Codable, Identifiable {
        public var id: String
        /// Its source part (`ImportedMesh.BuildingElement.partID`).
        public var partID: Int
        public var name: String
        public var ifcClass: String
        public var role: Role
        /// Its index among the structure's solids, for shells, beams and panes.
        public var solid: Int?
        /// The material it was given, and where that came from.
        public var material: String?
        public var materialSource: String
        /// Whether its material is an assumption (the stated default), not read from the IFC.
        public var assumed: Bool
        public var notes: [String]
        /// Where a concrete shell's or beam's reinforcement came from, in words: the IFC's bars,
        /// its properties, or the stated default; nil for other members.
        public var reinforcementSource: String? = nil
        /// Whether that reinforcement is the stated default (or none), not read from the IFC; nil
        /// for other members and in reports saved before reinforcement was read.
        public var reinforcementAssumed: Bool? = nil
    }

    /// Two members tied where they meet.
    public struct Connection: Sendable, Hashable, Codable {
        public var first: String
        public var second: String
        public var kind: String
        /// The pair, in either order, as `Options.untied` holds it.
        public var key: String { Self.key(first, second) }
        public static func key(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
    }

    public struct Options: Sendable, Hashable, Codable {
        /// The shells' and beams' size, in metres.
        public var elementSize: Float
        /// The material of elements whose own cannot be read.
        public var defaultMaterial: StructureMaterial
        /// Reinforcement for concrete shells, as the area of bars per unit area of section in each
        /// face, both ways; nil for none. Never inferred: a stated default, flagged.
        public var reinforcement: Float?
        /// The base's connection where there are no footings, and between a wall or column and
        /// its footing.
        public var base: Anchorage
        /// Gaps between members up to this, in metres, are closed so that they are tied.
        public var gap: Float
        /// Pairs of members (`Connection.key`) the user chose to leave untied: the second is drawn
        /// back from the first by `untiedGap`.
        public var untied: Set<String>

        public init(
            elementSize: Float = 0.25, defaultMaterial: StructureMaterial = .reinforcedConcrete,
            reinforcement: Float? = nil, base: Anchorage = .dowelled(ratio: BaseConnection.dowelRatio),
            gap: Float = 0.1, untied: Set<String> = []
        ) {
            self.elementSize = elementSize
            self.defaultMaterial = defaultMaterial
            self.reinforcement = reinforcement
            self.base = base
            self.gap = gap
            self.untied = untied
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            elementSize = try c.decode(Float.self, forKey: .elementSize)
            defaultMaterial = try c.decode(StructureMaterial.self, forKey: .defaultMaterial)
            reinforcement = try c.decodeIfPresent(Float.self, forKey: .reinforcement)
            base = try c.decode(Anchorage.self, forKey: .base)
            gap = try c.decode(Float.self, forKey: .gap)
            untied = try c.decodeIfPresent(Set<String>.self, forKey: .untied) ?? []
        }
    }

    /// How far an untied member is drawn back from the other, in metres.
    public static let untiedGap: Float = 0.01

    public var model: StructureModel
    public var members: [Member]
    public var connections: [Connection]
    /// The supports, in words.
    public var supports: [String]
    /// Everything assumed rather than read from the IFC, in words.
    public var assumptions: [String]
    /// The turn about the vertical (radians, anticlockwise) and the shift applied to the building.
    public var yaw: Float
    public var shift: SIMD3<Float>

    /// The elements kept as rigid obstacles.
    public var rigidIDs: [String] { members.filter { $0.role == .rigid }.map(\.id) }

    /// What the conversion did, to keep with the import and show: its members, connections,
    /// supports and assumptions, and the parts kept as rigid obstacles.
    public struct Report: Sendable, Hashable, Codable {
        public var members: [Member]
        public var connections: [Connection]
        public var supports: [String]
        public var assumptions: [String]
        public var yaw: Float
        public var shift: SIMD3<Float>
        public var rigidParts: [Int] { members.filter { $0.role == .rigid }.map(\.partID) }
        /// The elements whose material is the stated default, not read from the IFC.
        public var assumedMaterials: [Member] { members.filter(\.assumed) }
    }

    public var report: Report {
        Report(
            members: members, connections: connections, supports: supports, assumptions: assumptions,
            yaw: yaw,
            shift: shift)
    }

    static let plateClasses: Set<String> = [
        "IfcWall", "IfcWallStandardCase", "IfcSlab", "IfcSlabStandardCase", "IfcRoof", "IfcPlate",
        "IfcPlateStandardCase",
    ]
    static let memberClasses: Set<String> = [
        "IfcColumn", "IfcColumnStandardCase", "IfcBeam", "IfcBeamStandardCase", "IfcMember",
        "IfcMemberStandardCase",
    ]
    static let paneThickness: Float = 0.006

    /// The structure of `elements` (in the scene's frame, metres, z up), with `options`; their
    /// materials as the IFC gives them (their own `materials`, else from `materials` by GlobalId),
    /// unless `chosen` gives one for its part; `modelID` ties each solid to its source element
    /// for editing.
    public init(
        elements: [ImportedMesh.BuildingElement], materials: [String: [Layer]] = [:],
        chosen: [Int: StructureMaterial] = [:], options: Options = Options(), modelID: UUID? = nil
    ) throws {
        guard options.elementSize.isFinite, options.elementSize > 0, options.gap.isFinite, options.gap >= 0
        else {
            throw ImportedMesh.ImportError.invalid("Choose a positive element size and a nonnegative gap.")
        }
        var assumptions: [String] = []
        var supportNotes: [String] = []
        let sorted = elements.sorted { $0.globalID < $1.globalID }
        guard !sorted.isEmpty else { throw ImportedMesh.ImportError.invalid("No IFC elements to convert.") }

        // Turn the building so that its walls lie along the axes.
        let all = sorted.flatMap { $0.mesh.triangles.flatMap { [$0.a, $0.b, $0.c] } }
        let low = all.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = all.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let centre = 0.5 * (low + high)
        var turn = SIMD2<Float>.zero
        for element in sorted where Self.family(element.ifcClass) == .plate {
            for t in element.mesh.triangles {
                let normal = simd_cross(t.b - t.a, t.c - t.a)
                let horizontal = SIMD2(normal.x, normal.y)
                let area = simd_length(horizontal)
                guard area > 1e-9 else { continue }
                let angle = 4 * atan2(horizontal.y, horizontal.x)
                turn += area * SIMD2(cos(angle), sin(angle))
            }
        }
        var yaw = simd_length(turn) > 0 ? atan2(turn.y, turn.x) / 4 : 0
        if abs(yaw) < 0.2 * .pi / 180 { yaw = 0 }
        if yaw != 0 {
            assumptions.append(
                "The building is turned \(Self.degrees(-yaw))° about the vertical so that its walls lie along the "
                    + "axes the shells are meshed on; its place in the scene turns with it.")
        }
        func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
            guard yaw != 0 else { return p }
            let (c, s) = (cos(-yaw), sin(-yaw))
            let d = p - centre
            return centre + SIMD3(c * d.x - s * d.y, s * d.x + c * d.y, d.z)
        }

        let shapes: [Shape] = sorted.map { element in
            let triangles = element.mesh.triangles.map {
                ImportedMesh.Triangle(a: rotate($0.a), b: rotate($0.b), c: rotate($0.c))
            }
            let points = triangles.flatMap { [$0.a, $0.b, $0.c] }
            let box = Box(
                min: points.reduce(SIMD3<Float>(repeating: .infinity), simd_min),
                max: points.reduce(SIMD3<Float>(repeating: -.infinity), simd_max))
            // Square to the axes: nine tenths of its surface faces along one of them (a wall's top
            // cut to a pitched roof is not).
            var square: Float = 0
            var total: Float = 0
            var volume: Float = 0
            for t in triangles {
                let normal = simd_cross(t.b - t.a, t.c - t.a)
                let area = simd_length(normal)
                guard area > 0 else { continue }
                total += area
                if simd_reduce_max(simd_abs(normal)) / area > cos(Float(3) * .pi / 180) { square += area }
                volume += simd_dot(t.a, simd_cross(t.b, t.c)) / 6
            }
            return Shape(
                element: element, triangles: triangles, box: box, aligned: total > 0 && square >= 0.9 * total,
                volume: abs(volume))
        }

        // The lowest base of the walls, slabs and members square to the axes, and the walls and
        // columns that start there.
        let candidates = shapes.filter {
            $0.aligned && [.plate, .member].contains(Self.family($0.element.ifcClass))
        }
        let lowest = candidates.map(\.box.min.z).min() ?? 0
        let uprights = candidates.filter { shape in
            let thin = (0..<3).min { shape.box.size[$0] < shape.box.size[$1] } ?? 0
            return thin != 2 && shape.box.min.z <= lowest + 1e-3
        }

        var members: [Member] = []
        var solids: [Box] = []
        var solidMaterials: [StructureMaterial] = []
        var solidParts: [StructureModel.SourcePart?] = []
        var openings: [Box] = []
        var footings: [(id: String, box: Box, material: StructureMaterial, shape: Shape)] = []
        var panes: [(index: Int, member: Int)] = []
        var grades: [(name: String, box: Box)] = []
        var windows: [Shape] = []

        /// Each solid's whole element, finishes and all: a gap to a wall's trimmed layers is no gap.
        var envelopes: [Box] = []
        func add(_ box: Box, _ material: StructureMaterial, _ shape: Shape) -> Int {
            solids.append(box)
            envelopes.append(shape.box)
            solidMaterials.append(material)
            solidParts.append(
                modelID.map { StructureModel.SourcePart(modelID: $0, partID: shape.element.partID) })
            return solids.count - 1
        }

        for shape in shapes {
            let element = shape.element
            var member = Member(
                id: element.globalID, partID: element.partID, name: element.name, ifcClass: element.ifcClass,
                role: .rigid, solid: nil,
                material: nil, materialSource: "", assumed: false, notes: [])
            let extent = shape.box.size
            let thin = (0..<3).min { extent[$0] < extent[$1] } ?? 0
            let long = (0..<3).max { extent[$0] < extent[$1] } ?? 2
            let layers = element.materials ?? materials[element.globalID] ?? []
            func read() -> Reading {
                if let picked = chosen[element.partID] {
                    return Reading(
                        material: picked, source: "Chosen: \(picked.name)", assumed: false,
                        thickness: Self.material(of: layers, default: picked).thickness, notes: [])
                }
                return Self.material(of: layers, default: options.defaultMaterial)
            }
            // An element whose every layer is a finish, or that is named one, carries nothing.
            let finishes =
                (!layers.isEmpty && layers.allSatisfy { Self.classify($0.name) == .nonstructural })
                || element.name.localizedCaseInsensitiveContains("finish")
            switch Self.family(element.ifcClass) {
            case .plate:
                guard shape.aligned else {
                    member.notes.append(
                        "Not square to the axes (inclined or curved): kept as a rigid obstacle.")
                    break
                }
                guard (0..<3).allSatisfy({ $0 == thin || extent[thin] <= 0.5 * extent[$0] }) else {
                    member.notes.append(
                        "Not plate-like (\(Self.metres(extent))): kept as a rigid obstacle.")
                    break
                }
                if finishes && chosen[element.partID] == nil {
                    member.notes.append(
                        "A finish (\(layers.isEmpty ? element.name : layers.map(\.name).joined(separator: ", "))): kept "
                            + "as a rigid obstacle, not load-bearing.")
                    break
                }
                // A slab on grade that walls or columns pass through to the ground is not part of
                // the frame: they stand on the ground through it.
                if thin == 2, shape.box.min.z <= lowest + 1e-3,
                    uprights.contains(where: { u in
                        u.element.globalID != element.globalID
                            && (0..<2).allSatisfy {
                                u.box.max[$0] > shape.box.min[$0] && u.box.min[$0] < shape.box.max[$0]
                            }
                    })
                {
                    member.notes.append(
                        "A slab on grade, walls standing on the ground through it: kept as a rigid obstacle, not "
                            + "tied to them.")
                    grades.append((element.name, shape.box))
                    break
                }
                let reading = read()
                var box = shape.box
                if let thickness = reading.thickness, thickness < extent[thin] - 1e-3 {
                    let mid = 0.5 * (box.min[thin] + box.max[thin])
                    box.min[thin] = mid - thickness / 2
                    box.max[thin] = mid + thickness / 2
                    member.notes.append(
                        "Shell \(Self.millimetres(thickness)) thick, its structural layer, of "
                            + "\(Self.millimetres(extent[thin])) overall.")
                } else {
                    member.notes.append("Shell \(Self.millimetres(extent[thin])) thick, from its geometry.")
                }
                member.notes += reading.notes
                member.role = .shell
                member.solid = add(box, reading.material, shape)
                member.material = reading.material.name
                member.materialSource = reading.source
                member.assumed = reading.assumed
                let holes = Self.holes(
                    in: shape, box: shape.box, axis: thin, spacing: options.elementSize / 2)
                openings += holes
                if !holes.isEmpty {
                    member.notes.append(
                        "\(holes.count) opening\(holes.count == 1 ? "" : "s") or cut-out\(holes.count == 1 ? "" : "s") through it."
                    )
                }
            case .member:
                guard shape.aligned else {
                    member.notes.append("Not square to the axes (inclined): kept as a rigid obstacle.")
                    break
                }
                let across = (0..<3).filter { $0 != long }
                guard across.allSatisfy({ extent[$0] > 0 && 2 * extent[$0] <= extent[long] }) else {
                    member.notes.append("Not member-like (\(Self.metres(extent))): kept as a rigid obstacle.")
                    break
                }
                var reading = read()
                var box = shape.box
                let full = extent.x * extent.y * extent.z
                let fill = full > 0 ? shape.volume / full : 1
                let narrow = across.min { extent[$0] < extent[$1] } ?? across[0]
                let deep = across.first { $0 != narrow } ?? across[0]
                let depth = extent[deep]
                if fill < 0.5 {
                    // A flanged section: a rectangle 0.6 of its depth wide (the beam a beam
                    // element can be), of a material whose stiffness, density and strength make it
                    // as stiff and strong in bending, and as heavy, as a wide-flange shape of the
                    // same area and depth, for which I ≈ 0.175 A d² and Z ≈ 0.40 A d.
                    let area = fill * extent[narrow] * depth
                    let width = 0.6 * depth
                    let mid = 0.5 * (box.min[narrow] + box.max[narrow])
                    box.min[narrow] = mid - width / 2
                    box.max[narrow] = mid + width / 2
                    let rectangle = width * depth
                    var equivalent = reading.material
                    equivalent.name += " (flanged \(Self.millimetres(depth)))"
                    equivalent.youngsModulus *=
                        0.175 * area * depth * depth / (width * depth * depth * depth / 12)
                    equivalent.density *= area / rectangle
                    equivalent.yieldStress *= 0.40 * area * depth / (width * depth * depth / 4)
                    reading.material = equivalent
                    member.notes.append(
                        "A flanged section (\(Int((fill * 100).rounded()))% of its bounds): a rectangle 0.6 of its depth wide "
                            + "stands for it, its material scaled to the bending stiffness, strength and mass of a "
                            + "wide-flange shape of its area and depth; its axial stiffness is about twice the shape's."
                    )
                } else if fill < 0.9 {
                    // Keep its volume: the narrower side scaled to the section's area.
                    let width = extent[narrow] * fill
                    let mid = 0.5 * (box.min[narrow] + box.max[narrow])
                    box.min[narrow] = mid - width / 2
                    box.max[narrow] = mid + width / 2
                    member.notes.append(
                        "Its section fills \(Int((fill * 100).rounded()))% of its bounds: a rectangle of the same "
                            + "depth and area stands for it.")
                }
                member.notes += reading.notes
                member.role = .beam
                member.solid = add(box, reading.material, shape)
                member.material = reading.material.name
                member.materialSource = reading.source
                member.assumed = reading.assumed
            case .footing:
                guard shape.aligned else {
                    member.notes.append("Not square to the axes: left out.")
                    member.role = .rigid
                    break
                }
                let reading = read()
                footings.append((element.globalID, shape.box, reading.material, shape))
                member.role = .footing
                member.material = reading.material.name
                member.materialSource = reading.source
                member.assumed = reading.assumed
            case .window:
                member.role = .opening
                windows.append(shape)
                let glass = (layers.map(\.name) + [element.name]).contains {
                    Self.classify($0) == .glass || $0.localizedCaseInsensitiveContains("glaz")
                }
                if glass {
                    member.role = .pane
                    member.notes.append("Glazed: a pane of annealed glass in its opening.")
                } else {
                    member.notes.append("No glass named in the IFC: its opening is left open.")
                }
            case .door:
                member.role = .opening
                member.notes.append("A door: its opening is left open.")
            case .other:
                member.notes.append("Not a wall, slab, member or footing: kept as a rigid obstacle.")
            }
            members.append(member)
        }

        // Panes: in the opening of the wall the window sits in, on the wall's midsurface.
        for (n, member) in members.enumerated() where member.role == .pane {
            guard let window = windows.first(where: { $0.element.globalID == member.id }),
                let host = members.indices.first(where: { m in
                    members[m].role == .shell
                        && members[m].solid.map { Self.contains(solids[$0], window.box.centre) } == true
                }), let hostSolid = members[host].solid
            else {
                members[n].role = .opening
                members[n].notes.append("No wall around it: left open.")
                continue
            }
            let wall = solids[hostSolid]
            let axis = (0..<3).min { wall.size[$0] < wall.size[$1] } ?? 0
            let layers = window.element.materials ?? materials[member.id] ?? []
            let thickness = layers.first { Self.classify($0.name) == .glass }?.thickness ?? Self.paneThickness
            if layers.first(where: { Self.classify($0.name) == .glass })?.thickness == nil {
                members[n].notes.append("Its glass taken as \(Self.millimetres(thickness)) thick (assumed).")
            }
            var pane = window.box
            for k in 0..<3 where k != axis {
                pane.min[k] = max(pane.min[k], wall.min[k])
                pane.max[k] = min(pane.max[k], wall.max[k])
            }
            let mid = 0.5 * (wall.min[axis] + wall.max[axis])
            pane.min[axis] = mid - thickness / 2
            pane.max[axis] = mid + thickness / 2
            guard (0..<3).allSatisfy({ $0 == axis || pane.size[$0] > options.elementSize / 2 }) else {
                members[n].role = .opening
                members[n].notes.append("Smaller than half an element: left open.")
                continue
            }
            let index = add(pane, .annealedGlass, window)
            members[n].solid = index
            members[n].material = StructureMaterial.annealedGlass.name
            members[n].materialSource = "IFC: glazed"
            panes.append((index, n))
        }

        // Close small gaps, so that members that meet are tied.
        let structural = members.indices.filter { members[$0].solid != nil }
        var closed: [String] = []
        func thinAxis(_ box: Box) -> Int { (0..<3).min { box.size[$0] < box.size[$1] } ?? 0 }
        for a in structural {
            for b in structural where a != b {
                guard let i = members[a].solid, let j = members[b].solid else { continue }
                for k in 0..<3 where k != thinAxis(solids[i]) || members[a].role == .beam {
                    let others = (0..<3).filter { $0 != k }
                    guard
                        others.allSatisfy({
                            solids[i].max[$0] > solids[j].min[$0] + 1e-4
                                && solids[j].max[$0] > solids[i].min[$0] + 1e-4
                        })
                    else { continue }
                    let above = solids[j].min[k] - solids[i].max[k]
                    let below = solids[i].min[k] - solids[j].max[k]
                    // Measured to the other's whole element where it is a shell of its structural layer.
                    let envelope = members[b].role == .shell ? envelopes[j] : solids[j]
                    if above > 1e-4 && envelope.min[k] - solids[i].max[k] <= options.gap {
                        solids[i].max[k] = solids[j].min[k]
                        closed.append("\(members[a].name) to \(members[b].name), \(Self.millimetres(above))")
                    } else if below > 1e-4 && solids[i].min[k] - envelope.max[k] <= options.gap {
                        solids[i].min[k] = solids[j].max[k]
                        closed.append("\(members[a].name) to \(members[b].name), \(Self.millimetres(below))")
                    }
                }
            }
        }
        if !closed.isEmpty {
            assumptions.append(
                "Gaps closed so that members are tied: " + closed.prefix(12).joined(separator: "; ")
                    + (closed.count > 12 ? "; and \(closed.count - 12) more." : "."))
        }

        // Slabs a little apart in level are put on one midsurface, the smaller moved to the
        // larger's, with the ends of members that stand on them or hang from them: the mesh's
        // levels run through the whole building, so two near ones leave slivers in every wall
        // that crosses both.
        var aligned: [String] = []
        let plates = structural.filter { members[$0].role == .shell }.compactMap { a in
            members[a].solid.map { (member: a, solid: $0) }
        }.filter { thinAxis(solids[$0.solid]) == 2 }
        for (x, a) in plates.enumerated() {
            for b in plates[(x + 1)...] {
                let (i, j) = (a.solid, b.solid)
                let offset =
                    0.5 * (solids[i].min.z + solids[i].max.z) - 0.5 * (solids[j].min.z + solids[j].max.z)
                guard abs(offset) > 1e-4,
                    abs(offset)
                        <= min(0.5 * min(solids[i].size.z, solids[j].size.z), 0.25 * options.elementSize)
                else { continue }
                let area = { (n: Int) in solids[n].size.x * solids[n].size.y }
                let (moved, by) = area(i) < area(j) ? (a, -offset) : (b, offset)
                let old = solids[moved.solid]
                for other in structural {
                    guard let n = members[other].solid, n != moved.solid,
                        thinAxis(solids[n]) != 2 || members[other].role == .beam,
                        (0..<2).allSatisfy({
                            solids[n].max[$0] >= old.min[$0] - 1e-4 && old.max[$0] >= solids[n].min[$0] - 1e-4
                        })
                    else { continue }
                    if abs(solids[n].min.z - old.max.z) < 1e-4 { solids[n].min.z += by }
                    if abs(solids[n].max.z - old.min.z) < 1e-4 { solids[n].max.z += by }
                }
                solids[moved.solid].min.z += by
                solids[moved.solid].max.z += by
                aligned.append("\(members[moved.member].name) by \(Self.millimetres(abs(by)))")
            }
        }
        if !aligned.isEmpty {
            assumptions.append(
                "Slabs a little apart in level put on one midsurface: "
                    + aligned.prefix(12).joined(separator: "; ")
                    + (aligned.count > 12 ? "; and \(aligned.count - 12) more." : "."))
        }

        // Pairs the user untied: the second drawn back from the first along the axis they overlap
        // least, so that the mesh does not join them.
        func touching(_ i: Int, _ j: Int) -> Bool {
            (0..<3).allSatisfy {
                solids[i].max[$0] >= solids[j].min[$0] - 1e-4 && solids[j].max[$0] >= solids[i].min[$0] - 1e-4
            }
        }
        var untiedPairs = Set<String>()
        for (x, a) in structural.enumerated() {
            for b in structural[(x + 1)...] {
                let key = Connection.key(members[a].id, members[b].id)
                guard options.untied.contains(key), var i = members[a].solid, var j = members[b].solid,
                    touching(i, j)
                else { continue }
                let overlap = (0..<3).map {
                    min(solids[i].max[$0], solids[j].max[$0]) - max(solids[i].min[$0], solids[j].min[$0])
                }
                let k = (0..<3).min { overlap[$0] < overlap[$1] } ?? 0
                // The one whose end meets the other's face is drawn back, else the smaller; a
                // slab's face moved would leave all it carries.
                let ends = { (n: Int) in members[n].role == .beam || thinAxis(solids[n]) != k }
                let volume = { (n: Int) in solids[n].size.x * solids[n].size.y * solids[n].size.z }
                if ends(a) && !ends(b) || ends(a) == ends(b) && volume(i) < volume(j) { swap(&i, &j) }
                var moved = solids[j]
                if 0.5 * (moved.min[k] + moved.max[k]) >= 0.5 * (solids[i].min[k] + solids[i].max[k]) {
                    moved.min[k] = solids[i].max[k] + Self.untiedGap
                } else {
                    moved.max[k] = solids[i].min[k] - Self.untiedGap
                }
                guard moved.max[k] - moved.min[k] > 1e-3 else { continue }
                solids[j] = moved
                untiedPairs.insert(key)
            }
        }

        // Connections: members that touch or overlap share the mesh's nodes there.
        var connections: [Connection] = []
        for (x, a) in structural.enumerated() {
            for b in structural[(x + 1)...] {
                guard let i = members[a].solid, let j = members[b].solid else { continue }
                if untiedPairs.contains(Connection.key(members[a].id, members[b].id)) {
                    connections.append(
                        Connection(
                            first: members[a].id, second: members[b].id,
                            kind:
                                "\(Self.kind(members[a], solids[i]))–\(Self.kind(members[b], solids[j])), untied by choice, "
                                + "\(Self.millimetres(Self.untiedGap)) apart"))
                    continue
                }
                guard touching(i, j) else { continue }
                connections.append(
                    Connection(
                        first: members[a].id, second: members[b].id,
                        kind:
                            "\(Self.kind(members[a], solids[i]))–\(Self.kind(members[b], solids[j])), tied rigidly"
                    ))
            }
        }
        let tied = connections.filter { !untiedPairs.contains($0.key) }
        if !tied.isEmpty {
            assumptions.append(
                "\(tied.count) connections inferred where members meet, each tied rigidly (the shells share "
                    + "nodes); none was read from the IFC.")
        }

        // The base: footings' tops, or the lowest member.
        let bodies = structural.compactMap { members[$0].solid }.filter { !panes.map(\.index).contains($0) }
        guard !bodies.isEmpty else {
            throw ImportedMesh.ImportError.invalid(
                "No IFC element could be meshed as a shell or beam: walls, slabs and members must be flat, square to "
                    + "the axes and plate- or member-like.")
        }
        let base = bodies.map { solids[$0].min.z }.min() ?? 0
        let shift = SIMD3<Float>(0, 0, -base)
        for n in solids.indices {
            solids[n].min += shift
            solids[n].max += shift
        }
        for n in openings.indices {
            openings[n].min += shift
            openings[n].max += shift
        }
        if abs(base) > 1e-4 {
            assumptions.append(
                "The structure stands with its lowest member on the ground: lowered \(Self.metres(base)) from its placed "
                    + "height\(footings.isEmpty ? "" : ", its footings below the ground").")
        }

        var model = StructureModel(
            solids: solids, material: options.defaultMaterial, elementSize: options.elementSize)
        model.elementKind = .shell
        model.openings = openings
        model.solidMaterial = solidMaterials.map { $0 == options.defaultMaterial ? nil : $0 }
        model.solidSourceParts = modelID == nil ? [] : solidParts
        model.solidReinforcement = Array(repeating: .none, count: solids.count)

        // Footings: under each wall or column that stands on one, its own, set into the soil.
        var standing = Set<Int>()
        for footing in footings {
            let top = footing.box.max.z + shift.z
            var plan = footing.box
            plan.min += shift
            plan.max += shift
            var carried = 0
            for (n, member) in members.enumerated() where member.role == .shell || member.role == .beam {
                guard let index = member.solid else { continue }
                let box = solids[index]
                guard abs(box.min.z - top) <= options.gap + 1e-3, box.max.x > plan.min.x,
                    box.min.x < plan.max.x,
                    box.max.y > plan.min.y, box.min.y < plan.max.y,
                    thinAxis(box) != 2 || member.role == .beam
                else { continue }
                var region = Box(
                    min: SIMD3(
                        max(box.min.x, plan.min.x) - 0.01, max(box.min.y, plan.min.y) - 0.01, box.min.z - 0.01
                    ),
                    max: SIMD3(
                        min(box.max.x, plan.max.x) + 0.01, min(box.max.y, plan.max.y) + 0.01, box.min.z + 0.01
                    ))
                region.min.z = box.min.z - 0.01
                // How far the footing reaches past the member on each side, measured on the
                // footing's own plan at the member's middle: across a wall only (a strip footing
                // runs on along it), both ways under a column; the lesser side, as the model's
                // footing is centred.
                let middle = 0.5 * (box.min + box.max) - shift
                var overhang = SIMD2<Float>.zero
                for axis in 0..<2 where member.role == .beam || axis == thinAxis(box) {
                    let reach = (
                        Self.reach(of: footing.shape, from: middle, axis: axis, direction: -1),
                        Self.reach(of: footing.shape, from: middle, axis: axis, direction: 1)
                    )
                    overhang[axis] = max(0, min(reach.0, reach.1) - box.size[axis] / 2)
                }
                var law = options.base
                law.footing = Footing(
                    overhang: overhang, thickness: footing.box.size.z, density: footing.material.density,
                    soil: Soil(), embedment: top <= 1e-3 ? Embedment(depth: footing.box.size.z) : nil)
                model.supports.append(region)
                model.supportAnchorages.append(law)
                standing.insert(n)
                carried += 1
            }
            let name = members.first { $0.id == footing.id }?.name ?? footing.id
            if carried == 0 {
                supportNotes.append("\(name): nothing stands on it; left out.")
            } else {
                supportNotes.append(
                    "\(name): a footing \(Self.metres(footing.box.size.z)) deep under each of the \(carried) members on it, "
                        + "set into medium dense sand (assumed), tied to them by \(BaseConnection(options.base).title.lowercased())."
                )
            }
        }
        if !footings.isEmpty {
            assumptions.append(
                "Footings stand on the default soil, a medium dense sand, set into it by their own depth; the soil is not "
                    + "in the IFC.")
        }
        // Members at the base with no footing under them are tied to the ground by the stated
        // connection.
        if !standing.isEmpty {
            for (n, member) in members.enumerated()
            where (member.role == .shell || member.role == .beam) && !standing.contains(n) {
                guard let index = member.solid else { continue }
                let box = solids[index]
                guard box.min.z <= 1e-3, thinAxis(box) != 2 || member.role == .beam else { continue }
                model.supports.append(
                    Box(
                        min: SIMD3(box.min.x - 0.01, box.min.y - 0.01, -0.01),
                        max: SIMD3(box.max.x + 0.01, box.max.y + 0.01, 0.01)))
                model.supportAnchorages.append(options.base)
                supportNotes.append(
                    "\(member.name): no footing under it; tied to the ground by \(BaseConnection(options.base).title.lowercased()) (assumed)."
                )
            }
        }
        // Without footings, the base is tied to the ground by the stated connection.
        if footings.isEmpty || standing.isEmpty {
            model.fixedBase = true
            model.baseAnchorage = options.base
            supportNotes.append(
                "The base on the ground, tied to it by \(BaseConnection(options.base).title.lowercased()) (assumed)."
            )
        } else {
            model.fixedBase = false
        }
        // Members standing on a slab on grade are tied to it as to the ground.
        for grade in grades {
            let top = grade.box.max.z + shift.z
            for (n, member) in members.enumerated() where member.role == .shell || member.role == .beam {
                guard let index = member.solid else { continue }
                let box = solids[index]
                guard abs(box.min.z - top) <= options.gap + 1e-3, box.min.z > 1e-3,
                    (0..<2).allSatisfy({ box.max[$0] > grade.box.min[$0] && box.min[$0] < grade.box.max[$0] }
                    ),
                    thinAxis(box) != 2 || member.role == .beam
                else { continue }
                model.supports.append(
                    Box(
                        min: SIMD3(box.min.x - 0.01, box.min.y - 0.01, box.min.z - 0.01),
                        max: SIMD3(box.max.x + 0.01, box.max.y + 0.01, box.min.z + 0.01)))
                model.supportAnchorages.append(options.base)
                standing.insert(n)
                supportNotes.append(
                    "\(member.name): stands on \(grade.name), the slab on grade, tied to it as to the ground by "
                        + "\(BaseConnection(options.base).title.lowercased()) (assumed).")
            }
        }
        // Slabs on the ground rest on it.
        for member in members where member.role == .shell {
            guard let index = member.solid else { continue }
            let box = solids[index]
            guard thinAxis(box) == 2, box.min.z <= options.gap + 1e-3 else { continue }
            model.supports.append(
                Box(
                    min: SIMD3(box.min.x - 0.01, box.min.y - 0.01, box.min.z - 0.01),
                    max: SIMD3(box.max.x + 0.01, box.max.y + 0.01, box.min.z + 0.01)))
            model.supportAnchorages.append(.resting())
            supportNotes.append(
                "\(member.name): rests on the ground with friction 0.6 (assumed)"
                    + (box.min.z > 1e-3
                        ? ", the ground taken to reach its soffit \(Self.millimetres(box.min.z)) up." : "."))
        }

        // Walls and columns of the lowest storey with nothing under them stand on foundations the
        // IFC leaves out: tied to the ground at their base by the stated connection.
        func storey(_ n: Int) -> String? { shapes[n].element.storey }
        let lowestMember = members.indices.filter { members[$0].solid.map(bodies.contains) == true }
            .min { solids[members[$0].solid!].min.z < solids[members[$1].solid!].min.z }
        let groundStorey = lowestMember.flatMap(storey)
        for (n, member) in members.enumerated() where member.role == .shell || member.role == .beam {
            guard let index = member.solid, !standing.contains(n) else { continue }
            let box = solids[index]
            let upright =
                member.role == .shell ? thinAxis(box) != 2 : (0..<3).max { box.size[$0] < box.size[$1] } == 2
            guard upright, box.min.z > 1e-3,
                groundStorey.map { storey(n) == $0 } ?? (box.min.z <= 0.5),
                !bodies.contains(where: { j in
                    j != index && abs(solids[j].max.z - box.min.z) <= 1e-3
                        && (0..<2).allSatisfy {
                            solids[j].max[$0] > box.min[$0] + 1e-4 && box.max[$0] > solids[j].min[$0] + 1e-4
                        }
                })
            else { continue }
            // The mesh carries an edge ending inside a slab's thickness down to its midsurface.
            let drop =
                bodies.filter {
                    thinAxis(solids[$0]) == 2 && solids[$0].min.z < box.min.z - 1e-4
                        && solids[$0].max.z > box.min.z - 1e-4
                }
                .map { box.min.z - 0.5 * (solids[$0].min.z + solids[$0].max.z) }.max() ?? 0
            model.supports.append(
                Box(
                    min: SIMD3(box.min.x - 0.01, box.min.y - 0.01, box.min.z - max(0, drop) - 0.01),
                    max: SIMD3(box.max.x + 0.01, box.max.y + 0.01, box.min.z + 0.01)))
            model.supportAnchorages.append(options.base)
            supportNotes.append(
                "\(member.name): on the lowest storey with nothing under it in the IFC, its foundation left out; tied to "
                    + "the ground \(Self.millimetres(box.min.z)) up by \(BaseConnection(options.base).title.lowercased()) (assumed)."
            )
        }

        // Reinforcement, member by member: the IFC's bars where it gives them, else the ratio its
        // properties give, else the stated default (in shells), flagged.
        var counts = (bars: 0, properties: 0, defaulted: 0, none: 0)
        for m in members.indices where members[m].role == .shell || members[m].role == .beam {
            guard let index = members[m].solid, solidMaterials[index].model == .concrete,
                solidMaterials[index].units == nil, !solidMaterials[index].isTransparent
            else { continue }
            let box = solids[index]
            let isShell = members[m].role == .shell
            let hosted = shapes.first { $0.element.globalID == members[m].id }?.element.reinforcement
            if let hosted,
                let read = IFCReinforcement.layers(
                    for: hosted, box: box, isShell: isShell, elementSize: options.elementSize,
                    transform: rotate)
            {
                model.reinforcement += read.layers
                members[m].reinforcementSource = read.description
                members[m].reinforcementAssumed = false
                if hosted.bars.isEmpty { counts.properties += 1 } else { counts.bars += 1 }
            } else if let ratio = options.reinforcement, isShell {
                let axis = thinAxis(box)
                model.addMat(
                    to: IFCReinforcement.matRegion(box, elementSize: options.elementSize),
                    thicknessAxis: axis,
                    areaPerMetre: ratio * box.size[axis] / 2, depth: min(0.04, box.size[axis] / 4))
                members[m].reinforcementSource =
                    "Default: \(String(format: "%.2f", ratio * 100))% in each face both ways, none being in the IFC "
                    + "(assumed)."
                members[m].reinforcementAssumed = true
                counts.defaulted += 1
            } else {
                members[m].reinforcementSource =
                    (hosted?.bars.isEmpty == false
                        ? "None: its bars in the IFC run neither along it nor across a face."
                        : "None: the IFC gives none")
                    + (options.reinforcement != nil && !isShell
                        ? ", and the default reinforces shells only." : ".")
                members[m].reinforcementAssumed = true
                counts.none += 1
            }
        }
        if counts.bars + counts.properties > 0 {
            assumptions.append(
                "Reinforcement read from the IFC in \(counts.bars + counts.properties) concrete "
                    + "member\(counts.bars + counts.properties == 1 ? "" : "s")"
                    + (counts.properties > 0
                        ? " (\(counts.properties) from its properties' ratios alone)" : "")
                    + "; bars merged into mats and at most eight bars a beam (see each member).")
        }
        if counts.defaulted > 0, let ratio = options.reinforcement {
            assumptions.append(
                "\(counts.defaulted) concrete shell\(counts.defaulted == 1 ? "" : "s") reinforced with "
                    + "\(String(format: "%.2f", ratio * 100))% of bars in each face both ways: a stated default, the IFC "
                    + "giving none.")
        }
        if counts.none > 0 {
            assumptions.append(
                "\(counts.none) concrete member\(counts.none == 1 ? "" : "s") unreinforced: the IFC gives no "
                    + "reinforcement for \(counts.none == 1 ? "it" : "them")"
                    + (options.reinforcement == nil
                        ? " and none was asked for." : " and the default reinforces shells only."))
        }

        let assumed = members.filter(\.assumed)
        if !assumed.isEmpty {
            assumptions.append(
                "\(assumed.count) element\(assumed.count == 1 ? "" : "s") of the default material, "
                    + "\(options.defaultMaterial.name), their own not being one the solver has: "
                    + assumed.prefix(8).map(\.name).joined(separator: ", ") + (assumed.count > 8 ? ", …" : "")
                    + ".")
        }
        guard model.materials.count <= StructureModel.maxMaterials else {
            throw ImportedMesh.ImportError.invalid(
                "The building needs \(model.materials.count) materials, more than the solver's \(StructureModel.maxMaterials)."
            )
        }
        self.model = model
        self.members = members
        self.connections = connections
        self.supports = supportNotes
        self.assumptions = assumptions
        self.yaw = -yaw
        self.shift = shift
    }

    /// An element turned into the structure's frame.
    struct Shape {
        var element: ImportedMesh.BuildingElement
        var triangles: [ImportedMesh.Triangle]
        var box: Box
        var aligned: Bool
        var volume: Float
    }

    // MARK: - Classification

    enum Family { case plate, member, footing, window, door, other }

    static func family(_ ifcClass: String) -> Family {
        if plateClasses.contains(ifcClass) { return .plate }
        if memberClasses.contains(ifcClass) { return .member }
        if ifcClass == "IfcFooting" { return .footing }
        if ifcClass.hasPrefix("IfcWindow") { return .window }
        if ifcClass.hasPrefix("IfcDoor") { return .door }
        return .other
    }

    enum Kind { case concrete, block, masonry, steel, glass, timber, nonstructural, unknown }

    /// What a material's name says it is.
    static func classify(_ name: String) -> Kind {
        let n = name.lowercased()
        func has(_ words: String...) -> Bool { words.contains { n.contains($0) } }
        if has(
            "air", "insulation", "plaster", "gypsum", "membrane", "finish", "render", "paint", "carpet",
            "vapour",
            "vapor", "damp", "cladding", "screed", "stud", "virtual", "tile", "board")
        {
            return .nonstructural
        }
        if has("glass", "glazing") { return .glass }
        if has("block", "cmu", "breeze") { return .block }
        if has("brick", "masonry", "stone", "sand-lime", "sandlime", "calcium silicate", "clay") {
            return .masonry
        }
        if has("concrete", "beton", "béton") { return .concrete }
        if has("steel", "stahl", "metal", "iron") { return .steel }
        if has("wood", "timber", "spruce", "pine", "oak", "glulam", "lumber", "holz") { return .timber }
        return .unknown
    }

    struct Reading {
        var material: StructureMaterial
        var source: String
        var assumed: Bool
        var thickness: Float?
        var notes: [String]
    }

    /// The material and structural thickness `layers` give, or the default.
    static func material(of layers: [Layer], default fallback: StructureMaterial) -> Reading {
        let structural = layers.filter {
            ![.nonstructural, .unknown, .timber, .glass].contains(classify($0.name))
        }
        var notes: [String] = []
        let chosen = structural.max { ($0.thickness ?? 0) < ($1.thickness ?? 0) }
        if let chosen, structural.count > 1 {
            notes.append(
                "Of its \(structural.count) load-bearing layers (\(structural.map(\.name).joined(separator: ", "))), one of "
                    + "\(chosen.name) is taken; the others are left out, mass and all.")
        }
        guard let chosen else {
            let named = layers.map(\.name).filter { !$0.isEmpty }
            let why =
                named.isEmpty
                ? "no material in the IFC"
                : layers.contains { classify($0.name) == .timber }
                    ? "timber (\(named.joined(separator: ", "))), which the solver has no model of"
                    : "\(named.joined(separator: ", ")) not recognised as a load-bearing material"
            return Reading(
                material: fallback, source: "Assumed: \(why)", assumed: true, thickness: nil, notes: [])
        }
        let material: StructureMaterial
        switch classify(chosen.name) {
        case .concrete:
            if let grade = grade(in: chosen.name) {
                var named = StructureMaterial.concrete(
                    name: "Concrete C\(Int(grade))", compressiveStrength: grade * 1e6, steel: .grade500)
                named.rateDependent = true
                material = named
            } else {
                material = .reinforcedConcrete
                notes.append("No grade in its name: taken as 30 MPa concrete (assumed).")
            }
        case .block: material = .concreteBlock
        case .masonry: material = .masonry
        case .steel: material = .structuralSteel
        default: material = fallback
        }
        return Reading(
            material: material, source: "IFC: \(chosen.name) → \(material.name)", assumed: false,
            thickness: chosen.thickness, notes: notes)
    }

    /// A concrete grade's characteristic strength in MPa, from a name such as "C30/37" or "C25".
    static func grade(in name: String) -> Float? {
        guard let match = name.range(of: #"(?i)\bC(\d{2,3})(/\d{2,3})?\b"#, options: .regularExpression)
        else {
            return nil
        }
        let digits = name[match].dropFirst().prefix { $0.isNumber }
        return Float(String(digits))
    }

    // MARK: - Geometry

    /// Holes through a plate: rectangles of its plane through which a ray across it meets none
    /// of its faces, sampled every `spacing`, as boxes through its thickness.
    static func holes(in shape: Shape, box: Box, axis k: Int, spacing: Float) -> [Box] {
        let (i, j) = ((k + 1) % 3, (k + 2) % 3)
        let ni = min(800, max(1, Int((box.size[i] / spacing).rounded(.up))))
        let nj = min(800, max(1, Int((box.size[j] / spacing).rounded(.up))))
        let di = box.size[i] / Float(ni)
        let dj = box.size[j] / Float(nj)
        // Triangles facing across the plate, binned by the rows of samples they span.
        let facing = shape.triangles.filter { t in
            let normal = simd_cross(t.b - t.a, t.c - t.a)
            return abs(normal[k]) > 1e-9 * simd_length(normal)
        }
        var rows = [[Int]](repeating: [], count: nj)
        for (n, t) in facing.enumerated() {
            let lo = min(t.a[j], t.b[j], t.c[j])
            let hi = max(t.a[j], t.b[j], t.c[j])
            let a = max(0, Int(((lo - box.min[j]) / dj).rounded(.down)))
            let b = min(nj - 1, Int(((hi - box.min[j]) / dj).rounded(.down)))
            if a <= b { for r in a...b { rows[r].append(n) } }
        }
        func inside(_ u: Float, _ v: Float, _ t: ImportedMesh.Triangle) -> Bool {
            let p = SIMD2(u, v)
            let a = SIMD2(t.a[i], t.a[j])
            let b = SIMD2(t.b[i], t.b[j])
            let c = SIMD2(t.c[i], t.c[j])
            func side(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
                (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
            }
            let d1 = side(a, b, p)
            let d2 = side(b, c, p)
            let d3 = side(c, a, p)
            let negative = d1 < 0 || d2 < 0 || d3 < 0
            let positive = d1 > 0 || d2 > 0 || d3 > 0
            return !(negative && positive)
        }
        var empty = [[Bool]](repeating: [Bool](repeating: false, count: ni), count: nj)
        for r in 0..<nj {
            let v = box.min[j] + (Float(r) + 0.5) * dj
            for c in 0..<ni {
                let u = box.min[i] + (Float(c) + 0.5) * di
                empty[r][c] = !rows[r].contains { inside(u, v, facing[$0]) }
            }
        }
        // Greedy rectangles of empty samples.
        var holes: [Box] = []
        for r in 0..<nj {
            var c = 0
            while c < ni {
                guard empty[r][c] else {
                    c += 1
                    continue
                }
                var c1 = c
                while c1 < ni && empty[r][c1] { c1 += 1 }
                var r1 = r + 1
                while r1 < nj && (c..<c1).allSatisfy({ empty[r1][$0] }) { r1 += 1 }
                for rr in r..<r1 { for cc in c..<c1 { empty[rr][cc] = false } }
                var hole = box
                hole.min[i] = box.min[i] + Float(c) * di
                hole.max[i] = box.min[i] + Float(c1) * di
                hole.min[j] = box.min[j] + Float(r) * dj
                hole.max[j] = box.min[j] + Float(r1) * dj
                hole.min[k] -= 0.01
                hole.max[k] += 0.01
                holes.append(hole)
                c = c1
            }
        }
        return holes
    }

    /// How far a footing's plan reaches from `point` along `axis` one way, sampled every 25 mm
    /// with rays down through it.
    static func reach(of shape: Shape, from point: SIMD3<Float>, axis: Int, direction: Float) -> Float {
        let step: Float = 0.025
        var distance: Float = 0
        while distance < 20 {
            var probe = point
            probe[axis] += direction * (distance + step / 2)
            let hit = shape.triangles.contains { t in
                let normal = simd_cross(t.b - t.a, t.c - t.a)
                guard abs(normal.z) > 1e-9 * simd_length(normal) else { return false }
                let p = SIMD2(probe.x, probe.y)
                let a = SIMD2(t.a.x, t.a.y)
                let b = SIMD2(t.b.x, t.b.y)
                let c = SIMD2(t.c.x, t.c.y)
                func side(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float {
                    (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
                }
                let d = (side(a, b, p), side(b, c, p), side(c, a, p))
                return !((d.0 < 0 || d.1 < 0 || d.2 < 0) && (d.0 > 0 || d.1 > 0 || d.2 > 0))
            }
            guard hit else { break }
            distance += step
        }
        return distance
    }

    static func contains(_ box: Box, _ point: SIMD3<Float>) -> Bool {
        let slack: Float = 0.05
        return (0..<3).allSatisfy { point[$0] >= box.min[$0] - slack && point[$0] <= box.max[$0] + slack }
    }

    static func kind(_ member: Member, _ box: Box) -> String {
        switch member.role {
        case .beam:
            return box.size.z >= box.size.x && box.size.z >= box.size.y ? "column" : "beam"
        case .pane: return "pane"
        default:
            let thin = (0..<3).min { box.size[$0] < box.size[$1] } ?? 0
            return thin == 2 ? "slab" : "wall"
        }
    }

    static func degrees(_ radians: Float) -> String { String(format: "%.1f", radians * 180 / .pi) }
    static func metres(_ value: Float) -> String { String(format: "%.2f m", value) }
    static func metres(_ value: SIMD3<Float>) -> String {
        String(format: "%.2f × %.2f × %.2f m", value.x, value.y, value.z)
    }
    static func millimetres(_ value: Float) -> String { "\(Int((value * 1000).rounded())) mm" }
}

extension Box {
    fileprivate var centre: SIMD3<Float> { 0.5 * (min + max) }
}
