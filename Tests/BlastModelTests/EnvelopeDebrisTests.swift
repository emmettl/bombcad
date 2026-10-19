import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Envelope debris")
struct EnvelopeDebrisTests {
    @Test("A slow piece thrown level lands as a drag-free throw would, at the speed its fall gives it")
    func slowThrow() {
        // 2 m/s from 2 m: 1.28 m out, landing at √(4 + 2 g 2) = 6.6 m/s; drag on a 2.7 kg brick is slight.
        var cloud = FragmentCloud(
            particles: [
                FragmentCloud.Particle(
                    position: SIMD3(0, 0, 2), velocity: SIMD3(2, 0, 0), mass: 2.7, area: 0.02)
            ])
        cloud.land(in: Primitive(density: 1.225, pressure: 101_325))
        let impact = cloud.impacts[0]
        #expect(abs(impact.position.x - 2 * (2 * 2 / 9.81).squareRoot()) < 0.05)
        #expect(abs(impact.speed - (4 + 2 * 9.81 * 2).squareRoot()) < 0.2, "\(impact.speed) m/s")
    }

    @Test("Inside a building the minimum safe distance is never shorter than DoD's structure debris distance")
    func structureDistance() {
        // DESR 6055.09 Table V3.E3.T2, "Structure": 61.0 m to 14.1 kg, 282.6 m at 90.7 kg, 381 m past 204.1 kg.
        #expect(MinimumSafeDistance.defaultStructureDebrisDistance(kilograms: 10) == 61)
        #expect(abs(MinimumSafeDistance.defaultStructureDebrisDistance(kilograms: 90.7) - 282.6) < 0.2)
        #expect(MinimumSafeDistance.defaultStructureDebrisDistance(kilograms: 300) == 381)
        let inside = MinimumSafeDistance(kilograms: 80, fragments: nil, inStructure: true)
        #expect(
            abs(inside.distanceM - 267.7) < 0.2
                && inside.governedBy == "DoD's default structure debris distance")
        let open = MinimumSafeDistance(kilograms: 80, fragments: nil)
        #expect(open.governedBy == "overpressure (K40)")
    }
}

@Suite("Concrete judged either way")
struct ConcreteEitherWayTests {
    @Test(
        "A concrete wall pushed out from inside is judged as the same wall pushed in, and throws its debris outward"
    )
    func outward() throws {
        // 2 ms of 2 MPa on a 0.15 m wall 2 m square held all round: well past failing.
        let pulse = (0..<300).map { $0 < 20 ? 2e6 : 0.0 }
        let zero = Array(repeating: 0.0, count: pulse.count)
        func load(outer: [Double], inner: [Double]) -> EnvelopeComponentLoad {
            EnvelopeComponentLoad(
                id: "wall", owner: UUID(), kind: .wall,
                region: Box(min: SIMD3(0, 0, 0), max: SIMD3(0.15, 2, 2)),
                axis: 0, binS: 1e-4, outerPa: outer, innerPa: inner, supportEdges: [true, true, true, true],
                outward: -1)
        }
        let construction = EnvelopeConstruction(
            objectID: UUID(), walls: .reinforcedConcrete, wallThicknessM: 0.15, source: .user, detail: "test",
            barsInBothFaces: true)
        let pushedIn = try #require(
            EnvelopeDamageAssessment.assess(load(outer: pulse, inner: zero), construction: construction))
        let pushedOut = try #require(
            EnvelopeDamageAssessment.assess(load(outer: zero, inner: pulse), construction: construction))
        #expect(pushedIn.levels.upperBound == .failed)
        #expect(pushedOut.levels == pushedIn.levels)
        let launchIn = try #require(pushedIn.launch)
        let launchOut = try #require(pushedOut.launch)
        #expect(launchIn.speedMS > 0 && abs(launchOut.speedMS + launchIn.speedMS) < 1e-9)
    }
}
