import Foundation
import Metal
import simd

/// One of MERGE's congested rigs (Modelling and Experimental Research into Gas Explosions; Mercx
/// 1994): a cube-like lattice of pipes along all three axes, twice as wide as it is high, standing
/// on the ground, filled with a stoichiometric cloud and lit at its centre on the ground. Their
/// peak pressures (Arntzen 1998, figure 8.6; docs/congestion-model.md#merge) show the three trends
/// a congestion model must reproduce: propane about twice methane, half the pitch about seven
/// times, and twice the size 60–100% more.
public struct MergeRig: Sendable, Hashable, CaseIterable {
    public var name: String
    /// The pipes' diameter and pitch, m.
    public var diameter: Float
    public var pitch: Float
    /// The rig's width (it is square) and height, m.
    public var width: Float
    public var height: Float
    /// The peak overpressure measured in the rig, barg, with methane and with propane.
    public var methanePeak: Float
    public var propanePeak: Float

    /// Medium scale, 43 mm pipes at 0.2 m (10% by volume).
    public static let a = MergeRig(
        name: "A", diameter: 0.043, pitch: 0.2, width: 4.5, height: 2.25, methanePeak: 0.74, propanePeak: 1.77
    )
    /// Medium scale, 86 mm pipes at 0.4 m (10%).
    public static let c = MergeRig(
        name: "C", diameter: 0.086, pitch: 0.4, width: 4.5, height: 2.25, methanePeak: 0.113,
        propanePeak: 0.223)
    /// Large scale, 168 mm pipes at 0.8 m (10%): array C scaled up.
    public static let e = MergeRig(
        name: "E", diameter: 0.168, pitch: 0.8, width: 9, height: 4.5, methanePeak: 0.183, propanePeak: 0.35)
    /// Large scale, array C's 86 mm pipes at 0.4 m, twice as many across.
    public static let cStar = MergeRig(
        name: "C*", diameter: 0.086, pitch: 0.4, width: 9, height: 4.5, methanePeak: 1.04, propanePeak: 2.89)

    public static let allCases: [MergeRig] = [.a, .c, .e, .cStar]

    public func measuredPeak(_ gas: FlammableGas) -> Float { gas == .propane ? propanePeak : methanePeak }

    /// The rig's lattice, with its lower corner at `corner`.
    public func congestion(at corner: SIMD3<Float>) -> CongestionArray {
        CongestionArray(
            name: "MERGE \(name)",
            region: Box(min: corner, max: corner + SIMD3(width, width, height)), diameter: diameter,
            pitch: pitch, axes: [0, 1, 2])
    }
}

/// A MERGE rig's explosion run through the congestion model, against its measured peak.
public struct CongestedRigStudy: Sendable {
    public var rig: MergeRig
    public var gas: FlammableGas
    /// The fuel's volume fraction: MERGE's tests were a little rich (equivalence ratio 1.02–1.05).
    public var concentration: Float?
    public var cellSize: Float
    public var acceleration = FlameAcceleration()

    public init(rig: MergeRig, gas: FlammableGas, cellSize: Float, concentration: Float? = nil) {
        self.rig = rig
        self.gas = gas
        self.cellSize = cellSize
        self.concentration = concentration ?? (gas == .propane ? 0.041 : 0.098)
    }

    public struct Result: Sendable {
        /// The highest overpressure at any gauge in the rig, Pa, and where (m from the centre).
        public var peak: Float
        public var peakAt: Float
        /// Peak overpressure at each gauge, Pa, and its distance from the centre along x, m.
        public var gaugePeaks: [Float]
        public var gaugeDistances: [Float]
        /// The measured peak, Pa.
        public var measured: Float
        /// When the flame reached each gauge (its cell half burnt), s, or nil if it never did.
        public var arrivals: [Double?]
        /// The flame's fastest speed between neighbouring gauges in the rig, m/s, and as a Mach
        /// number in the ambient air (Baker–Strehlow–Tang's measure).
        public var flameSpeed: Double
        public var flameMach: Double { flameSpeed / 340.3 }
        public var burntFraction: Double
        public var duration: Double
        public var ratio: Float { peak / measured }
    }

