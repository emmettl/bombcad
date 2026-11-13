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
    /// Each block's swell before it lets go: how long (s, 0 for none) and how fast (m/s). A block on
    /// the face puffs dust as its swell begins, so the dust starts as the rock first moves, not
    /// when it lets go.
    let swellRise: [Float]
    let swellSpeed: [Float]
    /// A ridge cut's blocks' way out down their flank, for the puffs at release (a face's is -y).
    let outward: [SIMD3<Float>]
    /// A ridge cut's (stage 3f): each block's draw for whether its top cracks open and jets dust
    /// as it heaves (it does once the dome's rise passes the draw's threshold, up to
    /// `crackShare` of the exposed blocks); a jet's rate per square metre of block and m/s of
    /// rise; and the spurt the first quarter of the cracks give as the rock starts to move.
    let crack: [Float]
    let crackShare: Float = 0.08
    let crackJet: Float = 6
    let crackSpurt: Float = 200
    /// The share of a crack's dust put into the field (stage 3i): the rest is drawn as its jet,
    /// whose dust at the field's cells was a round puff three metres across at the least.
    let crackField: Float = 0.35
    /// A ridge's broken rock's dust after it lets go, from half its exposed blocks: a rate per
    /// square metre of block, fading over `shedTime` seconds.
    let shed: Float = 56
    static let shedTime: Float = 1.5
    /// How long a ridge's firing's column is fed (s).
    static let columnTime: Float = 0.35
    /// The ridge's heave's ramp (s), from the launch law: how far the dome has risen.
    let ridgeRamp: Float = max(QuarryLaunch().ridgeRise, 0.1)
    /// A ridge cut's rock top this frame, for where the firings' columns are born.
    var top: TopMap?

    /// A ridge's crack jets drawn as thin spurts, finer than the field's cells (stage 3i,
    /// emmettl/bombcad-work#143): at the window's 1.5 m cells a jet's dust is three metres across
    /// at the least and read as a round puff. Each crack that jets this step is also drawn as a
    /// narrow streak from its top (`jetVertex`, `jetFragment` in the renderer's shaders), growing
    /// at the jet's speed to a few metres, and for a moment after it stops, its tail flying off;
    /// only `crackField` of its dust goes into the field. Drawn only, nothing moves by it. Layout
    /// matches `QuarryJet` there.
    public struct Jet {
        /// The crack's top; w the jet's strength, 0 to 1.
        public var base: SIMD4<Float>
        /// Direction times length (m); w the half-width at the base (m).
        public var axis: SIMD4<Float>
        /// x a draw for the jet's own pattern, y its age (s), z the half-width at its tip (m).
        public var shape: SIMD4<Float>
    }
    /// The most jets drawn at once.
    public static let jetCapacity = 1024
    /// This step's jets, in one of three buffers taken in turn, so a frame still being drawn keeps
    /// its own.
    let jetBuffers: [MTLBuffer]
    public private(set) var jetSlot = 0
    public private(set) var jetCount = 0
    public var jets: MTLBuffer { jetBuffers[jetSlot] }
    /// Each crack jetting or lately stopped: when it started and last jetted, where and how.
    struct JetTrack {
        var start: Float
        var last: Float
        var base: SIMD3<Float>
        var direction: SIMD3<Float>
        var speed: Float
        var strength: Float
        var seed: Float
    }
    var jetTracks: [Int: JetTrack] = [:]
    /// How long a jet's tail is drawn after it stops (s), and the longest a jet grows (m).
    static let jetFade: Float = 0.35
    static let jetLength: Float = 4.5

    /// The highest top of the moving rock in each 2 m column of the dust box, this frame.
    struct TopMap {
        let low: SIMD2<Float>
        let nx: Int, ny: Int
        var height: [Float]
        static let cell: Float = 2
        init(low: SIMD2<Float>, extent: SIMD2<Float>) {
            self.low = low
            nx = max(1, Int(extent.x / Self.cell))
            ny = max(1, Int(extent.y / Self.cell))
            height = Array(repeating: -.infinity, count: nx * ny)
        }
        mutating func reset() {
            for i in height.indices { height[i] = -.infinity }
        }
        func index(_ x: Float, _ y: Float) -> (Int, Int) {
            (Int(floor((x - low.x) / Self.cell)), Int(floor((y - low.y) / Self.cell)))
        }
    }

    private func noteTop(_ p: SIMD3<Float>, _ size: Float) {
        let (i, j) = top!.index(p.x, p.y)
        guard i >= 0, j >= 0, i < top!.nx, j < top!.ny else { return }
        top!.height[i + top!.nx * j] = max(top!.height[i + top!.nx * j], p.z + 0.5 * size)
    }

    /// The highest moving rock's top within `reach` cells of (x, y), or -inf.
    func rockTop(_ x: Float, _ y: Float, reach: Int) -> Float {
        guard let top else { return -.infinity }
        let (i0, j0) = top.index(x, y)
        var best = -Float.infinity
        for j in max(0, j0 - reach)...min(top.ny - 1, max(0, j0 + reach)) {
            for i in max(0, i0 - reach)...min(top.nx - 1, max(0, i0 + reach)) {
                best = max(best, top.height[i + top.nx * j])
            }
        }
        return best
    }
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
        swellRise = launchState.swell.map(\.w)
        swellSpeed = launchState.swell.map { simd_length(SIMD3($0.x, $0.y, $0.z)) }
        exposed = hillside.blocks.map { hillside.exposed($0.centre) }
        outward = hillside.ridge == nil ? [] : hillside.blocks.map { hillside.outward(at: $0.centre) }
        var draw = QuarryRandom(seed: 0xC4AC)
        crack = hillside.ridge == nil ? [] : hillside.blocks.map { _ in draw.float() }
        if hillside.ridge != nil {
            top = TopMap(low: SIMD2(low.x, low.y), extent: SIMD2(high.x - low.x, high.y - low.y))
        }
        lastVelocity = Array(repeating: .zero, count: hillside.blocks.count)
        jetBuffers = (0..<3).map { _ in
            device.makeBuffer(
                length: MemoryLayout<Jet>.stride * Self.jetCapacity, options: .storageModeShared)!
        }
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

    /// The puff as a block's swell begins: a rate per metre a second of swell and square metre of
    /// block, fading over this share of the swell. A ridge's is twice a face's: its dust thins
    /// fast and it is seen from further off.
    var vent: Float { face.ridge == nil ? 5 : 10 }
    static let ventShare: Float = 0.35

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

    /// Crack `n` jets this step from `top` at `rate` (the field's), its rock rising at `rising`.
    private func noteJet(_ n: Int, top: SIMD3<Float>, rate: Float, rising: Float, time: Float) {
        let strength = min(1, max(0.25, rate / 60))
        if var track = jetTracks[n], time - track.last <= Self.jetFade {
            track.last = time
            track.base = top
            track.speed = 9 + rising
            track.strength = strength
            jetTracks[n] = track
            return
        }
        // A draw of its own for the lean and the pattern, fixed by the crack.
        var r = QuarryRandom(seed: 0x7E7 &+ UInt64(n) &* 2_654_435_761)
        let lean = SIMD3(r.float(-0.4, 0.4), r.float(-0.4, 0.4), Float(1))
        jetTracks[n] = JetTrack(
            start: time, last: time, base: top, direction: simd_normalize(lean), speed: 9 + rising,
            strength: strength, seed: r.float())
    }

    /// This step's jets into the next of the jet buffers: each grows from its crack at its speed,
    /// easing to `jetLength`; once stopped its tail flies on up and fades.
    private func writeJets(time: Float) {
        jetSlot = (jetSlot + 1) % jetBuffers.count
        jetCount = 0
        guard !jetTracks.isEmpty else { return }
        let out = jetBuffers[jetSlot].contents().bindMemory(to: Jet.self, capacity: Self.jetCapacity)
        // In the cracks' order, so a frame is drawn the same every time.
        for n in jetTracks.keys.sorted() {
            let track = jetTracks[n]!
            let since = time - track.last
            if since > Self.jetFade {
                jetTracks[n] = nil
                continue
            }
            guard jetCount < Self.jetCapacity else { continue }
            let age = time - track.start
            // Thrown grit slows in the air: the jet's reach eases toward its longest.
            let reach = Self.jetLength * (1 - exp(-track.speed * age / Self.jetLength))
            let fade = 1 - since / Self.jetFade
            // A stopped jet's tail leaves the crack and flies on up as it thins.
            let base = track.base + track.direction * min(reach, track.speed * since)
            let length = max(0.3, reach - min(reach, track.speed * since) + 0.6 * track.speed * since)
            out[jetCount] = Jet(
                base: SIMD4(base, track.strength * fade * fade),
                axis: SIMD4(track.direction * length, 0.12),
                shape: SIMD4(track.seed, age, 0.25 + 0.3 * length, 0))
            jetCount += 1
        }
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
        // The rock's top is wanted only while a ridge's firing's column is being born.
        let mapTop =
            top != nil && firings.contains { time >= $0.time && time < $0.time + Self.columnTime }
        if mapTop { top!.reset() }
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
            // A block on the face vents a puff of dust as its swell begins, carried with it and up
            // (a ridge's jets from cracks instead):
            // so the dust starts with the first motion of the rock around each firing (the swell
            // begins 0.8 to 1.25 s before the block lets go), not only when it lets go.
            if exposed[n], swellRise[n] > 0, time <= blockFire[n], time > blockFire[n] - swellRise[n] {
                let share = (time - (blockFire[n] - swellRise[n])) / swellRise[n]
                if face.ridge != nil {
                    // A ridge's heaving rock (stage 3f) jets dust from its cracks rather than
                    // puffing it over its whole top (which lay on the dome like patchy fog): a few
                    // blocks of its top at first, more as the dome rises and opens, each a thin hot
                    // jet off its top, faster than the rock under it and densest as the rock moves
                    // fastest.
                    let opened = (time - (blockFire[n] - swellRise[n])) / ridgeRamp
                    let t = min(1, max(0, (opened - 0.03) / 1.1))
                    let lean = SIMD3(scatter.float(-0.6, 0.6), scatter.float(-0.6, 0.6), Float(0))
                    if opened > 0.03, crack[n] < crackShare * (0.25 + 0.75 * t * t * (3 - 2 * t)) {
                        let rising = max(0, v.z)
                        // The first cracks spurt as the rock starts to move, then settle to the
                        // rate the rising rock gives.
                        let spurt = crack[n] < 0.25 * crackShare ? crackSpurt * max(0, 1 - opened / 0.5) : 0
                        let rate = crackJet * (1.5 + rising) + spurt
                        add(
                            here + SIMD3(0, 0, 0.5 * size + 0.8), dust: crackField * rate * size * size,
                            velocity: SIMD3(v.x, v.y, 0) + lean + SIMD3(0, 0, rising + 9), heat: 1)
                        noteJet(
                            n, top: here + SIMD3(0, 0, 0.5 * size), rate: rate, rising: rising, time: time)
                    }
                } else if share < Self.ventShare {
                    let out = outward.isEmpty ? SIMD3<Float>(0, -1, 0) : outward[n]
                    add(
                        here + out * (0.5 * size),
                        dust: vent * swellSpeed[n] * (1 - share / Self.ventShare) * size * size,
                        velocity: v + out * 2 + SIMD3(0, 0, 2.5), heat: 0.8)
                }
            }
            // A block on the face lets go with a puff that travels with it.
            if exposed[n], blockFire[n] > time - dt, blockFire[n] <= time {
                let out = outward.isEmpty ? SIMD3<Float>(0, -1, 0) : outward[n]
                if face.ridge != nil {
                    // A ridge's breaking dome: the dust bursts up out of the opening cracks.
                    add(
                        here + SIMD3(0, 0, 0.5 * size + 0.3), dust: 6 * size * size * once,
                        velocity: v + out * 2 + SIMD3(0, 0, 6), heat: 1)
                } else {
                    add(here, dust: 6 * size * size * once, velocity: v + out * 4 + SIMD3(0, 0, 3), heat: 0.8)
                }
            }
            // A ridge's broken rock goes on shedding dust for a second and a half after it lets
            // go, carried with it, so the cloud comes out of the breaking mass and follows it down
            // rather than being left in the air where the dome was. Half the blocks at twice the
            // rate: the same cloud, for half the sources (0.4 ms of the step).
            if face.ridge != nil, exposed[n], crack[n] < 0.5, time > blockFire[n],
                time < blockFire[n] + Self.shedTime
            {
                let fade = 1 - (time - blockFire[n]) / Self.shedTime
                add(
                    here + SIMD3(0, 0, 0.5 * size), dust: shed * fade * fade * size * size,
                    velocity: v * 0.7 + SIMD3(0, 0, 1.5), heat: 0.5)
            }
            if mapTop { noteTop(here, size) }
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
        writeJets(time: time)
        // A ridge cut's firings: a narrow column from the rock's top over each firing as it stands
        // now (the heave has lifted it, stage 3f; it was born at the old ground, inside the risen
        // rock), mostly up and a little out down the flank, most of its dust slow so the column
        // stands on the rock; each firing shows as its own plume along the cut, and the plumes
        // thin as they rise (the field's thinning, above).
        for firing in firings
        where face.ridge != nil && time >= firing.time && time < firing.time + Self.columnTime {
            let age = (time - firing.time) / Self.columnTime
            var r = QuarryRandom(seed: UInt64(firing.position.x * 100) &+ UInt64(time * 1000))
            let p = firing.position
            let base = max(face.height(face.original, p.x, p.y), rockTop(p.x, p.y, reach: 1)) + 0.3
            let out = face.outward(at: p)
            for _ in 0..<700 {
                var offset = r.unit() * r.float(0.3, 3) * SIMD3<Float>(0.7, 0.7, 2)
                offset.z = abs(offset.z)
                let way = simd_normalize(SIMD3<Float>(offset.x * 0.15 + out.x * 0.6, offset.y * 0.15, 3))
                // Most of it slow, so the column stands on the rock rather than leaving it as a puff.
                let speed = r.float(0.15, 1)
                add(
                    SIMD3(p.x, p.y, base) + offset, dust: 120 * (1 - age),
                    velocity: way * 11 * speed * speed + r.unit() * 3, heat: 0.7)
            }
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
        jetTracks = [:]
        jetCount = 0
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
