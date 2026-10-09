import Foundation
import Metal
import simd

/// Energy source, modelled as a sphere of hot compressed gas (the "bursting balloon" model).
public struct Charge: Sendable, Hashable, Codable {
    /// Conventional energy of one kilogram of TNT in joules.
    public static let energyPerKilogram: Float = 4.184e6

    /// TNT-equivalent mass in kilograms.
    public var mass: Float
    public var position: SIMD3<Float>

    public init(mass: Float, position: SIMD3<Float>) {
        self.mass = mass
        self.position = position
    }

    public var energy: Float { mass * Self.energyPerKilogram }
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
    public internal(set) var objects: [SceneObject]
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
    /// Further charges, fired at the same moment as `charge`. (Optional so that layouts saved
    /// before it existed still open.)
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

    /// True when the charge sits inside a rigid block or the structure, where it can release
    /// no energy into the air.
    public var chargeIsBlocked: Bool {
        rigidBoxes.contains { $0.contains(charge.position) }
            || structuralObjects.contains { $0.structure?.occupies(charge.position) == true }
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
            additionalStructures, buildingEnvelopes
    }

    private struct Ownership: Codable {
        var version = 1
        var blocks: [SceneObject.Ownership]
        var structure: SceneObject.Ownership?
        var order: [UUID]
    }

    private struct AdditionalStructure: Codable {
        var model: StructureModel
        var ownership: SceneObject.Ownership?
    }

    private struct SavedEnvelope: Codable {
        var model: BuildingEnvelope
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
        let physicsOnly = encoder.userInfo[Self.physicsInputEncoding] as? Bool == true
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

extension BlastSolver {
    /// Creates a solver sized for `scenario` and loads it, with `configuration` but the
    /// scenario's atmosphere and reflecting faces.
    public convenience init(
        device: MTLDevice, commandQueue: MTLCommandQueue? = nil, scenario: Scenario, cellSize: Float,
        configuration: SolverConfiguration = SolverConfiguration()
    ) throws {
        var configuration = configuration
        configuration.ambientPressure = scenario.atmosphere.pressure
        configuration.reflectiveFaces = scenario.reflectiveFaces
        try self.init(
            device: device, commandQueue: commandQueue, grid: scenario.grid(cellSize: cellSize),
            configuration: configuration)
        try load(scenario)
    }

    /// Voxelises the scenario's blocks and structure, fills the air, deposits the charge, places
    /// the gauges and builds the structural mesh.
    ///
    /// The scenario's domain must match the solver's grid.
    public func load(_ scenario: Scenario) throws {
        try scenario.validateObjectOwnership()
        clearEnvelopeExposure()
        configuration.ambientPressure = scenario.atmosphere.pressure
        configuration.reflectiveFaces = scenario.reflectiveFaces
        ambientSoundSpeed = scenario.atmosphere.soundSpeed(gamma: configuration.gamma)
        ambientDensity = scenario.atmosphere.density
        let grid = self.grid
        let dx = grid.cellSize

        mutateMask { mask in
            mask.update(repeating: 0)
            for box in scenario.rigidBoxes {
                // A cell is solid when its centre lies inside the block.
                let low = box.min / dx - 0.5
                let high = box.max / dx - 0.5
                let iRange = cellRange(low.x, high.x, count: grid.nx)
                let jRange = cellRange(low.y, high.y, count: grid.ny)
                let kRange = cellRange(low.z, high.z, count: grid.nz)
                for k in kRange {
                    for j in jRange {
                        let row = grid.index(0, j, k)
                        for i in iRange { mask[row + i] = 1 }
                    }
                }
            }
        }
        rigidBoxes = scenario.rigidBoxes
        // The structure is added to the mask on the GPU, by the same rule that later tracks it.
        try scenario.validateStructuralSeparation()
        try setStructures(scenario.structuralObjects)

        fill(
            uniform: Primitive(density: scenario.atmosphere.density, pressure: scenario.atmosphere.pressure))
        let mapping = mapping(for: scenario)
        let gaugeCells = scenario.gauges.map { nearestFluidCell(to: $0.position) }
        let gaugeCentres = gaugeCells.map { grid.cellCentre($0.i, $0.j, $0.k) }
        var mapped: SphericalBlast?
        if let mapping {
            mapped = depositMapped(
                scenario.charge, radius: mapping.radius, onGround: mapping.onGround, probes: gaugeCentres)
        } else {
            deposit(scenario.charge)
            for charge in scenario.additionalCharges ?? [] { deposit(charge) }
        }
        setGauges(cells: gaugeCells, points: scenario.gauges.map(\.position))
        restart()
        if interObjectContactDetected { throw SceneObjectError.interObjectContact }
        if couplingCapacityExceeded {
            throw BlastError.allocationFailed("local coupling tiles for the current geometry")
        }
        if scenario.structuralObjects.count > 1, configuration.refinement > 1, refinement == nil {
            throw BlastError.allocationFailed("multi-body air refinement")
        }
        if let mapping, let mapped {
            recordMapped(mapped, charge: scenario.charge, radius: mapping.radius, gauges: gaugeCentres)
        }
    }

