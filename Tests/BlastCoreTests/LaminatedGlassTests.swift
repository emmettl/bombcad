import Foundation
import Testing

@testable import BlastCore

@Suite("Laminated glass")
struct LaminatedGlassTests {
    /// Osnes, Holmen, Hopperstad and Børvik, "Fracture and fragmentation of blast-loaded laminated
    /// glass", *IJIE* 132 (2019) 103334 (CC BY), Table 2: 3.8 mm annealed / 1.52 mm PVB / 3.8 mm
    /// annealed, clamped over 300 × 300 mm in SIMLab's shock tube, the reflected pressure a
    /// Friedlander curve p_max (1 − t/t_d) exp(−b t/t_d). Measured: whether both plies cracked,
    /// and the largest deflection, mm (the centre target lost after it on D-01, D-03 and E-02).
    static let osnes:
        [(test: String, pMax: Double, duration: Double, b: Double, cracked: Bool, deflection: Double)] = [
            ("A-01", 167.8e3, 18.89e-3, 1.18, false, 3.74), ("A-02", 168.7e3, 18.78e-3, 1.15, false, 3.55),
            ("A-03", 169.7e3, 19.37e-3, 1.18, false, 3.56), ("A-04", 172.4e3, 18.87e-3, 1.21, false, 5.79),
            ("B-01", 204.3e3, 19.60e-3, 1.39, false, 4.25), ("B-02", 205.5e3, 19.65e-3, 1.29, false, 4.59),
            ("B-03", 206.3e3, 20.01e-3, 1.35, false, 4.38), ("C-01", 215.2e3, 20.62e-3, 1.42, false, 4.54),
            ("C-02", 215.6e3, 20.78e-3, 1.51, true, 69.67), ("D-01", 231.7e3, 21.40e-3, 1.63, true, 93.80),
            ("D-02", 237.4e3, 20.23e-3, 1.44, true, 95.41), ("D-03", 237.7e3, 21.09e-3, 1.48, true, 121.61),
            ("D-04", 238.9e3, 21.40e-3, 1.52, true, 92.53), ("E-01", 254.2e3, 23.10e-3, 2.21, true, 99.18),
            ("E-02", 258.9e3, 24.20e-3, 1.98, true, 111.61),
        ]

    static func friedlander(pMax: Double, duration: Double, b: Double, step: Double) -> [Double] {
        stride(from: 0.5 * step, to: duration, by: step).map { t in
            pMax * (1 - t / duration) * exp(-b * t / duration)
        }
    }

    @Test("Wölfel–Bennison's effective thicknesses and the membrane's shape follow their closed forms")
    func closedForms() {
        let laminate = LaminatedGlass(
            plies: [0.0038, 0.0038], interlayer: .pvb, interlayerThickness: 0.00152)
        let thickness = laminate.effectiveThicknesses(span: 0.3)
        // Between the plies acting apart, (2 × 3.8³)^(1/3) = 4.8 mm, and as one, 9.1 mm.
        #expect(thickness.deflection > 0.0048 && thickness.deflection < 0.0091)
        // The plies nearly act as one: the stress's thickness close to the deflection's.
        #expect(abs(thickness.stress / thickness.deflection - 1) < 0.1)
        // PVB's shear modulus relaxes from 178 MPa: about 64 MPa at 1 ms.
        #expect(abs(Interlayer.pvb.shearModulus(duration: 1e-3) / 1e6 - 64) < 3)
        // A square membrane: x = 0.0737 p a² / T; a long strip, a cable's p a² / 8T.
        #expect(abs(LaminatedGlass.membraneShape(aspect: 1) - 1 / 0.0737) < 0.05)
        #expect(abs(LaminatedGlass.membraneShape(aspect: 20) - 8) < 0.01)
        // Hooper's cracked 1.52 mm laminate at 10 s⁻¹: 15.9 MPa, 24 kN/m (he inferred 22 from
        // his panes' transverse wave speed).
        let tension = Interlayer.pvb.plateauStress(thickness: 0.00152, rate: 10) * 0.00152
        #expect(abs(tension / 1e3 - 24.2) < 0.5)
    }

