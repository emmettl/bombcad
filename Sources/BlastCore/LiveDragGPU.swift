import BlastModel
import Foundation
import Metal
import MetalPerformanceShaders
import simd

/// The live drag's work on the GPU (emmettl/bombcad-work#112; LiveDrag.metal): each chosen
/// component's sight line, features and loads (`liveLoads`), and the learned response's networks,
/// layer by layer (`liveLayer`). The district's raster and terrain go to the GPU once, kept for as
/// long as its layout (`LoadRequest.identity`) is the one asked about; the networks' weights once.
/// In float, where the CPU's reference (`LiveResponse.CPUEngine`) is in double: the features agree
/// to float rounding, and a line passing a cell's edge can cross one cell more or fewer.
public final class LiveDragGPU: LiveResponse.Engine, @unchecked Sendable {
    /// The raster, terrain, charge and yields of a frame. Layout matches `LiveRaster` in `LiveDrag.metal`.
    struct RasterParameters {
        var origin: SIMD2<Float>
        var cell: Float
        var columns: Int32
        var rows: Int32
        var hasTerrain: Int32
        var terrainOrigin: SIMD2<Float>
        var terrainSpacing: Float
        var terrainColumns: Int32
        var terrainRows: Int32
        var itemCount: Int32
        var charge: SIMD4<Float>
        var masses: SIMD4<Float>
    }

    /// `LiveCoefficients`' floats in LiveDrag.metal, in its order: the walls' and glass's terms
    /// (`structureRise` the walls' rise), or with `roofs` the roofs' (their rise the walls' too).
    static func packed(_ c: FacadeLoadSurrogate.Coefficients, roofs: Bool) -> [Float] {
        func fourteen(_ v: [Double]) -> [Float] { (0..<14).map { $0 < v.count ? Float(v[$0]) : 0 } }
        var values = fourteen(c.peak) + fourteen(c.impulse) + fourteen(c.rise)
        values += fourteen(roofs ? c.rise : c.structureRise ?? c.rise)
        values += [Float(c.scaledRange.lowerBound), Float(c.scaledRange.upperBound)]
        if let far = c.far {
            values += [
                1, Float(far.depthFrom), Float(far.distanceFromM), Float(far.peakDepth), Float(far.peakAway),
            ]
        } else {
            values += [0, 0, 0, 0, 0]
        }
        if let close = c.closeIn, c.peak.count > 10, c.impulse.count > 10 {
            values += [1] + (0..<3).map { Float(close.peak[$0]) } + (0..<3).map { Float(close.impulse[$0]) }
            values += [
                Float(close.referenceCell), Float(close.heldWithin.lowerBound),
                Float(close.heldWithin.upperBound),
                Float(close.blendTo), close.inSightOnly == true ? 1 : 0,
            ]
            if let s = close.shielding {
                values += [1, Float(s.peak), Float(s.impulse), Float(s.openScale)]
            } else {
                values += [0, 0, 0, 0]
            }
        } else {
            values += [Float](repeating: 0, count: 12 + 4)
        }
        if !roofs, let front = c.glassFront, front.points.count <= 8 {
            values += [Float(front.points.count), Float(front.minimumMassKg)]
            values += (0..<8).flatMap {
                $0 < front.points.count ? [Float(front.points[$0].x), Float(front.points[$0].y)] : [0, 0]
            }
        } else {
            values += [Float](repeating: 0, count: 18)
        }
        // A barrier wall's own shielding (emmettl/bombcad-work#117).
        if let barrier = c.barrier {
            values += [
                1, Float(barrier.peak), Float(barrier.impulse), Float(barrier.departure),
                Float(barrier.gamma),
            ]
        } else {
            values += [0, 0, 0, 1, 0]
        }
        return values
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let loadsPipeline: MTLComputePipelineState
    private let biasPipeline: MTLComputePipelineState
    private let lock = NSLock()
    /// The district on the GPU: its raster's cells, blocks and tops, and its terrain.
    private var district:
        (identity: UUID, starts: MTLBuffer, entries: MTLBuffer, tops: MTLBuffer, heights: MTLBuffer)?
    private var scratch: [String: MTLBuffer] = [:]
    private var products: [String: MPSMatrixMultiplication] = [:]
    /// The last frame's GPU time, s.
    public private(set) var lastGPUSeconds = 0.0

    public var label: String { "GPU" }

    /// Without weights it works out the loads alone.
    public init(weights: LiveResponse.Weights?, device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw BlastError.missingShader("LiveDrag.metal")
        }
        guard
            let url = Bundle.module.url(
                forResource: "LiveDrag", withExtension: "metal", subdirectory: "Shaders")
        else { throw BlastError.missingShader("LiveDrag.metal") }
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        let library = try device.makeLibrary(
            source: try String(contentsOf: url, encoding: .utf8), options: options)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw BlastError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        loadsPipeline = try pipeline("liveLoads")
        biasPipeline = try pipeline("liveBias")
        self.device = device
        self.queue = queue
        var prepared: [String: [Layer]] = [:]
        for (name, network) in weights?.header.networks ?? [:] {
            prepared[name] = try Self.layers(network, values: weights!.values, device: device)
        }
        networks = prepared
    }

