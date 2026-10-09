import Metal
import simd

/// What the models alongside the blast will want from the air at the next frame, cut out on the
/// GPU at the end of the batch that lands on it (see `BlastSolver.frameRequest`).
public struct FrameRequest: Sendable, Equatable {
    /// The fragments' block of air: its region and stride, as `airSlice(region:stride:)` takes them.
    public var airSlice: AirSliceRequest?
    /// The fireball's luminous temperature, as `fireball(luminousTemperature:)` takes it.
    public var fireball: Float?

    public init(airSlice: AirSliceRequest? = nil, fireball: Float? = nil) {
        self.airSlice = airSlice
        self.fireball = fireball
    }

    public var isEmpty: Bool { airSlice == nil && fireball == nil }
}

public struct AirSliceRequest: Sendable, Equatable {
    public var region: Box
    public var stride: Int

    public init(region: Box, stride: Int) {
        self.region = region
        self.stride = stride
    }
}

/// Cuts the air out on the GPU for `BlastSolver`: kernels encoded at the end of each batch while a
/// request stands, which write only in a batch that reaches its time limit, and what they wrote,
/// kept for the moment that batch ended. Reading the state on the CPU between batches instead
/// leaves the GPU waiting: a few milliseconds a frame each for the fragments and the fireball on
/// the medium street grid (see docs/distributed-computing.md).
final class FrameExtractor {
    private let device: MTLDevice
    private let airPipeline: MTLComputePipelineState
    private let fireballPipeline: MTLComputePipelineState
    private var airBuffer: MTLBuffer?
    private var blocksBuffer: MTLBuffer?
    private var blockCountBuffer: MTLBuffer?
    /// What the batch in flight was asked for.
    private var encoded: (air: AirSlice.Layout?, luminous: Float?)?
    /// What the last completed batch cut out, and the moment and step it ended at; nil when
    /// nothing is ready or the state has changed since.
    private(set) var ready: (time: Double, steps: Int, air: AirSlice.Layout?, luminous: Float?)?

    init(library: MTLLibrary) throws {
        device = library.device
        airPipeline = try ShaderLibrary.pipeline("extractAirSlice", in: library)
        fireballPipeline = try ShaderLibrary.pipeline("extractFireballBlocks", in: library)
    }

    /// Encodes the request's kernels at the end of a batch, after its last step.
    func encode(
        _ encoder: MTLComputeCommandEncoder, request: FrameRequest, grid: Grid, state: MTLBuffer,
        mask: MTLBuffer, control: MTLBuffer, uniforms: SolverUniforms
    ) {
        ready = nil
        var uniforms = uniforms
        var air: AirSlice.Layout?
        if let slice = request.airSlice {
            let layout = AirSlice.layout(region: slice.region, stride: slice.stride, grid: grid)
            let bytes = 2 * 5 * layout.sampleCount
            if (airBuffer?.length ?? 0) < bytes {
                airBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
            }
            if let airBuffer {
                var corners = [
                    SIMD4<Int32>(layout.first, layout.stride), SIMD4<Int32>(layout.counts, 0),
                ]
                encoder.setComputePipelineState(airPipeline)
                encoder.setBuffer(control, offset: 0, index: 0)
                encoder.setBuffer(state, offset: 0, index: 1)
                encoder.setBuffer(airBuffer, offset: 0, index: 2)
                encoder.setBytes(&corners, length: MemoryLayout<SIMD4<Int32>>.stride * 2, index: 3)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 4)
                encoder.dispatchThreads(
                    MTLSize(
                        width: Int(layout.counts.x), height: Int(layout.counts.y), depth: Int(layout.counts.z)
                    ),
                    threadsPerThreadgroup: Self.threadgroup(airPipeline, depth: true))
                air = layout
            }
        }
        var luminous: Float?
        if var temperature = request.fireball {
            let dims = LuminousBlock.dimensions(grid)
            let bytes = 2 * MemoryLayout<SIMD4<UInt32>>.stride * dims.x * dims.y * dims.z
            if (blocksBuffer?.length ?? 0) < bytes {
                blocksBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
            }
            if blockCountBuffer == nil {
                blockCountBuffer = device.makeBuffer(
                    length: MemoryLayout<UInt32>.stride, options: .storageModeShared)
            }
            if let blocksBuffer, let blockCountBuffer {
                // No batch is in flight while this one is encoded, so nothing else reads or
                // writes the count.
                blockCountBuffer.contents().storeBytes(of: 0, as: UInt32.self)
                encoder.setComputePipelineState(fireballPipeline)
                encoder.setBuffer(control, offset: 0, index: 0)
                encoder.setBuffer(state, offset: 0, index: 1)
                encoder.setBuffer(mask, offset: 0, index: 2)
                encoder.setBuffer(blocksBuffer, offset: 0, index: 3)
                encoder.setBuffer(blockCountBuffer, offset: 0, index: 4)
                encoder.setBytes(&temperature, length: MemoryLayout<Float>.stride, index: 5)
                encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 6)
                encoder.dispatchThreads(
                    MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                    threadsPerThreadgroup: Self.threadgroup(fireballPipeline, depth: true))
                luminous = temperature
            }
        }
        encoded = air == nil && luminous == nil ? nil : (air, luminous)
    }

    /// The batch in flight has finished, at `time` after `steps` steps; what it cut out is kept
    /// if it reached its time limit.
    func complete(reachedLimit: Bool, time: Double, steps: Int) {
        if reachedLimit, let encoded {
            ready = (time, steps, encoded.air, encoded.luminous)
        } else {
            ready = nil
        }
        encoded = nil
    }

    /// The state has been changed by other means: nothing cut out is current.
    func invalidate() { ready = nil }

    /// The samples cut out for `layout` at `time` and `steps`, if they are ready.
    func airValues(_ layout: AirSlice.Layout, time: Double, steps: Int) -> [Float16]? {
        guard let ready, ready.time == time, ready.steps == steps, ready.air == layout, let airBuffer
        else { return nil }
        let count = 5 * layout.sampleCount
        let pointer = airBuffer.contents().bindMemory(to: Float16.self, capacity: count)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    /// The blocks of luminous gas cut out at `luminous` kelvin, at `time` and `steps`, if they are
    /// ready, in order of their index (see `LuminousBlock`).
    func fireballBlocks(luminous: Float, time: Double, steps: Int) -> [LuminousBlock]? {
        guard let ready, ready.time == time, ready.steps == steps, ready.luminous == luminous,
            let blocksBuffer, let blockCountBuffer
        else { return nil }
        let count = Int(blockCountBuffer.contents().load(as: UInt32.self))
        let words = blocksBuffer.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: 2 * count)
        var blocks = (0..<count).map { n in
            let (a, b) = (words[2 * n], words[2 * n + 1])
            return LuminousBlock(
                index: Int(a.x), cells: Float(bitPattern: a.y), fourth: Float(bitPattern: a.z),
                hottest: Float(bitPattern: a.w),
                position: SIMD3(Float(bitPattern: b.x), Float(bitPattern: b.y), Float(bitPattern: b.z)),
                air: Float(bitPattern: b.w))
        }
        blocks.sort { $0.index < $1.index }
        return blocks
    }

    private static func threadgroup(_ pipeline: MTLComputePipelineState, depth: Bool) -> MTLSize {
        let width = pipeline.threadExecutionWidth
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width / (depth ? 4 : 1), 1)
        return MTLSize(width: width, height: height, depth: depth ? 4 : 1)
    }
}
