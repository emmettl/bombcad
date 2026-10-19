import BlastCore
import BlastRender
import CoreGraphics
import Foundation
import Metal
import Testing
import simd

/// Each material drawn as its own colour: a wall of it alone, rendered offscreen before the blast,
/// reads nearer its own `MaterialAppearance` than any other's.
@Suite("Materials drawn", .serialized, .hangLimit)
struct MaterialRenderingTests {
    /// A wall 3 m wide and 2 m high of `material`, as solids or as a shell, and no blast yet.
    private func scene(_ material: StructureMaterial?, shell: Bool) -> Scenario {
        var scene = Scenario(
            name: "Wall", domainSize: SIMD3(8, 6, 4), boxes: [],
            charge: Charge(mass: 0.01, position: SIMD3(7, 5, 1)))
        guard let material else { return scene }
        let thickness: Float = shell ? 0.05 : 0.25
        var wall = StructureModel(
            solids: [Box(min: SIMD3(2, 1.5, 0), max: SIMD3(2 + thickness, 4.5, 2))], material: material,
            elementSize: 0.25)
        if shell { wall.elementKind = .shell }
        scene.structure = wall
        return scene
    }

    /// The scene's pixels, RGBA, as drawn before any step.
    private func pixels(_ scene: Scenario, device: MTLDevice, queue: MTLCommandQueue) throws -> [SIMD4<UInt8>]
    {
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        let renderer = try SceneRenderer(device: device)
        renderer.setScene(scene, solver: solver)
        // The same view with the wall or without it, looking at its face from the charge's side.
        let camera = OrbitCamera(target: SIMD3(2, 3, 1), distance: 6, azimuth: 0.3, elevation: 0.35)
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 160, height: 100, camera: camera))
        var data = [SIMD4<UInt8>](repeating: .zero, count: 160 * 100)
        let context = try #require(
            CGContext(
                data: &data, width: 160, height: 100, bitsPerComponent: 8, bytesPerRow: 160 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(frame.image, in: CGRect(x: 0, y: 0, width: 160, height: 100))
        return data
    }

    /// A colour's chromaticity, its channels over their sum, so that light and shade drop out.
    private func chroma(_ c: SIMD3<Float>) -> SIMD3<Float> { c / max(c.x + c.y + c.z, 1e-6) }

    @Test(
        "A wall of each material reads nearest its own colour",
        arguments: [
            (StructureMaterial.plainConcrete, false, MaterialAppearance.concrete),
            (.structuralSteel, false, .steel),
            (.masonry, false, .brick),
            (.concreteBlock, false, .blockwork),
            (.softwood, true, .timber),
        ])
    func eachMaterial(_ material: StructureMaterial, shell: Bool, kind: MaterialAppearance) throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let queue = try #require(device.makeCommandQueue())
        let without = try pixels(scene(nil, shell: shell), device: device, queue: queue)
        let with = try pixels(scene(material, shell: shell), device: device, queue: queue)
        // The wall's pixels: those it changed.
        var sum = SIMD3<Float>.zero
        var count = 0
        for (a, b) in zip(without, with) where a != b {
            sum += SIMD3(Float(b.x), Float(b.y), Float(b.z)) / 255
            count += 1
        }
        #expect(count > 200 && count < 8_000, "\(count) pixels of the wall")
        let seen = chroma(sum / Float(max(count, 1)))
        let kinds = MaterialAppearance.allCases.filter { $0 != .glass }
        // The drawable is `bgra8Unorm`: the shaders' values, unencoded.
        let nearest = kinds.min {
            simd_distance(seen, chroma(SIMD3($0.colour.x, $0.colour.y, $0.colour.z)))
                < simd_distance(seen, chroma(SIMD3($1.colour.x, $1.colour.y, $1.colour.z)))
        }
        #expect(nearest == kind, "\(kind) drawn as \(seen), nearest \(String(describing: nearest))")
    }
}
