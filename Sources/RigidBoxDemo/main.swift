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
        let conserved = arguments.contains("--conserved-quadratic")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/moving-loads\(conserved ? "-conserved" : "").json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalMovingLoadStudy.Result] = []
        _ = try ExperimentalMovingLoadStudy.run(conservedQuadratic: conserved) { r in
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
        let conserved = arguments.contains("--conserved-quadratic")
        let limited = arguments.contains("--limited") || conserved
        let refined = arguments.contains("--refined")
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/wall-reflection\(conserved ? "-conserved" : (limited ? "-limited" : ""))\(refined ? "-refined" : "").json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalWallReflectionStudy.Result] = []
        _ = try ExperimentalWallReflectionStudy.run(
            cellLengths: refined ? [0.00625, 0.003125] : [0.1, 0.05, 0.025, 0.0125],
            cfls: refined ? [0.2] : [0.2, 0.1], limited: limited, conservedQuadratic: conserved
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
    if arguments.contains("--contact-benchmark") {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var results: [RigidBodyWorldBenchmark.Result] = []
        for count in [16, 64, 256] {
            let r = try RigidBodyWorldBenchmark.run(count: count, steps: 1000)
            results.append(r)
            print(
                String(
                    format: "%d boxes: %.3f ms/step, %.0f contacts, %.0f candidate pairs of %d",
                    r.bodies, 1000 * r.secondsPerStep, r.meanContacts, r.meanCandidatePairs, r.allPairs))
            fflush(stdout)
        }
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/contact-benchmark.json")
        try encoder.encode(results).write(to: output, options: .atomic)
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--car-row") {
        // --mass=10 --cases=0.2x4 --duration=2 --cars=4 [--nearest-only]
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        func option(_ name: String) -> String? {
            arguments.first(where: { $0.hasPrefix("--\(name)=") }).map {
                String($0.dropFirst(name.count + 3))
            }
        }
        let mass = option("mass").flatMap(Double.init) ?? 10
        let duration = option("duration").flatMap(Double.init) ?? 2
        let cars = option("cars").flatMap(Int.init) ?? 4
        let nearestOnly = arguments.contains("--nearest-only")
        let parts = (option("cases") ?? "0.2x4").split(separator: "x")
        let study = ExperimentalRigidCarStudy.Case(
            cellSize: Float(parts[0]) ?? 0.2, refinement: parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
        let destination = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-car-row-demo.html")
        var results: [ExperimentalRigidRowStudy.Result] = []
        var recording: RigidObjectDemo.Recording?
        for held in [false, true] {
            let (r, frames) = try ExperimentalRigidRowStudy.run(
                device: device, study: study, chargeMass: mass, held: held, count: cars,
                nearestOnly: nearestOnly, duration: duration, recordEvery: held ? nil : 0.01
            ) { time in
                print(String(format: "  %@: %.1f s", held ? "held" : "free", time))
                fflush(stdout)
            }
            results.append(r)
            print(
                String(
                    format: "%@, %@: %d steps in %.0f s (air %.0f, coupling %.0f, motion and contact %.1f)%@",
                    held ? "Held" : "Free", study.label, r.steps, r.wallSeconds, r.timings.air,
                    r.timings.coupling,
                    r.timings.mechanics, r.failure.map { "; FAILED: \($0)" } ?? ""))
            for car in r.cars where !held {
                print(
                    String(
                        format:
                            "  %@: air %.0f/%.0f/%.0f N s, moved %.2f m, peak speed %.2f m/s, peak tilt %.1f°, final %.1f° (%@)",
                        car.name, car.airImpulse.x, car.airImpulse.y, car.airImpulse.z,
                        simd_length(car.displacement), car.peakSpeed, car.peakTilt, car.finalTilt,
                        car.outcome.rawValue))
            }
            if !held {
                let summary = r.cars.map {
                    String(format: "%@ %.2f m, %.1f°", $0.name, simd_length($0.displacement), $0.peakTilt)
                }.joined(separator: "; ")
                recording = RigidObjectDemo.Recording(
                    name: String(format: "Row of %d cars, %g kg", cars, mass),
                    description: String(
                        format:
                            "%g kg 1.5 m from Car 1's near side at 0.3 m height; %@. Moved and peak tilt: %@. %@ air.",
                        mass,
                        nearestOnly
                            ? "only Car 1 is in the air, the others move only when struck"
                            : "every car is in the air",
                        summary, study.label),
                    frames: frames, view: "front")
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(
            to: destination.deletingPathExtension().appendingPathExtension("json"))
        if let recording {
            let source = Bundle.module.url(forResource: "viewer", withExtension: "html")!
            let html = try String(contentsOf: source, encoding: .utf8)
                .replacingOccurrences(
                    of: "__RECORDINGS__",
                    with: String(decoding: JSONEncoder().encode([recording]), as: UTF8.self)
                )
                .replacingOccurrences(
                    of: "Recorded from the Swift reference solver; no blast loading.",
                    with:
                        nearestOnly
                        ? "Experimental: the nearest car coupled to the air, the row moving through contact. The other cars take no air load and do not obstruct the blast."
                        : "Experimental: every car coupled to the air and moving through its load and contact."
                )
                .replacingOccurrences(
                    of: "<option value=\"1\" selected>Real time</option>",
                    with:
                        "<option value=\"0.1\" selected>10× slow</option><option value=\"1\">Real time</option>"
                )
            try html.write(to: destination, atomically: true, encoding: .utf8)
        }
        print("Wrote \(destination.path)")
        exit(0)
    }
    if arguments.contains("--car-flight") {
        // --cases=0.2x1,0.2x2 [--transport]
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        let text =
            arguments.first(where: { $0.hasPrefix("--cases=") })?.dropFirst(8) ?? "0.2x1,0.1x1,0.2x2,0.2x4"
        let cases = text.split(separator: ",").compactMap { item -> ExperimentalRigidCarStudy.Case? in
            let parts = item.split(separator: "x")
            guard parts.count == 2, let cell = Float(parts[0]), let ratio = Int(parts[1]) else { return nil }
            return ExperimentalRigidCarStudy.Case(cellSize: cell, refinement: ratio)
        }
        var results: [ExperimentalRigidCarStudy.Flight] = []
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") }) ?? ".build/rigid-car-flight.json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for mode in arguments.contains("--transport")
            ? [.redistribution, .connectedTransport] : [ExperimentalBoxRemap.redistribution]
        {
            for study in cases {
                let r = try ExperimentalRigidCarStudy.flight(device: device, study: study, remapMode: mode)
                results.append(r)
                try encoder.encode(results).write(to: output, options: .atomic)
                print(
                    String(
                        format:
                            "%@, %@: air impulse (%.0f, %.0f, %.0f) N s, moment (%.0f, %.0f, %.0f) N m s; piston scale %.0f N s; %.0f s",
                        study.label, mode.rawValue, r.airImpulse.x, r.airImpulse.y, r.airImpulse.z,
                        r.airAngularImpulse.x, r.airAngularImpulse.y, r.airAngularImpulse.z, r.pistonScale,
                        r.wallSeconds))
                fflush(stdout)
            }
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--car-convergence") {
        // --mass=1,5,10 --duration=2 --cases=0.2x1,0.2x4 (cell size × refinement factor)
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        func option(_ name: String) -> [String]? {
            arguments.first(where: { $0.hasPrefix("--\(name)=") })?.dropFirst(name.count + 3)
                .split(separator: ",").map(String.init)
        }
        let masses = option("mass")?.compactMap(Double.init) ?? [10, 5, 1]
        let duration = option("duration")?.first.flatMap(Double.init) ?? 2
        let cases =
            option("cases")?.compactMap { text -> ExperimentalRigidCarStudy.Case? in
                let parts = text.split(separator: "x")
                guard parts.count == 2, let cell = Float(parts[0]), let ratio = Int(parts[1]) else {
                    return nil
                }
                var study = ExperimentalRigidCarStudy.Case(
                    cellSize: cell, refinement: ratio, large: arguments.contains("--large"),
                    remapMode: arguments.contains("--transport") ? .connectedTransport : .redistribution)
                study.airUntil = option("air-until")?.first.flatMap(Double.init)
                return study
            }.flatMap { study -> [ExperimentalRigidCarStudy.Case] in
                (option("scale")?.compactMap(Double.init) ?? [1]).map { scale in
                    var scaled = study
                    scaled.airLoadScale = scale
                    return scaled
                }
            } ?? ExperimentalRigidCarStudy.defaultCases
        let output = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-car-convergence.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var completed: [ExperimentalRigidCarStudy.Result] = []
        for mass in masses {
            for study in cases {
                let r = try ExperimentalRigidCarStudy.run(
                    device: device, study: study, chargeMass: mass, duration: duration
                ) { time in
                    print(String(format: "  %g kg, %@: %.1f s", mass, study.label, time))
                    fflush(stdout)
                }
                completed.append(r)
                try encoder.encode(completed).write(to: output, options: .atomic)
                if let failure = r.failure {
                    print("\(mass) kg, \(study.label): FAILED at \(r.time) s: \(failure)")
                }
                print(
                    String(
                        format:
                            "%g kg, %@: air impulse %.0f N s sideways, %.0f N s up (%.0f, %.0f by 50 ms); peak tilt %.1f° at %.2f s, final %.1f° (%@); %d steps in %.0f s (air %.0f, coupling %.0f, contact %.1f), %d patches",
                        mass, study.label, r.airImpulse.y, r.airImpulse.z, r.earlyAirImpulse.y,
                        r.earlyAirImpulse.z, r.peakTilt, r.peakTiltTime, r.finalTilt, r.outcome.rawValue,
                        r.steps,
                        r.wallSeconds, r.timings.air, r.timings.coupling, r.timings.mechanics, r.patches))
                fflush(stdout)
            }
        }
        print("Wrote \(output.path)")
        exit(0)
    }
    if arguments.contains("--car-blast") {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExperimentalRigidBoxSimulation.Failure.unsupportedConfiguration
        }
        let fine = arguments.contains("--fine")
        let destination = URL(
            fileURLWithPath: arguments.first(where: { !$0.hasPrefix("--") })
                ?? ".build/rigid-car-blast\(fine ? "-fine" : "")-demo.html")
        // --fine: patches four times finer over the car, which resolve the gap under it.
        let recordings = try RigidCarDemo.coupledRecordings(
            device: device, cellSize: 0.2, refinement: fine ? 4 : 1)
        let source = Bundle.module.url(forResource: "viewer", withExtension: "html")!
        let html = try String(contentsOf: source, encoding: .utf8)
            .replacingOccurrences(
                of: "__RECORDINGS__", with: String(decoding: JSONEncoder().encode(recordings), as: UTF8.self)
            )
            .replacingOccurrences(
                of: "Recorded from the Swift reference solver; no blast loading.",
                with:
                    fine
                    ? "Experimental blast coupling: the car's shell in ideal-gas air, on 0.05 m cells around it, which resolve the 0.15 m gap under it. The blast's load converges; the flow after it, with the car steeply tilted, does not (see docs/freestanding-objects.md)."
                    : "Experimental blast coupling: the car's shell in uniform 0.2 m ideal-gas air, which makes the 0.15 m gap under it 0.2 m. Use --fine for 0.05 m cells around the car (see docs/freestanding-objects.md)."
            )
            .replacingOccurrences(
                of: "<option value=\"1\" selected>Real time</option>",
                with: "<option value=\"0.1\" selected>10× slow</option><option value=\"1\">Real time</option>"
            )
        try html.write(to: destination, atomically: true, encoding: .utf8)
        print("Wrote \(destination.path) (\(recordings.count) cases)")
        for recording in recordings { print("\(recording.name): \(recording.description)") }
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
