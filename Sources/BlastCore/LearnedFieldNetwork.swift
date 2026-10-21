import Foundation
import Metal
import MetalPerformanceShadersGraph

/// The learned field model's U-Net (Scripts/ml/train_field.py's `UNet`) on the GPU, with
/// MPSGraph: `depth` halvings, `width` channels at the top doubling at each, each level two 3 × 3
/// convolutions each followed by a group norm (8 groups) and the exact GELU, max-pooled down,
/// bilinearly upsampled (half-pixel centres, as PyTorch's `align_corners=False`) and joined to
/// the skip, then a 1 × 1 head. Only the head's first output, the log peak's correction, is
/// worked out (emmettl/bombcad-work#67). In float32, as PyTorch on the CPU, so that it matches
/// PyTorch's prediction to float rounding (`LearnedFieldNetworkTests`).
public final class LearnedFieldNetwork: LearnedField.Network, @unchecked Sendable {
    public let header: LearnedField.Weights.Header
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let weights: [String: (shape: [Int], values: [Float])]
    /// The graph for each padded plan, kept: dragging the charge asks for the same one each frame.
    private var graphs: [SIMD2<Int>: (graph: MPSGraph, input: MPSGraphTensor, output: MPSGraphTensor)] = [:]
    private let lock = NSLock()

