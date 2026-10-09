import Testing

@testable import BlastCore

@Suite("Rigid car demo recordings")
struct RigidCarDemoTests {
    @Test("The car replay cases are finite, stay above the ground and reach their intended outcomes")
    func recordings() throws {
        let cases = try RigidCarDemo.recordings()
        #expect(
            cases.map(\.name) == [
                "Car at rest", "Car braking", "Car sliding sideways", "Car rocking", "Car tipping",
            ])
        for recording in cases {
            #expect(recording.frames.count == 151 && recording.frames.last?.time == 3)
            for frame in recording.frames {
                #expect(frame.speed.isFinite && frame.energy.isFinite)
                #expect(frame.corners.count == 8 && frame.tyres?.count == 4)
                #expect((frame.corners + (frame.tyres ?? [])).allSatisfy { $0.z >= -1e-5 })
            }
            #expect(recording.frames.dropFirst().allSatisfy { $0.tyreLoads?.count == 4 })
        }
        let resting = try #require(cases[0].frames.last?.tyreLoads)
        #expect(abs(resting[0] - 1500 * 9.81 * 1.5 / 5.4) < 1e-3)
        let braking = try #require(cases[1].frames.last)
        #expect(abs(braking.centreOfMass.x - 0.15 - 100 / (2 * 0.7 * 9.81)) < 0.05 && braking.speed < 1e-6)
        #expect(try #require(cases[2].frames.last).centreOfMass.y > 1)
        #expect(abs(try #require(cases[3].frames.last).centreOfMass.z - 0.55) < 1e-3)
        #expect(abs(try #require(cases[4].frames.last).centreOfMass.z - 0.775) < 1e-3)
        #expect(cases.map(\.view) == ["side", "side", "front", "front", "front"])
    }
}
