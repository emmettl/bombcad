import Foundation
import RadialBlast
import simd

/// Energy source, modelled as a sphere of hot compressed gas (the "bursting balloon" model).
public struct Charge: Sendable, Hashable, Codable {
    /// Conventional energy of one kilogram of TNT in joules.
    public static let energyPerKilogram: Float = 4.184e6

    /// TNT-equivalent mass in kilograms.
    public var mass: Float
    public var position: SIMD3<Float>
    /// Seconds after the scenario's main charge that this one detonates; nil (or 0) at the same
    /// moment. The main charge always fires at t = 0, and a delay given it is not used. Optional,
    /// and left out of a saved layout when nil, so that layouts and runs saved before it read as
    /// before.
    public var delay: Float?

    public init(mass: Float, position: SIMD3<Float>, delay: Float? = nil) {
        self.mass = mass
        self.position = position
        self.delay = delay
    }

    public var energy: Float { mass * Self.energyPerKilogram }
    /// When it detonates on the run's clock, as a further charge: its delay, never negative.
    public var firingTime: Double { Double(max(delay ?? 0, 0)) }
}

public struct Gauge: Sendable, Hashable, Identifiable, Codable {
    public var name: String
    public var position: SIMD3<Float>

    public init(_ name: String, at position: SIMD3<Float>) {
        self.name = name
        self.position = position
    }

    public var id: String { name }
}

extension Scenario {
    /// The scaled distances (m/kg^(1/3)) a line of gauges stands at unless told otherwise: the span
    /// of the Kingery-Bulmash curves, from close in to where the overpressure is a few kPa.
    public static let gaugeLineScaledDistances: [Double] = [1, 1.5, 2, 3, 4, 5, 7, 10, 14, 20, 28, 40]

    /// Gauges `height` above the ground (or the terrain) on a line from the charge along the
    /// horizontal `direction`, one at each of `scaledDistances` (m/kg^(1/3) of the charge) that
    /// falls inside the domain, named by scaled distance and range.
    public func gaugeLine(
        direction: SIMD2<Float>, scaledDistances: [Double] = gaugeLineScaledDistances, height: Float = 1.5
    ) -> [Gauge] {
        let length = simd_length(direction)
        guard length > 0, charge.mass > 0 else { return [] }
        let unit = direction / length
        let scale = Float(cbrt(Double(charge.mass)))
        let start = SIMD2(charge.position.x, charge.position.y)
        return scaledDistances.compactMap { z in
            let range = Float(z) * scale
            let p = start + range * unit
            guard p.x >= 0, p.y >= 0, p.x <= domainSize.x, p.y <= domainSize.y else { return nil }
            let ground = terrain?.height(at: p) ?? 0
            guard ground + height < domainSize.z else { return nil }
            let distance = range >= 10 ? String(format: "%.0f m", range) : String(format: "%.1f m", range)
            return Gauge("Z \(String(format: "%g", z)) · \(distance)", at: SIMD3(p.x, p.y, ground + height))
        }
    }

    /// The horizontal direction along a domain axis in which the charge has the most room, for a
    /// line of gauges.
    public var roomiestGaugeLineDirection: SIMD2<Float> {
        let c = charge.position
        let room: [(SIMD2<Float>, Float)] = [
            (SIMD2(1, 0), domainSize.x - c.x), (SIMD2(-1, 0), c.x), (SIMD2(0, 1), domainSize.y - c.y),
            (SIMD2(0, -1), c.y),
        ]
        return room.max { $0.1 < $1.1 }!.0
    }
}

public struct Atmosphere: Sendable, Hashable, Codable {
    public var pressure: Float = 101_325
    public var density: Float = 1.225

    public init() {}

    public func soundSpeed(gamma: Float = 1.4) -> Float { (gamma * pressure / density).squareRoot() }
}

