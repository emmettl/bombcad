import simd

/// Uniform Cartesian grid. Cell `(i, j, k)` spans `[i, i + 1] * cellSize` along x and so on; z is up.
public struct Grid: Sendable, Hashable {
    public var nx: Int
    public var ny: Int
    public var nz: Int
    /// Edge length of a cell in metres.
    public var cellSize: Float

    public init(nx: Int, ny: Int, nz: Int, cellSize: Float) {
        precondition(nx > 0 && ny > 0 && nz > 0 && cellSize > 0, "Grid must be non-empty")
        self.nx = nx
        self.ny = ny
        self.nz = nz
        self.cellSize = cellSize
    }

    public var cellCount: Int { nx * ny * nz }

    public var size: SIMD3<Float> { SIMD3(Float(nx), Float(ny), Float(nz)) * cellSize }

    @inlinable
    public func index(_ i: Int, _ j: Int, _ k: Int) -> Int { i + nx * (j + ny * k) }

    public func contains(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        i >= 0 && i < nx && j >= 0 && j < ny && k >= 0 && k < nz
    }

    public func cellCentre(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * cellSize
    }

    /// Indices of the cell containing `point`, clamped to the grid.
    public func cell(containing point: SIMD3<Float>) -> (i: Int, j: Int, k: Int) {
        let scaled = point / cellSize
        return (
            min(max(Int(scaled.x.rounded(.down)), 0), nx - 1),
            min(max(Int(scaled.y.rounded(.down)), 0), ny - 1),
            min(max(Int(scaled.z.rounded(.down)), 0), nz - 1)
        )
    }
}

/// Faces of the domain that reflect (rigid wall). Faces not listed let waves leave.
public struct BoundaryFaces: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let xMin = BoundaryFaces(rawValue: 1 << 0)
    public static let xMax = BoundaryFaces(rawValue: 1 << 1)
    public static let yMin = BoundaryFaces(rawValue: 1 << 2)
    public static let yMax = BoundaryFaces(rawValue: 1 << 3)
    public static let zMin = BoundaryFaces(rawValue: 1 << 4)
    public static let zMax = BoundaryFaces(rawValue: 1 << 5)

    public static let ground: BoundaryFaces = [.zMin]
    public static let all: BoundaryFaces = [.xMin, .xMax, .yMin, .yMax, .zMin, .zMax]
}

public enum RiemannSolver: UInt32, Sendable, CaseIterable {
    case hllc = 0
    case hll = 1
}

public struct SolverConfiguration: Sendable, Hashable {
    /// Ratio of specific heats of the (ideal) gas.
    public var gamma: Float = 1.4
    /// Courant number per directional sweep.
    public var cfl: Float = 0.45
    /// Reference pressure used for overpressure, peak and impulse fields (Pa).
    public var ambientPressure: Float = 101_325
    public var reflectiveFaces: BoundaryFaces = .ground
    public var riemannSolver: RiemannSolver = .hllc
    /// Slope limiter steepness: 1 is minmod, 2 is monotonised central.
    public var limiterTheta: Float = 1.5
    public var densityFloor: Float = 1e-6
    public var pressureFloor: Float = 1e-3
    /// Number of initial steps over which the Courant number ramps up.
    public var startupSteps: Int = 6
    /// Let the air's solid cells follow the structure as it moves and breaks, so that breaches
    /// vent. When false the air sees the structure as it was at the start.
    public var twoWayCoupling = true
    /// Let a moving part of the structure push and pull the air like a piston. When false the
    /// air treats the structure's surface as stationary wherever it currently is.
    public var movingWalls = true
    /// Sweep only the tiles of 8 x 8 x 8 cells that the blast has reached (or is about to),
    /// leaving air that is still in its initial uniform state untouched. The answer is the same
    /// either way. Read at `restart()`.
    public var skipStillAir = true
    /// How the air's pressure follows from its energy (see `AirModel`).
    public var airModel: AirModel = .idealGas
    /// Burn the detonation products in the air they mix with (afterburning), releasing
    /// `afterburnEnergy` per kilogram of charge as far as the oxygen allows. Read at `restart()`;
    /// takes effect for charges deposited after it is set.
    public var afterburning = false
    /// Energy released by burning one kilogram of TNT's detonation products in air, J/kg: its
    /// heat of combustion less its heat of detonation.
    public var afterburnEnergy: Float = 10.0e6
    /// Time over which detonation products that have met air burn, per cube root of the charge's
    /// mass, s/kg^(1/3): 46 ms for 100 kg. Chosen so that the incident impulse of a burst in the
    /// open matches Kingery-Bulmash; burning at once would add to the leading shock, which those
    /// tests show it barely does.
    public var afterburnTime: Float = 10e-3
    /// Start a lone charge from a fine one-dimensional solution of its first moments, mapped
    /// onto the grid once its shock has spread as far as it can before meeting anything (at most
    /// 16 cells), instead of from a sphere of hot gas a few cells across. Only with an ideal gas
    /// and without afterburning.
    public var mappedCharge = false
    /// Once no air cell is further than this fraction of ambient pressure from ambient, and
    /// there is a structure to keep following, the air is frozen and only the structure is
    /// advanced. Zero disables this. The default, 2 kPa at sea level, is small beside the
    /// weight of a concrete slab; the winds left behind by a blast take seconds to fall below it.
    public var airSleepThreshold: Float = 0.02
    /// The air is also frozen once this many acoustic crossing times of the domain have passed,
    /// by when the blast has long gone. A collapsing structure keeps stirring the air near it,
    /// so the pressure test alone may never be met. Zero disables this.
    public var airSleepCrossings: Float = 5
    /// Smallest radius, in cells, of the sphere a charge's energy is deposited into.
    public var minimumBalloonCells: Float = 2
    /// Refine the air where the blast's shock is by this ratio, 2 or 4: each tile of 8 x 8 x 8
    /// cells the shock crosses is swept as (8r)^3 cells in r steps of its own, so that the shock
    /// stays sharp. 1 leaves the grid uniform. Not with afterburning, and not within the region
    /// around a deformable structure. Read at `restart()`.
    public var refinement = 1
    /// A tile is refined where the pressures of two neighbouring cells in it differ by more than
    /// this fraction of the lower, and so are the tiles around it.
    public var refinementThreshold: Float = 0.1
    /// GPU memory for the refined tiles, in bytes; where the shock would need more, the rest of
    /// it stays coarse. About 400 kB a tile at ratio 2, 1.5 MB at ratio 4.
    public var refinementMemory = 1 << 30

