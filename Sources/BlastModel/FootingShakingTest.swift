import Foundation
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

        package mutating func append(
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
        package func acceleration(at t: Double) -> Float {
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
            let loops = cycles.filter { $0.amplitude > 1e-3 }
            if !loops.isEmpty {
                s.cycleEnergy = loops.map(\.energy).reduce(0, +) / Float(loops.count)
                s.cycleAmplitude = loops.map(\.amplitude).reduce(0, +) / Float(loops.count)
                s.damping = loops.map(\.damping).sorted()[loops.count / 2]
            }
            return s
        }

        /// Each cycle of the moment, from one upward crossing of its median to the next: its
        /// half-range of rotation (rad), the work ∮ M dθ in it, and the equivalent damping ratio
        /// that work gives, W / (4π × ½ M₀ θ₀) with M₀ the moment's half-range.
        public var cycles: [(amplitude: Float, energy: Float, damping: Float)] {
            guard moment.count > 2 else { return [] }
            let middle = moment.sorted()[moment.count / 2]
            var starts: [Int] = []
            for i in 1..<moment.count where moment[i - 1] < middle && moment[i] >= middle {
                starts.append(i)
            }
            return zip(starts, starts.dropFirst()).map { a, b in
                var energy: Float = 0
                for i in (a + 1)...b {
                    energy += 0.5 * (moment[i] + moment[i - 1]) * (rotation[i] - rotation[i - 1])
                }
                let turn = rotation[a...b]
                let push = moment[a...b]
                let amplitude = 0.5 * (turn.max()! - turn.min()!)
                let force = 0.5 * (push.max()! - push.min()!)
                return (
                    amplitude, energy, amplitude > 0 && force > 0 ? energy / (2 * .pi * force * amplitude) : 0
                )
            }
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
        /// Over the cycles past 1 mrad: the mean work a cycle, their mean half-range of rotation
        /// (rad), and the median equivalent damping ratio.
        public var cycleEnergy: Float = 0
        public var cycleAmplitude: Float = 0
        public var damping: Float = 0

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            rotation: SIMD2<Float> = SIMD2<Float>.zero,
            residualRotation: Float = 0,
            moment: SIMD2<Float> = SIMD2<Float>.zero,
            shear: Float = 0,
            settlement: Float = 0,
            sliding: Float = 0,
            peakSliding: Float = 0,
            energy: Float = 0,
            travel: Float = 0,
            cycleEnergy: Float = 0,
            cycleAmplitude: Float = 0,
            damping: Float = 0
        ) {
            self.rotation = rotation
            self.residualRotation = residualRotation
            self.moment = moment
            self.shear = shear
            self.settlement = settlement
            self.sliding = sliding
            self.peakSliding = peakSliding
            self.energy = energy
            self.travel = travel
            self.cycleEnergy = cycleEnergy
            self.cycleAmplitude = cycleAmplitude
            self.damping = damping
        }
    }

    public struct Result: Sendable {
        public var events: [Series] = []
        /// The static pressure under the footing, P / A, once settled under gravity (Pa).
        public var pressure: Float = 0
        public var wallSeconds: Double = 0
        /// After each packet or event: how far the soil under the footing has sunk for good
        /// (m), against x along the footing, averaged across it.
        public var profiles: [[SIMD2<Float>]] = []

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            events: [Series] = [],
            pressure: Float = 0,
            wallSeconds: Double = 0,
            profiles: [[SIMD2<Float>]] = []
        ) {
            self.events = events
            self.pressure = pressure
            self.wallSeconds = wallSeconds
            self.profiles = profiles
        }
    }

    /// The wall's stem and top: the height (above the footing's top) where the top begins, the
    /// wall's height, and the two densities, for a wall of `structure`'s mass, centre and inertia
    /// with its parts on whole elements of `h`.
    package static func wallParts(_ structure: Structure, h: Float) -> (
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
}
