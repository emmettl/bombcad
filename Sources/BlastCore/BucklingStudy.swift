import Foundation
import Metal
import simd

/// Whether the shell solver's beams buckle: a straight steel strut, pinned at one end (clamped with
/// `clamped`) and clamped at the other, which is shortened at a set speed (a prescribed node keeps
/// its spin, so that end cannot turn), its
/// square section `side` wide, shortened slowly after a small lateral nudge. The axial force it
/// carries is set against Euler's load P_E = π² E I / L²: 2.046 P_E pinned and clamped, 4 P_E clamped
/// at both ends; and, where the strut is stocky enough to yield first, the squash load f_y A.
public enum BucklingStudy {
    public struct Result: Sendable {
        public var length: Float
        public var side: Float
        public var elementSize: Float
        public var beams: Int
        /// Largest axial force carried (N), and the shortening at it (m).
        public var peakForce: Float
        public var shorteningAtPeak: Float
        /// The largest sideways displacement of any node (m).
        public var lateral: Float
        /// The force carried over the last tenth of the shortening (N): an elastic strut's
        /// buckled plateau, which stays near its critical load.
        public var finalForce: Float = 0
        public var euler: Float
        public var squash: Float
        /// Force against shortening, sampled.
        public var history: [SIMD2<Float>]
        /// Nodes held at each end.
        public var endNodes: Int = 0
    }