    public init(weights: LearnedField.Weights, device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw LearnedFieldError.network("no command queue")
        }
        header = weights.header
        self.device = device
        self.queue = queue
        self.weights = weights.tensors
    }

    /// The network from its weights' file, on the system's GPU.
    public convenience init(contentsOf url: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LearnedFieldError.network("no Metal device")
        }
        try self.init(weights: LearnedField.Weights(contentsOf: url), device: device)
    }

    public func peakChannel(inputs: [Float], rows: Int, columns: Int) throws -> [Float] {
        let multiple = max(1, header.multiple)
        guard rows % multiple == 0, columns % multiple == 0, inputs.count == 6 * rows * columns else {
            throw LearnedFieldError.network("inputs of \(inputs.count) for 6 × \(rows) × \(columns)")
        }
        lock.lock()
        defer { lock.unlock() }
        let key = SIMD2(rows, columns)
        let built = graphs[key] ?? build(rows: rows, columns: columns)
        graphs[key] = built
        let shape: [NSNumber] = [1, 6, rows as NSNumber, columns as NSNumber]
        let data = inputs.withUnsafeBufferPointer { Data(buffer: $0) }
        let feed = MPSGraphTensorData(
            device: MPSGraphDevice(mtlDevice: device), data: data, shape: shape, dataType: .float32)
        let results = autoreleasepool {
            built.graph.run(
                with: queue, feeds: [built.input: feed], targetTensors: [built.output], targetOperations: nil)
        }
        guard let out = results[built.output] else { throw LearnedFieldError.network("no output") }
        var values = [Float](repeating: 0, count: rows * columns)
        values.withUnsafeMutableBytes { out.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
        return values
    }

    private func build(rows: Int, columns: Int) -> (
        graph: MPSGraph, input: MPSGraphTensor, output: MPSGraphTensor
    ) {
        let graph = MPSGraph()
        let input = graph.placeholder(
            shape: [1, 6, rows as NSNumber, columns as NSNumber], dataType: .float32, name: "inputs")
        func constant(_ name: String, shape: [Int]? = nil) -> MPSGraphTensor {
            let tensor = weights[name]!
            let data = tensor.values.withUnsafeBufferPointer { Data(buffer: $0) }
            return graph.constant(
                data, shape: (shape ?? tensor.shape).map { $0 as NSNumber }, dataType: .float32)
        }
        let convolution = MPSGraphConvolution2DOpDescriptor(
            strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1, groups: 1, paddingLeft: 1,
            paddingRight: 1, paddingTop: 1, paddingBottom: 1, paddingStyle: .explicit, dataLayout: .NCHW,
            weightsLayout: .OIHW)!
        let pointwise = MPSGraphConvolution2DOpDescriptor(
            strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1, groups: 1, paddingLeft: 0,
            paddingRight: 0, paddingTop: 0, paddingBottom: 0, paddingStyle: .explicit, dataLayout: .NCHW,
            weightsLayout: .OIHW)!
        let pool = MPSGraphPooling2DOpDescriptor(
            kernelWidth: 2, kernelHeight: 2, strideInX: 2, strideInY: 2, paddingStyle: .TF_VALID,
            dataLayout: .NCHW)!
        let groups = header.groupNormGroups
        let epsilon = Float(header.groupNormEpsilon)

        /// A 3 × 3 convolution with bias, a group norm (`gcd(8, channels)` groups) and GELU.
        func layer(_ x: MPSGraphTensor, _ prefix: String, _ conv: Int, _ norm: Int, size: (Int, Int))
            -> MPSGraphTensor
        {
            let w = weights["\(prefix).body.\(conv).weight"]!.shape
            let channels = w[0]
            var y = graph.convolution2D(
                x, weights: constant("\(prefix).body.\(conv).weight"), descriptor: convolution, name: nil)
            y = graph.addition(
                y, constant("\(prefix).body.\(conv).bias", shape: [1, channels, 1, 1]), name: nil)
            // Group norm: each group's mean and variance over its channels and the plan.
            let g = Self.gcd(groups, channels)
            let (h, wide) = size
            let grouped = graph.reshape(
                y, shape: [g as NSNumber, (channels / g) as NSNumber, h as NSNumber, wide as NSNumber],
                name: nil)
            let mean = graph.mean(of: grouped, axes: [1, 2, 3], name: nil)
            let variance = graph.variance(of: grouped, mean: mean, axes: [1, 2, 3], name: nil)
            let normal = graph.normalize(
                grouped, mean: mean, variance: variance, gamma: nil, beta: nil, epsilon: epsilon, name: nil)
            y = graph.reshape(
                normal, shape: [1, channels as NSNumber, h as NSNumber, wide as NSNumber], name: nil)
            y = graph.multiplication(
                y, constant("\(prefix).body.\(norm).weight", shape: [1, channels, 1, 1]), name: nil)
            y = graph.addition(
                y, constant("\(prefix).body.\(norm).bias", shape: [1, channels, 1, 1]), name: nil)
            // The exact GELU, x Φ(x), as PyTorch's default.
            let half = graph.constant(0.5, dataType: .float32)
            let one = graph.constant(1, dataType: .float32)
            let root = graph.constant(Double(Float(0.5).squareRoot()), dataType: .float32)
            let erf = graph.erf(with: graph.multiplication(y, root, name: nil), name: nil)
            return graph.multiplication(
                graph.multiplication(y, half, name: nil), graph.addition(erf, one, name: nil), name: nil)
        }
        func block(_ x: MPSGraphTensor, _ prefix: String, size: (Int, Int)) -> MPSGraphTensor {
            layer(layer(x, prefix, 0, 1, size: size), prefix, 3, 4, size: size)
        }

        let depth = header.depth
        var x = input
        var skips: [(MPSGraphTensor, (Int, Int))] = []
        var size = (rows, columns)
        for n in 0...depth {
            if n > 0 {
                x = graph.maxPooling2D(withSourceTensor: x, descriptor: pool, name: nil)
                size = (size.0 / 2, size.1 / 2)
            }
            x = block(x, "down.\(n)", size: size)
            skips.append((x, size))
        }
        skips.removeLast()
        for n in 0..<depth {
            let (skip, skipSize) = skips.removeLast()
            x = graph.resize(
                x, size: [skipSize.0 as NSNumber, skipSize.1 as NSNumber], mode: .bilinear,
                centerResult: true,
                alignCorners: false, layout: .NCHW, name: nil)
            x = graph.concatTensors([x, skip], dimension: 1, name: nil)
            x = block(x, "up.\(n)", size: skipSize)
        }
        // The head's first output alone.
        let head = weights["head.weight"]!
        let inner = head.shape[1]
        let first = Array(head.values[0..<inner])
        let headWeight = graph.constant(
            first.withUnsafeBufferPointer { Data(buffer: $0) }, shape: [1, inner as NSNumber, 1, 1],
            dataType: .float32)
        var output = graph.convolution2D(x, weights: headWeight, descriptor: pointwise, name: nil)
        output = graph.addition(
            output, graph.constant(Double(weights["head.bias"]!.values[0]), dataType: .float32), name: nil)
        return (graph, input, output)
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
}
