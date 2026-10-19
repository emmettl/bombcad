import BlastModel
import Foundation
import Metal

final class BatchGPUProfiler {
    let device: MTLDevice
    let samples: MTLCounterSampleBuffer
    /// Whether stages within the phases get encoders of their own.
    let detailed: Bool
    /// Encoders a batch can time; those beyond are not timed.
    let capacity: Int
    var phases: [String] = []
    var clock: (cpu: MTLTimestamp, gpu: MTLTimestamp) = (0, 0)

    init(device: MTLDevice, detailed: Bool = false) throws {
        guard device.supportsCounterSampling(.atStageBoundary),
            let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue })
        else { throw BlastError.allocationFailed("GPU stage timestamp counters unavailable") }
        self.device = device
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = set
        descriptor.storageMode = .shared
        self.detailed = detailed
        // A sample buffer holds at most 32 KB, 4,096 timestamps.
        capacity = detailed ? 2048 : 6 * BlastSolver.maxStepsPerBatch + 2
        descriptor.sampleCount = 2 * capacity
        descriptor.label = "Diagnostic solver stages"
        samples = try device.makeCounterSampleBuffer(descriptor: descriptor)
    }

    func beginBatch() {
        phases = []
        clock = device.sampleTimestamps()
    }

    func encoder(command: MTLCommandBuffer, phase: String) -> MTLComputeCommandEncoder? {
        guard phases.count < capacity else {
            // Past the sample buffer's room: untimed.
            let encoder = command.makeComputeCommandEncoder()
            encoder?.label = phase
            return encoder
        }
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
                if detailed { result.stages[phase, default: 0] += elapsed }
                switch phase.split(separator: "/").first.map(String.init) ?? phase {
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
