import Foundation
import Testing

@testable import BlastCore

/// The slabs with steel in one face or both (`TwoFaceSlabTests`) against the derived data in
/// Benchmarks/Slabs, transcribed from the papers.
@Suite("Slabs with steel in both faces")
struct TwoFaceSlabTestsTests {
    private func fixture(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Benchmarks/Slabs/\(name).json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try #require(object as? [String: Any])
    }

    @Test("Wu's measured responses match the derived data")
    func wu() throws {
        let data = try fixture("Wu2023")
        let contact = try #require(data["contact"] as? [[String: Any]])
        let open = try #require(data["non_contact"] as? [[String: Any]])
        #expect(TwoFaceSlabTests.wuTests.count == contact.count + open.count)
        for row in contact {
            let name = try #require(row["specimen"] as? String)
            let test = try #require(TwoFaceSlabTests.wuTests.first { $0.name == name && $0.standoff == nil })
            #expect(abs((test.hole ?? 0) * 100 - Float(try #require(row["hole_cm"] as? Double))) < 1e-3)
            #expect(
                abs((test.damagedTop ?? 0) * 1e4 - Float(try #require(row["top_damage_cm2"] as? Double)))
                    < 1e-2)
        }
        for row in open {
            let name = try #require(row["specimen"] as? String)
            let test = try #require(TwoFaceSlabTests.wuTests.first { $0.name == name })
            #expect(abs(test.standoff! - Float(try #require(row["distance_m"] as? Double))) < 1e-6)
            #expect(abs(test.peak! * 1000 + Float(try #require(row["peak_mm"] as? Double))) < 1e-3, "\(name)")
            #expect(
                abs(test.residual! * 1000 + Float(try #require(row["residual_mm"] as? Double))) < 1e-3,
                "\(name)")
        }
    }

    @Test("Wang's measured responses and the slabs' steel match the derived data")
    func wang() throws {
        let data = try fixture("Wang2022")
        let displacements = try #require(data["displacements"] as? [String: Any])
        for test in TwoFaceSlabTests.wangTests {
            let record = try #require(displacements[test.name] as? [String: Any])
            let peaks = try #require(record["peak_cm"] as? [Double])
            let residuals = try #require(record["residual_cm"] as? [Double])
            for n in peaks.indices {
                #expect(abs(test.peaks[n] * 100 - Float(peaks[n])) < 1e-4)
                #expect(abs(test.residuals[n] * 100 - Float(residuals[n])) < 1e-4)
            }
            // Bars at 100 mm with their centres 80 mm from the far face give the printed ratios.
            let slabs = try #require(data["slabs"] as? [String: Any])
            let printed = try #require((slabs[test.name] as? [String: Any])?["ratio_percent"] as? Double)
            let ratio = Float.pi * test.bar * test.bar / 4 / 0.1 / 0.08 * 100
            #expect(abs(ratio - Float(printed)) < 0.03 * Float(printed), "\(test.name): \(ratio)%")
        }
        let gauges = try #require((data["pressure_gauges"] as? [String: Any])?["points"] as? [[String: Any]])
        for (gauge, row) in zip(TwoFaceSlabTests.wangGauges, gauges) {
            #expect(abs(gauge.peak / 1e6 - Float(try #require(row["peak_MPa"] as? Double))) < 1e-3)
            #expect(abs(gauge.impulse / 1e3 - Float(try #require(row["impulse_MPa_ms"] as? Double))) < 1e-3)
        }
    }
}
