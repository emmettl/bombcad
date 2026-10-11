import Foundation
import Metal
import simd

/// Masonry walls under long-duration blast, and where their debris landed: R. A. Keys and S. K.
/// Clubley, "Experimental analysis of debris distribution of masonry panels subjected to long
/// duration blast loading", *Engineering Structures* 130 (2017) 229–241 (the accepted manuscript,
/// CC BY-NC-ND 4.0), and R. A. Keys's PhD thesis, University of Southampton, 2016. The derived
/// numbers are in `Fixtures/KeysClubley/walls.json`.
///
/// Single-leaf walls of frogged London bricks (215 × 100 × 65 mm, about 2.1 kg) in running bond
/// with 10 mm joints of class (ii) mortar, 26 courses (2 m) high, their bases mortared to the
/// floor, free at the top and sides, stood across the Air Blast Tunnel at MoD Shoeburyness: a
/// shock tube whose 4.9 m section gave about 110 kPa for 210 ms and its 10.2 m section about
/// 55 kPa for 150–180 ms. Every fragment was then logged by mass and position along the tunnel.
///
/// Assumed: the tunnel as a box of open sides 4 m wide and high, the wave driven in at its
/// upstream face as the measured incident overpressure's Friedlander curve (its peak, positive
/// phase and impulse) with the gas behind the shock by the Rankine–Hugoniot relations and a
/// simple wave; the wall's density from the debris collected (about 345 kg for 0.2 m³); the
/// built-in brickwork's units and joints (its joints from Lourenço and Rots, not measured here);
/// the base fixed.
public enum MasonryDebrisTest {
    public struct Test: Sendable {
        public var name: String
        /// Width across the tunnel (m); the walls were 0.1 m thick and 26 courses high.
        public var width: Float
        /// Measured incident overpressure (Pa), positive phase (s) and impulse (Pa s).
        public var overpressure: Float
        public var duration: Float
        public var impulse: Float
        /// Measured: the share of the debris's mass within each distance band (m from the wall's
        /// front face), read off the paper's figures; the farthest throw (m); the heights of the
        /// first horizontal cracks (m); whole bricks (share).
        public var bands: [(range: ClosedRange<Float>, share: Float)]
        public var farthest: Float
        public var crackHeights: [Float]
        public var wholeBricks: Float
        public var remark: String
    }

    public static let tests: [Test] = [
        Test(
            name: "BWL1A", width: 1, overpressure: 100e3, duration: 0.214, impulse: 7260,
            bands: [(0...10, 0.05), (10...25, 0.30), (25...35, 0.55), (35...50, 0.10)], farthest: 48,
            crackHeights: [0.3, 0.5, 1.6], wholeBricks: 0.80,
            remark: "the peak at 30 m piled against instrumentation columns"),
        Test(
            name: "BWL2C", width: 1, overpressure: 60e3, duration: 0.179, impulse: 3952,
            bands: [(0...3, 0.05), (3...6, 0.35), (6...9, 0.55), (9...14, 0.05)], farthest: 12,
            crackHeights: [0.5, 1.5], wholeBricks: 0.81,
            remark: "the peak at 7 m piled against the camera lights"),
        Test(
            name: "BWL3B", width: 2, overpressure: 57e3, duration: 0.152, impulse: 3362,
            bands: [(0...3, 0.25), (3...6, 0.25), (6...9, 0.40), (9...15, 0.10)], farthest: 14,
            crackHeights: [], wholeBricks: 0.82,
            remark: "the peak at 7 m piled against the camera lights; 2-3 horizontal cracks and stepped ones"),
    ]

    static let upstream: Float = 2
    static let downstream: Float = 10
    static let tunnel: Float = 4
    static let thickness: Float = 0.1
    static let height: Float = 26 * 0.075

    public static func wall(_ test: Test) -> Box {
        Box(
            min: SIMD3(upstream, (tunnel - test.width) / 2, 0),
            max: SIMD3(upstream + thickness, (tunnel + test.width) / 2, height))
    }

    /// Brickwork as units and joints, of the wall's density as collected.
    public static func material() -> StructureMaterial {
        var material = StructureMaterial.masonry
        material.density = 1725
        return material
    }