    public init() {}
}

/// Primitive gas state in SI units.
public struct Primitive: Sendable, Hashable {
    public var density: Float
    public var velocity: SIMD3<Float>
    public var pressure: Float

    public init(density: Float, velocity: SIMD3<Float> = .zero, pressure: Float) {
        self.density = density
        self.velocity = velocity
        self.pressure = pressure
    }
}

/// Conserved variables as stored on the GPU. Layout matches `Cell` in `Solver.metal`.
public struct CellState: Sendable, Equatable {
    public var density: Float
    public var momentumX: Float
    public var momentumY: Float
    public var momentumZ: Float
    public var energy: Float

    public init(_ primitive: Primitive, gamma: Float) {
        density = primitive.density
        momentumX = primitive.density * primitive.velocity.x
        momentumY = primitive.density * primitive.velocity.y
        momentumZ = primitive.density * primitive.velocity.z
        energy =
            primitive.pressure / (gamma - 1)
            + 0.5 * primitive.density * simd_length_squared(primitive.velocity)
    }

    public func primitive(gamma: Float) -> Primitive {
        let velocity = SIMD3(momentumX, momentumY, momentumZ) / density
        let pressure = (gamma - 1) * (energy - 0.5 * density * simd_length_squared(velocity))
        return Primitive(density: density, velocity: velocity, pressure: pressure)
    }
}

/// Layout matches `SolverUniforms` in `Solver.metal`.
struct SolverUniforms {
    var nx: UInt32
    var ny: UInt32
    var nz: UInt32
    var axis: UInt32 = 0
    var dx: Float
    var gamma: Float
    var cfl: Float
    var ambientPressure: Float
    var densityFloor: Float
    var pressureFloor: Float
    var limiterTheta: Float
    var riemannSolver: UInt32
    var boundaryFlags: UInt32
    var finalSweep: UInt32 = 0
    var gaugeCount: UInt32 = 0
    var forcedStep: Float = 0
    var regionX: UInt32 = 0
    var regionY: UInt32 = 0
    var regionZ: UInt32 = 0
    var regionNx: UInt32 = 0
    var regionNy: UInt32 = 0
    var regionNz: UInt32 = 0
    var maxStep: Float = 0
    var tileNx: UInt32 = 0
    var tileNy: UInt32 = 0
    var tileNz: UInt32 = 0
    var stillRho: Float = 0
    var stillMx: Float = 0
    var stillMy: Float = 0
    var stillMz: Float = 0
    var stillEnergy: Float = 0
    var afterburnEnergy: Float = 0
    var oxygenPerFuel: Float = 0
    var stillOxygen: Float = 0
    var afterburnRate: Float = 0
    var airModel: UInt32 = 0
    var refineRatio: UInt32 = 0
    var refineTileNx: UInt32 = 0
    var refineTileNy: UInt32 = 0
    var refineTileNz: UInt32 = 0
    var refineSubstep: UInt32 = 0
    var refineAlpha: Float = 0
    var refineThreshold: Float = 0
    var refineMaxPatches: UInt32 = 0
}

