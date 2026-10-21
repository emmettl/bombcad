import Foundation

package enum SandiaGlassStudy {
    /// `glass-sandia` (`--fixture` the path of Fixtures/BeauchampMatalucci1998/windows.json):
    /// the envelope's glass against Beauchamp and Matalucci's windows, which broke and which held,
    /// and the filmed panes' speeds (docs/validation.md#sandias-windows).
    package static func run(_ args: [String]) throws {
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        typealias S = SandiaWindows1998
        let url = URL(filePath: value("fixture") ?? "Fixtures/BeauchampMatalucci1998/windows.json")
        let fixture = try S.fixture(from: url)
        func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }
        let psi = 6894.76
        func describe(_ o: S.Outcome) -> String {
            if let t = o.crackedAt { return "cracks at \(f(t * 1000)) ms" }
            if let t = o.lostAt { return "leaves its frame at \(f(t * 1000)) ms, uncracked" }
            return "holds, peak \(f(o.peakDeflection * 1000, 1)) mm"
                + (o.peakStress.map { ", \(f($0 / 1e6, 0)) MPa" } ?? "")
        }

        print(
            "The shots: Kingery–Bulmash for a hemisphere on the ground, against the report's nominal values")
        print(
            "shot | TNT (kg) | Z (m/kg^(1/3)) | incident kPa (nominal) | impulse Pa s (nominal) | reflected kPa, Pa s"
        )
        for shot in fixture.shots {
            guard let point = S.blast(shot) else { continue }
            let (tnt, _) = S.charge(shot)
            print(
                "\(shot.name) | \(f(tnt, 3)) | \(f(point.scaledDistance)) | \(f(point.incidentPressure / 1000, 1)) "
                    + "(\(f(shot.nominalPeakPsi * psi / 1000, 1))) | \(f(point.incidentImpulse(mass: tnt), 1)) "
                    + "(\(f(shot.nominalImpulsePsiMs * psi / 1000, 1))) | \(f(point.reflectedPressure / 1000, 1)), "
                    + "\(f(point.reflectedImpulse(mass: tnt), 1))"
                    + (shot.measuredPeakPsi.map { "; measured \(f($0 * psi / 1000, 1)) kPa" } ?? ""))
        }

        print("\nWhich broke: the panes (flawed as tested) against the model's unflawed panes")
        for pane in fixture.panes {
            guard let shot = fixture.shot(pane.shot),
                let model = S.outcome(
                    glass: pane.glass, thicknessMM: pane.thicknessMM, opening: fixture.opening, shot: shot)
            else { continue }
            var line =
                "shot \(pane.shot) | \(pane.glass) \(f(pane.thicknessMM)) mm, \(pane.flaws) | "
                + "\(pane.broke ? "broke" : "held") | model " + describe(model)
            if let measured = shot.measuredPeakPsi,
                let scaled = S.outcome(
                    glass: pane.glass, thicknessMM: pane.thicknessMM, opening: fixture.opening, shot: shot,
                    peak: measured * psi)
            {
                line += "; at the measured \(f(measured, 1)) psi " + describe(scaled)
            }
            print(line)
        }

        print("\nThe filmed panes' speeds (central cluster, m/s)")
        for speed in fixture.speeds {
            guard let shot = fixture.shot(speed.shot),
                let model = S.outcome(
                    glass: speed.glass, thicknessMM: speed.thicknessMM, opening: fixture.opening, shot: shot)
            else { continue }
            let measured = speed.ftPerS * 0.3048
            let predicted = model.speed ?? 0
            let low =
                S.outcome(
                    glass: speed.glass, thicknessMM: speed.thicknessMM, opening: fixture.opening, shot: shot,
                    nominal: true)?.speed ?? 0
            print(
                "\(speed.label) | measured \(f(measured, 1)) | model \(f(predicted, 1))"
                    + ", " + describe(model)
                    + " | \(f(predicted / measured)) of measured; on the nominal's load \(f(low, 1)), "
                    + "\(f(low / measured))")
        }
        // The speed if the pane took the whole reflected impulse as a free mass, for scale.
        if let shot = fixture.shot("film"), let point = S.blast(shot) {
            let impulse = point.reflectedImpulse(mass: S.charge(shot).tnt)
            let arrival = point.arrival(mass: S.charge(shot).tnt)
            print(
                "Whole reflected impulse \(f(impulse, 0)) Pa s over 2,500 kg/m³: "
                    + "\(f(impulse / (2500 * 0.003175), 1)) m/s at 1/8 in, \(f(impulse / (2500 * 0.00635), 1)) at 1/4 in; "
                    + "the shock arrives \(f(arrival * 1000, 1)) ms after the detonation")
        }
    }
}
