import Foundation

/// How long the GPU has lately taken for a step, from the command buffers waited for, to size
/// the next so that it takes about `target` of the GPU's time.
package struct GPUStepRate {
    /// The GPU time a command buffer aims at by default, in seconds: `BlastSolver.commandBufferTarget`,
    /// which says why; `BOMBCAD_COMMAND_BUFFER_SECONDS` in the environment sets another.
    package static let commandBufferTarget =
        ProcessInfo.processInfo.environment["BOMBCAD_COMMAND_BUFFER_SECONDS"].flatMap(Double.init) ?? 0.075

    /// The GPU time a buffer aims at, in seconds.
    package var target = GPUStepRate.commandBufferTarget
    /// Seconds a step, smoothed over the buffers; nil until the first.
    package private(set) var seconds: Double?

    package init() {}

    /// How many of `remaining` steps the next buffer takes: at least one, and four to begin
    /// with, to measure the rate.
    package func part(_ remaining: Int) -> Int {
        guard let seconds, seconds > 0 else { return min(remaining, 4) }
        return min(max(Int(min(target / seconds, Double(Int.max / 2))), 1), remaining)
    }

    package mutating func measure(gpuSeconds: Double, steps: Int) {
        guard gpuSeconds > 0, steps > 0 else { return }
        let rate = gpuSeconds / Double(steps)
        seconds = seconds.map { 0.7 * $0 + 0.3 * rate } ?? rate
    }
}
