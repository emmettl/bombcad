import Foundation
import Testing

@testable import BlastModel

/// Security film on monolithic 1/4" (6 mm) panes against the open test reports film makers post:
/// shock-tube and arena tests to GSA-TS01 and ASTM F1642, each with its measured reflected peak and
/// impulse and the condition the pane was graded at (no open report gives a deflection).
@Suite("Security film")
struct SecurityFilmTests {
    struct Shot {
        var report: String
        var specimen: String
        /// The daylight opening, inches.
        var width: Double
        var height: Double
        var toughened: Bool
        var mils: Double
        var anchorage: SecurityFilm.Anchorage
        /// Reflected peak (psi) and impulse (psi·ms), as the report gives them.
        var peak: Double
        var impulse: Double
        /// GSA-TS01's condition, as graded.
        var condition: GlazingHazard.Condition
        /// Inches of the film pulled out of the frame, as reported (0 for none); nil where the
        /// report says only that the pane left whole.
        var pullout: Double?
    }

    static let shots: [Shot] = {
        var shots: [Shot] = []
        func add(
            _ report: String, _ specimen: String, _ size: (Double, Double), _ glass: String, _ mils: Double,
            _ anchorage: SecurityFilm.Anchorage, _ peak: Double, _ impulse: Double, _ condition: String,
            _ pullout: Double?
        ) {
            shots.append(
                Shot(
                    report: report, specimen: specimen, width: size.0, height: size.1,
                    toughened: glass == "T",
                    mils: mils, anchorage: anchorage, peak: peak, impulse: impulse,
                    condition: GlazingHazard.Condition(rawValue: condition)!, pullout: pullout))
        }
        let ipp = SecurityFilm.Anchorage.mechanical
        let ipa = SecurityFilm.Anchorage.wetGlazed
        let daylight = SecurityFilm.Anchorage.daylight
        // Intertek-ATI shock tube, York PA, for 3M, 2014: 36 × 48 in daylight opening, 1/2" bite.
        // D8962.03-119-12, Ultra S800 (8 mil), IPP (gasketed mechanical) and IPA (silicone bead).
        let s800 = "3M D8962.03"
        let tube = (36.0, 48.0)
        add(s800, "1", tube, "T", 8, ipp, 7.20, 45, "2", 0)
        add(s800, "2", tube, "T", 8, ipp, 6.94, 44, "2", 0)
        add(s800, "3", tube, "T", 8, ipp, 6.83, 43, "2", 0)
        add(s800, "4", tube, "T", 8, ipp, 6.91, 42, "2", 0)
        add(s800, "5", tube, "T", 8, ipa, 6.97, 41, "2", 0)
        add(s800, "6", tube, "T", 8, ipa, 6.55, 43, "2", 0)
        add(s800, "7", tube, "T", 8, ipa, 7.27, 44, "2", 0)
        add(s800, "8", tube, "T", 8, ipa, 9.47, 63, "2", 0)
        add(s800, "9", tube, "A", 8, ipp, 7.03, 44, "3a", 23)
        add(s800, "10", tube, "A", 8, ipp, 6.69, 43, "2", 0)
        add(s800, "11", tube, "A", 8, ipp, 6.51, 42, "2", 0)
        add(s800, "12", tube, "A", 8, ipa, 7.04, 43, "2", 0)
        add(s800, "13", tube, "A", 8, ipa, 6.43, 42, "2", 0)
        add(s800, "14", tube, "A", 8, ipa, 6.85, 44, "2", 0)
        add(s800, "15", tube, "A", 8, ipa, 9.31, 60, "2", 0)
        // D8962.01-119-12, Ultra S600 (6 mil), IPP. Specimen 8's load was not recorded: the target,
        // 6 psi and 42 psi·ms.
        let s600p = "3M D8962.01"
        add(s600p, "1", tube, "T", 6, ipp, 7.16, 45, "4", 20)
        add(s600p, "2", tube, "T", 6, ipp, 6.65, 40, "3a", 1)
        add(s600p, "3", tube, "T", 6, ipp, 6.77, 43, "2", 0)
        add(s600p, "4", tube, "T", 6, ipp, 7.39, 43, "2", 0)
        add(s600p, "5", tube, "A", 6, ipp, 6.82, 44, "3a", 1.5)
        add(s600p, "6", tube, "A", 6, ipp, 7.14, 43, "4", 47)
        add(s600p, "7", tube, "A", 6, ipp, 6.86, 41, "2", 0)
        add(s600p, "8", tube, "A", 6, ipp, 6.00, 42, "2", 0)
        // D8962.02-119-12, Ultra S600, IPA. Specimen 4 was graded 5 with no pullout or tear
        // recorded, unexplained.
        let s600a = "3M D8962.02"
        add(s600a, "1", tube, "T", 6, ipa, 6.62, 42, "2", 0)
        add(s600a, "2", tube, "T", 6, ipa, 6.98, 42, "2", 0)
        add(s600a, "3", tube, "T", 6, ipa, 6.50, 43, "2", 0)
        add(s600a, "4", tube, "T", 6, ipa, 9.47, 62, "5", 0)
        add(s600a, "5", tube, "A", 6, ipa, 7.07, 42, "2", 0)
        add(s600a, "6", tube, "A", 6, ipa, 7.04, 45, "2", 0)
        add(s600a, "7", tube, "A", 6, ipa, 6.72, 44, "2", 0)
        // E1272.01-119-12, Ultra Night Vision S25 and Prestige S50 (8 mil), monolithic lites
        // channel-glazed in a 43-1/4 × 61-1/4 in opening.
        let large = "3M E1272"
        let largeTube = (43.25, 61.25)
        add(large, "1", largeTube, "A", 8, ipa, 6.76, 43, "2", 0)
        add(large, "2", largeTube, "A", 8, ipp, 6.82, 43, "5", nil)
        add(large, "3", largeTube, "T", 8, ipa, 6.79, 45, "2", 0)
        add(large, "4", largeTube, "T", 8, ipp, 5.02, 32, "3b", 30)
        add(large, "9", largeTube, "A", 8, ipa, 6.90, 45, "4", 20)
        add(large, "10", largeTube, "A", 8, ipp, 4.99, 32, "5", nil)
        add(large, "11", largeTube, "T", 8, ipa, 6.68, 45, "2", 0)
        add(large, "12", largeTube, "T", 8, ipp, 5.10, 33, "5", nil)
        // E1298.01-801-12, ATI arena, Tahoka TX, 2014, ANFO: Ultra S600 and S800 in a
        // 44-1/2 × 62-1/2 in opening, daylight but for 10 and 11 (IPP). Every film tore round its
        // whole perimeter; the lites were thrown out (9 in).
        let arena = "3M E1298"
        let arenaPane = (44.5, 62.5)
        for (n, glass, mils) in [
            ("1", "A", 6.0), ("2", "A", 8.0), ("3", "T", 6.0), ("4", "T", 8.0), ("5", "A", 6.0),
            ("6", "A", 8.0),
            ("7", "T", 6.0), ("8", "T", 8.0),
        ] {
            let graded = ["1": "4", "6": "5"][n] ?? "3b"
            add(arena, n, arenaPane, glass, mils, daylight, 4.744, 28.38, graded, nil)
        }
        add(arena, "9", arenaPane, "A", 8, daylight, 10.97, 42.48, "5", nil)
        add(arena, "10", arenaPane, "A", 6, ipp, 10.97, 42.48, "5", nil)
        add(arena, "11", arenaPane, "T", 8, ipp, 10.97, 42.48, "3b", nil)
        add(arena, "12", arenaPane, "T", 6, daylight, 10.97, 42.48, "3b", nil)
        for (n, glass, mils) in [("13", "A", 6.0), ("14", "T", 6.0), ("15", "T", 8.0), ("16", "A", 8.0)] {
            add(arena, n, arenaPane, glass, mils, daylight, 5.19, 28.63, "3b", nil)
        }
        // ARA-TR-00-0041.1-3 for MSC Specialty Films, DTRA Chestnut site, 2000, 600 lb ANFO: 1/4"
        // annealed 46 × 64 in panes in storefront frames; the load measured on each structure.
        // The two-sided mechanical anchorages (MSC-2) are left out.
        let ara = "ARA 2000"
        let araPane = (46.0, 64.0)
        add(ara, "MSC-1-3", araPane, "A", 4, daylight, 4.3, 28.7, "3b", nil)
        add(ara, "MSC-1-2", araPane, "A", 7, daylight, 4.3, 28.7, "3b", nil)
        add(ara, "MSC-1-4", araPane, "A", 8, daylight, 4.3, 28.7, "3b", nil)
        add(ara, "MSC-3-1", araPane, "A", 8, ipp, 4.4, 28.0, "3a", 0)
        add(ara, "MSC-3-4", araPane, "A", 8, ipa, 4.4, 28.0, "3a", 0)
        add(ara, "MSC-5-4", araPane, "A", 14, ipp, 9.2, 48.3, "3a", 0)
        add(ara, "MSC-4-4", araPane, "A", 14, ipp, 11.2, 51.5, "3b", 0)
        // B7294.02-801-12, ATI arena for Solar Gard, 2010, 400 lb ANFO at 159 ft (the load partly
        // ConWep's): 44-3/4 × 62-3/4 in, wet glazed with a 3/4" bead. Specimen 5's condition is
        // not stated; a fragment struck the witness panel 9" up, condition 4.
        let solar = "Solar Gard B7294.02"
        let solarPane = (44.75, 62.75)
        add(solar, "5", solarPane, "T", 7, ipa, 5.633, 25.551, "4", nil)
        add(solar, "6", solarPane, "A", 8, ipa, 5.633, 25.551, "3b", 0)
        add(solar, "7", solarPane, "T", 8, ipa, 5.633, 25.551, "2", 0)
        add(solar, "8", solarPane, "A", 7, ipa, 5.633, 25.551, "3b", 0)
        // F5228.01-801-12, for Solar Gard, 2016, 400 lb ANFO at 159 ft: 8 mil with EdgPro, a
        // flexible mechanical attachment, 44-3/4 × 62 in; both pulled out round their perimeter.
        let edgpro = "Solar Gard F5228.01"
        add(edgpro, "1", (44.75, 62), "T", 8, ipp, 5.03, 28.24, "3b", nil)
        add(edgpro, "2", (44.75, 62), "A", 8, ipp, 5.03, 28.24, "3b", nil)
        return shots
    }()

