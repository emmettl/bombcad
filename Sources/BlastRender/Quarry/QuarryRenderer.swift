import BlastCore
import BlastModel
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import simd

/// Layout matches `QuarryCamera` in `QuarryRender.metal`.
public struct QuarryCameraUniforms {
    public var viewProjection: simd_float4x4
    public var shadow: simd_float4x4
    public var eye: SIMD4<Float>
    public var sun: SIMD4<Float>
    public var fogColor: SIMD4<Float>
    public var terrainOrigin: SIMD4<Float>
    public var inverseViewProjection: simd_float4x4
    public var dustLow: SIMD4<Float>
    public var dustHigh: SIMD4<Float>
    public var misc: SIMD4<Float>
}

public enum QuarryMatrix {
    public static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return simd_float4x4(
            SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0), SIMD4(0, 0, z, -1), SIMD4(0, 0, z * near, 0))
    }

    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let f = simd_normalize(target - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return simd_float4x4(
            SIMD4(s.x, u.x, -f.x, 0), SIMD4(s.y, u.y, -f.y, 0), SIMD4(s.z, u.z, -f.z, 0),
            SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1))
    }

    public static func orthographic(
        left: Float, right: Float, bottom: Float, top: Float, near: Float, far: Float
    )
        -> simd_float4x4
    {
        simd_float4x4(
            SIMD4(2 / (right - left), 0, 0, 0), SIMD4(0, 2 / (top - bottom), 0, 0),
            SIMD4(0, 0, 1 / (near - far), 0),
            SIMD4((left + right) / (left - right), (top + bottom) / (bottom - top), near / (near - far), 1))
    }

}

/// How much the renderer draws: everything for the film, less for the play window.
public struct QuarryRenderQuality: Sendable {
    public var shadowSize = 8192
    public var decorScale: Float = 1
    /// Frames between redraws of the top-down height the chips land on (the blocks included).
    public var heightEvery = 1
    public static let film = QuarryRenderQuality()
    public static let live = QuarryRenderQuality(shadowSize: 4096, decorScale: 0.35, heightEvery: 6)
}