    /// Runs every shot on a 3.8/1.52/3.8 pane at a 60 s strength (nil: E1300's median), printing a
    /// row a shot; returns how many cracked as measured, and the cracked panes' deflections over
    /// those measured.
    static func osnesShots(strength: Double?) -> (agreed: Int, ratios: [Double]) {
        let laminate = LaminatedGlass(
            plies: [0.0038, 0.0038], interlayer: .pvb, interlayerThickness: 0.00152)
        let system = EnvelopePanel.laminatedGlass(laminate, a: 0.3, b: 0.3, sixtySecondStrength: strength)
        let step = 1e-5
        var agreed = 0
        var ratios: [Double] = []
        for shot in osnes {
            let response = system.response(
                pressures: friedlander(pMax: shot.pMax, duration: shot.duration, b: shot.b, step: step),
                step: step)
            let cracked = response.crackedAt != nil
            if cracked == shot.cracked { agreed += 1 }
            if cracked && shot.cracked { ratios.append(response.peakDeflection * 1e3 / shot.deflection) }
            print(
                String(
                    format:
                        "%@ %.0f kPa: cracked %@ (measured %@) at %@ (%.0f MPa), %.1f mm (measured %.1f), torn %@",
                    shot.test, shot.pMax / 1e3, cracked ? "yes" : "no", shot.cracked ? "yes" : "no",
                    response.crackedAt.map { String(format: "%.2f ms", $0 * 1e3) } ?? "-",
                    (response.stressAtBreak ?? 0) / 1e6,
                    response.peakDeflection * 1e3, shot.deflection,
                    response.lostResistanceAt.map { String(format: "%.1f ms", $0 * 1e3) } ?? "no"))
        }
        return (agreed, ratios)
    }

    /// At E1300's median strength for the 0.09 m² pane (42.9 MPa held 60 s) every pane cracks,
    /// the eight that held too: the glass in the shock tube was stronger. Bisecting each shot for
    /// the strength at which its pane just holds puts the held panes' glass above 66.8 MPa and the
    /// cracked ones' between 66.7 and 79.3 MPa, so no single strength sorts all fifteen: C-01 held
    /// and C-02, a hair less impulsive, cracked. At 69 MPa (1.6 times E1300's median) the other
    /// fourteen sort as measured, cracking at 0.87–1.04 ms (measured 0.42–1.08 ms). The cracked
    /// panes, held by the interlayer, then go 0.67–0.89 times as far as measured, and none tears
    /// (none did). Their glass is held between neoprene strips, which a simply supported plate
    /// stands for: the panes that held deflected 2.8–3.5 mm in the model, 3.6–5.8 mm measured.
    @Test("Osnes et al.'s shock-tube panes: when the glass cracks, and how far the cracked pane goes")
    func osnesShockTube() {
        let median = Self.osnesShots(strength: nil)
        #expect(median.agreed == 7)
        let strong = Self.osnesShots(strength: 69e6)
        #expect(strong.agreed == 14)
        print(strong.ratios.map { String(format: "%.2f", $0) }.joined(separator: " "))
        #expect(strong.ratios.allSatisfy { $0 > 0.6 && $0 < 1.2 })
    }

    /// A triangular pulse, peak `peak` and impulse `impulse`, then (optionally) a triangular
    /// suction phase.
    static func triangle(
        peak: Double, impulse: Double, suction: Double = 0, suctionImpulse: Double = 0, step: Double,
        until: Double
    ) -> [Double] {
        let duration = 2 * impulse / peak
        let suctionDuration = suction > 0 ? 2 * suctionImpulse / suction : 0
        return stride(from: 0.5 * step, to: until, by: step).map { t in
            if t < duration { return peak * (1 - t / duration) }
            let u = t - duration
            guard u < suctionDuration else { return 0 }
            let half = 0.5 * suctionDuration
            return -suction * (u < half ? u / half : (suctionDuration - u) / half)
        }
    }

    /// Zhang, Hao and Wang, *IJIE* 78 (2015), field tests, Tables 3–5: 1.5 × 1.2 m panes clamped in
    /// steel frames on plastic strips, 10 kg TNT; reflected peak (kPa), impulse (kPa·ms), suction
    /// peak and impulse; the largest deflection (mm). 1-1-1 tore its PVB a little at 275 mm; 1-1-2
    /// was partly pulled out of its frame, 2-1-1 wholly on the rebound; 2-1-2 and 3-1-1 held.
    static let zhang:
        [(
            pane: String, ply: Double, interlayer: Double, peak: Double, impulse: Double, suction: Double,
            suctionImpulse: Double, deflection: Double, outcome: String
        )] = [
            ("1-1-1", 3, 1.52, 121.1, 395.0, 28.4, 319.7, 275, "PVB torn a little"),
            ("1-1-2", 3, 2.28, 121.1, 395.0, 28.4, 319.7, 280, "partly pulled out"),
            ("2-1-1", 3, 1.52, 168.6, 476.1, 35.8, 543.5, 326, "pulled out on the rebound"),
            ("2-1-2", 6, 1.52, 168.6, 476.1, 35.8, 543.5, 220, "held"),
            ("3-1-1", 3, 1.52, 82.2, 413.3, 17.5, 261.7, 264, "held"),
        ]