/// Layout matches `StepControl` in `Solver.metal`.
struct StepControl {
    var dt: Float = 0
    var batchTime: Float = 0
    var timeLimit: Float = .greatestFiniteMagnitude
    var stepIndex: UInt32 = 0
    var activeSteps: UInt32 = 0
    var maxOverpressure: Float = .greatestFiniteMagnitude
    var activeTiles: UInt32 = 0
    var tileSweeps: UInt32 = 0
}

/// Pressure history recorded at a gauge cell, one sample per solver step.
public struct GaugeSample: Sendable, Hashable {
    /// Simulation time in seconds.
    public var time: Double
    /// Absolute pressure in pascals.
    public var pressure: Float
}

/// The air's equation of state. Layout matches `AirModel` in `Solver.metal`.
public enum AirModel: UInt32, Sendable, Codable, CaseIterable {
    /// An ideal gas with the configuration's constant gamma.
    case idealGas = 0
    /// Air whose N2 and O2 store energy in vibration once hot, so that its gamma falls from 1.4
    /// towards 1.29 near 3000 K; dissociation is not included.
    case thermallyPerfect = 1

    static let gasConstant: Float = 287.05

    static func vibrationalEnergy(temperature: Float) -> Float {
        let t = max(temperature, 1)
        return gasConstant
            * (0.79 * 3390 / (exp(min(3390 / t, 80)) - 1) + 0.21 * 2270 / (exp(min(2270 / t, 80)) - 1))
    }

    /// Internal energy per volume of air at `density` and `pressure`.
    public func internalEnergy(density: Float, pressure: Float, gamma: Float) -> Float {
        switch self {
        case .idealGas: return pressure / (gamma - 1)
        case .thermallyPerfect:
            let t = pressure / (density * Self.gasConstant)
            return density * (2.5 * Self.gasConstant * t + Self.vibrationalEnergy(temperature: t))
        }
    }

    /// Pressure of air at `density` holding `internalEnergy` per volume.
    public func pressure(density: Float, internalEnergy: Float, gamma: Float) -> Float {
        switch self {
        case .idealGas: return (gamma - 1) * internalEnergy
        case .thermallyPerfect:
            let e = internalEnergy / density
            var t = max(e, 0) / (2.5 * Self.gasConstant)
            for _ in 0..<6 {
                let heat =
                    (Self.vibrationalEnergy(temperature: t * 1.001) - Self.vibrationalEnergy(temperature: t))
                    / (0.001 * max(t, 1))
                t -=
                    (2.5 * Self.gasConstant * t + Self.vibrationalEnergy(temperature: t) - e)
                    / (2.5 * Self.gasConstant + max(heat, 0))
            }
            return density * Self.gasConstant * max(t, 0)
        }
    }
}

public struct BatchResult: Sendable {
    /// Steps that advanced time (steps past a time limit are no-ops).
    public var steps: Int
    /// Simulated seconds covered by the batch.
    public var elapsed: Double
    /// Size of the last time step in seconds.
    public var lastTimeStep: Double
    /// False when the solution has blown up (non-finite time step).
    public var isStable: Bool
    /// Largest magnitude of overpressure anywhere in the air at the end of the batch, in Pa.
    public var maxOverpressure: Float = .greatestFiniteMagnitude
    /// Fraction of the grid's tiles swept, averaged over the batch's steps (1 when still air is
    /// not skipped).
    public var sweptFraction: Double = 1
    /// Tiles refined at the end of the batch (0 when the air is not refined).
    public var refinedTiles = 0
}

public enum BlastError: Error, CustomStringConvertible {
    case missingShader(String)
    case missingFunction(String)
    case allocationFailed(String)
    case tooManyMaterials(Int)
    /// Shells need every solid to be plate-like; this one is not.
    case notPlateLike(Int)
    /// The benchmark's supports do not fall on nodes of the mesh.
    case supportsMissNodes

    public var description: String {
        switch self {
        case .missingShader(let name): "Shader source \(name) is missing from the bundle"
        case .missingFunction(let name): "Shader function \(name) not found"
        case .allocationFailed(let what): "Could not allocate \(what)"
        case .tooManyMaterials(let count):
            "The structure has \(count) materials; at most \(StructureModel.maxMaterials) are supported"
        case .supportsMissNodes:
            "The supports do not fall on nodes of the mesh; choose an element size that divides 6 inches"
        case .notPlateLike(let index):
            "Solid \(index + 1) is neither a wall or slab nor a column, so it cannot be meshed with shells and beams"
        }
    }
}
