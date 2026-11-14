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
    /// shaders). `low.w` and `wind.w` are the fines' thinning a second, high up and near the ground.
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
    /// The most dust within `hazeReach` cells of each cell (stage 3l), for the march to skip its
    /// warp where the noise's cuts would keep nothing of any dust it could find.
    public let hazeBound: MTLTexture
    /// How many cells round a cell `hazeBound` covers: the march's warped lookup (5.1 m at most) and
    /// a cell's interpolation.
    let hazeReach: Int32
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
    /// The share of the first cracks' spurt put into the field (stage 3j, emmettl/bombcad-work#144).
    let crackSpurtField: Float = 0.12
    /// A ridge's broken rock's dust after it lets go, from half its exposed blocks: a rate per
    /// square metre of block, fading over `shedTime` seconds. 36 since stage 3k (it was 56): the
    /// dust now lingers, and at 56 the cloud hid the rock running down the near flank.
    let shed: Float = 36
    /// A ridge's low veil off the rock running over the ground (stage 3j): a rate per square metre
    /// of block and m/s of its speed (to 10 m/s).
    let veil: Float = 32
    static let shedTime: Float = 1.5
    /// How long a ridge's firing's column was fed in stage 3f (s), for its amount of dust, and
    /// the share of that dust a column gives now (stage 3k): the dust lingers.
    static let columnTime: Float = 0.35
    static let columnShare: Float = 0.7

    /// Whether any of a ridge cut's columns is being fed at `time`.
    func columnFed(_ time: Float) -> Bool {
        zip(firings, columns).contains { firing, column in
            time >= firing.time + column.delay && time < firing.time + column.delay + column.feed
        }
    }
    /// The ridge's heave's ramp (s), from the launch law: how far the dome has risen.
    let ridgeRamp: Float = max(QuarryLaunch().ridgeRise, 0.1)
    /// A ridge cut's rock top this frame, for where the firings' columns are born.
    var top: TopMap?
    /// A ridge cut's firings' columns (stage 3k, emmettl/bombcad-work#145): each its own strength,
    /// delay, length of feed, rise and place, so they rise unevenly and merge into one plume.
    struct Column {
        var delay: Float
        var feed: Float
        var strength: Float
        var lift: Float
        var shift: SIMD2<Float>
        /// Half the column's footprint along the cut and across it (m).
        var reach: SIMD2<Float>
        /// How shallow the rock over it is, 0 over the deepest to 1 toward the cut's ends.
        var shallow: Float = 0
    }
    var columns: [Column] = []
    /// The wind at height (m/s; a ridge cut's since stage 3k, a face's since stage 3l): light and
    /// steady, across the opening view and a little away from the eye, so the plume leans and
    /// drifts across the frame rather than toward the camera.
    static let windSpeed: Float = 3
    /// Where a ridge cut's opening view stands: its low veil is not fed within `veilClear` of it
    /// (in plan), where the last blocks rolling toward the eye left a smudge by the camera.
    var viewEye: SIMD2<Float>?
    static let veilClear: Float = 45
    /// When the rock has settled enough that the veil stops being fed: it fades over the 3 s
    /// from `veilEnd` after the last firing.
    static let veilEnd: Float = 2.5
    let lastFiring: Float

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
        // Mipmapped, so a ridge's billows (stage 3j) can be looked up at the level a pixel holds;
        // a face's march samples the base level only, as before.
        noiseDescriptor.mipmapLevelCount = 8
        noiseVolume = device.makeTexture(descriptor: noiseDescriptor)!
        pressure = [texture(.r16Float), texture(.r16Float)]
        divergence = texture(.r16Float)
        light = texture(.r16Float)
        hazeBound = texture(.r16Float)
        hazeReach = Int32((5.1 / h).rounded(.up)) + 1
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
        lastFiring = firings.map(\.time).max() ?? 0
        if let ridge = hillside.ridge {
            columns = Self.columns(firings: firings, ridge: ridge)
        } else {
            columns = Self.faceColumns(firings: firings, depth: hillside.depth)
        }
        // Each scene's light wind at height, across its opening view and a little away from the
        // eye, so the plume leans and drifts across the frame and not toward the camera: a ridge
        // cut's toward the view's left (stage 3k), over the far flank; a face's toward the view's
        // right (stage 3l, emmettl/bombcad-work#146), along the strip toward its far end and a
        // little off the face, so it carries the dust along the bench rather than into the face
        // (toward the view's left, it blew back into the face and over the bench). Until stage 3l
        // a face's dust drifted along the strip outside its flow.
        let opening = QuarryRidgeView.opening(hillside)
        let orbit = opening?.orbit ?? QuarryOrbit.faceOpening(hillside)
        let toEye = simd_normalize(SIMD2(orbit.direction.x, orbit.direction.y))
        // The view's left as the eye sees it (its right for a face), and away from the eye.
        let across = SIMD2(toEye.y, -toEye.x) * (opening == nil ? -1 : 1)
        let windAtHeight = SIMD3(simd_normalize(0.85 * across - 0.5 * toEye) * Self.windSpeed, 0)
        if opening != nil {
            viewEye = SIMD2(orbit.eye.x, orbit.eye.y)
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
            "dustWindStart", "dustSpreadMax",
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
            wind: SIMD4(windAtHeight, 0), sun: SIMD4(sun, 0), lowHigh: SIMD4(high, 0))
        // The fines thin slowly, a share a second: high up and near the ground (`fines`); the
        // coarse dust falls out while it is thick (`dustCorrect`). Stage 3f to 3j thinned all of a
        // ridge's at 0.9 and 0.6 a second, so its cloud had nearly gone by 7 s.
        let fines = Self.fines(hillside.ridge == nil ? .face : .ridgeCut)
        uniforms.low.w = fines.high
        uniforms.wind.w = fines.low
        // How much of its thin dust the march draws as haze (`sun.w`, stage 3l): all of a ridge
        // cut's; a face's 0.3 below its bench's top, rising to all of it above (the march), since
        // its excavated trench holds a thin sheet of dust in front of the new face, which at a
        // ridge's share hid the face behind a flat brown veil from 6 to 12 s.
        uniforms.sun.w = hillside.ridge == nil ? Self.faceHaze : 1
        // A face's bench top over the box's floor (m): the old ground just behind the face's line,
        // along the strip. For the march's haze low down and the trench's settling; 0 marks a ridge
        // cut.
        if hillside.ridge == nil {
            let samples = 32
            let crest =
                (0..<samples).map { i -> Float in
                    let x = hillside.length * (Float(i) + 0.5) / Float(samples)
                    return hillside.height(hillside.original, x, hillside.faceLine(x) + 2)
                }.reduce(0, +) / Float(samples)
            uniforms.dims.w = Int32(max(1, (crest - low.z).rounded()))
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
        let blit = buffer.makeBlitCommandEncoder()!
        blit.generateMipmaps(for: noiseVolume)
        blit.endEncoding()
        do {
            // The flow starts as the wind, which the first steps' pressure turns over the ground.
            let start = buffer.makeComputeCommandEncoder()!
            var u = uniforms
            start.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            start.setComputePipelineState(pipelines["dustWindStart"]!)
            start.setTexture(velocity[0], index: 0)
            start.setTexture(clearance, index: 1)
            start.setTexture(solid, index: 2)
            start.dispatchThreads(
                MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 8))
            start.endEncoding()
        }
        let boundEncoder = buffer.makeComputeCommandEncoder()!
        var u = uniforms
        boundEncoder.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encodeHazeBound(boundEncoder)
        boundEncoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// `hazeBound` from `density[0]`, on an encoder whose uniforms are set: a maximum over
    /// `hazeReach` cells along each axis in turn, through the advection's scratch (free by then).
    func encodeHazeBound(_ encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipelines["dustSpreadMax"]!)
        let passes: [(MTLTexture, MTLTexture, SIMD3<Int32>)] = [
            (density[0], scratch[0], SIMD3(1, 0, 0)), (scratch[0], scratch[1], SIMD3(0, 1, 0)),
            (scratch[1], hazeBound, SIMD3(0, 0, 1)),
        ]
        for (from, to, axis) in passes {
            var spread = SIMD4(axis, hazeReach)
            encoder.setBytes(&spread, length: MemoryLayout<SIMD4<Int32>>.stride, index: 1)
            encoder.setTexture(from, index: 0)
            encoder.setTexture(to, index: 1)
            encoder.dispatchThreads(
                MTLSize(width: dims.x, height: dims.y, depth: dims.z),
                threadsPerThreadgroup: MTLSize(width: 16, height: 8, depth: 8))
            encoder.memoryBarrier(scope: .textures)
        }
    }

    /// The fines' thinning a second in `scene`, high up (from 10 m over the ground) and near the
    /// ground (within 3 m of it): a ridge cut's since stage 3k, a face's since stage 3l.
    static func fines(_ scene: QuarryScene) -> (high: Float, low: Float) {
        scene == .ridgeCut ? (0.05, 0.15) : (0.02, 0.35)
    }

    /// Each firing's column (stage 3k): drawn once from the firing's place in the pattern, so a
    /// cut fires the same way every time. Stage 3f's columns were each a ball 4 m across fed for
    /// 0.35 s, the same at every firing, so at 4.5 s they stood as an even row of separate puffs
    /// and the low ones on the near flank were dense round balls. Now each spreads half-way or
    /// more to its neighbours along the cut and across both rows, is fed over 0.5 to 1 s, and
    /// differs from the next in strength, delay, rise and place.
    static func columns(firings: [QuarryFiring], ridge: QuarryRidge) -> [Column] {
        let xs = firings.map(\.position.x).sorted()
        // The spacing along the cut between neighbouring firings (both rows together).
        let spacing = xs.count > 1 ? max(2, (xs.last! - xs.first!) / Float(xs.count - 1)) : 6
        let deepest = max(ridge.crest - ridge.floor, 1)
        return firings.indices.map { n in
            var r = QuarryRandom(seed: 0xC01 &+ UInt64(n) &* 7919)
            // Toward the cut's ends, over shallower rock, a column is fainter, over a wider
            // footprint, and its dust comes from a few clumps of it (`clumps`): the low columns
            // on the near flank were the densest, roundest puffs (stage 3k), and then a tall
            // opaque wall over the rock running down the flank at 3.6 to 4.5 s, fed for up to 1.6 s
            // (stage 3l, emmettl/bombcad-work#146: a quarter as strong again, fed no longer than the
            // rest). (A firing stands half-way up the rock over it.)
            let deep = min(1, max(0.3, 2 * (firings[n].position.z - ridge.floor) / deepest))
            let shallow = (1 - deep) / 0.7
            return Column(
                delay: r.float(0, 0.3), feed: r.float(0.5, 1.0),
                strength: r.float(0.4, 1.5) * (1 - 0.75 * shallow), lift: r.float(0.7, 1.3),
                shift: SIMD2(r.float(-0.5, 0.5) * spacing, r.float(-0.25, 0.25) * ridge.halfWidth),
                reach: SIMD2(
                    r.float(0.9, 1.9) * spacing * (1 + 0.5 * shallow), ridge.halfWidth * r.float(0.35, 0.7)),
                shallow: shallow)
        }
    }

    /// Over rock shallower than this share, a ridge cut's column's dust comes from `clumps` clumps
    /// of its footprint, each `clumpSize` of it (stage 3l): broken low down, the rock between.
    static let clumpedFrom: Float = 0.3
    static let clumps = 3
    static let clumpSize: Float = 0.7

    /// A face's firings' dust (stage 3l, emmettl/bombcad-work#146), drawn once from each firing's
    /// place in the row as a ridge's columns are. Before it a face's firing was a ball 7 m across
    /// thrown out of the face at 22 m/s for 0.3 s, the same at every firing, so the row's late
    /// firings stood as a row of equal round puffs along the strip. Now each spreads along the
    /// strip over 0.9 to 1.9 times the spacing (reaching its neighbours), fed over 0.3 to 0.6 s
    /// within 0.1 s of the firing, so it billows out at once, some out of the face's height and thrown out over the floor, the rest vented from the
    /// bench's top behind the crest (`reach.y` back from it), and differs from the next in
    /// strength, delay, throw and place.
    static func faceColumns(firings: [QuarryFiring], depth: Float) -> [Column] {
        let xs = firings.map(\.position.x).sorted()
        let spacing = xs.count > 1 ? max(2, (xs.last! - xs.first!) / Float(xs.count - 1)) : 6
        return firings.indices.map { n in
            var r = QuarryRandom(seed: 0xFAC3 &+ UInt64(n) &* 7919)
            return Column(
                delay: r.float(0, 0.1), feed: r.float(0.3, 0.6), strength: r.float(0.5, 1.4),
                lift: r.float(0.7, 1.3), shift: SIMD2(r.float(-0.4, 0.4) * spacing, 0),
                // The row's end firings have no neighbour past them to merge with: wider.
                reach: SIMD2(
                    r.float(0.9, 1.9) * spacing * (n == 0 || n == firings.count - 1 ? 1.6 : 1),
                    depth * r.float(0.3, 0.6)))
        }
    }
    /// A face's firing's dust in all (the old ball's was 8,170, which never thinned), the share of
    /// it out of the face (the rest from the bench's top), and how fast it is thrown out (m/s).
    static let faceColumnDust: Float = 30000
    static let faceFrontShare: Float = 0.55
    static let faceThrow: Float = 12
    /// The share of its thin dust a face's march draws as haze below its bench's top, of a ridge
    /// cut's.
    static let faceHaze: Float = 0.3

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
        // A face's firings (stage 3l, `faceColumns`): each firing's dust spread along the strip
        // over its footprint, at its own delay and for its own feed, so the ripple runs through the
        // dust as it does through the rock and the firings' dust merges into one bank rather than a
        // row of equal puffs: most of it out of the face's height, thrown out over the floor and
        // up, the rest vented from the bench's top behind the crest.
        for (n, firing) in firings.enumerated() where face.ridge == nil && n < columns.count {
            let column = columns[n]
            let start = firing.time + column.delay
            guard time >= start, time < start + column.feed else { continue }
            let age = (time - start) / column.feed
            var r = QuarryRandom(seed: UInt64(firing.position.x * 100) &+ UInt64(time * 1000))
            // The firing's dust over its feed, falling off as it goes.
            let rate = Self.faceColumnDust * column.strength / (700 * 0.4 * column.feed)
            let falling = pow(1 - age, 1.5)
            for _ in 0..<700 {
                // Denser in the middle of the footprint, thinning to its ends.
                let a = (r.float(-1, 1) + r.float(-1, 1)) * 0.5
                let speed = r.float(0.2, 1)
                if r.float() < Self.faceFrontShare {
                    // Out of the face, nearer the firing along the strip than the vent (spread as
                    // far, the first firings' dust was too thin to show), up the middle of its
                    // height, thrown out over the floor, hot so it billows up off the pile.
                    let x = firing.position.x + column.shift.x + a * column.reach.x * 0.75
                    let front = face.faceLine(x)
                    let floor = face.floorHeight(x)
                    let top = face.height(face.original, x, front + 2)
                    let z = floor + r.float(0.3, 0.85) * (top - floor)
                    let out = SIMD3<Float>(a * 1.5, -Self.faceThrow * column.lift * speed, r.float(1, 5))
                    add(
                        SIMD3(x, front - r.float(0.5, 3), z), dust: rate * falling,
                        velocity: out + r.unit() * 3, heat: 1)
                } else {
                    let x = firing.position.x + column.shift.x + a * column.reach.x
                    let front = face.faceLine(x)
                    let y = front + r.float(0.3, 1) * column.reach.y
                    let base = face.height(face.original, x, y) + 0.3
                    let rise = r.float(0, 1)
                    add(
                        SIMD3(x, y, base + rise * rise * 3), dust: rate * falling,
                        velocity: SIMD3(a, -r.float(0, 3), 10 * column.lift * speed * speed) + r.unit() * 2.5,
                        heat: 0.8)
                }
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
        let mapTop = top != nil && columnFed(time)
        if mapTop { top!.reset() }
        let posePointer = pose.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        let previousPointer = previous.contents().bindMemory(to: SIMD4<Float>.self, capacity: 2 * bodies)
        // A ridge's veil fades out as the rock settles (stage 3k).
        let settling = (time - lastFiring - Self.veilEnd) / 3
        let veilFade = 1 - min(1, max(0, settling))
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
                        // The first spurts put less into the field (stage 3j): at its cells they
                        // were the small soft puffs left over the first cracks.
                        let field = crackField * (rate - spurt) + crackSpurtField * spurt
                        add(
                            here + SIMD3(0, 0, 0.5 * size + 0.8), dust: field * size * size,
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
                // A low veil that runs with the rock (stage 3j, emmettl/bombcad-work#144): a block
                // running over the ground (the cut's floor, the heap, the flanks) sheds dust close
                // over it, dragged along at most of the block's own speed and hardly rising, a little
                // warm so it neither climbs away as the skirt does nor drops out at once: a thin
                // rolling sheet runs down with the rock's front and thins behind it.
                // Stage 3k: not from blocks nearly stopped (it eases in from 2.5 to 6 m/s), nor near
                // the opening view's eye, and fading out as the rock settles, so the last blocks
                // rolling toward the camera no longer leave a lump of dust by it.
                if speed > 2.5, p.z - below < 0.6 * size + 0.5, veilFade > 0 {
                    let moving = min(1, (speed - 2.5) / 3.5)
                    var clear: Float = 1
                    if let viewEye {
                        let off = simd_distance(SIMD2(p.x, p.y), viewEye) / Self.veilClear
                        clear = min(1, max(0, (off - 1) / 0.5))
                    }
                    let weight = veilFade * moving * moving * clear
                    if weight > 0 {
                        let spread = SIMD3(
                            scatter.float(-1.5, 1.5), scatter.float(-1.5, 1.5), scatter.float(0, 0.8))
                        add(
                            SIMD3(p.x, p.y, below + 0.9) + spread,
                            dust: weight * veil * min(speed, 10) * size * size,
                            velocity: SIMD3(v.x, v.y, 0) * 0.85 + SIMD3(0, 0, 0.4), heat: 0.15)
                    }
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
        // A ridge cut's firings: a column from the rock's top over each firing as it stands now
        // (the heave has lifted it, stage 3f), mostly up and a little out down the flank, most of
        // its dust slow so the column stands on the rock. Stage 3k: each spreads over a footprint
        // reaching its neighbours along the cut and across both rows, fed over 0.5 to 1 s, and
        // differs from the next (`columns`), so the columns rise unevenly and merge into one
        // plume rather than standing as a row of equal puffs; the same dust as stage 3f's in all.
        for (n, firing) in firings.enumerated() where face.ridge != nil && n < columns.count {
            let column = columns[n]
            let start = firing.time + column.delay
            guard time >= start, time < start + column.feed else { continue }
            let age = (time - start) / column.feed
            var r = QuarryRandom(seed: UInt64(firing.position.x * 100) &+ UInt64(time * 1000))
            let centre = SIMD2(firing.position.x, firing.position.y) + column.shift
            let out = face.outward(at: firing.position)
            // Stage 3f's 120 a particle over 0.35 s, falling linearly, spread over this feed.
            let rate =
                Self.columnShare * 120 * column.strength * (0.5 * Self.columnTime) / (0.4 * column.feed)
            let falling = pow(1 - age, 1.5)
            for _ in 0..<700 {
                // Denser in the middle, thinning to the footprint's edge.
                var a = SIMD2(r.float(-1, 1) + r.float(-1, 1), r.float(-1, 1) + r.float(-1, 1)) * 0.5
                // Over shallow rock (stage 3l), from three clumps of the footprint, so the low dust
                // over the rock running down the flank is broken, with the rock between.
                if column.shallow > Self.clumpedFrom {
                    let c = min(Self.clumps - 1, Int(r.float() * Float(Self.clumps)))
                    var cr = QuarryRandom(seed: 0xC1A &+ UInt64(n) &* 131 &+ UInt64(c))
                    let middle = SIMD2(cr.float(-0.8, 0.8), cr.float(-0.8, 0.8))
                    a = middle + a * Self.clumpSize
                }
                let place = centre + a * column.reach
                let base =
                    max(face.height(face.original, place.x, place.y), rockTop(place.x, place.y, reach: 1))
                    + 0.3
                let rise = r.float(0, 1)
                let way = simd_normalize(SIMD3<Float>(a.x * 0.25 + out.x * 0.6, a.y * 0.25, 3))
                let speed = r.float(0.15, 1)
                add(
                    SIMD3(place.x, place.y, base + rise * rise * 4), dust: rate * falling,
                    velocity: way * 11 * column.lift * speed * speed + r.unit() * 3, heat: 0.7)
            }
        }
        let buffer = queue.makeCommandBuffer()!
        let encoder = buffer.makeComputeCommandEncoder()!
        var u = uniforms
        u.hdtsteps.y = dt
        // The wind in the flow and its gusts go by the event's time (stage 3k).
        u.lowHigh.w = time
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
        encoder.setTexture(clearance, index: 2)
        run("dustAdvectVelocity")
        encoder.memoryBarrier(scope: .textures)
        velocity.swapAt(0, 1)
        encoder.setTexture(velocity[0], index: 0)
        encoder.setTexture(density[0], index: 1)
        encoder.setTexture(velocity[1], index: 2)
        encoder.setTexture(noiseVolume, index: 3)
        encoder.setTexture(clearance, index: 4)
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
        encoder.memoryBarrier(scope: .textures)
        encodeHazeBound(encoder)
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
        encodeHazeBound(encoder)
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// All the fields' bytes.
    public var bytes: Int {
        (velocity + density + pressure + scratch
            + [divergence, light, solid, clearance, noiseVolume, hazeBound])
            .reduce(source.length) { $0 + $1.allocatedSize }
    }
}
