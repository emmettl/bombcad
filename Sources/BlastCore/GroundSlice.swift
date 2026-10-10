import Foundation
import simd

/// The air on the ground at one moment: the bottom layer of cells over a rectangle of the grid (over
/// a terrain, each column's first cell above the surface),
/// each with its overpressure now and the peak overpressure and positive impulse it has seen so
/// far. The peak and impulse are the solver's own, kept every time step, so a consumer fed a
/// frame a millisecond does not miss a peak between frames. What a ground shock consumer needs
/// from the blast, a thin slice to stream each frame.
public struct GroundSlice: Sendable, Equatable {
    public var time: Double
    public var cellSize: Float
    /// The grid's cell count along each axis, and the first bottom cell and how many along x and
    /// y the slice holds.
    public var grid: SIMD3<Int32>
    public var first: SIMD2<Int32>
    public var counts: SIMD2<Int32>
    /// Three values a cell, x fastest: overpressure now and the peak so far, Pa, and positive
    /// impulse so far, Pa·s; NaN in all three over a solid cell.
    public var values: [Float]
    /// The still air, for the speed of a front running into it.
    public var ambientDensity: Float
    public var ambientPressure: Float
    public var gamma: Float

    public init(
        time: Double, cellSize: Float, grid: SIMD3<Int32>, first: SIMD2<Int32>, counts: SIMD2<Int32>,
        values: [Float], ambientDensity: Float, ambientPressure: Float, gamma: Float
    ) {
        precondition(values.count == 3 * Int(counts.x) * Int(counts.y))
        self.time = time
        self.cellSize = cellSize
        self.grid = grid
        self.first = first
        self.counts = counts
        self.values = values
        self.ambientDensity = ambientDensity
        self.ambientPressure = ambientPressure
        self.gamma = gamma
    }

    public struct Sample: Sendable, Equatable {
        public var overpressure: Float
        public var peak: Float
        public var impulse: Float
    }

    /// The air on the ground at `point`, interpolated between the open cells round it; nil if
    /// the point is outside the slice or every cell round it is solid.
    public func sample(_ point: SIMD2<Float>) -> Sample? {
        var low = SIMD2<Int>.zero
        var fraction = SIMD2<Float>.zero
        for axis in 0..<2 {
            let position = point[axis] / cellSize - 0.5 - Float(first[axis])
            let last = Float(counts[axis] - 1)
            // Up to half a cell past the outer centres is theirs, as is everything to the domain's
            // edge where the grid has no further cell.
            let openBelow = first[axis] == 0
            let openAbove = first[axis] + counts[axis] == grid[axis]
            guard position >= -0.5 || openBelow, position <= last + 0.5 || openAbove else { return nil }
            let clamped = min(max(position, 0), last)
            let lower = min(clamped.rounded(.down), max(last - 1, 0))
            low[axis] = Int(lower)
            fraction[axis] = clamped - lower
        }
        let nx = Int(counts.x)
        let top = SIMD2<Int>(Int(counts.x) - 1, Int(counts.y) - 1)
        var sum = SIMD3<Float>.zero
        var total: Float = 0
        var open = SIMD3<Float>.zero
        var openCount: Float = 0
        for corner in 0..<4 {
            let offset = SIMD2<Int>(corner & 1, corner >> 1)
            let weight =
                (offset.x == 1 ? fraction.x : 1 - fraction.x) * (offset.y == 1 ? fraction.y : 1 - fraction.y)
            let index = simd_min(low &+ offset, top)
            let base = 3 * (index.x + nx * index.y)
            guard !values[base].isNaN else { continue }
            let value = SIMD3(values[base], values[base + 1], values[base + 2])
            sum += weight * value
            total += weight
            open += value
            openCount += 1
        }
        guard openCount > 0 else { return nil }
        // Where the cells that would weigh most are solid, the open ones round the point, evenly.
        let mean = total > 1e-3 ? sum / total : open / openCount
        return Sample(overpressure: mean.x, peak: mean.y, impulse: mean.z)
    }
}

extension BlastSolver {
    /// The air now on the ground under the rectangle from `low` to `high`, (x, y) in metres: in
    /// each column the first cell of air above the terrain, or the bottom cell on flat ground.
    /// Reads the state and fields directly, so call it only while no batch is in flight.
    public func groundSlice(low: SIMD2<Float>, high: SIMD2<Float>) -> GroundSlice {
        let h = grid.cellSize
        let dims = SIMD2<Int32>(Int32(grid.nx), Int32(grid.ny))
        let first = simd_clamp(SIMD2<Int32>((low / h).rounded(.down)), .zero, dims &- 1)
        let last = simd_clamp(SIMD2<Int32>((high / h).rounded(.down)), first, dims &- 1)
        let counts = last &- first &+ 1
        let (nx, ny) = (Int(counts.x), Int(counts.y))
        var values = [Float](repeating: .nan, count: 3 * nx * ny)
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let ambient = configuration.ambientPressure
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        withState { cells in
            setFields { peak, impulse in
                for j in 0..<ny {
                    for i in 0..<nx {
                        let column = Int(first.x) + i + grid.nx * (Int(first.y) + j)
                        let surface = min(Int(terrainSurface?[column] ?? 0), grid.nz - 1)
                        let cell = grid.index(Int(first.x) + i, Int(first.y) + j, surface)
                        guard mask[cell] == 0 else { continue }
                        let n = 3 * (i + nx * j)
                        values[n] =
                            Self.primitive(of: cells[cell], gamma: gamma, airModel: airModel).pressure
                            - ambient
                        values[n + 1] = peak[cell]
                        values[n + 2] = impulse[cell]
                    }
                }
            }
        }
        return GroundSlice(
            time: time, cellSize: h, grid: SIMD3(Int32(grid.nx), Int32(grid.ny), Int32(grid.nz)),
            first: first,
            counts: counts, values: values, ambientDensity: ambientDensity, ambientPressure: ambient,
            gamma: gamma)
    }
}

extension GroundSlice {
    /// Everything but the values, for sending ahead of them.
    public struct Header: Codable, Sendable, Equatable {
        public var time: Double
        public var cellSize: Float
        public var grid: SIMD3<Int32>
        public var first: SIMD2<Int32>
        public var counts: SIMD2<Int32>
        public var ambientDensity: Float
        public var ambientPressure: Float
        public var gamma: Float
    }

    public var header: Header {
        Header(
            time: time, cellSize: cellSize, grid: grid, first: first, counts: counts,
            ambientDensity: ambientDensity, ambientPressure: ambientPressure, gamma: gamma)
    }

    /// The values as raw little-endian 32-bit floats.
    public var payload: Data { values.withUnsafeBytes { Data($0) } }

    public init(header: Header, payload: Data) throws {
        let count = 3 * Int(header.counts.x) * Int(header.counts.y)
        guard payload.count == 4 * count else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "A slice of the ground's air arrived cut short."])
        }
        var values = [Float](repeating: 0, count: count)
        _ = values.withUnsafeMutableBytes { payload.copyBytes(to: $0) }
        self.init(
            time: header.time, cellSize: header.cellSize, grid: header.grid, first: header.first,
            counts: header.counts, values: values, ambientDensity: header.ambientDensity,
            ambientPressure: header.ambientPressure, gamma: header.gamma)
    }
}
