import Metal
import Testing

@testable import BlastModel
@testable import BlastRender

/// The quarry face's meshes live on the GPU only: a renderer of a face kept without them (the
/// session's, and a clip recorded from it) finds the ones another renderer of the same rock made.
/// Illustrative scene's plumbing.
@Suite("Quarry meshes shared on the GPU", .serialized)
struct QuarryMeshSharingTests {
    @Test("A renderer of a face without its meshes draws the same meshes while another holds them")
    func sharesMeshes() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var options = QuarryFace.Options()
        options.blocks = 3000
        options.meshDetail = 1
        var face = try QuarryFace(site: .builtIn(), options: options)
        face.generate()
        face.buildDressing(level: 1)
        let path = QuarryCameraPath(
            eyes: (.zero, SIMD3(0, 1, 0)), targets: (SIMD3(0, 1, 0), .zero), fovY: (36, 36), duration: 1)
        func renderer(_ face: QuarryFace) throws -> QuarryRenderer {
            try QuarryRenderer(
                device: device, face: face, width: 64, height: 36, supersample: 1, path: path, frameRate: 30,
                quality: .live)
        }
        var first: QuarryRenderer? = try renderer(face)
        #expect(first!.hillside.vertices.isEmpty, "the renderer keeps its face without the meshes")
        let second = try renderer(face.withoutMesh())
        #expect(second.indexCount == face.indices.count && second.indexCount > 0)
        #expect(second.dressingCount == face.dressingIndices.count && second.dressingCount > 0)
        #expect(second.blockVertices === first!.blockVertices)
        first = nil
        // Once no renderer holds them, a face without its meshes has nothing to draw, and another
        // rock's meshes are never taken for its own.
        var other = try QuarryFace(site: .builtIn(), options: options)
        other.generate()
        #expect(other.meshID != face.meshID)
        let third = try renderer(other.withoutMesh())
        #expect(third.indexCount == 0)
        _ = second
    }
}
