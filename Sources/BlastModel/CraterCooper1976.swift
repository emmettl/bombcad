import Foundation

/// H. F. Cooper Jr.'s high-explosive craters by height and depth of burst and by ground
/// (*Estimates of Crater Dimensions for Near-Surface Explosions of Nuclear and High-Explosive
/// Sources*, RDA-TR-2604-001, R&D Associates for Lawrence Livermore Laboratory, 1976; OSTI 6696719),
/// against the crater BombCAD digs (`CraterEstimate`). `Fixtures/Cooper1976/craters.json` holds his
/// table 1, figure 7's media, his height-of-burst and shape laws, and the points of figures 9–12
/// digitised (docs/cratering.md#against-cooper-1976).
///
/// Cooper gives each crater as its apparent volume per ton, V/Y (ft³/ton), at the height of burst
/// scaled by that volume, H = HOB / V^(1/3); his radius is about 1.2 V^(1/3) (1.1–1.4, his
/// equation 14). BombCAD gives a radius, from P. W. Cooper's law, at a height in charge radii to
/// the charge's underside. So each point is set where BombCAD would put the same charge: its centre
/// H V^(1/3) above the ground, its underside a charge radius lower.
public enum CooperCraters1976 {
    /// The four generic media of Cooper's table 1, each one of figures 9–12.
    public enum Medium: String, Codable, CaseIterable, Sendable {
        case drySoil, wetSoil, softRock, hardRock

        public var title: String {
            switch self {
            case .drySoil: "Dry soil"
            case .wetSoil: "Wet soil"
            case .softRock: "Soft rock"
            case .hardRock: "Hard rock"
            }
        }

        /// BombCAD's ground types that fall in this medium, the first its stand-in: dry alluvium
        /// for dry soil (Cooper's reference, among playa and dry clay); saturated soil for wet
        /// (Cooper's wet coral sand, wet sand and wet clay), with the clay over claystone of
        /// Diamond Ore, a wet clay shale in his figure 6; soil over sandstone for soft rock, its
        /// Mixed Company site being one of figure 11's; rock for hard rock. Suffield's glacial soil
        /// is in none of his figures.
        public var grounds: [GroundType] {
            switch self {
            case .drySoil: [.alluvium, .playa, .clay]
            case .wetSoil: [.saturated, .clayShale]
            case .softRock: [.soilOverSandstone]
            case .hardRock: [.rock]
            }
        }
    }

    public struct Range: Decodable, Sendable {
        public var best: Double
        public var range: [Double]
    }

    public struct Fixture: Decodable, Sendable {
        public struct TableRow: Decodable, Sendable {
            public var medium: Medium
            public var v0Range: [Double]
            public var v0: Double
        }
        public struct Shape: Decodable, Sendable {
            public var radius: Range
            public var depth: Range
        }
        public struct HeightOfBurst: Decodable, Sendable {
            public var exponent: Double
            public var validWithin: Double
        }
        public var tableOne: [TableRow]
        public var heightOfBurst: HeightOfBurst
        public var shape: Shape
        /// Each medium's points, as [H, V/Y in ft³/ton].
        public var points: [String: [[Double]]]

        public func points(_ medium: Medium) -> [(h: Double, efficiency: Double)] {
            (points[medium.rawValue] ?? []).map { ($0[0], $0[1]) }
        }

        public func row(_ medium: Medium) -> TableRow? { tableOne.first { $0.medium == medium } }
    }

    public static func fixture(from url: URL) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// A short ton, the ton of Cooper's cratering efficiencies, in pounds and kilograms.
    public static let tonPounds = 2000.0
    public static let tonKilograms = 907.185

    /// The radius of a ton of TNT as the air's charge (1,600 kg/m³), in feet.
    public static var chargeRadiusFeet: Double {
        Double(CraterEstimate.chargeRadius(mass: Float(tonKilograms))) / 0.3048
    }

    /// Where BombCAD measures the height of burst from.
    public enum Datum: String, Sendable, CaseIterable {
        /// The charge's underside, as `CraterEstimate.heightOfBurst` did until 22 October 2026.
        case underside
        /// Its centre, as Cooper, P. W. Cooper's example 29.2 and BombCAD since then do.
        case centre
    }

