import Foundation
import Metal
import simd

/// The panes the laminated glass is judged on, as their papers give them (the envelope's
/// `LaminatedGlassTests` and the shells' `LaminatedShellTest` both use them).
public enum LaminatedGlassMeasurements {
    /// Osnes, Holmen, Hopperstad and Børvik, "Fracture and fragmentation of blast-loaded laminated
    /// glass", *IJIE* 132 (2019) 103334 (CC BY), Table 2: 3.8 mm annealed / 1.52 mm PVB / 3.8 mm
    /// annealed, clamped over 300 × 300 mm in SIMLab's shock tube, the reflected pressure a
    /// Friedlander curve p_max (1 − t/t_d) exp(−b t/t_d). Measured: whether both plies cracked,
    /// and the largest deflection, mm (the centre target lost after it on D-01, D-03 and E-02).
    public static let osnes:
        [(test: String, pMax: Double, duration: Double, b: Double, cracked: Bool, deflection: Double)] = [
            ("A-01", 167.8e3, 18.89e-3, 1.18, false, 3.74), ("A-02", 168.7e3, 18.78e-3, 1.15, false, 3.55),
            ("A-03", 169.7e3, 19.37e-3, 1.18, false, 3.56), ("A-04", 172.4e3, 18.87e-3, 1.21, false, 5.79),
            ("B-01", 204.3e3, 19.60e-3, 1.39, false, 4.25), ("B-02", 205.5e3, 19.65e-3, 1.29, false, 4.59),
            ("B-03", 206.3e3, 20.01e-3, 1.35, false, 4.38), ("C-01", 215.2e3, 20.62e-3, 1.42, false, 4.54),
            ("C-02", 215.6e3, 20.78e-3, 1.51, true, 69.67), ("D-01", 231.7e3, 21.40e-3, 1.63, true, 93.80),
            ("D-02", 237.4e3, 20.23e-3, 1.44, true, 95.41), ("D-03", 237.7e3, 21.09e-3, 1.48, true, 121.61),
            ("D-04", 238.9e3, 21.40e-3, 1.52, true, 92.53), ("E-01", 254.2e3, 23.10e-3, 2.21, true, 99.18),
            ("E-02", 258.9e3, 24.20e-3, 1.98, true, 111.61),
        ]

    /// Hooper, PhD thesis (Imperial College London, 2011), Tables 3.1, 3.7, 3.8 and 3.12: panes
    /// bonded with a 20 mm bite of structural silicone; the reflected peak and impulse at the pane
    /// measured (tests 3–6, 8) or ConWep's (1, 2, 7: the gauges there read side-on); the largest
    /// deflection up to failure (mm), the largest speed (m/s) and how each failed.
    public static let hooper:
        [(
            test: String, a: Double, b: Double, ply: Double, interlayer: Double, peak: Double,
            impulse: Double,
            deflection: Double, speed: Double, outcome: String
        )] = [
            ("1", 1.5, 1.2, 3, 1.52, 165, 392, 179, 27.3, "joint failed, 7–8 ms"),
            ("2", 1.5, 1.2, 3, 1.52, 93.4, 288, 173, 17.4, "joint failed on the rebound"),
            ("3", 1.5, 1.2, 3, 1.52, 132, 413, 205, 20.5, "joint failed, 9–12 ms"),
            ("4", 1.5, 1.2, 3, 1.52, 152, 461, 140, 29.0, "joint failed, 7–9 ms"),
            ("5", 1.5, 1.2, 3, 1.52, 97, 419, 199, 21.9, "joint failed on the rebound"),
            ("6", 1.5, 1.2, 3, 1.52, 100, 418, 207, 22.3, "joint failed on the rebound"),
            ("7", 3.6, 2.0, 6, 1.52, 197, 739, 209, 23.7, "joint failed, PVB torn at 20% of the edge, 11 ms"),
            ("8", 3.3, 1.7, 6, 0.76, 223, 808, 185, 30.6, "PVB torn at every edge, 8.5 ms"),
        ]

    /// p_max (1 − t/t_d) exp(−b t/t_d) at the middle of each step to `duration`.
    public static func friedlander(pMax: Double, duration: Double, b: Double, step: Double) -> [Double] {
        stride(from: 0.5 * step, to: duration, by: step).map { t in
            pMax * (1 - t / duration) * exp(-b * t / duration)
        }
    }

    /// A triangular pulse, peak `peak` (Pa) and impulse `impulse` (Pa s), then (optionally) a
    /// triangular suction phase, at the middle of each step to `until`.
    public static func triangle(
        peak: Double, impulse: Double, suction: Double = 0, suctionImpulse: Double = 0, step: Double,
        until: Double
    ) -> [Double] {
        let duration = 2 * impulse / peak
        let suctionDuration = suction > 0 ? 2 * suctionImpulse / suction : 0
        return stride(from: 0.5 * step, to: until, by: step).map { t in
            if t < duration { return peak * (1 - t / duration) }
            let u = t - duration
            guard u < suctionDuration else { return 0 }
            let half = 0.5 * suctionDuration
            return -suction * (u < half ? u / half : (suctionDuration - u) / half)
        }
    }
}

/// A laminated pane meshed as a shell (`StructureMaterial.laminatedGlass`) under a uniform
/// pressure history, beside the envelope's single degree of freedom on the same pane: Osnes et
/// al.'s shock-tube panes on edges held still (pinned, as their clamps held them), Hooper's in
/// structural silicone, whose joints let go.
public enum LaminatedShellTest {
    /// How the pane's edges are held.
    public enum Edges: Sendable {
        /// Held still, free to turn.
        case pinned
        /// In structural silicone of the laminate's `edgeCapacity` per metre either way, reached as
        /// the edge pulls 20 mm away (Hooper's 20 mm bites peaked at 15–22 mm, thesis §6.3), then
        /// tearing to nothing over 5 mm more; the edge comes away once it has torn either way.
        case silicone
    }

