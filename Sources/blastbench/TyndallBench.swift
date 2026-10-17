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
    // `--tight`: the first harness's domain, the charge 1.1 m from the face behind it.
    TyndallCLTTest.tight = flag("tight")
    print(
        "Tyndall's E1 CLT building, 75 ft from the charge; air \(cellSize) m refined by \(refinement), shells \(elementSize) m"
    )
    for test in TyndallCLTTest.tests where numbers?.contains(test.number) ?? true {
        let result = try TyndallCLTTest.run(
            device: device, test: test, cellSize: cellSize, refinement: refinement, elementSize: elementSize,
            duration: duration, progress: flag("progress") ? { print("  " + $0) } : nil)
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
