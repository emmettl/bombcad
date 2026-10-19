import BlastModel
import Metal
import simd

/// The terrain a structure stands on (`StructureModel.ground`), for its kernels: what falls lands
/// on its surface instead of z = 0 (`structureTerrainLanding`, `shellTerrainLanding`, and the
/// rubble's `rubbleMove`). Without a terrain its uniforms are disabled and the floor stays z = 0.
struct StructureTerrain {
    var uniforms = TerrainUniforms()
    let heights: MTLBuffer

    init(device: MTLDevice, terrain: Terrain?) throws {
        let values = terrain?.heights ?? [0]
        guard
            let buffer = device.makeBuffer(
                bytes: values, length: max(values.count, 1) * MemoryLayout<Float>.stride,
                options: .storageModeShared)
        else { throw BlastError.allocationFailed("terrain heights (\(values.count) floats)") }
        buffer.label = "Structure terrain heights"
        heights = buffer
        if let terrain {
            uniforms.origin = terrain.origin
            uniforms.spacing = terrain.spacing
            uniforms.columns = UInt32(terrain.columns)
            uniforms.rows = UInt32(terrain.rows)
            uniforms.enabled = 1
        }
    }

    var isEnabled: Bool { uniforms.enabled != 0 }
}
