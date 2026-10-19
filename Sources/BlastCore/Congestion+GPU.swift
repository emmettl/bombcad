import BlastModel
import Foundation
import Metal
import simd

/// The congestion's fields on the GPU, and the turbulence its obstacles make: per cell the obstacle
/// turbulence's kinetic energy k (m²/s²) and its dissipation ε (m²/s³), carried by the air and
/// kept in two buffers, read from one and written to the other each step (`obstacleTurbulence`).
final class CongestionBuffers {
    let porosityDrag: MTLBuffer
    let generation: MTLBuffer
    let blockage: MTLBuffer
    let parallel: MTLBuffer
    /// Each cell's `CongestionField.unitWidth`.
    let unitWidth: MTLBuffer
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
        guard
            let width = field.unitWidth.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        else { throw BlastError.allocationFailed("congestion unit width") }
        width.label = "congestion unit width"
        unitWidth = width
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
        ([porosityDrag, generation, blockage, parallel, unitWidth] + turbulence).reduce(0) { $0 + $1.length }
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

extension CongestionBuffers {
    /// Its state for a checkpoint (`SolverCheckpoint`): the turbulence (both copies) and which is
    /// current, with the fields it was built with.
    func checkpoint() -> ClosureCheckpoint {
        let shared = ClosureCheckpoint.buffers(of: self, name: "congestion")
        return ClosureCheckpoint(
            checkpointName: "congestion", checkpointVersion: 1,
            parts: {
                var scalars = SolverCheckpoint.Writer()
                scalars.append(self.current)
                return shared.parts() + [.bytes("scalars", scalars.data)]
            },
            restore: { parts in
                try shared.restore(parts)
                var scalars = SolverCheckpoint.Reader(parts["scalars"] ?? Data())
                self.current = scalars.read(Int.self)
                try scalars.finish("congestion.scalars")
            })
    }
}
