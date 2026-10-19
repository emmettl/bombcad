import Foundation
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