/// A rectangular patch of air above rigid ground, a set of rigid blocks and one charge.
public struct Scenario: Sendable, Hashable, Codable {
    public var name: String
    /// Extent of the simulated volume in metres; its origin is at a ground-level corner.
    public var domainSize: SIMD3<Float>
    public package(set) var objects: [SceneObject]
    /// Compatibility adapter for the existing air solver and legacy callers.
    public var boxes: [Box] {
        get { fixedObjects.compactMap(\.fixedBox) }
        set {
            let old = fixedObjects
            let ids = SceneObject.reconcile(old.compactMap(\.fixedBox), ids: old.map(\.id), new: newValue)
            let byID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            let replacements = zip(newValue, ids).map { box, id in
                var object = byID[id] ?? SceneObject(id: id, name: "Block", representation: .fixed(box))
                object.setBox(box)
                return object
            }
            objects = replacements + objects.filter { $0.fixedBox == nil }
        }
    }
    /// Experimental independent rigid objects. Ordinary scene loading does not render or simulate
    /// them; the explicit standalone rigid-box driver can consume one definition.
    /// Optional so layouts predating rigid-object definitions continue to decode unchanged.
    public var rigidObjects: [RigidObjectDefinition]?
    /// Experimental simplified cars, inert like `rigidObjects`. Optional for older layouts.
    public var rigidCars: [RigidCarDefinition]?
    /// Import diagnostics persist with the layout: voxelisation cannot recover lost geometry.
    public var importNotes: [String]?
    public var importedModels: [ImportedModel]?
    public var charge: Charge
    /// Further charges, each fired its own `delay` after `charge` (at the same moment without
    /// one). (Optional so that layouts saved before it existed still open.)
    public var additionalCharges: [Charge]?
    public var gauges: [Gauge]
    /// Legacy adapter to the first deformable object. Multi-body callers address objects by ID.
    public var structure: StructureModel? {
        get { structuralObject?.structure }
        set {
            if let index = objects.firstIndex(where: { $0.structure != nil }) {
                if let newValue { objects[index].setStructure(newValue) } else { objects.remove(at: index) }
            } else if let newValue {
                objects.append(SceneObject(name: "Structure", representation: .deformable(newValue)))
            }
        }
    }
    public var atmosphere = Atmosphere()
    public var reflectiveFaces: BoundaryFaces = .ground
    /// The ground's shape, over the reflecting floor at z = 0; nil (the default) is flat ground.
    /// A scene-level property, beside the objects rather than one of them.
    public var terrain: Terrain?
    /// Credits the scene's data asks for (OpenStreetMap's for map buildings), shown in the app and
    /// written with its exports. Not part of the numerical input.
    public var attributions: [String]?
    /// Which envelopes were made from imports or map data, and how. Not part of the numerical input.
    public var envelopeSources: [EnvelopeSource]?
    /// What envelopes are built of, for their one-way damage (`envelopeConstruction(for:)`); an
    /// envelope without one takes the assumed default. The air never sees it.
    public var envelopeConstructions: [EnvelopeConstruction]?
    /// A premixed gas cloud ignited at a point: when set, it is the scene's source and the
    /// charges are not fired. (Optional so that layouts saved before it existed still open.)
    public var deflagration: Deflagration?
    /// Panels closing openings until the overpressure beside them reaches their release pressure,
    /// for either kind of source. (Optional for older layouts.)
    public var ventPanels: [VentPanel]?
    /// Obstacles smaller than the air's cells, as arrays of pipes or bars (`CongestionArray`): the
    /// air flows through them as through a porous, resisting medium. (Optional for older layouts.)
    public var congestion: [CongestionArray]?

    public init(
        name: String, domainSize: SIMD3<Float>, boxes: [Box], charge: Charge, gauges: [Gauge] = [],
        structure: StructureModel? = nil, rigidObjects: [RigidObjectDefinition]? = nil
    ) {
        self.name = name
        self.domainSize = domainSize
        objects = boxes.enumerated().map { SceneObject.legacyBlock($0.element, index: $0.offset) }
        self.charge = charge
        self.gauges = gauges
        if let structure { objects.append(.legacyStructure(structure)) }
        self.rigidObjects = rigidObjects
    }

    public func grid(cellSize: Float) -> Grid {
        Grid(
            nx: max(1, Int((domainSize.x / cellSize).rounded())),
            ny: max(1, Int((domainSize.y / cellSize).rounded())),
            nz: max(1, Int((domainSize.z / cellSize).rounded())),
            cellSize: cellSize)
    }

    /// True when the charge (or a gas cloud's ignition point) is buried in rigid blocks, a structure
    /// or the ground (`blocks`), where it can release no energy into the air.
    public var chargeIsBlocked: Bool {
        // A gas cloud's ignition point, when the cloud is the source.
        blocks(deflagration?.ignition ?? charge.position)
    }

    /// Whether `point` is buried: rigid blocks (an envelope's walls and a map building's solid
    /// among them), structures or the ground on every side of it, a millimetre out. A charge there
    /// releases no energy into the air, and the solver lays none of it. One on a face (a contact
    /// charge on a wall, under a slab or on a roof) has air on that side and is laid in it; one on
    /// the ground under a building's block, or on a seam between two of its boxes, is buried.
    public func blocks(_ point: SIMD3<Float>) -> Bool {
        let boxes = rigidBoxes
        let step = max(Float(1e-3), 8 * max(abs(point.x), abs(point.y), abs(point.z)).ulp)
        return (0..<3).allSatisfy { axis in
            [-step, step].allSatisfy { offset in
                var q = point
                q[axis] += offset
                return q.z < groundHeight(at: q) || boxes.contains { $0.contains(q) }
                    || structuralObjects.contains { $0.structure?.occupies(q) == true }
            }
        }
    }