    public static func scenario(_ test: Test, elementSize: Float = 0.025) -> Scenario {
        let wall = wall(test)
        let model = StructureModel(
            solids: [wall], material: material(), elementSize: elementSize, fixedBase: true)
        let centre = SIMD3((wall.min.x + wall.max.x) / 2, (wall.min.y + wall.max.y) / 2, 1)
        let gauges = [
            Gauge("Incident, by the inlet", at: SIMD3(0.3, 0.3, 1)),
            Gauge("Front face, centre", at: SIMD3(wall.min.x - 0.02, centre.y, 1)),
        ]
        return Scenario(
            name: "Masonry wall \(test.name)", domainSize: SIMD3(upstream + downstream, tunnel, tunnel),
            boxes: [], charge: Charge(mass: 0, position: SIMD3(0.5, 0.5, 0.5)), gauges: gauges,
            structure: model)
    }

    /// The Friedlander decay constant b for which a wave of `peak`, `duration` carries `impulse`:
    /// I = p t+ (1/b − (1 − e^−b)/b²).
    public static func decay(peak: Float, duration: Float, impulse: Float) -> Float {
        let target = impulse / (peak * duration)
        var low: Float = 0.01
        var high: Float = 20
        for _ in 0..<60 {
            let b = 0.5 * (low + high)
            let share = 1 / b - (1 - exp(-b)) / (b * b)
            if share > target { low = b } else { high = b }
        }
        return 0.5 * (low + high)
    }

    /// The air entering the tunnel at time `t` after the shock: the incident overpressure's
    /// Friedlander curve, the shock's jump by the Rankine–Hugoniot relations, and behind it a
    /// simple wave (isentropic, the Riemann invariant along the backward characteristics kept).
    public static func inflow(_ test: Test, at t: Float, ambient: Float = 101_325, density: Float = 1.225)
        -> Primitive
    {
        let gamma: Float = 1.4
        let c0 = (gamma * ambient / density).squareRoot()
        let ps = ambient + test.overpressure
        let mach = (1 + (gamma + 1) / (2 * gamma) * (ps / ambient - 1)).squareRoot()
        let rhos = density * (gamma + 1) * mach * mach / ((gamma - 1) * mach * mach + 2)
        let us = 2 * c0 / (gamma + 1) * (mach - 1 / mach)
        let cs = (gamma * ps / rhos).squareRoot()
        let b = decay(peak: test.overpressure, duration: test.duration, impulse: test.impulse)
        let s = max(t, 0) / test.duration
        // Past the negative phase's depth the curve is held at its least.
        let f = max((1 - s) * exp(-b * s), -0.3)
        let p = max(ambient + test.overpressure * f, 0.2 * ambient)
        let rho = rhos * pow(p / ps, 1 / gamma)
        let c = (gamma * p / rho).squareRoot()
        let u = us + 2 / (gamma - 1) * (c - cs)
        return Primitive(density: rho, velocity: SIMD3(u, 0, 0), pressure: p)
    }

    public struct Result: Sendable {
        /// Share of the wall's mass in each measured band, where the debris first touched the
        /// ground and where it lay at the end.
        public var landedShares: [Float]
        public var finalShares: [Float]
        /// The mass (kg) in 1 m bins downstream of the front face (index 0 is 0–1 m; standing or
        /// upstream mass in index 0), at first landing and at the end.
        public var landed: [Float]
        public var final: [Float]
        /// The farthest the mass went: the 99th percentile of the debris's mass by distance (m),
        /// at first landing and at the end.
        public var farthestLanded: Float
        public var farthestFinal: Float
        /// Heights (m) of the courses whose bed joints had opened by 1 mm across half the wall's
        /// width at 50 ms.
        public var crackHeights: [Float]
        /// Peak overpressure (Pa) and impulse (Pa s) at the incident gauge, and the peak on the
        /// front face.
        public var incidentPeak: Float
        public var incidentImpulse: Float
        public var reflectedPeak: Float
        public var totalMass: Float
        public var summary: StructureSummary
        public var wallSeconds: Double
    }

