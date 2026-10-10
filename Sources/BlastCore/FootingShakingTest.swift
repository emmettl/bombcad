import Foundation
import Metal
import simd

/// A wall on a footing on dry sand, shaken at its base, against measured ones: S. Gajan's
/// centrifuge tests SSG04 (a surface footing) and SSG03 (the same footing set 0.7 m into the
/// sand) at UC Davis (S. Gajan and B. L. Kutter, "Capacity, settlement, and energy dissipation of
/// shallow footings subjected to rocking", J. Geotech. Geoenviron. Eng. 134(8), 2008), from the
/// FoRDy database (B. L. Kutter, A. G. Gavras and others, DesignSafe PRJ-3836,
/// doi:10.13019/3rqyd929, Open Data Commons Attribution). They are the dynamic sisters of
/// SSG02_03 (`FootingRockingTest`): the same footing, 2.8 m long along the shaking and 0.65 m
/// wide and thick, on the same Nevada sand at a relative density of 80%.
///
/// In prototype units, per footing: the database's walls stand on it, of 33.6 Mg (DSW, a pair of
/// aluminium walls joined at the top across the shaking, one footing each) or 54.8 Mg (SHW, a
/// steel wall), with the footing's 3.2 Mg their centres of mass 5.29 or 4.98 m above the base.
/// Each was shaken by a tapered sine of 12 cycles at about 1.2 Hz, at three levels (events 3, 4
/// and 5) one after the other. The measured values are the database's time histories
/// (`Samples/FoRDy`): the footing's rotation, the moment about the base centre normalized by
/// P L / 2, the shear by P, the sliding and settlement of the base centre by L.
///
/// The model: the wall as a stiff elastic block 2.8 × 0.6 m in two parts, a lighter stem and a
/// heavier top, set so that it has the database's mass, height of centre of mass and moment of
/// inertia about it; on a footing 0.65 m thick reaching 25 mm beyond it each side across, of the
/// footing's mass; frictionless bearings against its faces near the top for what kept the walls
/// upright across the shaking. The problem is solved in the ground's frame, every node and the
/// footing pulled by −m a for the measured base acceleration (`StructureSolver.groundAcceleration`).
/// The soil is the footing's half-space with a bearing capacity, as in the slow test.
public enum FootingShakingTest {
    /// The structure on one footing.
    public struct Structure: Sendable {
        public var name: String
        /// The wall's mass (kg), its centre of mass above the footing's base (m) and its moment of
        /// inertia about that, in the plane of the shaking (kg m²).
        public var wallMass: Float
        public var wallCentre: Float
        public var wallInertia: Float
        /// How deep the footing's base is set into the sand, in metres.
        public var embedment: Float
    }

    public static let dsw = Structure(
        name: "DSW", wallMass: 33_600, wallCentre: 5.76, wallInertia: 143_200, embedment: 0)
    public static let shw = Structure(
        name: "SHW", wallMass: 54_800, wallCentre: 5.26, wallInertia: 385_000, embedment: 0)
    public static let embeddedDSW = Structure(
        name: "DSW, embedded", wallMass: 33_600, wallCentre: 5.76, wallInertia: 143_200, embedment: 0.7)

    public static let length: Float = 2.8
    public static let width: Float = 0.65
    public static let thickness: Float = 0.65
    public static let footingMass: Float = 3_200
    public static let bearingCapacity: Float = 814e3
    /// The sand's peak friction angle, back-calculated from vertical bearing tests on it.
    public static let frictionAngle: Float = 42 * .pi / 180

    /// A test's sequence of shakes on one structure.
    public struct Test: Sendable {
        public var name: String
        public var structure: Structure
        public var events: [String]
    }

    public static let tests: [Test] = [
        Test(name: "ssg04-dsw", structure: dsw, events: ["SSG04-1-DSW-3", "SSG04-1-DSW-4", "SSG04-1-DSW-5"]),
        Test(name: "ssg04-shw", structure: shw, events: ["SSG04-1-SHW-3", "SSG04-1-SHW-4"]),
        Test(
            name: "ssg03-dsw", structure: embeddedDSW,
            events: ["SSG03-1-DSW-3", "SSG03-1-DSW-4", "SSG03-1-DSW-5"]),
    ]

    /// A time history, measured or modelled: time (s), the base's acceleration (g), the footing's
    /// rotation (rad), moment / (P L / 2), shear / P, sliding / L and settlement / L.
    public struct Series: Sendable {
        public var time: [Float] = []
        public var base: [Float] = []
        public var rotation: [Float] = []
        public var moment: [Float] = []
        public var shear: [Float] = []
        public var sliding: [Float] = []
        public var settlement: [Float] = []

