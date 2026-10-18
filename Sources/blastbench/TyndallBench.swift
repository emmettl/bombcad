import BlastCore
import Foundation
import Metal
import simd

/// `blastbench tyndall [--tests 1,2,3] [--dx 0.25] [--refine 2] [--h 0.15] [--time 0.25]`: the
/// Nordic E1 CLT building of the Tyndall tests (`TyndallCLTTest`): the front's reflected load
/// and its centre's displacements at the first and second storeys, measured / model.
func runTyndall(device: MTLDevice) throws {
    let numbers = option("tests").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    let cellSize = option("dx").flatMap { Float($0) } ?? 0.25
    let refinement = option("refine").flatMap { Int($0) } ?? 2
    let elementSize = option("h").flatMap { Float($0) } ?? 0.15
    let duration = option("time").flatMap { Double($0) } ?? 0.25
    print(
        "Tyndall's E1 CLT building, 75 ft from the charge; air \(cellSize) m refined by \(refinement), shells \(elementSize) m"
    )
    for test in TyndallCLTTest.tests where numbers?.contains(test.number) ?? true {
        // `--pad back,side,top` moves the domain's faces out by so many metres; `--history <csv>`
        // writes the front's displacements and the gauges every batch; `--no-sleep` keeps the air
        // awake; `--copy-faces` copies the open faces instead of the far field.
        let pad =
            option("pad").map { text -> SIMD3<Float> in
                let v = text.split(separator: ",").compactMap { Float($0) }
                return SIMD3(v[0], v[1], v[2])
            } ?? .zero
        var rows =
            "time_s,first_mm,second_mm,front_kPa,front2_kPa,edge_kPa,roof_kPa,back_kPa,side_kPa,free_kPa\n"
        let result = try TyndallCLTTest.run(
            device: device, test: test, cellSize: cellSize, refinement: refinement, elementSize: elementSize,
            duration: duration, pad: pad,
            history: { t, a, b, p in
                rows +=
                    "\(t),\(a * 1000),\(b * 1000)," + p.map { "\($0 / 1000)" }.joined(separator: ",") + "\n"
            },
            configure: { c in
                if flag("no-sleep") {
                    c.airSleepThreshold = 0
                    c.airSleepCrossings = 0
                }
                if flag("copy-faces") { c.openFaces = .copy }
            },
            progress: flag("progress") ? { print("  " + $0) } : nil)
        if let path = option("history") { try rows.write(toFile: path, atomically: true, encoding: .utf8) }
        func mm(_ v: SIMD2<Float>) -> String {
            "\(format(Double(v.x) * 1000, 0)) / \(format(Double(v.y) * 1000, 0))"
        }
        print("Test \(test.number), \(format(Double(test.charge), 1)) kg (\(test.damage)):")
        print(
            "  reflected \(format(Double(test.reflected) / 1e3, 1)) / \(format(Double(result.reflected) / 1e3, 1)) kPa, "
                + "\(format(Double(test.impulse), 0)) / \(format(Double(result.impulse), 0)) kPa ms")
        print(
            "  incident \(format(Double(test.incident) / 1e3, 1)) / \(format(Double(result.incident) / 1e3, 1)) kPa, "
                + "\(format(Double(test.incidentImpulse), 0)) / \(format(Double(result.incidentImpulse), 0)) kPa ms"
        )
        print(
            "  first storey, in / rebound (mm): \(mm(test.firstFloor)) measured, \(mm(result.firstFloor)) model"
        )
        print("  second storey: \(mm(test.secondFloor)) measured, \(mm(result.secondFloor)) model")
        print("  damage up to \(format(Double(result.maxDamage), 2)); \(result.removed) elements removed")
        fflush(stdout)
    }
}
