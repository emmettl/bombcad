import Foundation
import Metal
import simd

/// A region of obstacles smaller than the air's cells: a regular array of pipes (or square bars)
/// running along one or more axes, `diameter` across, `pitch` apart, as a pipe rack's tiers or a
/// test rig's lattice are. The air does not resolve them; it flows through the region as through a
/// porous medium that takes room, resists the flow and (with the congestion model's turbulence)
/// stirs it (docs/congestion-model.md). Obstacles a cell or more across belong in the scene as
/// blocks, which the air resolves.
public struct CongestionArray: Codable, Hashable, Sendable {
    public enum Shape: String, Codable, Sendable, CaseIterable {
        case cylinder
        case box
    }

    public var name: String
    /// Where the obstacles are, filled uniformly.
    public var region: Box
    /// The pipes' diameter, or the bars' width, m.
    public var diameter: Float
    /// Centre-to-centre spacing, m, in both directions across each set of pipes.
    public var pitch: Float
    /// The axes the pipes run along (0 x, 1 y, 2 z): one for a rack's tiers, three for a lattice.
    public var axes: [Int]
    public var shape: Shape

    public init(
        name: String = "Congestion", region: Box, diameter: Float, pitch: Float, axes: [Int],
        shape: Shape = .cylinder
    ) {
        self.name = name
        self.region = region
        self.diameter = diameter
        self.pitch = pitch
        self.axes = axes
        self.shape = shape
    }

    /// One pipe's cross-section, m².
    public var section: Float { shape == .cylinder ? .pi * diameter * diameter / 4 : diameter * diameter }
    /// One pipe's surface per unit length, m.
    public var perimeter: Float { shape == .cylinder ? .pi * diameter : 4 * diameter }
    /// Drag coefficient of one pipe across the flow (a long cylinder or square bar in subcritical
    /// cross flow).
    public var dragCoefficient: Float { shape == .cylinder ? 1.2 : 2.0 }
    /// The share of the region's volume the pipes along each axis fill: a cross-section every
    /// pitch², so the volume blockage ratio (VBR) is their sum over `axes`.
    public var volumeBlockage: Float { Float(Set(axes).count) * section / (pitch * pitch) }
    /// The pipes' frontal area per volume, m⁻¹, across a flow along `axis`: those along the other
    /// axes, `diameter` wide every pitch².
    public func frontalArea(across axis: Int) -> Float {
        Float(Set(axes).filter { $0 != axis }.count) * diameter / (pitch * pitch)
    }
    /// The pipes' surface per volume, m⁻¹.
    public var wallArea: Float { Float(Set(axes).count) * perimeter / (pitch * pitch) }

    /// The share of a row's width its pipes block, across a flow along `axis`, as PDRFoam's
    /// PDRsetFields idealises a cell's obstacles: their area blockage over the square root of their
    /// count (`calc_drag_etc`), here (crossing sets) D / (√(sets) p) for a uniform array.
    public func rowBlockage(across axis: Int) -> Float {
        let sets = Set(axes)
        let crossing = Float(sets.filter { $0 != axis }.count)
        return min(crossing * diameter / (Float(sets.count).squareRoot() * pitch), 0.99)
    }

    /// The correction to a row's drag for its blockage b (`rowBlockage`), (1 − ½b)/(1 − b)², as
    /// PDRsetFields applies it inside a uniform array (α^(0.5+0.5·expon) for round obstacles, expon 1
    /// where the neighbouring cells are as blocked, and α^1.09 for sharp-edged ones).
    public func rowBlockageFactor(across axis: Int) -> Float {
        let b = rowBlockage(across: axis)
        let alpha = (1 - 0.5 * b) / ((1 - b) * (1 - b))
        return shape == .cylinder ? alpha : pow(alpha, 1.09)
    }

    /// PDRFoam's drag CR across a flow along `axis`, m⁻¹: C_D × frontal area per volume × the row's
    /// blockage factor.
    public func drag(across axis: Int) -> Float {
        dragCoefficient * rowBlockageFactor(across: axis) * frontalArea(across: axis)
    }

    /// PDRFoam's turbulence generation CT across a flow along `axis`, m⁻¹: its C_b (0.035 for round
    /// obstacles, 0.08 for sharp-edged) times their drag.
    public func turbulenceGeneration(across axis: Int) -> Float {
        (shape == .cylinder ? 0.035 : 0.08) * drag(across: axis)
    }
}