    /// How far a lone charge's blast can be solved in one dimension before it meets anything:
    /// 0.8 of the distance to the nearest block, structure or open face of the domain (a
    /// reflecting face the charge sits on mirrors it instead), at most 16 cells; nil if mapping is
    /// off or not possible, or would not reach 3 cells.
    func mapping(for scenario: Scenario) -> (radius: Float, onGround: Bool)? {
        guard configuration.mappedCharge, !configuration.afterburning, configuration.airModel == .idealGas,
            (scenario.additionalCharges ?? []).isEmpty, scenario.charge.mass > 0
        else { return nil }
        let c = scenario.charge.position
        let dx = grid.cellSize
        let onGround = c.z <= 0.5 * dx && scenario.reflectiveFaces.contains(.zMin)
        var nearest = Float.infinity
        var obstacles = scenario.rigidBoxes
        obstacles.append(contentsOf: scenario.structuralObjects.compactMap { $0.structure?.bounds })
        for box in obstacles {
            nearest = min(nearest, simd_distance(simd_clamp(c, box.min, box.max), c))
        }
        let size = scenario.domainSize
        let faces: [(BoundaryFaces, Float)] = [
            (.xMin, c.x), (.xMax, size.x - c.x), (.yMin, c.y), (.yMax, size.y - c.y), (.zMin, c.z),
            (.zMax, size.z - c.z),
        ]
        for (face, distance) in faces where !(face == .zMin && onGround) {
            nearest = min(nearest, distance)
        }
        let radius = min(0.8 * nearest, 16 * dx)
        return radius >= 3 * dx ? (radius, onGround) : nil
    }

    /// The ratio the air will be refined by at the next `restart()`, or 1.
    var refinementAtRestart: Int {
        configuration.refinement > 1 ? configuration.refinement : 1
    }

    /// Radius of the sphere the charge's energy is spread over: the physical charge size,
    /// but never fewer than a couple of cells (fine cells, where the air is refined) so the
    /// initial discontinuity is resolvable.
    public func balloonRadius(for charge: Charge) -> Float {
        let explosiveDensity: Float = 1600
        let physical = Float(cbrt(3 * Double(charge.mass) / (4 * Double.pi * Double(explosiveDensity))))
        return max(physical, configuration.minimumBalloonCells * grid.cellSize / Float(refinementAtRestart))
    }

    /// Adds the charge's mass and energy to the fluid cells inside its balloon radius.
    ///
    /// Cells are weighted by the fraction of their volume inside the sphere, and the totals are
    /// normalised over fluid cells only, so a charge resting on the ground (or against a wall)
    /// still releases all of its energy into the air.
    public func deposit(_ charge: Charge) {
        guard charge.mass > 0 else { return }
        if refinementAtRestart > 1 {
            depositRefined(charge)
            return
        }
        let grid = self.grid
        let dx = grid.cellSize
        let radius = balloonRadius(for: charge)
        let low = grid.cell(containing: charge.position - radius)
        let high = grid.cell(containing: charge.position + radius)
        let samples = 5

        var weights: [(index: Int, fraction: Float)] = []
        for k in low.k...high.k {
            for j in low.j...high.j {
                for i in low.i...high.i where !isSolid(i, j, k) {
                    var inside = 0
                    for c in 0..<samples {
                        for b in 0..<samples {
                            for a in 0..<samples {
                                let offset = (SIMD3(Float(a), Float(b), Float(c)) + 0.5) / Float(samples)
                                let point = (SIMD3(Float(i), Float(j), Float(k)) + offset) * dx
                                if simd_distance_squared(point, charge.position) <= radius * radius {
                                    inside += 1
                                }
                            }
                        }
                    }
                    if inside > 0 {
                        let fraction = Float(inside) / Float(samples * samples * samples)
                        weights.append((grid.index(i, j, k), fraction))
                    }
                }
            }
        }
        let total = weights.reduce(Float(0)) { $0 + $1.fraction }
        guard total > 0 else { return }

        let volume = total * dx * dx * dx
        let massDensity = charge.mass / volume
        let energyDensity = charge.energy / volume
        mutateState { cells in
            for (index, fraction) in weights {
                cells[index].density += massDensity * fraction
                cells[index].energy += energyDensity * fraction
            }
        }
        largestCharge = max(largestCharge, charge.mass)
        // The products, all unburnt; the air they displace keeps its oxygen.
        mutateSpecies { species in
            for (index, fraction) in weights { species[index].x += massDensity * fraction }
        }
    }

