import Testing

@testable import BlastModel

/// How `advance` sizes its command buffers by the GPU's time, from the rates measured lately (see
/// `CommandBufferTests` in BlastCoreTests for the buffers themselves).
@Suite("Command buffers sized by the GPU's time: the rate")
struct GPUStepRateTests {
    @Test("A buffer takes the target's worth of steps at the rate measured lately, at least one")
    func sizing() {
        var rate = GPUStepRate()
        rate.target = 0.075
        #expect(rate.part(100) == 4)
        rate.measure(gpuSeconds: 0.004, steps: 4)
        #expect(rate.part(1000) == 75 && rate.part(20) == 20)
        // Smoothed: a slower buffer moves the rate a third of the way.
        rate.measure(gpuSeconds: 0.03, steps: 10)
        #expect(abs(rate.seconds! - (0.7 * 0.001 + 0.3 * 0.003)) < 1e-12)
        rate.measure(gpuSeconds: 10, steps: 1)
        #expect(rate.part(50) == 1)
        // A buffer that took no time, or no steps, tells nothing.
        let before = rate.seconds
        rate.measure(gpuSeconds: 0, steps: 5)
        rate.measure(gpuSeconds: 1, steps: 0)
        #expect(rate.seconds == before)
    }
}