    /// The source in a few words: the charge's mass, or the gas cloud's mixture.
    public var sourceDescription: String {
        if let cloud = deflagration {
            return String(format: "%@–air cloud, %.1f%%", cloud.gas.displayName, cloud.concentration * 100)
        }
        return String(format: "%.2f kg TNT", charge.mass)
    }

    /// Time for an ambient sound wave to travel from the charge to the farthest corner.
    public var acousticCrossingTime: Double {
        let far = simd_max(charge.position, domainSize - charge.position)
        return Double(simd_length(far) / atmosphere.soundSpeed())
    }
}

extension Scenario {
    /// Saved-run fingerprints retain the pre-ownership numerical input encoding.
    public static let physicsInputEncoding = CodingUserInfoKey(rawValue: "dev.bombcad.physics-input")!

    private enum CodingKeys: String, CodingKey {
        case name, domainSize, boxes, rigidObjects, rigidCars, importNotes, importedModels, charge,
            additionalCharges, gauges, structure, atmosphere, reflectiveFaces, objectOwnership,
            additionalStructures, buildingEnvelopes, terrain, deflagration, ventPanels, congestion,
            attributions,
            envelopeSources, envelopeConstructions
    }

    private struct Ownership: Codable {
        var version = 1
        package var blocks: [SceneObject.Ownership]
        package var structure: SceneObject.Ownership?
        package var order: [UUID]
    }

    private struct AdditionalStructure: Codable {
        package var model: StructureModel
        var ownership: SceneObject.Ownership?
    }

