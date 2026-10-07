import Testing

@testable import BlastCore

@Suite("Rigid object demo recordings")
struct RigidObjectDemoTests {
    @Test("The visual cases contain finite ground-respecting trajectories with the intended outcomes")
    func recordings() throws {
        let cases = try RigidObjectDemo.recordings()
        #expect(cases.count == 6)
        for recording in cases {
            #expect(recording.frames.count == 101)
            #expect(recording.frames.first?.time == 0 && recording.frames.last?.time == 2)
            for frame in recording.frames {
                #expect(frame.speed.isFinite && frame.energy.isFinite)
                #expect(frame.corners.count == 8)
                #expect(frame.corners.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z >= -1e-10 })
            }
        }
        let resting = try #require(cases[0].frames.last)
        let held = try #require(cases[1].frames.last)
        let sliding = try #require(cases[2].frames.last)
        #expect(abs(resting.centreOfMass.z - 0.25) < 1e-6)
        // Bound accumulated contact-solver drift to 10 micrometres over the two-second replay.
        #expect(abs(held.centreOfMass.x) < 1e-5)
        #expect(sliding.centreOfMass.x > 2 && sliding.speed < 1e-6)
        #expect(cases[3].frames.contains { $0.centreOfMass.z > 0.4 })
        #expect(abs(try #require(cases[4].frames.last).centreOfMass.z - 1) < 0.01)
        #expect(abs(try #require(cases[5].frames.last).centreOfMass.z - 0.5) < 0.01)
    }
}
