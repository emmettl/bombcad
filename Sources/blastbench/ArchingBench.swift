import BlastCore
import Foundation
import simd

/// `blastbench envelope-terrace [--mass 96] [--height 0.3]`: the terraced row's front wall
/// (`ScenarioPreset.terracedRow`) judged by the envelope's one-way model, with and without
/// arching between its returns (`EnvelopeConstruction.masonryArching`), at the wartime survey's
/// distances, against what the detailed shells did (validation.md, "Solid one-brick walls").
/// The middle house's front, 5 m between its party walls and 5.3 m to the eaves, is two storey
/// panels as the envelope cuts a wall that no slab holds (3 m at most): the lower on the ground
/// and both party walls, the upper on the party walls alone (one way across), the floors not
/// holding it. Each takes a triangular pulse of the Kingery–Bulmash reflected peak and impulse
/// averaged over it at its points' slant ranges (hemispherical TNT). Walls: solid one brick
/// (215 mm); and a cavity wall's 102.5 mm leaf, taking the whole load (the outer leaf alone) or
/// half (both leaves sharing it, as they do once the ties give and the cavity closes).
func runEnvelopeTerrace() throws {
    let mass = option("mass").flatMap(Double.init) ?? 96
    let burst = option("height").flatMap(Double.init) ?? 0.3
    let width = 5.0
    let eaves = 5.298
    let storey = eaves / 2
    let distances = [4.7, 7.8, 10.8, 13.9, 16.9, 20.0, 23.0]
    let owner = UUID()
    let bin = 2e-4
    // The panels: (name, bottom, top, support edges [-u, +u, -v, +v]).
    let panels: [(String, Double, Double, [Bool])] = [
        ("ground storey", 0, storey, [true, true, true, false]),
        ("upper storey", storey, eaves, [true, true, false, false]),
    ]
    func load(distance: Double, bottom: Double, top: Double, edges: [Bool], share: Double)
        -> EnvelopeComponentLoad
    {
        // The panel's mean reflected peak and impulse over a grid of its points.
        var peak = 0.0
        var impulse = 0.0
        let n = 20
        for i in 0..<n {
            for j in 0..<n {
                let y = -width / 2 + (Double(i) + 0.5) * width / Double(n)
                let z = bottom + (Double(j) + 0.5) * (top - bottom) / Double(n)
                let range = (distance * distance + y * y + (z - burst) * (z - burst)).squareRoot()
                guard let point = KingeryBulmash.point(at: range / cbrt(mass)) else { continue }
                peak += point.reflectedPressure
                impulse += point.reflectedImpulse(mass: mass)
            }
        }
        peak *= share / Double(n * n)
        impulse *= share / Double(n * n)
        let duration = 2 * impulse / peak
        let bins = Int((duration / bin).rounded(.up)) + Int(0.5 / bin)
        let pressures = (0..<bins).map { k -> Double in
            let t = (Double(k) + 0.5) * bin
            return t < duration ? peak * (1 - t / duration) : 0
        }
        return EnvelopeComponentLoad(
            id: "front", owner: owner, kind: .wall,
            region: Box(min: SIMD3(0, 0, Float(bottom)), max: SIMD3(0.2, Float(width), Float(top))), axis: 0,
            binS: bin, outerPa: pressures, innerPa: pressures.map { _ in 0 }, supportEdges: edges)
    }
    let walls: [(String, Float, Double)] = [
        ("solid 215 mm", 0.215, 1), ("cavity leaf, whole load", 0.1025, 1),
        ("cavity leaf, half load", 0.1025, 0.5),
    ]
    print(
        "\(mass) kg TNT \(burst) m up; the middle house's front as two storey panels; level (support rotation)"
    )
    print("distance  wall                      arching  ground storey         upper storey")
    for distance in distances {
        for (name, thickness, share) in walls {
            for arching in [false, true] {
                var construction = EnvelopeConstruction(
                    objectID: owner, walls: .unreinforcedMasonry, wallThicknessM: thickness, source: .user,
                    detail: "terraced front")
                construction.masonryArching = arching ? true : nil
                var cells: [String] = []
                for (_, bottom, top, edges) in panels {
                    let panel = load(distance: distance, bottom: bottom, top: top, edges: edges, share: share)
                    guard
                        let damage = EnvelopeDamageAssessment.assess(
                            panel, construction: construction, buildingTop: eaves, buildingBase: 0)
                    else { continue }
                    let rotation = damage.rotationDeg.upperBound
                    cells.append(
                        "\(damage.levels.upperBound) (\(String(format: "%.2f", rotation))°)".padding(
                            toLength: 22, withPad: " ", startingAt: 0))
                }
                print(
                    String(format: "%6.1f m  ", distance)
                        + name.padding(toLength: 26, withPad: " ", startingAt: 0)
                        + (arching ? "on       " : "off      ") + cells.joined())
            }
        }
    }
}