    /// The rig's scene: the rig in the middle of a domain 2.5 times its size each way, open faces
    /// far-field, the ground reflecting; gauges on the ground from the centre out past the rig's edge.
    public func scenario() -> Scenario {
        let side = (2.5 * rig.width / cellSize).rounded(.up) * cellSize
        let top = (2.5 * rig.height / cellSize).rounded(.up) * cellSize
        let corner = SIMD3((side - rig.width) / 2, (side - rig.width) / 2, 0)
        let centre = SIMD3(side / 2, side / 2, 0.5 * cellSize)
        let half = rig.width / 2
        let distances: [Float] = [0, 0.25, 0.5, 0.75, 0.9, 1.0, 1.25, 1.5].map { $0 * half }
        var scenario = Scenario(
            name: "MERGE \(rig.name), \(gas)", domainSize: SIMD3(side, side, top), boxes: [],
            charge: Charge(mass: 0, position: centre),
            gauges: distances.map { Gauge(String(format: "%.2f m", $0), at: centre + SIMD3($0, 0, 0)) })
        scenario.deflagration = Deflagration(
            gas: gas, concentration: concentration,
            region: Box(min: corner, max: corner + SIMD3(rig.width, rig.width, rig.height)), ignition: centre,
            acceleration: acceleration)
        scenario.congestion = [rig.congestion(at: corner)]
        return scenario
    }

    public func run(
        device: MTLDevice, report: ((Double, Double, Float) -> Void)? = nil,
        monitor: ((BlastSolver) -> Void)? = nil
    ) throws -> Result {
        let scenario = scenario()
        var configuration = SolverConfiguration()
        configuration.openFaces = .farField
        let solver = try BlastSolver(
            device: device, scenario: scenario, cellSize: cellSize, configuration: configuration)
        let p0 = scenario.atmosphere.pressure
        // Until the cloud has burnt, then for the time a wave takes to cross the rig twice; every
        // quarter millisecond the flame's arrival at the gauges is noted.
        let chunk = 0.00025
        var burnt = 0.0
        let gaugeCells = scenario.gauges.map { solver.grid.cell(containing: $0.position) }
        var arrivals = [Double?](repeating: nil, count: gaugeCells.count)
        var stalled = 0
        while solver.time < 3, burnt < 0.98, stalled < 800 {
            let before = burnt
            solver.advance(until: solver.time + chunk)
            if let share = solver.unburntShare() {
                for (n, cell) in gaugeCells.enumerated() where arrivals[n] == nil {
                    if share[solver.grid.index(cell.i, cell.j, cell.k)] < 0.5 { arrivals[n] = solver.time }
                }
            }
            burnt = solver.deflagrationState()?.burntFraction ?? 0
            // Once the flame has left the rig, what is left burns slowly outside it, if at all.
            stalled = burnt - before < 1e-4 && burnt > 0.5 ? stalled + 1 : 0
            report?(
                solver.time, burnt,
                solver.gaugeHistories.map { ($0.map(\.pressure).max() ?? p0) - p0 }.max() ?? 0)
            monitor?(solver)
        }
        solver.advance(until: solver.time + Double(2 * rig.width / 340))
        let peaks = solver.gaugeHistories.map { ($0.map(\.pressure).max() ?? p0) - p0 }
        let half = rig.width / 2
        let distances: [Float] = [0, 0.25, 0.5, 0.75, 0.9, 1.0, 1.25, 1.5].map { $0 * half }
        // The gauges in the rig but outside the cell the flame is lit in, which burns almost at
        // constant volume as its kernel grows to the cell's size (MERGE's nearest gauge, 5 cm from
        // the ignition point, reads as the others do).
        let inside = peaks.indices.filter { distances[$0] <= half && distances[$0] >= cellSize }
        let best = inside.max { peaks[$0] < peaks[$1] } ?? 0
        var fastest = 0.0
        for n in 1..<distances.count where distances[n] <= half {
            if let a = arrivals[n - 1], let b = arrivals[n], b > a {
                fastest = max(fastest, Double(distances[n] - distances[n - 1]) / (b - a))
            }
        }
        return Result(
            peak: peaks[best], peakAt: distances[best], gaugePeaks: peaks, gaugeDistances: distances,
            measured: rig.measuredPeak(gas) * 1e5, arrivals: arrivals, flameSpeed: fastest,
            burntFraction: solver.deflagrationState()?.burntFraction ?? 0, duration: solver.time)
    }
}
