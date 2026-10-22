import Foundation
import simd

/// What the ground under a scene is made of, for the crater a charge digs in it and the share of
/// the charge's energy the air keeps. `rigid`, the default, is the reflecting ground the air model
/// has always had: no crater, and a charge on it acts on the air as one of twice its mass in free
/// air. Every other type is earth or rock, from P. W. Cooper's table of cratering efficiencies
/// (*Explosives Engineering*, 1996, Table 29.1, for bursts at zero height): it digs a crater by
/// Cooper's scaling, and a charge on it keeps 1.8 rather than 2 of its mass for the air, the middle
/// of Kinney and Graham's 1.5 to 2 (*Explosive Shocks in Air*, 1985, Example 8-7), the rest going
/// into the crater and the ground shock.
public enum GroundType: String, Codable, CaseIterable, Sendable {
    case rigid
    /// Basalt and granite (Cooper's Mice and Mine Shaft sites).
    case rock
    /// Soil over sandstone (Mixed Company, western Colorado).
    case soilOverSandstone
    /// Dry lake bed (playa, at the Nevada Test Site and in New Mexico).
    case playa
    /// Dry alluvial soil (the Nevada Test Site), Cooper's reference.
    case alluvium
    /// Clay soil over shale (Middle Gust, south-eastern Colorado).
    case clay
    /// Glacial soil (Suffield, Alberta, where Dial Pack was fired). Its crater is H. F. Cooper's
    /// wet soil's (`usesWetSoilVolumeLaw`): Suffield's craters flooded from a high water table.
    case glacialSoil
    /// Clay soil over shale and claystone (Diamond Ore, Montana).
    case clayShale
    /// Saturated soil: coral sand (Eniwetok) or saturated clay over shale (Middle Gust), the most
    /// efficient in Cooper's table; reclaimed fill below a high water table belongs here.
    case saturated

    public var title: String {
        switch self {
        case .rigid: "Rigid ground"
        case .rock: "Rock"
        case .soilOverSandstone: "Soil over sandstone"
        case .playa: "Dry lake bed"
        case .alluvium: "Dry alluvium"
        case .clay: "Clay over shale"
        case .glacialSoil: "Glacial soil"
        case .clayShale: "Clay over claystone"
        case .saturated: "Saturated soil"
        }
    }

    /// Cooper's cratering efficiency E_CR (Table 29.1, in his units); only its ratio to the
    /// alluvium's 0.5 enters the crater's size. Nil for rigid ground, which digs none.
    public var crateringEfficiency: Float? {
        switch self {
        case .rigid: nil
        case .rock: 0.20
        case .soilOverSandstone: 0.25
        case .playa: 0.45
        case .alluvium: 0.50
        case .clay: 0.55
        case .glacialSoil: 0.75
        case .clayShale: 0.95
        case .saturated: 2.00
        }
    }

    /// Whether the crater is H. F. Cooper's for wet soil (RDA-TR-2604-001, 1976): an apparent
    /// volume of 4,000 ft³ a short ton at zero height (his table 1), falling as e^(−5.2 H) with
    /// H = HOB / V^(1/3) (his equation 6), and a radius of 1.2 V^(1/3) (his equation 14). Since
    /// 22 October 2026 for glacial soil only: with the height to the charge's centre, P. W. Cooper's
    /// law and E_CR 0.75 put Suffield's resting 500-ton spheres at half their measured craters,
    /// where this law gives 0.96 and 1.17 of them (docs/cratering.md#height-of-burst).
    public var usesWetSoilVolumeLaw: Bool { self == .glacialSoil }

    /// The subgrade modulus, Pa/m, the structures' debris lands on (`SolverConfiguration
    /// .groundStiffness`) when this ground is chosen; nil for rigid ground. Rough, within the
    /// range the soft-ground setting already gives: loose or saturated soil low, rock at the top.
    public var debrisModulus: Float? {
        switch self {
        case .rigid: nil
        case .rock, .soilOverSandstone: 150e6
        case .playa, .glacialSoil, .clayShale: 100e6
        case .alluvium, .clay: 50e6
        case .saturated: 15e6
        }
    }

