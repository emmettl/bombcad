import BlastCore
import Foundation
import Metal
import simd

// blastbench contact-profile [--cases solid,shell,debris,terraced] [--steps 2000]
//
// Where contact's time goes: each case run with contact off, with contact filling its table each
// substep but finding no forces, and in full, so that the table's rebuilds and the pairs' tests
// separate. For bodies in contact with each other, the same with the pairs between bodies left
// out. Wall-clock seconds, the GPU's batches waited on.

/// A hash of every node's displacement and velocity, to show two builds stepped alike.
private func nodeHash(_ values: [Float]) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for value in values { hash = (hash ^ UInt64(value.bitPattern)) &* 0x100_0000_01b3 }
    return String(hash, radix: 16)
}

func runContactProfile() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
        throw BlastError.missingShader("no Metal device")
    }
    let cases = (option("cases") ?? "solid,shell,debris,terraced").split(separator: ",").map(String.init)
    let steps = option("steps").flatMap(Int.init) ?? 2000
    func seconds(_ body: () -> Void) -> Double {
        let start = Date()
        body()
        return Date().timeIntervalSince(start)
    }
    func report(_ name: String, _ off: Double, _ table: Double, _ full: Double, _ detail: String) {
        print(
            String(
                format:
                    "%@: off %.2f s, table %.2f s, full %.2f s; contact %.0f%% of the time (table %.0f%%, pairs %.0f%%)%@",
                name, off, table, full, 100 * (full - off) / full, 100 * (table - off) / full,
                100 * (full - table) / full, detail))
        fflush(stdout)
    }
    let building = ScenarioPreset.concreteBox.scenario.structure!
    for name in cases {
        switch name {
        case "solid", "debris":
            var times: [Double] = []
            var detail = ""
            for mode in 0..<3 {
                let solver = try StructureSolver(device: device, model: building)
                solver.contactMode = mode == 0 ? .off : .always
                solver.contactTableOnly = mode == 1
                if name == "debris" {
                    // The front wall (x below 16.5 m) thrown outward at 40 m/s: it breaks up and
                    // its pieces fly and pile against each other.
                    solver.mutateNodes { nodes in
                        for k in 0...solver.ez {
                            for j in 0...solver.ey {
                                for i in 0...solver.ex {
                                    guard let n = solver.storedNode(i, j, k),
                                        solver.referencePosition(i, j, k).x < 16.5,
                                        solver.referencePosition(i, j, k).z > 0.3
                                    else { continue }
                                    nodes[n].velocity = SIMD3(-40, 0, 0)
                                }
                            }
                        }
                    }
                }
                solver.advance(steps: 50)
                times.append(seconds { solver.advance(steps: steps) })
                if mode == 2 {
                    var values: [Float] = []
                    solver.mutateNodes { nodes in
                        for node in nodes {
                            values += [node.ux, node.uy, node.uz, node.vx, node.vy, node.vz]
                        }
                    }
                    if let dump = option("dump") {
                        try values.withUnsafeBufferPointer { Data(buffer: $0) }
                            .write(to: URL(fileURLWithPath: "\(dump)-\(name).bin"))
                    }
                    detail =
                        ", \(solver.elementCount) elements, \(solver.summary().erodedElements) broken, nodes \(nodeHash(values))"
                }
            }
            report(
                name == "solid" ? "Solid building, intact" : "Solid building, its front wall breaking up",
                times[0], times[1], times[2], detail)
        case "shell":
            var model = building
            var shellHash = ""
            model.elementKind = .shell
            model.elementSize = 0.25
            var times: [Double] = []
            for mode in 0..<3 {
                let solver = try ShellSolver(device: device, model: model)
                solver.contactMode = mode == 0 ? .off : .always
                solver.contactTableOnly = mode == 1
                solver.advance(steps: 50)
                times.append(seconds { solver.advance(steps: steps) })
                if mode == 2 {
                    var values: [Float] = []
                    solver.mutateNodes { nodes in
                        for node in nodes {
                            values += [node.ux, node.uy, node.uz, node.vx, node.vy, node.vz]
                        }
                    }
                    shellHash = nodeHash(values)
                }
            }
            report("Shell building, intact", times[0], times[1], times[2], ", nodes \(shellHash)")
        case "terraced":
            // Two buildings 0.1 m apart with 20 kg in the first (`blastbench buildings --terraced`),
            // in contact from the start: their own contact on in full, and the pairs between them.
            var times: [Double] = []
            var terracedHash = ""
            for mode in 0..<3 {
                var configuration = SolverConfiguration()
                configuration.airSleepThreshold = 0
                configuration.airSleepCrossings = 0
                let solver = try BlastSolver(
                    device: device, scenario: terracedLayout(), cellSize: 0.25, configuration: configuration)
                for body in solver.bodies {
                    body.solids?.contactTableOnly = mode == 0
                    body.shells?.contactTableOnly = mode == 0
                }
                solver.bodyContactPairsSkipped = mode < 2
                solver.advance(steps: 20)
                times.append(seconds { solver.advance(until: 0.03) })
                if mode == 2 {
                    var values: [Float] = []
                    for body in solver.bodies {
                        body.shells?.mutateNodes { nodes in
                            for node in nodes {
                                values += [node.ux, node.uy, node.uz, node.vx, node.vy, node.vz]
                            }
                        }
                    }
                    terracedHash = nodeHash(values)
                }
            }
            print(
                String(
                    format:
                        "Terraced buildings in contact, 0.03 s: own tables only %.2f s, own contact %.2f s, with the pairs between them %.2f s; pairs between bodies %.0f%%, own contact forces %.0f%%",
                    times[0], times[1], times[2], 100 * (times[2] - times[1]) / times[2],
                    100 * (times[1] - times[0]) / times[2]) + ", nodes \(terracedHash)")
            fflush(stdout)
        default:
            print("Unknown case \(name)")
        }
    }
}
