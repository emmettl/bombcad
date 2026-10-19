import Foundation
import simd

/// Invented conventional fixtures for numerical comparisons, not measured building tests.
public enum StreetInteractionStudy {
    public enum Layout: String, Codable, CaseIterable, Sendable {
        case isolated, pair, street
    }

    public static func make(_ layout: Layout, clamped: Bool = false) throws -> Scenario {
        var scene = Scenario(
            name: "Street interaction: \(layout.rawValue)", domainSize: SIMD3(40, 32, 8), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(8, 16, 1)),
            gauges: [
                Gauge("Front", at: SIMD3(14, 9, 1.5)),
                Gauge("Behind", at: SIMD3(24, 9, 1.5)),
                Gauge("Street", at: SIMD3(24, 16, 1.5)),
                Gauge("Far street", at: SIMD3(34, 16, 1.5)),
            ])
        let origins: [SIMD2<Float>] = [SIMD2(16, 6), SIMD2(16, 20), SIMD2(26, 6), SIMD2(26, 20)]
        let count = layout == .isolated ? 1 : layout == .pair ? 2 : 4
        for index in 0..<count {
            let x = origins[index].x
            let y = origins[index].y
            let solids = [
                Box(min: SIMD3(x, y, 0), max: SIMD3(x + 6, y + 0.5, 4)),
                Box(min: SIMD3(x, y + 5.5, 0), max: SIMD3(x + 6, y + 6, 4)),
                Box(min: SIMD3(x, y + 0.5, 0), max: SIMD3(x + 0.5, y + 5.5, 4)),
                Box(min: SIMD3(x + 5.5, y + 0.5, 0), max: SIMD3(x + 6, y + 5.5, 4)),
                Box(min: SIMD3(x, y, 4), max: SIMD3(x + 6, y + 6, 4.5)),
            ]
            var model = StructureModel(
                solids: solids, material: .reinforcedConcrete, elementSize: 0.5, fixedBase: true)
            model.elementKind = .shell
            if clamped { model.supports = [Box(min: model.bounds.min - 0.01, max: model.bounds.max + 0.01)] }
            // Matched geometry retains the same owner across every comparison and grid.
            let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!
            scene.objects.append(
                SceneObject(id: id, name: "Building \(index + 1)", representation: .deformable(model)))
        }
        return scene
    }
}
