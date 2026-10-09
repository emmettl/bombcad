import Foundation
import Metal
import simd

/// The visibility test on the GPU's ray-tracing hardware: the blocks and the structure's starting
/// outline in one acceleration structure, as bounding boxes, and one dispatch for all of a
/// frame's rays. The hardware finds each ray's candidate boxes and the same exact test as
/// `CPUThermalVisibility`'s decides (Thermal.metal), so the answers agree.
///
/// Other work can keep the GPU busy, the blast itself or another app. When a frame's rays have
/// not come back within a few times the usual wait, they are tested on the CPU's cores as well,
/// and whichever answer comes first is taken, as RoomCAD's wave solver moves to the CPU.
public final class MetalThermalVisibility: ThermalVisibility, @unchecked Sendable {
    /// Where the frames were tested.
    public struct Usage: Sendable, Equatable {
        public var gpuFrames = 0
        /// Frames the CPU answered first, because the GPU was slow to.
        public var cpuFrames = 0
        /// The GPU's time on the frames it answered, in seconds.
        public var gpuSeconds = 0.0
    }

    public let occluders: [Box]
    private let cpu: CPUThermalVisibility
    private let shared: Shared
    private let structure: MTLAccelerationStructure
    private let boxes: MTLBuffer
    private let lock = NSLock()
    private var buffers: Buffers?
    /// From committing a frame's rays to having them back, smoothed over the GPU's frames.
    private var typicalWait = 0.01
    private var counts = Usage()
    /// For tests: whether to hold each frame's rays back from the GPU until the CPU has answered,
    /// as a GPU kept busy by other work would, and not wait for it at all.
    var stalls: Bool {
        get { lock.withLock { stall != nil } }
        set { lock.withLock { stall = newValue ? shared.device.makeSharedEvent() : nil } }
    }
    private var stall: MTLSharedEvent?