    /// `rate` is the end's speed (m/s), `shortening` how far to go (m); `yieldStress` nil keeps
    /// the steel elastic. `nudge` is the middle's initial lateral speed (m/s).
    public static func run(
        device: MTLDevice, length: Float = 3, side: Float = 0.05, elementSize: Float = 0.05,
        rate: Float = 0.02,
        shortening: Float = 0.006, yieldStress: Float? = nil, nudge: Float = 0.002, damping: Float = 20,
        clamped: Bool = false, cowperSymonds: SIMD2<Float>? = nil
    ) throws -> Result {
        var material = StructureMaterial(
            name: "Strut steel", density: 7850, youngsModulus: 210e9, poissonRatio: 0.3,
            yieldStress: yieldStress ?? 1e30, hardeningModulus: 0, failureStrain: 1e30)
        material.rateLaw = cowperSymonds.map { .cowperSymonds(d: $0.x, q: $0.y) }
        let half = side / 2
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, -half, 1 - half), max: SIMD3(length, half, 1 + half))],
            material: material,
            elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        // Perfectly straight, as the closed forms take it.
        model.memberImperfections = false
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = damping
        let fixed = solver.nodes { $0.x < 1e-4 }
        let pushed = solver.nodes { $0.x > length - 1e-4 }
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            for n in fixed { nodes[n].restrain(x: true, y: true, z: true, rotation: clamped) }
            for n in pushed {
                nodes[n].restrain(y: true, z: true)
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(-rate, 0, 0)
            }
            // A half-sine of lateral speed, the first mode's shape.
            for n in nodes.indices where !fixed.contains(n) && !pushed.contains(n) {
                let x = positions[n].x
                nodes[n].velocity.z = nudge * sin(Float.pi * x / length)
            }
        }
        var history: [SIMD2<Float>] = []
        var peak: Float = 0
        var atPeak: Float = 0
        var lateral: Float = 0
        let stepsPerSample = max(1, Int(0.0005 / solver.criticalTimeStep))
        while Float(solver.time) * rate < shortening {
            solver.advance(steps: stepsPerSample)
            let force = pushed.reduce(Float(0)) { $0 + solver.nodalForce($1).x }
            let short = Float(solver.time) * rate
            history.append(SIMD2(short, abs(force)))
            if abs(force) > peak {
                peak = abs(force)
                atPeak = short
            }
            for n in 0..<solver.nodeCount {
                let d = solver.node(n).displacement
                lateral = max(lateral, (d.y * d.y + d.z * d.z).squareRoot())
            }
        }
        let inertia = side * side * side * side / 12
        let tail = history.filter { $0.x > 0.9 * shortening }
        var result = Result(
            length: length, side: side, elementSize: elementSize, beams: solver.beamCount, peakForce: peak,
            shorteningAtPeak: atPeak, lateral: lateral,
            euler: Float.pi * Float.pi * material.youngsModulus * inertia / (length * length),
            squash: (yieldStress ?? .infinity) * side * side, history: history, endNodes: fixed.count)
        result.finalForce = tail.reduce(0) { $0 + $1.y } / Float(max(tail.count, 1))
        return result
    }

    /// Dynamic buckling: the strut's end driven in at `speed` (m/s) from rest, its far end held,
    /// the steel elastic, every node given a small random sideways speed (`noise`, m/s). Behind
    /// the compression front, which runs at c = √(E/ρ), the force is F₀ = E A v / c, and the
    /// sideways disturbance grows fastest at the wavelength λ = 2π √(2 E I / F₀) (Lindberg's
    /// preferred mode; Gladden et al. measured λ ∝ v^(−1/2) in rods struck by projectiles, *PRL*
    /// 94, 2005), at the rate F₀ / 2√(ρA EI). Returned: that λ and the wavelength the strut's
    /// sideways speed shows most of, over the compressed length, once that rate has grown the
    /// disturbance `growth` times e, its power summed over `seeds` random disturbances; the strut
    /// is made long enough that the front has not reached its far end.
    public static func impact(
        device: MTLDevice, side: Float = 0.02, elementSize: Float = 0.02, speed: Float = 50,
        growth: Float = 5,
        noise: Float = 0.01, seeds: Int = 1
    ) throws -> (predicted: Float, measured: Float, force: Float, length: Float) {
        let c = (210e9 / Float(7850)).squareRoot()
        let force = 210e9 * side * side * speed / c
        let inertia = side * side * side * side / 12
        let rate = force / (2 * (7850 * side * side * 210e9 * inertia).squareRoot())
        let time = growth / rate
        let length = (c * time + 0.5).rounded(.up)
        let material = StructureMaterial(
            name: "Strut steel", density: 7850, youngsModulus: 210e9, poissonRatio: 0.3, yieldStress: 1e30,
            hardeningModulus: 0, failureStrain: 1e30)
        let half = side / 2
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, -half, 1 - half), max: SIMD3(length, half, 1 + half))],
            material: material, elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        // Straight but for the random disturbance, as Lindberg takes it.
        model.memberImperfections = false
        let predicted = 2 * Float.pi * (2 * material.youngsModulus * inertia / force).squareRoot()
        // Wavelengths from 4 elements to the compressed length, 1% apart, and their summed power.
        var wavelengths: [Float] = []
        var wavelength = 4 * elementSize
        while wavelength < c * time - 4 * elementSize {
            wavelengths.append(wavelength)
            wavelength *= 1.01
        }
        var power = [Float](repeating: 0, count: wavelengths.count)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func random() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(seed >> 40) / Float(1 << 24) * 2 - 1
        }
        for _ in 0..<max(seeds, 1) {
            let solver = try ShellSolver(device: device, model: model)
            solver.gravity = 0
            solver.groundContact = false
            let fixed = solver.nodes { $0.x < 1e-4 }
            let pushed = solver.nodes { $0.x > length - 1e-4 }
            solver.mutateNodes { nodes in
                for n in fixed { nodes[n].restrain(x: true, y: true, z: true, rotation: true) }
                for n in pushed {
                    nodes[n].restrain(y: true, z: true)
                    nodes[n].isPrescribed = true
                    nodes[n].velocity = SIMD3(-speed, 0, 0)
                }
                for n in nodes.indices where !fixed.contains(n) && !pushed.contains(n) {
                    nodes[n].velocity.z = noise * random()
                }
            }
            while Float(solver.time) < time {
                solver.advance(
                    steps: max(1, Int(((time - Float(solver.time)) / solver.criticalTimeStep).rounded(.up))))
            }
            // The compressed length, short of the front and the driven end.
            let positions = solver.referencePositions
            let front = length - c * Float(solver.time)
            let samples = positions.indices.filter {
                positions[$0].x > front + 2 * elementSize && positions[$0].x < length - 2 * elementSize
                    && abs(positions[$0].y) < 1e-4
            }
            .sorted { positions[$0].x < positions[$1].x }
            let xs = samples.map { positions[$0].x }
            let vs = samples.map { solver.node($0).velocity.z }
            for (n, wavelength) in wavelengths.enumerated() {
                let k = 2 * Float.pi / wavelength
                var re: Float = 0
                var im: Float = 0
                for (x, v) in zip(xs, vs) {
                    re += v * cos(k * x)
                    im += v * sin(k * x)
                }
                power[n] += re * re + im * im
            }
        }
        // The wavelength with the most power.
        let best = power.indices.max { power[$0] < power[$1] }.map { wavelengths[$0] } ?? 0
        return (predicted, best, force, length)
    }

    /// Against Eurocode 3's buckling curves: a pinned strut of S355 (or `yieldStress`), square
    /// `side` wide, as long as slenderness λ̄ = √(N_pl / N_cr) makes it, upright, its foot pinned and
    /// its head held sideways only. Its head carries a mass of a hundred times the strut's, whose
    /// weight is ramped by raising gravity slowly (over `cycles` of the longer of the strut's
    /// first sideways and the mass's axial periods) to 1.2 N_pl: load control, so the largest
    /// force its foot carries is the strut's resistance, χ N_pl. Bowed by `curve` (nil: straight).
    public static func curve(
        device: MTLDevice, slenderness: Float, curve: BucklingCurve?, side: Float = 0.05,
        yieldStress: Float = 355e6, elements: Int = 24, cycles: Float = 40, bowDivisor: Float? = nil
    ) throws -> (peak: Float, squash: Float, model: Float, eurocode: Float?, length: Float) {
        let modulus: Float = 210e9
        let rho: Float = 7850
        let area = side * side
        let inertia = side * side * side * side / 12
        let squash = yieldStress * area
        // λ̄ = (L / i) / (π √(E / f_y)).
        let length =
            slenderness * Float.pi * (modulus / yieldStress).squareRoot() * (inertia / area).squareRoot()
        let material = StructureMaterial(
            name: "Strut steel", density: rho, youngsModulus: modulus, poissonRatio: 0.3,
            yieldStress: yieldStress,
            hardeningModulus: 0, failureStrain: 1e30)
        let half = side / 2
        var model = StructureModel(
            solids: [Box(min: SIMD3(-half, -half, 0.5), max: SIMD3(half, half, 0.5 + length))],
            material: material, elementSize: length / Float(elements), fixedBase: false)
        model.elementKind = .shell
        model.memberImperfections = curve != nil
        if let curve { model.bucklingCurve = curve }
        // `bowDivisor`: Table 5.1's L / e₀ in place of the default amplitude.
        let solver = try MemberImperfection.$divisorOverride.withValue(bowDivisor) {
            try ShellSolver(device: device, model: model)
        }
        solver.groundContact = false
        solver.damping = 0
        let foot = solver.nodes { $0.z < 0.5 + 1e-4 }
        let head = solver.nodes { $0.z > 0.5 + length - 1e-4 }
        let headMass = 100 * rho * area * length / Float(max(head.count, 1))
        solver.mutateNodes { nodes in
            for n in foot { nodes[n].restrain(x: true, y: true, z: true) }
            for n in head {
                nodes[n].restrain(x: true, y: true)
                nodes[n].mass = headMass
            }
        }
        let omega = pow(Float.pi / length, 2) * (modulus * inertia / (rho * area)).squareRoot()
        let axialPeriod =
            2 * Float.pi * (headMass * Float(head.count) * length / (modulus * area)).squareRoot()
        let duration = cycles * max(2 * Float.pi / omega, axialPeriod)
        let top = 1.2 * squash / (headMass * Float(head.count))
        var peak: Float = 0
        let stepsPerSample = max(1, Int(duration / 400 / solver.criticalTimeStep))
        while Float(solver.time) < duration {
            solver.gravity = top * Float(solver.time) / duration
            solver.advance(steps: stepsPerSample)
            let force = foot.reduce(Float(0)) { $0 + solver.nodalForce($1).z }
            peak = max(peak, abs(force))
            // Past its peak by a third: it has gone.
            if abs(force) < 0.67 * peak, peak > 0.05 * squash { break }
        }
        return (peak, squash, peak / squash, curve?.reduction(slenderness: slenderness), length)
    }
}
