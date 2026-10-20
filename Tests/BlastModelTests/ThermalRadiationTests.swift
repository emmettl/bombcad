import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Thermal radiation from the fireball")
struct ThermalRadiationTests {
    private func scene(blocks: [Box] = [], domain: SIMD3<Float> = SIMD3(100, 100, 50)) -> FragmentScene {
        var scenario = Scenario(
            name: "Thermal", domainSize: domain, boxes: blocks,
            charge: Charge(mass: 1, position: SIMD3(50, 50, 10)))
        scenario.gauges = []
        return FragmentScene(scenario)
    }

    @Test("Receivers cover the ground and the faces the air touches")
    func receivers() {
        var spec = ThermalSpec()
        spec.groundSpacing = 10
        spec.surfaceSpacing = 1
        let block = Box(min: SIMD3(10, 10, 0), max: SIMD3(20, 30, 5))
        let receivers = ThermalExposure.receivers(scene: scene(blocks: [block]), spec: spec)
        let ground = receivers.filter { $0.surface == "ground" }
        // 10 × 10 points, two of them (15, 15) and (15, 25) under the block.
        #expect(ground.count == 98)
        let faces = receivers.filter { $0.surface == "block 0" }
        // Top 10 × 20, sides 2 × 20 × 5 and 2 × 10 × 5; not the underside.
        #expect(faces.count == 200 + 200 + 100)
        #expect(faces.allSatisfy { !block.contains($0.position) })
    }

    @Test("The receivers lie on the grids of their surfaces, which fill the cells under solids")
    func surfaceGrids() throws {
        var spec = ThermalSpec()
        spec.groundSpacing = 10
        spec.surfaceSpacing = 1
        let blocks = [
            Box(min: SIMD3(10, 10, 0), max: SIMD3(20, 30, 5)),
            Box(min: SIMD3(20, 10, 0), max: SIMD3(22, 12, 8)),
        ]
        let grids = ThermalExposure.surfaceGrids(scene: scene(blocks: blocks), spec: spec)
        let receivers = ThermalExposure.receivers(scene: scene(blocks: blocks), spec: spec)
        // The ground and five faces of each block.
        #expect(grids.count == 11 && grids[0].surface == "ground" && grids[0].columns == 10)
        #expect(grids.flatMap(\.receivers) == receivers)
        for grid in grids {
            #expect(grid.indices.count == grid.columns * grid.rows)
            for row in 0..<grid.rows {
                for column in 0..<grid.columns {
                    guard let index = grid.indices[row * grid.columns + column] else { continue }
                    let centre =
                        grid.origin + (Float(column) + 0.5) / Float(grid.columns) * grid.u
                        + (Float(row) + 0.5) / Float(grid.rows) * grid.v + 0.001 * grid.normal
                    #expect(simd_distance(receivers[index].position, centre) < 1e-4)
                    #expect(
                        receivers[index].normal == grid.normal && receivers[index].surface == grid.surface)
                }
            }
        }
        // The first block's +x face, against the second block over 2 m of its 20, is filled
        // there from its neighbours.
        let face = try #require(grids.first { $0.surface == "block 0" && $0.normal.x == 1 })
        #expect(face.indices.filter { $0 == nil }.count == 2 * 5)
        let values = try #require(face.filled { Float(receivers[$0].position.y) })
        #expect(values.allSatisfy { $0 >= 12 })
        let buried = face.indices.indices.filter { face.indices[$0] == nil }
        #expect(buried.allSatisfy { values[$0] > 12 && values[$0] < 13 })
        #expect(grids[0].filled { _ in 1 }?.count == 100)
    }

    @Test("Descriptions out of range are refused, and missing fields take their defaults")
    func descriptions() throws {
        let decoded = try JSONDecoder().decode(ThermalSpec.self, from: Data(#"{"emissivity": 0.5}"#.utf8))
        #expect(decoded.emissivity == 0.5 && decoded.luminousTemperature == 1500 && decoded.samples == 128)
        try decoded.validate()
        for change in [
            { (s: inout ThermalSpec) in s.emissivity = 1.5 }, { $0.samples = 4 }, { $0.groundSpacing = 0 },
        ] {
            var spec = ThermalSpec()
            change(&spec)
            #expect(throws: (any Error).self) { try spec.validate() }
        }
    }
}
