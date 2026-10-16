import Foundation
import Testing

@testable import BlastCore

/// The one-way glass model (`EnvelopePanel.glass`) against Monk and Clubley's annealed windows in
/// the air blast tunnel at Shoeburyness (`Fixtures/MonkClubley`): sixteen 4 mm panes of 0.89 m²,
/// four aspect ratios, a long-duration wave reflected at about 33 kPa; every pane broke, twelve
/// with their times. See docs/validation.md, "Window glass".
@Suite("Annealed windows against Monk and Clubley's trials")
struct GlassMeasurementTests {
    struct Fixture: Decodable {
        struct Pane: Decodable {
            var aspect: String
            var opening: [Double]
            var displacementAtBreak: [Double]
            var breakTime: [Double]
            var impulseAtBreak: [Double]

            enum CodingKeys: String, CodingKey {
                case aspect
                case opening = "opening_m"
                case displacementAtBreak = "displacementAtBreak_mm"
                case breakTime = "breakTime_ms"
                case impulseAtBreak = "impulseAtBreak_kPams"
            }
        }
        struct Reflected: Decodable {
            var allTrials: [[Double]]
        }
        var panes: [Pane]
        var reflectedPressure: Reflected
        /// The twelve timed panes' break times, ms, by aspect ratio.
        var breakTimes: [String: [Double]]

        enum CodingKeys: String, CodingKey {
            case panes, reflectedPressure
            case breakTimes = "breakTimes_ms"
        }
    }

    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/MonkClubley/windows.json")

    static let step = 1e-5

    /// The median of all trials' reflected pressure read off the paper's figure 8, Pa every `step`
    /// from the wave's arrival, held at its last value past 10 ms.
    static func measuredLoad(_ fixture: Fixture) -> [Double] {
        let points = [[0.0, 0.0]] + fixture.reflectedPressure.allTrials.map { [$0[0], $0[1]] }
        return (0..<2000).map { n in
            let ms = Double(n) * step * 1000
            guard let i = points.firstIndex(where: { $0[0] >= ms }) else { return points.last![1] * 1000 }
            if i == 0 { return 0 }
            let (a, b) = (points[i - 1], points[i])
            return (a[1] + (ms - a[0]) / (b[0] - a[0]) * (b[1] - a[1])) * 1000
        }
    }

    /// The paper's table 2 alone: a step at the mean pressure up to the break, its impulse at the
    /// break over its break time.
    static func tableLoad(_ pane: Fixture.Pane) -> [Double] {
        Array(repeating: pane.impulseAtBreak[0] / pane.breakTime[0] * 1000, count: 2000)
    }

    struct Prediction {
        var aspect: String
        var edges: EnvelopePanel.Edges
        var breakMs: Double?
        var deflectionMm: Double
        var measuredMs: Double
        var measuredMm: Double
    }

    static func predictions(load: (Fixture.Pane) -> [Double]) throws -> [Prediction] {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        return fixture.panes.flatMap { pane in
            [EnvelopePanel.Edges.fixed, .simplySupported].map { edges in
                let glass = EnvelopePanel.glass(
                    thickness: 0.004, material: .annealedGlass, a: pane.opening[0], b: pane.opening[1],
                    edges: edges)
                let response = glass.response(pressures: load(pane), step: step)
                return Prediction(
                    aspect: pane.aspect, edges: edges, breakMs: response.lostResistanceAt.map { $0 * 1000 },
                    deflectionMm: response.yieldDeflection * 1000, measuredMs: pane.breakTime[0],
                    measuredMm: pane.displacementAtBreak[0])
            }
        }
    }

    @Test("The digitised break times hold the paper's means")
    func digitisedMeans() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        #expect(fixture.breakTimes.values.map(\.count).reduce(0, +) == 12)
        for pane in fixture.panes {
            let times = try #require(fixture.breakTimes[pane.aspect])
            let mean = times.reduce(0, +) / Double(times.count)
            #expect(abs(mean - pane.breakTime[0]) < 0.01, "\(pane.aspect): \(mean)")
        }
    }

    @Test(
        "Every pane breaks, early: 0.40–0.46 of the measured time with fixed edges, 0.71–0.84 simply supported"
    )
    func breakTimes() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        for (name, load) in [("figure 8", { _ in Self.measuredLoad(fixture) }), ("table 2", Self.tableLoad)]
            as [(String, (Fixture.Pane) -> [Double])]
        {
            for p in try Self.predictions(load: load) {
                let ratio = (p.breakMs ?? .infinity) / p.measuredMs
                print(
                    String(
                        format:
                            "%@ load, %@, %@: breaks at %.2f ms (measured %.2f), %.2f of it; at %.1f mm (measured %.0f)",
                        name, p.aspect, "\(p.edges)", p.breakMs ?? -1, p.measuredMs, ratio, p.deflectionMm,
                        p.measuredMm))
                #expect(p.breakMs != nil, "\(p.aspect) \(p.edges) under the \(name) load")
                // On the figure's load; the table's step, at full pressure from the start, is earlier.
                let expected: ClosedRange<Double> =
                    name == "figure 8"
                    ? (p.edges == .fixed ? 0.39...0.47 : 0.70...0.85)
                    : (p.edges == .fixed ? 0.34...0.42 : 0.64...0.80)
                #expect(expected.contains(ratio), "\(name), \(p.aspect), \(p.edges): \(ratio)")
                #expect(p.deflectionMm < p.measuredMm, "\(p.aspect) \(p.edges)")
                // Before every measured break of its own aspect ratio.
                let earliest = try #require(fixture.breakTimes[p.aspect]?.min())
                #expect((p.breakMs ?? .infinity) < earliest, "\(name), \(p.aspect), \(p.edges)")
            }
        }
    }
}
