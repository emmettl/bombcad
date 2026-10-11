import Foundation
import Metal
import simd

/// A straight bar given as its own truss (`StructureModel.discreteBars`), instead of smeared
/// through the elements it crosses. It is cut into segments about an element long, whose nodes
/// are embedded in the elements they lie in: a node moves as its element does there, plus its
/// slip along the bar when the bars slip (`StructureModel.bondSlip`). So a bar is strained
/// where it lies, not at its elements' centres, and a crack's opening is shared along it by its
/// bond rather than smeared over a crack spacing.
public struct DiscreteBar: Sendable, Hashable, Codable {
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>
    /// In metres.
    public var diameter: Float

    public init(start: SIMD3<Float>, end: SIMD3<Float>, diameter: Float) {
        self.start = start
        self.end = end
        self.diameter = diameter
    }

    public var area: Float { .pi * diameter * diameter / 4 }
    public var length: Float { simd_length(end - start) }
}

extension StructureModel {
    /// A mat of `diameter` bars `spacing` apart along `axis`, `depth` in from each chosen face
    /// of `slab` across `thicknessAxis`, as discrete bars, the first half a spacing in from the
    /// slab's edge. The bars stop `endCover` short of the slab's ends.
    public mutating func addBarMat(
        to slab: Box, thicknessAxis: Int, along axis: Int, spacing: Float, diameter: Float, depth: Float,
        faces: (low: Bool, high: Bool) = (true, true), endCover: Float = 0.001
    ) {
        let across = 3 - thicknessAxis - axis
        var positions: [Float] = []
        var p = slab.min[across] + spacing / 2
        while p < slab.max[across] {
            positions.append(p)
            p += spacing
        }
        var heights: [Float] = []
        if faces.low { heights.append(slab.min[thicknessAxis] + depth) }
        if faces.high { heights.append(slab.max[thicknessAxis] - depth) }
        for height in heights {
            for position in positions {
                var start = SIMD3<Float>.zero
                start[thicknessAxis] = height
                start[across] = position
                var end = start
                start[axis] = slab.min[axis] + endCover
                end[axis] = slab.max[axis] - endCover
                discreteBars.append(DiscreteBar(start: start, end: end, diameter: diameter))
            }
        }
    }
}

extension StructureModel {
    /// The reinforcement layers' bars along the lattice axes as discrete bars of about `diameter`:
    /// each layer's steel along an axis as bars at the layer's mid-depth, spread evenly across its
    /// width, as many as keep their diameter nearest `diameter` while their total area is the
    /// layer's.
    public func barsFromLayers(diameter: Float) -> [DiscreteBar] {
        var bars: [DiscreteBar] = []
        let nominal = Float.pi * diameter * diameter / 4
        for layer in reinforcement {
            let extent = layer.region.max - layer.region.min
            for axis in 0..<3 where layer.ratio[axis] > 0 {
                let others = [0, 1, 2].filter { $0 != axis }
                let thickness = extent[others[0]] <= extent[others[1]] ? others[0] : others[1]
                let across = others[0] == thickness ? others[1] : others[0]
                let total = layer.ratio[axis] * extent[thickness] * extent[across]
                let count = max(1, Int((total / nominal).rounded()))
                let each = (4 * total / Float(count) / .pi).squareRoot()
                let cover = min(0.001, extent[axis] / 4)
                for n in 0..<count {
                    var start = SIMD3<Float>.zero
                    start[thickness] = (layer.region.min[thickness] + layer.region.max[thickness]) / 2
                    start[across] =
                        layer.region.min[across] + (Float(n) + 0.5) * extent[across] / Float(count)
                    var end = start
                    start[axis] = layer.region.min[axis] + cover
                    end[axis] = layer.region.max[axis] - cover
                    bars.append(DiscreteBar(start: start, end: end, diameter: each))
                }
            }
        }
        return bars
    }

    /// Every discrete bar the solver lays: those given, and the layers' when `barsAsTrusses`.
    public var allDiscreteBars: [DiscreteBar] {
        discreteBars
            + (barsAsTrusses ? barsFromLayers(diameter: trussDiameter ?? bondSlip?.barDiameter ?? 0.012) : [])
    }
}

/// The discrete bars' data on the GPU (see `DiscreteBar`), built by `StructureSolver`.
final class DiscreteBarSystem {
    /// 26 words a node: its host element's 8 node indices, their 8 shape functions, where it lies
    /// at rest, the bar's direction, the length and perimeter it stands for, and the segments
    /// before and after it (-1 for none).
    static let nodeWords = 26
    let nodes: MTLBuffer
    let segments: MTLBuffer
    let segmentState: MTLBuffer
    let histories: MTLBuffer
    let slips: MTLBuffer
    let transfer: MTLBuffer
    let gatherStart: MTLBuffer
    let gatherEntries: MTLBuffer
    /// The bond's force on each of the body's nodes, gathered each substep.
    let nodeForce: MTLBuffer
    let nodeCount: Int
    let segmentCount: Int
    /// The largest share of an element's cross-section any bar takes, for the time step.
    let densestRatio: Float
    /// Each bar's segments, as a range of segment indices.
    let segmentsOfBar: [Range<Int>]

