import BlastModel
import Foundation
import Metal
import simd

/// A passive dust field for the eye: a coarse incompressible smoke box (stable-fluids semi-Lagrangian
/// advection, Jacobi pressure, buoyancy, a little wind), fed by the firings and by blocks as they
/// strike the ground, ray-marched over the frame. Not the collapse's air-carried dust: that needs
/// the compressible air solver and its element work, far from an interactive scene.
public final class QuarryDustField {
    /// Layout matches `QuarryDustUniforms` in `QuarryDust.metal` (and its copy in the renderer's
    /// shaders). `low.w` and `wind.w` are a ridge cut's thinning, high up and near the ground.
    public struct Uniforms {
        public var low: SIMD4<Float>
        public var hdtsteps: SIMD4<Float>
        public var dims: SIMD4<Int32>
        public var wind: SIMD4<Float>
        public var sun: SIMD4<Float>
        public var lowHigh: SIMD4<Float>
    }

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let dims: SIMD3<Int>
    public let h: Float
    public let low: SIMD3<Float>
    public let high: SIMD3<Float>
    public var velocity: [MTLTexture]
    public var density: [MTLTexture]
    public let scratch: [MTLTexture]
    public let noiseVolume: MTLTexture
    public var pressure: [MTLTexture]
    public let divergence: MTLTexture
    public let light: MTLTexture
    public let solid: MTLTexture
    /// Each cell's height above the ground after the blast, up to 12.75 m, for the dust that falls
    /// out near it.
    public let clearance: MTLTexture
    public let source: MTLBuffer
    public let heatSource: MTLBuffer
    public let heatPointer: UnsafeMutablePointer<Float>
    /// Each block's release time, and whether it shows on the face, for the puffs at release.
    public let blockFire: [Float]
    public let exposed: [Bool]
    /// A ridge cut's blocks' way out down their flank, for the puffs at release (a face's is -y).
    let outward: [SIMD3<Float>]
    /// Each block's velocity at the last step, for the impacts.
    public var lastVelocity: [SIMD3<Float>]
    public let pointer: UnsafeMutablePointer<SIMD4<Float>>
    public var touched: [Int] = []
    public let pipelines: [String: MTLComputePipelineState]
    /// The face, for where each firing's puff is born.
    public let face: QuarryFace
    public var firings: [QuarryFiring]
    public var uniforms: Uniforms
    public var lastTime: Float = 0
    public let sampler: MTLSamplerState