    /// Hooper, PhD thesis (Imperial College London, 2011), Tables 3.1, 3.7, 3.8 and 3.12: panes
    /// bonded with a 20 mm bite of structural silicone; the reflected peak and impulse at the pane
    /// measured (tests 3–6, 8) or ConWep's (1, 2, 7: the gauges there read side-on); the largest
    /// deflection up to failure (mm), the largest speed (m/s) and how each failed.
    static let hooper:
        [(
            test: String, a: Double, b: Double, ply: Double, interlayer: Double, peak: Double,
            impulse: Double,
            deflection: Double, speed: Double, outcome: String
        )] = [
            ("1", 1.5, 1.2, 3, 1.52, 165, 392, 179, 27.3, "joint failed, 7–8 ms"),
            ("2", 1.5, 1.2, 3, 1.52, 93.4, 288, 173, 17.4, "joint failed on the rebound"),
            ("3", 1.5, 1.2, 3, 1.52, 132, 413, 205, 20.5, "joint failed, 9–12 ms"),
            ("4", 1.5, 1.2, 3, 1.52, 152, 461, 140, 29.0, "joint failed, 7–9 ms"),
            ("5", 1.5, 1.2, 3, 1.52, 97, 419, 199, 21.9, "joint failed on the rebound"),
            ("6", 1.5, 1.2, 3, 1.52, 100, 418, 207, 22.3, "joint failed on the rebound"),
            ("7", 3.6, 2.0, 6, 1.52, 197, 739, 209, 23.7, "joint failed, PVB torn at 20% of the edge, 11 ms"),
            ("8", 3.3, 1.7, 6, 0.76, 223, 808, 185, 30.6, "PVB torn at every edge, 8.5 ms"),
        ]

    @Test("Zhang et al.'s and Hooper's framed panes in the open")
    func framedPanes() {
        let step = 2e-5
        print("Zhang et al. (clamped frames):")
        for pane in Self.zhang {
            let laminate = LaminatedGlass(
                plies: [pane.ply * 1e-3, pane.ply * 1e-3], interlayer: .pvb,
                interlayerThickness: pane.interlayer * 1e-3)
            let system = EnvelopePanel.laminatedGlass(laminate, a: 1.5, b: 1.2)
            let response = system.response(
                pressures: Self.triangle(
                    peak: pane.peak * 1e3, impulse: pane.impulse, suction: pane.suction * 1e3,
                    suctionImpulse: pane.suctionImpulse, step: step, until: 0.08),
                step: step)
            print(Self.row(pane.pane, response, measured: pane.deflection, outcome: pane.outcome))
            // Held by the interlayer, as the panes were (two then left their frames, which the
            // clamped edge here cannot), going 1.2–1.7 times as far as measured.
            #expect(response.crackedAt != nil && response.lostResistanceAt == nil)
            let ratio = response.peakDeflection * 1e3 / pane.deflection
            #expect(ratio > 1.1 && ratio < 1.8)
        }
        print("Hooper (structural silicone, 20 mm bite):")
        for test in Self.hooper {
            let laminate = LaminatedGlass(
                plies: [test.ply * 1e-3, test.ply * 1e-3], interlayer: .pvb,
                interlayerThickness: test.interlayer * 1e-3,
                edgeCapacity: LaminatedGlass.siliconeCapacity(bite: 0.02))
            let system = EnvelopePanel.laminatedGlass(laminate, a: test.a, b: test.b)
            let response = system.response(
                pressures: Self.triangle(
                    peak: test.peak * 1e3, impulse: test.impulse, step: step, until: 0.08),
                step: step)
            print(Self.row(test.test, response, measured: test.deflection, outcome: test.outcome))
            // Every pane leaves its frame, as all did, at about the speed measured.
            #expect(response.lostResistanceAt != nil)
            let speed = abs(response.velocityAtLoss ?? 0) / test.speed
            #expect(speed > 0.8 && speed < 1.6)
        }
    }

    static func row(_ name: String, _ response: SDOFResponse, measured: Double, outcome: String) -> String {
        String(
            format: "%@: cracked at %@, %.0f mm (measured %.0f), %@ (measured: %@)", name,
            response.crackedAt.map { String(format: "%.2f ms", $0 * 1e3) } ?? "-",
            (response.deflectionAtLoss ?? response.peakDeflection) * 1e3, measured,
            response.lostResistanceAt.map {
                String(format: "lost at %.1f ms, %.1f m/s", $0 * 1e3, abs(response.velocityAtLoss ?? 0))
            } ?? "held", outcome)
    }

