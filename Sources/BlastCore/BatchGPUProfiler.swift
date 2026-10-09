import Foundation
import Metal

/// Diagnostic timings with additional compute-encoder boundaries. Disabled in ordinary runs.
/// Stage sums omit gaps between encoders; they are not production throughput estimates.
public struct BatchGPUProfile: Codable, Sendable {
    public var airS: Double = 0
    public var mechanicsS: Double = 0
    public var couplingS: Double = 0
    public var observationS: Double = 0
    public init() {}
}

final class BatchGPUProfiler {
    let device: MTLDevice
    let samples: MTLCounterSampleBuffer
    var phases: [String] = []
    var clock: (cpu: MTLTimestamp, gpu: MTLTimestamp) = (0, 0)

    init(device: MTLDevice) throws {
        guard device.supportsCounterSampling(.atStageBoundary),
            let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue })
        else { throw BlastError.allocationFailed("GPU stage timestamp counters unavailable") }
        self.device = device
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = set
        descriptor.storageMode = .shared
        descriptor.sampleCount = 2 * (6 * BlastSolver.maxStepsPerBatch + 2)
        descriptor.label = "Diagnostic solver stages"
        samples = try device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    func beginBatch() {
        phases = []
        clock = device.sampleTimestamps()
    }

    func encoder(command: MTLCommandBuffer, phase: String) -> MTLComputeCommandEncoder? {
        let descriptor = MTLComputePassDescriptor()
        let attachment = descriptor.sampleBufferAttachments[0]!
        attachment.sampleBuffer = samples
        attachment.startOfEncoderSampleIndex = 2 * phases.count
        attachment.endOfEncoderSampleIndex = 2 * phases.count + 1
        phases.append(phase)
        let encoder = command.makeComputeCommandEncoder(descriptor: descriptor)
        encoder?.label = phase
        return encoder
    }

    func resolve() -> BatchGPUProfile? {
        let end = device.sampleTimestamps()
        guard end.cpu > clock.cpu, end.gpu > clock.gpu,
            let data = try? samples.resolveCounterRange(0..<2 * phases.count),
            data.count == 2 * phases.count * MemoryLayout<UInt64>.stride
        else { return nil }
        // sampleTimestamps' CPU clock is in nanoseconds. Calibrate the GPU's clock per batch.
        let secondsPerTick = Double(end.cpu - clock.cpu) / Double(end.gpu - clock.gpu) * 1e-9
        return data.withUnsafeBytes { bytes in
            var result = BatchGPUProfile()
            for (index, phase) in phases.enumerated() {
                let a = bytes.loadUnaligned(fromByteOffset: 16 * index, as: UInt64.self)
                let b = bytes.loadUnaligned(fromByteOffset: 16 * index + 8, as: UInt64.self)
                guard a != UInt64.max, b != UInt64.max, b >= a else { return nil }
                let elapsed = Double(b - a) * secondsPerTick
                switch phase {
                case "air": result.airS += elapsed
                case "mechanics": result.mechanicsS += elapsed
                case "coupling": result.couplingS += elapsed
                default: result.observationS += elapsed
                }
            }
            return result
        }
    }
}
