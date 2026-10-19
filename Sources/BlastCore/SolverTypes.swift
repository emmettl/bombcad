import simd

/// Faces of the domain that reflect (rigid wall). Faces not listed let waves leave.
/// How the domain's open faces are treated (see `SolverConfiguration.openFaces`).
public enum OpenFaces: String, Sendable, Hashable, Codable, CaseIterable {
    case copy
    case farField
}

/// Bit 6 of the uniforms' boundary flags: the open faces stand ambient air beyond them.
let farFieldFlag: UInt32 = 1 << 6

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
    /// What runs start from since 15 October 2026 (the app's new projects, `BombCAD run`, the
    /// benches and the validation's harnesses): afterburning and hot air, which keep the open
    /// blast's incident and suction impulses within a few per cent and a closed room's pressure
    /// within 8% of the references, and far-field open faces, which let the burning products
    /// out of a domain hardly bigger than the fireball (docs/validation.md, "Afterburning by
    /// default"). `SolverConfiguration()` stays the bare numerical core: an ideal gas, no
    /// afterburning and faces that copy, which the exact solutions and conservation checks test.
    /// The harnesses that start here, each with an explicit choice of gas and faces: the air
    /// benches (`validate`, `gas`, `throughput`), rooms (`ChamberTest`), Wu and Wang
    /// (`TwoFaceSlabTests`), Chiquito (`CloseInSlabTest`), Hupfauf (`ContactSlabTest`), Alsubaei
    /// (`PerimeterWallTests`), Keys in the open (`MasonryDebrisTests.run`), the coupled anchorage
    /// wall, the validation ensemble's wall, Dial Pack, the landscape, buildings and terrain
    /// profiles. On the bare core, deliberately: the numerical studies (the wedge's reflection, the
    /// bubble, the mixing layer, the digest, the experimental rigid bodies), the deflagrations,
    /// whose gas is their own, Keys' tunnel, driven by an inflow at an open face, and the blind
    /// tests, which keep the air of their frozen commits.
    public static var recommended: SolverConfiguration {
        var configuration = SolverConfiguration()
        configuration.afterburning = true
        configuration.airModel = .thermallyPerfect
        configuration.openFaces = .farField
        // The fine one-dimensional start, since 18 October 2026 (docs/air-blast-model.md, "A finely
        // resolved start"); the harnesses validated on the balloon before then take `balloonStart`.
        configuration.mappedCharge = true
        // The fireball's gas losing the heat it radiates, since 19 October 2026
        // (docs/thermal-radiation.md, "The gas losing what it radiates").
        configuration.radiativeCooling = RadiativeCooling()
        return configuration
    }

    /// This configuration as the comparisons recorded before 18 October 2026 were run: the charge
    /// started from the balloon of hot gas, the fireball keeping the heat it radiates. Each harness
    /// so pinned is listed in validation.md, "Still on the balloon start", until it is rerun.
    public var balloonStart: SolverConfiguration {
        var configuration = self
        configuration.mappedCharge = false
        configuration.radiativeCooling = nil
        return configuration
    }

    /// Coarse boundary storage for multiple structures, read by `setStructures`.
    /// Automatic keeps dense storage when smaller; a single body retains its dense path.
    public var bodyCouplingLayout: BodyCouplingLayout = .automatic
    /// Independent bodies that come close meet through contact (see `BlastSolver`); without it,
    /// their envelopes or cells overlapping stops the run as an unsupported interaction.
    public var interBodyContact = true
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
    /// Bring each structure to rest under its own weight before the blast reaches it
    /// (`BlastSolver.settleStructures()`), as it stood before the charge went off. Off, a structure
    /// takes its weight as the run starts, sags about twice its static deflection and is still
    /// swinging when the blast arrives. A body whose gravity is zero, or whose motion the scene
    /// sets, is never settled; with this off nothing is done, so runs are as before.
    public var settlesStructures = true
    /// Sweep only the tiles of 8 x 8 x 8 cells that the blast has reached (or is about to),
    /// leaving air that is still in its initial uniform state untouched. The answer is the same
    /// either way. Read at `restart()`.
    public var skipStillAir = true
    /// How the air's pressure follows from its energy (see `AirModel`). Hot air in `recommended`.
    public var airModel: AirModel = .idealGas
    /// Burn the detonation products in the air they mix with (afterburning), releasing
    /// `afterburnEnergy` per kilogram of charge as far as the oxygen allows. Read at `restart()`;
    /// takes effect for charges deposited after it is set. On in `recommended`.
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
    /// onto the grid once its shock has spread as far as it can before meeting anything (0.8 of the
    /// way to the nearest block, structure, ground that is not flat or open face, at most
    /// `mappedChargeCells`), instead of from a sphere of hot gas a few cells across; the balloon
    /// where that is under 3 cells. With the ideal gas or hot air, and afterburning burnt in the
    /// one-dimensional solution as on the grid; not with dissociating air, gravity, sub-grid mixing,
    /// radiative cooling, the afterburning limit or more than one charge (see
    /// docs/air-blast-model.md, "A finely resolved start").
    public var mappedCharge = false
    /// The furthest, in cells, a mapped charge's blast is solved in one dimension before it is
    /// mapped (if nothing is nearer). 64 brought the incident peaks to 99–117% of Kingery–Bulmash
    /// on 0.25 m cells, where 16 left them at 67–89%.
    public var mappedChargeCells: Float = 64
    /// The furthest, in scaled distance (m/kg^(1/3)), a mapped charge's blast is solved in one
    /// dimension: past it the grid carries the wave well enough, and the one-dimensional solution's
    /// cost, which grows as the square of its reach in charge radii, stays within seconds.
    public var mappedChargeScaledReach: Float = 6
    /// Whether the mapped charge's products have their own equation of state in the
    /// one-dimensional solution (JWL, TNT's from the LLNL handbook) rather than the air's gas.
    /// They are dilute, and press as the air's gas nearly would, by the time they are mapped. A
    /// study (`blastbench products`, `closeair --products`), off by default.
    public var mappedChargeProducts = false
    /// With afterburning, whether the products burn in the one-dimensional solution, or are carried
    /// unburnt to burn on the grid once mapped, as the balloon's do.
    public var mappedChargeBurns = true
    /// The one-dimensional fireball's turbulent mixing of products and air, as an eddy
    /// diffusivity per cube root of the charge's mass, m^2/s/kg^(1/3) (see `SphericalBlast`): the
    /// mixing the grid's cells give the balloon's products, which a fine one-dimensional grid does
    /// not. 16 was fitted once, on 10 kg and 0.5 m cells, and checked on 1 and 100 kg and 0.25 m.
    public var mappedChargeMixing: Float = 16
    /// Once no air cell is further than this fraction of ambient pressure from ambient, and
    /// there is a structure to keep following, the air is frozen and only the structure is
    /// advanced. Zero disables this. The default, 2 kPa at sea level, is small beside the
    /// weight of a concrete slab; the winds left behind by a blast take seconds to fall below it.
    public var airSleepThreshold: Float = 0.02
    /// The air is also frozen once this many acoustic crossing times of the domain have passed,
    /// by when the blast has long gone. A collapsing structure keeps stirring the air near it,
    /// so the pressure test alone may never be met. Zero disables this.
    public var airSleepCrossings: Float = 5
    /// How far beyond the structure's starting bounds (m, along x, y and z) the air's mask
    /// follows it and loads its loose debris. Debris that flies further keeps flying but feels no
    /// air; walls thrown tens of metres down a shock tube need it larger.
    public var debrisReach = SIMD3<Float>(4, 4, 3)
    /// What the domain's open (not reflective) faces do. `.copy` copies the state inside outward,
    /// which lets a shock out but holds whatever pressure the air near the face settles to: a
    /// domain hardly bigger than a fireball traps its burning products, and one that loses air
    /// through them drains below ambient. `.farField` stands still ambient air beyond each open
    /// face and treats the waves across it as acoustic (the one leaving from inside, the one
    /// entering from the ambient), so a wave passes out, late pressure relaxes to ambient and
    /// products leave. On Wang's slab, whose 10 kg charge stands 0.4 m from a face, the gauges'
    /// impulse with afterburning is within 4% of a domain four times as wide, where copying
    /// gave 3.8 times it. Not with gravity, whose ambient changes with height: there the faces
    /// copy. Far field in `recommended`.
    public var openFaces: OpenFaces = .copy
    /// Whether structures' outlines are cut cells: a cell a structure's solids cross holds the air
    /// it has and its faces open as far as they are (`StructureCutGeometry`), rather than the
    /// structure taking whole cells. From the structures as built, without refinement. Off by default.
    public var structureCutCells = false
    /// Whether a gauge beside a wall (a solid cell, or a reflective face of the domain, within a cell
    /// of its point) reads the pressure at the wall: its cell's gas against its mirror across the
    /// wall, two shocks or two rarefactions, rather than the cell's mean. A reflected shock is
    /// smeared over cells and the cell beside the wall reads it low (69% of Kingery–Bulmash's
    /// reflected peak at 2 m/kg^(1/3) on 0.25 m cells for 100 kg); read at the wall it comes within
    /// what the incident shock had lost on its way (93%). Off by default.
    public var gaugesReadWallPressure = false
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
    /// Holds refinement in the air beside envelope buildings' recorded faces (a cell either side)
    /// while it is loaded, its overpressure past this many pascals either way, so that their
    /// façades' reflected loads stay on the finest cells through their positive phase rather
    /// than only as the shock passes. Nil, the default, holds nothing.
    public var refinementHoldsEnvelopes: Float?
    /// Holds refinement likewise in the air about each structure (a cell beyond each of its
    /// solids, both faces of a wall or slab), past this many pascals: its load after the shock has
    /// passed (the reflections, the second swing, the venting) on the finest cells. With both
    /// set, the band holds past the lower. Nil holds nothing.
    public var refinementHoldsStructures: Float?
    /// No air is refined more than this many metres above the ground beneath it (the terrain, or
    /// the domain's floor), but for the refined blocks that hold a cell below it, up to four cells
    /// higher, and the air within `refinementCeilingExemption` of a charge: over a district, the shock's top above the roofs, which loads no façade
    /// (docs/beirut-2020.md, "What cell size the glass and the damage need"). It caps the bands held
    /// beside envelopes and structures (`refinementHoldsEnvelopes`, `refinementHoldsStructures`)
    /// too: a face above it is loaded on the coarse cells. Nil, the default, refines at any height.
    public var refinementCeiling: Float?
    /// About each charge, out to this many m/kg^(1/3), the air is refined whatever the ceiling: a
    /// charge raised above it keeps its near field sharp.
    public static let refinementCeilingExemption: Float = 3
    /// Refinement only inside these boxes (metres, the domain's frame): a coarse cell whose
    /// centre lies in none of them is never refined, as above the ceiling, and nor are the bands
    /// held in it. For refinement steered by a decision (docs/refinement-steering.md): the boxes
    /// about the components whose outcome is in doubt. Nil, the default, refines anywhere.
    public var refinementConfinedTo: [RefinementRegion]?
    /// How close, in cells of the grid a level refines, such a pair must come to a block for the
    /// block to be refined too: the margin kept around the shock. A shock moves under half a cell
    /// a step and the blocks are placed afresh every step, so 1 still holds it. Until 15 October
    /// 2026 it was 2; 1 moves the validation's peaks and impulses by under 1.3% and refines a
    /// fifth fewer blocks (docs/performance.md, "Where a refined run's GPU time goes").
    public var refinementMargin = 1
    /// Levels of refinement, 1 or 2, each by `refinement`: with 2, the blocks of the first level
    /// that the shock crosses are refined again, as the first refines the coarse grid, so that
    /// near the shock the cells are `refinement` squared times finer. Read at `restart()`.
    public var refinementLevels = 1
    /// The jump that refines the second level, as `refinementThreshold` does the first; nil
    /// for the same.
    public var refinementFinerThreshold: Float?
    /// Let each refined level take only as many of its r substeps, in each step of the grid above
    /// it, as its own fastest wave needs, rather than always r: the step is set by the fastest
    /// wave anywhere, which is often in the hot, unrefined middle of the fireball, while the
    /// patches follow the slower shock. The coarse step is unchanged; mass, momentum and energy
    /// stay conserved across every level's edge. Off by default.
    public var refinementOwnSteps = false
    /// The most GPU memory the refined blocks may take, in bytes; where the shock would need more,
    /// the rest of it stays coarse. About 63 kB a block at ratio 2, 364 kB at ratio 4. With two
    /// levels, a third of it goes to the first and two thirds to the second. The pools start
    /// smaller (`refinementStartMemory`) and grow ahead of the blocks in use, so that a run takes
    /// only the memory its shock needs, and steps as one given all of this from the start would.
    public var refinementMemory = 1 << 30
    /// The memory the refined blocks' pools start with, shared as `refinementMemory` is, before
    /// they grow; nil to start with all of `refinementMemory`. The run is the same either way.
    public var refinementStartMemory: Int? = 64 << 20
    /// How finely solid elements are sampled for the air's outline: points per air cell along each
    /// axis, of each level's cells. nil, the default, samples each element once, at its centre, or
    /// at points a cell apart where it is larger: a layer of elements then fills whichever cell
    /// its centres fall in, and centres on a cell's face flip it with microns of movement. 2 or 4
    /// counts each element's volume to half or a quarter of a cell.
    public var structureMaskSampling: Int?
    /// The share of an air cell the structure's samples must fill for the cell to be solid. nil,
    /// the default, for a third, which keeps a layer a third of a cell thick but puts the wall a
    /// sixth of a cell outside the face on average; a half places it without bias, losing thinner
    /// layers.
    public var structureMaskFill: Float?
    /// Count each sample of an element as a box, by the share of it in each air cell it overlaps,
    /// rather than whole in the cell holding its centre: a cell then fills as the structure moves
    /// into it, and one whose face a layer of centres lies on does not flicker. A cell then turns
    /// solid an eighth above the fill threshold and opens an eighth below it, so that a fill lying
    /// on the threshold does not flicker either. On by default since 16 October 2026; off, the
    /// outline counts each element at its centre, as before.
    public var structureMaskOverlap = true
    /// The luminous gas losing the heat it radiates (see `RadiativeCooling`); nil, the default,
    /// for none. Read at `restart()`.
    public var radiativeCooling: RadiativeCooling?
    /// Gravity acting on the air, which then starts at rest in a hydrostatic atmosphere (see
    /// `AirGravity`); nil, the default, for none. Read when the air is filled.
    public var gravity: AirGravity?
    /// Sub-grid turbulent mixing in the air (see `SubgridMixing`); nil, the default, for none.
    public var mixing: SubgridMixing?
    /// For benchmarks: the two outermost cells on each x and y side copy the far side's before
    /// every sweep, so that the rest of the grid is periodic in x and y. Not for scenes.
    public var periodicSides = false
    /// With afterburning, an extinction limit: the products burn only where the mixture can keep a
    /// flame going (see `AfterburnLimit`); nil, the default, for wherever they meet oxygen.
    public var afterburnLimit: AfterburnLimit?
    /// The terrain's ground surface as cut cells rather than whole ones (see `TerrainCutGeometry`):
    /// slopes are slopes, not staircases. On by default; false for the staircase. Read when a scene
    /// is loaded (see `cutsTerrain(of:)`).
    public var terrainCutCells = true
    /// Soft ground under the structures' debris (`StructureSolver.groundStiffness`): the soil's
    /// subgrade modulus in Pa/m, a Winkler bed the debris lands on, or nil for the hard ground (the
    /// default). For debris falling on earth, not on paving or a slab; compared once, on Keys's
    /// brick walls (docs/validation.md#brick-walls-debris). The air sees the ground as hard either
    /// way. Read when a scene is loaded.
    public var groundStiffness: Float?
    /// What the ground is made of, for the air (`GroundType`): on earth or rock a charge near it
    /// keeps a smaller share of its energy for the air (`Charge.coupled`), the rest going into its
    /// crater and the ground shock. Nil, the default, for the rigid, reflecting ground. The air's
    /// ground stays where it was before the blast either way: the crater forms after it has gone.
    /// Read when a scene is loaded.
    public var ground: GroundType?

    /// The soil's subgrade modulus for soft ground: medium dense sand under a footing about a metre
    /// wide (as `Anchorage.soil`), and the range foundation texts give from loose sand to dense
    /// sand and stiff clay (J. E. Bowles, *Foundation Analysis and Design*; from memory).
    public static let soilSubgradeModulus: Float = 50e6
    public static let soilSubgradeRange: ClosedRange<Float> = 10e6...150e6

    public init() {}

    /// Whether `scenario`'s terrain is cut through the cells when it loads: it has slopes and cut
    /// cells are on. For now, refined air with a structure standing on the terrain keeps the
    /// staircase: the structure shuts in thin cut cells under it, which are made solid on the
    /// coarse grid (`remaskCapSlivers`) but not yet on a level of refinement.
    public func cutsTerrain(of scenario: Scenario, cellSize: Float = 0) -> Bool {
        terrainCutCells && (scenario.terrain.map { !$0.isFlat } ?? false)
            && !(refinement > 1 && scenario.structureStandsOnTerrain(cellSize: cellSize))
    }
}

