import Foundation
import Metal
import simd

/// A passive dust field for the eye: a coarse incompressible smoke box (stable-fluids semi-Lagrangian
/// advection, Jacobi pressure, buoyancy, a little wind), fed by the firings and by blocks as they
/// strike the ground, ray-marched over the frame. Not the collapse's air-carried dust: that needs
/// the compressible air solver and its element work, far from an interactive scene.
final class DustField {
    /// Layout matches `HillsideDustUniforms` in `HillsideDust.metal`.
    struct Uniforms {
        var low: SIMD4<Float>
        var hdtsteps: SIMD4<Float>
        var dims: SIMD4<Int32>
        var wind: SIMD4<Float>
        var sun: SIMD4<Float>
        var lowHigh: SIMD4<Float>
    }

    let device: MTLDevice
    let queue: MTLCommandQueue
    let dims: SIMD3<Int>
    let h: Float
    let low: SIMD3<Float>
    let high: SIMD3<Float>
    var velocity: [MTLTexture]
    var density: [MTLTexture]
    var pressure: [MTLTexture]
    let divergence: MTLTexture
    let light: MTLTexture
    let solid: MTLTexture
    let source: MTLBuffer
    let pointer: UnsafeMutablePointer<SIMD4<Float>>
    var touched: [Int] = []
    let pipelines: [String: MTLComputePipelineState]
    let composite: MTLRenderPipelineState
    let halfDust: MTLTexture
    let dustDraw: MTLRenderPipelineState
    let firings: [Firing]
    var uniforms: Uniforms
    var lastTime: Float = 0
    let sampler: MTLSamplerState