    /// Nil where there is no GPU with ray tracing, or nothing to block the view but the ground,
    /// which the CPU tests as quickly.
    public init?(occluders: [Box]) {
        guard !occluders.isEmpty, let shared = Shared.system else { return nil }
        let device = shared.device
        // Each box a little enlarged, so that the hardware's candidates include every box the
        // exact test could find across a ray.
        let bounds = occluders.map { box -> MTLAxisAlignedBoundingBox in
            let low = simd_min(box.min, box.max)
            let high = simd_max(box.min, box.max)
            let margin = 0.001 + 1e-5 * max(simd_reduce_max(abs(low)), simd_reduce_max(abs(high)))
            return MTLAxisAlignedBoundingBox(
                min: MTLPackedFloat3Make(low.x - margin, low.y - margin, low.z - margin),
                max: MTLPackedFloat3Make(high.x + margin, high.y + margin, high.z + margin))
        }
        let stride = MemoryLayout<MTLAxisAlignedBoundingBox>.stride
        guard
            let boxes = device.makeBuffer(
                bytes: occluders, length: MemoryLayout<Box>.stride * occluders.count,
                options: .storageModeShared),
            let boundsBuffer = device.makeBuffer(
                bytes: bounds, length: stride * bounds.count, options: .storageModeShared)
        else { return nil }
        let geometry = MTLAccelerationStructureBoundingBoxGeometryDescriptor()
        geometry.boundingBoxBuffer = boundsBuffer
        geometry.boundingBoxStride = stride
        geometry.boundingBoxCount = bounds.count
        let descriptor = MTLPrimitiveAccelerationStructureDescriptor()
        descriptor.geometryDescriptors = [geometry]
        let sizes = device.accelerationStructureSizes(descriptor: descriptor)
        guard let structure = device.makeAccelerationStructure(size: sizes.accelerationStructureSize),
            let scratch = device.makeBuffer(
                length: max(sizes.buildScratchBufferSize, 16), options: .storageModePrivate),
            let commandBuffer = shared.queue.makeCommandBuffer(),
            let encoder = commandBuffer.makeAccelerationStructureCommandEncoder()
        else { return nil }
        encoder.build(
            accelerationStructure: structure, descriptor: descriptor, scratchBuffer: scratch,
            scratchBufferOffset: 0)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }
        self.occluders = occluders
        cpu = CPUThermalVisibility(occluders: occluders)
        self.shared = shared
        self.structure = structure
        self.boxes = boxes
    }

    public var usage: Usage { lock.withLock { counts } }

    public func visible(_ rays: [ThermalRay]) -> [Bool] {
        guard !rays.isEmpty else { return [] }
        return lock.withLock { test(rays) }
    }

    private func test(_ rays: [ThermalRay]) -> [Bool] {
        let pipeline = shared.pipeline
        guard let buffers = buffers(for: rays.count), let commandBuffer = shared.queue.makeCommandBuffer()
        else {
            counts.cpuFrames += 1
            return cpu.visible(rays)
        }
        if let stall {
            commandBuffer.encodeWaitForEvent(stall, value: stall.signaledValue + 1)
        }
        defer { stall.map { $0.signaledValue += 1 } }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            counts.cpuFrames += 1
            return cpu.visible(rays)
        }
        rays.withUnsafeBytes { bytes in
            // In pieces across the cores: a frame's rays are megabytes.
            let pieces = 8
            let piece = (bytes.count + pieces - 1) / pieces
            DispatchQueue.concurrentPerform(iterations: pieces) { p in
                let range = min(p * piece, bytes.count)..<min((p + 1) * piece, bytes.count)
                (buffers.rays.contents() + range.lowerBound).copyMemory(
                    from: bytes.baseAddress! + range.lowerBound, byteCount: range.count)
            }
        }
        var count = UInt32(rays.count)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffers.rays, offset: 0, index: 0)
        encoder.setBuffer(boxes, offset: 0, index: 1)
        encoder.setAccelerationStructure(structure, bufferIndex: 2)
        encoder.setBuffer(buffers.visible, offset: 0, index: 3)
        encoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 4)
        encoder.dispatchThreads(
            MTLSize(width: rays.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
        encoder.endEncoding()
        let done = DispatchSemaphore(value: 0)
        let finished = Flag()
        commandBuffer.addCompletedHandler { _ in
            finished.set()
            done.signal()
        }
        buffers.inFlight = commandBuffer
        let committed = ContinuousClock.now
        commandBuffer.commit()
        let grace = stall != nil ? 0 : min(0.05, max(0.004, 3 * typicalWait))
        if done.wait(timeout: .now() + grace) == .timedOut {
            // The GPU is slow to get to them: test them on the CPU meanwhile, and take whichever
            // answer comes first. The GPU's buffers stay its own until it is done with them.
            if let answer = cpu.visible(rays, until: { finished.isSet }) {
                counts.cpuFrames += 1
                return answer
            }
            done.wait()
        }
        guard commandBuffer.status == .completed else {
            counts.cpuFrames += 1
            return cpu.visible(rays)
        }
        let wait = (ContinuousClock.now - committed) / .seconds(1)
        typicalWait = 0.8 * typicalWait + 0.2 * wait
        counts.gpuFrames += 1
        counts.gpuSeconds += max(0, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
        return [Bool](unsafeUninitializedCapacity: rays.count) { result, initialized in
            // The kernel writes only 0 and 1, which is how a Bool is stored.
            UnsafeMutableRawPointer(result.baseAddress!).copyMemory(
                from: buffers.visible.contents(), byteCount: rays.count)
            initialized = rays.count
        }
    }

    /// Buffers for `count` rays, reused unless the GPU may still be reading the last ones.
    private func buffers(for count: Int) -> Buffers? {
        if let buffers, buffers.capacity >= count, buffers.isIdle { return buffers }
        let capacity = max(count, buffers?.capacity ?? 0)
        guard
            let rays = shared.device.makeBuffer(
                length: MemoryLayout<ThermalRay>.stride * capacity, options: .storageModeShared),
            let visible = shared.device.makeBuffer(length: capacity, options: .storageModeShared)
        else { return nil }
        let made = Buffers(rays: rays, visible: visible, capacity: capacity)
        buffers = made
        return made
    }

    private final class Buffers {
        let rays: MTLBuffer
        let visible: MTLBuffer
        let capacity: Int
        var inFlight: MTLCommandBuffer?

        init(rays: MTLBuffer, visible: MTLBuffer, capacity: Int) {
            self.rays = rays
            self.visible = visible
            self.capacity = capacity
        }

        var isIdle: Bool {
            guard let inFlight else { return true }
            return inFlight.status == .completed || inFlight.status == .error
        }
    }

    /// The device, queue and kernel, made once for every exposure.
    private final class Shared: @unchecked Sendable {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let pipeline: MTLComputePipelineState

        static let system: Shared? = try? Shared()

        private init() throws {
            guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing,
                let queue = device.makeCommandQueue()
            else { throw BlastError.missingShader("Thermal.metal") }
            guard
                let url = Bundle.module.url(
                    forResource: "Thermal", withExtension: "metal", subdirectory: "Shaders")
            else { throw BlastError.missingShader("Thermal.metal") }
            let options = MTLCompileOptions()
            // No fused or reordered arithmetic, so that the test is the CPU's.
            options.mathMode = .safe
            options.mathFloatingPointFunctions = .precise
            let library = try device.makeLibrary(
                source: try String(contentsOf: url, encoding: .utf8), options: options)
            guard let function = library.makeFunction(name: "thermalVisibility") else {
                throw BlastError.missingFunction("thermalVisibility")
            }
            self.device = device
            self.queue = queue
            pipeline = try device.makeComputePipelineState(function: function)
        }
    }
}

extension ThermalExposure {
    /// The visibility test to use: on the GPU's ray-tracing hardware where there is one,
    /// otherwise on the CPU. `BOMBCAD_THERMAL_VISIBILITY=cpu` in the environment keeps it on the
    /// CPU.
    public static func defaultVisibility(occluders: [Box]) -> any ThermalVisibility {
        if ProcessInfo.processInfo.environment["BOMBCAD_THERMAL_VISIBILITY"] != "cpu",
            let metal = MetalThermalVisibility(occluders: occluders)
        {
            return metal
        }
        return CPUThermalVisibility(occluders: occluders)
    }
}
