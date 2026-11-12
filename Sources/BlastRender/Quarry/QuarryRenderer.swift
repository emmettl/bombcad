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
    /// xyz unused; w 2 when the far ground fades into the backdrop's hills (a ridge cut), else 1.
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
    /// Texels of the top-down height between the fines' grid points.
    public var finesStep = 1
    public static let film = QuarryRenderQuality()
    public static let live = QuarryRenderQuality(
        shadowSize: 4096, decorScale: 0.35, heightEvery: 6, finesStep: 2)
}

public final class QuarryRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let library: MTLLibrary
    public let hillside: QuarryFace
    /// The frame's size (pixels), which `resize(width:height:)` changes.
    public private(set) var width: Int
    public private(set) var height: Int
    public let supersample: Int
    /// The meshes on the GPU, shared with any other renderer of the same rock.
    public let meshes: QuarryMeshBuffers
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
    public private(set) var hdr: MTLTexture
    public private(set) var hdrDepth: MTLTexture
    public private(set) var output: MTLTexture
    public let heightMap: MTLTexture
    /// The top-down height's colour: each texel's top height and what is there (blocks of the pile
    /// at rest, the ground, or something else).
    public let heightColour: MTLTexture
    /// The excavated ground's heights, and the fines' surface over the top-down grid.
    public let groundHeights: MTLTexture
    public let fines: MTLTexture
    let finesScratch: MTLTexture
    public let finesIndices: MTLBuffer
    public let finesIndexCount: Int
    public var finesUniforms: QuarryFinesUniforms
    /// The event time the fines were last built for.
    public var finesTime: Float = -.infinity
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
    public let blockHeight: MTLRenderPipelineState
    public let terrainHeight: MTLRenderPipelineState
    public let finesBuild: MTLComputePipelineState
    public let finesRelax: MTLComputePipelineState
    public let finesPipeline: MTLRenderPipelineState
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
    /// The chips' shapes: `QuarryChipShapes.count` small convex stones, each as
    /// `QuarryChipShapes.vertices` vertices of unindexed triangles.
    public let chipShapes: MTLBuffer
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
    /// The projection's width over its height: the frame's own, unless it is to be shown stretched
    /// over a view of another shape (the window's, while its size settles).
    public var aspect: Float
    /// The view and projection of the frame drawn last.
    public private(set) var lastViewProjection = matrix_identity_float4x4
    public let frameRate: Float

    public init(
        device: MTLDevice, face hillside: QuarryFace, width: Int, height: Int, supersample: Int,
        path: QuarryCameraPath, frameRate: Float, quality: QuarryRenderQuality = .film,
        sun: SIMD3<Float>? = nil
    ) throws {
        let sunGiven = sun ?? Self.sun(hillside)
        self.quality = quality
        self.device = device
        let library = try QuarryShaders.library(device: device, file: "QuarryRender", bundle: Bundle.module)
        self.library = library
        dustPass = try QuarryDustPass(
            device: device, library: library, width: width * supersample, height: height * supersample)
        // The meshes go to the GPU here, or are found there for a face kept without them; the
        // copy kept here does without them.
        self.hillside = hillside.withoutMesh()
        self.width = width
        self.height = height
        self.supersample = supersample
        self.cameraPath = path
        self.frameRate = frameRate
        queue = device.makeCommandQueue()!
        meshes = QuarryMeshBuffers.of(hillside, device: device)
        blockVertices = meshes.blockVertices
        blockIndices = meshes.blockIndices
        indexCount = meshes.indexCount
        dressingVertices = meshes.dressingVertices
        dressingIndices = meshes.dressingIndices
        dressingCount = meshes.dressingCount
        let identity: [SIMD4<Float>] = [SIMD4(0, 0, 0, 0), SIMD4(0, 0, 0, 1)]
        identityPose = device.makeBuffer(bytes: identity, length: 32)!
        let identityR: [SIMD4<Float>] = [.zero]
        identityRest = device.makeBuffer(bytes: identityR, length: 16)!
        let rest = hillside.blocks.map { SIMD4<Float>($0.centre, Float($0.size)) }
        restCentres = device.makeBuffer(bytes: rest, length: 16 * rest.count)!
        let chipData = QuarryDecor.make(face: hillside, scale: quality.decorScale)
        chips = chipData.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        chipCount = chipData.count
        let shapeData = QuarryChipShapes.make()
        chipShapes = device.makeBuffer(bytes: shapeData, length: 16 * shapeData.count)!
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
                // The steep ground sits behind the render-only rock, not through it: set back along
                // its normal (straight down left a near-vertical face where it was).
                let inset: Float = n.z < 0.8 ? 1.8 : 0
                let p = SIMD3(x, y, h(i, j)) - n * inset
                vertices += [p.x, p.y, p.z, n.x, n.y, n.z]
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
        var extColumns = 570
        var extRows = 296
        var (extX, extY): (Float, Float) = (-610, t.origin.y + 1)
        if hillside.ridge != nil {
            // A ridge runs on both ways across the cut's line: the ground all round it.
            extColumns = Int(
                (t.origin.x + Float(t.columns) * t.spacing + 900 - (t.origin.x - 600)) / extSpacing)
            extRows = 440
            (extX, extY) = (t.origin.x - 600, -660)
        }
        func inMain(_ x: Float, _ y: Float) -> Bool {
            x > t.origin.x + 1 && x < t.origin.x + Float(t.columns - 2) * t.spacing
                && y < t.origin.y + Float(t.rows - 2) * t.spacing
                && (hillside.ridge == nil || y > t.origin.y + 1)
        }
        func extHeight(_ x: Float, _ y: Float) -> Float {
            if inMain(x, y) { return hillside.height(t.heights, x, y) - 2.2 }
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
                let p = SIMD3(x, y, z) - n * inset
                vertices += [p.x, p.y, p.z, n.x, n.y, n.z]
            }
        }
        for j in 0..<(extRows - 1) {
            for i in 0..<(extColumns - 1) {
                // Not over the main grid: at 3 m its chords stood in front of a steep face's foot
                // and showed as a smooth wall past the strip's ends (12 November 2026).
                let (x0, y0) = (extX + Float(i) * extSpacing, extY + Float(j) * extSpacing)
                if inMain(x0, y0), inMain(x0 + extSpacing, y0), inMain(x0, y0 + extSpacing),
                    inMain(x0 + extSpacing, y0 + extSpacing)
                {
                    continue
                }
                let a = extBase + UInt32(i + j * extColumns)
                let b = a + 1
                let c = a + UInt32(extColumns)
                let d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        // A ground beyond the grid, so the long lens sees no edge: a low skirt on four sides.
        let skirtBase = UInt32(vertices.count / 6)
        if hillside.ridge != nil {
            // Round the whole of it, at the height of its edge, a little below so it never shows
            // through: a frame of four quads from the edge out to 2.5 km.
            let (x0, y0) = (extX + extSpacing, extY + extSpacing)
            let (x1, y1) = (extX + Float(extColumns - 2) * extSpacing, extY + Float(extRows - 2) * extSpacing)
            var edge: [Float] = []
            for k in 0..<64 {
                let u = Float(k) / 63
                edge += [
                    extHeight(x0 + (x1 - x0) * u, y0), extHeight(x0 + (x1 - x0) * u, y1),
                    extHeight(x0, y0 + (y1 - y0) * u), extHeight(x1, y0 + (y1 - y0) * u),
                ]
            }
            let z = edge.reduce(0, +) / Float(edge.count) - 1
            let far: Float = 2500
            let ring: [(Float, Float)] = [
                (x0, y0), (x1, y0), (x1, y1), (x0, y1),
                (x0 - far, y0 - far), (x1 + far, y0 - far), (x1 + far, y1 + far), (x0 - far, y1 + far),
            ]
            for (x, y) in ring { vertices += [x, y, z, 0, 0, 1] }
            for k in 0..<4 {
                let (a, b) = (skirtBase + UInt32(k), skirtBase + UInt32((k + 1) % 4))
                let (c, d) = (a + 4, b + 4)
                indices += [a, c, b, b, c, d]
            }
        } else {
            let skirt: [(Float, Float)] = [
                (-900, -900), (900, -900), (900, t.origin.y + 2), (-900, t.origin.y + 2),
            ]
            for (x, y) in skirt { vertices += [x, y, 0.1, 0, 0, 1] }
            indices += [skirtBase, skirtBase + 2, skirtBase + 1, skirtBase, skirtBase + 3, skirtBase + 2]
        }
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
        let colourDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rg32Float, width: 1000, height: 790, mipmapped: false)
        colourDescriptor.usage = [.renderTarget, .shaderRead]
        colourDescriptor.storageMode = .private
        heightColour = device.makeTexture(descriptor: colourDescriptor)!
        let finesDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: 1000, height: 790, mipmapped: false)
        finesDescriptor.usage = [.shaderRead, .shaderWrite]
        finesDescriptor.storageMode = .private
        fines = device.makeTexture(descriptor: finesDescriptor)!
        finesScratch = device.makeTexture(descriptor: finesDescriptor)!
        let groundDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: t.columns, height: t.rows, mipmapped: false)
        groundDescriptor.usage = [.shaderRead]
        let groundTexture = device.makeTexture(descriptor: groundDescriptor)!
        groundHeights = groundTexture
        t.heights.withUnsafeBytes {
            groundTexture.replace(
                region: MTLRegionMake2D(0, 0, t.columns, t.rows), mipmapLevel: 0, withBytes: $0.baseAddress!,
                bytesPerRow: 4 * t.columns)
        }
        // The fines are drawn over the part of the top-down grid the pile can reach.
        let spanXY = SIMD2(hillside.high.x - hillside.low.x, hillside.high.y - hillside.low.y)
        func texel(_ x: Float, _ y: Float) -> SIMD2<Int> {
            SIMD2(
                Int((x - hillside.low.x) / spanXY.x * 1000),
                Int((1 - (y - hillside.low.y) / spanXY.y) * 790))
        }
        let faceYs = stride(from: Float(-20), through: hillside.length + 20, by: 2).map {
            hillside.faceLine($0)
        }
        var a = texel(-30, (faceYs.max() ?? 0) + hillside.depth + 8)
        var b = texel(hillside.length + 30, (faceYs.min() ?? 0) - 80)
        if let ridge = hillside.ridge {
            // Down both flanks along the line, and a way either side of the cut's walls.
            let reach = ridge.halfWidth + 45
            a = texel(-70, reach)
            b = texel(hillside.length + 70, -reach)
        }
        let first = SIMD2(max(0, min(a.x, b.x)), max(0, min(a.y, b.y)))
        let last = SIMD2(min(999, max(a.x, b.x)), min(789, max(a.y, b.y)))
        let step = quality.finesStep
        let columns = (last.x - first.x) / step + 1
        let rows = (last.y - first.y) / step + 1
        var grid = [UInt32]()
        grid.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for j in 0..<(rows - 1) {
            for i in 0..<(columns - 1) {
                let v = UInt32(i + j * columns)
                let below = v + UInt32(columns)
                grid += [v, below, v + 1, v + 1, below, below + 1]
            }
        }
        finesIndices = device.makeBuffer(bytes: grid, length: grid.count * 4)!
        finesIndexCount = grid.count
        finesUniforms = QuarryFinesUniforms(
            low: SIMD4(hillside.low.x, hillside.low.y, spanXY.x, spanXY.y),
            ground: SIMD4(t.origin.x, t.origin.y, t.spacing, 0),
            misc: SIMD4(0, 0, Float(first.x), Float(first.y)),
            grid: SIMD4(Float(step), Float(columns), Float(rows), 0))
        (hdr, hdrDepth, output) = Self.frameTargets(
            device: device, width: width, height: height, supersample: supersample)
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
        blockHeight = try pipeline(vertex: "blockHeightVertex", fragment: "heightFragment", color: .rg32Float)
        terrainHeight = try pipeline(
            vertex: "terrainHeightVertex", fragment: "heightFragment", color: .rg32Float)
        finesBuild = try device.makeComputePipelineState(function: library.makeFunction(name: "finesBuild")!)
        finesRelax = try device.makeComputePipelineState(function: library.makeFunction(name: "finesRelax")!)
        finesPipeline = try pipeline(vertex: "finesVertex", fragment: "finesFragment")
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
        let sun = simd_normalize(sunGiven)
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
            fogColor: SIMD4(0.6, 0.55, 0.5, hillside.ridge == nil ? 1 : 2), terrainOrigin: .zero,
            inverseViewProjection: matrix_identity_float4x4,
            dustLow: .zero, dustHigh: .zero, misc: .zero)
    }

    /// The scene's own low sun, in the strip's frame: a face's rakes along it from in front; a
    /// ridge cut's is its opening view's (`QuarryRidgeView`), along the ridge from the side the view
    /// looks from, so that the cut's wall facing the eye is lit and the flanks are raked.
    public static func sun(_ face: QuarryFace) -> SIMD3<Float> {
        QuarryRidgeView.opening(face)?.sun ?? SIMD3(0.86, -0.42, 0.26)
    }

    /// The targets of a frame `width` by `height`: the scene's colour and depth (supersampled) and
    /// the frame drawn from them.
    static func frameTargets(device: MTLDevice, width: Int, height: Int, supersample: Int) -> (
        hdr: MTLTexture, depth: MTLTexture, output: MTLTexture
    ) {
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float, width: width * supersample, height: height * supersample,
            mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        let hdrDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: width * supersample, height: height * supersample,
            mipmapped: false)
        hdrDescriptor.usage = [.renderTarget, .shaderRead]
        hdrDescriptor.storageMode = .private
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        outputDescriptor.usage = [.renderTarget, .shaderRead]
        return (
            device.makeTexture(descriptor: hdrDescriptor)!, device.makeTexture(descriptor: depthDescriptor)!,
            device.makeTexture(descriptor: outputDescriptor)!
        )
    }

    /// Makes the frame's targets again at `width` by `height` (pixels), and the projection that
    /// shape. Everything else (the geometry, the shadow, the chips, the fines) is kept.
    public func resize(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        aspect = Float(width) / Float(height)
        guard width != self.width || height != self.height else { return }
        self.width = width
        self.height = height
        (hdr, hdrDepth, output) = Self.frameTargets(
            device: device, width: width, height: height, supersample: supersample)
        dustPass.resize(device: device, width: width * supersample, height: height * supersample)
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
        lastViewProjection = vp
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
        // After a jump the fines are built again from this frame alone. While the rock is still in
        // the air its fines are left out: a jump gives no speeds to tell what has landed.
        if abs(time - finesTime) > Float(quality.heightEvery) / frameRate + 0.02 {
            let landed = time > 7
            if landed { encodeHeight(buffer, pose: pose, previous: pose, rate: 0) }
            encodeFines(buffer, time: time, gathered: landed ? Self.finesGathered(time) : 0)
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
        shadow.setVertexBuffer(chipShapes, offset: 0, index: 5)
        shadow.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: QuarryChipShapes.vertices, instanceCount: chipCount)
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
        // The fines over the pile.
        var fineUniforms = finesUniforms
        scene.setRenderPipelineState(finesPipeline)
        scene.setVertexTexture(fines, index: 0)
        scene.setVertexBytes(&fineUniforms, length: MemoryLayout<QuarryFinesUniforms>.stride, index: 3)
        scene.drawIndexedPrimitives(
            type: .triangle, indexCount: finesIndexCount, indexType: .uint32, indexBuffer: finesIndices,
            indexBufferOffset: 0)
        scene.setRenderPipelineState(chipPipeline)
        scene.setVertexBuffer(chips, offset: 0, index: 0)
        scene.setVertexBuffer(restCentres, offset: 0, index: 3)
        scene.setVertexBuffer(chipShapes, offset: 0, index: 5)
        scene.drawPrimitives(
            type: .triangle, vertexStart: 0, vertexCount: QuarryChipShapes.vertices, instanceCount: chipCount)
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

    /// The top-down height of the scene (blocks and ground), for the chips to land on and the
    /// fines to fill. `rate` is the frame rate between `pose` and `previous`, for telling which
    /// blocks are at rest; 0 counts every released block as at rest.
    func encodeHeight(_ buffer: MTLCommandBuffer, pose: MTLBuffer, previous: MTLBuffer, rate: Float) {
        var top = camera
        top.shadow = topDown
        top.misc = SIMD4(0, 0, rate, 0)
        let heightPass = MTLRenderPassDescriptor()
        heightPass.depthAttachment.texture = heightMap
        heightPass.depthAttachment.loadAction = .clear
        heightPass.depthAttachment.storeAction = .store
        heightPass.depthAttachment.clearDepth = 1
        heightPass.colorAttachments[0].texture = heightColour
        heightPass.colorAttachments[0].loadAction = .clear
        heightPass.colorAttachments[0].storeAction = .store
        heightPass.colorAttachments[0].clearColor = MTLClearColor(red: -1000, green: 0, blue: 0, alpha: 0)
        let encoder = buffer.makeRenderCommandEncoder(descriptor: heightPass)!
        encoder.setDepthStencilState(opaqueDepth)
        encoder.setCullMode(.none)
        encoder.setVertexBytes(&top, length: MemoryLayout<QuarryCameraUniforms>.stride, index: 2)
        encoder.setRenderPipelineState(blockHeight)
        encoder.setVertexBuffer(blockVertices, offset: 0, index: 0)
        encoder.setVertexBuffer(pose, offset: 0, index: 1)
        encoder.setVertexBuffer(previous, offset: 0, index: 4)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: indexCount, indexType: .uint32, indexBuffer: blockIndices,
            indexBufferOffset: 0)
        encoder.setRenderPipelineState(terrainHeight)
        encoder.setVertexBuffer(terrainVertices, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle, indexCount: terrainIndexCount, indexType: .uint32,
            indexBuffer: terrainIndices,
            indexBufferOffset: 0)
        encoder.endEncoding()
    }

    /// How far the fines have gathered on the pile at `time`: from nothing as the rock lands to
    /// all of them as it settles.
    public static func finesGathered(_ time: Float) -> Float { max(0, min(1, (time - 3) / 5)) }

    /// The fines' surface from the top-down height as it stands.
    func encodeFines(_ buffer: MTLCommandBuffer, time: Float, gathered: Float) {
        var u = finesUniforms
        u.misc.x = time
        u.misc.y = gathered
        let compute = buffer.makeComputeCommandEncoder()!
        compute.setComputePipelineState(finesBuild)
        compute.setTexture(heightColour, index: 0)
        compute.setTexture(groundHeights, index: 1)
        compute.setTexture(fines, index: 2)
        compute.setBytes(&u, length: MemoryLayout<QuarryFinesUniforms>.stride, index: 0)
        let grid = MTLSize(width: fines.width, height: fines.height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        compute.dispatchThreads(grid, threadsPerThreadgroup: group)
        compute.setComputePipelineState(finesRelax)
        for _ in 0..<3 {
            for (from, to) in [(fines, finesScratch), (finesScratch, fines)] {
                compute.memoryBarrier(scope: .textures)
                compute.setTexture(from, index: 0)
                compute.setTexture(to, index: 1)
                compute.dispatchThreads(grid, threadsPerThreadgroup: group)
            }
        }
        compute.endEncoding()
        finesTime = time
    }

    /// One frame's step of the decorative chips, over a top-down height of the scene, and the
    /// fines with it.
    public func stepDecor(pose: MTLBuffer, previous: MTLBuffer, time: Float) {
        let buffer = queue.makeCommandBuffer()!
        heightFrame += 1
        let redraw = heightFrame % quality.heightEvery == 1 || quality.heightEvery == 1
        if redraw { encodeHeight(buffer, pose: pose, previous: previous, rate: frameRate) }
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
        if redraw { encodeFines(buffer, time: time, gathered: Self.finesGathered(time)) }
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Back to the chips as built, for a jump backward.
    public func resetDecor() {
        chips.contents().copyMemory(from: pristineChips.contents(), byteCount: chips.length)
        finesTime = -.infinity
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

/// A face's meshes on the GPU: the blocks' and the dressing's. Made once for a generated rock and
/// shared by every renderer of it while one holds them, so the session can keep its face without
/// the meshes (`QuarryFace.withoutMesh()`) and a clip recorded from the session's face still has
/// them. Illustrative scene's plumbing.
public final class QuarryMeshBuffers: @unchecked Sendable {
    public let blockVertices: MTLBuffer
    public let blockIndices: MTLBuffer
    public let indexCount: Int
    public let dressingVertices: MTLBuffer
    public let dressingIndices: MTLBuffer
    public let dressingCount: Int

    init(_ face: QuarryFace, device: MTLDevice) {
        func buffer<T>(_ array: [T], minimum: Int) -> MTLBuffer {
            array.isEmpty
                ? device.makeBuffer(length: minimum)!
                : array.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count)! }
        }
        blockVertices = buffer(face.vertices, minimum: 20)
        blockIndices = buffer(face.indices, minimum: 12)
        indexCount = face.indices.count
        dressingVertices = buffer(face.dressingVertices, minimum: 20)
        dressingIndices = buffer(face.dressingIndices, minimum: 12)
        dressingCount = face.dressingIndices.count
    }

    private final class Weak {
        weak var meshes: QuarryMeshBuffers?
        init(_ meshes: QuarryMeshBuffers) { self.meshes = meshes }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [String: Weak] = [:]

    /// `face`'s meshes: made from its arrays when it has them, else those another renderer of the
    /// same rock made, while it still holds them (empty, drawing nothing, if none does).
    static func of(_ face: QuarryFace, device: MTLDevice) -> QuarryMeshBuffers {
        let key = "\(device.registryID)-\(face.meshID)"
        return lock.withLock {
            made = made.filter { $0.value.meshes != nil }
            if face.vertices.isEmpty, face.meshID != 0, let shared = made[key]?.meshes { return shared }
            let meshes = QuarryMeshBuffers(face, device: device)
            if !face.vertices.isEmpty, face.meshID != 0 { made[key] = Weak(meshes) }
            return meshes
        }
    }
}

/// Layout matches `QuarryFinesUniforms` in `QuarryRender.metal`.
public struct QuarryFinesUniforms {
    public var low: SIMD4<Float>
    public var ground: SIMD4<Float>
    public var misc: SIMD4<Float>
    public var grid: SIMD4<Float>
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
