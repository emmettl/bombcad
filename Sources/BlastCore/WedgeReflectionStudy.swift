import Foundation
import Metal
import simd

/// A plane shock running up a planar slope: regular or Mach reflection, by the angle of the
/// triple point's path. Two set-ups of the same problem: the slope as terrain, the whole-cell
/// staircase the air sees of it, rising from flat ground (the shock-tube wedge); and, as a
/// control without the staircase, the flat ground itself with the shock tilted to meet it at the
/// slope's angle. Measured where the shock's foot has run `distance` metres along the surface.
public struct WedgeReflectionStudy: Sendable {
    public enum Surface: String, Sendable, CaseIterable { case terrain, tilted }

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
        public var regularPressure: Double?
        /// The terrain's incident shock as measured high above the slope, less where its speed
        /// puts it, metres.
        public var probeOffset: Double?
        public var cells: Int
        public var steps: Int
        public var seconds: Double
    }

    public func run(device: MTLDevice) throws -> Result {
        let theta = wedge * .pi / 180
        let dx = cellSize
        let ell = distance
        let ambient = (density: 1.225, pressure: 101_325.0)
        let behind = ShockReflectionTheory.behindNormalShock(
            shock: shockMach, density: ambient.density, pressure: ambient.pressure)
        let middle = Float(0.5 * (ambient.pressure + behind.pressure))
        // Where the terrain's incident shock is checked: above the triple point (χ under 20°).
        let probe = 0.4 * ell
        var scenario: Scenario
        var foot: Float
        switch surface {
        case .terrain:
            foot = 0.15 * ell
            let length = foot + ell * Float(cos(theta)) + 0.25 * ell
            let height = ell * (Float(sin(theta)) + 0.65)
            scenario = Scenario(
                name: "Wedge", domainSize: SIMD3(length, Float(width) * dx, height), boxes: [],
                charge: Charge(mass: 0, position: SIMD3(0, 0, height)))
            scenario.terrain = .slope(
                domain: scenario.domainSize, spacing: dx, foot: foot, angle: Float(wedge))
        case .tilted:
            foot = 2 * dx
            let length = foot + 1.3 * ell
            scenario = Scenario(
                name: "Tilted shock", domainSize: SIMD3(length, Float(width) * dx, ell), boxes: [],
                charge: Charge(mass: 0, position: SIMD3(0, 0, ell)))
        }
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: dx, configuration: configuration)
        let grid = solver.grid
        // The terrain's shock starts two cells before the foot, moving along x; the tilted one meets
        // the ground at the foot, its normal (cos θ, 0, −sin θ).
        let normal =
            surface == .terrain ? SIMD3<Float>(1, 0, 0) : SIMD3(Float(cos(theta)), 0, -Float(sin(theta)))
        let start = surface == .terrain ? SIMD3(foot - 2 * dx, 0, 0) : SIMD3(foot, 0, 0)
        let post = Primitive(
            density: Float(behind.density), velocity: normal * Float(behind.speed),
            pressure: Float(behind.pressure))
        let still = Primitive(density: Float(ambient.density), pressure: Float(ambient.pressure))
        solver.fill { i, j, k in
            simd_dot(grid.cellCentre(i, j, k) - start, normal) < 0 ? post : still
        }
        // Until the shock's foot, were it regular, has run `distance` along the surface.
        let footSpeed = behind.shockSpeed / (surface == .terrain ? 1 : cos(theta))
        let travel = surface == .terrain ? Double(foot - start.x) + Double(ell) * cos(theta) : Double(ell)
        let clock = Date()
        let advanced = solver.advance(until: travel / footSpeed)
        let seconds = Date().timeIntervalSince(clock)
        let j = grid.ny / 2

        /// The last place, scanning along `points` from its end, where the pressure has passed
        /// `middle`, interpolated between cells: the shock's position in `position`'s measure.
        func front(_ points: [(position: Double, pressure: Float)]) -> Double {
            for n in stride(from: points.count - 1, to: 0, by: -1) where points[n - 1].pressure >= middle {
                let (a, b) = (points[n - 1], points[n])
                guard b.pressure < middle else { return b.position }
                let f = Double((a.pressure - middle) / (a.pressure - b.pressure))
                return a.position + f * (b.position - a.position)
            }
            return points.first?.position ?? 0
        }
        var probeOffset: Double? = nil
        var surfacePoints: [(position: Double, pressure: Float)] = []
        var probePoints: [(position: Double, pressure: Float)] = []
        let surfaceCells = solver.terrainSurface
        for i in 0..<grid.nx {
            let x = Double((Float(i) + 0.5) * dx)
            let k = Int(surfaceCells?[i + grid.nx * j] ?? 0)
            guard k < grid.nz else { continue }
            if surface == .tilted || x >= Double(foot) {
                surfacePoints.append((x, solver.primitive(i, j, k).pressure))
            }
            let kp = min(Int((Float(sin(theta)) * ell + probe) / dx), grid.nz - 1)
            if surface == .terrain, !solver.isSolid(i, j, kp) {
                probePoints.append((x, solver.primitive(i, j, kp).pressure))
            }
        }
        let footX = front(surfacePoints)
        // The incident shock, undisturbed far from the surface, is where its speed puts it: the
        // terrain's plane x = incidentX; the tilted one meeting the ground at incidentX. (Measured
        // high above the terrain's slope it agrees within a fifth of a cell; the tilted shock is
        // bent near the open top, so it is not measured there.)
        let incidentX =
            surface == .terrain
            ? Double(start.x) + behind.shockSpeed * solver.time
            : Double(foot) + behind.shockSpeed * solver.time / cos(theta)
        probeOffset = surface == .terrain ? front(probePoints) - incidentX : nil
        let lead: Double
        let footRun: Double
        switch surface {
        case .terrain:
            // Along the surface, from where the plane x = incidentX meets it.
            lead = (footX - incidentX) / cos(theta)
            footRun = (footX - Double(foot)) / cos(theta)
        case .tilted:
            lead = footX - incidentX
            footRun = footX - Double(foot)
        }
        let chi = atan(max(lead, 0) / (footRun * tan(theta))) * 180 / .pi
        let peak = surfacePoints.filter { $0.position < footX }.map(\.pressure).max() ?? 0
        return Result(
            wedge: wedge, surface: surface, cellSize: dx, lead: lead, footRun: footRun, chi: chi,
            theoryChi: ShockReflectionTheory.triplePointAngle(shock: shockMach, wedge: theta).map {
                $0 * 180 / .pi
            },
            surfacePressure: Double(peak) / ambient.pressure,
            regularPressure: ShockReflectionTheory.regularReflectionPressure(shock: shockMach, wedge: theta),
            probeOffset: probeOffset,
            cells: grid.cellCount, steps: advanced.steps, seconds: seconds)
    }
}