    /// The water table a crater in this ground meets unless told otherwise, metres below the
    /// surface: at the surface for saturated soil, which is saturated because it lies below one;
    /// nil, deep enough not to matter, for the rest.
    public var typicalWaterTable: Float? { self == .saturated ? 0 : nil }

    /// The mass, in multiples of the charge's own, that a charge resting on this ground acts on
    /// the air with, as against free air: 2 on rigid ground, 1.8 on earth or rock, with Kinney and
    /// Graham's 1.5 to 2 as its range.
    public var surfaceYieldRatio: (central: Float, low: Float, high: Float) {
        self == .rigid ? (2, 2, 2) : (1.8, 1.5, 2)
    }
}

/// The explosive, for the crater: a charge's TNT-equivalent mass gives its air blast, but how deep
/// it digs also depends on how hard it pushes the ground, through its detonation pressure.
public enum CraterExplosive: String, Codable, CaseIterable, Sendable {
    case tnt
    /// Ammonium nitrate and fuel oil, or ammonium nitrate alone, much the softer.
    case anfo

    public var title: String { self == .tnt ? "TNT" : "ANFO or ammonium nitrate" }

    /// Cooper's K, ft/lb^(1/3): 0.97 for TNT (his equation 29.3); for ANFO, 0.46 + 0.027 × 5.5,
    /// from his equation 29.5 with ANFO's Chapman–Jouguet pressure of 5.5 GPa read off his
    /// figure 29.6. (The book prints 29.5's pressure in kbar; its own figure and example 29.1 work
    /// only in GPa.)
    public var radiusConstant: Float { self == .tnt ? 0.97 : 0.46 + 0.027 * 5.5 }
}

/// A charge's crater by empirical scaling, for a burst on or above the ground. Approximation:
/// Cooper's cube-root law for the apparent radius, with Kinney and Graham's scatter.
public struct CraterEstimate: Codable, Sendable, Equatable {
    /// Where the crater is centred, on the ground under the charge, metres.
    public var centre: SIMD3<Float>
    public var ground: GroundType
    public var explosive: CraterExplosive
    /// The charge's TNT-equivalent mass, kg, and its height of burst in charge radii, from the
    /// ground to the charge's centre, as Cooper measures it: 1 for a sphere resting on the ground,
    /// 0 for a charge centred on it or below it (see `heightOfBurst(_:groundHeight:)`).
    public var mass: Float
    public var heightOfBurst: Float
    /// The share of the charge's energy that goes into the ground, by Cooper's figure 29.7, at the
    /// height the air's share is tapered on (`couplingHeight`, to the underside), so that it is
    /// the share the air lost.
    public var groundShare: Float
    /// The apparent crater, the hole left after fallback and slough have filled back the true
    /// crater the charge dug, as its radius at the original ground's level and its depth below
    /// it, metres; with the one-sigma range of the radius, a third either way (Kinney and Graham).
    /// The true crater, larger and deeper, has no open scaling and is not estimated.
    public var apparentRadius: Float
    public var apparentDepth: Float
    public var radiusRange: ClosedRange<Float>
    /// The water table, metres below the surface, where it is shallow enough to cut the crater's
    /// depth: below it the walls slump, and the depth's range is that of the slumped walls'
    /// slope (see `CraterShape.slumpedSlope`). Nil where the water table is deep.
    public var waterTable: Float?
    public var depthRange: ClosedRange<Float>?
    /// The lip of thrown and upturned earth round it: its crest's height above the original
    /// ground and radius, and how far out its ejecta reach (Glasstone and Dolan, §6.71–6.75).
    public var lipHeight: Float
    public var lipCrestRadius: Float
    public var lipRadius: Float
    /// When the charge that digs it fires, seconds after the run's start: a delayed additional
    /// charge's delay, nil for one fired at the start. The crater starts to grow then (see
    /// `grown(atTime:)`).
    public var delay: Float?

    public var apparentDiameter: Float { 2 * apparentRadius }

