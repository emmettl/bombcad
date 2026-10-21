import BlastCore
import BlastRender
import Foundation
import Metal
import simd

// `blastbench capture-cost`: what a timeline recorder's view field costs the GPU and the main
// thread (emmettl/bombcad-work#7 and emmettl/bombcad-work#55).

/// The street canyon on about `--cells` cells (25 million by default), stepped as the app steps it,
/// batches of about 10 ms of GPU time (at most 64 steps) with the visualisation brought up to date:
/// batches with a recorder standing, a frame every `--frame-interval` seconds (1 ms by default,
/// 240 over a quarter-second run), alternated with batches without one. Prints each kind's mean GPU
/// time a batch, the share the recorder adds, and the main thread's time reading each frame's
/// field and bodies (`--cpu-bodies` reads the original body buffers), against `--blocking` reading it with no recorder standing, as before. The run is the
/// same to the bit either way (`digest --record`).
func runCaptureCost() throws {
    let wanted = option("cells").flatMap { Double($0) } ?? 25e6
    let pairs = option("pairs").flatMap { Int($0) } ?? 60
    let interval = option("frame-interval").flatMap { Double($0) } ?? 1e-3
    let blocking = flag("blocking")
    let scenario = chosenScenario()
    let volume = Double(scenario.domainSize.x * scenario.domainSize.y * scenario.domainSize.z)
    let cellSize = Float(cbrt(volume / wanted))
    let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
    let stride = max(1, Int(cbrt(Double(solver.grid.cellCount) / Double(1 << 19)).rounded(.up)))
    func batch(steps: Int, capture: ViewFieldCapture?) throws -> Double {
        solver.viewFieldCapture = capture
        guard let buffer = solver.encodeBatch(steps: steps, updateVisualization: true) else {
            throw BlastError.allocationFailed("batch")
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        solver.completeBatch()
        return buffer.gpuEndTime - buffer.gpuStartTime
    }
    func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
    }
    // A step's GPU time once the blast has spread, for batches of about 10 ms as the app takes them.
    var warm = 0.0
    for _ in 0..<20 { warm = try batch(steps: 1, capture: nil) }
    let steps = max(1, min(64, Int((0.010 / max(warm, 1e-6)).rounded())))
    var with: [Double] = []
    var without: [Double] = []
    var reads: [Double] = []
    var next = (solver.time / interval).rounded(.down) * interval + interval
    func recorded() throws -> Double {
        let capture = blocking ? nil : ViewFieldCapture(stride: stride, from: next)
        let gpu = try batch(steps: steps, capture: capture)
        if solver.time >= next - 1e-12 {
            let start = ContinuousClock.now
            let field = try solver.viewField(stride: stride)
            _ = ViewFrame(solver: solver, field: field, useCapturedBodies: !flag("cpu-bodies"))
            reads.append(seconds(ContinuousClock.now - start))
            while next <= solver.time + 1e-12 { next += interval }
        }
        return gpu
    }
    for n in 0..<pairs {
        // Each order half the time, so that the run's changing cost falls on both alike.
        if n.isMultiple(of: 2) {
            with.append(try recorded())
            without.append(try batch(steps: steps, capture: nil))
        } else {
            without.append(try batch(steps: steps, capture: nil))
            with.append(try recorded())
        }
    }
    func mean(_ values: [Double]) -> Double { values.reduce(0, +) / Double(max(values.count, 1)) }
    let (a, b) = (mean(without), mean(with))
    let lines = [
        String(
            format:
                "%@: %.1f M cells at %.3f m, field every %d cells; batches of %d steps, %d of each, to %.1f ms",
            scenario.name, Double(solver.grid.cellCount) / 1e6, cellSize, stride, steps, pairs,
            1000 * solver.time),
        String(format: "  without a recorder: %.3f ms a batch", 1000 * a),
        String(
            format: "  %@ %.3f ms a batch (%+.2f%%); %d frames, each read in %.3f ms on the main thread",
            blocking ? "read blocking:" : "recording:   ", 1000 * b, 100 * (b - a) / a, reads.count,
            1000 * mean(reads)),
    ]
    print(lines.joined(separator: "\n"))
}