/// The congestion's per-cell fields on a grid: what the air's porous, resisting cells take, and
/// what the turbulence the obstacles make and the flame's folding by them take (after PDRFoam's
/// PDRsetFields; docs/congestion-model.md).
public struct CongestionField: Sendable {
    /// Per cell: the volume porosity β_v (the share of the cell open to the air), and half
    /// PDRFoam's drag CR across each axis, ½ C_D (A/V) α summed over the obstacles in the cell
    /// (m⁻¹), so that the drag force per volume along axis i is −(this) ρ|u| u_i. A cell without
    /// obstacles holds (1, 0, 0, 0).
    public var porosityDrag: [SIMD4<Float>]
    /// Per cell: the turbulence generation CT across each axis (m⁻¹), and the obstacles' length
    /// scale L_obs (m): the cell's size where there are none.
    public var generation: [SIMD4<Float>]
    /// Per cell: the obstacles' area blockage across each axis (PDRFoam's B, sharp-edged ones
    /// counted at their larger drag), and their count N, the obstacles crossing the cell.
    public var blockage: [SIMD4<Float>]
    /// Per cell: the count of obstacles along each axis (PDRFoam's ns, less what all three share),
    /// and the obstacles' wall area per volume A_w (m⁻¹).
    public var parallel: [SIMD4<Float>]
    /// Whether any cell has obstacles.
    public var isEmpty: Bool

    /// The least volume porosity a cell may have: arrays packed tighter than this are not
    /// sub-grid congestion but a solid, which belongs in the scene as a block.
    public static let minimumPorosity: Float = 0.2

    public init(arrays: [CongestionArray], grid: Grid) {
        let count = grid.nx * grid.ny * grid.nz
        porosityDrag = Array(repeating: SIMD4(1, 0, 0, 0), count: count)
        generation = Array(repeating: SIMD4(0, 0, 0, grid.cellSize), count: count)
        blockage = Array(repeating: .zero, count: count)
        parallel = Array(repeating: .zero, count: count)
        isEmpty = true
        let dx = grid.cellSize
        let volume = dx * dx * dx
        // The obstacles' own area blockage and count along each axis, for their length scale.
        var area = [SIMD3<Float>](repeating: .zero, count: count)
        var along = [SIMD3<Float>](repeating: .zero, count: count)
        var touched = Set<Int>()
        for array in arrays {
            let region = array.region
            let floorMin = (region.min / dx).rounded(.down)
            let ceilMax = (region.max / dx).rounded(.up)
            let low = SIMD3(max(Int(floorMin.x), 0), max(Int(floorMin.y), 0), max(Int(floorMin.z), 0))
            let high = SIMD3(
                min(Int(ceilMax.x), grid.nx), min(Int(ceilMax.y), grid.ny), min(Int(ceilMax.z), grid.nz))
            guard all(high .> low) else { continue }
            let blocked = array.volumeBlockage
            let drag = 0.5 * SIMD3<Float>(array.drag(across: 0), array.drag(across: 1), array.drag(across: 2))
            let made = SIMD3<Float>(
                array.turbulenceGeneration(across: 0), array.turbulenceGeneration(across: 1),
                array.turbulenceGeneration(across: 2))
            // Per cell: each crossing pipe blocks D/Δ of the face, (Δ/p)² pipes of each set cross it.
            let perSet = (dx / array.pitch) * (dx / array.pitch)
            let sets = Set(array.axes)
            var crossing = SIMD3<Float>.zero
            var parallelSets = SIMD3<Float>.zero
            for axis in 0..<3 {
                crossing[axis] = Float(sets.filter { $0 != axis }.count)
                parallelSets[axis] = sets.contains(axis) ? 1 : 0
            }
            let ownArea = crossing * array.diameter * dx / (array.pitch * array.pitch)
            // Sharp-edged obstacles fold the flame as their larger drag has it (PDRsetFields' B).
            let effectiveArea = ownArea * (array.shape == .cylinder ? 1 : 2.0 / 1.2)
            for k in low.z..<high.z {
                for j in low.y..<high.y {
                    for i in low.x..<high.x {
                        let cellLow = SIMD3<Float>(Float(i), Float(j), Float(k)) * dx
                        let overlap = simd_max(
                            simd_min(cellLow + dx, region.max) - simd_max(cellLow, region.min),
                            SIMD3(repeating: 0))
                        let share = overlap.x * overlap.y * overlap.z / volume
                        guard share > 0 else { continue }
                        let index = i + grid.nx * (j + grid.ny * k)
                        var value = porosityDrag[index]
                        value.x = max(value.x - blocked * share, Self.minimumPorosity)
                        value.y += drag.x * share
                        value.z += drag.y * share
                        value.w += drag.z * share
                        porosityDrag[index] = value
                        generation[index].x += made.x * share
                        generation[index].y += made.y * share
                        generation[index].z += made.z * share
                        blockage[index].x += effectiveArea.x * share
                        blockage[index].y += effectiveArea.y * share
                        blockage[index].z += effectiveArea.z * share
                        blockage[index].w += Float(sets.count) * perSet * share
                        parallel[index].x += parallelSets.x * perSet * share
                        parallel[index].y += parallelSets.y * perSet * share
                        parallel[index].z += parallelSets.z * perSet * share
                        parallel[index].w += array.wallArea * share
                        area[index] += ownArea * share
                        along[index] += parallelSets * perSet * share
                        touched.insert(index)
                        isEmpty = false
                    }
                }
            }
        }
        for index in touched {
            let n = blockage[index].w
            // The length scale (PDRsetFields): the area blockage per obstacle across each axis,
            // times the cell's width, the largest of the three; a cell's size where the obstacles
            // are too few or too sparse to set one.
            if n >= 0.05, simd_reduce_max(area[index]) >= 0.002, porosityDrag[index].x >= 0.1 {
                var scale: Float = 0
                for axis in 0..<3 {
                    scale = max(scale, area[index][axis] / max(n - along[index][axis], 1) * dx)
                }
                generation[index].w = scale
            }
            // What all three counts along share is no obstacle along any (PDRsetFields' nmin).
            let shared = simd_reduce_min(along[index])
            parallel[index].x -= shared
            parallel[index].y -= shared
            parallel[index].z -= shared
            blockage[index].w -= shared
        }
    }
}

