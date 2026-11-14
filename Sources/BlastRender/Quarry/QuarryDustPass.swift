import BlastCore
import Metal

/// The quarry's dust drawn over a frame: ray-marched against the scene's depth into a target of the frame's size,
/// then blended over. Illustrative.
final class QuarryDustPass {
    private(set) var target: MTLTexture
    /// The march, one for both scenes since stage 3l (emmettl/bombcad-work#146).
    let march: MTLRenderPipelineState
    let blend: MTLRenderPipelineState
    /// A ridge cut's crack jets, drawn as thin streaks over the scene before the march (stage 3i).
    let jets: MTLRenderPipelineState
    let jetDepth: MTLDepthStencilState
    let sampler: MTLSamplerState

    static func makeTarget(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    /// The target made again for a frame of another size.
    func resize(device: MTLDevice, width: Int, height: Int) {
        target = Self.makeTarget(device: device, width: width, height: height)
    }

    init(device: MTLDevice, library: MTLLibrary, width: Int, height: Int) throws {
        target = Self.makeTarget(device: device, width: width, height: height)
        let draw = MTLRenderPipelineDescriptor()
        draw.vertexFunction = library.makeFunction(name: "fullscreen")!
        draw.fragmentFunction = library.makeFunction(name: "dustFragment")!
        draw.colorAttachments[0].pixelFormat = .rgba16Float
        march = try device.makeRenderPipelineState(descriptor: draw)
        let over = MTLRenderPipelineDescriptor()
        over.vertexFunction = library.makeFunction(name: "fullscreen")!
        over.fragmentFunction = library.makeFunction(name: "dustComposite")!
        over.colorAttachments[0].pixelFormat = .rgba16Float
        over.colorAttachments[0].isBlendingEnabled = true
        over.colorAttachments[0].rgbBlendOperation = .add
        over.colorAttachments[0].alphaBlendOperation = .add
        over.colorAttachments[0].sourceRGBBlendFactor = .one
        over.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        over.colorAttachments[0].sourceAlphaBlendFactor = .one
        over.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        blend = try device.makeRenderPipelineState(descriptor: over)
        over.vertexFunction = library.makeFunction(name: "jetVertex")!
        over.fragmentFunction = library.makeFunction(name: "jetFragment")!
        over.depthAttachmentPixelFormat = .depth32Float
        jets = try device.makeRenderPipelineState(descriptor: over)
        let tested = MTLDepthStencilDescriptor()
        tested.depthCompareFunction = .less
        tested.isDepthWriteEnabled = false
        jetDepth = device.makeDepthStencilState(descriptor: tested)!
        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: linear)!
    }

    func composite(
        _ dust: QuarryDustField, buffer: MTLCommandBuffer, hdr: MTLTexture, depth: MTLTexture,
        camera: QuarryCameraUniforms
    ) {
        var cam = camera
        if dust.jetCount > 0 {
            let jetPass = MTLRenderPassDescriptor()
            jetPass.colorAttachments[0].texture = hdr
            jetPass.colorAttachments[0].loadAction = .load
            jetPass.colorAttachments[0].storeAction = .store
            jetPass.depthAttachment.texture = depth
            jetPass.depthAttachment.loadAction = .load
            jetPass.depthAttachment.storeAction = .store
            let encoder = buffer.makeRenderCommandEncoder(descriptor: jetPass)!
            encoder.setRenderPipelineState(jets)
            encoder.setDepthStencilState(jetDepth)
            encoder.setCullMode(.none)
            encoder.setVertexBuffer(dust.jets, offset: 0, index: 0)
            encoder.setVertexBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 0)
            encoder.setFragmentTexture(dust.light, index: 0)
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: dust.jetCount)
            encoder.endEncoding()
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(march)
        encoder.setFragmentTexture(dust.density[0], index: 0)
        encoder.setFragmentTexture(dust.light, index: 1)
        encoder.setFragmentTexture(depth, index: 2)
        encoder.setFragmentTexture(dust.noiseVolume, index: 3)
        // The billows ride the flow (stage 3j).
        encoder.setFragmentTexture(dust.velocity[0], index: 4)
        // Where the dust is thin enough to march as haze alone (stage 3l).
        encoder.setFragmentTexture(dust.hazeBound, index: 5)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentBytes(&cam, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 0)
        var u = dust.uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<QuarryDustField.Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let over = MTLRenderPassDescriptor()
        over.colorAttachments[0].texture = hdr
        over.colorAttachments[0].loadAction = .load
        over.colorAttachments[0].storeAction = .store
        let blendEncoder = buffer.makeRenderCommandEncoder(descriptor: over)!
        blendEncoder.setRenderPipelineState(blend)
        blendEncoder.setFragmentTexture(target, index: 0)
        blendEncoder.setFragmentSamplerState(sampler, index: 0)
        blendEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        blendEncoder.endEncoding()
    }
}
