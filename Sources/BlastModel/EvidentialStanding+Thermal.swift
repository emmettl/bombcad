import Foundation
import simd

// Thermal: the standing's entries, fields and results for the fireball's, the surfaces' heating and the cloud's part of a scene.
// Split from EvidentialStanding.swift (emmettl/bombcad-work#50); see that file for the types.

extension StandingTable {
    /// The entries of the fireball's, the surfaces' heating and the cloud's options; `entry(for:)` sends them here.
    static func thermalEntry(for option: ModelOption) -> Entry {
        switch option {
        case .thermalVolume:
            return Entry(
                title: "Fireball as a volume", affects: [.thermal], limit: nil,
                note: "The luminous cells as a partly transparent gas, its absorption an assumption.",
                document: "thermal-radiation.md#the-volume-against-the-shape")
        case .thermalShape:
            return Entry(
                title: "Fireball as an opaque shape", affects: [.thermal], limit: nil,
                note: "An opaque flame of the gas's shape, at a chosen emissivity.",
                document: "thermal-radiation.md#the-model")
        case .thermalSphere:
            return Entry(
                title: "Fireball as a sphere", affects: [.thermal], limit: nil,
                note: "The fireball's equivalent sphere, at a chosen emissivity.",
                document: "thermal-radiation.md#the-model")
        case .surfaceHeating:
            return Entry(
                title: "Surface heating", affects: [.surfaceHeating], limit: .illustrative,
                note: "Each surface heated as an inert solid, one dimension deep; ignition flags are test "
                    + "thresholds, not a fire model.",
                document: "surface-heating.md")
        case .measuredSounding:
            return Entry(
                title: "Measured sounding", affects: [.cloud], limit: nil,
                note: "A measured atmosphere sets the air, its wind and its humidity.",
                document: "fireball-rise.md#a-measured-sounding")
        case .cloudSpread:
            return Entry(
                title: "Spread after stopping", affects: [.cloud], limit: nil,
                note: "Once it stops rising the cloud spreads as a gravity current and a Pasquill–Gifford "
                    + "puff; no measured width of a high-explosive cloud has been found to check it.",
                document: "fireball-rise.md#limitations")
        default:
            preconditionFailure(
                "\(option) is not one of the fireball's, the surfaces' heating and the cloud's options")
        }
    }

    /// The fields of the fireball's, the surfaces' heating and the cloud's inputs; part of `fields`.
    static let thermalFields: [String: Field] = [
        // Models run alongside.
        "ThermalSpec.luminousTemperature": .input,
        "ThermalSpec.emissivity": .input,
        "ThermalSpec.surfaceSpacing": .input,
        "ThermalSpec.groundSpacing": .input,
        "ThermalSpec.samples": .numerical,
        "ThermalSpec.fireball": .option([.thermalVolume, .thermalShape, .thermalSphere]),
        "ThermalSpec.absorption": .input,
        "ThermalSpec.sootYield": .input,
        "ThermalSpec.hotAirAbsorption": .input,
        "ThermalSpec.marchStep": .numerical,
        "ThermalSpec.heating": .option([.surfaceHeating]),
        "SurfaceHeatingSpec.enabled": .option([.surfaceHeating]),
        "SurfaceHeatingSpec.ambient": .input,
        "SurfaceHeatingSpec.convection": .input,
        "SurfaceHeatingSpec.ground": .input,
        "SurfaceHeatingSpec.blocks": .input,
        "SurfaceHeatingSpec.structure": .input,
        "SurfaceHeatingSpec.overrides": .input,
        "SurfaceHeatingSpec.materials": .input,
        "SurfaceHeatingSpec.cells": .numerical,
        "SurfaceHeatingSpec.resolvedTime": .numerical,
        "SurfaceHeatingSpec.horizon": .numerical,
        "SurfaceHeatingSpec.maximumStep": .numerical,
        "CloudSpec.handOverTemperature": .input,
        "CloudSpec.entrainment": .input,
        "CloudSpec.addedMass": .input,
        "CloudSpec.emissivity": .input,
        "CloudSpec.lapseRate": .input,
        "CloudSpec.tropopause": .input,
        "CloudSpec.specificHeat": .input,
        "CloudSpec.windSpeed": .input,
        "CloudSpec.windDirection": .input,
        "CloudSpec.windHeight": .input,
        "CloudSpec.windExponent": .input,
        "CloudSpec.windCeiling": .input,
        "CloudSpec.relativeHumidity": .input,
        "CloudSpec.productWater": .input,
        "CloudSpec.rainRate": .input,
        "CloudSpec.rainThreshold": .input,
        "CloudSpec.frictionVelocity": .input,
        "CloudSpec.convectiveVelocity": .input,
        "CloudSpec.boundaryLayerHeight": .input,
        "CloudSpec.turbulentEntrainment": .input,
        "CloudSpec.sounding": .option([.measuredSounding]),
        "CloudSpec.northDirection": .input,
        "CloudSpec.spread": .option([.cloudSpread]),
        "CloudSpec.frontFroude": .input,
        "CloudSpec.stabilityClass": .input,
        "CloudSpec.leastTransportSpeed": .input,
        "CloudSpec.duration": .input,
        "CloudSpec.frameInterval": .numerical,
    ]
}

