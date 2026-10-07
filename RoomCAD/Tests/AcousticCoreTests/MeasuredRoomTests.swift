import Foundation
import Testing

@testable import AcousticCore

/// RoomCAD against the measured seminar room CR2 of the BRAS database, in the parts that are quick to
/// simulate; `acousticbench --bras-cr2` makes the full comparison, decay and the wave solver included.
@Suite("Measured room")
struct MeasuredRoomTests {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Validation/bras-cr2")

    struct Pair: Decodable {
        var parameters: [RoomParameters]
        var early: [Double]
    }

    struct Fixture: Decodable {
        var pairs: [String: Pair]
    }

    @Test("The simplified seminar room has the measured room's volume and its materials' octave values")
    func scene() throws {
        let scene = try ValidationScene.load(Self.directory.appendingPathComponent("scene.json"))
        let room = scene.room(set: "initial")
        try room.validate()
        // BRAS gives 145 m³.
        #expect(abs(room.volume / 145 - 1) < 0.01)
        // The 1 kHz octave averages the 800 Hz, 1 kHz and 1.25 kHz third octaves.
        let plaster = scene.materials["initial"]!["plaster"]!.absorption
        #expect(
            abs(
                scene.material(["plaster": 1], set: "initial").absorption[4]
                    - (plaster[16] + plaster[17] + plaster[18]) / 3) < 1e-12)
        // A wall of two materials takes their area-weighted mean.
        let mixed = scene.material(["windows": 0.53, "concrete": 0.47], set: "fitted")
        let windows = scene.material(["windows": 1], set: "fitted")
        let concrete = scene.material(["concrete": 1], set: "fitted")
        #expect(
            abs(mixed.absorption[2] - (0.53 * windows.absorption[2] + 0.47 * concrete.absorption[2])) < 1e-12)
    }

    @Test("The early reflections' timing and strength follow the measurements at every receiver")
    func earlyReflections() throws {
        let scene = try ValidationScene.load(Self.directory.appendingPathComponent("scene.json"))
        let fixture = try JSONDecoder().decode(
            Fixture.self, from: Data(contentsOf: Self.directory.appendingPathComponent("measured.json")))
        let receivers = (1...5).map { "MP\($0)" }
        var matched: [Double] = []
        var mismatched: [Double] = []
        for source in ["LS1", "LS2"] {
            // All three drivers, as measured; the first 20 ms need only a short response.
            let result = try scene.generate(
                set: "fitted", source: source, receivers: receivers, duration: 0.1, lowFrequencyModel: false
            ) { $0.diffuseRays = 5_000 }
            for (r, channel) in result.channels.enumerated() {
                let simulated = ResponseComparison.earlyReflections(channel, sampleRate: result.sampleRate)
                for other in receivers.indices {
                    let correlation = ResponseComparison.correlation(
                        fixture.pairs["\(source)-\(receivers[other])"]!.early, simulated)
                    if other == r { matched.append(correlation) } else { mismatched.append(correlation) }
                }
            }
        }
        func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(values.count) }
        // About 0.7 at the same position and 0.2 at others when the bench last ran.
        #expect(mean(matched) > 0.55, "\(matched)")
        #expect(mean(mismatched) < 0.35, "\(mismatched)")
    }
}
