import BlastCore
import Foundation
import Metal
import simd

// `blastbench anchorage`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A freestanding wall under a blast on each kind of base connection (`AnchorageStudy`).
func runAnchorage() throws {
    let mass = option("mass").flatMap { Float($0) } ?? 50
    let standoffs = (option("standoff") ?? "6,10,15,25").split(separator: ",").compactMap { Float($0) }
    let duration = option("time").flatMap { Float($0) } ?? 0.5
    // `--shells` meshes the wall with shells (of 0.125 m unless `--h` says otherwise).
    let shells = flag("shells")
    let h = option("h").flatMap { Float($0) } ?? (shells ? 0.125 : 0.0625)
    print(
        "Freestanding wall\(shells ? " of shells" : ""), \(format(Double(AnchorageStudy.height), 0)) m high and "
            + "\(format(Double(AnchorageStudy.thickness) * 1000, 0)) mm thick, a surface burst of "
            + "\(format(Double(mass), 0)) kg; "
            + (flag("air") ? "12 m long, loaded by the air" : "Kingery–Bulmash reflected pulse, no air")
            + "; \(format(Double(duration), 1)) s"
    )
    if flag("panel") {
        print(
            "As a panel 3 m long resting on the ground between two columns, its vertical edges tied to them\n"
                + "by each connection in turn; sway at the top's middle; ties, slip and moment are of all its joints."
        )
    }
    if !flag("air") {
        print(
            "The pulse loads the face alone. A freestanding wall's back face is loaded too, as the wave wraps\n"
                + "over and round it, and it sways about a third as far at 10 m: see --air.")
    }
    // The footing's soil: `--massless` without its mass and radiation damping; `--layer d` a layer
    // d metres deep over rock (or `--beneath sand`, a looser sand, or `--beneath clay`, a soft
    // clay, as a half-space); `--elastic` elastic up to its bearing capacity, not settling under
    // cycles.
    var soil = Soil()
    soil.radiationDamping = !flag("massless")
    soil.cyclic = cyclicSandOption()
    soil.layerDepth = option("layer").flatMap { Float($0) }
    switch option("beneath") {
    case "sand": soil.beneath = SoilMaterial(shearModulus: 20e6, poissonRatio: 0.3, density: 1800)
    case "clay": soil.beneath = SoilMaterial(shearModulus: 10e6, poissonRatio: 0.45, density: 1700)
    default: soil.beneath = nil
    }
    if soil != Soil() {
        print(
            "Footing on medium dense sand" + (soil.radiationDamping ? "" : " without its mass")
                + (soil.cyclic == nil ? ", elastic" : "")
                + (soil.layerDepth.map {
                    " as a layer \(format(Double($0), 1)) m deep over " + (option("beneath") ?? "rock")
                } ?? ""))
    }
    for standoff in standoffs {
        print("")
        var header = false
        // `--bases clamped,dowelled` picks the bases; `--air` loads a 12 m wall by the air solver
        // instead of the pulse, on cells of `--cell` metres (0.25 by default), the air reaching
        // `--margin` metres (12) beyond the wall and charge and `--height` metres (18) up.
        let bases =
            option("bases").map {
                $0.split(separator: ",").compactMap { BaseConnection(rawValue: String($0)) }
            }
            ?? BaseConnection.allCases
        for base in bases {
            let r =
                flag("air")
                ? try AnchorageStudy.runCoupled(
                    device: device, base: base, mass: mass, standoff: standoff, duration: Double(duration),
                    cellSize: option("cell").flatMap { Float($0) } ?? 0.25, elementSize: h,
                    margin: option("margin").flatMap { Float($0) } ?? 12,
                    domainHeight: option("height").flatMap { Float($0) } ?? 18, soil: soil,
                    air: {
                        // The mapped start since its rerun on 19 October 2026; `--balloon-start` for the balloon.
                        var air =
                            (flag("balloon-start")
                                ? SolverConfiguration.recommended.balloonStart
                                : SolverConfiguration.recommended)
                        applyChosenAir(&air)
                        return air
                    }(),
                    progress: flag("progress") ? { print("    " + $0) } : nil)
                : flag("panel")
                    ? try AnchorageStudy.run(
                        device: device, base: .resting, mass: mass, standoff: standoff, duration: duration,
                        elementSize: h, shells: shells, edges: base)
                    : try AnchorageStudy.run(
                        device: device, base: base, mass: mass, standoff: standoff, duration: duration,
                        elementSize: h,
                        shells: shells, soil: soil,
                        embedment: option("embed").flatMap { Float($0) }.map { Embedment(depth: $0) })
            if !header {
                print(
                    "\(format(Double(standoff), 0)) m: \(format(Double(r.pressure) / 1000, 0)) kPa reflected for "
                        + "\(format(Double(r.duration) * 1000, 1)) ms, "
                        + "\(format(Double(r.pressure * r.duration) / 2, 0)) Pa s")
                print(
                    pad(flag("panel") ? "edges" : "base", 22) + pad("peak sway", 11) + pad("final", 10)
                        + pad("uplift", 10)
                        + pad("slip", 10) + pad("tie failed", 12) + pad("base M", 12) + pad("eroded", 8)
                        + pad("run time", 9))
                header = true
            }
            let anchored = base != .clamped
            // A body resting on the ground has no tie to fail.
            let failed = anchored && base != .resting ? "\(format(Double(r.separated) * 100, 0))%" : "-"
            let sway = pad("\(format(Double(r.peakSway) * 1000, 1)) mm", 11)
            let final = pad("\(format(Double(r.finalSway) * 1000, 1)) mm", 10)
            let uplift = anchored ? "\(format(Double(r.peakUplift) * 1000, 2)) mm" : "-"
            let slip = anchored ? "\(format(Double(r.maxSlip) * 1000, 2)) mm" : "-"
            print(
                pad(base.title.lowercased(), 22) + sway + final + pad(uplift, 10) + pad(slip, 10)
                    + pad(failed, 12)
                    + pad(anchored ? "\(format(Double(r.peakBaseMoment) / 1000, 0)) kN m/m" : "-", 12)
                    + pad("\(r.summary.erodedElements)", 8) + pad("\(format(r.wallSeconds)) s", 9))
            if base == .footing {
                print(
                    pad("", 22)
                        + "footing: turned \(format(Double(r.footingRotation) * 1000, 2)) mrad, heel lifted "
                        + "\(format(Double(r.footingUplift) * 1000, 2)) mm; at the end slid "
                        + "\(format(Double(r.footingSlide) * 1000, 2)) mm, settled \(format(Double(r.footingSettlement) * 1000, 2)) mm"
                )
            }
            if flag("air") {
                print(
                    pad("", 22)
                        + "face \(format(Double(r.pressure * r.duration) / 2, 0)) Pa s (positive phase); "
                        + "over 50 ms, back \(format(Double(r.backImpulse), 0)) Pa s, net \(format(Double(r.netImpulse), 0)) Pa s; "
                        + "back towards the charge \(format(Double(r.peakBackSway) * 1000, 1)) mm")
            }
        }
    }
}
