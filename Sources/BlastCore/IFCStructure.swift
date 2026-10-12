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
        /// Its source part (`ImportedMesh.BuildingElement.partID`), its first part's for an
        /// assembly.
        public var partID: Int
        /// For an element built of parts (`ImportedMesh.BuildingElement.assembly`), all of them.
        public var parts: [Int]?
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
        /// back from the first by `untiedGap(elementSize:thickness:)`.
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
    /// How far an untied member is drawn back from the other's face, in metres: at least 10 mm,
    /// and far enough that its end lies over half an element from the other's midsurface, as the
    /// mesh joins an end nearer a midsurface than that to it.
    public static func untiedGap(elementSize: Float, thickness: Float) -> Float {
        max(0.01, 0.5 * elementSize + 0.01 - 0.5 * thickness)
    }

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
        public var rigidParts: [Int] {
            members.filter { $0.role == .rigid }.flatMap { $0.parts ?? [$0.partID] }
        }
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
    /// How far the mesh can move a member's end or centreline onto a line it keeps: half an
    /// element (see `ShellMesh`), and a little.
    static func snap(_ elementSize: Float) -> Float { 0.5 * elementSize + 0.01 }
    /// A support region under `box`'s foot, reaching `reach` above and below its underside, so
    /// as to hold the points of its underside wherever the mesh has put them.
    static func foot(of box: Box, reach: Float) -> Box {
        Box(
            min: SIMD3(box.min.x - 0.01, box.min.y - 0.01, box.min.z - reach),
            max: SIMD3(box.max.x + 0.01, box.max.y + 0.01, box.min.z + reach))
    }
    /// How far above the lowest level a slab of the lowest storey with nothing under it is
    /// taken to rest on the ground (a foundation slab above a pit), in metres.
    static let foundationReach: Float = 1

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
        // An element built of parts (a wall of blocks, a slab of planks) is one member: its
        // parts' meshes together, as the element they belong to.
        var groups:
            [String: (
                element: ImportedMesh.BuildingElement, triangles: [ImportedMesh.Triangle],
                meshes: [[ImportedMesh.Triangle]],
                parts: [Int]
            )] = [:]
        for element in elements.sorted(by: { $0.globalID < $1.globalID }) {
            let key = element.assembly?.id ?? element.globalID
            if groups[key] == nil {
                var representative = element
                if let assembly = element.assembly {
                    representative.globalID = assembly.id
                    representative.name = assembly.name
                    representative.ifcClass = assembly.ifcClass
                    representative.assembly = nil
                }
                groups[key] = (representative, [], [], [])
            } else if let held = element.reinforcement {
                // A part's bars are its element's, as are its properties where no part before it had any.
                var gathered = groups[key]!.element.reinforcement ?? .init()
                gathered.bars += held.bars
                gathered.properties = gathered.properties ?? held.properties
                groups[key]!.element.reinforcement = gathered
            }
            groups[key]!.triangles += element.mesh.triangles
            groups[key]!.meshes.append(element.mesh.triangles)
            groups[key]!.parts.append(element.partID)
            if groups[key]!.element.materials == nil { groups[key]!.element.materials = element.materials }
        }
        let units = groups.values.sorted { $0.element.globalID < $1.element.globalID }
        let sorted = units.map(\.element)
        guard !sorted.isEmpty else { throw ImportedMesh.ImportError.invalid("No IFC elements to convert.") }

        // Turn the building so that its walls lie along the axes.
        let all = units.flatMap { $0.triangles.flatMap { [$0.a, $0.b, $0.c] } }
        let low = all.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = all.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let centre = 0.5 * (low + high)
        var turn = SIMD2<Float>.zero
        for unit in units where Self.family(unit.element.ifcClass) == .plate {
            for t in unit.triangles {
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

        let shapes: [Shape] = units.map { unit in
            let element = unit.element
            let triangles = unit.triangles.map {
                ImportedMesh.Triangle(a: rotate($0.a), b: rotate($0.b), c: rotate($0.c))
            }
            // An assembly is square where the parts holding nine tenths of its volume are: round
            // bars in a precast plank do not tip it.
            var squareVolume: Float = 0
            var allVolume: Float = 0
            for part in unit.meshes where unit.meshes.count > 1 {
                var square: Float = 0
                var total: Float = 0
                var volume: Float = 0
                for t in part {
                    let (a, b, c) = (rotate(t.a), rotate(t.b), rotate(t.c))
                    let normal = simd_cross(b - a, c - a)
                    let area = simd_length(normal)
                    guard area > 0 else { continue }
                    total += area
                    if simd_reduce_max(simd_abs(normal)) / area > cos(Float(3) * .pi / 180) { square += area }
                    volume += simd_dot(a, simd_cross(b, c)) / 6
                }
                allVolume += abs(volume)
                if total > 0 && square >= 0.9 * total { squareVolume += abs(volume) }
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
            let aligned =
                unit.meshes.count > 1
                ? allVolume > 0 && squareVolume >= 0.9 * allVolume : total > 0 && square >= 0.9 * total
            return Shape(
                element: element, parts: unit.parts, triangles: triangles, box: box, aligned: aligned,
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
                modelID.map { StructureModel.SourcePart(modelID: $0, partID: shape.parts[0]) })
            return solids.count - 1
        }

        for shape in shapes {
            let element = shape.element
            var member = Member(
                id: element.globalID, partID: shape.parts[0],
                parts: shape.parts.count > 1 ? shape.parts : nil,
                name: element.name, ifcClass: element.ifcClass, role: .rigid, solid: nil,
                material: nil, materialSource: "", assumed: false, notes: [])
            let picked = shape.parts.lazy.compactMap { chosen[$0] }.first
            let extent = shape.box.size
            let thin = (0..<3).min { extent[$0] < extent[$1] } ?? 0
            let long = (0..<3).max { extent[$0] < extent[$1] } ?? 2
            let layers = element.materials ?? materials[element.globalID] ?? []
            func read() -> Reading {
                if let picked {
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
                if finishes && picked == nil {
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
            if shape.parts.count > 1 {
                member.notes.append("Built of \(shape.parts.count) parts, taken together as one.")
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

        // Parallel plates a little apart (slabs in level, walls in plan) are put on one
        // midsurface, the smaller moved to the larger's, with the ends of members that stand on
        // them or meet them: the mesh's lines run through the whole building, so two near ones
        // leave slivers in every plate that crosses both.
        var aligned: [[String]] = [[], [], []]
        // Panes go with them, or they would be left on their wall's old midsurface.
        let plates = structural.filter { members[$0].role == .shell || members[$0].role == .pane }.compactMap
        { a in
            members[a].solid.map { (member: a, solid: $0) }
        }
        for (x, a) in plates.enumerated() {
            for b in plates[(x + 1)...] {
                let (i, j) = (a.solid, b.solid)
                let k = thinAxis(solids[i])
                guard thinAxis(solids[j]) == k else { continue }
                let offset =
                    0.5 * (solids[i].min[k] + solids[i].max[k]) - 0.5 * (solids[j].min[k] + solids[j].max[k])
                guard abs(offset) > 1e-4,
                    abs(offset)
                        <= min(0.5 * min(solids[i].size[k], solids[j].size[k]), 0.25 * options.elementSize)
                else { continue }
                let area = { (n: Int) in
                    solids[n].size.x * solids[n].size.y * solids[n].size.z / solids[n].size[k]
                }
                let (moved, by) = area(i) < area(j) ? (a, -offset) : (b, offset)
                let old = solids[moved.solid]
                let across = (0..<3).filter { $0 != k }
                for other in structural {
                    guard let n = members[other].solid, n != moved.solid,
                        thinAxis(solids[n]) != k || members[other].role == .beam,
                        across.allSatisfy({
                            solids[n].max[$0] >= old.min[$0] - 1e-4 && old.max[$0] >= solids[n].min[$0] - 1e-4
                        })
                    else { continue }
                    if abs(solids[n].min[k] - old.max[k]) < 1e-4 { solids[n].min[k] += by }
                    if abs(solids[n].max[k] - old.min[k]) < 1e-4 { solids[n].max[k] += by }
                }
                solids[moved.solid].min[k] += by
                solids[moved.solid].max[k] += by
                aligned[k].append("\(members[moved.member].name) by \(Self.millimetres(abs(by)))")
            }
        }
        for (k, list) in aligned.enumerated() where !list.isEmpty {
            assumptions.append(
                (k == 2 ? "Slabs a little apart in level" : "Walls a little apart in plan")
                    + " put on one midsurface: " + list.prefix(12).joined(separator: "; ")
                    + (list.count > 12 ? "; and \(list.count - 12) more." : "."))
        }

        // Pairs the user untied: the second drawn back from the first along the axis they overlap
        // least, so that the mesh does not join them.
        func touching(_ i: Int, _ j: Int) -> Bool {
            (0..<3).allSatisfy {
                solids[i].max[$0] >= solids[j].min[$0] - 1e-4 && solids[j].max[$0] >= solids[i].min[$0] - 1e-4
            }
        }
        var untiedPairs: [String: Float] = [:]
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
                let gap = Self.untiedGap(elementSize: options.elementSize, thickness: solids[i].size[k])
                if 0.5 * (moved.min[k] + moved.max[k]) >= 0.5 * (solids[i].min[k] + solids[i].max[k]) {
                    moved.min[k] = solids[i].max[k] + gap
                } else {
                    moved.max[k] = solids[i].min[k] - gap
                }
                guard moved.max[k] - moved.min[k] > 1e-3 else { continue }
                solids[j] = moved
                untiedPairs[key] = gap
            }
        }

        // Connections: members that touch or overlap share the mesh's nodes there.
        var connections: [Connection] = []
        for (x, a) in structural.enumerated() {
            for b in structural[(x + 1)...] {
                guard let i = members[a].solid, let j = members[b].solid else { continue }
                if let gap = untiedPairs[Connection.key(members[a].id, members[b].id)] {
                    connections.append(
                        Connection(
                            first: members[a].id, second: members[b].id,
                            kind:
                                "\(Self.kind(members[a], solids[i]))–\(Self.kind(members[b], solids[j])), untied by choice, "
                                + "\(Self.millimetres(gap)) apart"))
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
        let tied = connections.filter { untiedPairs[$0.key] == nil }
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

        // The solver holds eight materials: past that, the nearest of a kind are merged.
        let fitted = Self.merging(
            solidMaterials, volumes: solids.map { $0.size.x * $0.size.y * $0.size.z },
            keeping: options.defaultMaterial,
            // Bars, offered or read from the IFC, take a place of their own.
            limit: StructureModel.maxMaterials
                - (options.reinforcement == nil && !units.contains { $0.element.reinforcement != nil }
                    ? 0 : 1))
        if let note = fitted.note {
            solidMaterials = fitted.materials
            for n in members.indices {
                if let index = members[n].solid { members[n].material = solidMaterials[index].name }
            }
            assumptions.append(note)
        }

        var model = StructureModel(
            solids: solids, material: options.defaultMaterial, elementSize: options.elementSize)
        model.elementKind = .shell
        // Members that touch but that the mesh leaves apart are tied where they touch.
        model.tiesTouching = true
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
                groundStorey.map({ storey(n) == $0 }) ?? (box.min.z <= 0.5),
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
            var region = Self.foot(of: box, reach: Self.snap(options.elementSize))
            region.min.z = min(region.min.z, box.min.z - max(0, drop) - 0.01)
            model.supports.append(region)
            model.supportAnchorages.append(options.base)
            supportNotes.append(
                "\(member.name): on the lowest storey with nothing under it in the IFC, its foundation left out; tied to "
                    + "the ground \(Self.millimetres(box.min.z)) up by \(BaseConnection(options.base).title.lowercased()) (assumed)."
            )
        }

        // Slabs of the lowest storey with nothing under them (foundation slabs on piles or soil
        // the IFC leaves out, above a pit that sets the lowest level) rest on the ground at their
        // soffit.
        for (n, member) in members.enumerated() where member.role == .shell {
            guard let index = member.solid else { continue }
            let box = solids[index]
            // What stands under it covers under half its plan: walls round a pit's edge do not
            // carry a slab.
            let covered = bodies.filter { j in
                j != index && solids[j].max.z <= box.min.z + 1e-3 && solids[j].max.z >= box.min.z - options.gap
            }.reduce(Float(0)) { sum, j in
                let overlap = (0..<2).map { max(0, min(solids[j].max[$0], box.max[$0]) - max(solids[j].min[$0], box.min[$0])) }
                return sum + overlap[0] * overlap[1]
            }
            guard thinAxis(box) == 2, box.min.z > options.gap + 1e-3, box.min.z <= Self.foundationReach,
                groundStorey.map({ storey(n) == $0 }) ?? false,
                covered < 0.5 * box.size.x * box.size.y
            else { continue }
            model.supports.append(Self.foot(of: box, reach: 0.2 * options.elementSize + 0.01))
            model.supportAnchorages.append(.resting())
            supportNotes.append(
                "\(member.name): on the lowest storey near its lowest level with nothing under it in the IFC, its foundation left out; rests on "
                    + "the ground at its soffit, \(Self.millimetres(box.min.z)) up, with friction 0.6 (assumed).")
        }

        // Beams lying on the ground (base plates, ground beams): their centrelines above it, the
        // ground's connection holds none of their nodes, so they are tied at their underside.
        for member in members where member.role == .beam {
            guard let index = member.solid else { continue }
            let box = solids[index]
            let long = (0..<3).max { box.size[$0] < box.size[$1] } ?? 2
            guard long != 2, box.min.z <= options.gap + 1e-3,
                !model.supports.contains(where: { region in
                    (0..<3).allSatisfy { box.max[$0] >= region.min[$0] && region.max[$0] >= box.min[$0] }
                })
            else { continue }
            model.supports.append(Self.foot(of: box, reach: Self.snap(options.elementSize)))
            model.supportAnchorages.append(options.base)
            supportNotes.append(
                "\(member.name): lies on the ground, tied at its underside by "
                    + "\(BaseConnection(options.base).title.lowercased()) (assumed).")
        }
        // Members that stand on an element kept rigid (an arch, an inclined roof, a finish) are
        // held by it, as it does not move.
        let rigidBoxes = members.indices.filter { members[$0].role == .rigid }.map { n -> (name: String, box: Box) in
            var box = shapes[n].box
            box.min += shift
            box.max += shift
            return (members[n].name, box)
        }
        for member in members where member.role == .shell || member.role == .beam {
            guard let index = member.solid else { continue }
            let box = solids[index]
            guard box.min.z > options.gap + 1e-3,
                !model.supports.indices.contains(where: { n in
                    let region = model.supports[n]
                    return (0..<3).allSatisfy { box.max[$0] >= region.min[$0] && region.max[$0] >= box.min[$0] }
                }),
                let under = rigidBoxes.first(where: { rigid in
                    rigid.box.max.z >= box.min.z - options.gap && rigid.box.min.z < box.min.z
                        && (0..<2).allSatisfy {
                            min(rigid.box.max[$0], box.max[$0]) - max(rigid.box.min[$0], box.min[$0]) > 1e-3
                        }
                }),
                // Nothing of the structure under it already.
                !bodies.contains(where: { j in
                    j != index && abs(solids[j].max.z - box.min.z) <= 1e-3
                        && (0..<2).allSatisfy { solids[j].max[$0] > box.min[$0] + 1e-4 && box.max[$0] > solids[j].min[$0] + 1e-4 }
                })
            else { continue }
            model.supports.append(Self.foot(of: box, reach: Self.snap(options.elementSize)))
            model.supportAnchorages.append(options.base)
            supportNotes.append(
                "\(member.name): stands on \(under.name), kept rigid, so held by it as it does not move; tied at its "
                    + "underside by \(BaseConnection(options.base).title.lowercased()) (assumed).")
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
        // Members tied to nothing that stands on a support fall under gravity: say which. The
        // mesh decides what is tied: elements sharing nodes, and nodes tied to a column's; and
        // what is held: nodes clamped, or with points of a connection, as the solver holds them.
        var reached: Set<Int>?
        if let mesh = try? ShellMesh(model: model) {
            // The ties the mesh had to infer, between members it does not meet: a guess, flagged.
            let bySolid = Dictionary(
                members.indices.compactMap { n in members[n].solid.map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
            var inferred = 0
            for tie in mesh.contactTies {
                guard let a = bySolid[tie.first], let b = bySolid[tie.second] else { continue }
                let key = Connection.key(members[a].id, members[b].id)
                let kind =
                    "\(Self.kind(members[a], model.solids[tie.first]))–\(Self.kind(members[b], model.solids[tie.second])), "
                    + "tied at \(tie.nodes) nearest node\(tie.nodes == 1 ? "" : "s") (inferred: the mesh does not meet them)"
                if let n = connections.firstIndex(where: { $0.key == key }) {
                    connections[n].kind = kind
                } else {
                    connections.append(Connection(first: members[a].id, second: members[b].id, kind: kind))
                }
                inferred += 1
            }
            if inferred > 0 {
                assumptions.append(
                    "\(inferred) pairs of members that touch but that the mesh does not meet (layers face to face, beams off "
                        + "a column's centreline) are tied rigidly at their nearest nodes: a guess at how they are joined, "
                        + "listed with the connections; untick one to leave the pair apart.")
            }
            var parent = Array(0..<mesh.positions.count)
            func root(_ n: Int) -> Int {
                var n = n
                while parent[n] != n {
                    parent[n] = parent[parent[n]]
                    n = parent[n]
                }
                return n
            }
            func join(_ a: Int, _ b: Int) { parent[root(a)] = root(b) }
            for element in mesh.elements {
                for k in 1..<4 { join(Int(element.nodes[0]), Int(element.nodes[k])) }
            }
            for beam in mesh.beams { join(Int(beam.nodes[0]), Int(beam.nodes[1])) }
            for tie in mesh.ties { join(Int(tie.slave), Int(tie.master)) }
            var anchored = [Bool](repeating: false, count: mesh.positions.count)
            if model.connectionStiffness != nil {
                let points = mesh.jointPoints(
                    across: ShellSolver.fibresAcross, normals: model.connectionNormals
                ) {
                    point, node in
                    guard let slot = model.connectionSlot(at: point), slot != 0 || abs(node.z) < 1e-4,
                        let law = model.connection(inSlot: slot)
                    else { return nil }
                    return (slot, law.across)
                }
                for (n, list) in points.enumerated() where !list.isEmpty { anchored[n] = true }
            }
            var held = Set<Int>()
            for (n, position) in mesh.positions.enumerated()
            where anchored[n] || model.isClampedBySupport(at: position)
                || (model.fixedBase && abs(position.z) < 1e-4)
            {
                held.insert(root(n))
            }
            var solidHeld = [Bool](repeating: false, count: model.solids.count)
            for element in mesh.elements where held.contains(root(Int(element.nodes[0]))) {
                solidHeld[element.solid] = true
            }
            for beam in mesh.beams where held.contains(root(Int(beam.nodes[0]))) {
                solidHeld[beam.solid] = true
            }
            // A member the mesh gave no elements of its own (overlapping another, coplanar, as a
            // duplicate does) has nothing to fall.
            var meshed = [Bool](repeating: false, count: model.solids.count)
            for element in mesh.elements { meshed[element.solid] = true }
            for beam in mesh.beams { meshed[beam.solid] = true }
            reached = Set(members.indices.filter { members[$0].solid.map { solidHeld[$0] || !meshed[$0] } ?? false })
        }
        let loose =
            reached.map { reached in
                members.indices.filter { members[$0].solid != nil && !reached.contains($0) }
            } ?? []
        if !loose.isEmpty {
            let volume = { (n: Int) in
                members[n].solid.map {
                    model.solids[$0].size.x * model.solids[$0].size.y * model.solids[$0].size.z
                } ?? 0
            }
            let total = members.indices.reduce(Float(0)) { $0 + volume($1) }
            let share = loose.reduce(Float(0)) { $0 + volume($1) } / max(total, 1e-9)
            for n in loose {
                members[n].notes.append(
                    "Tied to nothing that stands on a support: it will fall under gravity.")
            }
            assumptions.append(
                "\(loose.count) of \(members.filter { $0.solid != nil }.count) members, \(Int((share * 100).rounded()))% of the "
                    + "structure by volume, are tied to nothing that stands on a support and will fall under gravity: "
                    + loose.prefix(8).map { members[$0].name }.joined(separator: ", ")
                    + (loose.count > 8 ? ", …" : "")
                    + ". Close larger gaps, add supports under Restraints once imported, or leave them out.")
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

    /// `materials` (one per solid, of `volumes`) with the nearest two of a kind merged, again and
    /// again, until there are at most `limit` with `keeping` (the default, never merged): their
    /// stiffness, density and strengths the volume-weighted means. Nearness is the sum of the
    /// logarithmic differences of those. The note says how many were merged and the largest change
    /// in stiffness it made; nil where nothing had to be.
    static func merging(
        _ materials: [StructureMaterial], volumes: [Float], keeping: StructureMaterial, limit: Int
    ) -> (materials: [StructureMaterial], note: String?) {
        var kinds: [StructureMaterial] = []
        for material in materials where material != keeping && !kinds.contains(material) {
            kinds.append(material)
        }
        guard kinds.count + 1 > limit else { return (materials, nil) }
        // Each kind's members (indices into `kinds` as first given) and volume.
        var groups = kinds.map { kind in
            (
                material: kind, members: [kind],
                volume: zip(materials, volumes).filter { $0.0 == kind }.reduce(Float(0)) { $0 + $1.1 }
            )
        }
        func strength(_ m: StructureMaterial) -> Float {
            m.model == .concrete ? m.compressiveStrength : m.yieldStress
        }
        func distance(_ a: StructureMaterial, _ b: StructureMaterial) -> Float {
            guard a.model == b.model, a.isTransparent == b.isTransparent else { return .infinity }
            func log(_ x: Float, _ y: Float) -> Float {
                x > 0 && y > 0 ? abs(Foundation.log(x / y)) : (x == y ? 0 : 10)
            }
            return log(a.youngsModulus, b.youngsModulus) + log(a.density, b.density)
                + log(strength(a), strength(b))
        }
        while groups.count + 1 > limit {
            var best: (Int, Int, Float)?
            for i in groups.indices {
                for j in groups.indices where j > i {
                    let d = distance(groups[i].material, groups[j].material)
                    if d < (best?.2 ?? .infinity) { best = (i, j, d) }
                }
            }
            guard let (i, j, _) = best else { break }
            let (a, b) = (groups[i], groups[j])
            let total = max(a.volume + b.volume, 1e-12)
            func mean(_ x: Float, _ y: Float) -> Float { (x * a.volume + y * b.volume) / total }
            var merged = a.volume >= b.volume ? a.material : b.material
            merged.youngsModulus = mean(a.material.youngsModulus, b.material.youngsModulus)
            merged.density = mean(a.material.density, b.material.density)
            if merged.yieldStress < 1e29 {
                merged.yieldStress = mean(a.material.yieldStress, b.material.yieldStress)
            }
            merged.compressiveStrength = mean(a.material.compressiveStrength, b.material.compressiveStrength)
            merged.tensileStrength = mean(a.material.tensileStrength, b.material.tensileStrength)
            let members = a.members + b.members
            let base = merged.name.components(separatedBy: " (").first ?? merged.name
            merged.name = "\(base) (\(members.count) merged)"
            groups[i] = (merged, members, a.volume + b.volume)
            groups.remove(at: j)
        }
        var replacement: [StructureMaterial: StructureMaterial] = [:]
        var change: Float = 0
        var merged = 0
        for group in groups where group.members.count > 1 {
            merged += group.members.count
            for member in group.members {
                replacement[member] = group.material
                change = max(change, abs(group.material.youngsModulus / member.youngsModulus - 1))
            }
        }
        guard merged > 0 else { return (materials, nil) }
        return (
            materials.map { replacement[$0] ?? $0 },
            "\(merged) materials merged into \(groups.filter { $0.members.count > 1 }.count) to fit the solver's limit of "
                + "\(limit), the nearest of a kind together (volume-weighted means): stiffness changed by up to "
                + "\(Int((change * 100).rounded()))% from an element's own."
        )
    }

    /// An element turned into the structure's frame.
    struct Shape {
        var element: ImportedMesh.BuildingElement
        /// Its source parts: its own, or an assembly's.
        var parts: [Int]
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