    public init(
        device: MTLDevice, face hillside: QuarryFace, firings: [QuarryFiring], sun: SIMD3<Float>,
        gridSize: Float = 1
    ) throws {
        self.device = device
        face = hillside
        let library = try QuarryShaders.library(device: device, file: "QuarryDust")
        self.firings = firings
        queue = device.makeCommandQueue()!
        let h = gridSize
        let (low, extent) = hillside.dustBox
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
        scratch = [texture(.r16Float), texture(.r16Float)]
        let noiseDescriptor = MTLTextureDescriptor()
        noiseDescriptor.textureType = .type3D
        noiseDescriptor.pixelFormat = .rg16Float
        noiseDescriptor.width = 128
        noiseDescriptor.height = 128
        noiseDescriptor.depth = 128
        noiseDescriptor.usage = [.shaderRead, .shaderWrite]
        noiseDescriptor.storageMode = .private
        noiseVolume = device.makeTexture(descriptor: noiseDescriptor)!
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
        solidDescriptor.storageMode = .shared
        let solidTexture = device.makeTexture(descriptor: solidDescriptor)!
        var solidBytes = [UInt8](repeating: 0, count: dims.x * dims.y * dims.z)
        var clearanceBytes = [UInt8](repeating: 0, count: dims.x * dims.y * dims.z)
        for j in 0..<dims.y {
            for i in 0..<dims.x {
                let column = low + h * (SIMD3<Float>(Float(i), Float(j), 0) + 0.5)
                // The ground left after the blast, not the hill before it: dust must be free to
                // fill the space the rock leaves and to move with it.
                let ground = hillside.height(hillside.terrain.heights, column.x, column.y)
                for k in 0..<dims.z {
                    let z = low.z + h * (Float(k) + 0.5)
                    let index = i + dims.x * (j + dims.y * k)
                    solidBytes[index] = z < ground ? 255 : 0
                    clearanceBytes[index] = UInt8(max(0, min(255, (z - ground) / 12.75 * 255)))
                }
            }
        }
        solidTexture.replace(
            region: MTLRegionMake3D(0, 0, 0, dims.x, dims.y, dims.z), mipmapLevel: 0, slice: 0,
            withBytes: solidBytes, bytesPerRow: dims.x, bytesPerImage: dims.x * dims.y)
        solid = solidTexture
        let clearanceTexture = device.makeTexture(descriptor: solidDescriptor)!
        clearanceTexture.replace(
            region: MTLRegionMake3D(0, 0, 0, dims.x, dims.y, dims.z), mipmapLevel: 0, slice: 0,
            withBytes: clearanceBytes, bytesPerRow: dims.x, bytesPerImage: dims.x * dims.y)
        clearance = clearanceTexture
        let cells = dims.x * dims.y * dims.z
        source = device.makeBuffer(length: 16 * cells, options: .storageModeShared)!
        memset(source.contents(), 0, 16 * cells)
        pointer = source.contents().bindMemory(to: SIMD4<Float>.self, capacity: cells)
        heatSource = device.makeBuffer(length: 4 * cells, options: .storageModeShared)!
        memset(heatSource.contents(), 0, 4 * cells)
        heatPointer = heatSource.contents().bindMemory(to: Float.self, capacity: cells)
        var blocks = hillside.blocks
        let launchState = QuarryLaunch().apply(to: &blocks, firings: firings, face: hillside)
        blockFire = launchState.fire
        exposed = hillside.blocks.map { hillside.exposed($0.centre) }
        outward = hillside.ridge == nil ? [] : hillside.blocks.map { hillside.outward(at: $0.centre) }
        lastVelocity = Array(repeating: .zero, count: hillside.blocks.count)
        var map: [String: MTLComputePipelineState] = [:]
        for name in [
            "dustAddSources", "dustAdvectVelocity", "dustForces", "dustDivergence", "dustJacobi",
            "dustProject", "dustAdvectDensity", "dustLight", "dustBackward", "dustCorrect", "dustBakeNoise",
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
        // A ridge cut's dust thins as it rises and spreads, a share a second: 0.9 from 10 m above
        // the ground up, 0.6 within 3 m of it (where the skirt down the flanks is fed). None for
        // a face, whose dust is as it was.
        if hillside.ridge != nil {
            uniforms.low.w = 0.9
            uniforms.wind.w = 0.6
        }
        // A first clear of the private textures so the first frame is defined.
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        encoder.setComputePipelineState(pipelines["dustBakeNoise"]!)
        encoder.setTexture(noiseVolume, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 128, height: 128, depth: 128),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 8))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func add(_ p: SIMD3<Float>, dust: Float, velocity v: SIMD3<Float>, heat: Float = 0) {
        let g = (p - low) / h
        let c = SIMD3<Int>(Int(g.x), Int(g.y), Int(g.z))
        guard c.x >= 0, c.y >= 0, c.z >= 0, c.x < dims.x, c.y < dims.y, c.z < dims.z else { return }
        let index = c.x + dims.x * (c.y + dims.y * c.z)
        if pointer[index] == .zero { touched.append(index) }
        heatPointer[index] += heat * dust / (h * h * h)
        // A coarser field gets the same amount of dust per unit volume.
        let scaled = dust / (h * h * h)
        pointer[index] += SIMD4(v * scaled, scaled)
    }