    init(
        device: MTLDevice, library: MTLLibrary, hillside: Hillside, firings: [Firing], width: Int,
        height: Int, sun: SIMD3<Float>
    ) throws {
        self.device = device
        self.firings = firings
        queue = device.makeCommandQueue()!
        let h = option(CommandLine.arguments, "--dust-h").flatMap(Float.init) ?? 1.0
        let low = SIMD3<Float>(-45, -165, -3)
        let extent = SIMD3<Float>(282, 237, 129)
        let dims = SIMD3<Int>(Int(extent.x / h), Int(extent.y / h), Int(extent.z / h))
        let high = low + h * SIMD3<Float>(dims)
        self.h = h
        self.low = low
        self.dims = dims
        self.high = high
        func texture(_ format: MTLPixelFormat) -> MTLTexture {
            let d = MTLTextureDescriptor()
            d.textureType = .type3D
            d.pixelFormat = format
            d.width = dims.x
            d.height = dims.y
            d.depth = dims.z
            d.usage = [.shaderRead, .shaderWrite]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        velocity = [texture(.rgba16Float), texture(.rgba16Float)]
        density = [texture(.r16Float), texture(.r16Float)]
        pressure = [texture(.r16Float), texture(.r16Float)]
        divergence = texture(.r16Float)
        light = texture(.r16Float)
        let solidDescriptor = MTLTextureDescriptor()
        solidDescriptor.textureType = .type3D
        solidDescriptor.pixelFormat = .r8Unorm
        solidDescriptor.width = dims.x
        solidDescriptor.height = dims.y
        solidDescriptor.depth = dims.z
        solidDescriptor.usage = [.shaderRead]
        solidDescriptor.storageMode = .managed
        let solidTexture = device.makeTexture(descriptor: solidDescriptor)!
        var solidBytes = [UInt8](repeating: 0, count: dims.x * dims.y * dims.z)
        for k in 0..<dims.z {
            for j in 0..<dims.y {
                for i in 0..<dims.x {
                    let world = low + h * (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5)
                    solidBytes[i + dims.x * (j + dims.y * k)] =
                        world.z < hillside.height(hillside.original, world.x, world.y) ? 255 : 0
                }
            }
        }
        solidTexture.replace(
            region: MTLRegionMake3D(0, 0, 0, dims.x, dims.y, dims.z), mipmapLevel: 0, slice: 0,
            withBytes: solidBytes, bytesPerRow: dims.x, bytesPerImage: dims.x * dims.y)
        solid = solidTexture
        let cells = dims.x * dims.y * dims.z
        source = device.makeBuffer(length: 16 * cells, options: .storageModeShared)!
        memset(source.contents(), 0, 16 * cells)
        pointer = source.contents().bindMemory(to: SIMD4<Float>.self, capacity: cells)
        var map: [String: MTLComputePipelineState] = [:]
        for name in [
            "dustAddSources", "dustAdvectVelocity", "dustForces", "dustDivergence", "dustJacobi",
            "dustProject", "dustAdvectDensity", "dustLight",
        ] {
            map[name] = try device.makeComputePipelineState(function: library.makeFunction(name: name)!)
        }
        pipelines = map
        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        linear.rAddressMode = .clampToEdge
        sampler = device.makeSamplerState(descriptor: linear)!
        uniforms = Uniforms(
            low: SIMD4(low, 0), hdtsteps: SIMD4(h, 0, 0, 0),
            dims: SIMD4(Int32(dims.x), Int32(dims.y), Int32(dims.z), 0),
            wind: SIMD4(1.4, -0.3, 0.05, 0), sun: SIMD4(sun, 0), lowHigh: SIMD4(high, 0))
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        halfDust = device.makeTexture(descriptor: d)!
        let draw = MTLRenderPipelineDescriptor()
        draw.vertexFunction = library.makeFunction(name: "fullscreen")!
        draw.fragmentFunction = library.makeFunction(name: "dustFragment")!
        draw.colorAttachments[0].pixelFormat = .rgba16Float
        dustDraw = try device.makeRenderPipelineState(descriptor: draw)
        let blend = MTLRenderPipelineDescriptor()
        blend.vertexFunction = library.makeFunction(name: "fullscreen")!
        blend.fragmentFunction = library.makeFunction(name: "dustComposite")!
        blend.colorAttachments[0].pixelFormat = .rgba16Float
        blend.colorAttachments[0].isBlendingEnabled = true
        blend.colorAttachments[0].rgbBlendOperation = .add
        blend.colorAttachments[0].alphaBlendOperation = .add
        blend.colorAttachments[0].sourceRGBBlendFactor = .one
        blend.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blend.colorAttachments[0].sourceAlphaBlendFactor = .one
        blend.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        composite = try device.makeRenderPipelineState(descriptor: blend)
        // A first clear of the private textures so the first frame is defined.
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        encoder.endEncoding()
        buffer.commit()
    }

    private func add(_ p: SIMD3<Float>, dust: Float, velocity v: SIMD3<Float>) {
        let g = (p - low) / h
        let c = SIMD3<Int>(Int(g.x), Int(g.y), Int(g.z))
        guard c.x >= 0, c.y >= 0, c.z >= 0, c.x < dims.x, c.y < dims.y, c.z < dims.z else { return }
        let index = c.x + dims.x * (c.y + dims.y * c.z)
        if pointer[index] == .zero { touched.append(index) }
        pointer[index] += SIMD4(v * dust, dust)
    }

    /// One 1/30 s dust step: sources from the firings and blocks (their poses this frame and last),
    /// then the fluid.
    func step(
        pose: MTLBuffer, previous: MTLBuffer, bodies: Int, time: Float, restSize: [Float], frameRate: Float
    ) -> Double {
        let dt = 1 / frameRate
        for firing in firings where time >= firing.time && time < firing.time + 0.35 {
            let age = (time - firing.time) / 0.35
            // A plume along the face from the firing, pushed out and up.
            var r = Random(seed: UInt64(firing.position.x * 100) &+ UInt64(time * 1000))
            for _ in 0..<900 {
                let offset = r.unit() * r.float(0.5, 11)
                let p = firing.position + SIMD3(offset.x, offset.y - 5, offset.z * 0.8 + 4)
                let radial = simd_normalize(offset + SIMD3(0, -1, 3))
                add(p, dust: 80 * (1 - age), velocity: radial * 24 + SIMD3(0, -14, 30))
            }
        }
        let posePointer = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        let previousPointer = previous.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        for n in 0..<bodies {
            let p = posePointer[2 * n]
            let q = previousPointer[2 * n]
            guard p.w != 0 else { continue }
            let v = SIMD3(p.x - q.x, p.y - q.y, p.z - q.z) * frameRate
            let speed = simd_length(v)
            // A moving block sheds fines; a block striking something makes more.
            let size = restSize[n]
            var dust: Float = 0
            if speed > 2.5 { dust += 0.12 * speed * size * size }
            add(SIMD3(p.x, p.y, p.z), dust: dust, velocity: v)
        }
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        var u = uniforms
        u.hdtsteps.y = dt
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        func run(_ name: String) {
            encoder.setComputePipelineState(pipelines[name]!)
            encoder.dispatchThreads(
                MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 8))
        }
        // Sources.
        encoder.setBuffer(source, offset: 0, index: 1)
        encoder.setTexture(velocity[0], index: 0)
        encoder.setTexture(density[0], index: 1)
        encoder.setTexture(velocity[1], index: 2)
        encoder.setTexture(density[1], index: 3)
        run("dustAddSources")
        encoder.memoryBarrier(scope: .textures)
        velocity.swapAt(0, 1)
        density.swapAt(0, 1)
        // Velocity: advect, forces.
        encoder.setSamplerState(sampler, index: 0)
        encoder.setTexture(velocity[0], index: 0)
        encoder.setTexture(velocity[1], index: 1)
        run("dustAdvectVelocity")
        encoder.memoryBarrier(scope: .textures)
        velocity.swapAt(0, 1)
        encoder.setTexture(velocity[0], index: 0)
        encoder.setTexture(density[0], index: 1)
        encoder.setTexture(velocity[1], index: 2)
        run("dustForces")
        encoder.memoryBarrier(scope: .textures)
        velocity.swapAt(0, 1)
        // Pressure.
        encoder.setTexture(velocity[0], index: 0)
        encoder.setTexture(solid, index: 1)
        encoder.setTexture(divergence, index: 2)
        run("dustDivergence")
        encoder.memoryBarrier(scope: .textures)
        for _ in 0..<22 {
            encoder.setTexture(pressure[0], index: 0)
            encoder.setTexture(divergence, index: 1)
            encoder.setTexture(solid, index: 2)
            encoder.setTexture(pressure[1], index: 3)
            run("dustJacobi")
            encoder.memoryBarrier(scope: .textures)
            pressure.swapAt(0, 1)
        }
        encoder.setTexture(velocity[0], index: 0)
        encoder.setTexture(pressure[0], index: 1)
        encoder.setTexture(solid, index: 2)
        encoder.setTexture(velocity[1], index: 3)
        run("dustProject")
        encoder.memoryBarrier(scope: .textures)
        velocity.swapAt(0, 1)
        // Density advection and its light.
        encoder.setTexture(density[0], index: 0)
        encoder.setTexture(velocity[0], index: 1)
        encoder.setTexture(density[1], index: 2)
        encoder.setTexture(solid, index: 3)
        run("dustAdvectDensity")
        encoder.memoryBarrier(scope: .textures)
        density.swapAt(0, 1)
        encoder.setTexture(density[0], index: 0)
        encoder.setTexture(light, index: 1)
        run("dustLight")
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        for index in touched { pointer[index] = .zero }
        touched.removeAll(keepingCapacity: true)
        return buffer.gpuEndTime - buffer.gpuStartTime
    }

    func composite(
        buffer: MTLCommandBuffer, hdr: MTLTexture, depth: MTLTexture, camera: CameraUniforms,
        sampler: MTLSamplerState
    ) {
        var cam = camera
        // Half-resolution ray march against the scene's depth.
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = halfDust
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(dustDraw)
        encoder.setFragmentTexture(density[0], index: 0)
        encoder.setFragmentTexture(light, index: 1)
        encoder.setFragmentTexture(depth, index: 2)
        encoder.setFragmentSamplerState(self.sampler, index: 0)
        encoder.setFragmentBytes(&cam, length: MemoryLayout<CameraUniforms>.stride, index: 0)
        var u = uniforms
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let over = MTLRenderPassDescriptor()
        over.colorAttachments[0].texture = hdr
        over.colorAttachments[0].loadAction = .load
        over.colorAttachments[0].storeAction = .store
        let blend = buffer.makeRenderCommandEncoder(descriptor: over)!
        blend.setRenderPipelineState(self.composite)
        blend.setFragmentTexture(halfDust, index: 0)
        blend.setFragmentSamplerState(self.sampler, index: 0)
        blend.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        blend.endEncoding()
    }
}
