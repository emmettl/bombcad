import BlastModel
import Foundation
import Metal
import simd

extension ContactSlabTest {
    public static func run(
        device: MTLDevice, test: Test, cellSize: Float = 0.02, elementSize: Float? = nil, refinement: Int = 2,
        levels: Int = 2, duration: Double = 0.003, stepDivisor: Float = 4,
        adjust: (inout Scenario) -> Void = { _ in },
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        progress: ((String) -> Void)? = nil, inspect: ((StructureSolver, Double) -> Void)? = nil,
        configure: (inout SolverConfiguration) -> Void = { _ in }
    ) throws -> Result {
        var scenario = scenario(test, elementSize: elementSize)
        adjust(&scenario)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.refinement = refinement
        solver.configuration.refinementLevels = refinement > 1 ? levels : 1
        solver.configuration.afterburning = afterburning
        solver.configuration.openFaces = openFaces
        // As the app's "Afterburning and hot air": both or neither.
        solver.configuration.airModel = airModel ?? (afterburning ? .thermallyPerfect : .idealGas)
        configure(&solver.configuration)
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        // The structure's step is set by its elastic wave speed; compacted concrete is several
        // times stiffer (the Holmquist-Johnson-Cook curve's tangent past locking is 77 GPa and
        // rising, against an elastic bulk modulus of 15 GPa), and under a contact charge its
        // step at that limit ran away within 50 µs. A smaller step keeps it stable.
        structure.stepOverride = structure.stableTimeStep / stepDivisor
        let h = structure.model.elementSize
        let slab = slab(test, elementSize: h)
        let c = centre(test, elementSize: h)
        let top = structure.ez
        // The beams hold both faces still along two opposite edges.
        structure.mutateNodes { nodes in
            for k in [0, top] {
                for j in 0...structure.ey {
                    for i in 0...structure.ex {
                        let x = structure.origin.x + Float(i) * h
                        guard x <= slab.min.x + supportStrip + 1e-4 || x >= slab.max.x - supportStrip - 1e-4,
                            let n = structure.storedNode(i, j, k)
                        else { continue }
                        nodes[n].restrain(z: true)
                    }
                }
            }
        }
        // Nodes of the protective face by ring about the axis.
        let ring = h
        var rings: [[(i: Int, j: Int)]] = Array(repeating: [], count: Int((plan / 2) / ring) + 1)
        for j in 0...structure.ey {
            for i in 0...structure.ex where structure.storedNode(i, j, 0) != nil {
                let p = structure.referencePosition(i, j, 0)
                let r = simd_length(SIMD2(p.x - c.x, p.y - c.y))
                let bin = Int(r / ring)
                if bin < rings.count { rings[bin].append((i, j)) }
            }
        }
        // Medians, not means: a loose node thrown from the crater can pass through the slab and
        // knock a node of the protective face away several times faster than the face moves.
        func median(_ values: [Float]) -> Float {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        // With rubble, a face node whose elements have all become particles is out of the body, and
        // the particles made of the face's layer of elements move for it.
        let rubble = structure.model.rubbleParticles
        func velocities(_ ring: [(i: Int, j: Int)]) -> [Float] {
            ring.flatMap { point -> [Float] in
                let node = structure.node(point.i, point.j, 0)
                var values: [Float] = !rubble || node.mass > 0 ? [-node.velocity.z] : []
                if rubble, let p = structure.rubbleParticle(point.i, point.j, 0) { values.append(-p.vz) }
                return values
            }
        }
        func faceVelocities() -> [Float] { rings.map { median(velocities($0)) } }
        // The face within two rings of the axis: a dozen nodes or more.
        func tip() -> Float { median(velocities(rings[0] + rings[1])) }
        let start = ContinuousClock.now
        var momentum: [SIMD2<Double>] = []
        var tipVelocity: Float = 0
        var nextReport = 0.0005
        var profiles: [(time: Double, velocity: [Float])] = []
        var profileTimes = [0.0005, 0.001, 0.002].filter { $0 < duration }
        while solver.time < duration {
            let result = solver.advance(steps: 4, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            momentum.append(SIMD2(solver.time, -structure.momentum().z))
            tipVelocity = max(tipVelocity, tip())
            if let next = profileTimes.first, solver.time >= next {
                profileTimes.removeFirst()
                profiles.append((solver.time, faceVelocities()))
            }
            inspect?(structure, solver.time)
            if let progress, solver.time >= nextReport {
                nextReport += 0.0005
                progress(
                    String(
                        format:
                            "%5.2f ms: momentum %6.0f N s, face at the axis %5.1f m/s, %d elements failed",
                        solver.time * 1000, momentum.last!.y, tip(), structure.summary().erodedElements))
            }
        }
        let elapsed = ContinuousClock.now - start
        profiles.append((solver.time, faceVelocities()))
        // The cover: the elements between the protective face and the bars' band.
        let barLayer = Int(((0.045 - h / 2) / h).rounded(.down))
        var byDamage: Float = 0
        var craterRadius: Float = 0
        var craterDepth: Float = 0
        var breached = false
        var separated: Float = 0
        var removed = (protective: 0, loaded: 0)
        for j in 0..<structure.ey {
            for i in 0..<structure.ex where structure.flag(i, j, 0) != .empty {
                let p = structure.referencePosition(i, j, 0) + SIMD3(h, h, 0) / 2
                let r = simd_length(SIMD2(p.x - c.x, p.y - c.y))
                func gone(_ k: Int) -> Bool {
                    let flag = structure.flag(i, j, k)
                    return flag == .eroded || flag == .bare
                }
                var loose = false
                for k in 0...max(barLayer, 0) where k < top {
                    if gone(k) {
                        loose = true
                        break
                    }
                    let planes = structure.crackPlanes(i, j, k)
                    for p in planes.normals.indices where abs(planes.normals[p].z) > 0.7 {
                        if planes.history[p] * h > 0.5e-3 { loose = true }
                    }
                }
                if loose { byDamage = max(byDamage, r) }
                var depth = 0
                for k in stride(from: top - 1, through: 0, by: -1) {
                    guard gone(k) || structure.plasticStrain(i, j, k) > 0.01 else { break }
                    depth += 1
                }
                if depth > 0 {
                    craterRadius = max(craterRadius, r)
                    craterDepth = max(craterDepth, Float(depth) * h)
                }
                let through = (0..<top).allSatisfy(gone)
                if through { breached = true }
                for k in 0..<top where gone(k) {
                    if 2 * k < top { removed.protective += 1 } else { removed.loaded += 1 }
                }
                // The face's own node at this element's corner, against the slab at mid-depth.
                let face = -structure.node(i, j, 0).velocity.z
                let behind = -structure.node(i, j, top / 2).velocity.z
                if through || face > behind + 1 { separated = max(separated, r) }
            }
        }
        let elementMass = Double(structure.model.material.density) * Double(h * h * h)
        var kinetic = 0.0
        for k in 0...structure.ez {
            for j in 0...structure.ey {
                for i in 0...structure.ex where structure.storedNode(i, j, k) != nil {
                    let n = structure.node(i, j, k)
                    kinetic += 0.5 * Double(n.mass) * Double(simd_length_squared(n.velocity))
                }
            }
        }
        kinetic += structure.rubbleParticles().reduce(0) { $0 + Double($1.particle.kineticEnergy) }
        return Result(
            momentum: momentum, faceProfiles: profiles, ring: ring, tipVelocity: tipVelocity,
            tipVelocityAtEnd: tip(), separatedRadius: separated, spallRadiusByDamage: byDamage,
            craterRadius: craterRadius, craterDepth: craterDepth, breached: breached,
            removedProtective: Double(removed.protective) * elementMass,
            removedLoaded: Double(removed.loaded) * elementMass, kineticEnergy: kinetic,
            summary: structure.summary(),
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