        public init() {}

        mutating func append(
            _ t: Float, _ a: Float, _ r: Float, _ m: Float, _ v: Float, _ u: Float, _ s: Float
        ) {
            time.append(t)
            base.append(a)
            rotation.append(r)
            moment.append(m)
            shear.append(v)
            sliding.append(u)
            settlement.append(s)
        }

        /// Reads one of `Samples/FoRDy`'s files.
        public static func load(_ url: URL) throws -> Series {
            let text = try String(contentsOf: url, encoding: .utf8)
            var series = Series()
            for line in text.split(separator: "\n").dropFirst() {
                let v = line.split(separator: ",").compactMap { Float($0) }
                guard v.count == 7 else { continue }
                series.append(v[0], v[1], v[2], v[3], v[4], v[5], v[6])
            }
            guard series.time.count > 10 else {
                throw ImportedMesh.ImportError.invalid("\(url.lastPathComponent) holds no time history.")
            }
            return series
        }

        /// The base's acceleration (g) at `t`, linearly between samples, zero outside.
        func acceleration(at t: Double) -> Float {
            guard let first = time.first, let last = time.last, t >= Double(first), t <= Double(last) else {
                return 0
            }
            let step = Double(last - first) / Double(time.count - 1)
            let at = (t - Double(first)) / step
            let i = min(Int(at), time.count - 2)
            let f = Float(at - Double(i))
            return base[i] + (base[i + 1] - base[i]) * f
        }

        /// The response summed up as the database does.
        public var summary: Summary {
            var s = Summary()
            guard let r0 = rotation.first, let s0 = settlement.first, let u0 = sliding.first else { return s }
            s.rotation = SIMD2(rotation.max()!, rotation.min()!)
            s.residualRotation = rotation.last! - r0
            s.moment = SIMD2(moment.max()!, moment.min()!)
            s.shear = shear.map(abs).max()!
            s.settlement = settlement.last! - s0
            s.sliding = sliding.last! - u0
            s.peakSliding = sliding.map { abs($0 - u0) }.max()!
            for i in 1..<rotation.count {
                let turn = rotation[i] - rotation[i - 1]
                s.energy += 0.5 * (moment[i] + moment[i - 1]) * turn
                s.travel += abs(turn)
            }
            return s
        }
    }

    public struct Summary: Sendable {
        /// Largest rotation each way (rad), and its change over the event.
        public var rotation = SIMD2<Float>.zero
        public var residualRotation: Float = 0
        /// Largest moment / (P L / 2) each way, and largest shear / P.
        public var moment = SIMD2<Float>.zero
        public var shear: Float = 0
        /// Settlement / L over the event, and the change in sliding / L and its largest.
        public var settlement: Float = 0
        public var sliding: Float = 0
        public var peakSliding: Float = 0
        /// The work the moment did on the footing's rotation, ∫ M dθ / (P L / 2), in radians; and
        /// the rotation's whole travel, ∫ |dθ|.
        public var energy: Float = 0
        public var travel: Float = 0
    }

    public struct Result: Sendable {
        public var events: [Series] = []
        /// The static pressure under the footing, P / A, once settled under gravity (Pa).
        public var pressure: Float = 0
        public var wallSeconds: Double = 0
    }

    /// The wall's stem and top: the height (above the footing's top) where the top begins, the
    /// wall's height, and the two densities, for a wall of `structure`'s mass, centre and inertia
    /// with its parts on whole elements of `h`.
    static func wallParts(_ structure: Structure, h: Float) -> (
        split: Float, height: Float, densities: SIMD2<Float>
    ) {
        let area = length * 0.6
        let centre = structure.wallCentre - thickness
        var best: (Float, Float, SIMD2<Float>, Float) = (0, 0, .zero, .infinity)
        for top in stride(from: 4 * h, through: 20, by: h) {
            for split in stride(from: h, to: top - h / 2, by: h) {
                let (c1, c2) = (split / 2, (split + top) / 2)
                guard c2 > centre, c1 < centre else { continue }
                let m2 = structure.wallMass * (centre - c1) / (c2 - c1)
                let m1 = structure.wallMass - m2
                let (rho1, rho2) = (m1 / (area * split), m2 / (area * (top - split)))
                // A stem no lighter than a fifth of the top, so that it stays stiff and its
                // waves do not shorten the step much.
                guard rho1 >= 0.2 * rho2, rho1 <= rho2 else { continue }
                func inertia(_ m: Float, _ height: Float, _ c: Float) -> Float {
                    m * (height * height + length * length) / 12 + m * (c - centre) * (c - centre)
                }
                let total = inertia(m1, split, c1) + inertia(m2, top - split, c2)
                let miss = abs(total - structure.wallInertia)
                if miss < best.3 { best = (split, top, SIMD2(rho1, rho2), miss) }
            }
        }
        return (best.0, best.1, best.2)
    }

