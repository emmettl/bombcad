import Foundation
import simd

/// A plane shock running up a planar slope: regular or Mach reflection, by the angle of the
/// triple point's path. Two set-ups of the same problem: the slope as terrain, the whole-cell
/// staircase the air sees of it, rising from flat ground (the shock-tube wedge); and, as a
/// control without the staircase, the flat ground itself with the shock tilted to meet it at the
/// slope's angle. Measured where the shock's foot has run `distance` metres along the surface.
public struct WedgeReflectionStudy: Sendable {
    public enum Surface: String, Sendable, CaseIterable {
        /// The slope as terrain, a staircase of whole cells; as terrain in cut cells; and, without
        /// either, the flat ground with the shock tilted.
        case terrain, cut, tilted

        /// The slope is terrain.
        package var isTerrain: Bool { self != .tilted }
    }

    public var shockMach: Double = 2
    /// The slope's angle to the shock's direction of travel, degrees.
    public var wedge: Double
    public var surface: Surface
    public var cellSize: Float
    /// How far along the surface the shock's foot runs before it is measured, metres.
    public var distance: Float = 1
    /// Cells across, along y; the problem is two-dimensional.
    public var width = 8
    public var configuration = SolverConfiguration()

    public init(wedge: Double, surface: Surface, cellSize: Float) {
        self.wedge = wedge
        self.surface = surface
        self.cellSize = cellSize
    }

    public struct Result: Sendable {
        public var wedge: Double
        public var surface: Surface
        public var cellSize: Float
        /// How far the foot of the shock on the surface leads where the incident shock would meet
        /// it, along the surface (zero for regular reflection), and how far it has run.
        public var lead: Double
        public var footRun: Double
        /// The triple point's trajectory angle from the surface, degrees, from the lead.
        public var chi: Double
        /// Three-shock theory's χ with a straight stem normal to the surface (nil for regular
        /// reflection).
        public var theoryChi: Double?
        /// The largest pressure on the surface behind the foot over the pressure ahead, and
        /// two-shock theory's for regular reflection (nil where it is impossible).
        public var surfacePressure: Double
        /// The median pressure over the surface just behind the foot, over the pressure ahead.
        public var surfaceMedian: Double
        public var regularPressure: Double?
        /// The terrain's incident shock as measured high above the slope, less where its speed
        /// puts it, metres.
        public var probeOffset: Double?
        public var cells: Int
        public var steps: Int
        public var seconds: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            wedge: Double,
            surface: Surface,
            cellSize: Float,
            lead: Double,
            footRun: Double,
            chi: Double,
            theoryChi: Double? = nil,
            surfacePressure: Double,
            surfaceMedian: Double,
            regularPressure: Double? = nil,
            probeOffset: Double? = nil,
            cells: Int,
            steps: Int,
            seconds: Double
        ) {
            self.wedge = wedge
            self.surface = surface
            self.cellSize = cellSize
            self.lead = lead
            self.footRun = footRun
            self.chi = chi
            self.theoryChi = theoryChi
            self.surfacePressure = surfacePressure
            self.surfaceMedian = surfaceMedian
            self.regularPressure = regularPressure
            self.probeOffset = probeOffset
            self.cells = cells
            self.steps = steps
            self.seconds = seconds
        }
    }
}