    static func run(_ shot: Shot) -> (response: SDOFResponse, hazard: GlazingHazard) {
        let inch = 0.0254
        let (a, b) = (shot.width * inch, shot.height * inch)
        let film = SecurityFilm.mils(shot.mils, anchorage: shot.anchorage)
        let system = EnvelopePanel.filmedGlass(film, thickness: 0.006, toughened: shot.toughened, a: a, b: b)
        let step = 2e-5
        let pressures = LaminatedGlassMeasurements.triangle(
            peak: shot.peak * 6894.76, impulse: shot.impulse * 6.89476, step: step, until: 0.1)
        let response = system.response(pressures: pressures, step: step)
        let hazard = GlazingHazard.broken(
            response: response, netPa: pressures, binS: step, massPerArea: system.massPerArea,
            paneHeight: max(a, b))
        return (response, hazard)
    }

    /// Each anchorage against its tests, GSA's conditions in order (1 best, 5 worst):
    /// - **Wet glazed:** held, condition 2, where most were graded 2; the rest tore or pulled out
    ///   in part and were graded worse. The model is never graded worse than a test.
    /// - **Daylight:** held while pushed, gone outward on the rebound, condition 3a; the tests'
    ///   sheets were not thrown in either, but their fragments reached 1–3 m (3b), so the model is
    ///   one class better than most. The toughened panes at 11 psi reach the end of Moore's curves
    ///   (ten thicknesses) unbroken and are lost there, graded 5 (the tests' broke, 3b).
    /// - **Mechanical:** pulled out at the vendor's capacity once the film yields, condition 5:
    ///   never better than a test.
    @Test("Filmed panes against the open GSA test reports")
    func reports() {
        var tally: [SecurityFilm.Anchorage: (n: Int, exact: Int, better: Int, worse: Int)] = [:]
        for shot in Self.shots {
            let (response, hazard) = Self.run(shot)
            var row = tally[shot.anchorage] ?? (0, 0, 0, 0)
            row.n += 1
            if hazard.condition == shot.condition { row.exact += 1 }
            if hazard.condition < shot.condition { row.better += 1 }
            if hazard.condition > shot.condition { row.worse += 1 }
            tally[shot.anchorage] = row
            print(
                String(
                    format:
                        "%@ %@: %@ %.0f mil %@, %.2f psi %.0f psi·ms: cracked %@, %@; condition %@ (graded %@)",
                    shot.report, shot.specimen, shot.toughened ? "T" : "A", shot.mils,
                    shot.anchorage.rawValue,
                    shot.peak, shot.impulse,
                    response.crackedAt.map { String(format: "%.1f ms", $0 * 1e3) } ?? "no",
                    response.lostResistanceAt.map {
                        String(
                            format: "lost at %.1f ms, %.0f mm, %.1f m/s", $0 * 1e3,
                            (response.deflectionAtLoss ?? 0) * 1e3, response.velocityAtLoss ?? 0)
                    } ?? String(format: "held, %.0f mm", response.peakDeflection * 1e3),
                    hazard.condition.rawValue, shot.condition.rawValue))
        }
        for (anchorage, row) in tally.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print(
                "\(anchorage.rawValue): \(row.n) tests, \(row.exact) as graded, \(row.better) better, \(row.worse) worse"
            )
        }
        let wet = tally[.wetGlazed]!
        #expect(wet.n == 24 && wet.exact == 18 && wet.worse == 0)
        let daylight = tally[.daylight]!
        #expect(daylight.n == 17 && daylight.better == 16)
        let mechanical = tally[.mechanical]!
        #expect(mechanical.n == 26 && mechanical.better == 0)
    }

    @Test("A filmed window in the damage path: held wet glazed (GSA 2), gone outward in daylight (3a)")
    func envelopeWindow() throws {
        let owner = UUID()
        func construction(_ film: SecurityFilm?) -> EnvelopeConstruction {
            var construction = EnvelopeConstruction.assumed(objectID: owner)
            construction.film = film
            return construction
        }
        // A 0.9 m wide, 1.2 m tall window facing x, under the 3M shock tube's 7 psi and 43 psi·ms.
        let load = EnvelopeComponentLoad(
            id: "\(owner.uuidString)/pane/0.0", owner: owner, kind: .pane,
            region: Box(min: SIMD3(0, 0, 1), max: SIMD3(0.02, 0.914, 2.219)), axis: 0, binS: 1e-4,
            outerPa: LaminatedGlassMeasurements.triangle(peak: 48e3, impulse: 300, step: 1e-4, until: 0.1),
            innerPa: [], supportEdges: [true, true, true, true])
        let wet = try #require(
            EnvelopeDamageAssessment.assess(load, construction: construction(.mils(8, anchorage: .wetGlazed)))
        )
        #expect(wet.material == .filmedGlass && wet.crackedAtS != nil && wet.failedAtS == nil)
        #expect(wet.glazing?.condition == .two)
        let daylight = try #require(
            EnvelopeDamageAssessment.assess(load, construction: construction(.mils(8, anchorage: .daylight))))
        #expect(daylight.failedAtS != nil && daylight.glazing?.condition == .threeA)
        let bare = try #require(EnvelopeDamageAssessment.assess(load, construction: construction(nil)))
        #expect(bare.material == .annealedGlass && (bare.glazing?.condition ?? .one) >= .four)
        print(wet.glazing!, daylight.glazing!, bare.glazing!)
    }

    @Test("A filmed pane's construction: its pane, its record, a document's film")
    func construction() throws {
        var construction = EnvelopeConstruction(
            objectID: UUID(), glassThicknessM: 0.006, source: .user, detail: "Filmed")
        #expect(construction.hasPlainGlass && construction.paneMaterial == .annealedGlass)
        construction.film = .mils(8, anchorage: .wetGlazed)
        #expect(!construction.hasPlainGlass && construction.holdsFragments)
        #expect(construction.paneMaterial == .filmedGlass && abs(construction.glassAloneM - 0.006) < 1e-9)
        let pane = construction.pane(a: 0.914, b: 1.219)
        // 6 mm of glass and 8 mil of film; 21 kN/m once the glass cracks.
        #expect(abs(pane.massPerArea - (15 + 1390 * 8 * 25.4e-6)) < 0.01)
        #expect(abs((pane.membrane?.tension ?? 0) - 20.9e3) < 0.1e3)
        #expect(pane.membrane?.edgeCapacity == nil)
        let decoded = try JSONDecoder().decode(
            EnvelopeConstruction.self, from: JSONEncoder().encode(construction))
        #expect(decoded.film == construction.film)
        var broken = SecurityFilm.mils(8, anchorage: .mechanical)
        broken.anchorageCapacity = -1
        #expect(throws: (any Error).self) { try broken.validate() }
    }
}
