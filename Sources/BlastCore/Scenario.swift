import Metal
import simd

/// Axis-aligned rigid block, in metres. Buildings sit on the ground plane z = 0.
public struct Box: Sendable, Hashable, Codable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    /// A block with the given footprint, rising from the ground to `height`.
    public init(x: ClosedRange<Float>, y: ClosedRange<Float>, height: Float) {
        self.init(
            min: SIMD3(x.lowerBound, y.lowerBound, 0), max: SIMD3(x.upperBound, y.upperBound, height))
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        all(point .>= min) && all(point .< max)
    }

    public var size: SIMD3<Float> {
        get { max - min }
        set { max = min + newValue }
    }
}

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
    public var boxes: [Box]
    public var charge: Charge
    /// Further charges, fired at the same moment as `charge`. (Optional so that layouts saved
    /// before it existed still open.)
    public var additionalCharges: [Charge]?
    public var gauges: [Gauge]
    /// An optional deformable body. The air treats it as rigid; it responds to the air's pressure.
    public var structure: StructureModel?
    public var atmosphere = Atmosphere()
    public var reflectiveFaces: BoundaryFaces = .ground

    public init(
        name: String, domainSize: SIMD3<Float>, boxes: [Box], charge: Charge, gauges: [Gauge] = [],
        structure: StructureModel? = nil
    ) {
        self.name = name
        self.domainSize = domainSize
        self.boxes = boxes
        self.charge = charge
        self.gauges = gauges
        self.structure = structure
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
        boxes.contains { $0.contains(charge.position) } || structure?.occupies(charge.position) == true
    }

    /// Time for an ambient sound wave to travel from the charge to the farthest corner.
    public var acousticCrossingTime: Double {
        let far = simd_max(charge.position, domainSize - charge.position)
        return Double(simd_length(far) / atmosphere.soundSpeed())
    }
}

extension BlastSolver {
    /// Creates a solver sized for `scenario` and loads it.
    public convenience init(
        device: MTLDevice, commandQueue: MTLCommandQueue? = nil, scenario: Scenario, cellSize: Float
    ) throws {
        var configuration = SolverConfiguration()
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
        configuration.ambientPressure = scenario.atmosphere.pressure
        configuration.reflectiveFaces = scenario.reflectiveFaces
        ambientSoundSpeed = scenario.atmosphere.soundSpeed(gamma: configuration.gamma)
        ambientDensity = scenario.atmosphere.density
        let grid = self.grid
        let dx = grid.cellSize

        mutateMask { mask in
            mask.update(repeating: 0)
            for box in scenario.boxes {
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
        // The structure is added to the mask on the GPU, by the same rule that later tracks it.
        try setStructure(scenario.structure)

        fill(
            uniform: Primitive(density: scenario.atmosphere.density, pressure: scenario.atmosphere.pressure))
        deposit(scenario.charge)
        for charge in scenario.additionalCharges ?? [] { deposit(charge) }
        setGauges(cells: scenario.gauges.map { nearestFluidCell(to: $0.position) })
        restart()
    }

    /// Radius of the sphere the charge's energy is spread over: the physical charge size,
    /// but never fewer than a couple of cells so the initial discontinuity is resolvable.
    public func balloonRadius(for charge: Charge) -> Float {
        let explosiveDensity: Float = 1600
        let physical = Float(cbrt(3 * Double(charge.mass) / (4 * Double.pi * Double(explosiveDensity))))
        return max(physical, configuration.minimumBalloonCells * grid.cellSize)
    }

    /// Adds the charge's mass and energy to the fluid cells inside its balloon radius.
    ///
    /// Cells are weighted by the fraction of their volume inside the sphere, and the totals are
    /// normalised over fluid cells only, so a charge resting on the ground (or against a wall)
    /// still releases all of its energy into the air.
    public func deposit(_ charge: Charge) {
        guard charge.mass > 0 else { return }
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
