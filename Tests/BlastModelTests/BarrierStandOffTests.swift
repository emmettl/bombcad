import Foundation
import Testing
import simd

@testable import BlastModel

/// Protective design's site-wide changes as scene elements: a barrier wall the air and the façade
/// load surrogate's raster both see, and a stand-off line that keeps charges back.
@Suite("Barriers and stand-off lines")
struct BarrierStandOffTests {
    @Test("A stand-off line guards one side: charges inside it, and where a charge stops")
    func standOff() throws {
        // A line running along +x at y = 10, guarding its left, the side towards +y.
        let line = StandOffLine(
            name: "Car park", points: [SIMD2(0, 10), SIMD2(20, 10), SIMD2(20, 30)], guardsLeft: true)
        try line.validate()
        #expect(line.guards(SIMD2(5, 12)) && !line.guards(SIMD2(5, 8)))
        #expect(abs(line.distance(to: SIMD2(5, 8)) - 2) < 1e-5)
        // Inside, it stops on the line a metre to the unguarded side; outside, it stays.
        #expect(simd_distance(line.stopPoint(for: SIMD2(5, 12)), SIMD2(5, 9)) < 1e-5)
        #expect(line.stopPoint(for: SIMD2(5, 8)) == SIMD2(5, 8))
        // Along the second leg, running +y at x = 20, its left is towards −x.
        #expect(line.guards(SIMD2(18, 25)) && !line.guards(SIMD2(22, 25)))
        #expect(throws: (any Error).self) {
            try StandOffLine(name: "Point", points: [SIMD2(1, 1)], guardsLeft: true).validate()
        }

        var scene = Scenario(
            name: "Stand-off", domainSize: SIMD3(40, 40, 10), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(5, 12, 0.5)), gauges: [])
        scene.additionalCharges = [Charge(mass: 5, position: SIMD3(5, 5, 0.5))]
        scene.standOffLines = [line]
        #expect(scene.chargesInsideStandOff == [0])
        // Saved with the layout, but not part of the numerical input.
        let decoded = try JSONDecoder().decode(Scenario.self, from: JSONEncoder().encode(scene))
        #expect(decoded.standOffLines == [line])
        let physics = JSONEncoder()
        physics.outputFormatting = .sortedKeys
        physics.userInfo[Scenario.physicsInputEncoding] = true
        var plain = scene
        plain.standOffLines = nil
        let input = try physics.encode(scene)
        #expect(input == (try physics.encode(plain)))
        #expect(!String(decoding: input, as: UTF8.self).contains("Car park"))
    }

    @Test("A barrier is a block along x or y, standing on the lowest ground under it")
    func barrier() throws {
        var scene = Scenario(
            name: "Barrier", domainSize: SIMD3(40, 40, 20), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(5, 20, 0.5)), gauges: [])
        // Ground rising 0.1 m per metre along x.
        scene.terrain = Terrain(
            spacing: 10, columns: 5, rows: 5, heights: (0..<25).map { Float($0 % 5) * 1 })
        let id = try scene.addBarrier(from: SIMD2(10, 15), to: SIMD2(10, 25), height: 3)
        let object = try #require(scene.objects.first { $0.id == id })
        #expect(object.name == "Barrier 1")
        let box = try #require(object.fixedBox)
        #expect(
            abs(box.min.x - 9.85) < 1e-5 && abs(box.max.x - 10.15) < 1e-5 && box.min.y == 15
                && box.max.y == 25)
        // The ground under it runs from 0.985 to 1.015 m: it stands on the lower and is 3 m over it.
        #expect(abs(box.min.z - 0.985) < 1e-4 && abs(box.max.z - 3.985) < 1e-4)
        #expect(scene.boxes.contains(box))
        #expect(throws: (any Error).self) {
            try scene.addBarrier(from: SIMD2(0, 0), to: SIMD2(5, 5), height: 3)
        }
    }

    @Test("The surrogate's raster sees a thin barrier on coarse cells, and counts it as crossed")
    func raster() {
        // A 0.3 m wall 3 m tall between a charge and a façade 20 m away, on 4 m cells.
        let wall = Box(min: SIMD3(9.85, 0, 0), max: SIMD3(10.15, 20, 3))
        let facade = Box(min: SIMD3(20, 5, 0), max: SIMD3(20.2, 15, 3))
        let charge = SIMD3<Float>(0, 10, 0.5)
        func features(_ blocks: [Box]) -> FacadeLoadSurrogate.Features {
            let raster = FacadeLoadSurrogate.Raster(objects: [], blocks: blocks, terrain: nil, cell: 4)
            return FacadeLoadSurrogate.features(
                region: facade, axis: 0, outward: -1, owner: 0, charge: charge, raster: raster)
        }
        let open = features([])
        let shielded = features([wall])
        print(open, shielded)
        #expect(open.buildingsCrossed == 0 && open.blockedM == 0)
        #expect(shielded.buildingsCrossed == 1 && shielded.blockedM > 0 && shielded.shadowM > 5)
    }
}
