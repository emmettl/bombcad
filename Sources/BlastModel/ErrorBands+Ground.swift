import Foundation
import simd

// The ground shock's bands and figures (emmettl/bombcad-work#26).
// See ErrorBands.swift for the types.

extension ValidationTables {
    /// The half-space's motion where the ground's own wave outruns the blast: Prairie Flat's
    /// judge of a factor of three, which all 16 records past its outrunning limit met. Part of
    /// `figures`, in its order.
    static let groundFigures: [Figure] = [
        Figure(
            id: "groundOutrun", low: 0.33, high: 3,
            document: "ground-shock-outrunning.md#against-prairie-flat-20-october-2026",
            quote: "a band of 0.33 to 3 times")
    ]
}

extension StandingScene {
    /// `bands(for:)`'s case .groundShock: a band only for the half-space, and only for the motion
    /// at points the ground's own wave reaches before the air.
    func groundBands(bands: inout [ErrorBand], unbanded: inout [String]) {
        if has(.halfSpace) {
            bands.append(
                figure(
                    "groundOutrun", .groundVelocity, "Ground's motion where outrun", lowIsUnsafe: true,
                    low: "too little", high: "too much",
                    validity:
                        "the elastic half-space's peak downward and outward velocity at points labelled "
                        + "outrun, 170 to 350 m from 500 t of TNT, 0.5 to 3 m deep, on two measured layers with "
                        + "their densities assumed; a factor of three, Prairie Flat's judge, which all 16 records "
                        + "met (0.47–2.25, with the direct source)",
                    check: "Prairie Flat's 500 t, past its outrunning limit"))
            unbanded.append(
                "Inside the outrunning limit, where the air reaches a point first: within a factor of two at under "
                    + "two-thirds of Prairie Flat's records, too far off to band.")
        } else {
            unbanded.append(
                "Two measured surface bursts, too far off to band: at Xia's the vertical velocity 20 to 80 times "
                    + "the measured near and past where the ground's wave outruns the air; at Prairie Flat's, inside "
                    + "that limit, within a factor of two at under half the records.")
        }
    }
}
