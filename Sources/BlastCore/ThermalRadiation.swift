import BlastModel
import Foundation
import simd

extension BlastSolver {
    /// The fireball now: every cell of air at least `luminousTemperature` kelvin, summed in
    /// blocks of two cells a side. Summed on the GPU if the batch that ended now was asked for it
    /// (see `frameRequest`); otherwise read from the state, spread across the CPU's cores, so call
    /// it only while no batch is in flight.
    public func fireball(for spec: ThermalSpec) -> FireballFrame {
        fireball(luminousTemperature: spec.luminousTemperature, cells: spec.fireball == .volume)
    }

    /// As `fireball(for:)`; with `cells`, the luminous gas cell by cell too, for the volume model.
    public func fireball(luminousTemperature: Float, cells: Bool = false) -> FireballFrame {
        let blocks =
            frameExtractor?.fireballBlocks(luminous: luminousTemperature, time: time, steps: stepCount)
            ?? cpuLuminousBlocks(luminousTemperature: luminousTemperature)
        // In the blocks' order and in double precision, so the same from one run to the next.
        var count = 0.0
        var position = SIMD3<Double>.zero
        var fourth = 0.0
        var hottest: Float = 0
        for block in blocks {
            count += Double(block.cells)
            position += SIMD3<Double>(block.position)
            fourth += Double(block.fourth)
            hottest = max(hottest, block.hottest)
        }
        guard count > 0 else {
            return FireballFrame(time: time, volume: 0, centre: .zero, temperature: 0, hottest: 0)
        }
        let h = grid.cellSize
        return FireballFrame(
            time: time, volume: count * pow(Double(h), 3), centre: SIMD3<Float>(position / count) * h,
            temperature: Float(pow(fourth / count, 0.25)), hottest: hottest,
            shape: FireballShape(blocks: blocks, grid: grid),
            cells: cells ? luminousCells(blocks, luminousTemperature: luminousTemperature) : nil)
    }
}

extension ThermalExposure {
    /// `visibility` tests what blocks the receivers' view, by default `defaultVisibility`'s.
    public init(spec: ThermalSpec, scene: FragmentScene, visibility: (any ThermalVisibility)? = nil) {
        self.init(spec: spec, scene: scene, visibility: visibility, march: nil)
    }

    /// `march` follows rays through the volume, by default `defaultMarch`'s, sharing the
    /// visibility's acceleration structure where it has one.
    init(
        spec: ThermalSpec, scene: FragmentScene, visibility: (any ThermalVisibility)?,
        march: (any ThermalMarch)?
    ) {
        let occluders = Self.occluders(scene)
        let visibility = visibility ?? Self.defaultVisibility(occluders: occluders, terrain: scene.terrain)
        self.init(
            spec: spec, scene: scene, seeing: visibility,
            marching: spec.fireball != .volume
                ? nil
                : march
                    ?? Self.defaultMarch(
                        occluders: occluders, terrain: scene.terrain, spiral: Self.spread(spec.samples),
                        visibility: visibility as? MetalThermalVisibility))
    }
}
