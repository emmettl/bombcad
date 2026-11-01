import Foundation

// The dust a collapse raises (emmettl/bombcad-work#36; docs/whole-event.md, "Dust, stage 1"): what
// needs no GPU. Fines are made from the elements' fracture and crushing work and from a share of
// the rubble's impact losses, each divided by an energy per kilogram of fines, and carried by the
// air as two size classes that settle at their terminal speeds (BlastCore's `AirDust`). Here are
// the coefficients, the settling speeds, and the readings of a dust field: what is airborne, where
// it has settled, how high and how far the cloud reaches, and the mass in each column of air.

/// The coefficients of a collapse's dust. Illustrative: no study measures the fines concrete makes
/// for the energy its fracture dissipates (docs/whole-event.md, "Dust, stage 1"; data-wanted.md).
public struct DustSettings: Codable, Sendable, Hashable {
    /// J per kilogram of fines (below about 100 µm) made. 5×10⁴ J/kg, within 2×10⁴–2×10⁵: rock's
    /// drop-weight tests give 45–150 kJ/kg of input energy for fines below 100 µm (Ouchterlony,
    /// Sanchidrián and Genç 2021, the fragmentation-energy fan of Banini's hornfels), Bond's work
    /// indices of cement clinker and limestone 40–60 kJ/kg to grind to 100 µm.
    public var energyPerKilogram: Double = 5e4
    /// The share of the rubble's impact losses that goes into making fines, the rest to heat,
    /// waves and friction: 0.2, within 0.05–0.5 (at most 43% to fracture in Bbosa's 2007
    /// split-Hopkinson tests on ore).
    public var impactShare: Double = 0.2
    /// The share of the fines in the fine class: 0.15, within 0.05–0.35 (the World Trade Center's
    /// settled dust 0.5–0.7 km away held 3–5% of its material below 53–75 µm below 10 µm, Lioy et
    /// al. 2002, biased low by what stayed aloft; a Schuhmann distribution of modulus 0.5–1 gives
    /// 0.1–0.32).
    public var fineShare: Double = 0.15
    /// The two classes' diameters, m: the fine class stands for PM10, the coarse for the rest.
    public var fineDiameter: Double = 10e-6
    public var coarseDiameter: Double = 100e-6
    /// The fines' own density, kg/m³ (concrete's cement paste, sand and aggregate).
    public var particleDensity: Double = 2500
    /// The air the fines settle through: its density (kg/m³) and dynamic viscosity (Pa s).
    public var airDensity: Double = 1.2
    public var airViscosity: Double = 1.81e-5
    public var gravity: Double = 9.81

    public init() {}

    /// The coefficients the whole-event bench takes with `--dust`.
    public static let standard = DustSettings()

    /// These settings with the energy per kilogram scaled by `factor` (the sensitivity runs).
    public func withEnergy(times factor: Double) -> DustSettings {
        var settings = self
        settings.energyPerKilogram *= factor
        return settings
    }

    /// The terminal settling speed (m/s) of a sphere of `diameter` m: Stokes's law, corrected for
    /// inertia by Schiller and Naumann's drag (C_D = 24/Re (1 + 0.15 Re^0.687)), solved by fixed
    /// point. 10 µm: 7.5 mm/s; 100 µm: 0.52 m/s against Stokes's 0.75.
    public func settlingSpeed(diameter: Double) -> Double {
        let stokes = (particleDensity - airDensity) * gravity * diameter * diameter / (18 * airViscosity)
        var speed = stokes
        for _ in 0..<60 {
            let reynolds = airDensity * speed * diameter / airViscosity
            speed = stokes / (1 + 0.15 * pow(reynolds, 0.687))
        }
        return speed
    }

    public var fineSettling: Double { settlingSpeed(diameter: fineDiameter) }
    public var coarseSettling: Double { settlingSpeed(diameter: coarseDiameter) }

    /// Fines (kg) from `work` joules of fracture and crushing, and from `impactLoss` joules of the
    /// rubble's impact losses.
    public func fines(fractureWork work: Double, impactLoss: Double = 0) -> Double {
        (work + impactShare * impactLoss) / energyPerKilogram
    }

    /// The mass extinction coefficient (m²/kg) of a class of `diameter`: the geometric limit,
    /// 3 Q / (2 ρ d) with an extinction efficiency Q of 2. 10 µm: 120 m²/kg; 100 µm: 12 m²/kg.
    public func extinction(diameter: Double) -> Double { 3.0 / (particleDensity * diameter) }
}

/// Where the fines made have gone, kg: the ledger of a dust field, which closes to rounding.
public struct DustLedger: Codable, Sendable, Hashable {
    /// Made, by class (fine, coarse), and by source: the elements' fracture and crushing, the
    /// rubble's impacts, and what was made outside the air's domain (lost at once).
    public var made: SIMD2<Double> = .zero
    public var fromElements: Double = 0
    public var fromImpacts: Double = 0
    public var madeOutside: Double = 0
    /// In the air, by class, and of it in solid cells (made inside a solid or shut in by it).
    public var airborne: SIMD2<Double> = .zero
    public var inSolids: SIMD2<Double> = .zero
    /// Settled, by class: on the ground beyond the plan, on the ground within it (under the pile),
    /// and on solids above the ground (the floors, the standing walls' heads, the podium).
    public var onGroundOutside: SIMD2<Double> = .zero
    public var onGroundWithin: SIMD2<Double> = .zero
    public var onSolids: SIMD2<Double> = .zero
    /// Out through the domain's open faces, by class (and what was made outside it).
    public var leftDomain: SIMD2<Double> = .zero

