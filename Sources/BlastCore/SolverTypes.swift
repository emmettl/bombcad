import simd

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
    /// Coarse boundary storage for multiple structures, read by `setStructures`.
    /// Automatic keeps dense storage when smaller; a single body retains its dense path.
    public var bodyCouplingLayout: BodyCouplingLayout = .automatic
    /// Zero reserves twice the initial padded tile footprint. Positive values set a bounded pool.
    public var bodyCouplingTileCapacity = 0
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
    /// Refine the air where the blast's shock is by this ratio, 2 or 4: each block of 4 x 4 x 4
    /// cells the shock crosses is swept as (4r)^3 cells in r steps of its own, so that the shock
    /// stays sharp, and a deformable structure is loaded by the fine cells beside its faces. 1
    /// leaves the grid uniform. Read at `restart()`.
    public var refinement = 1
    /// A tile is refined where the pressures of two neighbouring cells in it differ by more than
    /// this fraction of the lower, and so are the tiles around it.
    public var refinementThreshold: Float = 0.1
    /// GPU memory for the refined blocks, in bytes; where the shock would need more, the rest of
    /// it stays coarse. About 63 kB a block at ratio 2, 364 kB at ratio 4.
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
    var experimentalBox: UInt32 = 0
    var boxCentreX: Float = 0
    var boxCentreY: Float = 0
    var boxCentreZ: Float = 0
    var boxMinX: Float = 0
    var boxMinY: Float = 0
    var boxMinZ: Float = 0
    var boxMaxX: Float = 0
    var boxMaxY: Float = 0
    var boxMaxZ: Float = 0
    var couplingMapCount: UInt32 = 0
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
    var stopped: UInt32 = 0
    var lastStep: Float = 0
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
    /// Thermally perfect air whose N2 and O2 also dissociate into atoms in equilibrium, as
    /// Lighthill's ideal dissociating gas: O2 from about 2500 K, N2 from about 4500 K.
    case dissociating = 2

    static let gasConstant: Float = 287.05

    static func vibrationalEnergy(temperature: Float) -> Float {
        let t = max(temperature, 1)
        return gasConstant
            * (0.79 * 3390 / (exp(min(3390 / t, 80)) - 1) + 0.21 * 2270 / (exp(min(2270 / t, 80)) - 1))
    }

    /// N2 then O2: mass fraction, gas constant, dissociation temperature, characteristic
    /// density and vibrational temperature (see `Solver.metal`).
    static let species: [(share: Double, r: Double, theta: Double, density: Double, vibration: Double)] = [
        (0.767, 296.8, 113_000, 1.3e5, 3390), (0.233, 259.8, 59_500, 1.5e5, 2270),
    ]

    /// The fraction of each species' molecules, N2 then O2, dissociated in air at `density` and
    /// `temperature`, by Lighthill's alpha^2 / (1 - alpha) = (rho_d / rho_s) exp(-theta_d / T).
    public static func dissociatedFractions(density: Float, temperature: Float) -> [Float] {
        species.map { s in
            let exponent = s.theta / Double(max(temperature, 1e-12))
            guard exponent < 80 else { return 0 }
            let k = s.density / max(s.share * Double(density), 1e-12) * exp(-exponent)
            return Float(2 / (1 + (1 + 4 / k).squareRoot()))
        }
    }

    /// Dissociating air at `density` and `temperature`: energy per kilogram and p / (rho T).
    static func dissociating(density: Float, temperature: Float) -> (energy: Double, gasConstant: Double) {
        let t = Double(max(temperature, 1e-12))
        let alphas = dissociatedFractions(density: density, temperature: temperature).map(Double.init)
        var energy = 0.0
        var gasConstant = 0.0
        for (s, alpha) in zip(species, alphas) {
            let molecules = s.r * (2.5 * t + s.vibration / (exp(min(s.vibration / t, 80)) - 1))
            let atoms = s.r * (3 * t + s.theta)
            energy += s.share * ((1 - alpha) * molecules + alpha * atoms)
            gasConstant += s.share * s.r * (1 + alpha)
        }
        return (energy, gasConstant)
    }

    /// Temperature of air at `density` and `pressure`.
    public func temperature(density: Float, pressure: Float) -> Float {
        switch self {
        case .idealGas, .thermallyPerfect: return pressure / (density * Self.gasConstant)
        case .dissociating:
            // Bisection between no dissociation and full: p = rho R(T) T rises with T.
            var low = Double(pressure) / (Double(density) * 2 * 287.2)
            var high = Double(pressure) / (Double(density) * 287.2)
            for _ in 0..<60 {
                let middle = 0.5 * (low + high)
                let p =
                    Double(density)
                    * Self.dissociating(density: density, temperature: Float(middle)).gasConstant
                    * middle
                if p > Double(pressure) { high = middle } else { low = middle }
            }
            return Float(0.5 * (low + high))
        }
    }

    /// Internal energy per volume of air at `density` and `pressure`.
    public func internalEnergy(density: Float, pressure: Float, gamma: Float) -> Float {
        switch self {
        case .idealGas: return pressure / (gamma - 1)
        case .dissociating:
            let t = temperature(density: density, pressure: pressure)
            return Float(Double(density) * Self.dissociating(density: density, temperature: t).energy)
        case .thermallyPerfect:
            let t = pressure / (density * Self.gasConstant)
            return density * (2.5 * Self.gasConstant * t + Self.vibrationalEnergy(temperature: t))
        }
    }

    /// Pressure of air at `density` holding `internalEnergy` per volume.
    public func pressure(density: Float, internalEnergy: Float, gamma: Float) -> Float {
        switch self {
        case .idealGas: return (gamma - 1) * internalEnergy
        case .dissociating:
            // Bisection on the temperature: the energy rises with it.
            let e = Double(internalEnergy / density)
            var low = 0.0
            var high = max(e / (2.5 * 287.2), 1e-12)
            for _ in 0..<60 {
                let middle = 0.5 * (low + high)
                if Self.dissociating(density: density, temperature: Float(middle)).energy > e {
                    high = middle
                } else {
                    low = middle
                }
            }
            let t = Float(0.5 * (low + high))
            return Float(
                Double(density) * Self.dissociating(density: density, temperature: t).gasConstant * Double(t))
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
    /// True when the batch stopped just short of its time limit, leaving the last step up to it
    /// for another batch; its unused steps did nothing.
    public var stoppedShort = false
    /// True when the batch's time reached its limit; its unused steps did nothing.
    public var reachedLimit = false
    /// A conservative independent-body overlap was detected; this run cannot continue.
    public var unsupportedInteraction = false
    /// Local boundary storage could not cover the current geometry; no completed result is valid.
    public var couplingCapacityExceeded = false
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
    /// A scaled distance (m/kg^(1/3)) outside the Kingery–Bulmash curves.
    case outsideBlastCurves(Double)

    public var description: String {
        switch self {
        case .missingShader(let name): "Shader source \(name) is missing from the bundle"
        case .missingFunction(let name): "Shader function \(name) not found"
        case .allocationFailed(let what): "Could not allocate \(what)"
        case .tooManyMaterials(let count):
            "The structure has \(count) materials; at most \(StructureModel.maxMaterials) are supported"
        case .supportsMissNodes:
            "The supports do not fall on nodes of the mesh; choose an element size that divides 6 inches"
        case .outsideBlastCurves(let z):
            "A scaled distance of \(String(format: "%.2f", z)) m/kg^(1/3) is outside the Kingery–Bulmash curves (0.2 to 40)"
        case .notPlateLike(let index):
            "Solid \(index + 1) is neither a wall or slab nor a column, so it cannot be meshed with shells and beams"
        }
    }
}
