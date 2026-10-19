import Foundation
import simd

/// A precast beam's seat on a column corbel, pushed slowly to and fro along it, against measured
/// ones: N. Batalha, H. Rodrigues, A. Arêde, A. Furtado, R. Sousa and H. Varum's twelve full-scale
/// tests ("Cyclic behaviour of precast beam-to-column connections with low seismic detailing",
/// *Earthquake Eng. Struct. Dyn.*, 2022, doi:10.1002/eqe.3606; data on Mendeley Data,
/// doi:10.17632/46xpgbhsw6.1, CC BY 4.0, in `Samples/PrecastSeat`).
///
/// Each test pressed a beam end on its corbel with an axial load of 50, 100 or 150 kN and pushed
/// it along the seat in cycles of growing amplitude, to about ±48 mm, at 0.2 mm/s. The interface
/// was concrete on concrete (i0), one or two neoprene pads (i1, i2), or concrete with two dowels
/// 16 mm across 13 or 6 cm from the column's face (c1, c2). The data are the actuator's
/// displacement and force.
///
/// The model: the beam's seated end as a stiff elastic block 0.35 m square and as high, resting on
/// a bearing (a support region's connection) with the given law, for the corbel of a stiff
/// column. (On a corbel block of its own across a joint between parts, the corbel's undamped
/// ringing makes the seat stick now and then as it slides, and it dissipated 5 to 10% less.) The
/// axial load is the seat's weight. An actuator, a block beside the seat whose nodes are moved as asked, is pinned to it
/// across a gap by a second joint between parts that pushes and pulls but carries nothing along
/// it; it follows the measured displacement's reversals in turn at up to 0.25 m/s, speeding up and
/// slowing down at 2 m/s² (the law has no rate dependence), the seat damped in proportion to its
/// mass at 3,000/s so that the pin does not ring. The energy the bearing dissipates, and the force
/// at which it slides, are compared with the test's ∮ F du and its plateau.
public enum PrecastSeatTest {
    /// One test's name, as the data's files are named, and its axial load in newtons.
    public static func axialLoad(of test: String) -> Float {
        Float(test.split(separator: "_").last.flatMap { Double($0) } ?? 0) * 1000
    }

    public struct Measured: Sendable {
        /// Displacement (m) and force (N), every tenth sample of the test.
        public var samples: [SIMD2<Float>]
        /// The displacement's reversals, ignoring wiggles under 0.3 mm, in metres, and the
        /// samples they are at.
        public var reversals: [Float]
        public var reversalSamples: [Int]
        /// ∮ F du, joules, and the path's whole length, metres.
        public var energy: Float
        public var path: Float
    }

    /// Reads `test` (as `spc_i0_100`) from the folder `samples`.
    public static func measured(_ test: String, samples folder: URL) throws -> Measured {
        let text = try String(contentsOf: folder.appendingPathComponent(test + ".csv"), encoding: .utf8)
        let samples = text.split(separator: "\n").dropFirst().compactMap { line -> SIMD2<Float>? in
            let parts = line.split(separator: ",").compactMap { Float($0) }
            return parts.count == 2 ? SIMD2(parts[0] / 1000, parts[1] * 1000) : nil
        }
        var energy: Float = 0
        var path: Float = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            energy += 0.5 * (a.y + b.y) * (b.x - a.x)
            path += abs(b.x - a.x)
        }
        // Reversals: the extremes between swings of more than 0.3 mm.
        var reversals: [Float] = [0]
        var at: [Int] = [0]
        var extreme = (value: samples.first?.x ?? 0, index: 0)
        var rising = true
        for (index, sample) in samples.enumerated() {
            let d = sample.x
            if rising ? d > extreme.value : d < extreme.value {
                extreme = (d, index)
            } else if abs(d - extreme.value) > 3e-4 {
                reversals.append(extreme.value)
                at.append(extreme.index)
                rising.toggle()
                extreme = (d, index)
            }
        }
        reversals.append(extreme.value)
        at.append(extreme.index)
        return Measured(
            samples: samples, reversals: reversals, reversalSamples: at, energy: energy, path: path)
    }

    /// The force at which a test's seat slides: the median of its forces' sizes where it is 5 mm
    /// or more from the middle, in newtons.
    public static func plateau(_ samples: [SIMD2<Float>]) -> Float {
        let sliding = samples.filter { abs($0.x) >= 5e-3 }.map { abs($0.y) }.sorted()
        return sliding.isEmpty ? 0 : sliding[sliding.count / 2]
    }

    public struct Result: Sendable {
        public var test: String
        /// The force while the seat slides: the model's, the work its joint dissipated over the
        /// distance it slid; the test's, its `plateau`; in newtons. And the energy dissipated, in joules: the model's joint's own sliding work,
        /// the test's ∮ F du. (The force at any instant chatters about its mean as the seat hops
        /// on its joint, and rings on the actuator's pin, so the joint's own work is the measure.)
        public var sliding: Float = 0
        /// How far the model's seat slid along the corbel, in metres.
        public var slid: Float = 0
        public var energy: Float = 0
        public var measuredSliding: Float = 0
        public var measuredEnergy: Float = 0
        /// The largest the seat fell short of the path, in metres.
        public var lag: Float = 0
        /// (displacement, force) every 10 ms.
        public var history: [SIMD2<Float>] = []
        public var wallSeconds: Double = 0

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            test: String,
            sliding: Float = 0,
            slid: Float = 0,
            energy: Float = 0,
            measuredSliding: Float = 0,
            measuredEnergy: Float = 0,
            lag: Float = 0,
            history: [SIMD2<Float>] = [],
            wallSeconds: Double = 0
        ) {
            self.test = test
            self.sliding = sliding
            self.slid = slid
            self.energy = energy
            self.measuredSliding = measuredSliding
            self.measuredEnergy = measuredEnergy
            self.lag = lag
            self.history = history
            self.wallSeconds = wallSeconds
        }
    }
}
