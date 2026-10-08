import Foundation
import simd

/// A block of the air at one moment: density, velocity and pressure at every `stride`-th cell
/// centre over a box of the grid, in 16-bit floats. What a one-way consumer, such as
/// `FragmentCloud`, needs from the blast around it, small enough to stream each frame.
public struct AirSlice: Sendable, Equatable {
    public var time: Double
    public var cellSize: Float
    /// The grid's cell count along each axis, and the first cell and every `stride`-th after it
    /// that the slice holds, `counts` of them along each axis.
    public var grid: SIMD3<Int32>
    public var first: SIMD3<Int32>
    public var counts: SIMD3<Int32>
    public var stride: Int32
    /// Five values a sample, x fastest: density (kg/m³), velocity (m/s) and pressure, in MPa so
    /// that a charge's gigapascals fit a 16-bit float; `sample` gives it in pascals.
    public var values: [Float16]
    /// The still air around the domain and in any cell left out.
    public var ambient: Primitive

    public init(
        time: Double, cellSize: Float, grid: SIMD3<Int32>, first: SIMD3<Int32>, counts: SIMD3<Int32>,
        stride: Int32,
        values: [Float16], ambient: Primitive
    ) {
        precondition(values.count == 5 * Int(counts.x) * Int(counts.y) * Int(counts.z))
        self.time = time
        self.cellSize = cellSize
        self.grid = grid
        self.first = first
        self.counts = counts
        self.stride = stride
        self.values = values
        self.ambient = ambient
    }

    /// The box of the world the slice's samples span.
    public var bounds: Box {
        let h = cellSize
        let low = (SIMD3<Float>(first) + 0.5) * h
        let high = (SIMD3<Float>(first &+ (counts &- 1) &* stride) + 0.5) * h
        return Box(min: low, max: high)
    }

    /// The air at `point`, interpolated between samples; nil inside the domain but outside the
    /// slice, and the still ambient air outside the domain.
    public func sample(_ point: SIMD3<Float>) -> Primitive? {
        let domain = SIMD3<Float>(grid) * cellSize
        guard all(point .>= 0), all(point .<= domain) else { return ambient }
        var low = SIMD3<Int>.zero
        var fraction = SIMD3<Float>.zero
        for axis in 0..<3 {
            // Continuous index among the slice's samples along this axis.
            let position = (point[axis] / cellSize - 0.5 - Float(first[axis])) / Float(stride)
            let last = Float(counts[axis] - 1)
            // Up to half a stride past the outer samples is taken as theirs, and all the way to the
            // domain's edge where the grid has no further sample to take.
            let openBelow = first[axis] - stride < 0
            let openAbove = first[axis] + Int32(counts[axis]) * stride > grid[axis] - 1
            guard position >= -0.5 || openBelow, position <= last + 0.5 || openAbove else { return nil }
            let clamped = min(max(position, 0), last)
            let lower = min(clamped.rounded(.down), max(last - 1, 0))
            low[axis] = Int(lower)
            fraction[axis] = clamped - lower
        }
        let nx = Int(counts.x)
        let ny = Int(counts.y)
        let top = SIMD3<Int>(Int(counts.x) - 1, Int(counts.y) - 1, Int(counts.z) - 1)
        var result = [Float](repeating: 0, count: 5)
        for corner in 0..<8 {
            let offset = SIMD3<Int>(corner & 1, (corner >> 1) & 1, (corner >> 2) & 1)
            var weight: Float = 1
            for axis in 0..<3 {
                weight *= offset[axis] == 1 ? fraction[axis] : 1 - fraction[axis]
            }
            guard weight > 0 else { continue }
            let index = simd_min(low &+ offset, top)
            let base = 5 * (index.x + nx * (index.y + ny * index.z))
            for n in 0..<5 { result[n] += weight * Float(values[base + n]) }
        }
        return Primitive(
            density: result[0], velocity: SIMD3(result[1], result[2], result[3]), pressure: result[4] * 1e6)
    }