    @Test("A laminated window cracks and stays in its frame (GSA 2), or leaves it and is thrown")
    func envelopeWindow() throws {
        let owner = UUID()
        let laminated = EnvelopeConstruction(
            objectID: owner, source: .user, detail: "laminated", laminate: .facade)
        #expect(abs(laminated.glassThicknessM - 0.01352) < 1e-6)
        let annealed = EnvelopeConstruction.assumed(objectID: owner)
        func window(_ peak: Double) -> EnvelopeComponentLoad {
            // A 1.2 m wide, 1.5 m tall window facing x, a triangular load lasting 10 ms.
            EnvelopeComponentLoad(
                id: "\(owner.uuidString)/pane/0.0", owner: owner, kind: .pane,
                region: Box(min: SIMD3(0, 0, 1), max: SIMD3(0.02, 1.2, 2.5)), axis: 0, binS: 1e-4,
                outerPa: Self.triangle(peak: peak, impulse: peak * 5e-3, step: 1e-4, until: 0.1), innerPa: [],
                supportEdges: [true, true, true, true])
        }
        let held = try #require(EnvelopeDamageAssessment.assess(window(30e3), construction: laminated))
        #expect(held.material == .laminatedGlass && held.crackedAtS != nil && held.failedAtS == nil)
        #expect(held.glazing?.condition == .two && held.glazing?.rating == .noHazard)
        #expect(held.levels == EnvelopeDamageLevel.heavy ... .heavy)
        let thrown = try #require(EnvelopeDamageAssessment.assess(window(150e3), construction: laminated))
        #expect(thrown.failedAtS != nil && (thrown.glazing?.condition ?? .one) >= .threeA)
        let broken = try #require(EnvelopeDamageAssessment.assess(window(30e3), construction: annealed))
        #expect(broken.material == .annealedGlass && broken.crackedAtS == nil && broken.failedAtS != nil)
        print(held.glazing!, thrown.glazing!, broken.glazing!)
        // A construction saved without a laminate opens as annealed glass.
        let decoded = try JSONDecoder().decode(
            EnvelopeConstruction.self, from: JSONEncoder().encode(annealed))
        #expect(decoded.laminate == nil)
        let reopened = try JSONDecoder().decode(
            EnvelopeConstruction.self, from: JSONEncoder().encode(laminated))
        #expect(reopened.laminate == .facade)
    }

    @Test("Roof glass over a concourse: held, or falling whole or in shards, graded at 79 J and 14.9 J")
    func overhead() throws {
        let owner = UUID()
        let laminated = EnvelopeConstruction(
            objectID: owner, source: .user, detail: "laminated", laminate: .facade)
        let annealed = EnvelopeConstruction.assumed(objectID: owner)
        func roofPane(_ peak: Double) -> EnvelopeComponentLoad {
            // A 1.2 × 1.5 m roof pane 8 m above the floor, loaded downward for 10 ms.
            EnvelopeComponentLoad(
                id: "\(owner.uuidString)/pane/0.0", owner: owner, kind: .pane,
                region: Box(min: SIMD3(0, 0, 8), max: SIMD3(1.2, 1.5, 8.02)), axis: 2, binS: 1e-4,
                outerPa: Self.triangle(peak: peak, impulse: peak * 5e-3, step: 1e-4, until: 0.1), innerPa: [],
                supportEdges: [true, true, true, true])
        }
        func overhead(_ peak: Double, _ construction: EnvelopeConstruction) -> OverheadGlassHazard? {
            EnvelopeDamageAssessment.assess(roofPane(peak), construction: construction, buildingBase: 0)?
                .overhead
        }
        let held = try #require(overhead(30e3, laminated))
        #expect(held.fall == .held && !held.hazardous)
        let whole = try #require(overhead(150e3, laminated))
        #expect(whole.fall == .whole && whole.hazardous)
        // Faster than falling 8 m from rest, the load having pushed it down first.
        #expect(whole.impactSpeedMS > (2 * 9.81 * 8).squareRoot())
        let energy = whole.massKg * whole.impactSpeedMS * whole.impactSpeedMS / 2
        #expect(abs((whole.pieceEnergyJ ?? 0) - energy) < 1e-6)
        let shards = try #require(overhead(30e3, annealed))
        #expect(shards.fall == .shards && shards.pieceEnergyJ == nil)
        // A 6 mm shard s square strikes with 79 J where 2500 × 0.006 s² × v²/2 = 79.
        let perMass = shards.impactSpeedMS * shards.impactSpeedMS / 2
        let side = (79 / (2500 * 0.006 * perMass)).squareRoot()
        #expect(abs((shards.hazardousShardM ?? 0) - side) < 1e-6 && shards.hazardous)
        print(whole, shards)
    }
}
