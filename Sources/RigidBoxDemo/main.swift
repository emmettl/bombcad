import BlastCore
import Foundation
import Metal
import simd

// Generates a self-contained visual replay of the tested Swift mechanics, with no browser physics.
// swift run rigidboxdemo [output.html]
do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.contains("--initial-wall-traces") {
        let decompose = arguments.contains("--decompose")
        let sweep = arguments.contains("--stencil-sweep")
        let volumeFits = arguments.contains("--volume-fit") || sweep
        let suffix =
            sweep ? "-stencil-sweep" : (volumeFits ? "-volume-fit" : (decompose ? "-decomposition" : ""))
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/initial-wall-traces\(suffix).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalInitialWallTraceStudy.Result] = []
        for rings in (sweep ? [1, 2, 3] : [2]) {
            _ = try ExperimentalInitialWallTraceStudy.run(
                rotations: sweep ? [0, 0.1, 0.23, 0.4] : [0, 0.23], decompose: decompose,
                volumeFits: volumeFits, stencilRings: rings
            ) { r in
                completed.append(r)
                try encoder.encode(completed).write(to: output, options: .atomic)
                print(
                    "dx \(r.cellSize), rotation \(r.rotation), stencil rings \(rings): supplied force/torque error \(r.supplied.relativeForceError)/\(r.supplied.relativeTorqueError), limited \(r.limited.relativeForceError)/\(r.limited.relativeTorqueError)"
                )
                fflush(stdout)
            }
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--moving-loads") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/moving-loads.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingLoadStudy.Result] = []
        _ = try ExperimentalMovingLoadStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            let f = r.frames.last!
            print(
                "dx \(r.cellSize), rotation \(r.rotation), CFL \(r.cfl): \(f.steps) steps, impulse \(f.bodyImpulse), torque impulse \(f.bodyAngularImpulse), \(r.computeSeconds) s"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--moving-pressure") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/moving-pressure.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingPressureStudy.Result] = []
        _ = try ExperimentalMovingPressureStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellSize), rotation \(r.rotation), slices \(r.timeSlices): centroid impulse/torque error \(r.centroid.relativeImpulseError)/\(r.centroid.relativeAngularImpulseError), sampled \(r.sampled.relativeImpulseError)/\(r.sampled.relativeAngularImpulseError)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--moving-entropy") {
        let limited = arguments.contains("--limited")
        let secondOrder = arguments.contains("--heun")
        let surfaceQuadrature = arguments.contains("--surface-quadrature")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/moving-entropy\(limited ? "-limited" : "")\(secondOrder ? "-heun" : "")\(surfaceQuadrature ? "-surface-quadrature" : "").json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingTrajectoryStudy.Result] = []
        _ = try ExperimentalMovingEntropyStudy.run(
            limited: limited, secondOrder: secondOrder, surfaceQuadrature: surfaceQuadrature
        ) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            let f = r.frames.last!
            print(
                "dx \(r.cellSize), rotation \(r.rotation), CFL \(r.cfl): \(f.steps) steps, density L1 \(f.transport!.relativeDensityL1), pressure error \(f.maximumRelativePressureError)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--moving-trajectory") {
        let window = arguments.contains("--ambient-window")
        let halving = arguments.contains("--halving")
        let limited = arguments.contains("--limited")
        let secondOrder = arguments.contains("--heun")
        let surfaceQuadrature = arguments.contains("--surface-quadrature")
        let stem =
            "moving-trajectory" + (window ? "-ambient-window" : "") + (halving ? "-halving" : "")
            + (limited ? "-limited" : "") + (secondOrder ? "-heun" : "")
            + (surfaceQuadrature ? "-surface-quadrature" : "")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") }) ?? ".build/\(stem).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingTrajectoryStudy.Result] = []
        _ = try ExperimentalMovingTrajectoryStudy.run(
            cfls: halving ? [0.2, 0.1] : [0.2],
            duration: window ? 0.000064 : 0.0008, velocityScale: window ? 1 : 100, nearCrossing: window,
            limited: limited, secondOrder: secondOrder, surfaceQuadrature: surfaceQuadrature
        ) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            let f = r.frames.last!
            print(
                "dx \(r.cellSize), rotation \(r.rotation), CFL \(r.cfl): \(f.steps) steps, dry→wet \(f.dryToWetCells), wet→dry \(f.wetToDryCells), pressure error \(f.maximumRelativePressureError), \(r.computeSeconds) s"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--moving-groups") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/moving-groups.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingGroupsStudy.Result] = []
        _ = try ExperimentalMovingGroupsStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellSize), rotation \(r.rotation), \(r.transition): dry→wet \(r.dryToWetCells), wet→dry \(r.wetToDryCells), pressure error \(r.maximumRelativePressureError)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--translating-box-geometry") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/translating-box-geometry.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalTranslatingBoxGeometryStudy.Result] = []
        _ = try ExperimentalTranslatingBoxGeometryStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellSize), rotation \(r.rotation): dry→wet \(r.dryToWetCells), wet→dry \(r.wetToDryCells), volume error \(r.maximumRelativeVolumeChangeResidual), uniform energy error \(r.maximumRelativeUniformEnergyResidual)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--moving-reflection") {
        let constant = arguments.contains("--constant")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/moving-reflection\(constant ? "-constant" : "").json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingReflectionStudy.Result] = []
        _ = try ExperimentalMovingReflectionStudy.run(limited: !constant) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellLength), Mach \(r.mach), piston \(r.pistonVelocity), CFL \(r.cfl): history L1 \(r.relativePressureHistoryL1), impulse error \(r.frames.last!.impulseError), work error \(r.frames.last!.workError)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--wall-reflection") {
        let limited = arguments.contains("--limited")
        let refined = arguments.contains("--refined")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/wall-reflection\(limited ? "-limited" : "")\(refined ? "-refined" : "").json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalWallReflectionStudy.Result] = []
        _ = try ExperimentalWallReflectionStudy.run(
            cellLengths: refined ? [0.00625, 0.003125] : [0.1, 0.05, 0.025, 0.0125],
            cfls: refined ? [0.2] : [0.2, 0.1], limited: limited
        ) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellLength), Mach \(r.mach), CFL \(r.cfl): history L1 \(r.relativePressureHistoryL1), impulse error \(r.frames.last!.impulseError)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--connected-loads") {
        let convergence = arguments.contains("--convergence")
        let volumeAverage = arguments.contains("--volume-average")
        let limited = arguments.contains("--limited")
        let surfaceQuadrature = arguments.contains("--surface-quadrature")
        let stem =
            "connected-loads" + (convergence ? "-convergence" : "") + (volumeAverage ? "-volume-average" : "")
            + (limited ? "-limited" : "") + (surfaceQuadrature ? "-surface-quadrature" : "")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/\(stem).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalConnectedLoadStudy.Result] = []
        _ = try ExperimentalConnectedLoadStudy.run(
            cellSizes: convergence ? [0.2, 0.1, 0.05] : [0.2, 0.1],
            cfls: convergence ? [0.2, 0.1] : [0.2], targetPulseEnergy: convergence ? 6400 : nil,
            volumeAverage: volumeAverage, limited: limited, surfaceQuadrature: surfaceQuadrature
        ) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellSize), rotation \(r.rotation), CFL \(r.cfl): \(r.steps) steps, body impulse \(r.bodyImpulse), momentum residual \(r.momentumBudgetResidual)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--connected-gas") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") }) ?? ".build/connected-gas.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalConnectedGasStudy.Result] = []
        _ = try ExperimentalConnectedGasStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellSize), rotation \(r.rotation): \(r.wetCells) wet cells → \(r.groups) groups, timestep gain \(r.groupedStep / r.initialStep)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--piston-wave") {
        let limited = arguments.contains("--limited")
        let halving = arguments.contains("--halving")
        let strong = arguments.contains("--strong")
        let mergeStudy = arguments.contains("--merge-study")
        let suffix =
            (limited ? "-limited" : "") + (halving && limited ? "-halving" : "")
            + (strong ? "-strong" : "") + (mergeStudy ? "-merges" : "")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/piston-wave\(suffix).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalPistonWaveStudy.Result] = []
        _ = try ExperimentalPistonWaveStudy.run(
            limited: limited, halving: halving, strong: strong, mergeStudy: mergeStudy
        ) { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellLength), CFL \(r.cfl), merge \(r.mergeFraction), piston \(r.pistonVelocity): final pressure L1 \(r.frames.last!.relativePressureL1)"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--piston-transients") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/piston-transients.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalPistonTransientStudy.Result] = []
        _ = try ExperimentalPistonTransientStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellLength), CFL \(r.cfl), piston \(r.pistonVelocity): \(r.frames.count) frames, \(r.frames.last!.steps) steps"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--piston-sensitivity") {
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/piston-sensitivity.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalPistonSensitivityStudy.Result] = []
        _ = try ExperimentalPistonSensitivityStudy.run { r in
            completed.append(r)
            try encoder.encode(completed).write(to: output, options: .atomic)
            print(
                "dx \(r.cellLength), CFL \(r.cfl), merge \(r.mergeFraction), piston \(r.pistonVelocity): \(r.steps) steps, mean pressure \(r.meanPressure) Pa"
            )
            fflush(stdout)
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--piston-crossings") {
        let results = try ExperimentalPistonCrossingStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") }) ?? ".build/piston-crossings.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "dx \(r.cellLength), piston \(r.pistonVelocity): \(r.gridCrossings) crossings, \(r.remeshes) repartitions, \(r.steps) steps, energy residual \(r.energyBudgetResidual) J"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--piston") {
        let results = try ExperimentalPistonStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/piston.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "Piston \(r.pistonVelocity) m/s: \(r.steps) steps, energy residual \(r.energyBudgetResidual) J, pressure error \(r.relativeQuasiStaticPressureError)"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--wall-pressure") {
        let results = try ExperimentalWallPressureStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/wall-pressure.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print("Normal Mach \(r.normalMach): wall pressure ratio \(r.pressureRatio), vacuum \(r.vacuum)")
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--fractional-flux") || arguments.contains("--fractional-walls") {
        let reflectingWalls = arguments.contains("--fractional-walls")
        let results = try ExperimentalFractionalFluxStudy.run(reflectingWalls: reflectingWalls)
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? (reflectingWalls ? ".build/fractional-walls.json" : ".build/fractional-flux.json"))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "Smallest volume \(r.smallestVolume) m³: \(r.steps) steps, energy change \(r.relativeEnergyChange), peak speed \(r.maximumSpeed) m/s"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--fractional-substeps") {
        let results = try ExperimentalFractionalSubstepStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/fractional-substeps.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "Transit volume \(r.transitVolume) m³: \(r.acceptedSteps) steps, \(r.rejectedIntervals) retries, pressure error \(r.maximumRelativePressureError)"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--fractional-remap") {
        let results = try ExperimentalFractionalRemapStudy.run()
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/fractional-remap.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: output, options: .atomic)
        for r in results {
            print(
                "dx \(r.cellSize): \(r.transferCount) transfers, mass change \(r.relativeMassChange), pressure error \(r.maximumRelativePressureError)"
            )
        }
        print("Wrote \(output.path)")
        exit(0)
    }
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
        recordings = try RigidObjectDemo.recordings() + RigidCarDemo.recordings()
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
            of: "Box cases: mass 2 kg, static friction 0.6, sliding friction 0.5; impacts have no rebound.",
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