    /// One dust step of 1/`frameRate` s (1/30 s for the event's own frames): sources from the
    /// firings and blocks (their poses this frame and last), then the fluid.
    public func step(
        pose: MTLBuffer, previous: MTLBuffer, bodies: Int, time: Float, restSize: [Float], frameRate: Float
    ) -> Double {
        let dt = 1 / frameRate
        // The sources are rates, which the shader multiplies by dt; the puffs at release and the
        // spray of an impact happen once, so at finer steps (a slow-motion clip) they are scaled
        // to give the same dust as one 1/30 s step. Exactly 1 at 30 frames a second.
        let once = frameRate / 30
        // Each firing's puff, born on the face in front of it at its own time, so the ripple runs
        // through the dust as it does through the rock.
        for firing in firings where face.ridge != nil && time >= firing.time && time < firing.time + 0.35 {
            // A ridge cut's: a narrow column from the ground above the firing, mostly up and a
            // little out down the flank, its dust at every speed from 10% to all of 14 m/s so the
            // column stands from the ground; each firing shows as its own plume along the cut, and
            // the plumes thin as they rise (the field's thinning, above).
            let age = (time - firing.time) / 0.35
            var r = QuarryRandom(seed: UInt64(firing.position.x * 100) &+ UInt64(time * 1000))
            let p = firing.position
            let top = SIMD3<Float>(p.x, p.y, face.height(face.original, p.x, p.y) + 0.5)
            let out = face.outward(at: p)
            for _ in 0..<700 {
                let offset = r.unit() * r.float(0.3, 3) * SIMD3<Float>(1, 1, 3)
                let way = simd_normalize(SIMD3<Float>(offset.x * 0.15 + out.x * 0.6, offset.y * 0.15, 3))
                add(
                    top + offset, dust: 120 * (1 - age), velocity: way * 14 * r.float(0.1, 1) + r.unit() * 5,
                    heat: 1)
            }
        }
        for firing in firings where face.ridge == nil && time >= firing.time && time < firing.time + 0.3 {
            let age = (time - firing.time) / 0.3
            var r = QuarryRandom(seed: UInt64(firing.position.x * 100) &+ UInt64(time * 1000))
            let x = firing.position.x
            let front = SIMD3<Float>(x, face.faceLine(x) - 1.5, firing.position.z)
            for _ in 0..<700 {
                let offset = r.unit() * r.float(0.3, 7) * SIMD3<Float>(1, 0.5, 1.2)
                let out = simd_normalize(SIMD3<Float>(offset.x * 0.4, -3, offset.z * 0.4 + 1))
                add(front + offset, dust: 70 * (1 - age), velocity: out * 22 + r.unit() * 6, heat: 1)
            }
        }
        // Blocks trail dust and throw it up where they strike below this: a face's floor and pile,
        // all of a ridge up to a little over its top.
        let dustCeiling: Float = face.ridge == nil ? 30 : face.topLevel + 10
        // A ridge's flanks: the ground below the cut's floor, out of the notch.
        let flankTop = face.ridge.map { $0.floor - 1 }
        var scatter = QuarryRandom(seed: 0x5EED &+ UInt64(time * 1000))
        let ground = face.terrain.heights
        let posePointer = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        let previousPointer = previous.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        for n in 0..<bodies {
            let p = posePointer[2 * n]
            let q = previousPointer[2 * n]
            guard p.w != 0 else { continue }
            let v = SIMD3(p.x - q.x, p.y - q.y, p.z - q.z) * frameRate
            let here = SIMD3(p.x, p.y, p.z)
            let size = restSize[n]
            let speed = simd_length(v)
            // A block on the face lets go with a puff that travels with it.
            if exposed[n], blockFire[n] > time - dt, blockFire[n] <= time {
                let out = outward.isEmpty ? SIMD3<Float>(0, -1, 0) : outward[n]
                add(here, dust: 6 * size * size * once, velocity: v + out * 4 + SIMD3(0, 0, 3), heat: 0.8)
            }
            // A tumbling block trails dust.
            if speed > 3, p.z < dustCeiling {
                add(here, dust: 0.03 * speed * size * size, velocity: v, heat: 0.2)
            }
            // A block that strikes the floor or the pile throws dust up, in proportion to the blow.
            let change = simd_length(v - lastVelocity[n])
            if let flankTop {
                // On a ridge's flanks a block sliding or rolling on the ground kicks up dust that
                // goes on down the slope with it, a skirt behind the rock. It is born 2.5 m clear
                // of the ground and a little scattered, or it lies hidden behind the flank's ledges.
                let below = speed > 1 && p.z < dustCeiling ? face.height(ground, p.x, p.y) : -.infinity
                if p.z - below < 0.6 * size + 0.5, below < flankTop {
                    let spread = SIMD3(scatter.float(-2, 2), scatter.float(-2, 2), scatter.float(0, 2))
                    add(
                        SIMD3(p.x, p.y, max(p.z - 0.3 * size, below + 2.5)) + spread,
                        dust: 20 * min(speed, 12) * size * size, velocity: v * 0.7 + SIMD3(0, 0, 2), heat: 0.5
                    )
                }
                // A ridge's blows count from 3 m/s and throw up more dust than a face's, which
                // otherwise hardly shows on the flanks from the distance a ridge is seen from.
                if change > 3, p.z < dustCeiling {
                    let before = lastVelocity[n]
                    let spray = SIMD3(before.x * 0.5, before.y * 0.5, 2.5 + 0.15 * change)
                    add(
                        here - SIMD3(0, 0, 0.4 * size), dust: 2 * (change - 3) * size * size * once,
                        velocity: spray, heat: 0.7)
                }
            } else if change > 4, p.z < dustCeiling {
                let before = lastVelocity[n]
                let spray = SIMD3(before.x * 0.5, before.y * 0.5, 2.5 + 0.15 * change)
                add(
                    here - SIMD3(0, 0, 0.4 * size), dust: 0.12 * (change - 4) * size * size * once,
                    velocity: spray,
                    heat: 0.7)
            }
            lastVelocity[n] = v
        }
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        var u = uniforms
        u.hdtsteps.y = dt
        // What velocity and density keep each step: 0.995 and 0.9992 a 1/30 s step, the same
        // a second at any rate.
        let frames = 30 / frameRate
        u.hdtsteps.z = frames == 1 ? 0.995 : pow(Float(0.995), frames)
        u.hdtsteps.w = frames == 1 ? 0.9992 : pow(Float(0.9992), frames)
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        func run(_ name: String) {
            encoder.setComputePipelineState(pipelines[name]!)
            encoder.dispatchThreads(
                MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 8))
        }
        // Sources.
        encoder.setBuffer(source, offset: 0, index: 1)
        encoder.setBuffer(heatSource, offset: 0, index: 2)
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
        encoder.setTexture(scratch[0], index: 2)
        encoder.setTexture(solid, index: 3)
        run("dustAdvectDensity")
        encoder.memoryBarrier(scope: .textures)
        encoder.setTexture(scratch[0], index: 0)
        encoder.setTexture(velocity[0], index: 1)
        encoder.setTexture(scratch[1], index: 2)
        run("dustBackward")
        encoder.memoryBarrier(scope: .textures)
        encoder.setTexture(density[0], index: 0)
        encoder.setTexture(scratch[0], index: 1)
        encoder.setTexture(scratch[1], index: 2)
        encoder.setTexture(velocity[0], index: 3)
        encoder.setTexture(solid, index: 4)
        encoder.setTexture(density[1], index: 5)
        encoder.setTexture(clearance, index: 6)
        run("dustCorrect")
        encoder.memoryBarrier(scope: .textures)
        density.swapAt(0, 1)
        encoder.setTexture(density[0], index: 0)
        encoder.setTexture(light, index: 1)
        run("dustLight")
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        for index in touched {
            pointer[index] = .zero
            heatPointer[index] = 0
        }
        touched.removeAll(keepingCapacity: true)
        return buffer.gpuEndTime - buffer.gpuStartTime
    }

    /// Bytes of one stored field: velocity (four halves a cell) and density (one).
    public var storedBytes: Int { dims.x * dims.y * dims.z * 10 }

    /// Writes the field as it stands (velocity and density) to `url`, for scrubbing back to it.
    public func save(to url: URL) throws {
        let cells = dims.x * dims.y * dims.z
        let staging = device.makeBuffer(length: cells * 10, options: .storageModeShared)!
        let buffer = queue.makeCommandBuffer()!
        let blit = buffer.makeBlitCommandEncoder()!
        let size = MTLSize(width: dims.x, height: dims.y, depth: dims.z)
        blit.copy(
            from: velocity[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: size,
            to: staging, destinationOffset: 0, destinationBytesPerRow: dims.x * 8,
            destinationBytesPerImage: dims.x * dims.y * 8)
        blit.copy(
            from: density[0], sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: size,
            to: staging, destinationOffset: cells * 8, destinationBytesPerRow: dims.x * 2,
            destinationBytesPerImage: dims.x * dims.y * 2)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        try Data(bytesNoCopy: staging.contents(), count: cells * 10, deallocator: .none).write(to: url)
    }

    /// Back to a field written by `save`; the light is rebuilt from it.
    public func load(from url: URL) throws {
        let cells = dims.x * dims.y * dims.z
        let data = try Data(contentsOf: url)
        guard data.count == cells * 10 else { throw CocoaError(.fileReadCorruptFile) }
        let staging = data.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        lastVelocity = Array(repeating: .zero, count: lastVelocity.count)
        let buffer = queue.makeCommandBuffer()!
        let blit = buffer.makeBlitCommandEncoder()!
        let size = MTLSize(width: dims.x, height: dims.y, depth: dims.z)
        blit.copy(
            from: staging, sourceOffset: 0, sourceBytesPerRow: dims.x * 8,
            sourceBytesPerImage: dims.x * dims.y * 8,
            sourceSize: size, to: velocity[0], destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin())
        blit.copy(
            from: staging, sourceOffset: cells * 8, sourceBytesPerRow: dims.x * 2,
            sourceBytesPerImage: dims.x * dims.y * 2, sourceSize: size, to: density[0], destinationSlice: 0,
            destinationLevel: 0, destinationOrigin: MTLOrigin())
        blit.endEncoding()
        let encoder = buffer.makeComputeCommandEncoder()!
        var u = uniforms
        u.hdtsteps.y = 1.0 / 30
        encoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setTexture(density[0], index: 0)
        encoder.setTexture(light, index: 1)
        encoder.setComputePipelineState(pipelines["dustLight"]!)
        encoder.dispatchThreads(
            MTLSize(width: dims.x, height: dims.y, depth: dims.z),
            threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 8))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// All the fields' bytes.
    public var bytes: Int {
        (velocity + density + pressure + scratch + [divergence, light, solid, clearance, noiseVolume])
            .reduce(source.length) { $0 + $1.allocatedSize }
    }
}
