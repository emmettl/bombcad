import CoreGraphics
import Foundation
import Metal
import SceneView
import simd

/// Layout matches `SceneUniforms` in `Scene.metal`.
private struct SceneUniforms {
    var viewProjection: simd_float4x4
    var eye: SIMD4<Float>
    var options: SIMD4<Float>
    var highlight: SIMD4<Float>
}

public enum SceneRenderError: Error {
    case missingShader
    case allocationFailed(String)
}

/// Draws a `SceneGeometry` from an `OrbitCamera`: solid triangles lit from the eye and seen only from
/// the side they face, then translucent triangles from both sides without hiding what lies behind
/// them, then lines a little in front of both. Anti-aliased with four samples per pixel.
public final class MeshRenderer {
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    public static let depthFormat = MTLPixelFormat.depth32Float
    public static let sampleCount = 4

    public let device: MTLDevice
    /// The pick number to highlight, if any, and the colour and strength of the highlight.
    public var highlighted: Int32?
    public var highlightColour = SIMD4<Float>(1, 0.75, 0.2, 0.55)
    public var background = MTLClearColor(red: 0.96, green: 0.96, blue: 0.95, alpha: 1)

    private let solidPipeline: MTLRenderPipelineState
    private let translucentPipeline: MTLRenderPipelineState
    private let linePipeline: MTLRenderPipelineState
    private let solidDepth: MTLDepthStencilState
    private let translucentDepth: MTLDepthStencilState
    private var buffers: (solid: MTLBuffer?, translucent: MTLBuffer?, lines: MTLBuffer?) = (nil, nil, nil)
    private var counts = (solid: 0, translucent: 0, lines: 0)

    public init(device: MTLDevice) throws {
        self.device = device
        guard
            let url = Bundle.module.url(forResource: "Scene", withExtension: "metal", subdirectory: "Shaders")
        else { throw SceneRenderError.missingShader }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(vertex: String, fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            descriptor.depthAttachmentPixelFormat = Self.depthFormat
            descriptor.rasterSampleCount = Self.sampleCount
            if blended {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        solidPipeline = try pipeline(vertex: "sceneVertex", fragment: "litFragment", blended: false)
        translucentPipeline = try pipeline(vertex: "sceneVertex", fragment: "litFragment", blended: true)
        linePipeline = try pipeline(vertex: "lineVertex", fragment: "flatFragment", blended: true)
        func depthState(writes: Bool) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = .lessEqual
            descriptor.isDepthWriteEnabled = writes
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw SceneRenderError.allocationFailed("depth state")
            }
            return state
        }
        solidDepth = try depthState(writes: true)
        translucentDepth = try depthState(writes: false)
    }

    /// Replaces what is drawn.
    public func setGeometry(_ geometry: SceneGeometry) {
        func buffer(_ vertices: [SceneGeometry.Vertex]) -> MTLBuffer? {
            guard !vertices.isEmpty else { return nil }
            return vertices.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
        }
        buffers = (buffer(geometry.solid), buffer(geometry.translucent), buffer(geometry.lines))
        counts = (geometry.solid.count, geometry.translucent.count, geometry.lines.count)
    }

    /// The camera's view and perspective projection, for a view of the given aspect ratio, with the
    /// near and far planes set about what it orbits.
    public static func viewProjection(_ camera: OrbitCamera, aspectRatio: Float) -> simd_float4x4 {
        let eye = camera.eye
        let forward = simd_normalize(camera.target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let view = simd_float4x4(
            rows: [
                SIMD4(right, -simd_dot(right, eye)), SIMD4(up, -simd_dot(up, eye)),
                SIMD4(-forward, simd_dot(forward, eye)), SIMD4(0, 0, 0, 1),
            ])
        let near = max(camera.distance * 0.01, 0.01)
        let far = camera.distance * 20
        let y = 1 / tan(camera.fieldOfView / 2)
        let x = y / max(aspectRatio, 1e-3)
        // Depth from 0 at the near plane to 1 at the far one, as Metal expects.
        let projection = simd_float4x4(
            rows: [
                SIMD4(x, 0, 0, 0), SIMD4(0, y, 0, 0),
                SIMD4(0, 0, far / (near - far), near * far / (near - far)),
                SIMD4(0, 0, -1, 0),
            ])
        return projection * view
    }

    /// Encodes one frame into a pass whose colour and depth attachments are multisampled.
    public func encode(
        into commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, camera: OrbitCamera,
        aspectRatio: Float
    ) {
        descriptor.colorAttachments[0].clearColor = background
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.depthAttachment.clearDepth = 1
        descriptor.depthAttachment.loadAction = .clear
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        var uniforms = SceneUniforms(
            viewProjection: Self.viewProjection(camera, aspectRatio: aspectRatio), eye: SIMD4(camera.eye, 1),
            options: SIMD4(Float(highlighted ?? -1), 2e-4, 0, 0), highlight: highlightColour)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SceneUniforms>.stride, index: 1)
        encoder.setFrontFacing(.counterClockwise)
        if let solid = buffers.solid {
            encoder.setRenderPipelineState(solidPipeline)
            encoder.setDepthStencilState(solidDepth)
            encoder.setCullMode(.back)
            encoder.setVertexBuffer(solid, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: counts.solid)
        }
        if let translucent = buffers.translucent {
            encoder.setRenderPipelineState(translucentPipeline)
            encoder.setDepthStencilState(translucentDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(translucent, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: counts.translucent)
        }
        if let lines = buffers.lines {
            encoder.setRenderPipelineState(linePipeline)
            encoder.setDepthStencilState(translucentDepth)
            encoder.setVertexBuffer(lines, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: counts.lines)
        }
        encoder.endEncoding()
    }

    /// Renders one frame offscreen at the given size in pixels, blocking until the GPU has finished.
    public func snapshot(commandQueue: MTLCommandQueue, width: Int, height: Int, camera: OrbitCamera)
        -> CGImage?
    {
        func texture(_ format: MTLPixelFormat, multisampled: Bool) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            if multisampled {
                descriptor.textureType = .type2DMultisample
                descriptor.sampleCount = Self.sampleCount
                descriptor.storageMode = .private
            } else {
                descriptor.storageMode = .shared
            }
            return device.makeTexture(descriptor: descriptor)
        }
        guard width > 0, height > 0,
            let colour = texture(Self.pixelFormat, multisampled: true),
            let depth = texture(Self.depthFormat, multisampled: true),
            let resolved = texture(Self.pixelFormat, multisampled: false),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colour
        pass.colorAttachments[0].resolveTexture = resolved
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.storeAction = .dontCare
        encode(
            into: commandBuffer, descriptor: pass, camera: camera, aspectRatio: Float(width) / Float(height))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        resolved.getBytes(
            &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
            decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)
    }
}