    /// The air at `point` and `time`, between two slices; nil where either has no sample.
    public static func sample(_ point: SIMD3<Float>, time: Double, between a: AirSlice, and b: AirSlice)
        -> Primitive?
    {
        guard let first = a.sample(point), let second = b.sample(point) else { return nil }
        let t = Float(b.time > a.time ? min(max((time - a.time) / (b.time - a.time), 0), 1) : 0)
        return Primitive(
            density: first.density + t * (second.density - first.density),
            velocity: first.velocity + t * (second.velocity - first.velocity),
            pressure: first.pressure + t * (second.pressure - first.pressure))
    }
}

extension BlastSolver {
    /// The air now over `region`, every `stride`-th cell. Reads the state directly, so call it
    /// only while no batch is in flight.
    public func airSlice(region: Box, stride: Int) -> AirSlice {
        let h = grid.cellSize
        let dims = SIMD3<Int32>(Int32(grid.nx), Int32(grid.ny), Int32(grid.nz))
        let stride = Int32(max(stride, 1))
        let low = simd_clamp(SIMD3<Int32>((region.min / h).rounded(.down)), .zero, dims &- 1)
        let high = simd_clamp(SIMD3<Int32>((region.max / h).rounded(.down)), low, dims &- 1)
        // Enough samples to reach past the region's far side, as far as the grid goes.
        let counts = simd_min((high &- low &+ stride &- 1) / stride &+ 1, (dims &- 1 &- low) / stride &+ 1)
        var values = [Float16](repeating: 0, count: 5 * Int(counts.x) * Int(counts.y) * Int(counts.z))
        withState { cells in
            var n = 0
            for k in 0..<Int(counts.z) {
                for j in 0..<Int(counts.y) {
                    for i in 0..<Int(counts.x) {
                        let cell = low &+ SIMD3<Int32>(Int32(i), Int32(j), Int32(k)) &* stride
                        let state = primitive(of: cells[grid.index(Int(cell.x), Int(cell.y), Int(cell.z))])
                        values[n] = Float16(state.density)
                        values[n + 1] = Float16(state.velocity.x)
                        values[n + 2] = Float16(state.velocity.y)
                        values[n + 3] = Float16(state.velocity.z)
                        values[n + 4] = Float16(state.pressure / 1e6)
                        n += 5
                    }
                }
            }
        }
        return AirSlice(
            time: time, cellSize: h, grid: dims, first: low, counts: counts, stride: stride, values: values,
            ambient: Primitive(density: ambientDensity, pressure: configuration.ambientPressure))
    }
}

extension AirSlice {
    /// Everything but the samples, for sending ahead of them.
    public struct Header: Codable, Sendable, Equatable {
        public var time: Double
        public var cellSize: Float
        public var grid: SIMD3<Int32>
        public var first: SIMD3<Int32>
        public var counts: SIMD3<Int32>
        public var stride: Int32
        public var ambientDensity: Float
        public var ambientPressure: Float
    }

    public var header: Header {
        Header(
            time: time, cellSize: cellSize, grid: grid, first: first, counts: counts, stride: stride,
            ambientDensity: ambient.density, ambientPressure: ambient.pressure)
    }

    /// The samples as raw little-endian 16-bit floats.
    public var payload: Data { values.withUnsafeBytes { Data($0) } }

    public init(header: Header, payload: Data) throws {
        let count = 5 * Int(header.counts.x) * Int(header.counts.y) * Int(header.counts.z)
        guard payload.count == 2 * count else {
            throw CocoaError(
                .coderInvalidValue, userInfo: [NSLocalizedDescriptionKey: "A slice of air arrived cut short."]
            )
        }
        var values = [Float16](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { payload.copyBytes(to: $0) }
        self.init(
            time: header.time, cellSize: header.cellSize, grid: header.grid, first: header.first,
            counts: header.counts,
            stride: header.stride, values: values,
            ambient: Primitive(density: header.ambientDensity, pressure: header.ambientPressure))
    }
}
