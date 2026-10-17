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
    /// The correction to a row's drag for the blockage of the row, (1 − ½b)/(1 − b)² with
    /// b = diameter/pitch the share of the row's width its pipes block, as PDRFoam's PDRsetFields
    /// applies it inside a uniform array (`calc_drag_etc`: α^(0.5+0.5·expon), expon 1 where the
    /// neighbouring cells are as blocked).
    public var rowBlockageFactor: Float {
        let b = min(diameter / pitch, 0.99)
        return (1 - 0.5 * b) / ((1 - b) * (1 - b))
    }
    /// The pipes' surface per volume, m⁻¹.
    public var wallArea: Float { Float(Set(axes).count) * perimeter / (pitch * pitch) }
}

/// The congestion's per-cell fields on a grid: what the air's porous, resisting cells take.
public struct CongestionField: Sendable {
    /// Per cell: the volume porosity β_v (the share of the cell open to the air), and half
    /// PDRFoam's drag CR across each axis, ½ C_D (A/V) α summed over the obstacles in the cell
    /// (m⁻¹), so that the drag force per volume along axis i is −(this) ρ|u| u_i. A cell without obstacles
    /// holds (1, 0, 0, 0).
    public var porosityDrag: [SIMD4<Float>]
    /// Per cell: the obstacles' wall area per volume (m⁻¹), and three values for the turbulence the
    /// congestion makes, set by later stages; zero where there are none.
    public var wallArea: [SIMD4<Float>]
    /// Whether any cell has obstacles.
    public var isEmpty: Bool

    /// The least volume porosity a cell may have: arrays packed tighter than this are not
    /// sub-grid congestion but a solid, which belongs in the scene as a block.
    public static let minimumPorosity: Float = 0.2

    public init(arrays: [CongestionArray], grid: Grid) {
        let count = grid.nx * grid.ny * grid.nz
        porosityDrag = Array(repeating: SIMD4(1, 0, 0, 0), count: count)
        wallArea = Array(repeating: .zero, count: count)
        isEmpty = true
        let dx = grid.cellSize
        let volume = dx * dx * dx
        for array in arrays {
            let region = array.region
            let floorMin = (region.min / dx).rounded(.down)
            let ceilMax = (region.max / dx).rounded(.up)
            let low = SIMD3(max(Int(floorMin.x), 0), max(Int(floorMin.y), 0), max(Int(floorMin.z), 0))
            let high = SIMD3(
                min(Int(ceilMax.x), grid.nx), min(Int(ceilMax.y), grid.ny), min(Int(ceilMax.z), grid.nz))
            guard all(high .> low) else { continue }
            let blockage = array.volumeBlockage
            // PDRFoam's CR, C_D × frontal area per volume × the row's blockage factor, halved here
            // as its drag ½ρ|U|U·CR is applied.
            let factor = 0.5 * array.dragCoefficient * array.rowBlockageFactor
            let drag = SIMD3<Float>(
                factor * array.frontalArea(across: 0), factor * array.frontalArea(across: 1),
                factor * array.frontalArea(across: 2))
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
                        value.x = max(value.x - blockage * share, Self.minimumPorosity)
                        value.y += drag.x * share
                        value.z += drag.y * share
                        value.w += drag.z * share
                        porosityDrag[index] = value
                        wallArea[index].x += array.wallArea * share
                        isEmpty = false
                    }
                }
            }
        }
    }
}

extension BlastSolver {
    /// Lays the congestion's fields over the grid (`CongestionField`), or clears them where there is
    /// none, so that the kernels leave its code out.
    func loadCongestion(_ arrays: [CongestionArray]) throws {
        let field = arrays.isEmpty ? nil : CongestionField(arrays: arrays, grid: grid)
        guard let field, !field.isEmpty else {
            congestionBuffer = nil
            congestionWallBuffer = nil
            return
        }
        func buffer(_ values: [SIMD4<Float>], _ label: String) throws -> MTLBuffer {
            guard
                let buffer = values.withUnsafeBytes({
                    device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
                })
            else { throw BlastError.allocationFailed(label) }
            buffer.label = label
            return buffer
        }
        congestionBuffer = try buffer(field.porosityDrag, "congestion porosity and drag")
        congestionWallBuffer = try buffer(field.wallArea, "congestion wall area")
        try prepareCongestionDrag()
    }
}