/// The congestion's fields on the GPU, and the turbulence its obstacles make: per cell the obstacle
/// turbulence's kinetic energy k (m²/s²) and its dissipation ε (m²/s³), carried by the air and
/// kept in two buffers, read from one and written to the other each step (`obstacleTurbulence`).
final class CongestionBuffers {
    let porosityDrag: MTLBuffer
    let generation: MTLBuffer
    let blockage: MTLBuffer
    let parallel: MTLBuffer
    let turbulence: [MTLBuffer]
    /// Which of `turbulence` holds the latest.
    var current = 0
    /// Each cell's volume porosity, for the totals.
    let porosity: [Float]
    let drag: MTLComputePipelineState
    let turbulenceUpdate: MTLComputePipelineState

    /// The obstacle turbulence a cell starts with, as k and ε: a trace, whose ε sets its decay in
    /// open air (to a hundredth in about a minute).
    static let quiescent = SIMD2<Float>(1e-6, 1e-7)

    init(field: CongestionField, device: MTLDevice, library: MTLLibrary, constants: MTLFunctionConstantValues)
        throws
    {
        func buffer(_ values: [SIMD4<Float>], _ label: String) throws -> MTLBuffer {
            guard
                let buffer = values.withUnsafeBytes({
                    device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                })
            else { throw BlastError.allocationFailed(label) }
            buffer.label = label
            return buffer
        }
        porosityDrag = try buffer(field.porosityDrag, "congestion porosity and drag")
        generation = try buffer(field.generation, "congestion turbulence generation")
        blockage = try buffer(field.blockage, "congestion blockage")
        parallel = try buffer(field.parallel, "congestion parallel counts")
        let cells = field.porosityDrag.count
        turbulence = try (0..<2).map { n in
            guard
                let buffer = device.makeBuffer(
                    length: cells * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared)
            else { throw BlastError.allocationFailed("obstacle turbulence") }
            buffer.label = "obstacle turbulence \(n)"
            return buffer
        }
        porosity = field.porosityDrag.map(\.x)
        drag = try ShaderLibrary.pipeline("congestionDrag", in: library, constants: constants)
        turbulenceUpdate = try ShaderLibrary.pipeline("obstacleTurbulence", in: library, constants: constants)
        reset()
    }

    /// Back to a trace of turbulence everywhere.
    func reset() {
        current = 0
        for buffer in turbulence {
            let values = buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: porosity.count)
            for index in 0..<porosity.count { values[index] = Self.quiescent }
        }
    }

    var memoryFootprint: Int {
        ([porosityDrag, generation, blockage, parallel] + turbulence).reduce(0) { $0 + $1.length }
    }
}

extension BlastSolver {
    /// Lays the congestion's fields over the grid (`CongestionField`), or clears them where there is
    /// none, so that the kernels leave its code out.
    func loadCongestion(_ arrays: [CongestionArray]) throws {
        let field = arrays.isEmpty ? nil : CongestionField(arrays: arrays, grid: grid)
        guard let field, !field.isEmpty else {
            congestion = nil
            return
        }
        var constants = MTLFunctionConstantValues()
        var value = configuration.airModel.rawValue
        constants.setConstantValue(&value, type: .uint, index: ShaderLibrary.airModelConstant)
        constants = ShaderLibrary.withPorousAir(constants)
        congestion = try CongestionBuffers(
            field: field, device: device, library: library, constants: constants)
    }

    /// The obstacle turbulence in each cell as (k, ε), m²/s² and m²/s³, or nil without congestion.
    public func obstacleTurbulence() -> [SIMD2<Float>]? {
        guard let congestion else { return nil }
        let values = congestion.turbulence[congestion.current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        return Array(UnsafeBufferPointer(start: values, count: grid.cellCount))
    }

    /// The share of cell `index` the gas has: its cut cell's fluid share times its congestion's
    /// porosity. The air's densities are of the gas in that share.
    func openShare(_ index: Int) -> Double {
        fluidShare(index) * Double(congestion?.porosity[index] ?? 1)
    }
}
