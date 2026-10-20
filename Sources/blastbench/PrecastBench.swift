import BlastCore
import Foundation
import Metal
import simd

// `blastbench precast` and `blastbench seat`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A precast beam's seat cycled along its corbel against Batalha et al.'s tests (`PrecastSeatTest`).
func runPrecast() throws {
    let tests = (option("tests") ?? "i0_50,i0_100,i0_150").split(separator: ",").map { "spc_" + $0 }
    let friction = option("friction").flatMap { Float($0) } ?? 0.7
    let limit = option("reversals").flatMap { Int($0) }
    let folder = URL(fileURLWithPath: option("samples") ?? "Samples/PrecastSeat")
    print(
        "Precast seat cycled along its corbel, "
            + (flag("neoprene")
                ? "on neoprene (friction falling with pressure)"
                : "resting with friction \(format(Double(friction), 2))")
            + (limit.map { ", first \($0) reversals" } ?? ""))
    print(
        pad("test", 13) + pad("load", 8) + pad("sliding, model", 16) + pad("test", 10)
            + pad("energy, model", 15)
            + pad("test", 10) + pad("lag", 9) + pad("run time", 9))
    for test in tests {
        // `--neoprene`: friction falling with pressure, fitted to the pads' tests (`Anchorage.neoprenePad`).
        var law = flag("neoprene") ? Anchorage.neoprenePad : Anchorage.resting(friction: friction)
        // `--pad 1e8` gives the joint a neoprene pad's shear stiffness, in Pa/m.
        law.shearStiffness = option("pad").flatMap { Float($0) }
        // `--normal 1e9` the joint's stiffness across, in Pa/m.
        law.normalStiffness = option("normal").flatMap { Float($0) }
        let r = try PrecastSeatTest.run(
            device: device, test: test, samples: folder, law: law, reversals: limit)
        if let out = option("history") {
            try r.history.map { "\($0.x),\($0.y)" }.joined(separator: "\n").write(
                toFile: out.replacingOccurrences(of: "%", with: test), atomically: true, encoding: .utf8)
        }
        print(
            pad(test, 13) + pad("\(format(Double(PrecastSeatTest.axialLoad(of: test)) / 1000, 0)) kN", 8)
                + pad("\(format(Double(r.sliding) / 1000, 1)) kN", 16)
                + pad("\(format(Double(r.measuredSliding) / 1000, 1)) kN", 10)
                + pad("\(format(Double(r.energy) / 1000, 1)) kJ", 15)
                + pad("\(format(Double(r.measuredEnergy) / 1000, 1)) kJ", 10)
                + pad("\(format(Double(r.lag) * 1000, 2)) mm", 9) + pad("\(format(r.wallSeconds)) s", 9))
    }
}

/// A precast beam seated on corbels, one of its columns struck away from the span
/// (`DroppedSpanStudy`).
func runSeat() throws {
    let speeds = (option("speeds") ?? "4,8,12").split(separator: ",").compactMap { Float($0) }
    let seats = (option("seats") ?? "0.1,0.2").split(separator: ",").compactMap { Float($0) }
    let duration = option("time").flatMap { Float($0) } ?? 1.5
    let h = option("h").flatMap { Float($0) } ?? 0.1
    // `--dowels` ties the beam to its corbels by starter bars through the pad instead of resting.
    let law: Anchorage = flag("dowels") ? .dowelled(ratio: 0.004) : .resting(friction: 0.5)
    print(
        "Precast beam 0.5 m deep on corbels of two columns 6 m apart, "
            + (flag("dowels") ? "dowelled to them" : "resting with friction 0.5")
            + "; the right column struck away from the span; \(format(Double(duration), 1)) s")
    print(
        pad("seat", 8) + pad("speed", 9) + pad("column sway", 13) + pad("slide", 10) + pad("off seat", 10)
            + pad("end fell", 10) + pad("eroded", 8) + pad("run time", 9))
    for seat in seats {
        for speed in speeds {
            let r = try DroppedSpanStudy.run(
                device: device, seat: seat, speed: speed, law: law, duration: duration, elementSize: h)
            print(
                pad("\(format(Double(seat) * 1000, 0)) mm", 8) + pad("\(format(Double(speed), 1)) m/s", 9)
                    + pad("\(format(Double(r.peakSway) * 1000, 0)) mm", 13)
                    + pad("\(format(Double(r.peakSlide) * 1000, 0)) mm", 10)
                    + pad("\(format(Double(r.unseated) * 100, 0))%", 10)
                    + pad("\(format(Double(r.drop) * 1000, 0)) mm", 10)
                    + pad("\(r.summary.erodedElements)", 8)
                    + pad("\(format(r.wallSeconds)) s", 9))
        }
    }
}
