import Foundation
import Metal
import simd

/// The terrain's ground surface as cut cells (`SolverConfiguration.terrainCutCells`): for every
/// cell the surface crosses, the share of its volume above the surface (alpha) and of each face open
/// to the air (the apertures), worked out once, since the ground does not move. The air is then
/// updated in them as Klein, Bates and Nikiforakis's dimensionally split cut cells are (see
/// `sweepCell` in Solver.metal) with flux redistribution after each step (`redistributeCutDefects`).
///
/// In a column of a heightfield the fluid share never falls going up, so a column's cut cells
/// are one run: below it the cells are solid, above it whole. The surface's quadrature takes
/// `samples` × `samples` points over a cell's footprint (and `samples` along a face's), so the
/// shares are good to about 1 / samples²; the scheme stays conservative, and keeps air at rest at
/// rest, whatever they are, as the wall's area along each axis is the difference of the cell's two
/// apertures along it.
public struct TerrainCutGeometry: Sendable, Equatable {
    /// Per column (x fastest, nx + 1 by ny + 1, so that the domain's high faces have apertures):
    /// where its records start, its first cell of air, its first whole cell, and its first cell at
    /// least half full, which takes the rest of the smaller cells' differences.
    public var columns: [SIMD4<UInt32>]
    /// Per cut cell, from a column's first cell of air up: its fluid share and the apertures of its
    /// low x, y and z faces.
    public var records: [SIMD4<Float>]
    /// Per cut cell: the wall's unit normal, out of the air into the ground, and its area over a
    /// face's.
    public var walls: [SIMD4<Float>]
    /// The columns of the domain with cut cells.
    public var cutColumns: [UInt32]
    public var nx: Int
    public var ny: Int

    /// Cells under this share of air pass the rest of their difference to the first cell above at
    /// least this full, so that what a cell takes is at most twice its own.
    public static let receivingShare: Float = 0.5

    public func column(_ i: Int, _ j: Int) -> SIMD4<UInt32> { columns[i + (nx + 1) * j] }

    /// The fluid share of cell (i, j, k).
    public func alpha(_ i: Int, _ j: Int, _ k: Int) -> Float { record(i, j, k).x }

    /// Cell (i, j, k)'s fluid share and the apertures of its low faces: zeros below its column's
    /// cut cells, ones above.
    public func record(_ i: Int, _ j: Int, _ k: Int) -> SIMD4<Float> {
        let c = column(i, j)
        if k < Int(c.y) { return .zero }
        if k >= Int(c.z) { return .one }
        return records[Int(c.x) + k - Int(c.y)]
    }

    /// The cut cells of `terrain` on `grid`.
    public init(terrain: Terrain, grid: Grid, samples: Int = 8) {
        let dx = Double(grid.cellSize)
        nx = grid.nx
        ny = grid.ny
        let n = max(samples, 1)
        func h(_ x: Double, _ y: Double) -> Double { Double(terrain.height(at: SIMD2(Float(x), Float(y)))) }
        // The surface's lowest and highest over a footprint: at its corners, the terrain's nodes inside
        // it and where its edges cross the nodes' lines (a bilinear patch has its extremes there).
        func extremes(_ i: Int, _ j: Int) -> (low: Double, high: Double) {
            let x0 = Double(i) * dx
            let y0 = Double(j) * dx
            var xs = [x0, x0 + dx]
            var ys = [y0, y0 + dx]
            let s = Double(terrain.spacing)
            let ox = Double(terrain.origin.x)
            let oy = Double(terrain.origin.y)
            var line = ((x0 - ox) / s).rounded(.up)
            while ox + line * s < x0 + dx {
                xs.append(ox + line * s)
                line += 1
            }
            line = ((y0 - oy) / s).rounded(.up)
            while oy + line * s < y0 + dx {
                ys.append(oy + line * s)
                line += 1
            }
            var low = Double.infinity
            var high = -Double.infinity
            for x in xs {
                for y in ys {
                    let v = h(x, y)
                    low = min(low, v)
                    high = max(high, v)
                }
            }
            return (low, high)
        }
        // Midpoints of n × n (or n) equal parts.
        let offsets = (0..<n).map { (Double($0) + 0.5) / Double(n) }
        func open(_ height: Double, _ z0: Double) -> Double {
            min(max((z0 + dx - max(height, z0)) / dx, 0), 1)
        }

        var columns: [SIMD4<UInt32>] = []
        var records: [SIMD4<Float>] = []
        columns.reserveCapacity((nx + 1) * (ny + 1))
        for j in 0...ny {
            for i in 0...nx {
                let x0 = Double(i) * dx
                let y0 = Double(j) * dx
                let (low, high) = extremes(i, j)
                // Footprint heights at its quadrature points; the low x and y faces' along them.
                var foot: [Double] = []
                foot.reserveCapacity(n * n)
                for b in offsets { for a in offsets { foot.append(h(x0 + a * dx, y0 + b * dx)) } }
                let faceX = offsets.map { h(x0, y0 + $0 * dx) }
                let faceY = offsets.map { h(x0 + $0 * dx, y0) }
                var first = max(Int((low / dx).rounded(.down)), 0)
                let whole = min(max(Int((high / dx).rounded(.up)), first), grid.nz)
                var cells: [SIMD4<Float>] = []
                for k in first..<whole {
                    let z0 = Double(k) * dx
                    let alpha = foot.reduce(0) { $0 + open($1, z0) } / Double(foot.count)
                    // Fluid below this share counts as none.
                    if alpha < 1e-6 && cells.isEmpty {
                        first = k + 1
                        continue
                    }
                    let apertureX = faceX.reduce(0) { $0 + open($1, z0) } / Double(n)
                    let apertureY = faceY.reduce(0) { $0 + open($1, z0) } / Double(n)
                    let apertureZ = Double(foot.filter { $0 < z0 }.count) / Double(foot.count)
                    cells.append(
                        SIMD4(Float(max(alpha, 1e-6)), Float(apertureX), Float(apertureY), Float(apertureZ)))
                }
                let start = min(first, whole)
                columns.append(
                    SIMD4(UInt32(records.count), UInt32(start), UInt32(start + cells.count), UInt32(start)))
                records += cells
            }
        }
        self.columns = columns
        self.records = records
        self.walls = []
        self.cutColumns = []
        // A face between two cells is open only where both hold air.
        for j in 0...ny {
            for i in 0...nx {
                let c = column(i, j)
                for k in Int(c.y)..<Int(c.z) {
                    let at = Int(c.x) + k - Int(c.y)
                    if i > 0, alpha(i - 1, j, k) == 0 { self.records[at].y = 0 }
                    if j > 0, alpha(i, j - 1, k) == 0 { self.records[at].z = 0 }
                    if k == 0 || alpha(i, j, k - 1) == 0 { self.records[at].w = 0 }
                }
            }
        }
        // The walls, and for each column the cell its smaller cells pass the rest of their differences to.
        var walls = [SIMD4<Float>](repeating: SIMD4(0, 0, -1, 0), count: self.records.count)
        for j in 0...ny {
            for i in 0...nx {
                let c = column(i, j)
                for k in Int(c.y)..<Int(c.z) {
                    let own = record(i, j, k)
                    let area = SIMD3(
                        own.y - record(i + 1 > nx ? i : i + 1, j, k).y,
                        own.z - record(i, j + 1 > ny ? j : j + 1, k).z,
                        own.w - record(i, j, k + 1).w)
                    let size = simd_length(area)
                    if size > 1e-6 { walls[Int(c.x) + k - Int(c.y)] = SIMD4(area / size, size) }
                }
                var receiver = Int(c.y)
                while receiver < grid.nz, alpha(i, j, receiver) < Self.receivingShare { receiver += 1 }
                self.columns[i + (nx + 1) * j].w = UInt32(min(receiver, grid.nz - 1))
                if i < nx, j < ny, c.y < c.z { cutColumns.append(UInt32(i + (nx + 1) * j)) }
            }
        }
        self.walls = walls
    }

