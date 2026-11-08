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
    let terrainVertices: MTLBuffer
    let terrainIndices: MTLBuffer
    let terrainIndexCount: Int
    let shadowMap: MTLTexture
    let hdr: MTLTexture
    let hdrDepth: MTLTexture
    let output: MTLTexture
    let shadowSampler: MTLSamplerState
    let linearSampler: MTLSamplerState
    let blockPipeline: MTLRenderPipelineState
    let terrainPipeline: MTLRenderPipelineState
    let blockShadow: MTLRenderPipelineState
    let terrainShadow: MTLRenderPipelineState
    let tonemap: MTLRenderPipelineState
    let sky: MTLRenderPipelineState
    let skyDepth: MTLDepthStencilState
    let opaqueDepth: MTLDepthStencilState
    var dust: DustField?
    let restCentres: MTLBuffer
    var camera: CameraUniforms

    init(
        device: MTLDevice, library: MTLLibrary, hillside: Hillside, width: Int, height: Int, supersample: Int
    ) throws {
        self.device = device
        self.library = library
        self.hillside = hillside
        self.width = width
        self.height = height
        self.supersample = supersample
        queue = device.makeCommandQueue()!
        blockVertices = hillside.vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
        }
        blockIndices = hillside.indices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)!
        }
        indexCount = hillside.indices.count
        let rest = hillside.blocks.map { SIMD4<Float>($0.centre, Float($0.size)) }
        restCentres = device.makeBuffer(bytes: rest, length: 16 * rest.count)!
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
                        (h(i, j - 1) - h(i, j + 1)) / (2 * t.spacing), 1))
                vertices += [x, y, h(i, j), n.x, n.y, n.z]
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
        terrainVertices = device.makeBuffer(bytes: vertices, length: vertices.count * 4)!
        terrainIndices = device.makeBuffer(bytes: indices, length: indices.count * 4)!
        terrainIndexCount = indices.count

        let shadowDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: 4096, height: 4096, mipmapped: false)
        shadowDescriptor.usage = [.renderTarget, .shaderRead]
        shadowDescriptor.storageMode = .private
        shadowMap = device.makeTexture(descriptor: shadowDescriptor)!
        let hdrDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width * supersample, height: height * supersample,
            mipmapped: false)
        hdrDescriptor.usage = [.renderTarget, .shaderRead]
        hdrDescriptor.storageMode = .private
        hdr = device.makeTexture(descriptor: hdrDescriptor)!
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width * supersample, height: height * supersample,
            mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        hdrDepth = device.makeTexture(descriptor: depthDescriptor)!
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        output = device.makeTexture(descriptor: outputDescriptor)!

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
            vertex: String, fragment: String?, depth: Bool = true, color: MTLPixelFormat? = .rgba16Float
        ) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)!
            if let fragment { d.fragmentFunction = library.makeFunction(name: fragment)! }
            if let color { d.colorAttachments[0].pixelFormat = color }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        blockPipeline = try pipeline(vertex: "blockVertex", fragment: "blockFragment")
        terrainPipeline = try pipeline(vertex: "terrainVertex", fragment: "terrainFragment")
        blockShadow = try pipeline(vertex: "blockShadowVertex", fragment: nil, color: nil)
        terrainShadow = try pipeline(vertex: "terrainShadowVertex", fragment: nil, color: nil)
        let bgra = try pipeline(vertex: "fullscreen", fragment: "tonemap", depth: false, color: .bgra8Unorm)
        tonemap = bgra
        sky = try pipeline(vertex: "skyVertex", fragment: "skyFragment")
        let skyState = MTLDepthStencilDescriptor()
        skyState.depthCompareFunction = .lessEqual
        skyState.isDepthWriteEnabled = false
        skyDepth = device.makeDepthStencilState(descriptor: skyState)!
        let depthState = MTLDepthStencilDescriptor()
        depthState.depthCompareFunction = .less
        depthState.isDepthWriteEnabled = true
        opaqueDepth = device.makeDepthStencilState(descriptor: depthState)!

        let aspect = Float(width) / Float(height)
        let sun = simd_normalize(SIMD3<Float>(-0.78, -0.42, 0.46))
        let eye = option(CommandLine.arguments, "--eye").map(parseVector) ?? SIMD3<Float>(-18, -118, 22)
        let target = option(CommandLine.arguments, "--target").map(parseVector) ?? SIMD3<Float>(88, 8, 18)
        let vp =
            perspective(
                fovY: (option(CommandLine.arguments, "--fov").flatMap(Float.init) ?? 34) * .pi / 180,
                aspect: aspect, near: 2, far: 900)
            * lookAt(eye: eye, target: target, up: SIMD3(0, 0, 1))
        let centre = (hillside.low + hillside.high) * 0.5
        let lightEye = centre + sun * 400
        let lightView = lookAt(eye: lightEye, target: centre, up: SIMD3(0, 0, 1))
        let ortho = orthographic(left: -230, right: 230, bottom: -180, top: 180, near: 50, far: 800)
        camera = CameraUniforms(
            viewProjection: vp, shadow: ortho * lightView, eye: SIMD4(eye, 1), sun: SIMD4(sun, 0),
            fogColor: SIMD4(0.46, 0.52, 0.62, 1),
            terrainOrigin: .zero, inverseViewProjection: vp.inverse,
            dustLow: .zero, dustHigh: .zero, misc: .zero)
    }

    /// Renders one frame with block poses from `pose` (pairs of float4); returns GPU time (s).
    @discardableResult
    func render(pose: MTLBuffer, time: Float) -> Double {
        let buffer = queue.makeCommandBuffer()!
        var cam = camera
        cam.misc = SIMD4(time, 0, 0, 0)
        // Shadow map.
        let shadowPass = MTLRenderPassDescriptor()
        shadowPass.depthAttachment.texture = shadowMap
        shadowPass.depthAttachment.loadAction = .clear
        shadowPass.depthAttachment.storeAction = .store
        shadowPass.depthAttachment.clearDepth = 1
        let shadow = buffer.makeRenderCommandEncoder(descriptor: shadowPass)!
        shadow.setDepthStencilState(opaqueDepth)
        shadow.setCullMode(.front)
        shadow.setRenderPipelineState(blockShadow)
        shadow.setVertexBuffer(blockVertices, offset: 0, index: 0)
        shadow.setVertexBuffer(pose, offset: 0, index: 1)
        shadow.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)
        shadow.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
            indexBufferOffset: 0)
        shadow.setRenderPipelineState(terrainShadow)
        shadow.setCullMode(.none)
        shadow.setVertexBuffer(terrainVertices, offset: 0, index: 0)
        shadow.drawIndexedPrimitives(
            type: .triangle, indexCount: terrainIndexCount, indexType: .uint32, indexBuffer: terrainIndices,
            indexBufferOffset: 0)
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
        scene.setFragmentSamplerState(shadowSampler, index: 0)
        scene.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        scene.setRenderPipelineState(blockPipeline)
        scene.setVertexBuffer(blockVertices, offset: 0, index: 0)
        scene.setVertexBuffer(pose, offset: 0, index: 1)
        scene.setVertexBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 2)
        scene.setVertexBuffer(restCentres, offset: 0, index: 3)
        scene.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
            indexBufferOffset: 0)
        scene.setRenderPipelineState(terrainPipeline)
        scene.setCullMode(.none)
        scene.setVertexBuffer(terrainVertices, offset: 0, index: 0)
        scene.drawIndexedPrimitives(
            type: .triangle, indexCount: terrainIndexCount, indexType: .uint32, indexBuffer: terrainIndices,
            indexBufferOffset: 0)
        scene.setRenderPipelineState(sky)
        scene.setDepthStencilState(skyDepth)
        scene.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        scene.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        scene.endEncoding()
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
        final.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        final.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        return buffer.gpuEndTime - buffer.gpuStartTime
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
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 24_000_000],
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
