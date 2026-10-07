import BlastCore
import Foundation
import Metal
import simd

// Generates a self-contained visual replay of the tested Swift mechanics, with no browser physics.
// swift run rigidboxdemo [output.html]
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--fractional-gas") {
        let results = try ExperimentalFractionalGasStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/fractional-gas-compression.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "\(r.steps) compression steps: pressure \(r.pressure) Pa, relative error \(r.relativePressureError), energy residual \(r.energyBudgetResidual) J"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--grazing-geometry") {
        let results = try ExperimentalRigidBoxGrazingStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-box-grazing-geometry.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "\(r.contactDuration) s graze: impulse \(r.linearImpulse), expected \(r.expectedLinearImpulse), evaluations \(r.evaluations)"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--motion-geometry") {
        let results = try ExperimentalRigidBoxMotionStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-box-motion-geometry.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "\(r.kind) \(r.integration.rawValue) dx \(r.cellSize) samples \(r.temporalSamples): volume residual \(r.volumeResidual) m³, work balance \(r.workBalanceResidual) J"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--geometry") {
        let results = try ExperimentalRigidBoxGeometryStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-box-geometry.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        let error = results.map { abs($0.solidVolume - 0.512) }.max() ?? 0
        print("\(results.count) geometry cases; maximum box-volume error \(error) m³")
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--diagnostics") {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        let transport = arguments.contains("--transport")
        let results = try ExperimentalRigidBoxDiagnostics.run(
            device: device, remapMode: transport ? .connectedTransport : .redistribution)
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? (transport
                    ? ".build/rigid-box-diagnostics-transport.json" : ".build/rigid-box-diagnostics.json"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            let grid = r.cellSize.map { " dx \($0)" } ?? ""
            let cfl = r.cfl.map { " CFL \($0)" } ?? ""
            let step = r.mechanicalStep.map { " dt \($0)" } ?? ""
            let pressure = r.maximumRelativePressureError.map { ", pressure error \($0)" } ?? ""
            print(
                "\(r.kind)\(grid)\(cfl)\(step): displacement \(simd_length(r.displacement)) m, speed \(simd_length(r.velocity)) m/s\(pressure)"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--convergence") {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        let extended = arguments.contains("--extended")
        let transport = arguments.contains("--transport")
        let suffix = (transport ? "-transport" : "") + (extended ? "-extended" : "")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-box-convergence\(suffix).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalRigidBoxStudy.Result] = []
        let results = try ExperimentalRigidBoxStudy.run(
            device: device, extended: extended,
            remapMode: transport ? .connectedTransport : .redistribution
        ) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                String(
                    format: "Finished dx %.3f CFL %.3f refine %d %@: speed %.5f m/s, %.3f s",
                    r.cellSize, r.cfl, r.refinement, r.held ? "held" : "free",
                    simd_length(r.velocity), r.computeSeconds))
            fflush(stdout)
        }
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                String(
                    format:
                        "dx %.3f CFL %.3f refine %d %@: displacement %.5f m, speed %.5f m/s, impulse x %.5f N s, mass change %.3g, %.3f s",
                    r.cellSize, r.cfl, r.refinement, r.held ? "held" : "free", simd_length(r.displacement),
                    simd_length(r.velocity),
                    r.linearImpulse.x, r.relativeMassChange, r.computeSeconds))
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    let refined = arguments.contains("--refined")
    let coupled = arguments.contains("--blast") || refined
    let destination = URL(
        fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
            ?? (refined
                ? ".build/rigid-box-refined-demo.html"
                : coupled ? ".build/rigid-box-blast-demo.html" : ".build/rigid-box-demo.html"))
    let recordings: [RigidObjectDemo.Recording]
    if coupled {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        recordings = try RigidObjectDemo.coupledRecordings(device: device, refinement: refined ? 2 : 1)
    } else {
        recordings = try RigidObjectDemo.recordings()
    }
    let data = try JSONEncoder().encode(recordings)
    let source = Bundle.module.url(forResource: "viewer", withExtension: "html")!
    let template = try String(contentsOf: source, encoding: .utf8)
    var html = template.replacingOccurrences(
        of: "__RECORDINGS__", with: String(decoding: data, as: UTF8.self))
    if coupled {
        html = html.replacingOccurrences(
            of: "Recorded from the Swift reference solver; no blast loading.",
            with: "Experimental blast coupling; compare a held and free box.")
    }
    if coupled {
        html = html.replacingOccurrences(
            of: "<option value=\"1\" selected>Real time</option>",
            with: "<option value=\"0.01\" selected>100× slow</option><option value=\"1\">Real time</option>")
        html = html.replacingOccurrences(
            of: "All cases: mass 2 kg, static friction 0.6, sliding friction 0.5; impacts have no rebound.",
            with:
                "Experimental 0.8 m cube, mass 2 kg; static friction 0.6, sliding friction 0.5. Held mode fixes the pose; free mode includes gravity and ground contact."
        )
    }
    try html.write(to: destination, atomically: true, encoding: .utf8)
    print("Wrote \(destination.path) (\(recordings.count) cases)")
    if coupled { for recording in recordings { print("\(recording.name): \(recording.description)") } }
} catch {
    FileHandle.standardError.write(Data("rigidboxdemo: \(error.localizedDescription)\n".utf8))
    exit(1)
}