    struct Embedding {
        var corners: [Int]
        var weights: [Float]
        var material: Int
    }

    init(
        device: MTLDevice, bars: [DiscreteBar], elementSize h: Float, bodyNodeCount: Int, crackSpacing: Float,
        embed: (SIMD3<Float>) -> Embedding?
    ) throws {
        var words: [UInt32] = []
        var segmentWords: [UInt32] = []
        var gather = [[(node: Int, weight: Float)]](repeating: [], count: bodyNodeCount)
        var densest: Float = 0
        var ranges: [Range<Int>] = []
        var nodeIndex = 0
        var segmentIndex = 0
        for (b, bar) in bars.enumerated() {
            let length = bar.length
            guard length > 0 else { throw BlastError.barOutsideConcrete(b, bar.start) }
            let count = max(1, Int((length / h).rounded(.up)))
            let axis = (bar.end - bar.start) / length
            let piece = length / Float(count)
            let first = segmentIndex
            let last = first + count - 1
            let reach = max(0, Int((crackSpacing / 2 / piece).rounded()))
            for n in 0...count {
                let point = bar.start + axis * (piece * Float(n))
                guard let embedding = embed(point) else { throw BlastError.barOutsideConcrete(b, point) }
                let previous = n > 0 ? Int32(segmentIndex - 1) : -1
                let next = n < count ? Int32(segmentIndex) : -1
                let stands = piece * (n == 0 || n == count ? 0.5 : 1)
                words += embedding.corners.map { UInt32($0) }
                words += embedding.weights.map(\.bitPattern)
                words += [point.x, point.y, point.z, axis.x, axis.y, axis.z, stands, .pi * bar.diameter].map(
                    \.bitPattern)
                words += [UInt32(bitPattern: previous), UInt32(bitPattern: next)]
                for (corner, weight) in zip(embedding.corners, embedding.weights) where weight != 0 {
                    gather[corner].append((nodeIndex, weight))
                }
                if n < count {
                    segmentWords += [
                        UInt32(nodeIndex), piece.bitPattern, bar.area.bitPattern, UInt32(embedding.material),
                        UInt32(first), UInt32(last), UInt32(reach),
                    ]
                    segmentIndex += 1
                }
                nodeIndex += 1
            }
            ranges.append(first..<segmentIndex)
            densest = max(densest, bar.area / (h * h))
        }
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            memset(buffer.contents(), 0, buffer.length)
            return buffer
        }
        nodes = try buffer(words.count * 4, "discrete bar nodes")
        nodes.copy(words)
        segments = try buffer(segmentWords.count * 4, "discrete bar segments")
        segments.copy(segmentWords)
        segmentState = try buffer(segmentIndex * 16, "discrete bar segment state")
        histories = try buffer(segmentIndex * 32, "discrete bar histories")
        slips = try buffer(nodeIndex * 16, "discrete bar slip")
        transfer = try buffer(nodeIndex * 16, "discrete bar transfer")
        var starts: [UInt32] = [0]
        var entries: [SIMD2<Float>] = []
        for list in gather {
            for entry in list { entries.append(SIMD2(Float(bitPattern: UInt32(entry.node)), entry.weight)) }
            starts.append(UInt32(entries.count))
        }
        gatherStart = try buffer(starts.count * 4, "discrete bar gather starts")
        gatherStart.copy(starts)
        gatherEntries = try buffer(entries.count * 8, "discrete bar gather")
        gatherEntries.copy(entries)
        nodeForce = try buffer(bodyNodeCount * 16, "discrete bar node forces")
        nodeCount = nodeIndex
        segmentCount = segmentIndex
        densestRatio = densest
        segmentsOfBar = ranges
    }

    func reset() {
        for buffer in [segmentState, histories, slips, transfer, nodeForce] {
            memset(buffer.contents(), 0, buffer.length)
        }
    }

    /// Segment `n`'s force (N) and plastic strain (1e9 once ruptured).
    func segment(_ n: Int) -> (force: Float, plastic: Float) {
        let state = segmentState.contents().load(fromByteOffset: n * 16, as: SIMD4<Float>.self)
        return (state.x, state.w != 0 ? 1e9 : state.y)
    }

    /// Bar node `n`'s slip along its bar, in metres.
    func slip(_ n: Int) -> Float {
        slips.contents().load(fromByteOffset: n * 16, as: SIMD4<Float>.self).x
    }
}
