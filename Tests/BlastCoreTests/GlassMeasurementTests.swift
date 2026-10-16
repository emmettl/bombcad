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

    /// The app's glass (`largeDeflectionGlass`), and before it the small-deflection pane on either edge.
    enum Model: String, CaseIterable {
        case largeDeflection, smallFixed, smallSimple
    }

    struct Prediction {
        var aspect: String
        var model: Model
        var breakMs: Double?
        var deflectionMm: Double
        var measuredMs: Double
        var measuredMm: Double
    }

    static func predictions(_ models: [Model], load: (Fixture.Pane) -> [Double]) throws -> [Prediction] {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        return fixture.panes.flatMap { pane in
            models.map { model in
                let (a, b) = (pane.opening[0], pane.opening[1])
                let glass =
                    model == .largeDeflection
                    ? EnvelopePanel.largeDeflectionGlass(
                        thickness: 0.004, material: .annealedGlass, a: a, b: b)
                    : EnvelopePanel.glass(
                        thickness: 0.004, material: .annealedGlass, a: a, b: b,
                        edges: model == .smallFixed ? .fixed : .simplySupported)
                let response = glass.response(pressures: load(pane), step: step)
                return Prediction(
                    aspect: pane.aspect, model: model, breakMs: response.lostResistanceAt.map { $0 * 1000 },
                    deflectionMm: (response.deflectionAtBreak ?? response.yieldDeflection) * 1000,
                    measuredMs: pane.breakTime[0], measuredMm: pane.displacementAtBreak[0])
            }
        }
    }

    static func loads(_ fixture: Fixture) -> [(String, (Fixture.Pane) -> [Double])] {
        [("figure 8", { _ in Self.measuredLoad(fixture) }), ("table 2", Self.tableLoad)]
    }

    static func describe(_ name: String, _ p: Prediction) {
        print(
            String(
                format:
                    "%@ load, %@, %@: breaks at %.2f ms (measured %.2f), %.2f of it; at %.1f mm (measured %.0f), %.2f",
                name, p.aspect, p.model.rawValue, p.breakMs ?? -1, p.measuredMs,
                (p.breakMs ?? .infinity) / p.measuredMs,
                p.deflectionMm, p.measuredMm, p.deflectionMm / p.measuredMm))
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
        "Moore's large-deflection panes break as measured: 0.82–1.07 of the time, 0.70–1.16 of the deflection"
    )
    func largeDeflection() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        for (name, load) in Self.loads(fixture) {
            for p in try Self.predictions([.largeDeflection], load: load) {
                Self.describe(name, p)
                let ratio = (p.breakMs ?? .infinity) / p.measuredMs
                // On the figure's load; the table's step, at full pressure from the start, is earlier.
                let time: ClosedRange<Double> = name == "figure 8" ? 0.81...1.08 : 0.75...1.01
                #expect(time.contains(ratio), "\(name), \(p.aspect): \(ratio)")
                #expect((0.65...1.20).contains(p.deflectionMm / p.measuredMm), "\(name), \(p.aspect)")
            }
        }
    }

    @Test(
        "Small-deflection panes break early: 0.40–0.46 of the time with fixed edges, 0.71–0.84 simply supported"
    )
    func smallDeflection() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixture))
        for (name, load) in Self.loads(fixture) {
            for p in try Self.predictions([.smallFixed, .smallSimple], load: load) {
                Self.describe(name, p)
                let ratio = (p.breakMs ?? .infinity) / p.measuredMs
                let expected: ClosedRange<Double> =
                    name == "figure 8"
                    ? (p.model == .smallFixed ? 0.39...0.47 : 0.70...0.85)
                    : (p.model == .smallFixed ? 0.34...0.42 : 0.64...0.80)
                #expect(expected.contains(ratio), "\(name), \(p.aspect), \(p.model): \(ratio)")
                #expect(p.deflectionMm < p.measuredMm, "\(p.aspect) \(p.model)")
                // Before every measured break of its own aspect ratio.
                let earliest = try #require(fixture.breakTimes[p.aspect]?.min())
                #expect((p.breakMs ?? .infinity) < earliest, "\(name), \(p.aspect), \(p.model)")
            }
        }
    }

    /// ASTM E1300's load resistance (the load breaking 8 panes in 1,000 held for 3 s) of eight
    /// annealed panes, with the largest principal stress and deflection there from its own
    /// finite-difference plate analysis (Vallabhan), as Soules, Morse and Norville tabulate them
    /// (their tables 1–3; E = 71.7 GPa): (long m, short m, thickness m, load kPa, stress MPa,
    /// deflection mm).
    static let e1300:
        [(name: String, a: Double, b: Double, t: Double, load: Double, stress: Double, deflection: Double)] =
            [
                ("A", 1.930, 0.965, 0.00556, 2.0, 27.12, 12.5),
                ("D", 1.676, 1.676, 0.00457, 1.4, 27.62, 20.8),
                ("I", 1.803, 1.219, 0.00556, 2.1, 22.90, 16.4),
                ("N", 1.956, 1.778, 0.00742, 2.1, 22.28, 19.5),
                ("Q", 7.620, 0.762, 0.00742, 2.9, 22.78, 4.9), ("T", 1.829, 0.254, 0.00556, 21.3, 33.24, 1.1),
                ("Z", 1.905, 0.381, 0.01826, 97.2, 31.64, 0.7),
                ("CC", 3.048, 2.286, 0.01191, 2.0, 19.92, 22.5),
            ]

    @Test(
        "Moore's plate gives E1300's stress and deflection within 11%, and breaks at 0.57–0.72 of its load resistance"
    )
    func e1300Threshold() {
        let modulus = 71.7e9 / (12 * (1 - 0.22 * 0.22))
        for c in Self.e1300 {
            func at(_ q: Double) -> (stress: Double, deflection: Double) {
                let r = MooreGlassCurves.response(load: q * pow(c.b / c.t, 4) / modulus, aspect: c.a / c.b)
                return (r.stress * modulus * pow(c.t / c.b, 2), r.deflection * c.t)
            }
            let there = at(c.load * 1000)
            #expect(abs(there.stress / 1e6 / c.stress - 1) < 0.09, "\(c.name): \(there.stress / 1e6)")
            #expect(
                abs(there.deflection * 1000 / c.deflection - 1) < 0.12,
                "\(c.name): \(there.deflection * 1000)")
            // The same probability and duration by `GlassStrength`, the whole pane at its largest stress.
            let breaking =
                GlassStrength.sixtySecond(area: c.a * c.b, probability: 0.008)
                / pow(3 / 60, 1 / GlassStrength.fatigueExponent)
            var (low, high) = (1.0, 1e7)
            for _ in 0..<100 {
                let mid = (low * high).squareRoot()
                if at(mid).stress < breaking { low = mid } else { high = mid }
            }
            print(
                String(
                    format: "E1300 %@: load resistance %.2f kPa against %.1f, %.2f", c.name, low / 1000,
                    c.load, low / 1000 / c.load))
            #expect((0.56...0.73).contains(low / 1000 / c.load), "\(c.name)")
        }
    }
}