    /// The share of air of cell `cell` of `cellSize` over `terrain`, by `samples` × `samples` points,
    /// in single precision as a level of refinement works it out (`cutShareAt` in Refine.metal).
    public static func share(of cell: SIMD3<Int>, cellSize: Float, terrain: Terrain, samples: Int) -> Float {
        let origin = SIMD2<Float>(Float(cell.x), Float(cell.y)) * cellSize
        let z0 = Float(cell.z) * cellSize
        var sum: Float = 0
        for b in 0..<samples {
            for a in 0..<samples {
                let p = origin + (SIMD2<Float>(Float(a), Float(b)) + 0.5) / Float(samples) * cellSize
                let h = terrain.height(at: p)
                sum += min(max((z0 + cellSize - max(h, z0)) / cellSize, 0), 1)
            }
        }
        let share = sum / Float(samples * samples)
        return share < 1e-6 ? 0 : share
    }

    /// The first cell of air in each column of the domain, x fastest (cells below are solid).
    public var firstAirCells: [Int32] {
        var cells = [Int32](repeating: 0, count: nx * ny)
        for j in 0..<ny { for i in 0..<nx { cells[i + nx * j] = Int32(column(i, j).y) } }
        return cells
    }

    /// The first cell at least half air in each column of the domain, x fastest: where the
    /// surface's pressure is read, as a sliver's state is its share of what it is given.
    public var surfaceCells: [Int32] {
        var cells = [Int32](repeating: 0, count: nx * ny)
        for j in 0..<ny { for i in 0..<nx { cells[i + nx * j] = Int32(column(i, j).w) } }
        return cells
    }
}

/// The cut cells' buffers on the GPU, bound to the sweeps at 20 to 23.
final class TerrainCutBuffers {
    let geometry: TerrainCutGeometry
    let columns: MTLBuffer
    let records: MTLBuffer
    let walls: MTLBuffer
    /// Each cut cell's difference over the step so far: mass and momentum, then fuel, oxygen and energy.
    let defects: MTLBuffer
    let cutColumns: MTLBuffer

    init(geometry: TerrainCutGeometry, device: MTLDevice) throws {
        func buffer<T>(_ values: [T], _ label: String) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, 16)
            guard let made = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed(label)
            }
            values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    made.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            made.label = label
            return made
        }
        self.geometry = geometry
        columns = try buffer(geometry.columns, "cut-cell columns")
        records = try buffer(geometry.records, "cut-cell records")
        walls = try buffer(geometry.walls, "cut-cell walls")
        defects = try buffer(
            [SIMD4<Float>](repeating: .zero, count: 2 * geometry.records.count), "cut-cell differences")
        cutColumns = try buffer(geometry.cutColumns, "columns with cut cells")
    }
}
