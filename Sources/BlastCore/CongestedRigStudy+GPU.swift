import BlastModel
import Foundation
import Metal
import simd

extension CongestedRigStudy {
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