    /// A network's layer on the GPU: its weights transposed (in × out, each padded to a multiple of
    /// 4 with zeros) for MPS's matrix product, and its biases; the first layer's with the inputs'
    /// standardisation folded in.
    struct Layer {
        var inputs: Int
        var outputs: Int
        var paddedInputs: Int
        var paddedOutputs: Int
        var weights: MTLBuffer
        var biases: MTLBuffer
    }
    private let networks: [String: [Layer]]

    static func padded(_ n: Int) -> Int { (n + 3) / 4 * 4 }

    static func layers(_ network: LiveResponse.Weights.Network, values: [Float], device: MTLDevice) throws
        -> [Layer]
    {
        try network.layers.enumerated().map { l, layer in
            let (inputs, outputs) = (layer.inputs, layer.outputs)
            var w = (0..<(inputs * outputs)).map { Double(values[layer.offset + $0]) }
            var b = (0..<outputs).map { Double(values[layer.offset + inputs * outputs + $0]) }
            if l == 0 {
                // (x - mean) / std into the first layer: w / std, and b - Σ w mean / std.
                for o in 0..<outputs {
                    for k in 0..<inputs {
                        let scaled = w[o * inputs + k] / network.std[k]
                        b[o] -= scaled * network.mean[k]
                        w[o * inputs + k] = scaled
                    }
                }
            }
            let (pi, po) = (padded(inputs), padded(outputs))
            var transposed = [Float](repeating: 0, count: pi * po)
            for o in 0..<outputs {
                for k in 0..<inputs { transposed[k * po + o] = Float(w[o * inputs + k]) }
            }
            let bias = (0..<po).map { $0 < outputs ? Float(b[$0]) : 0 }
            guard
                let wb = device.makeBuffer(
                    bytes: transposed, length: 4 * transposed.count, options: .storageModeShared),
                let bb = device.makeBuffer(bytes: bias, length: 4 * bias.count, options: .storageModeShared)
            else { throw BlastError.allocationFailed("live response weights") }
            return Layer(
                inputs: inputs, outputs: outputs, paddedInputs: pi, paddedOutputs: po, weights: wb, biases: bb
            )
        }
    }

    private func buffer(_ name: String, bytes: Int) -> MTLBuffer? {
        if let known = scratch[name], known.length >= bytes { return known }
        let made = device.makeBuffer(length: max(bytes, 16) * 5 / 4, options: .storageModeShared)
        scratch[name] = made
        return made
    }

    private func upload<T>(_ name: String, _ values: [T]) -> MTLBuffer? {
        let bytes = MemoryLayout<T>.stride * values.count
        guard let b = buffer(name, bytes: bytes) else { return nil }
        values.withUnsafeBytes {
            if let base = $0.baseAddress { b.contents().copyMemory(from: base, byteCount: bytes) }
        }
        return b
    }

