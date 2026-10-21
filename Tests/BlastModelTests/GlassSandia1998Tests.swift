import Foundation
import Testing

@testable import BlastModel

@Suite("Glass against Beauchamp and Matalucci's windows (SAND98-0598)")
struct GlassSandia1998Tests {
    typealias S = SandiaWindows1998
    let psi = 6894.76

    func fixture() throws -> S.Fixture {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/BeauchampMatalucci1998/windows.json")
        return try S.fixture(from: url)
    }

    @Test("The filmed panes fly at 0.81–1.03 of their measured speeds, the speed inverse to thickness")
    func speeds() throws {
        let fixture = try fixture()
        let shot = try #require(fixture.shot("film"))
        var ratios: [Double] = []
        for speed in fixture.speeds {
            let model = try #require(
                S.outcome(
                    glass: speed.glass, thicknessMM: speed.thicknessMM, opening: fixture.opening, shot: shot))
            ratios.append(try #require(model.speed) / (speed.ftPerS * 0.3048))
        }
        // Recorded 21 October 2026 (docs/validation.md#sandias-windows): 45.8 and 22.0 m/s.
        let expected = [0.81, 1.03, 0.97, 0.89]
        for (ratio, want) in zip(ratios, expected) { #expect(abs(ratio - want) < 0.02) }
    }

    @Test("Shot 1: the 1/2 in pane holds; at the measured 4 psi the thin panes pass their flaws' strengths")
    func shotOne() throws {
        let fixture = try fixture()
        let shot = try #require(fixture.shot("1"))
        let opening = fixture.opening
        let thick = try #require(
            S.outcome(glass: "annealed", thicknessMM: 12.7, opening: opening, shot: shot))
        #expect(!thick.broke)
        // On Kingery–Bulmash's reflected load the thin annealed panes go; at the measured 4 psi they
        // hold unflawed, but their stress passes what the indented panes broke at (Table 3: 5.6–5.9
        // ksi at 3.95 mm, 4.7 ksi at 0.219 in).
        for (thickness, failedAt) in [(3.95, 5.6 * psi * 1000), (5.56, 4.7 * psi * 1000)] {
            let nominal = try #require(
                S.outcome(glass: "annealed", thicknessMM: thickness, opening: opening, shot: shot))
            #expect(nominal.broke)
            let measured = try #require(
                S.outcome(
                    glass: "annealed", thicknessMM: thickness, opening: opening, shot: shot, peak: 4 * psi))
            #expect(!measured.broke && (measured.peakStress ?? 0) > failedAt)
        }
    }
}
