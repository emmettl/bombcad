import Foundation

// The calibration's glass cases (docs/calibration.md), on the CPU: Monk and Clubley's break times
// and ASTM E1300's load resistances at a factor on the glass's flaw constant. Here rather than
// beside the GPU cases, so that they build and run on Linux (docs/linux.md).
extension ValidationEnsemble {
    /// Monk and Clubley's panes (`Fixtures/MonkClubley/windows.json`), as `GlassMeasurementTests`
    /// reads them.
    package struct MonkFixture: Decodable {
        package struct Pane: Decodable {
            package var aspect: String
            package var opening: [Double]
            package var breakTime: [Double]
            enum CodingKeys: String, CodingKey {
                case aspect
                case opening = "opening_m"
                case breakTime = "breakTime_ms"
            }
        }
        package struct Reflected: Decodable { package var allTrials: [[Double]] }
        package var panes: [Pane]
        package var reflectedPressure: Reflected
        package var breakTimes: [String: [Double]]
        enum CodingKeys: String, CodingKey {
            case panes, reflectedPressure
            case breakTimes = "breakTimes_ms"
        }
    }

    package static func monkFixture() throws -> MonkFixture {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/MonkClubley/windows.json")
        return try JSONDecoder().decode(MonkFixture.self, from: Data(contentsOf: url))
    }

    /// Each aspect ratio's break time (ms) on the median of the trials' reflected pressure, the
    /// app's large-deflection pane with its 60 s strength times `flawFactor`^(−1/7): the flaw
    /// constant, or the share of the pane at its largest stress, times `flawFactor`.
    package static func monkBreakTimes(flawFactor: Double) throws -> [String: Double] {
        let fixture = try monkFixture()
        let step = 1e-5
        let points = [[0.0, 0.0]] + fixture.reflectedPressure.allTrials.map { [$0[0], $0[1]] }
        let load = (0..<2000).map { n -> Double in
            let ms = Double(n) * step * 1000
            guard let i = points.firstIndex(where: { $0[0] >= ms }) else { return points.last![1] * 1000 }
            if i == 0 { return 0 }
            let (a, b) = (points[i - 1], points[i])
            return (a[1] + (ms - a[0]) / (b[0] - a[0]) * (b[1] - a[1])) * 1000
        }
        var outputs: [String: Double] = [:]
        for pane in fixture.panes {
            let (a, b) = (pane.opening[0], pane.opening[1])
            let glass = EnvelopePanel.largeDeflectionGlass(
                thickness: 0.004, material: .annealedGlass, a: a, b: b,
                sixtySecondStrength: GlassStrength.sixtySecond(area: a * b)
                    * pow(flawFactor, -1 / GlassStrength.weibullModulus))
            let response = glass.response(pressures: load, step: step)
            outputs["t" + pane.aspect.replacingOccurrences(of: ":", with: "-")] =
                response.lostResistanceAt.map { $0 * 1000 } ?? .nan
        }
        return outputs
    }

    /// Four of the eight panes `GlassMeasurementTests.e1300` takes from Soules, Morse and Norville
    /// (the largest, a square, a strip and a long one): long and short side, thickness (m), E1300's
    /// load resistance (kPa).
    package static let e1300Panes: [(name: String, a: Double, b: Double, t: Double, load: Double)] = [
        ("A", 1.930, 0.965, 0.00556, 2.0), ("D", 1.676, 1.676, 0.00457, 1.4),
        ("T", 1.829, 0.254, 0.00556, 21.3), ("CC", 3.048, 2.286, 0.01191, 2.0),
    ]

    /// Each pane's load (kPa) breaking 8 in 1,000 held for 3 s on Moore's plate, with the whole
    /// pane at its largest stress and the flaw constant times `flawFactor`.
    package static func e1300Resistances(flawFactor: Double) -> [String: Double] {
        let modulus = 71.7e9 / (12 * (1 - 0.22 * 0.22))
        var outputs: [String: Double] = [:]
        for c in e1300Panes {
            func stress(_ q: Double) -> Double {
                let r = MooreGlassCurves.response(load: q * pow(c.b / c.t, 4) / modulus, aspect: c.a / c.b)
                return r.stress * modulus * pow(c.t / c.b, 2)
            }
            let breaking =
                GlassStrength.sixtySecond(area: c.a * c.b, probability: 0.008)
                * pow(flawFactor, -1 / GlassStrength.weibullModulus)
                / pow(3 / 60, 1 / GlassStrength.fatigueExponent)
            var (low, high) = (1.0, 1e7)
            for _ in 0..<100 {
                let mid = (low * high).squareRoot()
                if stress(mid) < breaking { low = mid } else { high = mid }
            }
            outputs["lr" + c.name] = low / 1000
        }
        return outputs
    }
}