    /// The ground's change at horizontal distance `r` from the centre, metres, negative where
    /// earth was taken away: the apparent crater as a paraboloid from `apparentDepth` below the
    /// original ground at the centre up to it at `apparentRadius`; the lip rising on to its crest,
    /// `lipHeight` at `lipCrestRadius`; and beyond, the ejecta thinning as the 3.86th power of the
    /// distance (Glasstone and Dolan, §6.75), eased to nothing at `lipRadius`.
    public func change(atDistance r: Float) -> Float {
        if r < apparentRadius {
            let s = r / apparentRadius
            return -apparentDepth * (1 - s * s)
        }
        guard lipHeight > 0, r < lipRadius else { return 0 }
        if r < lipCrestRadius {
            let s = (r - apparentRadius) / (lipCrestRadius - apparentRadius)
            return lipHeight * (1 - (1 - s) * (1 - s))
        }
        let edge = pow(lipCrestRadius / lipRadius, 3.86)
        return lipHeight * (pow(lipCrestRadius / r, 3.86) - edge) / (1 - edge)
    }

    /// The ground's change at `point`, in the plane.
    public func change(at point: SIMD2<Float>) -> Float {
        change(atDistance: simd_distance(point, SIMD2(centre.x, centre.y)))
    }

    /// The share of the energy that couples into the ground at `heightOfBurst` charge radii:
    /// 33.3% on the surface, falling to 1% at 2.4 radii (Cooper, figure 29.7).
    public static func groundShare(heightOfBurst: Float) -> Float {
        0.333 * exp(-1.457 * max(heightOfBurst, 0))
    }

    /// The radius, metres, of a TNT sphere of `mass` kg at 1,600 kg/m³ (as the air's charge).
    public static func chargeRadius(mass: Float) -> Float {
        cbrt(3 * mass / (4 * .pi * 1600))
    }

    /// The charge's height of burst for its crater, in charge radii, from the ground to its centre,
    /// as both Coopers measure it (P. W. Cooper's example 29.2; H. F. Cooper, 1976): 1 for a sphere
    /// resting on the ground, 0 for one centred on it or below it. Until 22 October 2026 it ran to
    /// the underside; H. F. Cooper's 40 raised charges read 0.57 of the craters that gave, and 0.90
    /// of these (docs/cratering.md#against-cooper-1976).
    public static func heightOfBurst(_ charge: Charge, groundHeight: Float) -> Float {
        let radius = chargeRadius(mass: charge.mass)
        guard radius > 0 else { return 0 }
        return max(charge.position.z - groundHeight, 0) / radius
    }

    /// The height, in charge radii, that the air's share on soft ground tapers on
    /// (`Charge.coupled`) and `groundShare` is taken at: to the charge's underside, so that a
    /// sphere resting on the ground acts on the air as a surface burst. The crater's datum moved to
    /// the centre on 22 October 2026; the air's was left, so no blast moved.
    public static func couplingHeight(_ charge: Charge, groundHeight: Float) -> Float {
        let radius = chargeRadius(mass: charge.mass)
        guard radius > 0 else { return 0 }
        return max(charge.position.z - groundHeight - radius, 0) / radius
    }

    /// H. F. Cooper's wet-soil crater (`GroundType.usesWetSoilVolumeLaw`): the apparent radius, m,
    /// of `mass` kg of TNT with its centre `centreHeight` m above the ground. The scaled height
    /// H = HOB / V^(1/3) is solved with the volume it gives.
    public static func wetSoilRadius(mass: Float, centreHeight: Float) -> Float {
        let tons = Double(mass) / 907.185
        let height = Double(max(centreHeight, 0)) / 0.3048
        var volume = 4000 * tons
        for _ in 0..<60 { volume = 4000 * tons * exp(-5.2 * height / cbrt(volume)) }
        return Float(1.2 * cbrt(volume) * 0.3048)
    }

    /// Cooper's equation 29.7: the apparent crater's radius, feet, for `pounds` of TNT equivalent in
    /// earth of cratering efficiency `efficiency`, with his constant K for the explosive, at
    /// `heightOfBurst` charge radii: K (2 E_CR W e^(−1.457 HOB))^(1/3).
    public static func cooperRadius(
        pounds: Float, efficiency: Float, radiusConstant: Float, heightOfBurst: Float
    ) -> Float {
        radiusConstant * cbrt(2 * efficiency * pounds * exp(-1.457 * max(heightOfBurst, 0)))
    }

