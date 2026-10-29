import BlastCore
import BlastModel
import Foundation
import simd

// `--values`: what a run's digest hashes, as numbers, so that two builds whose digests differ can be
// compared by how far apart their results are, not only whether they are the same to the bit
// (emmettl/bombcad-work#95). One line per body or air, `values <label>: key=value ...`, at full
// precision; with `--values-dump <folder>` each solid body's elements (flag, damage, cracked,
// largest bar strain, compaction) and nodes (displacement) are written there as JSON as well, for
// Scripts/compare-result-values.py to set element by element against another build's.

/// The solid elements' and nodes' values that judge a run: flags, cracking, yield, damage and
/// displacements.
struct SolidValues {
    var flags: [UInt8] = []
    var damage: [Float] = []
    var cracked: [UInt8] = []
    var barPlastic: [Float] = []
    var compaction: [Float] = []
    var displacement: [Float] = []  // x, y, z per node with mass

    init(_ solids: StructureSolver) {
        for k in 0..<solids.ez {
            for j in 0..<solids.ey {
                for i in 0..<solids.ex {
                    let flag = solids.flag(i, j, k)
                    guard flag != .empty else { continue }
                    flags.append(flag.rawValue)
                    damage.append(solids.damage(i, j, k))
                    cracked.append(solids.crackingFactor(i, j, k) != 0 ? 1 : 0)
                    let bars = abs(solids.barPlasticStrain(i, j, k))
                    // A ruptured bar's 1e9 counts as rupture, not as a strain.
                    barPlastic.append(bars.max() >= 1e8 ? -1 : bars.max())
                    compaction.append(solids.compaction(i, j, k))
                }
            }
        }
        solids.mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                displacement += [node.ux, node.uy, node.uz]
            }
        }
    }

    var line: String {
        var values: [(String, String)] = []
        values.append(("elements", "\(flags.count)"))
        values.append(("active", "\(flags.filter { $0 == ElementFlag.active.rawValue }.count)"))
        values.append(("eroded", "\(flags.filter { $0 == ElementFlag.eroded.rawValue }.count)"))
        values.append(("bare", "\(flags.filter { $0 == ElementFlag.bare.rawValue }.count)"))
        values.append(("cracked", "\(cracked.filter { $0 != 0 }.count)"))
        values.append(("yielded", "\(barPlastic.filter { $0 > 0 }.count)"))
        values.append(("ruptured", "\(barPlastic.filter { $0 < 0 }.count)"))
        values.append(("compacted", "\(compaction.filter { $0 > 0 }.count)"))
        values.append(("damageSum", exact(damage.reduce(0) { $0 + Double($1) })))
        values.append(("damageMax", exact(Double(damage.max() ?? 0))))
        var sum = 0.0
        var squares = 0.0
        var largest = 0.0
        for n in stride(from: 0, to: displacement.count, by: 3) {
            let length = Double(
                simd_length(SIMD3(displacement[n], displacement[n + 1], displacement[n + 2])))
            sum += length
            squares += length * length
            largest = max(largest, length)
        }
        let count = Double(max(displacement.count / 3, 1))
        values.append(("dispMean", exact(sum / count)))
        values.append(("dispRMS", exact((squares / count).squareRoot())))
        values.append(("dispMax", exact(largest)))
        return values.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    func write(to url: URL) throws {
        let record: [String: Any] = [
            "flags": flags.map(Int.init), "damage": damage.map(Double.init), "cracked": cracked.map(Int.init),
            "barPlastic": barPlastic.map(Double.init), "compaction": compaction.map(Double.init),
            "displacement": displacement.map(Double.init),
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: url)
    }
}

private func exact(_ value: Double) -> String { String(format: "%.9g", value) }

/// The summary's numbers at full precision.
private func summaryLine(_ summary: StructureSummary) -> String {
    "summaryActive=\(summary.activeElements) summaryEroded=\(summary.erodedElements) "
        + "maxDisp=\(exact(Double(summary.maxDisplacement))) sag=\(exact(Double(summary.selfWeightSag))) "
        + "maxPlastic=\(exact(Double(summary.maxPlasticStrain))) maxDamage=\(exact(Double(summary.maxDamage))) "
        + "beams=\(summary.activeBeams + summary.erodedBeams) erodedBeams=\(summary.erodedBeams) "
        + "maxBeamDisp=\(exact(Double(summary.maxBeamDisplacement))) hingesReleased=\(summary.hingesReleased)"
}

/// `--values` lines (and `--values-dump` files) for structure `solids` alone, under `label`.
func printResultValues(_ label: String, solids: StructureSolver) {
    guard flag("values") else { return }
    let values = SolidValues(solids)
    print("values \(label): \(summaryLine(solids.summary())) \(values.line)")
    dumpValues(values, label: label)
}

/// `--values` lines for a coupled run: the air's peaks and impulses over every cell, and each body.
func printResultValues(_ label: String, solver: BlastSolver) {
    guard flag("values") else { return }
    var peakSum = 0.0
    var peakMax = 0.0
    var impulseSum = 0.0
    let grid = solver.grid
    for k in 0..<grid.nz {
        for j in 0..<grid.ny {
            for i in 0..<grid.nx {
                let peak = Double(solver.peakOverpressure(i, j, k))
                peakSum += peak
                peakMax = max(peakMax, peak)
                impulseSum += Double(solver.impulse(i, j, k))
            }
        }
    }
    print(
        "values \(label) air: peakSum=\(exact(peakSum)) peakMax=\(exact(peakMax)) impulseSum=\(exact(impulseSum))"
    )
    // How each body settled under its own weight first: a different rounding can stop the settling a
    // chunk sooner or later, which leaves the body a different residual motion.
    for (index, settlement) in solver.settlements.enumerated() {
        print(
            "values \(label) settle \(index): settled=\(settlement.settled ? 1 : 0) steps=\(settlement.steps) "
                + "residual=\(exact(Double(settlement.residualSpeed))) sagSettled=\(exact(Double(settlement.displacement)))"
        )
    }
    for (index, body) in solver.bodies.enumerated() {
        let name = "\(label) body \(index)"
        let summary = body.summary().map(summaryLine) ?? ""
        if let solids = body.solids {
            let values = SolidValues(solids)
            print("values \(name): \(summary) \(values.line)")
            dumpValues(values, label: name)
        } else {
            print("values \(name): \(summary)")
        }
        if let shells = body.shells {
            var sum = 0.0
            var largest = 0.0
            var count = 0
            shells.mutateNodes { nodes in
                for node in nodes where node.mass > 0 {
                    let length = Double(simd_length(SIMD3(node.ux, node.uy, node.uz)))
                    sum += length
                    largest = max(largest, length)
                    count += 1
                }
            }
            print(
                "values \(name) shells: nodes=\(count) dispMean=\(exact(sum / Double(max(count, 1)))) "
                    + "dispMax=\(exact(largest))")
        }
    }
}

private func dumpValues(_ values: SolidValues, label: String) {
    guard let folder = option("values-dump") else { return }
    let name = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let url = URL(filePath: folder).appending(path: String(name) + ".json")
    do {
        try FileManager.default.createDirectory(at: URL(filePath: folder), withIntermediateDirectories: true)
        try values.write(to: url)
    } catch {
        print("values: could not write \(url.path): \(error)")
    }
}
