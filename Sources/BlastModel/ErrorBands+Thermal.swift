import Foundation
import simd

// The fireball's and the cloud's bands and figures.
// Split from ErrorBands.swift (emmettl/bombcad-work#50); see that file for the types.

extension ValidationTables {
    /// The fireball's radiation and the cloud's top. Part of `figures`, in its order.
    static let thermalFigures: [Figure] = [
        Figure(
            id: "fireballTotal", low: 3, high: 5.5, document: "validation.md#summary",
            quote: "exceeds three to five and a half times"),
        Figure(
            id: "fireballCooling", low: 2, high: 3, document: "thermal-radiation.md#limitations",
            quote: "three to five times (two to three with the gas cooling)"),
        Figure(
            id: "cloudTop", low: 0.79, high: 1.21, document: "fireball-rise.md",
            quote: "to 4% on average and 21% shot by shot"),
    ]
}

extension StandingScene {
    /// `bands(for:)`'s case .thermal.
    func thermalBands(bands: inout [ErrorBand], unbanded: inout [String]) {
        if has(.deflagration) {
            unbanded.append("Energy radiated: compared with TNT fireballs, not a gas deflagration.")
        } else if !burning {
            unbanded.append(
                "Energy radiated: compared with afterburning and hot air, today's defaults; without both the "
                    + "fireball is gone within 50 ms, or with afterburning alone radiates 29% against 21%."
            )
        } else if inputs.thermal?.fireball == .volume {
            bands.append(
                figure(
                    has(.radiativeCooling) ? "fireballCooling" : "fireballTotal", .radiatedEnergy,
                    "Energy radiated", lowIsUnsafe: true, low: "too dim", high: "too bright",
                    validity: "a 100 t TNT shot, the volume", check: "DREO's TNT fireball"))
        } else {
            unbanded.append("Only the volume's radiation was compared with a measurement.")
        }
    }

    /// `bands(for:)`'s case .cloud.
    func cloudBands(bands: inout [ErrorBand], unbanded: inout [String]) {
        if has(.deflagration) {
            unbanded.append("Cloud's top: compared with TNT clouds, not a gas deflagration.")
        } else if has(.afterburning) && !has(.hotAir) {
            unbanded.append(
                "Cloud's top: Church's clouds were compared with afterburning and hot air together, today's "
                    + "defaults; afterburning alone was not run against them.")
        } else if has(.afterburning) {
            bands.append(
                figure(
                    "cloudTop", .cloudTop, "Cloud's top", lowIsUnsafe: true, low: "too low",
                    high: "too high",
                    validity: "54 to 1,270 kg of TNT, half a minute to two minutes; 21% is a geometric "
                        + "spread, not a bound, with afterburning whose burning time was fitted to the open blast",
                    check: "Church's 22 detonations"))
        } else {
            unbanded.append("The comparison with Church's clouds was made with afterburning on.")
        }
    }
}