public final class QuarryRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let hillside: QuarryFace
    public let width: Int
    public let height: Int
    public let supersample: Int
    public let blockVertices: MTLBuffer
    public let blockIndices: MTLBuffer
    public let indexCount: Int
    public let dressingVertices: MTLBuffer
    public let dressingIndices: MTLBuffer
    public let dressingCount: Int
    public let identityPose: MTLBuffer
    public let identityRest: MTLBuffer
    public let terrainVertices: MTLBuffer
    public let terrainIndices: MTLBuffer
    public let terrainIndexCount: Int
    public let shadowMap: MTLTexture
    public let hdr: MTLTexture
    public let hdrDepth: MTLTexture
    public let output: MTLTexture
    public let heightMap: MTLTexture
    public let noDust: MTLTexture
    public let shadowSampler: MTLSamplerState
    public let linearSampler: MTLSamplerState
    public let blockPipeline: MTLRenderPipelineState
    public let terrainPipeline: MTLRenderPipelineState
    public let chipPipeline: MTLRenderPipelineState
    public let blockShadow: MTLRenderPipelineState
    public let terrainShadow: MTLRenderPipelineState
    public let chipShadow: MTLRenderPipelineState
    public let chipUpdate: MTLComputePipelineState
    public let tonemap: MTLRenderPipelineState
    public let sky: MTLRenderPipelineState
    public let aoPipeline: MTLRenderPipelineState
    public let skyDepth: MTLDepthStencilState
    public let opaqueDepth: MTLDepthStencilState
    public var dust: QuarryDustField?
    let dustPass: QuarryDustPass
    public let restCentres: MTLBuffer
    public let chips: MTLBuffer
    public let chipCount: Int
    public var camera: QuarryCameraUniforms
    public let cameraPath: QuarryCameraPath
    /// A view that replaces the path, for the play window.
    public var viewOverride: (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float)?
    public let quality: QuarryRenderQuality
    public var heightFrame = 0
    public let pristineChips: MTLBuffer
    public let topDown: simd_float4x4
    public let heightTop: Float = 130
    public let heightBottom: Float = 0
    public let aspect: Float
    public let frameRate: Float

    public init(
        device: MTLDevice, face hillside: QuarryFace, width: Int, height: Int, supersample: Int,
        path: QuarryCameraPath, frameRate: Float, quality: QuarryRenderQuality = .film,
        sun: SIMD3<Float> = SIMD3(0.86, -0.42, 0.26)
    ) throws {
        self.quality = quality
        self.device = device
        let library = try QuarryShaders.library(device: device, file: "QuarryRender", bundle: Bundle.module)
        self.library = library
        dustPass = try QuarryDustPass(
            device: device, library: library, width: width * supersample, height: height * supersample)
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
        let chipData = QuarryDecor.make(face: hillside, scale: quality.decorScale)
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
        let sun = simd_normalize(sun)
        let centre = (hillside.low + hillside.high) * 0.5
        let lightEye = centre + sun * 420
        let lightView = QuarryMatrix.lookAt(eye: lightEye, target: centre, up: SIMD3(0, 0, 1))
        let reach = max(260, (hillside.high.x - hillside.low.x) * 0.7)
        let ortho = QuarryMatrix.orthographic(
            left: -reach, right: reach, bottom: -reach / 2, top: reach / 2, near: 30, far: 900 + reach)
        let span = hillside.high - hillside.low
        let middle = (hillside.high + hillside.low) * 0.5
        topDown =
            QuarryMatrix.orthographic(
                left: -span.x / 2, right: span.x / 2, bottom: -span.y / 2, top: span.y / 2, near: 0,
                far: heightTop - heightBottom)
            * QuarryMatrix.lookAt(
                eye: SIMD3(middle.x, middle.y, heightTop), target: SIMD3(middle.x, middle.y, 0),
                up: SIMD3(0, 1, 0))
        camera = QuarryCameraUniforms(
            viewProjection: matrix_identity_float4x4, shadow: ortho * lightView, eye: .zero,
            sun: SIMD4(sun, 0),
            fogColor: SIMD4(0.6, 0.55, 0.5, 1), terrainOrigin: .zero,
            inverseViewProjection: matrix_identity_float4x4,
            dustLow: .zero, dustHigh: .zero, misc: .zero)
    }

    /// Renders one frame with block poses from `pose`, `previous` being the frame before, stepping
    /// the decorative chips by one frame. Returns the GPU time (s).
    @discardableResult
    public func render(pose: MTLBuffer, previous: MTLBuffer, time: Float) -> Double {
        let buffer = queue.makeCommandBuffer()!
        var cam = camera
        let view = viewOverride ?? cameraPath.at(time)
        let tanHalf = tan(view.fovY * 0.5)
        let vp =
            QuarryMatrix.perspective(fovY: view.fovY, aspect: aspect, near: 3, far: 1600)
            * QuarryMatrix.lookAt(eye: view.eye, target: view.target, up: SIMD3(0, 0, 1))
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
        shadow.setVertexBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 2)
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
        scene.setFragmentBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 0)
        scene.setVertexBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 2)
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
        ao.setFragmentBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 0)
        ao.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        ao.endEncoding()
        if let dust { dustPass.composite(dust, buffer: buffer, hdr: hdr, depth: hdrDepth, camera: cam) }
        // Tonemap and downsample.
        let finalPass = MTLRenderPassDescriptor()
        finalPass.colorAttachments[0].texture = output
        finalPass.colorAttachments[0].loadAction = .dontCare
        finalPass.colorAttachments[0].storeAction = .store
        let final = buffer.makeRenderCommandEncoder(descriptor: finalPass)!
        final.setRenderPipelineState(tonemap)
        final.setFragmentTexture(hdr, index: 0)
        final.setFragmentSamplerState(linearSampler, index: 0)
        final.setFragmentBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 0)
        final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        final.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.gpuEndTime - buffer.gpuStartTime
    }

    /// One frame's step of the decorative chips, over a top-down height of the scene.
    public func stepDecor(pose: MTLBuffer, previous: MTLBuffer, time: Float) {
        let buffer = queue.makeCommandBuffer()!
        var top = camera
        top.shadow = topDown
        heightFrame += 1
        if heightFrame % quality.heightEvery == 1 || quality.heightEvery == 1 {
            let heightPass = MTLRenderPassDescriptor()
            heightPass.depthAttachment.texture = heightMap
            heightPass.depthAttachment.loadAction = .clear
            heightPass.depthAttachment.storeAction = .store
            heightPass.depthAttachment.clearDepth = 1
            let encoder = buffer.makeRenderCommandEncoder(descriptor: heightPass)!
            encoder.setDepthStencilState(opaqueDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBytes(&top, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 2)
            encoder.setRenderPipelineState(blockShadow)
            encoder.setVertexBuffer(blockVertices, offset: 0, index: 0)
            encoder.setVertexBuffer(pose, offset: 0, index: 1)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
                indexBufferOffset: 0)
            encoder.setRenderPipelineState(terrainShadow)
            encoder.setVertexBuffer(terrainVertices, offset: 0, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle, indexCount: terrainIndexCount, indexType: .uint32,
                indexBuffer: terrainIndices,
                indexBufferOffset: 0)
            encoder.endEncoding()
        }
        var chipUniforms = QuarryDecor.Uniforms(
            dt: 1 / frameRate, gravity: 9.81, time: time, pad: 0, low: SIMD4(hillside.low, 0),
            size: SIMD4(
                hillside.high.x - hillside.low.x, hillside.high.y - hillside.low.y, heightTop, heightBottom))
        let compute = buffer.makeComputeCommandEncoder()!
        compute.setComputePipelineState(chipUpdate)
        compute.setBuffer(chips, offset: 0, index: 0)
        compute.setBuffer(pose, offset: 0, index: 1)
        compute.setBuffer(previous, offset: 0, index: 2)
        compute.setTexture(heightMap, index: 0)
        compute.setBytes(&chipUniforms, length: MemoryLayout<QuarryDecor.Uniforms>.stride, index: 3)
        compute.dispatchThreads(
            MTLSize(width: chipCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        compute.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Back to the chips as built, for a jump backward.
    public func resetDecor() {
        chips.contents().copyMemory(from: pristineChips.contents(), byteCount: chips.length)
    }

    public func savePNG(_ url: URL) {
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
}

/// The camera over the clip: from one view to another, easing, with a long lens.
public struct QuarryCameraPath: Sendable {
    public var eyes: (SIMD3<Float>, SIMD3<Float>)
    public var targets: (SIMD3<Float>, SIMD3<Float>)
    public var fovY: (Float, Float)
    public var duration: Float

    public init(
        eyes: (SIMD3<Float>, SIMD3<Float>), targets: (SIMD3<Float>, SIMD3<Float>), fovY: (Float, Float),
        duration: Float
    ) {
        self.eyes = eyes
        self.targets = targets
        self.fovY = fovY
        self.duration = duration
    }

    public func at(_ time: Float) -> (eye: SIMD3<Float>, target: SIMD3<Float>, fovY: Float) {
        let u = max(0, min(1, time / duration))
        let s = u * u * u * (u * (u * 6 - 15) + 10)
        return (
            eyes.0 + (eyes.1 - eyes.0) * s, targets.0 + (targets.1 - targets.0) * s,
            (fovY.0 + (fovY.1 - fovY.0) * s) * .pi / 180
        )
    }
}

/// Decorative chips, gravel and scrub: instanced little polyhedra, never rigid bodies.
public enum QuarryDecor {
    /// Layout matches `QuarryChip` in `QuarryRender.metal`.
    public struct Chip {
        public var posSize: SIMD4<Float>
        public var velAge: SIMD4<Float>
        public var offsetDelay: SIMD4<Float>
        public var parent: UInt32
        public var state: UInt32
        public var seed: Float
        public var tint: Float
    }

    /// Layout matches `QuarryChipUniforms` in `QuarryRender.metal`.
    public struct Uniforms {
        public var dt: Float
        public var gravity: Float
        public var time: Float
        public var pad: Float
        public var low: SIMD4<Float>
        public var size: SIMD4<Float>
    }

    public static func make(face hillside: QuarryFace, scale: Float = 1) -> [Chip] {
        var r = QuarryRandom(seed: 8_675_309)
        var chips: [Chip] = []
        chips.reserveCapacity(1_000_000)
        func size(_ low: Float, _ high: Float, _ power: Float) -> Float {
            let u = r.float()
            return min(high, low * pow(max(u, 1e-4), -power))
        }
        // Chips that leave their blocks, and fines that trickle after them and settle on the pile.
        // Nothing is strewn on the floor beforehand: what lies there comes from the event.
        for (n, block) in hillside.blocks.enumerated() where !block.skin {
            let c = block.centre
            let count = max(2, min(8, Int(block.size * block.size * 3 + 2)))
            for k in 0..<count {
                let anchor = hillside.chipAnchors[6 * n + k % 6]
                chips.append(
                    Chip(
                        posSize: SIMD4(c, size(0.06, 0.5, 0.42)), velAge: .zero,
                        offsetDelay: SIMD4(anchor, r.float(0.02, 1.4)), parent: UInt32(n), state: 0,
                        seed: r.float(), tint: r.float(0.25, 0.9)))
            }
            // Spalls: a few larger slabs off the bigger blocks, for a spread of sizes in the pile.
            if block.size > 1.3 {
                for k in 0..<Int(block.size) {
                    let anchor = hillside.chipAnchors[6 * n + (k + 1) % 6]
                    chips.append(
                        Chip(
                            posSize: SIMD4(c, r.float(0.3, 0.7)), velAge: .zero,
                            offsetDelay: SIMD4(anchor, r.float(0.05, 0.8)), parent: UInt32(n), state: 0,
                            seed: r.float(), tint: r.float(0.3, 0.9)))
                }
            }
            let fines = Int((Float(4 + Int(block.size * 4)) * scale).rounded())
            for k in 0..<fines {
                let anchor = hillside.chipAnchors[6 * n + (k + 3) % 6]
                chips.append(
                    Chip(
                        posSize: SIMD4(c, size(0.025, 0.12, 0.35)), velAge: .zero,
                        offsetDelay: SIMD4(anchor, r.float(0.3, 3.0)), parent: UInt32(n), state: 0,
                        seed: r.float(), tint: r.float(0.3, 0.95)))
            }
        }
        print("decor: \(chips.count) chips and stones")
        return chips
    }
}
