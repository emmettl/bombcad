import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Congestion below the grid", .serialized)
struct CongestionTests {
    /// A rig's lattice: 43 mm pipes at 0.2 m along all three axes (MERGE's array A).
    static let lattice = CongestionArray(
        name: "Lattice", region: Box(min: SIMD3(1, 1, 1), max: SIMD3(3, 3, 3)), diameter: 0.043, pitch: 0.2,
        axes: [0, 1, 2])

    @Test("The array's fields: its volume blockage, drag, turbulence generation, length scale and counts")
    func fields() {
        let array = Self.lattice
        // Three sets of 43 mm pipes at 0.2 m: 3 × π 0.043² / 4 / 0.2² = 10.9%, MERGE's 10%
        // nominal less the joints counted twice.
        #expect(abs(array.volumeBlockage - 0.1089) < 0.001)
        let field = CongestionField(arrays: [array], grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.25))
        let index = 8 + 16 * (8 + 16 * 8)
        let inside = field.porosityDrag[index]
        #expect(abs(inside.x - (1 - array.volumeBlockage)) < 1e-5)
        // Across x, the pipes along y and z: 2 × 0.043 / 0.2² m⁻¹ of frontal area; the row's
        // blockage, as PDRsetFields idealises a cell's obstacles, 2 × 0.043 / (√3 × 0.2) = 0.248,
        // so its factor (1 − 0.124)/(0.752)² = 1.550; C_D 1.2, and ½.
        let area = 2 * 0.043 / 0.04
        let factor = 1.550
        #expect(abs(inside.y / Float(0.5 * 1.2 * factor * area) - 1) < 0.002, "\(inside.y)")
        #expect(inside.y == inside.z && inside.z == inside.w)
        // CT, C_b 0.035 of the drag; L_obs the pipes' diameter, the blockage per obstacle across
        // the flow (2 × 0.043 × 0.25 / 0.04 over 2 × 1.25²) times the cell's width.
        let made = field.generation[index]
        #expect(abs(made.x / Float(0.035 * 1.2 * factor * area) - 1) < 0.002, "\(made.x)")
        #expect(abs(made.w - 0.043) < 1e-5, "\(made.w)")
        // B across x, 0.5375; the count crossing the cell, 3 × 1.25² less the 1.25² all three axes
        // share, which leaves none counted along any one.
        #expect(abs(field.blockage[index].x - 0.5375) < 1e-4)
        #expect(abs(field.blockage[index].w - 3.125) < 1e-4)
        #expect(field.parallel[index].x == 0 && field.parallel[index].y == 0)
        #expect(abs(field.parallel[index].w - Float(3 * Double.pi * 0.043 / 0.04)) < 1e-3)
        // Outside the region, nothing; the length scale the cell's size.
        #expect(field.porosityDrag[0] == SIMD4(1, 0, 0, 0))
        #expect(field.generation[0] == SIMD4(0, 0, 0, 0.25))
        // A rack's tier, pipes along x only: a flow along them meets none.
        let tier = CongestionArray(
            region: Box(min: .zero, max: SIMD3(4, 4, 1)), diameter: 0.1, pitch: 0.5, axes: [0])
        let rack = CongestionField(arrays: [tier], grid: Grid(nx: 8, ny: 8, nz: 4, cellSize: 0.5))
        #expect(rack.porosityDrag[0].y == 0 && rack.porosityDrag[0].z > 0)
        #expect(rack.parallel[0].x == 1 && rack.blockage[0].w == 1)
    }

    @Test("On cells smaller than the pitch the counts and blockage are a pitch's, not the cell's")
    func countsOverAPitch() {
        let field = CongestionField(arrays: [Self.lattice], grid: Grid(nx: 40, ny: 40, nz: 40, cellSize: 0.1))
        let index = 20 + 40 * (20 + 40 * 20)
        // Over a 0.2 m unit cell: one pipe of each set crosses it, the three counts sharing one, so
        // two across any flow; each crossing set blocks 0.043 / 0.2 of its face.
        #expect(abs(field.blockage[index].w - 2) < 1e-4)
        #expect(abs(field.blockage[index].x - 2 * 0.043 / 0.2) < 1e-4)
        #expect(field.unitWidth[index] == 0.2)
        #expect(abs(field.generation[index].w - 0.043) < 1e-5)
        // The drag and generation per volume do not depend on the cell.
        let coarse = CongestionField(
            arrays: [Self.lattice], grid: Grid(nx: 16, ny: 16, nz: 16, cellSize: 0.25))
        let inside = 8 + 16 * (8 + 16 * 8)
        #expect(abs(field.porosityDrag[index].y / coarse.porosityDrag[inside].y - 1) < 1e-5)
        #expect(abs(field.generation[index].x / coarse.generation[inside].x - 1) < 1e-5)
    }

    @Test("MERGE's rigs: their lattices hold a tenth of their volume, the scene its cloud and gauges")
    func mergeRigs() {
        for rig in MergeRig.allCases {
            let lattice = rig.congestion(at: .zero)
            #expect(abs(lattice.volumeBlockage - 0.1) < 0.012, "\(rig.name) \(lattice.volumeBlockage)")
            let study = CongestedRigStudy(rig: rig, gas: .methane, cellSize: rig.pitch)
            let scenario = study.scenario()
            #expect(scenario.congestion?.count == 1)
            #expect(scenario.deflagration?.region == scenario.congestion?.first?.region)
            #expect(scenario.gauges.count == 8)
        }
    }

    @Test("The standing advises cells no larger than the congestion's pitch")
    func gridGuideline() throws {
        let study = CongestedRigStudy(rig: .a, gas: .methane, cellSize: 0.25)
        let coarse = SceneStanding(StandingInputs(scenario: study.scenario(), cellSize: 0.25))
        let advice = try #require(
            coarse[.peakOverpressure]?.regimes?.first { $0.option == "Congestion's cells" })
        #expect(advice.suits == false && advice.suggestion?.contains("0.20 m") == true)
        let fine = SceneStanding(StandingInputs(scenario: study.scenario(), cellSize: 0.2))
        #expect(fine[.impulse]?.regimes?.first { $0.option == "Congestion's cells" }?.suits == true)
    }
}
