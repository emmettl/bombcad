import BlastModel
import Foundation
import Metal
import simd

extension DinuColumnTest {
    /// The shot on the shell column in the air: `cellSize` refined `levels` times by `refinement`
    /// near the shock (20 mm twice by 2 is 5 mm), from the recommended air (the mapped start).
    public static func run(
        device: MTLDevice, shot: Shot, settings: Settings = Settings(), cellSize: Float = 0.02,
        refinement: Int = 2, levels: Int = 2, duration: Double = 0.005,
        configure: (inout SolverConfiguration) -> Void = { _ in },
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let scenario = scenario(shot, settings: settings)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        var configuration = SolverConfiguration.recommended
        configuration.refinement = refinement
        configuration.refinementLevels = refinement > 1 ? levels : 1
        configure(&configuration)
        solver.configuration = configuration
        try solver.load(scenario)
        guard let shells = solver.shells else { throw BlastError.allocationFailed("the column's shells") }
        let mesh = shells.mesh
        let length = settings.length
        let h = settings.elementSize
        // The top is clamped as the base is, or both are pinned; the joint holds what it holds.
        shells.mutateNodes { nodes in
            for n in nodes.indices {
                let p = mesh.positions[n]
                if !settings.pinnedEnds {
                    if p.z > length - 1e-4 { nodes[n].isClamped = true }
                    continue
                }
                let held = restraint(at: p, settings: settings)
                guard held.x || held.y || held.z else { continue }
                nodes[n].isClamped = false
                nodes[n].restrain(x: held.x, y: held.y, z: held.z)
            }
        }
        let charge = chargePosition(shot, settings: settings)
        let webSolid = 2
        let webCentre = shells.nearestNode(to: SIMD3(axis.x, axis.y, charge.z))
        // Flange nodes at the charge's height: their tips (outward spread) and their middles (sway).
        let flangeNodes = shells.nodes { p in
            abs(p.z - charge.z) < h / 2 + 1e-4
                && abs(abs(p.x - axis.x) - (settings.section.depth - settings.section.flange) / 2) < 1e-3
        }
        let middles = flangeNodes.filter { abs(mesh.positions[$0].y - axis.y) < h / 2 + 1e-4 }
        let start = ContinuousClock.now
        var webPeak: Float = 0
        var next = 0.0005
        // As `advance(until:)` judges the end reached.
        while duration - solver.time > 1e-7 * max(duration, 1e-3) {
            let batch = autoreleasepool { solver.advance(until: min(duration, solver.time + 2e-5)) }
            guard batch.steps > 0 else {
                throw BlastError.allocationFailed(
                    String(
                        format: "a step at %.4f ms (stable %@, unsupported interaction %@, coupling full %@)",
                        solver.time * 1000, batch.isStable ? "yes" : "no",
                        batch.unsupportedInteraction ? "yes" : "no",
                        batch.couplingCapacityExceeded ? "yes" : "no"))
            }
            webPeak = max(webPeak, -shells.node(webCentre).displacement.y)
            if let progress, solver.time >= next {
                next += 0.0005
                progress(
                    String(
                        format: "%5.2f ms: web at the charge %6.1f mm back, %d elements removed",
                        solver.time * 1000, -shells.node(webCentre).displacement.y * 1000,
                        shells.summary().erodedElements))
            }
        }
        let elapsed = ContinuousClock.now - start
        let damage = shells.displayBuffer.contents().bindMemory(
            to: Float.self, capacity: max(shells.elementCount, 1))
        // Gauge S6's place, each side: the web elements nearest it.
        let gaugeElements = gaugeS6(settings).compactMap { g in
            mesh.elements.indices.filter { mesh.elements[$0].solid == webSolid }.min {
                simd_distance_squared(shells.elementCentre($0), g)
                    < simd_distance_squared(shells.elementCentre($1), g)
            }
        }
        var gaugeStrain: Float?
        var removedZ: [Float] = []
        var removedX: [Float] = []
        var flangeRemoved = 0
        var webStrain: Float = 0
        var flangeStrain: Float = 0
        for (e, element) in mesh.elements.enumerated() {
            let failure = shells.materials[element.material].failureStrain
            let web = element.solid == webSolid
            if shells.flag(e) == .active {
                let strain = damage[e] * failure
                if web {
                    webStrain = max(webStrain, strain)
                    if gaugeElements.contains(e) { gaugeStrain = max(gaugeStrain ?? 0, strain) }
                } else {
                    flangeStrain = max(flangeStrain, strain)
                }
            } else if web {
                let c = shells.elementCentre(e)
                removedZ.append(c.z)
                removedX.append(c.x)
            } else {
                flangeRemoved += 1
            }
        }
        var spread: Float = 0
        var sway: Float = 0
        for n in flangeNodes {
            let side: Float = mesh.positions[n].x > axis.x ? 1 : -1
            spread = max(spread, side * shells.node(n).displacement.x)
        }
        for n in middles { sway += -shells.node(n).displacement.y / Float(max(middles.count, 1)) }
        let samples = solver.gaugeHistories.first ?? []
        let ambient = scenario.atmosphere.pressure
        var impulse: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
        }
        let reach = reach(removedZ, from: charge.z, elementSize: h)
        return Result(
            shot: shot, webRemoved: removedZ.count, breachLength: extent(removedZ, elementSize: h),
            breachWidth: extent(removedX, elementSize: h), breachAbove: reach.above, breachBelow: reach.below,
            flangeRemoved: flangeRemoved, webPeak: webPeak,
            webFinal: -shells.node(webCentre).displacement.y, webPlasticStrain: webStrain,
            flangePlasticStrain: flangeStrain, flangeSpread: spread, columnSway: sway,
            gaugeS6PlasticStrain: gaugeStrain,
            reflectedPeak: (samples.map(\.pressure).max() ?? ambient) - ambient, reflectedImpulse: impulse,
            duration: solver.time,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