    private func districtBuffers(_ request: LiveResponse.LoadRequest) throws -> (
        starts: MTLBuffer, entries: MTLBuffer, tops: MTLBuffer, heights: MTLBuffer
    ) {
        if let district, district.identity == request.identity {
            return (district.starts, district.entries, district.tops, district.heights)
        }
        let raster = request.raster
        var entries = [Float]()
        entries.reserveCapacity(4 * raster.entries.count)
        for entry in raster.entries {
            entries += [entry.low, entry.high, Float(bitPattern: UInt32(bitPattern: entry.owner)), 0]
        }
        func make<T>(_ values: [T]) throws -> MTLBuffer {
            let bytes = max(MemoryLayout<T>.stride * values.count, 16)
            guard let b = device.makeBuffer(length: bytes, options: .storageModeShared) else {
                throw BlastError.allocationFailed("live drag district")
            }
            values.withUnsafeBytes {
                if let base = $0.baseAddress { b.contents().copyMemory(from: base, byteCount: $0.count) }
            }
            return b
        }
        let made = (
            identity: request.identity, starts: try make(raster.starts), entries: try make(entries),
            tops: try make(raster.tops), heights: try make(raster.terrain?.heights ?? [0])
        )
        district = made
        return (made.starts, made.entries, made.tops, made.heights)
    }

