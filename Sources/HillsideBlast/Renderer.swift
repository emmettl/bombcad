import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// Layout matches `HillsideCamera` in `Hillside.metal` and `HillsideDust.metal`.
struct CameraUniforms {
    var viewProjection: simd_float4x4
    var shadow: simd_float4x4
    var eye: SIMD4<Float>
    var sun: SIMD4<Float>
    var fogColor: SIMD4<Float>
    var terrainOrigin: SIMD4<Float>
    var inverseViewProjection: simd_float4x4
    var dustLow: SIMD4<Float>
    var dustHigh: SIMD4<Float>
    var misc: SIMD4<Float>
}

func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return simd_float4x4(
        SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0))
}

func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
    let f = simd_normalize(target - eye)
    let s = simd_normalize(simd_cross(f, up))
    let u = simd_cross(s, f)
    return simd_float4x4(
        SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1))
}

func orthographic(left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float)
    -> simd_float4x4
{
    simd_float4x4(
        SIMD4(2 / (right - left), 0, 0, 0), SIMD4(0, 2 / (top - bottom), 0, 0),
        SIMD4(0, 0, 1 / (near - far), 0),
        SIMD4((left + right) / (left - right), (top + bottom) / (bottom - top), near / (near - far), 1))
}

func parseVector(_ text: String) -> SIMD3<Float> {
    let v = text.split(separator: ",").compactMap { Float($0) }
    return SIMD3(v[0], v[1], v[2])
}

/// How much the renderer draws: everything for the film, less for the play window.
struct RenderQuality {
    var shadowSize = 8192
    var decorScale: Float = 1
    /// The chips land on the terrain alone, not on the moving blocks: one height pass, not one a frame.
    var staticHeight = false
    static let film = RenderQuality()
    static let live = RenderQuality(shadowSize: 4096, decorScale: 0.3, staticHeight: true)
}

final class Renderer {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    let hillside: Hillside
    let width: Int
    let height: Int
    let supersample: Int
    let blockVertices: MTLBuffer
    let blockIndices: MTLBuffer
    let indexCount: Int
    let dressingVertices: MTLBuffer
    let dressingIndices: MTLBuffer
    let dressingCount: Int
    let identityPose: MTLBuffer
    let identityRest: MTLBuffer
    let terrainVertices: MTLBuffer
    let terrainIndices: MTLBuffer
    let terrainIndexCount: Int
    let shadowMap: MTLTexture
    let hdr: MTLTexture
    let hdrDepth: MTLTexture
    let output: MTLTexture
    let heightMap: MTLTexture
    let noDust: MTLTexture
    let shadowSampler: MTLSamplerState
    let linearSampler: MTLSamplerState
    let blockPipeline: MTLRenderPipelineState
    let terrainPipeline: MTLRenderPipelineState
    let chipPipeline: MTLRenderPipelineState
    let blockShadow: MTLRenderPipelineState
    let terrainShadow: MTLRenderPipelineState
    let chipShadow: MTLRenderPipelineState
    let chipUpdate: MTLComputePipelineState
    let tonemap: MTLRenderPipelineState
    let sky: MTLRenderPipelineState
    let aoPipeline: MTLRenderPipelineState
    let skyDepth: MTLDepthStencilState
    let opaqueDepth: MTLDepthStencilState
    var dust: DustField?
    let restCentres: MTLBuffer
    let chips: MTLBuffer
    let chipCount: Int
    var camera: CameraUniforms
    let cameraPath: CameraPath
    /// A view that replaces the path, for the play window.
    var viewOverride: (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float)?
    let quality: RenderQuality
    var heightDrawn = false
    let pristineChips: MTLBuffer
    let topDown: simd_float4x4
    let heightTop: Float = 130
    let heightBottom: Float = 0
    let aspect: Float
    let frameRate: Float

