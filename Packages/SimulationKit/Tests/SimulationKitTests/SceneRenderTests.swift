import CoreGraphics
import Foundation
import Metal
import SceneModel
import SceneRender
import SceneView
import Testing
import simd

@Suite("Scene rendering")
struct SceneRenderTests {
    static let floorColour = SIMD4<Float>(0.2, 0.4, 0.9, 1)
    static let wallColour = SIMD4<Float>(0.9, 0.3, 0.2, 1)

    /// A 4 × 3 × 2.5 m room with its faces pointing in: floor pick 0, ceiling 1, walls 2 to 5.
    static var room: SceneGeometry {
        var scene = SceneGeometry()
        let (x, y, z): (Float, Float, Float) = (4, 3, 2.5)
        // Anticlockwise seen from inside.
        scene.addPolygon(
            [[0, 0, 0], [0, y, 0], [x, y, 0], [x, 0, 0]].reversed(), colour: floorColour, pick: 0)
        scene.addPolygon([[0, 0, z], [0, y, z], [x, y, z], [x, 0, z]], colour: wallColour, pick: 1)
        scene.addPolygon(
            [[0, 0, 0], [0, 0, z], [0, y, z], [0, y, 0]].reversed(), colour: wallColour, pick: 2)
        scene.addPolygon([[x, 0, 0], [x, 0, z], [x, y, z], [x, y, 0]], colour: wallColour, pick: 3)
        scene.addPolygon([[0, 0, 0], [0, 0, z], [x, 0, z], [x, 0, 0]], colour: wallColour, pick: 4)
        scene.addPolygon(
            [[0, y, 0], [0, y, z], [x, y, z], [x, y, 0]].reversed(), colour: wallColour, pick: 5)
        return scene
    }

    @Test("The room's faces point in, and a click picks the nearest face seen from its front")
    func picking() {
        let scene = Self.room
        // Every face's normal points towards the room's centre.
        let centre = SIMD3<Float>(2, 1.5, 1.25)
        for i in stride(from: 0, to: scene.solid.count, by: 3) {
            let v = scene.solid[i]
            #expect(simd_dot(SIMD3(v.normal.x, v.normal.y, v.normal.z), centre - v.point) > 0)
        }
        // From above, through the ceiling (seen from behind, so passed through), onto the floor.
        #expect(scene.pick(origin: [2, 1.5, 10], direction: [0, 0, -1]) == 0)
        // From inside, looking up: the ceiling.
        #expect(scene.pick(origin: [2, 1.5, 1], direction: [0, 0, 1]) == 1)
        // From the west, outside: through the west wall to the east wall.
        #expect(scene.pick(origin: [-5, 1.5, 1], direction: [1, 0, 0]) == 3)
        // Missing the room.
        #expect(scene.pick(origin: [10, 10, 10], direction: [1, 0, 0]) == nil)
        #expect(scene.bounds == Box(min: [0, 0, 0], max: [4, 3, 2.5]))
    }

    @Test("Spheres and boxes face out, and lines come in pairs")
    func shapes() {
        var scene = SceneGeometry()
        scene.addSphere(centre: [1, 2, 3], radius: 0.5, colour: Self.wallColour, pick: 7)
        for i in stride(from: 0, to: scene.solid.count, by: 3) {
            let v = scene.solid[i]
            #expect(simd_dot(SIMD3(v.normal.x, v.normal.y, v.normal.z), v.point - [1, 2, 3]) > 0)
            #expect(abs(simd_distance(v.point, [1, 2, 3]) - 0.5) < 1e-5)
        }
        #expect(scene.pick(origin: [1, 2, 10], direction: [0, 0, -1]) == 7)
        var box = SceneGeometry()
        box.addBox([0, 0, 0], [1, 1, 1], colour: Self.wallColour, pick: 1)
        box.addBoxEdges([0, 0, 0], [1, 1, 1], colour: Self.wallColour)
        #expect(box.solid.count == 36)
        #expect(box.lines.count == 24)
        #expect(box.pick(origin: [0.5, 0.5, 5], direction: [0, 0, -1]) == 1)
        // Translucent pieces are picked from either side, nearest first.
        var glass = SceneGeometry()
        glass.addBox([0, 0, 0], [1, 1, 1], colour: Self.wallColour, pick: 2, translucent: true)
        glass.addPolygon(
            [[0, 0, -1], [1, 0, -1], [1, 1, -1], [0, 1, -1]], colour: Self.floorColour, pick: 3)
        #expect(glass.pick(origin: [0.5, 0.5, 5], direction: [0, 0, -1]) == 2)
        #expect(glass.pick(origin: [0.5, 0.5, 0.5], direction: [0, 0, -1]) == 2)
        #expect(glass.pick(origin: [0.5, 0.5, -0.5], direction: [0, 0, -1]) == 3)
    }

    @Test("Rendered from outside, the near walls are cut away: the floor shows, and the highlight tints it")
    func cutaway() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            return
        }
        let renderer = try MeshRenderer(device: device)
        renderer.setGeometry(Self.room)
        let camera = OrbitCamera(target: [2, 1.5, 0.5], distance: 9, azimuth: -2.2, elevation: 0.7)
        func centrePixel() throws -> SIMD3<Float> {
            let image = try #require(
                renderer.snapshot(commandQueue: queue, width: 64, height: 48, camera: camera))
            let data = try #require(image.dataProvider?.data as Data?)
            // BGRA, little-endian with the alpha byte skipped.
            let offset = (24 * 64 + 32) * 4
            return SIMD3(Float(data[offset + 2]), Float(data[offset + 1]), Float(data[offset])) / 255
        }
        // Looking down past the near walls onto the floor: blue, not the walls' red.
        let plain = try centrePixel()
        #expect(plain.z > plain.x, "\(plain)")
        // The floor highlighted turns towards the highlight's orange.
        renderer.highlighted = 0
        let lit = try centrePixel()
        #expect(lit.x > plain.x + 0.2, "\(lit) against \(plain)")
        // The projection keeps what the camera looks at in the middle of the view.
        let clip = MeshRenderer.viewProjection(camera, aspectRatio: 4 / 3) * SIMD4(camera.target, 1)
        #expect(abs(clip.x / clip.w) < 1e-5 && abs(clip.y / clip.w) < 1e-5)
        #expect(clip.z / clip.w > 0 && clip.z / clip.w < 1)
    }
}