    public func loads(_ request: LiveResponse.LoadRequest) throws -> [Float] {
        try lock.withLock {
            let count = request.count
            guard count > 0 else { return [] }
            let d = try districtBuffers(request)
            let raster = request.raster
            let terrain = raster.terrain
            var parameters = RasterParameters(
                origin: raster.origin, cell: raster.cell, columns: Int32(raster.columns),
                rows: Int32(raster.rows),
                hasTerrain: terrain == nil ? 0 : 1, terrainOrigin: terrain?.origin ?? .zero,
                terrainSpacing: terrain?.spacing ?? 1, terrainColumns: Int32(terrain?.columns ?? 2),
                terrainRows: Int32(terrain?.rows ?? 2), itemCount: Int32(count),
                charge: SIMD4(request.charge, Float(request.openReachM)),
                masses: SIMD4(
                    Float(request.mass), Float(request.mass * exp(LiveResponse.slopeStep)), request.cellSize,
                    0))
            let walls = Self.packed(request.coefficients, roofs: false)
            let roofs = Self.packed(request.roofCoefficients, roofs: true)
            guard let centres = upload("centres", request.centres),
                let facings = upload("facings", request.facings),
                let owners = upload("owners", request.owners),
                let factors = upload("factors", request.factors),
                let output = buffer("loads", bytes: 4 * count * LiveResponse.itemWidth),
                let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder()
            else { throw BlastError.allocationFailed("live drag loads") }
            encoder.setComputePipelineState(loadsPipeline)
            encoder.setBytes(&parameters, length: MemoryLayout<RasterParameters>.stride, index: 0)
            encoder.setBuffer(d.heights, offset: 0, index: 1)
            encoder.setBuffer(d.starts, offset: 0, index: 2)
            encoder.setBuffer(d.entries, offset: 0, index: 3)
            encoder.setBuffer(d.tops, offset: 0, index: 4)
            encoder.setBuffer(centres, offset: 0, index: 5)
            encoder.setBuffer(facings, offset: 0, index: 6)
            encoder.setBuffer(owners, offset: 0, index: 7)
            encoder.setBuffer(factors, offset: 0, index: 8)
            walls.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 9) }
            roofs.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 10) }
            encoder.setBuffer(output, offset: 0, index: 11)
            let width = min(loadsPipeline.maxTotalThreadsPerThreadgroup, 64)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }
            lastGPUSeconds = commands.gpuEndTime - commands.gpuStartTime
            let pointer = output.contents().bindMemory(
                to: Float.self, capacity: count * LiveResponse.itemWidth)
            return Array(UnsafeBufferPointer(start: pointer, count: count * LiveResponse.itemWidth))
        }
    }

    public func run(_ name: String, rows: [Float], count: Int) throws -> [Float] {
        try lock.withLock {
            guard count > 0, let layers = networks[name], let first = layers.first, let last = layers.last
            else {
                return []
            }
            let width = first.inputs
            guard rows.count >= count * width,
                let input = buffer("\(name)-rows", bytes: 4 * count * first.paddedInputs),
                let commands = queue.makeCommandBuffer()
            else { throw BlastError.allocationFailed("live response rows") }
            // The rows, each padded to its multiple of 4.
            let pointer = input.contents().bindMemory(to: Float.self, capacity: count * first.paddedInputs)
            rows.withUnsafeBufferPointer { source in
                if first.paddedInputs == width {
                    pointer.update(from: source.baseAddress!, count: count * width)
                } else {
                    for row in 0..<count {
                        (pointer + row * first.paddedInputs).update(
                            from: source.baseAddress! + row * width, count: width)
                        for k in width..<first.paddedInputs { pointer[row * first.paddedInputs + k] = 0 }
                    }
                }
            }
            var current = input
            for (l, layer) in layers.enumerated() {
                guard let next = buffer("\(name)-layer\(l % 2)", bytes: 4 * count * layer.paddedOutputs)
                else {
                    throw BlastError.allocationFailed("live response layer")
                }
                let a = MPSMatrix(
                    buffer: current,
                    descriptor: MPSMatrixDescriptor(
                        rows: count, columns: layer.paddedInputs, rowBytes: 4 * layer.paddedInputs,
                        dataType: .float32))
                let b = MPSMatrix(
                    buffer: layer.weights,
                    descriptor: MPSMatrixDescriptor(
                        rows: layer.paddedInputs, columns: layer.paddedOutputs,
                        rowBytes: 4 * layer.paddedOutputs,
                        dataType: .float32))
                let c = MPSMatrix(
                    buffer: next,
                    descriptor: MPSMatrixDescriptor(
                        rows: count, columns: layer.paddedOutputs, rowBytes: 4 * layer.paddedOutputs,
                        dataType: .float32))
                // The products kept for each layer and row count: a drag asks for the same ones each frame.
                let key = "\(name)/\(l)/\(count)"
                let product =
                    products[key]
                    ?? MPSMatrixMultiplication(
                        device: device, transposeLeft: false, transposeRight: false, resultRows: count,
                        resultColumns: layer.paddedOutputs, interiorColumns: layer.paddedInputs, alpha: 1,
                        beta: 0)
                if products.count > 64 { products.removeAll() }
                products[key] = product
                product.encode(commandBuffer: commands, leftMatrix: a, rightMatrix: b, resultMatrix: c)
                guard let encoder = commands.makeComputeCommandEncoder() else {
                    throw BlastError.allocationFailed("live response layer")
                }
                var shape = SIMD4<Int32>(
                    Int32(count), Int32(layer.paddedOutputs), l == layers.count - 1 ? 0 : 1, 0)
                encoder.setComputePipelineState(biasPipeline)
                encoder.setBuffer(next, offset: 0, index: 0)
                encoder.setBuffer(layer.biases, offset: 0, index: 1)
                encoder.setBytes(&shape, length: MemoryLayout<SIMD4<Int32>>.stride, index: 2)
                encoder.dispatchThreads(
                    MTLSize(width: count * layer.paddedOutputs, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
                encoder.endEncoding()
                current = next
            }
            commands.commit()
            commands.waitUntilCompleted()
            if let error = commands.error { throw error }
            lastGPUSeconds = commands.gpuEndTime - commands.gpuStartTime
            let outputs = last.outputs
            let result = current.contents().bindMemory(to: Float.self, capacity: count * last.paddedOutputs)
            var values = [Float](repeating: 0, count: count * outputs)
            for row in 0..<count {
                for o in 0..<outputs { values[row * outputs + o] = result[row * last.paddedOutputs + o] }
            }
            return values
        }
    }
}
