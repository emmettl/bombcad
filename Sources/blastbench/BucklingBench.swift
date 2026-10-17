import BlastCore
import Foundation
import Metal

// Whether the beams buckle (see BucklingStudy.swift):
//
//   blastbench buckling [--length 3] [--side 0.05] [--dx 0.05,0.025] [--yield 355] [--rate 0.02]
//                       [--shortening 0.006] [--nudge 0.002] [--damping 20] [--clamped]
//   blastbench buckling --impact 25,50,100 [--side 0.02] [--dx 0.02] [--growth 5]

func runBuckling(device: MTLDevice) throws {
    if let speeds = option("impact") {
        // Dynamic buckling: the preferred wavelength behind the compression front.
        for speed in speeds.split(separator: ",").compactMap({ Float($0) }) {
            let r = try BucklingStudy.impact(
                device: device, side: option("side").flatMap { Float($0) } ?? 0.02,
                elementSize: option("dx").flatMap { Float($0) } ?? 0.02, speed: speed,
                growth: option("growth").flatMap { Float($0) } ?? 5)
            print(
                String(
                    format:
                        "struck at %.1f m/s: force %.0f kN, wavelength %.3f m (Lindberg %.3f, %.2f), strut %.0f m",
                    speed, r.force / 1000, r.measured, r.predicted, r.measured / r.predicted, r.length))
        }
        return
    }
    let sizes = (option("dx") ?? "0.05").split(separator: ",").compactMap { Float($0) }
    let length = option("length").flatMap { Float($0) } ?? 3
    let side = option("side").flatMap { Float($0) } ?? 0.05
    let yieldStress = option("yield").flatMap { Float($0) }.map { $0 * 1e6 }
    for h in sizes {
        let r = try BucklingStudy.run(
            device: device, length: length, side: side, elementSize: h,
            rate: option("rate").flatMap { Float($0) } ?? 0.02,
            shortening: option("shortening").flatMap { Float($0) } ?? 0.006, yieldStress: yieldStress,
            nudge: option("nudge").flatMap { Float($0) } ?? 0.002,
            damping: option("damping").flatMap { Float($0) } ?? 20, clamped: flag("clamped"))
        print(
            String(
                format:
                    "L %.2f m, side %.3f m, h %.4f m (%d beams): peak %.1f kN at %.2f mm, Euler %.1f kN (%.2f), "
                    + "at the end %.1f kN (%.2f), squash %.1f kN, out %.1f mm",
                r.length, r.side, r.elementSize, r.beams, r.peakForce / 1000, r.shorteningAtPeak * 1000,
                r.euler / 1000, r.peakForce / r.euler, r.finalForce / 1000, r.finalForce / r.euler,
                r.squash / 1000,
                r.lateral * 1000))
        if flag("history") {
            for point in r.history where Int(point.x * 1e5) % 25 == 0 {
                print(String(format: "  %.3f mm  %.2f kN", point.x * 1000, point.y / 1000))
            }
        }
    }
}