    /// Where the air will be refined, the charge is laid down in the fine cells, as on a grid that
    /// fine: a sphere a couple of coarse cells across is a blocky cube, which the fine cells
    /// resolve, and which then drives a stronger blast along its faces' normals than the sphere it
    /// stands for (30% higher peaks 1.5 radii out). The coarse cells take the mean of their fine
    /// cells, and `restart()` gives the fine cells their own share once the patches are placed.
    private func depositRefined(_ charge: Charge) {
        let grid = self.grid
        let r = refinementAtRestart
        let fine = grid.cellSize / Float(r)
        let radius = balloonRadius(for: charge)
        let low = SIMD3<Int>(simd_max((charge.position - radius) / fine, .zero).rounded(.down))
        let high = simd_min(
            SIMD3<Int>(((charge.position + radius) / fine).rounded(.down)),
            SIMD3(grid.nx, grid.ny, grid.nz) &* r &- 1)
        let samples = 5
        // Sample points are measured from the cell's centre, relative to the charge, so that cells
        // mirrored about it do mirrored arithmetic and count the same points.
        let charged = charge.position / fine
        var weights: [(fine: SIMD3<Int>, fraction: Float)] = []
        for k in low.z...high.z {
            for j in low.y...high.y {
                for i in low.x...high.x {
                    let cell = SIMD3(i, j, k) / r
                    let centre = SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5
                    guard !isSolid(cell.x, cell.y, cell.z),
                        !(rigidBoxes ?? []).contains(where: { $0.contains(centre * fine) })
                    else { continue }
                    let fromCharge = centre - charged
                    var inside = 0
                    for c in 0..<samples {
                        for b in 0..<samples {
                            for a in 0..<samples {
                                let offset = (SIMD3(Float(a), Float(b), Float(c)) - 2) / Float(samples)
                                if simd_length_squared((fromCharge + offset) * fine) <= radius * radius {
                                    inside += 1
                                }
                            }
                        }
                    }
                    if inside > 0 {
                        weights.append((SIMD3(i, j, k), Float(inside) / Float(samples * samples * samples)))
                    }
                }
            }
        }
        let total = weights.reduce(Float(0)) { $0 + $1.fraction }
        guard total > 0 else { return }
        let volume = total * fine * fine * fine
        let massDensity = charge.mass / volume
        let energyDensity = charge.energy / volume
        // Each coarse cell's share is summed in double precision, where the sum of its fine cells'
        // is exact, so that it does not depend on their order (a centred charge stays symmetric).
        var coarse: [Int: SIMD2<Double>] = [:]
        for (cell, fraction) in weights {
            let added = SIMD2(massDensity, energyDensity) * fraction
            fineDeposit[cell, default: .zero] += added
            coarse[grid.index(cell.x / r, cell.y / r, cell.z / r), default: .zero] += SIMD2<Double>(added)
        }
        let share = 1 / Double(r * r * r)
        editState { cells in
            for (index, added) in coarse {
                cells[index].density += Float(added.x * share)
                cells[index].energy += Float(added.y * share)
            }
        }
        largestCharge = max(largestCharge, charge.mass)
        mutateSpecies { species in
            for (index, added) in coarse { species[index].x += Float(added.x * share) }
        }
    }

    /// The cell containing `point`, or the closest fluid cell if that one is solid.
    public func nearestFluidCell(to point: SIMD3<Float>) -> (i: Int, j: Int, k: Int) {
        let home = grid.cell(containing: point)
        guard isSolid(home.i, home.j, home.k) else { return home }
        var best = home
        var bestDistance = Float.infinity
        let reach = 4
        for k in (home.k - reach)...(home.k + reach) {
            for j in (home.j - reach)...(home.j + reach) {
                for i in (home.i - reach)...(home.i + reach)
                where grid.contains(i, j, k) && !isSolid(i, j, k) {
                    let distance = simd_distance_squared(grid.cellCentre(i, j, k), point)
                    if distance < bestDistance {
                        bestDistance = distance
                        best = (i, j, k)
                    }
                }
            }
        }
        return best
    }
}

private func cellRange(_ low: Float, _ high: Float, count: Int) -> Range<Int> {
    let lower = min(max(Int(low.rounded(.up)), 0), count)
    let upper = min(max(Int(high.rounded(.up)), lower), count)
    return lower..<upper
}