    /// BombCAD's apparent radius, ft per ton^(1/3), for a ton of TNT on `ground` whose centre is
    /// `centreHeight` charge radii above the surface (negative below it, which BombCAD counts as on
    /// it).
    public static func bombcadRadius(ground: GroundType, centreHeight: Double, datum: Datum = .centre)
        -> Double
    {
        let height = max(datum == .underside ? centreHeight - 1 : centreHeight, 0)
        return Double(
            CraterEstimate.cooperRadius(
                pounds: Float(tonPounds), efficiency: ground.crateringEfficiency ?? 0,
                radiusConstant: CraterExplosive.tnt.radiusConstant, heightOfBurst: Float(height)))
    }

    /// BombCAD's apparent crater volume for that radius, ft³ per ton: its paraboloid, depth half
    /// the radius, π R² D / 2.
    public static func bombcadVolume(radius: Double, depthRatio: Double = 0.5) -> Double {
        .pi * radius * radius * (radius * depthRatio) / 2
    }

    /// One of Cooper's craters set beside BombCAD's for the same charge and height.
    public struct Pair: Sendable {
        public var medium: Medium
        public var ground: GroundType
        /// Cooper's scaled height, and the charge's centre above the ground in charge radii.
        public var h: Double
        public var centreHeight: Double
        public var efficiency: Double
        /// His radius (1.2 V^(1/3)) over BombCAD's; his volume over BombCAD's paraboloid's.
        public var radiusRatio: Double
        public var volumeRatio: Double
    }

    public static func pairs(
        _ fixture: Fixture, datum: Datum = .centre, ground: ((Medium) -> GroundType)? = nil
    )
        -> [Pair]
    {
        let radius = chargeRadiusFeet
        return Medium.allCases.flatMap { medium -> [Pair] in
            let ground = ground?(medium) ?? medium.grounds[0]
            return fixture.points(medium).map { point in
                let scale = cbrt(point.efficiency)
                let centre = point.h * scale / radius
                let predicted = bombcadRadius(ground: ground, centreHeight: centre, datum: datum)
                return Pair(
                    medium: medium, ground: ground, h: point.h, centreHeight: centre,
                    efficiency: point.efficiency,
                    radiusRatio: fixture.shape.radius.best * scale / predicted,
                    volumeRatio: point.efficiency / bombcadVolume(radius: predicted))
            }
        }
    }

    /// Where a point lies: above the surface, on it, or below it, by Cooper's H.
    public enum Band: String, Sendable, CaseIterable {
        case above, surface, below

        public init(h: Double) {
            self = h > 0.05 ? .above : h < -0.05 ? .below : .surface
        }

        public var title: String {
            switch self {
            case .above: "above the surface (H > 0.05)"
            case .surface: "on it (|H| ≤ 0.05)"
            case .below: "below it (H < −0.05)"
            }
        }
    }

    /// A set of ratios' count, geometric mean and range, and the share within BombCAD's one-sigma
    /// radius band (two thirds to four thirds of its radius).
    public struct Summary: Sendable {
        public var count: Int
        public var geometricMean: Double
        public var low: Double
        public var high: Double
        public var withinBand: Double

        public init?(_ ratios: [Double]) {
            guard !ratios.isEmpty else { return nil }
            count = ratios.count
            geometricMean = exp(ratios.map(log).reduce(0, +) / Double(ratios.count))
            low = ratios.min()!
            high = ratios.max()!
            withinBand = Double(ratios.filter { $0 >= 2.0 / 3 && $0 <= 4.0 / 3 }.count) / Double(ratios.count)
        }
    }

    /// Cooper's own best estimate at H, ft³/ton: his medium's V₀ times e^(−5.2 H), for |H| < 0.4.
    public static func cooperEstimate(_ fixture: Fixture, medium: Medium, h: Double) -> Double? {
        guard let row = fixture.row(medium) else { return nil }
        return row.v0 * exp(-fixture.heightOfBurst.exponent * h)
    }

    /// Cooper's best-estimate scaled height for a sphere of TNT resting on the ground (its centre
    /// a charge radius up), solving H = r / (V₀ e^(−5.2 H))^(1/3).
    public static func restingSphereHeight(_ fixture: Fixture, medium: Medium) -> Double {
        let radius = chargeRadiusFeet
        var h = 0.0
        for _ in 0..<50 { h = radius / cbrt(cooperEstimate(fixture, medium: medium, h: h) ?? 1) }
        return h
    }
}
