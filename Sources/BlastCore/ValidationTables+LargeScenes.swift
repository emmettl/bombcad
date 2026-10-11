import Foundation

// The large-scene comparison's numbers (docs/large-scenes.md), beside the validation record's:
// 500 t on rigid ground against Kingery–Bulmash out to 40 m/kg^(1/3), and how far refinement
// follows a weakening shock. The standing's error bands and the advisor both read them here.
extension ValidationTables {
    /// The large-scene gauges' scaled distances, m/kg^(1/3), along a mirrored side of the domain.
    public static let farDistances: [Double] = [1, 2, 5, 10, 14, 20, 28, 40]
    /// Uniform cells of 16, 8 and 4 m on 500 t, as cells per kg^(1/3).
    public static let farGrids: [Double] = [16, 8, 4].map { $0 / cbrt(500_000) }

    /// Incident peak overpressure and impulse on those grids, an ideal gas without afterburning.
    public static let farIncidentPeak = Table(byGrid: [
        [47, 53, 52, 52, 51, 49, 49, 51], [66, 66, 70, 69, 67, 65, 64, 66], [82, 80, 81, 81, 77, 74, 75, 79],
    ])
    public static let farIncidentImpulse = Table(byGrid: [
        [101, 89, 86, 85, 85, 84, 84, 84], [85, 82, 85, 84, 83, 82, 82, 83],
        [79, 81, 86, 84, 83, 83, 82, 83],
    ])
    /// With afterburning and hot air, 16 m cells refined twice to 4 m: impulse, which the coarse
    /// cells carry as well as fine ones, so read for the coarse and the fine grid alike.
    static let farBurningRow: [Double] = [90, 91, 107, 106, 102, 107, 101, 102]
    public static let farBurningIncidentImpulse = Table(byGrid: [farBurningRow, nil, farBurningRow])

    /// The incident overpressure, in pascals, above which refined cells follow a shock flagged at
    /// `threshold` (the jump across a cell as a share of its pressure): about 20 kPa at 0.1 and
    /// 5 kPa at 0.02, beyond 40 m/kg^(1/3) at 0.005. Twice the threshold's share of ambient.
    public static func refinementReach(threshold: Double, ambient: Double = 101_325) -> Double {
        2 * threshold * ambient
    }
}
