import Foundation
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            length: Float,
            side: Float,
            elementSize: Float,
            beams: Int,
            peakForce: Float,
            shorteningAtPeak: Float,
            lateral: Float,
            finalForce: Float = 0,
            euler: Float,
            squash: Float,
            history: [SIMD2<Float>],
            endNodes: Int = 0
        ) {
            self.length = length
            self.side = side
            self.elementSize = elementSize
            self.beams = beams
            self.peakForce = peakForce
            self.shorteningAtPeak = shorteningAtPeak
            self.lateral = lateral
            self.finalForce = finalForce
            self.euler = euler
            self.squash = squash
            self.history = history
            self.endNodes = endNodes
        }
    }
}