    /// Shakes `test`'s structure through its events one after another, a second's rest between,
    /// on sand of `shearModulus`; the base's acceleration is set every `interval` seconds.
    public static func run(
        device: MTLDevice, test: Test, series: [Series], shearModulus: Float = 80e6,
        bearingCapacity: Float = Self.bearingCapacity, friction: Float = 0.6, damping: Float = 0.2,
        cyclic: CyclicSand? = CyclicSand(), interval: Double = 1e-3, progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let started = ContinuousClock.now
        let h: Float = 0.2
        let parts = wallParts(test.structure, h: h)
        let stem = Box(min: .zero, max: SIMD3(length, 0.6, parts.split))
        let top = Box(min: SIMD3(0, 0, parts.split), max: SIMD3(length, 0.6, parts.height))
        // Both parts as stiff as each other, so that the wall bends as one.
        func material(_ density: Float) -> StructureMaterial {
            .elastic(density: density, youngsModulus: 10e9, poissonRatio: 0.2)
        }
        var model = StructureModel(
            solids: [stem, top], material: material(parts.densities.x), elementSize: h, fixedBase: true)
        model.setMaterial(material(parts.densities.y), of: 1)
        var joint = Anchorage(
            tensileStrength: 1e9, tensionOpening: 1, cohesion: 1e9, cohesionSlip: 1, friction: 1)
        var soil = Soil(
            material: SoilMaterial(shearModulus: shearModulus, poissonRatio: 0.3, density: 1657),
            bearingCapacity: bearingCapacity, friction: friction)
        soil.cyclic = cyclic
        joint.footing = Footing(
            overhang: SIMD2(0, (width - 0.6) / 2), thickness: thickness,
            density: footingMass / (length * width * thickness), soil: soil,
            embedment: test.structure.embedment > 0
                ? Embedment(depth: test.structure.embedment, frictionAngle: frictionAngle) : nil)
        model.baseAnchorage = joint
        // What kept the walls upright across the shaking: bearings against both faces over the
        // top 2 m, without friction or tie.
        for side in [JointSide.negativeY, .positiveY] {
            let y: Float = side == .negativeY ? 0 : 0.6
            model.supports.append(
                Box(
                    min: SIMD3(-0.01, y - 0.01, parts.height - 2.01),
                    max: SIMD3(length + 0.01, y + 0.01, parts.height + 0.01)))
            var guide = Anchorage.resting(friction: 0)
            guide.side = side
            model.supportAnchorages.append(guide)
        }
        let solver = try StructureSolver(device: device, model: model)
        let weight = (test.structure.wallMass + footingMass) * solver.gravity

        // Settle under gravity.
        solver.damping = 200
        solver.advance(steps: Int((0.5 / Double(solver.criticalTimeStep)).rounded()))
        solver.damping = damping
        guard let rest = solver.footingSummaries().first else {
            throw ImportedMesh.ImportError.invalid("The shaken wall has no footing.")
        }
        var result = Result()
        result.pressure = rest.soilForce.z / (length * width)
        let steps = max(1, Int((interval / Double(solver.criticalTimeStep)).rounded()))
        for (name, record) in zip(test.events, series) {
            var modelled = Series()
            let end = Double(record.time.last!) + 1
            var time = Double(record.time.first!)
            var lastSample = -1.0
            while time < end {
                let a = record.acceleration(at: time + interval / 2)
                solver.groundAcceleration = SIMD3(a * solver.gravity, 0, 0)
                solver.advance(steps: steps)
                time += interval
                guard time - lastSample >= 0.01 - 1e-9, let footing = solver.footingSummaries().first else {
                    continue
                }
                lastSample = time
                modelled.append(
                    Float(time), a, footing.rotation.y, -footing.soilMoment.y * 2 / (length * weight),
                    -footing.soilForce.x / weight, (footing.displacement.x - rest.displacement.x) / length,
                    -(footing.displacement.z - rest.displacement.z) / length)
            }
            solver.groundAcceleration = .zero
            result.events.append(modelled)
            let s = modelled.summary
            progress?(
                String(
                    format:
                        "%@: rotation %+.4f / %+.4f rad, moment %.3f / %.3f, settlement %.4f L, energy %.4f",
                    name, s.rotation.x, s.rotation.y, s.moment.x, s.moment.y, s.settlement, s.energy))
        }
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