    init(
        device: MTLDevice, library: MTLLibrary, hillside: Hillside, width: Int, height: Int, supersample: Int,
        path: CameraPath, frameRate: Float, quality: RenderQuality = .film
    ) throws {
        self.quality = quality
        self.device = device
        self.library = library
        self.hillside = hillside
        self.width = width
        self.height = height
        self.supersample = supersample
        self.cameraPath = path
        self.frameRate = frameRate
        queue = device.makeCommandQueue()!
        blockVertices = hillside.vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
        }
        blockIndices = hillside.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
        }
        indexCount = hillside.indices.count
        dressingVertices = hillside.dressingVertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 20))!
        }
        dressingIndices = hillside.dressingIndices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: max($0.count, 12))!
        }
        dressingCount = hillside.dressingIndices.count
        let identity: [SIMD4<Float>] = [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 1)]
        identityPose = device.makeBuffer(bytes: identity, length: 32)!
        let identityR: [SIMD4<Float>] = [.zero]
        identityRest = device.makeBuffer(bytes: identityR, length: 16)!
        let rest = hillside.blocks.map { SIMD4<Float>($0.centre, Float($0.size)) }
        restCentres = device.makeBuffer(bytes: rest, length: 16 * rest.count)!
        let chipData = Decor.make(hillside: hillside, scale: quality.decorScale)
        chips = chipData.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        chipCount = chipData.count
        pristineChips = chipData.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
        }
        // Terrain mesh.
        let t = hillside.terrain
        var vertices = [Float]()
        vertices.reserveCapacity(t.columns * t.rows * 6)
        func h(_ i: Int, _ j: Int) -> Float {
            t.height(column: max(0, min(t.columns - 1, i)), row: max(0, min(t.rows - 1, j)))
        }
        for j in 0..<t.rows {
            for i in 0..<t.columns {
                let x = t.origin.x + Float(i) * t.spacing
                let y = t.origin.y + Float(j) * t.spacing
                let n = simd_normalize(
                    SIMD3<Float>(
                        (h(i - 1, j) - h(i + 1, j)) / (2 * t.spacing),
                        (h(i, j - 1) - h(i, j + 1)) / (2 * t.spacing), 1
                    ))
                // The steep ground sits behind the render-only rock, not through it.
                let inset: Float = n.z < 0.8 ? 1.8 : 0
                vertices += [x, y, h(i, j) - inset, n.x, n.y, n.z]
            }
        }
        var indices = [UInt32]()
        indices.reserveCapacity((t.columns - 1) * (t.rows - 1) * 6)
        for j in 0..<(t.rows - 1) {
            for i in 0..<(t.columns - 1) {
                let a = UInt32(i + j * t.columns)
                let b = a + 1
                let c = a + UInt32(t.columns)
                let d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        // The same hillside on past the broken strip's grid, so the view has no edge (render only).
        let extBase = UInt32(vertices.count / 6)
        let extSpacing: Float = 3
        let extColumns = 570
        let extRows = 296
        let (extX, extY): (Float, Float) = (-610, t.origin.y + 1)
        func extHeight(_ x: Float, _ y: Float) -> Float {
            let main =
                x > t.origin.x + 1 && x < t.origin.x + Float(t.columns - 2) * t.spacing
                && y < t.origin.y + Float(t.rows - 2) * t.spacing
            if main { return hillside.height(t.heights, x, y) - 2.2 }
            return hillside.oldHeight(x, y)
        }
        for j in 0..<extRows {
            for i in 0..<extColumns {
                let (x, y) = (extX + Float(i) * extSpacing, extY + Float(j) * extSpacing)
                let z = extHeight(x, y)
                let dx = extHeight(x + 1, y) - extHeight(x - 1, y)
                let dy = extHeight(x, y + 1) - extHeight(x, y - 1)
                let n = simd_normalize(SIMD3<Float>(-dx * 0.5, -dy * 0.5, 1))
                let inset: Float = n.z < 0.8 ? 1.8 : 0
                vertices += [x, y, z - inset, n.x, n.y, n.z]
            }
        }
        for j in 0..<(extRows - 1) {
            for i in 0..<(extColumns - 1) {
                let a = extBase + UInt32(i + j * extColumns)
                let b = a + 1
                let c = a + UInt32(extColumns)
                let d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        // A ground beyond the grid, so the long lens sees no edge: a low skirt on four sides.
        let skirtBase = UInt32(vertices.count / 6)
        let skirt: [(Float, Float)] = [
            (-900, -900), (900, -900), (900, t.origin.y + 2), (-900, t.origin.y + 2),
        ]
        for (x, y) in skirt { vertices += [x, y, 0.1, 0, 0, 1] }
        indices += [skirtBase, skirtBase + 2, skirtBase + 1, skirtBase, skirtBase + 3, skirtBase + 2]
        terrainVertices = device.makeBuffer(bytes: vertices, length: vertices.count * 4)!
        terrainIndices = device.makeBuffer(bytes: indices, length: indices.count * 4)!
        terrainIndexCount = indices.count

        func depthTarget(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        shadowMap = depthTarget(quality.shadowSize, quality.shadowSize)
        heightMap = depthTarget(1000, 790)
        hdrDepth = depthTarget(width * supersample, height * supersample)
        let hdrDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width * supersample, height: height * supersample,
            mipmapped: false)
        hdrDescriptor.usage = [.renderTarget, .shaderRead]
        hdrDescriptor.storageMode = .private
        hdr = device.makeTexture(descriptor: hdrDescriptor)!
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        output = device.makeTexture(descriptor: outputDescriptor)!
        let empty = MTLTextureDescriptor()
        empty.textureType = .type3D
        empty.pixelFormat = .r16Float
        empty.width = 2
        empty.height = 2
        empty.depth = 2
        noDust = device.makeTexture(descriptor: empty)!

        let shadowSamplerDescriptor = MTLSamplerDescriptor()
        shadowSamplerDescriptor.compareFunction = .lessEqual
        shadowSamplerDescriptor.minFilter = .linear
        shadowSamplerDescriptor.magFilter = .linear
        shadowSamplerDescriptor.sAddressMode = .clampToEdge
        shadowSamplerDescriptor.tAddressMode = .clampToEdge
        shadowSampler = device.makeSamplerState(descriptor: shadowSamplerDescriptor)!
        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: linear)!

        func pipeline(
            vertex: String, fragment: String?, depth: Bool = true, color: MTLPixelFormat? = .rgba16Float,
            multiply: Bool = false
        ) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)!
            if let fragment { d.fragmentFunction = library.makeFunction(name: fragment)! }
            if let color {
                d.colorAttachments[0].pixelFormat = color
                if multiply {
                    d.colorAttachments[0].isBlendingEnabled = true
                    d.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
                    d.colorAttachments[0].destinationRGBBlendFactor = .zero
                    d.colorAttachments[0].sourceAlphaBlendFactor = .zero
                    d.colorAttachments[0].destinationAlphaBlendFactor = .one
                }
            }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        blockPipeline = try pipeline(vertex: "blockVertex", fragment: "blockFragment")
        terrainPipeline = try pipeline(vertex: "terrainVertex", fragment: "terrainFragment")
        chipPipeline = try pipeline(vertex: "chipVertex", fragment: "chipFragment")
        blockShadow = try pipeline(vertex: "blockShadowVertex", fragment: nil, color: nil)
        terrainShadow = try pipeline(vertex: "terrainShadowVertex", fragment: nil, color: nil)
        chipShadow = try pipeline(vertex: "chipShadowVertex", fragment: nil, color: nil)
        chipUpdate = try device.makeComputePipelineState(function: library.makeFunction(name: "chipUpdate")!)
        tonemap = try pipeline(vertex: "fullscreen", fragment: "tonemap", depth: false, color: .bgra8Unorm)
        sky = try pipeline(vertex: "skyVertex", fragment: "skyFragment")
        aoPipeline = try pipeline(vertex: "fullscreen", fragment: "aoFragment", depth: false, multiply: true)
        let skyState = MTLDepthStencilDescriptor()
        skyState.depthCompareFunction = .lessEqual
        skyState.isDepthWriteEnabled = false
        skyDepth = device.makeDepthStencilState(descriptor: skyState)!
        let depthState = MTLDepthStencilDescriptor()
        depthState.depthCompareFunction = .less
        depthState.isDepthWriteEnabled = true
        opaqueDepth = device.makeDepthStencilState(descriptor: depthState)!

        aspect = Float(width) / Float(height)
        let sun = simd_normalize(
            option(CommandLine.arguments, "--sun").map(parseVector) ?? SIMD3<Float>(0.86, -0.42, 0.26))
        let centre = (hillside.low + hillside.high) * 0.5
        let lightEye = centre + sun * 420
        let lightView = lookAt(eye: lightEye, target: centre, up: SIMD3(0, 0, 1))
        let ortho = orthographic(left: -260, right: 260, bottom: -130, top: 130, near: 30, far: 900)
        let span = hillside.high - hillside.low
        let middle = (hillside.high + hillside.low) * 0.5
        topDown =
            orthographic(
                left: -span.x / 2, right: span.x / 2, bottom: -span.y / 2, top: span.y / 2, near: 0,
                far: heightTop - heightBottom)
            * lookAt(
                eye: SIMD3(middle.x, middle.y, heightTop), target: SIMD3(middle.x, middle.y, 0),
                up: SIMD3(0, 1, 0))
        camera = CameraUniforms(
            viewProjection: matrix_identity_float4x4, shadow: ortho * lightView, eye: .zero,
            sun: SIMD4(sun, 0),
            fogColor: SIMD4(0.6, 0.55, 0.5, 1), terrainOrigin: .zero,
            inverseViewProjection: matrix_identity_float4x4,
            dustLow: .zero, dustHigh: .zero, misc: .zero)
    }

    /// Renders one frame with block poses from `pose`, `previous` being the frame before, stepping
    /// the decorative chips by one frame. Returns the GPU time (s).
    @discardableResult
    func render(pose: MTLBuffer, previous: MTLBuffer, time: Float) -> Double {
        let buffer = queue.makeCommandBuffer()!
        var cam = camera
        let view = viewOverride ?? cameraPath.at(time)
        let tanHalf = tan(view.fovY * 0.5)
        let vp =
            perspective(fovY: view.fovY, aspect: aspect, near: 3, far: 1600)
            * lookAt(eye: view.eye, target: view.target, up: SIMD3(0, 0, 1))
        cam.viewProjection = vp
        cam.inverseViewProjection = vp.inverse
        cam.eye = SIMD4(view.eye, 1)
        cam.misc = SIMD4(time, 0.5 / tanHalf, 0, 0)
        if let dust {
            cam.dustLow = SIMD4(dust.low, 0)
            cam.dustHigh = SIMD4(dust.high, 1)
        }
        func drawGeometry(
            _ encoder: MTLRenderCommandEncoder, block: MTLRenderPipelineState, terrain: MTLRenderPipelineState
        ) {
            encoder.setRenderPipelineState(block)
            encoder.setVertexBuffer(blockVertices, offset: 0, index: 0)
            encoder.setVertexBuffer(pose, offset: 0, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
                indexBufferOffset: 0)
            encoder.setVertexBuffer(dressingVertices, offset: 0, index: 0)
            encoder.setVertexBuffer(identityPose, offset: 0, index: 1)
            if dressingCount > 0 {
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: dressingCount, indexType: .uint32,
                    indexBuffer: dressingIndices,
                    indexBufferOffset: 0)
            }
            encoder.setRenderPipelineState(terrain)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(terrainVertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: terrainIndexCount, indexType: .uint32,
                indexBuffer: terrainIndices,
                indexBufferOffset: 0)
        }
        // Shadow map.
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        let shadow = buffer.makeRenderCommandEncoder(descriptor: shadowPass)!
        shadow.setDepthStencilState(opaqueDepth)
        shadow.setCullMode(.front)
        shadow.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)
        drawGeometry(shadow, block: blockShadow, terrain: terrainShadow)
        shadow.setCullMode(.none)
        shadow.setRenderPipelineState(chipShadow)
        shadow.setVertexBuffer(chips, offset: 0, index: 0)
        shadow.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 60, instanceCount: chipCount)
        shadow.endEncoding()
        // Scene.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = hdr
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0.3, green: 0.42, blue: 0.62, alpha: 1)
        scenePass.depthAttachment.texture = hdrDepth
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.storeAction = .store
        scenePass.depthAttachment.clearDepth = 1
        let scene = buffer.makeRenderCommandEncoder(descriptor: scenePass)!
        scene.setDepthStencilState(opaqueDepth)
        scene.setFrontFacing(.counterClockwise)
        scene.setCullMode(.back)
        scene.setFragmentTexture(shadowMap, index: 0)
        scene.setFragmentTexture(dust?.light ?? noDust, index: 1)
        scene.setFragmentSamplerState(shadowSampler, index: 0)
        scene.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        scene.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)
        // Blocks and their rest positions.
        scene.setRenderPipelineState(blockPipeline)
        scene.setVertexBuffer(blockVertices, offset: 0, index: 0)
        scene.setVertexBuffer(pose, offset: 0, index: 1)
        scene.setVertexBuffer(restCentres, offset: 0, index: 3)
        scene.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
            indexBufferOffset: 0)
        // The dressing of the rest of the face.
        if dressingCount > 0 {
            scene.setVertexBuffer(dressingVertices, offset: 0, index: 0)
            scene.setVertexBuffer(identityPose, offset: 0, index: 1)
            scene.setVertexBuffer(identityRest, offset: 0, index: 3)
            scene.drawIndexedPrimitives(
                type: .triangle, indexCount: dressingCount, indexType: .uint32, indexBuffer: dressingIndices,
                indexBufferOffset: 0)
        }
        scene.setRenderPipelineState(terrainPipeline)
        scene.setCullMode(.none)
        scene.setVertexBuffer(terrainVertices, offset: 0, index: 0)
        scene.drawIndexedPrimitives(
            type: .triangle, indexCount: terrainIndexCount, indexType: .uint32, indexBuffer: terrainIndices,
            indexBufferOffset: 0)
        scene.setRenderPipelineState(chipPipeline)
        scene.setVertexBuffer(chips, offset: 0, index: 0)
        scene.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 60, instanceCount: chipCount)
        scene.setRenderPipelineState(sky)
        scene.setDepthStencilState(skyDepth)
        scene.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        scene.endEncoding()
        // Ambient occlusion.
        let aoPass = MTLRenderPassDescriptor()
        aoPass.colorAttachments[0].texture = hdr
        aoPass.colorAttachments[0].loadAction = .load
        aoPass.colorAttachments[0].storeAction = .store
        let ao = buffer.makeRenderCommandEncoder(descriptor: aoPass)!
        ao.setRenderPipelineState(aoPipeline)
        ao.setFragmentTexture(hdrDepth, index: 0)
        ao.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        ao.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ao.endEncoding()
        dust?.composite(buffer: buffer, hdr: hdr, depth: hdrDepth, camera: cam, sampler: linearSampler)
        // Tonemap and downsample.
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = output
        finalPass.colorAttachments[0].loadAction = .dontCare
        finalPass.colorAttachments[0].storeAction = .store
        let final = buffer.makeRenderCommandEncoder(descriptor: finalPass)!
        final.setRenderPipelineState(tonemap)
        final.setFragmentTexture(hdr, index: 0)
        final.setFragmentSamplerState(linearSampler, index: 0)
        final.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        final.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.gpuEndTime - buffer.gpuStartTime
    }

    /// One frame's step of the decorative chips, over a top-down height of the scene.
    func stepDecor(pose: MTLBuffer, previous: MTLBuffer, time: Float) {
        let buffer = queue.makeCommandBuffer()!
        var top = camera
        top.shadow = topDown
        if !(quality.staticHeight && heightDrawn) {
            let heightPass = MTLRenderPassDescriptor()
            heightPass.depthAttachment.texture = heightMap
            heightPass.depthAttachment.loadAction = .clear
            heightPass.depthAttachment.storeAction = .store
            heightPass.depthAttachment.clearDepth = 1
            let encoder = buffer.makeRenderCommandEncoder(descriptor: heightPass)!
            encoder.setDepthStencilState(opaqueDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(&top, length: MemoryLayout<CameraUniforms>.stride, index: 2)
            if !quality.staticHeight {
                encoder.setRenderPipelineState(blockShadow)
                encoder.setVertexBuffer(blockVertices, offset: 0, index: 0)
                encoder.setVertexBuffer(pose, offset: 0, index: 1)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
                    indexBufferOffset: 0)
            }
            encoder.setRenderPipelineState(terrainShadow)
            encoder.setVertexBuffer(terrainVertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: terrainIndexCount, indexType: .uint32,
                indexBuffer: terrainIndices,
                indexBufferOffset: 0)
            encoder.endEncoding()
            heightDrawn = true
        }
        var chipUniforms = Decor.Uniforms(
            dt: 1 / frameRate, gravity: 9.81, time: time, pad: 0, low: SIMD4(hillside.low, 0),
            size: SIMD4(
                hillside.high.x - hillside.low.x, hillside.high.y - hillside.low.y, heightTop, heightBottom))
        let compute = buffer.makeComputeCommandEncoder()!
        compute.setComputePipelineState(chipUpdate)
        compute.setBuffer(chips, offset: 0, index: 0)
        compute.setBuffer(pose, offset: 0, index: 1)
        compute.setBuffer(previous, offset: 0, index: 2)
        compute.setTexture(heightMap, index: 0)
        compute.setBytes(&chipUniforms, length: MemoryLayout<Decor.Uniforms>.stride, index: 3)
        compute.dispatchThreads(
            MTLSize(width: chipCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        compute.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Back to the chips as built, for a jump backward.
    func resetDecor() {
        chips.contents().copyMemory(from: pristineChips.contents(), byteCount: chips.length)
    }

    func savePNG(_ url: URL) {
        let bytesPerRow = 4 * width
        var data = [UInt8](repeating: 0, count: bytesPerRow * height)
        output.getBytes(
            &data, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        data.withUnsafeMutableBytes { raw in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue),
                let image = context.makeImage(),
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    /// Copies the frame into a new pixel buffer for AVFoundation.
    func pixelBuffer(pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let pixel = out else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        output.getBytes(
            CVPixelBufferGetBaseAddress(pixel)!, bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
            from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return pixel
    }
}

/// The camera over the clip: from one view to another, easing, with a long lens.
struct CameraPath {
    var eyes: (SIMD3<Float>, SIMD3<Float>)
    var targets: (SIMD3<Float>, SIMD3<Float>)
    var fovY: (Float, Float)
    var duration: Float

    func at(_ time: Float) -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float) {
        let u = max(0, min(1, time / duration))
        let s = u * u * u * (u * (u * 6 - 15) + 10)
        return (
            eyes.0 + (eyes.1 - eyes.0) * s, targets.0 + (targets.1 - targets.0) * s,
            (fovY.0 + (fovY.1 - fovY.0) * s) * .pi / 180
        )
    }
}

/// Decorative chips, gravel and scrub: instanced little polyhedra, never rigid bodies.
enum Decor {
    /// Layout matches `HillsideChip` in `Hillside.metal`.
    struct Chip {
        var posSize: SIMD4<Float>
        var velAge: SIMD4<Float>
        var offsetDelay: SIMD4<Float>
        var parent: UInt32
        var state: UInt32
        var seed: Float
        var tint: Float
    }

    /// Layout matches `HillsideChipUniforms` in `Hillside.metal`.
    struct Uniforms {
        var dt: Float
        var gravity: Float
        var time: Float
        var pad: Float
        var low: SIMD4<Float>
        var size: SIMD4<Float>
    }

    static func make(hillside: Hillside, scale: Float = 1) -> [Chip] {
        var r = Random(seed: 8_675_309)
        var chips: [Chip] = []
        chips.reserveCapacity(1_000_000)
        func size(_ low: Float, _ high: Float, _ power: Float) -> Float {
            let u = r.float()
            return min(high, low * pow(max(u, 1e-4), -power))
        }
        // Chips that leave their blocks.
        for (n, block) in hillside.blocks.enumerated() {
            let c = block.centre
            let across =
                c.y - Hillside.faceLine(c.x) - hillside.options.depth
                * Hillside.mask(c.x, length: hillside.options.length)
            if across > -2.6 { continue }
            let count = max(2, min(8, Int(block.size * block.size * 3 + 2)))
            for k in 0..<count {
                let anchor = hillside.chipAnchors[6 * n + k % 6]
                chips.append(
                    Chip(
                        posSize: SIMD4(c, size(0.06, 0.5, 0.42)), velAge: .zero,
                        offsetDelay: SIMD4(anchor, r.float(0.02, 1.4)), parent: UInt32(n), state: 0,
                        seed: r.float(), tint: r.float(0.25, 0.9)))
            }
        }
        // Gravel and small stones: dense under the faces, thinning across the floor.
        let t = hillside.terrain
        func onGround(_ x: Float, _ y: Float, _ s: Float, _ tint: Float) {
            guard x > hillside.low.x, y > hillside.low.y, x < hillside.high.x, y < hillside.high.y else {
                return
            }
            let z = hillside.height(t.heights, x, y)
            chips.append(
                Chip(
                    posSize: SIMD4(x, y, z + s * 0.45, s), velAge: .zero, offsetDelay: .zero, parent: 0,
                    state: 3,
                    seed: r.float(), tint: tint))
        }
        for _ in 0..<Int(260_000 * scale) {
            let x = r.float(hillside.low.x, hillside.high.x)
            let toe =
                Hillside.faceLine(x) + hillside.options.depth
                * Hillside.mask(x, length: hillside.options.length) - 2
            onGround(x, toe - 14 * -log(max(r.float(), 1e-3)), size(0.05, 0.28, 0.38), r.float(0.25, 0.75))
        }
        for _ in 0..<Int(220_000 * scale) {
            onGround(
                r.float(hillside.low.x, hillside.high.x), r.float(hillside.low.y, -8), size(0.05, 0.18, 0.4),
                r.float(0.2, 0.65))
        }
        for _ in 0..<Int(320_000 * scale) {
            let x = r.float(hillside.low.x, hillside.high.x)
            let y = r.float(-430, hillside.low.y)
            let s = size(0.06, 0.25, 0.42)
            chips.append(
                Chip(
                    posSize: SIMD4(x, y, 0.1 + s * 0.4, s), velAge: .zero, offsetDelay: .zero, parent: 0,
                    state: 3, seed: r.float(), tint: r.float(0.2, 0.7)))
        }
        print("decor: \(chips.count) chips and stones")
        return chips
    }
}

/// Writes the frames to an H.264 movie.
final class ClipWriter {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    var frame = 0
    let fps: Int32

    init(url: URL, width: Int, height: Int, fps: Int32) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: option(CommandLine.arguments, "--bitrate").flatMap(Int.init)
                        ?? 10_000_000
                ],
            ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.fps = fps
    }

    func append(_ renderer: Renderer) {
        guard let pool = adaptor.pixelBufferPool, let pixel = renderer.pixelBuffer(pool: pool) else { return }
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        adaptor.append(pixel, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
        frame += 1
    }

    func finish() {
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}