    public init() {}

    public var deposited: SIMD2<Double> { onGroundOutside + onGroundWithin + onSolids }
    public var total: Double { made.x + made.y + madeOutside }
    /// What the ledger cannot place: made less airborne, deposited and gone (zero but for rounding).
    public var unplaced: Double {
        total - (airborne.x + airborne.y) - (deposited.x + deposited.y) - (leftDomain.x + leftDomain.y)
            - madeOutside
    }
}

/// A dust field's cloud, read at one time.
public struct DustCloudReading: Codable, Sendable, Hashable {
    /// The concentration (kg/m³ of both classes) the cloud is bounded at.
    public var threshold: Double
    /// Cells at or above it, and the volume they fill (m³).
    public var cells: Int
    public var volume: Double
    /// The highest such cell's top, m above the ground; the furthest such cell's centre from the
    /// plan's edge (m, horizontally; 0 within it); and whether any lies against an open face.
    public var top: Double
    public var reach: Double
    public var atOpenFace: Bool
    /// The highest concentration anywhere in the air, kg/m³.
    public var peak: Double
}

/// The readings of a dust field on a uniform grid of `cellSize` cubes from the origin, x fastest.
public struct DustField {
    public var dims: SIMD3<Int>
    public var cellSize: Double
    /// Each cell's density of fines in each class, kg/m³.
    public var fine: [Float]
    public var coarse: [Float]
    /// Whether each cell is solid (the air's mask).
    public var solid: [Bool]

    public init(dims: SIMD3<Int>, cellSize: Double, fine: [Float], coarse: [Float], solid: [Bool]) {
        precondition(
            fine.count == dims.x * dims.y * dims.z && coarse.count == fine.count && solid.count == fine.count)
        self.dims = dims
        self.cellSize = cellSize
        self.fine = fine
        self.coarse = coarse
        self.solid = solid
    }

    /// The fines in the air (by class), and of them in solid cells, kg.
    public func airborne() -> (all: SIMD2<Double>, inSolids: SIMD2<Double>) {
        let volume = cellSize * cellSize * cellSize
        var all = SIMD2<Double>.zero
        var held = SIMD2<Double>.zero
        for n in fine.indices {
            let here = SIMD2(Double(fine[n]), Double(coarse[n])) * volume
            all += here
            if solid[n] { held += here }
        }
        return (all, held)
    }

    /// The cloud bounded at `threshold` kg/m³ (both classes), measured from the plan
    /// `plan` (its corners, m, in x and y), in the air's own cells (solid ones left out). Open faces
    /// are every face but the ground's.
    public func cloud(threshold: Double, plan: (min: SIMD2<Double>, max: SIMD2<Double>)) -> DustCloudReading {
        var reading = DustCloudReading(
            threshold: threshold, cells: 0, volume: 0, top: 0, reach: 0, atOpenFace: false, peak: 0)
        for z in 0..<dims.z {
            for y in 0..<dims.y {
                for x in 0..<dims.x {
                    let n = x + dims.x * (y + dims.y * z)
                    guard !solid[n] else { continue }
                    let c = Double(fine[n]) + Double(coarse[n])
                    reading.peak = max(reading.peak, c)
                    guard c >= threshold else { continue }
                    reading.cells += 1
                    reading.top = max(reading.top, Double(z + 1) * cellSize)
                    let centre = SIMD2(Double(x) + 0.5, Double(y) + 0.5) * cellSize
                    let outside = SIMD2(
                        max(plan.min.x - centre.x, 0, centre.x - plan.max.x),
                        max(plan.min.y - centre.y, 0, centre.y - plan.max.y))
                    reading.reach = max(reading.reach, (outside * outside).sum().squareRoot())
                    if x == 0 || y == 0 || x == dims.x - 1 || y == dims.y - 1 || z == dims.z - 1 {
                        reading.atOpenFace = true
                    }
                }
            }
        }
        reading.volume = Double(reading.cells) * cellSize * cellSize * cellSize
        return reading
    }

    /// The mass of fines over each column of the ground, kg/m² (both classes, x fastest, then y):
    /// the precursor of the cloud's optical depth.
    public func columnMass() -> [Double] {
        var columns = [Double](repeating: 0, count: dims.x * dims.y)
        for z in 0..<dims.z {
            for y in 0..<dims.y {
                for x in 0..<dims.x {
                    let n = x + dims.x * (y + dims.y * z)
                    columns[x + dims.x * y] += (Double(fine[n]) + Double(coarse[n])) * cellSize
                }
            }
        }
        return columns
    }

    /// The optical depth of each column straight down, from each class's mass extinction coefficient
    /// (m²/kg): an estimate of what the cloud hides, looked at from above.
    public func columnOpticalDepth(fineExtinction: Double, coarseExtinction: Double) -> [Double] {
        var columns = [Double](repeating: 0, count: dims.x * dims.y)
        for z in 0..<dims.z {
            for y in 0..<dims.y {
                for x in 0..<dims.x {
                    let n = x + dims.x * (y + dims.y * z)
                    columns[x + dims.x * y] +=
                        (Double(fine[n]) * fineExtinction + Double(coarse[n]) * coarseExtinction) * cellSize
                }
            }
        }
        return columns
    }
}