    /// Bursts higher than this, in charge radii to the centre, are air bursts that dig no crater
    /// worth the name: under 1% of the energy couples into the ground (Cooper, figure 29.7).
    public static let highestBurst: Float = 3.2

    /// The crater `charge` digs in `ground` whose surface is at `groundHeight` under it, or nil on
    /// rigid ground, for a charge too high to dig one, or one of no mass.
    public init?(
        charge: Charge, groundHeight: Float, ground: GroundType, explosive: CraterExplosive = .tnt,
        waterTable: Float? = nil, shape: CraterShape = .standard
    ) {
        guard let efficiency = ground.crateringEfficiency, charge.mass > 0 else { return nil }
        let height = Self.heightOfBurst(charge, groundHeight: groundHeight)
        guard height <= Self.highestBurst else { return nil }
        let radius: Float
        if ground.usesWetSoilVolumeLaw {
            // H. F. Cooper's law is for TNT; another explosive scales as P. W. Cooper's K does.
            radius =
                Self.wetSoilRadius(
                    mass: charge.mass, centreHeight: height * Self.chargeRadius(mass: charge.mass))
                * explosive.radiusConstant / CraterExplosive.tnt.radiusConstant
        } else {
            radius =
                Self.cooperRadius(
                    pounds: charge.mass * 2.204_62, efficiency: efficiency,
                    radiusConstant: explosive.radiusConstant, heightOfBurst: height) * 0.3048
        }
        centre = SIMD3(charge.position.x, charge.position.y, groundHeight)
        self.ground = ground
        self.explosive = explosive
        mass = charge.mass
        heightOfBurst = height
        groundShare = Self.groundShare(heightOfBurst: Self.couplingHeight(charge, groundHeight: groundHeight))
        apparentRadius = radius
        // Depth about half the radius (Cooper, p. 430; Kinney and Graham: a quarter of the diameter).
        apparentDepth = radius * shape.depthRatio
        // Below a water table the walls slump to 10–15° and the crater comes out shallower and
        // broader (Glasstone and Dolan, §6.11): a bowl whose rim slopes at θ is R tan θ / 2 deep.
        // It still reaches down to the water table, and never deeper than in dry ground.
        if let table = waterTable.map({ max($0, 0) }), table < apparentDepth {
            let dry = apparentDepth
            func slumped(_ degrees: Float) -> Float {
                min(dry, max(table, radius * tan(degrees * .pi / 180) / 2))
            }
            self.waterTable = table
            apparentDepth = slumped(shape.slumpedSlope)
            depthRange =
                slumped(shape.slumpedSlopeRange.lowerBound)...slumped(shape.slumpedSlopeRange.upperBound)
        }
        radiusRange = (radius * (1 - shape.radiusScatter))...(radius * (1 + shape.radiusScatter))
        lipHeight = apparentDepth * shape.lipHeightRatio
        lipCrestRadius = radius * shape.lipCrestRatio
        lipRadius = radius * shape.lipReachRatio
    }

    /// The craters a scene's charges dig in `ground`, with its water table `waterTable` metres
    /// down, or deep where nil.
    public static func craters(
        of scenario: Scenario, ground: GroundType, explosive: CraterExplosive = .tnt, waterTable: Float? = nil
    ) -> [CraterEstimate] {
        // The main charge fires at the start whatever delay it is given.
        ([(scenario.charge, Float?.none)] + (scenario.additionalCharges ?? []).map { ($0, $0.delay) })
            .compactMap { charge, delay in
                var crater = CraterEstimate(
                    charge: charge, groundHeight: scenario.groundHeight(at: charge.position), ground: ground,
                    explosive: explosive, waterTable: waterTable)
                crater?.delay = delay.flatMap { $0 > 0 ? $0 : nil }
                return crater
            }
    }

