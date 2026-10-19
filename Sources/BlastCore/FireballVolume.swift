import BlastModel
import Foundation
import RadialBlast
import simd

extension BlastSolver {
    /// The luminous gas cell by cell over the box of `blocks` (see `LuminousBlock`): cut out on
    /// the GPU at the end of the batch that ended now if it was asked for (see `frameRequest`),
    /// otherwise read from the state on the CPU.
    func luminousCells(_ blocks: [LuminousBlock], luminousTemperature: Float) -> LuminousCells? {
        guard let firstBlock = blocks.first else { return nil }
        let dims = LuminousBlock.dimensions(grid)
        func coordinates(_ index: Int) -> SIMD3<Int> {
            SIMD3(index % dims.x, (index / dims.x) % dims.y, index / (dims.x * dims.y))
        }
        var lowest = coordinates(firstBlock.index)
        var highest = lowest
        for block in blocks {
            lowest = simd_min(lowest, coordinates(block.index))
            highest = simd_max(highest, coordinates(block.index))
        }
        let size = SIMD3(grid.nx, grid.ny, grid.nz)
        let low = 2 &* lowest
        let counts = simd_min(2 &* (highest &+ 1), size) &- low
        let hasProducts = speciesHoldDetonationProducts
        if let packed = frameExtractor?.luminousCells(
            luminous: luminousTemperature, time: time, steps: stepCount, count: grid.cellCount)
        {
            if let refined = refinedLuminousCells(
                low: low, counts: counts, luminousTemperature: luminousTemperature,
                coarse: { packed[grid.index($0.x, $0.y, $0.z)] })
            {
                return refined
            }
            return LuminousCells(
                cellSize: grid.cellSize, low: low, counts: counts, hasProducts: hasProducts
            ) { n in
                let i = n % counts.x
                let j = (n / counts.x) % counts.y
                let k = n / (counts.x * counts.y)
                return packed[grid.index(low.x + i, low.y + j, low.z + k)]
            }
        }
        let packed = cpuLuminousCells(low: low, counts: counts, luminousTemperature: luminousTemperature)
        if let refined = refinedLuminousCells(
            low: low, counts: counts, luminousTemperature: luminousTemperature,
            coarse: { c in
                let l = c &- low
                return packed[l.x + counts.x * (l.y + counts.y * l.z)]
            })
        {
            return refined
        }
        return LuminousCells(cellSize: grid.cellSize, low: low, counts: counts, hasProducts: hasProducts) {
            packed[$0]
        }
    }

    /// Where the air is refined over the box of `counts` coarse cells from `low`, its luminous gas
    /// at the finest level whose box of cells stays within `LuminousCells.maximumVoxels`: each of
    /// those cells taken from the finest patch that holds it, and from its coarse cell, through
    /// `coarse` (packed as `extractLuminousCells` writes it), where none does. Nil where no patch
    /// holds any of the box, which then goes as the coarse cells have it.
    func refinedLuminousCells(
        low: SIMD3<Int>, counts: SIMD3<Int>, luminousTemperature: Float, coarse: (SIMD3<Int>) -> SIMD2<UInt32>
    ) -> LuminousCells? {
        let levels = refinementLevels
        guard let first = levels.first, first.holdsAny(from: low, through: low &+ counts &- 1),
            let top = levels.indices.last(where: {
                let n = counts &* (levels[$0].parentScale * levels[$0].ratio)
                return n.x * n.y * n.z <= LuminousCells.maximumVoxels
            })
        else { return nil }
        // Finest first: each level's cells along a coarse cell's edge, and its reader.
        let readers = levels[0...top].reversed().map { ($0.parentScale * $0.ratio, $0.fineReader()) }
        let scale = readers[0].0
        let fineLow = low &* scale
        let fineCounts = counts &* scale
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let hasProducts = speciesHoldDetonationProducts
        var packed = [SIMD2<UInt32>](repeating: .zero, count: fineCounts.x * fineCounts.y * fineCounts.z)
        packed.withUnsafeMutableBufferPointer { packed in
            concurrently(iterations: fineCounts.z) { k in
                for j in 0..<fineCounts.y {
                    for i in 0..<fineCounts.x {
                        let at = fineLow &+ SIMD3(i, j, k)
                        var value: SIMD2<UInt32>?
                        for (cells, read) in readers {
                            guard let cell = read(at / (scale / cells)) else { continue }
                            value = Self.packedLuminous(
                                cell.state, products: hasProducts ? cell.products : 0, gamma: gamma,
                                airModel: airModel, luminousTemperature: luminousTemperature)
                            break
                        }
                        packed[i + fineCounts.x * (j + fineCounts.y * k)] = value ?? coarse(at / scale)
                    }
                }
            }
        }
        return LuminousCells(
            cellSize: grid.cellSize / Float(scale), low: fineLow, counts: fineCounts, hasProducts: hasProducts
        ) { packed[$0] }
    }