extension StandingScene {
    func thermal() -> ResultStanding {
        let cooling = has(.radiativeCooling)
        var assumptions = [
            cooling
                ? "The luminous gas loses what it radiates, on the lattice's 26 directions, into black."
                : "The radiated energy is not taken from the gas, which stays hot and luminous too long.",
            "The air between the fireball and a surface is transparent; nothing scatters.",
            "Shows where surfaces see the fireball, not burns, ignition or damage.",
        ]
        if !has(.afterburning) {
            assumptions.append(
                "Without afterburning the products cool as cold air would: the fireball is a few metres across "
                    + "and gone within 50 ms. Use afterburning for a thermal study.")
        } else if !has(.hotAir) {
            assumptions.append(
                "The comparisons were run with afterburning and hot air, today's defaults; afterburning alone "
                    + "radiates more (29% of the street's charge against 21%).")
        }
        var resolution: [String] = []
        if inputs.cellSize >= 0.5 {
            resolution.append(
                "On 0.5 m cells the charge's gas is spread over large cells and comes out cooler (0.5 kg starts "
                    + "under 800 K).")
        }
        return result(
            .thermal, .illustrative,
            "Set against two TNT fireballs measured by one group: a 100 kg run, scaled, exceeds the 100 t "
                + "shot's total "
                + (cooling
                    ? "two to three and a half times, the gas cooling as it radiates"
                    : "three to five and a half times")
                + ", and Dial Pack's 500 t pulse comes out far too faint early and two to five times too bright "
                + "after a second.",
            evidence: [
                StandingEvidence(
                    "The 100 t TNT shot's measured radiation, against a 100 kg run scaled by the cube root",
                    cooling
                        ? "Exceeded two to three and a half times, with the gas cooling"
                        : "Exceeded three to five and a half times",
                    "thermal-radiation.md#the-volume-against-the-shape"),
                StandingEvidence(
                    "Dial Pack, 500 t of TNT, at full size on 2 to 8 m cells",
                    "A sixth as bright at the first maximum, dark from 40 to 350 ms, two to five times too "
                        + "bright after 1 s", "validation.md#the-fireballs-radiation-against-dial-pack"),
            ], assumptions: assumptions, resolution: resolution,
            documents: ["thermal-radiation.md#limitations"])
    }

    func surfaceHeating() -> ResultStanding {
        result(
            .surfaceHeating, .illustrative,
            "Checked against conduction's exact solutions within 0.5%, but fed an illustrative irradiance; "
                + "the ignition flags say a surface passed a test's threshold, not that it ignites.",
            evidence: [
                StandingEvidence(
                    "Constant flux on a semi-infinite solid, and a slab against its series", "Within 0.5%",
                    "surface-heating.md#checks")
            ],
            assumptions: [
                "Inert solids of constant properties: nothing melts, chars, spalls or burns, and no moisture.",
                "Heat flows only along each receiver's normal, and only radiation heats the surfaces.",
                "Ignition thresholds are from nuclear thermal pulses of seconds, applied unscaled.",
            ], documents: ["surface-heating.md#limitations", "surface-heating.md#ignition-illustrative"])
    }

    func cloud() -> ResultStanding {
        var assumptions = [
            "A textbook integral model of a turbulent thermal, with coefficients from laboratory thermals, "
                + "started from whatever the gas model leaves."
        ]
        if !has(.afterburning) {
            assumptions.append("The comparison with Church's clouds was made with afterburning on.")
        } else if !has(.hotAir) {
            assumptions.append(
                "The comparison with Church's clouds was made with afterburning and hot air together, today's "
                    + "defaults; afterburning alone was not run against them.")
        }
        return result(
            .cloud, .illustrative,
            "Either way: its top within 4% on average of 22 TNT clouds Church measured, for their first two "
                + "minutes, a geometric spread of 21% shot by shot, not a bound. In one lapse rate it falls behind "
                + "them later; in each shot's measured temperature and wind it follows them to five minutes within "
                + "12% on average, though 27–55% shot by shot, so at night give the cloud a sounding. It needs "
                + "afterburning, whose burning time was fitted to the open blast, and the entrainment coefficient's "
                + "plausible range moves the tops −9% to +13%.",
            evidence: [
                StandingEvidence(
                    "Church's 22 detonations of 54 to 1,270 kg of TNT",
                    "Cloud top within 4% on average, 21% shot "
                        + "by shot, from half a minute to two minutes",
                    "fireball-rise.md#against-churchs-measured-clouds"),
                StandingEvidence(
                    "The same, in Church's measured profiles",
                    "Cloud top 0.88–0.98 of his from three to five minutes, 27–55% shot by shot; his repeated "
                        + "shots themselves spread 36–92%",
                    "fireball-rise.md#in-churchs-own-air-20-october-2026"),
            ], assumptions: assumptions, documents: ["fireball-rise.md#limitations"])
    }
}