    public var summary: String {
        let depth =
            depthRange.map { range in
                String(
                    format: "%.1f m deep (%.1f–%.1f), slumped below the water table %.1f m down",
                    apparentDepth,
                    range.lowerBound, range.upperBound, waterTable ?? 0)
            } ?? String(format: "%.1f m deep", apparentDepth)
        return String(
            format: "Crater in %@: %.1f m across (%.1f–%.1f), %@, lip %.2f m high out to %.1f m",
            ground.title.lowercased(), apparentDiameter, 2 * radiusRange.lowerBound,
            2 * radiusRange.upperBound, depth, lipHeight, lipRadius)
    }
}

/// The crater's proportions, as multiples of the apparent radius and depth.
public struct CraterShape: Sendable, Equatable {
    /// Apparent depth over apparent radius: a half (Cooper, p. 430; Glasstone and Dolan, §6.09).
    public var depthRatio: Float
    /// The one-sigma scatter of the radius, as a fraction of it: a third (Kinney and Graham).
    public var radiusScatter: Float
    /// The lip crest's height over the apparent depth, a quarter, and its radius over the apparent
    /// radius, 1.25 (Glasstone and Dolan, §6.71); how far the continuous ejecta reach, 2.5 times
    /// the radius, the middle of their "two to three times" (§6.74).
    public var lipHeightRatio: Float
    public var lipCrestRatio: Float
    public var lipReachRatio: Float
    /// The slope, degrees, that a crater's walls slump to below a shallow water table: 10 to 15
    /// degrees (Glasstone and Dolan, §6.11), 12.5 in the middle.
    public var slumpedSlope: Float
    public var slumpedSlopeRange: ClosedRange<Float>

    public static let standard = CraterShape(
        depthRatio: 0.5, radiusScatter: 1.0 / 3, lipHeightRatio: 0.25, lipCrestRatio: 1.25,
        lipReachRatio: 2.5,
        slumpedSlope: 12.5, slumpedSlopeRange: 10...15)
}

extension Charge {
    /// The charge as the air should see it on `ground`, whose surface is at `groundHeight` under
    /// it: on rigid ground unchanged; on earth or rock with the mass that the share of its energy
    /// left to the air carries, 1.8 rather than 2 of its own for a charge on the surface, tapering
    /// back to all of it with height as the share going into the ground does (Cooper, figure
    /// 29.7).
    public func coupled(to ground: GroundType, groundHeight: Float) -> Charge {
        guard ground != .rigid, mass > 0 else { return self }
        let height = CraterEstimate.couplingHeight(self, groundHeight: groundHeight)
        let loss = 1 - ground.surfaceYieldRatio.central / 2
        var charge = self
        charge.mass = mass * (1 - loss * exp(-1.457 * height))
        return charge
    }
}

extension Scenario {
    /// The scene with every charge as the air sees it on `ground` (see `Charge.coupled`).
    public func coupled(to ground: GroundType) -> Scenario {
        guard ground != .rigid else { return self }
        var scenario = self
        scenario.charge = charge.coupled(to: ground, groundHeight: groundHeight(at: charge.position))
        scenario.additionalCharges = additionalCharges?.map {
            $0.coupled(to: ground, groundHeight: groundHeight(at: $0.position))
        }
        return scenario
    }
}

extension Terrain {
    /// The terrain with `craters` cut into it and their lips built up, for a scene that starts
    /// after the blast. Throws where a crater would reach below z = 0, the air domain's floor:
    /// raise the terrain's datum first. Nodes are taken from the existing grid, so craters
    /// smaller than its spacing barely show.
    public func cratered(_ craters: [CraterEstimate]) throws -> Terrain {
        var terrain = self
        for row in 0..<rows {
            for column in 0..<columns {
                let point = origin + SIMD2(Float(column), Float(row)) * spacing
                let change = craters.reduce(Float(0)) { $0 + $1.change(at: point) }
                guard change != 0 else { continue }
                let height = heights[row * columns + column] + change
                guard height >= 0 else { throw Terrain.Failure.invalidHeight }
                terrain.heights[row * columns + column] = height
            }
        }
        return terrain
    }
}