/// Primitive gas state in SI units.
/// A box of the domain in which air may be refined (`SolverConfiguration.refinementConfinedTo`).
public struct RefinementRegion: Sendable, Hashable {
    public var low: SIMD3<Float>
    public var high: SIMD3<Float>

    public init(low: SIMD3<Float>, high: SIMD3<Float>) {
        self.low = low
        self.high = high
    }
}

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
    /// The number of experimental rigid boxes in the air (see `ExperimentalBoxGeometry`).
    var experimentalBox: UInt32 = 0
    var couplingMapCount: UInt32 = 0
    var parentSide: UInt32 = 0
    var parentTileNx: UInt32 = 0
    var parentTileNy: UInt32 = 0
    var parentScale: UInt32 = 0
    var childTileNx: UInt32 = 0
    var childTileNy: UInt32 = 0
    var childTileNz: UInt32 = 0
    var gravity: Float = 0
    var gravityLapse: Float = 0
    var gravityT0: Float = 0
    var gravityP0: Float = 0
    /// 1 when the air carries a deflagration's unburnt mixture (see `Deflagration.metal`).
    var deflagration: UInt32 = 0
    var mixingCoefficient: Float = 0
    var mixingPrandtl: Float = 0
    var ignitionTemperature: Float = 0
    var limitFlameTemperature: Float = 0
    /// Sub-grid mixing's model: 0 Smagorinsky's, 1 the σ-model (see `SubgridMixing.Model`).
    var mixingModel: UInt32 = 0
    var refineMargin: UInt32 = 1
    var ownSteps: UInt32 = 0
    var refineLevel: UInt32 = 0
    var sweepAxes: UInt32 = 0
    var gaugeWalls: UInt32 = 0
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
    var levelSubsteps0: UInt32 = 0
    var levelSubsteps1: UInt32 = 0
    var levelStep0: Float = 0
    var levelStep1: Float = 0
    var levelSubstepSum0: UInt32 = 0
    var levelSubstepSum1: UInt32 = 0
    /// The run's clock in ticks of 2^-40 s (`runClock` in Solver.metal), low and high words.
    var clockLow: UInt32 = 0
    var clockHigh: UInt32 = 0

    /// A tick of the run's clock, s.
    static let tick = 1.0 / 1_099_511_627_776.0
    var clock: UInt64 { UInt64(clockLow) | UInt64(clockHigh) << 32 }
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
    /// Blocks of the second level refined at the end of the batch (0 without one).
    public var finerRefinedTiles = 0
    /// Substeps the first refined level took per step, and the second per step of the coarse
    /// grid, averaged over the batch's steps: r and r squared unless they take their own
    /// (`SolverConfiguration.refinementOwnSteps`); 0 without the level.
    public var firstLevelSubsteps = 0.0
    public var secondLevelSubsteps = 0.0
    /// True when the batch stopped just short of its time limit, leaving the last step up to it
    /// for another batch; its unused steps did nothing.
    public var stoppedShort = false
    /// True when the batch's time reached its limit; its unused steps did nothing.
    public var reachedLimit = false
    /// A conservative independent-body overlap was detected; this run cannot continue.
    public var unsupportedInteraction = false
    /// Independent bodies came close in this batch, which stopped early so that the next could
    /// encode them in contact.
    public var contactStarted = false
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
    /// A discrete bar that does not lie wholly within the body's concrete.
    case barOutsideConcrete(Int, SIMD3<Float>)
    /// Timber in solid elements, which have no law for it: it is meshed as shells and beams.
    case timberNeedsShells(String)
    /// The charge is inside a block, a building, the ground or a structure, where it would
    /// release no energy into the air (`Scenario.chargeIsBlocked`).
    case chargeBlocked(SIMD3<Float>)

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
        case .barOutsideConcrete(let index, let point):
            "Discrete bar \(index + 1) does not lie wholly within the structure's elements: at \(point)"
        case .timberNeedsShells(let name):
            "\(name) is timber, which is meshed with shells and beams; choose shells for the structure"
        case .chargeBlocked(let point):
            String(
                format:
                    "The charge at %.1f, %.1f, %.1f m is inside a block, a building, the ground or a structure, where it would release no energy",
                point.x, point.y, point.z)
        case .notPlateLike(let index):
            "Solid \(index + 1) is neither a wall or slab nor a column, so it cannot be meshed with shells and beams"
        }
    }
}