    public static func run(
        device: MTLDevice, test: Test, cellSize: Float = 0.05, elementSize: Float = 0.025,
        duration: Double = 1.5, adjust: (inout Scenario) -> Void = { _ in },
        progress: ((String) -> Void)? = nil, inspect: (StructureSolver) -> Void = { _ in }
    ) throws -> Result {
        var scenario = scenario(test, elementSize: elementSize)
        adjust(&scenario)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // Air the wave has not reached is still, but its cells at the inlet are rewritten.
        solver.configuration.skipStillAir = false
        solver.configuration.mappedCharge = false
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        inspect(structure)
        let grid = solver.grid
        let inlet = 2
        func drive() {
            let cell = solver.cellState(inflow(test, at: Float(solver.time)))
            solver.editState { cells in
                for k in 0..<grid.nz {
                    for j in 0..<grid.ny {
                        for i in 0..<inlet { cells[grid.index(i, j, k)] = cell }
                    }
                }
            }
        }
        let h = structure.model.elementSize
        let front = upstream
        var nodes: [(i: Int, j: Int, k: Int)] = []
        for k in 0...structure.ez {
            for j in 0...structure.ey {
                for i in 0...structure.ex where structure.storedNode(i, j, k) != nil {
                    nodes.append((i, j, k))
                }
            }
        }
        var landedAt = [Float?](repeating: nil, count: nodes.count)
        var crackHeights: [Float] = []
        var checkedCracks = false
        let start = ContinuousClock.now
        var nextReport = 0.05
        drive()
        while solver.time < duration {
            let result = solver.advance(steps: 8, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            drive()
            // A node of the debris has landed when it first comes down near the ground having
            // left the wall's footprint.
            for (n, node) in nodes.enumerated() where landedAt[n] == nil {
                let p = structure.position(node.i, node.j, node.k)
                if p.z < 0.05, p.x > front + thickness + 0.05 { landedAt[n] = p.x - front }
            }
            if !checkedCracks, solver.time >= 0.05 {
                checkedCracks = true
                for k in 0..<structure.ez {
                    var open = 0
                    var count = 0
                    for j in 0..<structure.ey {
                        for i in 0..<structure.ex where structure.flag(i, j, k) != .empty {
                            count += 1
                            let planes = structure.crackPlanes(i, j, k)
                            let flag = structure.flag(i, j, k)
                            let opened = planes.normals.indices.contains { p in
                                abs(planes.normals[p].z) > 0.7 && planes.history[p] * h > 1e-3
                            }
                            if opened || flag == .eroded { open += 1 }
                        }
                    }
                    if count > 0, open * 2 >= count { crackHeights.append((Float(k) + 0.5) * h) }
                }
            }
            if let progress, solver.time >= nextReport {
                nextReport += 0.05
                progress(
                    String(
                        format: "%4.0f ms: inlet %5.1f kPa, %d elements failed", solver.time * 1000,
                        (inflow(test, at: Float(solver.time)).pressure - 101_325) / 1000,
                        structure.summary().erodedElements))
            }
        }
        let elapsed = ContinuousClock.now - start
        // Mass by distance downstream of the front face.
        let bins = 60
        var landed = [Float](repeating: 0, count: bins)
        var final = [Float](repeating: 0, count: bins)
        var total: Float = 0
        func bin(_ x: Float) -> Int { min(max(Int(x.rounded(.down)), 0), bins - 1) }
        var landedPoints: [(Float, Float)] = []
        var finalPoints: [(Float, Float)] = []
        for (n, node) in nodes.enumerated() {
            let mass = structure.node(node.i, node.j, node.k).mass
            total += mass
            let x = structure.position(node.i, node.j, node.k).x - front
            let first = landedAt[n] ?? x
            landed[bin(first)] += mass
            final[bin(x)] += mass
            landedPoints.append((first, mass))
            finalPoints.append((x, mass))
        }
        func shares(_ points: [(Float, Float)]) -> [Float] {
            test.bands.map { band in
                points.filter { band.range.contains($0.0) }.reduce(0) { $0 + $1.1 } / max(total, 1)
            }
        }
        func percentile(_ points: [(Float, Float)], _ q: Float) -> Float {
            var sum: Float = 0
            for point in points.sorted(by: { $0.0 < $1.0 }) {
                sum += point.1
                if sum >= q * total { return point.0 }
            }
            return points.map(\.0).max() ?? 0
        }
        let ambient = scenario.atmosphere.pressure
        let incident = solver.gaugeHistories.first ?? []
        var impulse: Float = 0
        for (a, b) in zip(incident, incident.dropFirst()) {
            impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
        }
        return Result(
            landedShares: shares(landedPoints), finalShares: shares(finalPoints), landed: landed,
            final: final,
            farthestLanded: percentile(landedPoints, 0.99), farthestFinal: percentile(finalPoints, 0.99),
            crackHeights: crackHeights,
            incidentPeak: (incident.map(\.pressure).max() ?? ambient) - ambient, incidentImpulse: impulse,
            reflectedPeak: ((solver.gaugeHistories.dropFirst().first ?? []).map(\.pressure).max() ?? ambient)
                - ambient,
            totalMass: total, summary: structure.summary(),
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