    public struct Result: Sendable {
        /// When the glass first cracked (s), nil if it held.
        public var crackedAt: Double?
        /// The middle's largest deflection (m), up to the edges' letting go if they did.
        public var peak: Double
        /// Elements removed (the interlayer torn through).
        public var removed: Int
        /// When half the edge had let go of its silicone (s), and the pane's speed then (m/s).
        public var releasedAt: Double?
        public var speedAtRelease: Double?
        /// The envelope's single degree of freedom on the same pane and load.
        public var sdof: SDOFResponse
    }

    /// The silicone's pull-out law per metre of edge for an edge capacity `capacity` (N/m).
    static func silicone(_ capacity: Double) -> SpringLaw {
        SpringLaw(
            stiffness: Float(capacity / 0.02), yield: Float(capacity), hardening: Float(-capacity / 0.005))
    }

    /// The pane, a × b (m) in the xy plane, its glass meshed at about `elements` across the
    /// shorter span.
    public static func model(
        _ laminate: LaminatedGlass, a: Double, b: Double, edges: Edges, elements: Int = 24,
        glass: StructureMaterial = .annealedGlass, sixtySecondStrength: Double? = nil
    ) -> StructureModel {
        let h = Float(laminate.thickness)
        let size = Float(min(a, b)) / Float(elements)
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(Float(a), Float(b), 1 + h))],
            material: .laminatedGlass(
                laminate, a: a, b: b, glass: glass, sixtySecondStrength: sixtySecondStrength),
            elementSize: size,
            fixedBase: false)
        model.elementKind = .shell
        if edges == .silicone, let capacity = laminate.edgeCapacity {
            let law = silicone(capacity)
            let free = SpringLaw(stiffness: 0)
            let (x1, y1) = (Float(a), Float(b))
            let lines: [(Box, Int, Int)] = [
                (Box(min: SIMD3(-size, -size / 4, 0), max: SIMD3(x1 + size, size / 4, 2)), 0, 1),
                (Box(min: SIMD3(-size, y1 - size / 4, 0), max: SIMD3(x1 + size, y1 + size / 4, 2)), 0, 1),
                (Box(min: SIMD3(-size / 4, size / 2, 0), max: SIMD3(size / 4, y1 - size / 2, 2)), 1, 0),
                (
                    Box(min: SIMD3(x1 - size / 4, size / 2, 0), max: SIMD3(x1 + size / 4, y1 - size / 2, 2)),
                    1, 0
                ),
            ]
            for (region, edge, along) in lines {
                model.springSupports.append(
                    SpringSupport(
                        region: region, edge: edge, along: along, pull: law, across: law, turnPositive: free,
                        turnNegative: free, releases: true))
                model.springSupports[model.springSupports.count - 1].releasesOnPull = true
            }
        }
        return model
    }

    /// Runs the pane under `pressures` (Pa pushing it along -z, one a `step`) for `duration`.
    public static func run(
        device: MTLDevice, laminate: LaminatedGlass, a: Double, b: Double, edges: Edges,
        pressures: [Double], step: Double, duration: Double, elements: Int = 24,
        glass: StructureMaterial = .annealedGlass, sixtySecondStrength: Double? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let model = model(
            laminate, a: a, b: b, edges: edges, elements: elements, glass: glass,
            sixtySecondStrength: sixtySecondStrength)
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let size = model.elementSize
        if edges == .pinned {
            let held = solver.nodes {
                $0.x < size / 4 || $0.y < size / 4 || $0.x > Float(a) - size / 4 || $0.y > Float(b) - size / 4
            }
            solver.mutateNodes { nodes in for n in held { nodes[n].restrain(x: true, y: true, z: true) } }
        }
        // The load as at most 256 points of its table.
        let stride = max(1, Int((Double(pressures.count) / 250).rounded(.up)))
        var history: [SIMD2<Float>] = []
        for i in Swift.stride(from: 0, to: pressures.count, by: stride) {
            history.append(SIMD2(Float((Double(i) + 0.5) * step), Float(pressures[i])))
        }
        history.append(SIMD2(Float(Double(pressures.count) * step), 0))
        solver.appliedLoad = PressureLoad(axis: 2, positiveSide: true, history: history)
        let centre = solver.nearestNode(
            to: SIMD3(Float(a / 2), Float(b / 2), 1 + Float(laminate.thickness) / 2))
        var result = Result(
            crackedAt: nil, peak: 0, removed: 0, releasedAt: nil, speedAtRelease: nil,
            sdof: EnvelopePanel.laminatedGlass(laminate, a: a, b: b, sixtySecondStrength: sixtySecondStrength)
                .response(pressures: pressures, step: step))
        let chunk = max(1, Int(5e-5 / Double(solver.criticalTimeStep)))
        var time = 0.0
        while time < duration {
            solver.advance(steps: chunk)
            time += Double(chunk) * Double(solver.criticalTimeStep)
            let summary = solver.summary()
            if result.crackedAt == nil, solver.hasFragmented(0) { result.crackedAt = time }
            let node = solver.node(centre)
            if result.releasedAt == nil {
                result.peak = max(result.peak, Double(-node.displacement.z))
                if edges == .silicone, solver.releasedSpringShare() >= 0.5 {
                    result.releasedAt = time
                    result.speedAtRelease = Double(abs(node.vz))
                }
            }
            result.removed = summary.erodedElements
            if summary.hasBlownUp { break }
        }
        progress?(String(format: "%.1f ms", time * 1e3))
        return result
    }
}
