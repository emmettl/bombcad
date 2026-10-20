import BlastCore
import Foundation
import Metal
import simd

// `blastbench rocking` and `blastbench shaking`.
// Split from main.swift (emmettl/bombcad-work#51).

/// A footing rocked slowly on dry sand against Gajan and Kutter's centrifuge test SSG02_03
/// (`FootingRockingTest`). `--shear` is the sand's shear modulus in MPa, `--bearing` its bearing
/// capacity in kPa; `--history` writes rotation, moment and settlement every 10 ms.
func runRocking() throws {
    let shear = (option("shear").flatMap { Float($0) } ?? 40) * 1e6
    let bearing = (option("bearing").flatMap { Float($0) } ?? 814) * 1e3
    let names = option("packets").map { $0.split(separator: ",").map(String.init) }
    let packets = FootingRockingTest.packets.filter { names?.contains($0.name) ?? true }
    print(
        "Gajan and Kutter's SSG02_03: a 29 Mg shear wall on a 2.8 × 0.65 m surface footing on dry dense sand, "
            + "rocked slowly; sand of \(format(Double(shear) / 1e6, 0)) MPa, bearing \(format(Double(bearing) / 1e3, 0)) kPa"
    )
    let result = try FootingRockingTest.run(
        device: device, shearModulus: shear, bearingCapacity: bearing, packets: packets,
        speed: option("speed").flatMap { Float($0) } ?? 0.2, cyclic: cyclicSandOption(),
        progress: { print("  " + $0) })
    print("")
    print(
        pad("packet", 8) + pad("rotation", 18) + pad("moment forward", 18) + pad("moment back", 18)
            + pad("settlement / L", 18))
    print(pad("", 8) + String(repeating: pad("measured  model", 18), count: 4))
    for (measured, model) in zip(packets, result.packets) {
        func pair(_ a: Float, _ b: Float, _ digits: Int) -> String {
            pad(format(Double(a), digits) + "  " + format(Double(b), digits), 18)
        }
        print(
            pad(measured.name, 8) + pair(measured.peakRotation, model.peakRotation, 4)
                + pair(measured.moment.x, model.moment.x, 3) + pair(measured.moment.y, model.moment.y, 3)
                + pair(measured.settlement, model.settlement, 4))
    }
    print(
        String(
            format: "Largest actuator lag %.1f mm; %.0f s", (result.packets.map(\.lag).max() ?? 0) * 1000,
            result.wallSeconds))
    print("The soil sunk for good under the footing (mm), along it, after each packet:")
    for (packet, profile) in zip(result.packets, result.profiles) {
        print(
            pad(packet.name, 4) + "  "
                + profile.map { String(format: "%5.1f", $0.y * 1000) }.joined(separator: " "))
    }
    if let path = option("history") {
        let lines = ["rotation,moment,settlement"] + result.history.map { "\($0.x),\($0.y),\($0.z)" }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
}

/// The footing's sand: Gajan's cyclic sand (`CyclicSand`), changed by `--elastic-share`,
/// `--memory` and `--heave`; `--elastic` for the bed elastic up to its bearing capacity.
func cyclicSandOption() -> CyclicSand? {
    guard !flag("elastic") else { return nil }
    var sand = CyclicSand()
    if let v = option("elastic-share").flatMap({ Float($0) }) { sand.elasticShare = v }
    if let v = option("memory").flatMap({ Float($0) }) { sand.memory = v }
    if let v = option("heave").flatMap({ Float($0) }) { sand.heave = v }
    return sand
}

func runShaking() throws {
    let shear = (option("shear").flatMap { Float($0) } ?? 80) * 1e6
    let bearing = (option("bearing").flatMap { Float($0) } ?? 814) * 1e3
    let folder = URL(fileURLWithPath: option("samples") ?? "Samples/FoRDy")
    let names = option("tests").map { $0.split(separator: ",").map(String.init) }
    let tests = FootingShakingTest.tests.filter { names?.contains($0.name) ?? true }
    for test in tests {
        let measured = try test.events.map {
            try FootingShakingTest.Series.load(folder.appendingPathComponent("\($0).csv"))
        }
        print(
            "\n\(test.name): \(test.structure.name) on the 2.8 × 0.65 m footing"
                + (test.structure.embedment > 0 ? ", set \(test.structure.embedment) m in" : "")
                + ", on sand of \(format(Double(shear) / 1e6, 0)) MPa, bearing \(format(Double(bearing) / 1e3, 0)) kPa"
        )
        let result = try FootingShakingTest.run(
            device: device, test: test, series: measured, shearModulus: shear, bearingCapacity: bearing,
            damping: option("damping").flatMap { Float($0) } ?? 0.2, cyclic: cyclicSandOption(),
            radiationDamping: !flag("massless"), progress: { print("  " + $0) })
        print(String(format: "  static pressure %.0f kPa; %.0f s", result.pressure / 1e3, result.wallSeconds))
        print(
            pad("event", 15) + pad("peak g", 8) + pad("rotation + / − (mrad)", 26) + pad("moment + / −", 26)
                + pad("settlement / L", 18) + pad("∫M dθ", 18) + pad("travel", 16))
        print(
            pad("", 23) + String(repeating: pad("measured  model", 26), count: 2)
                + String(repeating: pad("measured  model", 18), count: 2) + pad("measured  model", 16))
        for (index, name) in test.events.enumerated() {
            let a = measured[index].summary
            let b = result.events[index].summary
            func mrad(_ v: SIMD2<Float>) -> String { String(format: "%+.1f/%+.1f", v.x * 1000, v.y * 1000) }
            func pair2(_ v: SIMD2<Float>) -> String { String(format: "%.2f/%.2f", v.x, v.y) }
            let peak = measured[index].base.map(abs).max() ?? 0
            print(
                pad(name, 15) + pad(format(Double(peak), 2), 8)
                    + pad(mrad(a.rotation) + "  " + mrad(b.rotation), 26)
                    + pad(pair2(a.moment) + "  " + pair2(b.moment), 26)
                    + pad(String(format: "%.4f  %.4f", a.settlement, b.settlement), 18)
                    + pad(String(format: "%.4f  %.4f", a.energy, b.energy), 18)
                    + pad(String(format: "%.3f  %.3f", a.travel, b.travel), 16))
        }
        print("  the soil sunk for good under the footing (mm), along it, after each event:")
        for (name, profile) in zip(test.events, result.profiles) {
            print(
                pad(name, 15) + "  "
                    + profile.map { String(format: "%5.1f", $0.y * 1000) }.joined(separator: " "))
        }
        print(
            pad("event", 15) + pad("cycles past 1 mrad: rotation (mrad), ∮M dθ a cycle, damping ratio", 70))
        print(pad("", 15) + pad("measured", 34) + pad("model", 34))
        for (index, name) in test.events.enumerated() {
            func cycles(_ s: FootingShakingTest.Summary) -> String {
                pad(
                    String(
                        format: "%.1f  %.4f  %.0f%%", s.cycleAmplitude * 1000, s.cycleEnergy, s.damping * 100),
                    34)
            }
            print(pad(name, 15) + cycles(measured[index].summary) + cycles(result.events[index].summary))
        }
        if let pattern = option("history") {
            for (index, name) in test.events.enumerated() {
                let m = result.events[index]
                var lines = ["time,base_g,rotation,moment,shear,sliding,settlement"]
                for i in m.time.indices {
                    lines.append(
                        "\(m.time[i]),\(m.base[i]),\(m.rotation[i]),\(m.moment[i]),\(m.shear[i]),\(m.sliding[i]),\(m.settlement[i])"
                    )
                }
                try lines.joined(separator: "\n").write(
                    toFile: pattern.replacingOccurrences(of: "%", with: name), atomically: true,
                    encoding: .utf8)
            }
        }
    }
}