    private struct SavedEnvelope: Codable {
        package var model: BuildingEnvelope
        var ownership: SceneObject.Ownership?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try c.decode(String.self, forKey: .name),
            domainSize: try c.decode(SIMD3<Float>.self, forKey: .domainSize),
            boxes: try c.decode([Box].self, forKey: .boxes),
            charge: try c.decode(Charge.self, forKey: .charge),
            gauges: try c.decode([Gauge].self, forKey: .gauges),
            structure: try c.decodeIfPresent(StructureModel.self, forKey: .structure),
            rigidObjects: try c.decodeIfPresent([RigidObjectDefinition].self, forKey: .rigidObjects))
        rigidCars = try c.decodeIfPresent([RigidCarDefinition].self, forKey: .rigidCars)
        importNotes = try c.decodeIfPresent([String].self, forKey: .importNotes)
        importedModels = try c.decodeIfPresent([ImportedModel].self, forKey: .importedModels)
        additionalCharges = try c.decodeIfPresent([Charge].self, forKey: .additionalCharges)
        atmosphere = try c.decode(Atmosphere.self, forKey: .atmosphere)
        reflectiveFaces = try c.decode(BoundaryFaces.self, forKey: .reflectiveFaces)
        terrain = try c.decodeIfPresent(Terrain.self, forKey: .terrain)
        attributions = try c.decodeIfPresent([String].self, forKey: .attributions)
        envelopeSources = try c.decodeIfPresent([EnvelopeSource].self, forKey: .envelopeSources)
        envelopeConstructions = try c.decodeIfPresent(
            [EnvelopeConstruction].self, forKey: .envelopeConstructions)
        deflagration = try c.decodeIfPresent(Deflagration.self, forKey: .deflagration)
        ventPanels = try c.decodeIfPresent([VentPanel].self, forKey: .ventPanels)
        congestion = try c.decodeIfPresent([CongestionArray].self, forKey: .congestion)
        let additional =
            try c.decodeIfPresent([AdditionalStructure].self, forKey: .additionalStructures) ?? []
        guard additional.count < Self.maximumStructures, additional.isEmpty || structure != nil else {
            throw SceneObjectError.invalidOwnership
        }
        let extraObjects = try additional.enumerated().map { index, saved in
            let object = SceneObject.legacyStructure(saved.model, index: index + 1)
            return try saved.ownership?.applying(to: object) ?? object
        }
        let envelopes = try (c.decodeIfPresent([SavedEnvelope].self, forKey: .buildingEnvelopes) ?? [])
            .enumerated().map { index, saved in
                let object = SceneObject(
                    id: SceneObject.legacyID(6, index), name: "Building \(index + 1)",
                    representation: .envelope(saved.model))
                return try saved.ownership?.applying(to: object) ?? object
            }
        if let ownership = try c.decodeIfPresent(Ownership.self, forKey: .objectOwnership) {
            guard ownership.version == 1, ownership.blocks.count == fixedObjects.count,
                (ownership.structure == nil) == (structuralObject == nil)
            else { throw SceneObjectError.invalidOwnership }
            var restored = try zip(fixedObjects, ownership.blocks).map { try $1.applying(to: $0) }
            if let body = structuralObject, let owner = ownership.structure {
                restored.append(try owner.applying(to: body))
            }
            restored.append(contentsOf: extraObjects)
            restored.append(contentsOf: envelopes)
            objects = restored
            try validateObjectOwnership()
            try reorderObjects(ownership.order)
        } else {
            objects.append(contentsOf: extraObjects)
            objects.append(contentsOf: envelopes)
            resolveLegacyStructuralSource()
        }
        try validateObjectOwnership()
    }

    public func encode(to encoder: Encoder) throws {
        try validateObjectOwnership()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(domainSize, forKey: .domainSize)
        try c.encode(boxes, forKey: .boxes)
        try c.encodeIfPresent(rigidObjects, forKey: .rigidObjects)
        try c.encodeIfPresent(rigidCars, forKey: .rigidCars)
        try c.encodeIfPresent(importNotes, forKey: .importNotes)
        try c.encodeIfPresent(importedModels, forKey: .importedModels)
        try c.encode(charge, forKey: .charge)
        try c.encodeIfPresent(additionalCharges, forKey: .additionalCharges)
        try c.encode(gauges, forKey: .gauges)
        try c.encodeIfPresent(structure, forKey: .structure)
        try c.encode(atmosphere, forKey: .atmosphere)
        try c.encode(reflectiveFaces, forKey: .reflectiveFaces)
        try c.encodeIfPresent(terrain, forKey: .terrain)
        try c.encodeIfPresent(deflagration, forKey: .deflagration)
        if let ventPanels, !ventPanels.isEmpty { try c.encode(ventPanels, forKey: .ventPanels) }
        if let congestion, !congestion.isEmpty { try c.encode(congestion, forKey: .congestion) }
        let physicsOnly = encoder.userInfo[Self.physicsInputEncoding] as? Bool == true
        if !physicsOnly {
            try c.encodeIfPresent(attributions, forKey: .attributions)
            try c.encodeIfPresent(envelopeSources, forKey: .envelopeSources)
        }
        try c.encodeIfPresent(envelopeConstructions, forKey: .envelopeConstructions)
        if !envelopeObjects.isEmpty {
            try c.encode(
                envelopeObjects.map {
                    SavedEnvelope(model: $0.envelope!, ownership: physicsOnly ? nil : .init($0))
                }, forKey: .buildingEnvelopes)
        }
        if structuralObjects.count > 1 {
            try c.encode(
                structuralObjects.dropFirst().map { object in
                    AdditionalStructure(
                        model: object.structure!, ownership: physicsOnly ? nil : .init(object))
                }, forKey: .additionalStructures)
        }
        if !physicsOnly {
            try c.encode(
                Ownership(
                    blocks: fixedObjects.map(SceneObject.Ownership.init),
                    structure: structuralObject.map(SceneObject.Ownership.init), order: objects.map(\.id)),
                forKey: .objectOwnership)
        }
    }
}

extension Box {
    /// The block as the air's mask takes it on cells of `cellSize`: unchanged where it holds a cell's
    /// centre along every axis. A plate too thin to hold one across it (a 0.2 m wall on 0.5 m cells,
    /// between two centres), but at least a cell in its other two directions, takes across it the
    /// layer of cells its middle lies in, so that the blast does not pass through it. A block thin
    /// in two directions (a rod, or the sliver an opening leaves beside it) is left as it is. A
    /// block's cells are those whose centres it holds, so one thicker than a cell never changes.
    public func holdingCells(of cellSize: Float) -> Box {
        var result = self
        let size = self.size
        for axis in 0..<3 {
            // As the rasteriser: a centre (n + 0.5) cellSize in [min, max).
            let lower = (self.min[axis] / cellSize - 0.5).rounded(.up)
            let upper = (self.max[axis] / cellSize - 0.5).rounded(.up)
            guard upper <= lower, size[(axis + 1) % 3] >= cellSize, size[(axis + 2) % 3] >= cellSize else {
                continue
            }
            let middle = ((self.min[axis] + self.max[axis]) / 2 / cellSize).rounded(.down)
            result.min[axis] = middle * cellSize
            result.max[axis] = (middle + 1) * cellSize
        }
        return result
    }
}
