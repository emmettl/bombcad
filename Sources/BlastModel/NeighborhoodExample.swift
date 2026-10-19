import simd

/// An illustrative conventional scene for inspecting shielding and multiple-owner response.
/// Detailed material parameters remain uncalibrated for these invented buildings.
public enum NeighborhoodExample {
    public static func make() throws -> Scenario {
        var scene = Scenario(
            name: "Courtyard neighborhood", domainSize: SIMD3(144, 144, 12), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(72, 72, 1)),
            gauges: [
                Gauge("Courtyard", at: SIMD3(72, 67, 1)), Gauge("Behind building", at: SIMD3(52, 47, 1)),
                Gauge("Street", at: SIMD3(72, 40, 1)),
            ])
        for row in 0..<4 {
            for column in 0..<4 {
                let x = Float(8 + column * 40)
                let y = Float(8 + row * 40)
                let solids = [
                    Box(min: SIMD3(x, y, 0), max: SIMD3(x + 8, y + 0.25, 4)),
                    Box(min: SIMD3(x, y + 5.75, 0), max: SIMD3(x + 8, y + 6, 4)),
                    Box(min: SIMD3(x, y + 0.25, 0), max: SIMD3(x + 0.25, y + 5.75, 4)),
                    Box(min: SIMD3(x + 7.75, y + 0.25, 0), max: SIMD3(x + 8, y + 5.75, 4)),
                    Box(min: SIMD3(x, y, 4), max: SIMD3(x + 8, y + 6, 4.25)),
                ]
                var body = StructureModel(
                    solids: solids, material: .reinforcedConcrete, elementSize: 0.5, fixedBase: true)
                body.elementKind = .shell
                body.openings = [Box(min: SIMD3(x + 3, y - 0.01, 0), max: SIMD3(x + 4.5, y + 0.3, 2.5))]
                try scene.addStructureObject(body, name: "Building \(row * 4 + column + 1)")
            }
        }
        return scene
    }
}
