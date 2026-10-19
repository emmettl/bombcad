import BlastModel
import Foundation
import Metal
import simd

extension ImpactBenchmark {
    /// Strikes the beam: the weight's mass is added to the plate's top nodes, which start down
    /// with its momentum at 8.0 m/s shared with their own mass, and leaves them once they turn
    /// back up. Gravity is on. Runs for `duration`; the residual is the mean over its last 30 ms.
    public static func run(
        device: MTLDevice, test: Test, elementsThroughDepth: Int = 16, duration: Double = 0.2,
        specimen change: (inout Specimen) -> Void = { _ in },
        adjust: (inout StructureModel) -> Void = { _ in }, inspect: (StructureSolver) -> Void = { _ in },
        prepare: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        var specimen = specimen(test)
        change(&specimen)
        return try run(
            device: device, specimen: specimen, weight: test.weight, speed: impactSpeed,
            elementsThroughDepth: elementsThroughDepth, duration: duration, adjust: adjust, inspect: inspect,
            prepare: prepare)
    }

    /// Strikes `specimen` at mid-span with `weight` kilograms at `speed` metres per second, as
    /// `run(device:test:)` does. With `bounce`, the weight leaves the plate once the plate stops
    /// going down, as a real one does; without it, it stays on.
    public static func run(
        device: MTLDevice, specimen: Specimen, weight: Float, speed impact: Float,
        elementsThroughDepth: Int = 16,
        duration: Double = 0.2, bounce: Bool = true, push: Float? = nil,
        adjust: (inout StructureModel) -> Void = { _ in }, inspect: (StructureSolver) -> Void = { _ in },
        sample: ((StructureSolver) -> Void)? = nil, prepare: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        let length = specimen.length
        let depth = specimen.depth
        let span = specimen.span
        let plate = specimen.plate
        let bearingLength = specimen.bearingLength
        var model = model(specimen, elementsThroughDepth: elementsThroughDepth)
        adjust(&model)
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        // For benchmarks: a hook before the run, such as a shorter step.
        prepare(solver)
        let h = model.elementSize
        let middle = Int(((specimen.strike.map { (length - span) / 2 + $0 } ?? length / 2) / h).rounded())
        // With support plates the lattice starts at their undersides, this many rows below the beam.
        let plateRows = specimen.supportPlates.map { Int(max(($0 / h).rounded(), 1)) } ?? 0
        let beamBottom = plateRows
        let beamTop = plateRows + Int((depth / h).rounded())
        // The plate is as many elements thick as its 50 mm rounds to.
        let top = (0...solver.ez).last { solver.storedNode(middle, 0, $0) != nil } ?? solver.ez
        let reach = Int((plate.x / 2 / h).rounded())
        let supports = [(length - span) / 2, (length + span) / 2].map { Int(($0 / h).rounded()) }
        // Rollers below and hinges above, the hinges held down by bars, bear on the beam through
        // steel plates, taken as 100 mm long: through one line of nodes the reaction would crush
        // the concrete. The beam is pushed up from below and held down from above, so that it
        // never hangs from its bottom face.
        let bearing = max(Int((bearingLength / 2 / h).rounded()), 0)
        let bearingNodes = supports.map { (($0 - bearing)...($0 + bearing)) }
        var struck: [Int] = []
        var struckAt: [(Int, Int)] = []
        for i in (middle - reach)...(middle + reach) {
            for j in 0...solver.ey {
                if let n = solver.storedNode(i, j, top) {
                    struck.append(n)
                    struckAt.append((i, j))
                }
            }
        }
        // With `push`, the plate is driven down slowly instead, and damped, until the beam's
        // middle has gone down that far; then drawn back until it no longer pushes, and let go.
        let pushRate: Float = 0.05
        if push != nil { solver.damping = 100 }
        solver.mutateNodes { nodes in
            // The weight's momentum, shared with the plate's top nodes it strikes.
            let carried = struck.reduce(Float(0)) { $0 + nodes[$1].mass }
            let speed = weight * impact / (weight + carried)
            for n in struck {
                if push != nil {
                    nodes[n].isPushedVertically = true
                    nodes[n].velocity = SIMD3(0, 0, -pushRate)
                } else {
                    nodes[n].mass += weight / Float(struck.count)
                    nodes[n].velocity = SIMD3(0, 0, -speed)
                }
            }
            if plateRows > 0 {
                // The plates are held along their centre lines, under the bottom plate and over
                // the top one, up and down; lengthwise at the bottom line, at one support or both.
                for (side, support) in supports.enumerated() {
                    for j in 0...solver.ey {
                        if let n = solver.storedNode(support, j, 0) {
                            nodes[n].restrain(x: side == 0 || specimen.pinnedEnds, y: j == 0, z: true)
                        }
                        if let n = solver.storedNode(support, j, beamTop + plateRows) {
                            nodes[n].restrain(z: true)
                        }
                    }
                }
                return
            }
            for range in bearingNodes {
                for i in range {
                    for j in 0...solver.ey {
                        if let n = solver.storedNode(i, j, 0) {
                            nodes[n].restsOnSupport = true
                            nodes[n].restrain(y: j == 0)
                        }
                        if specimen.heldDown, let n = solver.storedNode(i, j, beamTop) {
                            nodes[n].isHeldDown = true
                        }
                    }
                }
            }
            if specimen.pinnedEnds {
                // Lengthwise at mid-depth along the whole clamp, so the thrust is not on one line.
                for range in bearingNodes {
                    for i in range {
                        for j in 0...solver.ey {
                            if let n = solver.storedNode(i, j, beamTop / 2) { nodes[n].restrain(x: true) }
                        }
                    }
                }
            } else if let n = solver.storedNode(supports[0], 0, 0) {
                nodes[n].restrain(x: true)
            }
        }
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        var reactions: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.0001 / solver.criticalTimeStep))
        var attached = push == nil
        // The weight's speed (the struck nodes' mean, downwards) while it rides the plate.
        var weightSpeed: [Float] = push == nil ? [impact] : []
        // Pushing: 0 down, 1 drawn back, 2 let go and settling (until `settled`).
        var phase = 0
        var settled = Double.infinity
        var pushForce: Float = 0
        while solver.time < (push.map { Double(3 * $0 / pushRate) } ?? duration), solver.time < settled {
            solver.advance(steps: stepsPerSample)
            sample?(solver)
            history.append(
                SIMD2(Float(solver.time), -solver.displacement(middle, solver.ey / 2, beamBottom).z))
            if let push {
                let force = struckAt.reduce(Float(0)) { $0 + solver.nodalForce($1.0, $1.1, top).z }
                if phase == 0 { pushForce = max(pushForce, force) }
                if phase == 0 && history.last!.y >= push {
                    phase = 1
                    solver.mutateNodes { nodes in
                        for n in struck { nodes[n].velocity = SIMD3(0, 0, pushRate) }
                    }
                } else if phase == 1 && force <= 0 {
                    phase = 2
                    settled = solver.time + 0.1
                    solver.mutateNodes { nodes in
                        for n in struck {
                            nodes[n].isPushedVertically = false
                            nodes[n].velocity = .zero
                        }
                    }
                }
            }
            if attached {
                solver.mutateNodes { nodes in
                    weightSpeed.append(
                        -struck.reduce(Float(0)) { $0 + nodes[$1].velocity.z } / Float(struck.count))
                }
            }
            if attached && bounce {
                // The weight rides the plate down and leaves it once the plate turns back up:
                // its mass comes off, carrying away its share of the plate's (by then nearly
                // nil) momentum.
                solver.mutateNodes { nodes in
                    let rising = struck.reduce(Float(0)) { $0 + nodes[$1].velocity.z } / Float(struck.count)
                    if rising > 0 {
                        for n in struck { nodes[n].mass -= weight / Float(struck.count) }
                        attached = false
                    }
                }
            }
            var reaction = SIMD2<Float>.zero
            if plateRows > 0 {
                for (side, support) in supports.enumerated() {
                    for j in 0...solver.ey {
                        for k in [0, beamTop + plateRows] where solver.storedNode(support, j, k) != nil {
                            reaction[side] += solver.nodalForce(support, j, k).z
                        }
                    }
                }
            }
            for (side, range) in bearingNodes.enumerated() where plateRows == 0 {
                for i in range {
                    // Only the nodes sitting on their stops bear on the supports.
                    for j in 0...solver.ey {
                        if solver.storedNode(i, j, 0) != nil, solver.displacement(i, j, 0).z == 0 {
                            reaction[side] += solver.nodalForce(i, j, 0).z
                        }
                        if specimen.heldDown, solver.storedNode(i, j, beamTop) != nil,
                            solver.displacement(i, j, beamTop).z == 0
                        {
                            reaction[side] += solver.nodalForce(i, j, beamTop).z
                        }
                    }
                }
            }
            reactions.append(reaction)
        }
        let elapsed = ContinuousClock.now - start
        inspect(solver)
        let window = max(
            1, Int((0.0005 / (Double(stepsPerSample) * Double(solver.criticalTimeStep))).rounded()))
        var peakReaction: Float = 0
        var supportReactions = SIMD2<Float>.zero
        var supportReactionTimes = SIMD2<Float>.zero
        let sampleTime = Float(Double(stepsPerSample) * Double(solver.criticalTimeStep))
        if reactions.count >= window {
            for end in window...reactions.count {
                let mean = abs(reactions[(end - window)..<end].reduce(.zero, +) / Float(window))
                peakReaction = max(peakReaction, mean.max())
                for side in 0..<2 where mean[side] > supportReactions[side] {
                    supportReactions[side] = mean[side]
                    supportReactionTimes[side] = (Float(end) - Float(window) / 2) * sampleTime
                }
            }
        }
        // Impact force from the weight's deceleration, over 0.42 ms windows.
        let sample = Double(stepsPerSample) * Double(solver.criticalTimeStep)
        let reading = max(1, Int((1 / 2400 / sample).rounded()))
        var peakImpactForce: Float = 0
        var impactPeakTime: Float = 0
        if weightSpeed.count > reading {
            for i in reading..<weightSpeed.count {
                let force =
                    weight * (weightSpeed[i - reading] - weightSpeed[i]) / Float(Double(reading) * sample)
                if force > peakImpactForce {
                    peakImpactForce = force
                    impactPeakTime = (Float(i) - Float(reading) / 2) * Float(sample)
                }
            }
        }
        let end = push == nil ? duration : Double(history.last?.x ?? 0)
        let tail = history.filter { Double($0.x) >= end - 0.03 }
        if push != nil { peakReaction = pushForce }
        return Result(
            history: history, peak: history.map(\.y).max() ?? 0,
            residual: tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1)), peakReaction: peakReaction,
            peakImpactForce: peakImpactForce, impactPeakTime: impactPeakTime,
            supportReactions: supportReactions,
            supportReactionTimes: supportReactionTimes, summary: solver.summary(),
            elementCount: solver.elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    /// The same beam meshed with beam elements of `size`, stirrups as their tie ratio, struck
    /// through the nodes under the plate; supported at the nodes over each bearing, on the
    /// beam's axis. The blow is impulsive loading, under whose defaults beams do not check each
    /// section's shear; with the check (`sectionShear` true), the sections beside the plate fail
    /// in the first half millisecond under every drop: see docs/validation.md. Nil follows the
    /// regime.
    public static func runBeams(
        device: MTLDevice, test: Test, size: Float = 0.1, duration: Double = 0.2, sectionShear: Bool? = nil
    ) throws -> BeamResult {
        var model = model(test, elementsThroughDepth: 12)
        model.solids.removeLast()
        model.solidMaterial = []
        model.elementSize = size
        model.elementKind = .shell
        model.detectedLoading = .impulsive
        if sectionShear == true { model.regimeDefaults = false }
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        if sectionShear == false { solver.disableSectionShear() }
        let axis = solver.referencePositions[solver.nearestNode(to: SIMD3(length / 2, width / 2, 0))]
        func nodes(within half: Float, of x: Float) -> [Int] {
            let at = solver.referencePositions[solver.nearestNode(to: SIMD3(x, axis.y, axis.z))].x
            return solver.nodes { abs($0.x - at) <= half + 1e-4 && abs($0.z - axis.z) < 1e-4 }
        }
        let struck = nodes(within: plate.x / 2, of: length / 2)
        let supports = [(length - span) / 2, (length + span) / 2].map { nodes(within: 0, of: $0) }
        let middle = solver.nearestNode(to: SIMD3(length / 2, axis.y, axis.z))
        solver.mutateNodes { nodes in
            let carried = struck.reduce(Float(0)) { $0 + nodes[$1].mass }
            let speed = test.weight * impactSpeed / (test.weight + carried)
            for n in struck {
                nodes[n].mass += test.weight / Float(struck.count)
                nodes[n].velocity = SIMD3(0, 0, -speed)
            }
            for (side, support) in supports.enumerated() {
                for n in support { nodes[n].restrain(x: side == 0, y: true, z: true) }
            }
        }
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        var reactions: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.0001 / solver.criticalTimeStep))
        while solver.time < duration {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.node(middle).displacement.z))
            reactions.append(SIMD2(supports.map { $0.reduce(Float(0)) { $0 + solver.nodalForce($1).z } }))
        }
        let elapsed = ContinuousClock.now - start
        let window = max(
            1, Int((0.0005 / (Double(stepsPerSample) * Double(solver.criticalTimeStep))).rounded()))
        var peakReaction: Float = 0
        if reactions.count >= window {
            for end in window...reactions.count {
                peakReaction = max(
                    peakReaction, abs(reactions[(end - window)..<end].reduce(.zero, +) / Float(window)).max())
            }
        }
        let tail = history.filter { Double($0.x) >= duration - 0.03 }
        return BeamResult(
            peak: history.map(\.y).max() ?? 0,
            residual: tail.map(\.y).reduce(0, +) / Float(max(tail.count, 1)),
            peakReaction: peakReaction,
            sheared: (0..<solver.beamCount).filter { solver.beamHasShearFailed($0) }.count,
            removed: (0..<solver.beamCount).filter { solver.beamFlag($0) != .active }.count,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }

    public static func run(
        device: MTLDevice, test: ShearTest, elementsThroughDepth: Int = 16, duration: Double = 0.15,
        specimen change: (inout Specimen) -> Void = { _ in },
        adjust: (inout StructureModel) -> Void = { _ in }, inspect: (StructureSolver) -> Void = { _ in },
        prepare: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        var specimen = specimen(test)
        change(&specimen)
        return try run(
            device: device, specimen: specimen, weight: 300, speed: test.speed,
            elementsThroughDepth: elementsThroughDepth, duration: duration, adjust: adjust, inspect: inspect,
            prepare: prepare)
    }

    /// Strikes one of Peterson's beams with 70 kg at 6.86 m/s, as `run(device:specimen:...)`.
    public static func run(
        device: MTLDevice, test: PetersonTest, elementsThroughDepth: Int = 16, duration: Double = 0.03,
        specimen change: (inout Specimen) -> Void = { _ in },
        adjust: (inout StructureModel) -> Void = { _ in }, inspect: (StructureSolver) -> Void = { _ in },
        sample: ((StructureSolver) -> Void)? = nil, prepare: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        var specimen = specimen(test)
        change(&specimen)
        return try run(
            device: device, specimen: specimen, weight: petersonWeight, speed: petersonSpeed,
            elementsThroughDepth: elementsThroughDepth, duration: duration, adjust: adjust, inspect: inspect,
            sample: sample, prepare: prepare)
    }
}
