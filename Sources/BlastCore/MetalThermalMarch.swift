import Foundation
import Metal
import simd

/// The fireball's march on the GPU (`thermalMarch` in Thermal.metal): one threadgroup a receiver,
/// each ray followed through the medium's voxels in ordinary shader code, and the first block or
/// structure in its way found on the ray-tracing hardware in the acceleration structure the
/// visibility test built (`MetalThermalVisibility`). Unlike the visibility test, the CPU is no
/// match for it, so a busy GPU is waited for rather than raced; the CPU takes over only if the GPU
/// fails.
final class MetalThermalMarch: ThermalMarch, @unchecked Sendable {
    /// Where the frames were marched.
    struct Usage: Sendable, Equatable {
        var gpuFrames = 0
        var cpuFrames = 0
        /// The GPU's time on its frames, in seconds.
        var gpuSeconds = 0.0
    }

    private let visibility: MetalThermalVisibility
    private let cpu: CPUThermalMarch
    private let spiralBuffer: MTLBuffer
    private let samples: Int
    private let lock = NSLock()
    private var mediumBuffer: MTLBuffer?
    private var outputBuffer: MTLBuffer?
    private var counts = Usage()

    /// `visibility` lends its acceleration structure; one is built if it is not given. Nil where
    /// there is no GPU with ray tracing.
    init?(occluders: [Box], spiral: [SIMD3<Float>], visibility: MetalThermalVisibility? = nil) {
        guard let visibility = visibility ?? MetalThermalVisibility(occluders: occluders, allowingNone: true)
        else { return nil }
        let packed = spiral.flatMap { [$0.x, $0.y, $0.z] }
        guard
            let spiralBuffer = visibility.shared.device.makeBuffer(
                bytes: packed, length: MemoryLayout<Float>.stride * max(packed.count, 1),
                options: .storageModeShared)
        else { return nil }
        self.visibility = visibility
        self.spiralBuffer = spiralBuffer
        samples = spiral.count
        cpu = CPUThermalMarch(occluders: occluders, spiral: spiral)
    }

    var usage: Usage { lock.withLock { counts } }

    func irradiance(_ medium: ThermalMedium, receivers set: ThermalReceiverSet, occluded: Bool) -> [Float] {
        let count = set.receivers.count
        guard count > 0 else { return [] }
        guard !medium.tiles.isEmpty else { return [Float](repeating: 0, count: count) }
        return lock.withLock {
            if let answer = march(medium, set, occluded: occluded) {
                counts.gpuFrames += 1
                return answer
            }
            counts.cpuFrames += 1
            return cpu.irradiance(medium, receivers: set, occluded: occluded)
        }
    }

    private func march(_ medium: ThermalMedium, _ set: ThermalReceiverSet, occluded: Bool) -> [Float]? {
        let shared = visibility.shared
        let device = shared.device
        let count = set.receivers.count
        let mediumBytes = MemoryLayout<SIMD4<Float>>.stride * medium.voxels.count
        if (mediumBuffer?.length ?? 0) < mediumBytes {
            mediumBuffer = device.makeBuffer(length: mediumBytes, options: .storageModeShared)
        }
        if (outputBuffer?.length ?? 0) < 4 * count {
            outputBuffer = device.makeBuffer(length: 4 * count, options: .storageModeShared)
        }
        guard let mediumBuffer, let outputBuffer, let receivers = receiverBuffer(set, device: device),
            let commandBuffer = shared.queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return nil }
        medium.voxels.withUnsafeBytes { bytes in
            mediumBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        var tiles = medium.tiles.prefix(FireballShape.maximumTiles).flatMap {
            [$0.centre.x, $0.centre.y, $0.centre.z, $0.radius, $0.compactness]
        }
        var uniforms = MarchUniforms(
            lowX: medium.low.x, lowY: medium.low.y, lowZ: medium.low.z, voxelSize: medium.voxelSize,
            nx: UInt32(medium.counts.x), ny: UInt32(medium.counts.y), nz: UInt32(medium.counts.z),
            tileCount: UInt32(tiles.count / 5), samples: UInt32(samples), occluded: occluded ? 1 : 0,
            step: medium.step, unused: 0)
        encoder.setComputePipelineState(shared.marchPipeline)
        encoder.setBuffer(mediumBuffer, offset: 0, index: 0)
        encoder.setBytes(&tiles, length: MemoryLayout<Float>.stride * tiles.count, index: 1)
        encoder.setBuffer(receivers, offset: 0, index: 2)
        encoder.setBuffer(spiralBuffer, offset: 0, index: 3)
        encoder.setBuffer(visibility.boxes, offset: 0, index: 4)
        encoder.setAccelerationStructure(visibility.structure, bufferIndex: 5)
        encoder.setBuffer(outputBuffer, offset: 0, index: 6)
        encoder.setBytes(&uniforms, length: MemoryLayout<MarchUniforms>.stride, index: 7)
        encoder.dispatchThreadgroups(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        counts.gpuSeconds += max(0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        let output = outputBuffer.contents().bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: output, count: count))
    }

    /// The receivers' positions and normals on the GPU, made once a set.
    private func receiverBuffer(_ set: ThermalReceiverSet, device: MTLDevice) -> MTLBuffer? {
        set.lock.withLock {
            if let buffer = set.cached as? MTLBuffer, buffer.device === device { return buffer }
            let floats = set.receivers.flatMap {
                [$0.position.x, $0.position.y, $0.position.z, $0.normal.x, $0.normal.y, $0.normal.z]
            }
            let buffer = device.makeBuffer(
                bytes: floats, length: MemoryLayout<Float>.stride * floats.count, options: .storageModeShared)
            set.cached = buffer
            return buffer
        }
    }

    /// As `MarchUniforms` in Thermal.metal.
    private struct MarchUniforms {
        var lowX, lowY, lowZ, voxelSize: Float
        var nx, ny, nz, tileCount, samples, occluded: UInt32
        var step: Float
        var unused: UInt32
    }
}