    /// A cell of air packed as `extractLuminousCells` writes it: in x its temperature in kelvin in
    /// the low 16 bits and its unburnt products' density as a half float in the high, in y its
    /// absorption as hot air as a half; or zero if it is cooler than `luminousTemperature`.
    static func packedLuminous(
        _ cell: CellState, products held: Float, gamma: Float, airModel: AirModel, luminousTemperature: Float
    ) -> SIMD2<UInt32> {
        let air = primitive(of: cell, gamma: gamma, airModel: airModel)
        let bound = air.pressure / (air.density * AirModel.gasConstant)
        guard bound >= luminousTemperature, bound.isFinite else { return .zero }
        let t =
            airModel == .dissociating
            ? airModel.temperature(density: air.density, pressure: air.pressure) : bound
        guard t >= luminousTemperature, t.isFinite else { return .zero }
        let kelvin = UInt32(min(max(t.rounded(), 1), 65535))
        let products = Float16(min(max(held, 0), 65504))
        let absorption = Float16(min(HotAir.planckAbsorption(temperature: t, density: cell.density), 65504))
        return SIMD2(kelvin | UInt32(products.bitPattern) << 16, UInt32(absorption.bitPattern))
    }

    /// The cells of the box of `counts` from `low` packed as `extractLuminousCells` writes them,
    /// read from the state across the CPU's cores.
    func cpuLuminousCells(low: SIMD3<Int>, counts: SIMD3<Int>, luminousTemperature: Float) -> [SIMD2<UInt32>]
    {
        let gamma = configuration.gamma
        let airModel = configuration.airModel
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var packed = [SIMD2<UInt32>](repeating: .zero, count: counts.x * counts.y * counts.z)
        let hasProducts = speciesHoldDetonationProducts
        withState { cells in
            readSpecies { species in
                packed.withUnsafeMutableBufferPointer { packed in
                    concurrently(iterations: counts.z) { k in
                        for j in 0..<counts.y {
                            for i in 0..<counts.x {
                                let index = grid.index(low.x + i, low.y + j, low.z + k)
                                guard mask[index] == 0 else { continue }
                                packed[i + counts.x * (j + counts.y * k)] = Self.packedLuminous(
                                    cells[index], products: hasProducts ? species?[index].x ?? 0 : 0,
                                    gamma: gamma, airModel: airModel, luminousTemperature: luminousTemperature
                                )
                            }
                        }
                    }
                }
            }
        }
        return packed
    }
}

extension ThermalExposure {
    /// The march to use: on the GPU where there is one with ray tracing, borrowing `visibility`'s
    /// acceleration structure if given, otherwise on the CPU; `BOMBCAD_THERMAL_VISIBILITY=cpu` in
    /// the environment keeps it on the CPU.
    static func defaultMarch(
        occluders: [Box], terrain: Terrain? = nil, spiral: [SIMD3<Float>],
        visibility: MetalThermalVisibility? = nil
    ) -> any ThermalMarch {
        if ProcessInfo.processInfo.environment["BOMBCAD_THERMAL_VISIBILITY"] != "cpu",
            let metal = MetalThermalMarch(
                occluders: occluders, terrain: terrain, spiral: spiral, visibility: visibility)
        {
            return metal
        }
        return CPUThermalMarch(occluders: occluders, terrain: terrain, spiral: spiral)
    }

    /// The GPU's time on the volume's march so far, in seconds; nil if it is not marched there.
    public var marchGPUSeconds: Double? {
        (march as? MetalThermalMarch)?.usage.gpuSeconds
    }
}
