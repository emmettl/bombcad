import BlastCore
import CoreGraphics
import Foundation
import Metal
import simd

public enum DisplayMode: Int, CaseIterable, Identifiable, Sendable {
    case overpressure = 0
    case peakOverpressure = 1
    case impulse = 2

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .overpressure: "Overpressure now"
        case .peakOverpressure: "Peak overpressure"
        case .impulse: "Impulse"
        }
    }

    public var unit: String { self == .impulse ? "kPa·ms" : "kPa" }
}

public struct RenderSettings: Sendable, Hashable {
    /// Field painted onto the ground and the blocks.
    public var mode: DisplayMode = .peakOverpressure
    /// Top of the surface colour scale, in kPa.
    public var pressureScale: Float = 300
    /// Top of the surface colour scale in impulse mode, in kPa ms (equal to Pa s).
    public var impulseScale: Float = 1000
    /// Pressure jump across one cell, in kPa, at which the blast wave in the air is drawn brightest.
    public var waveScale: Float = 30
    /// Decades spanned by the logarithmic colour scales.
    public var decades: Float = 2
    public var showWave = true
    public var waveOpacity: Float = 0.3
    public var showCharge = true
    /// Fragments in flight and where they landed, and tracers, when a run flies them.
    public var showFragments = true
    public var showTracers = true
    /// Ground points where the ground's shaking is estimated, when the project has any.
    public var showGroundPoints = true
    /// The thermal radiation's receivers, coloured by their fluence, when a run reckons it.
    public var showThermal = true
    /// Their dots' diameter on screen, in points, whatever their true size.
    public var dotSize: Float = 5
    /// A box to outline in the view, such as the one being edited.
    public var highlight: Box?

    public init() {}

    public var surfaceScale: Float { mode == .impulse ? impulseScale : pressureScale }
}

/// Layout matches `RenderUniforms` in `Render.metal`.
private struct RenderUniforms {
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    var domain: SIMD4<Float>
    var display: SIMD4<Float>
    var counts: SIMD4<Float>
    var charge: SIMD4<Float>
    var sun: SIMD4<Float>
    var clip: SIMD4<Float>
    var highlightLow: SIMD4<Float>
    var highlightHigh: SIMD4<Float>
}

/// Layout matches `MeshUniforms` in `Render.metal`.
private struct MeshUniforms {
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var forward: SIMD4<Float>
    var projection: SIMD4<Float>
    var lattice: SIMD4<Float>
    var dims: SIMD4<Float>
    var sun: SIMD4<Float>
}

/// Draws a scenario, its deformable structure and the solver's visualisation volume.
///
/// A frame takes two passes: the scene and the structure's mesh go into an offscreen colour and
/// depth target, then the blast wave is ray-marched over them into the destination.
public final class SceneRenderer {
    public static let maxBoxes = 2048
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    private static let depthFormat = MTLPixelFormat.depth32Float
    private static let nearPlane: Float = 0.5
    private static let farPlane: Float = 4000

    public let device: MTLDevice
    public var settings = RenderSettings()

    private let scenePipeline: MTLRenderPipelineState
    private let meshPipeline: MTLRenderPipelineState
    private let shellPipeline: MTLRenderPipelineState
    private let beamPipeline: MTLRenderPipelineState
    private let glassPipeline: MTLRenderPipelineState
    private let dotPipeline: MTLRenderPipelineState
    private var dotBuffer: MTLBuffer?
    private var dotCount = 0
    private let freestandingPipeline: MTLRenderPipelineState
    private var freestandingBuffer: MTLBuffer?
    private var freestandingCount = 0
    private let compositePipeline: MTLRenderPipelineState
    private let sceneDepthState: MTLDepthStencilState
    private let meshDepthState: MTLDepthStencilState
    /// Tested against what is drawn but not written, for glass.
    private let glassDepthState: MTLDepthStencilState
    private let boxBuffer: MTLBuffer
    private let gaugeBuffer: MTLBuffer
    private var boxCount = 0
    private var gaugeCount = 0
    private var scenario: Scenario?
    private var cellSize: Float = 1
    private var field: MTLTexture?
    private var bodies: [StructuralBody] = []
    private var ambientPressure: Float = 101_325
    private var colourTarget: MTLTexture?
    private var depthTarget: MTLTexture?

    public init(device: MTLDevice) throws {
        self.device = device
        guard
            let url = Bundle.module.url(
                forResource: "Render", withExtension: "metal", subdirectory: "Shaders")
        else {
            throw BlastError.missingShader("Render.metal")
        }
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        func pipeline(vertex: String, fragment: String, depth: Bool, blended: Bool = false) throws
            -> MTLRenderPipelineState
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            if blended {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if depth {
                descriptor.depthAttachmentPixelFormat = Self.depthFormat
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        scenePipeline = try pipeline(vertex: "fullscreenVertex", fragment: "sceneFragment", depth: true)
        meshPipeline = try pipeline(vertex: "structureVertex", fragment: "structureFragment", depth: true)
        shellPipeline = try pipeline(vertex: "shellVertex", fragment: "structureFragment", depth: true)
        beamPipeline = try pipeline(vertex: "beamVertex", fragment: "structureFragment", depth: true)
        glassPipeline = try pipeline(
            vertex: "shellVertex", fragment: "glassFragment", depth: true, blended: true)
        dotPipeline = try pipeline(vertex: "dotVertex", fragment: "dotFragment", depth: true)
        freestandingPipeline = try pipeline(
            vertex: "freestandingVertex", fragment: "freestandingFragment", depth: true)
        compositePipeline = try pipeline(
            vertex: "fullscreenVertex", fragment: "compositeFragment", depth: false)

        func depthState(_ compare: MTLCompareFunction, writes: Bool = true) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = writes
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw BlastError.allocationFailed("depth state")
            }
            return state
        }
        sceneDepthState = try depthState(.always)
        meshDepthState = try depthState(.less)
        glassDepthState = try depthState(.less, writes: false)

        let vectorStride = MemoryLayout<SIMD4<Float>>.stride
        guard
            let boxes = device.makeBuffer(
                length: Self.maxBoxes * 2 * vectorStride, options: .storageModeShared),
            let gauges = device.makeBuffer(
                length: BlastSolver.maxGauges * vectorStride, options: .storageModeShared)
        else {
            throw BlastError.allocationFailed("scene buffers")
        }
        boxBuffer = boxes
        gaugeBuffer = gauges
    }

    /// Points the renderer at a scenario and the solver simulating it.
    public func setScene(_ scenario: Scenario, solver: BlastSolver) {
        self.scenario = scenario
        cellSize = solver.grid.cellSize
        field = solver.visualizationTexture
        bodies = solver.bodies
        ambientPressure = scenario.atmosphere.pressure

        boxCount = min(scenario.rigidBoxes.count, Self.maxBoxes)
        let boxes = boxBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxBoxes * 2)
        for (n, box) in scenario.rigidBoxes.prefix(boxCount).enumerated() {
            boxes[2 * n] = SIMD4(box.min, 0)
            boxes[2 * n + 1] = SIMD4(box.max, 0)
        }
        gaugeCount = min(scenario.gauges.count, BlastSolver.maxGauges)
        let gauges = gaugeBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: BlastSolver.maxGauges)
        for (n, gauge) in scenario.gauges.prefix(gaugeCount).enumerated() {
            gauges[n] = SIMD4(gauge.position, 0.35)
        }
    }

    /// Pixels to a point on the screen drawn to, for dots of a size in points.
    public var pixelsPerPoint: Float = 1

    /// Dots to draw over the scene: each a position and a code, its kind (0 a fragment in flight,
    /// 1 a tracer, 2 a fragment's landing, 3 a ground point, 4 a thermal receiver) plus a value
    /// from 0 to 1 that colours it (a fragment's speed, a landing's energy, how fast the ground
    /// under a point has moved, a receiver's fluence).
    public func setDots(_ dots: [SIMD4<Float>]) {
        dotCount = dots.count
        guard !dots.isEmpty else { return }
        let length = dots.count * MemoryLayout<SIMD4<Float>>.stride
        if (dotBuffer?.length ?? 0) < length {
            dotBuffer = device.makeBuffer(length: max(length, 4096) * 2, options: .storageModeShared)
        }
        guard let dotBuffer else {
            dotCount = 0
            return
        }
        dots.withUnsafeBytes { dotBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length) }
    }

    /// A freestanding object to draw: an oriented box, a car's shell or a rigid box.
    public struct OrientedBox: Sendable, Hashable {
        public var centre: SIMD3<Float>
        /// Body to world, as a unit quaternion.
        public var orientation: simd_quatf
        public var size: SIMD3<Float>
        public var isCar: Bool

        public init(centre: SIMD3<Float>, orientation: simd_quatf, size: SIMD3<Float>, isCar: Bool) {
            self.centre = centre
            self.orientation = orientation
            self.size = size
            self.isCar = isCar
        }
    }

    /// Freestanding objects to draw over the scene, at their current poses.
    public func setFreestanding(_ boxes: [OrientedBox]) {
        freestandingCount = boxes.count
        guard !boxes.isEmpty else { return }
        let values = boxes.flatMap {
            [SIMD4($0.centre, $0.isCar ? 1 : 0), $0.orientation.vector, SIMD4($0.size / 2, 0)]
        }
        let length = values.count * MemoryLayout<SIMD4<Float>>.stride
        if (freestandingBuffer?.length ?? 0) < length {
            freestandingBuffer = device.makeBuffer(length: max(length, 4096), options: .storageModeShared)
        }
        guard let freestandingBuffer else {
            freestandingCount = 0
            return
        }
        values.withUnsafeBytes {
            freestandingBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: length)
        }
    }

    /// Encodes a frame into `descriptor`'s first colour attachment.
    public func encode(
        into commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor, camera: OrbitCamera
    ) {
        guard let scenario, let field, let destination = descriptor.colorAttachments[0].texture,
            let (colourTarget, depthTarget) = targets(width: destination.width, height: destination.height)
        else { return }

        let aspectRatio = Float(destination.width) / Float(max(destination.height, 1))
        let eye = camera.eye
        let forward = simd_normalize(camera.target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let halfHeight = tan(camera.fieldOfView / 2)
        let sun = SIMD4(simd_normalize(SIMD3<Float>(0.35, -0.55, 0.75)), 0)
        // Pressure channels are stored in units of ambient pressure, impulse in Pa s (= kPa ms).
        let kiloPascal = 1000 / ambientPressure
        let surfaceScale =
            settings.mode == .impulse ? settings.impulseScale : settings.pressureScale * kiloPascal
        var uniforms = RenderUniforms(
            eye: SIMD4(eye, 1),
            right: SIMD4(right * halfHeight * aspectRatio, 0),
            up: SIMD4(up * halfHeight, 0),
            forward: SIMD4(forward, 0),
            domain: SIMD4(scenario.domainSize, cellSize),
            display: SIMD4(
                Float(settings.mode.rawValue), surfaceScale, settings.decades,
                settings.showWave ? settings.waveOpacity : 0),
            counts: SIMD4(
                Float(boxCount), Float(gaugeCount), settings.showCharge ? 0.45 : 0,
                settings.waveScale * kiloPascal),
            charge: SIMD4(scenario.charge.position, 0),
            sun: sun,
            clip: SIMD4(Self.nearPlane, Self.farPlane, 0, 0),
            highlightLow: SIMD4(settings.highlight?.min ?? .zero, settings.highlight == nil ? 0 : 1),
            highlightHigh: SIMD4(settings.highlight?.max ?? .zero, 0))

        // Pass 1: ground, blocks and markers, then the structure's mesh, sharing a depth buffer.
        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = colourTarget
        scenePass.colorAttachments[0].loadAction = .dontCare
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.depthAttachment.texture = depthTarget
        scenePass.depthAttachment.loadAction = .clear
        scenePass.depthAttachment.clearDepth = 1
        scenePass.depthAttachment.storeAction = .store
        guard let sceneEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        sceneEncoder.setRenderPipelineState(scenePipeline)
        sceneEncoder.setDepthStencilState(sceneDepthState)
        sceneEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        sceneEncoder.setFragmentBuffer(boxBuffer, offset: 0, index: 1)
        sceneEncoder.setFragmentBuffer(gaugeBuffer, offset: 0, index: 2)
        sceneEncoder.setFragmentTexture(field, index: 0)
        sceneEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        var transparentBodies: [ShellSolver] = []
        for body in bodies {
            if let structure = body.solids, structure.elementCount > 0 {
                var mesh = MeshUniforms(
                    eye: SIMD4(eye, 1), right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
                    projection: SIMD4(
                        1 / (halfHeight * aspectRatio), 1 / halfHeight, Self.nearPlane, Self.farPlane),
                    lattice: SIMD4(structure.origin, structure.model.elementSize),
                    dims: SIMD4(
                        Float(structure.ex), Float(structure.ey), Float(structure.ez),
                        Float(StructureSolver.stateStride / 4)),
                    sun: sun)
                sceneEncoder.setRenderPipelineState(meshPipeline)
                sceneEncoder.setDepthStencilState(meshDepthState)
                sceneEncoder.setCullMode(.none)
                sceneEncoder.setVertexBuffer(structure.instanceBuffer, offset: 0, index: 0)
                sceneEncoder.setVertexBuffer(structure.nodeBuffer, offset: 0, index: 1)
                sceneEncoder.setVertexBuffer(structure.flagBuffer, offset: 0, index: 2)
                sceneEncoder.setVertexBuffer(structure.stateBuffer, offset: 0, index: 3)
                sceneEncoder.setVertexBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 4)
                sceneEncoder.setVertexBuffer(structure.nodeMapBuffer, offset: 0, index: 5)
                sceneEncoder.setFragmentBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 0)
                sceneEncoder.drawPrimitives(
                    type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: structure.elementCount)
            }
            if let shells = body.shells, shells.elementCount + shells.beamCount > 0 {
                var mesh = MeshUniforms(
                    eye: SIMD4(eye, 1), right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
                    projection: SIMD4(
                        1 / (halfHeight * aspectRatio), 1 / halfHeight, Self.nearPlane, Self.farPlane),
                    lattice: .zero, dims: .zero, sun: sun)
                sceneEncoder.setRenderPipelineState(shellPipeline)
                sceneEncoder.setDepthStencilState(meshDepthState)
                sceneEncoder.setCullMode(.none)
                sceneEncoder.setVertexBuffer(shells.elementBuffer, offset: 0, index: 0)
                sceneEncoder.setVertexBuffer(shells.nodeBuffer, offset: 0, index: 1)
                sceneEncoder.setVertexBuffer(shells.flagBuffer, offset: 0, index: 2)
                sceneEncoder.setVertexBuffer(shells.displayBuffer, offset: 0, index: 3)
                sceneEncoder.setVertexBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 4)
                sceneEncoder.setVertexBuffer(shells.referenceBuffer, offset: 0, index: 5)
                sceneEncoder.setFragmentBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 0)
                // Glass is drawn last, over everything opaque (below).
                var transparent: UInt32 = 0
                for (n, material) in shells.materials.enumerated() where material.isTransparent && n < 32 {
                    transparent |= 1 << UInt32(n)
                }
                var draw: UInt32 = transparent == 0 ? 0 : 1
                sceneEncoder.setVertexBytes(&transparent, length: 4, index: 6)
                sceneEncoder.setVertexBytes(&draw, length: 4, index: 7)
                if shells.elementCount > 0 {
                    sceneEncoder.drawPrimitives(
                        type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: shells.elementCount)
                }
                if transparent != 0 && shells.elementCount > 0 { transparentBodies.append(shells) }
                if shells.beamCount > 0 {
                    sceneEncoder.setRenderPipelineState(beamPipeline)
                    sceneEncoder.setVertexBuffer(shells.beamBuffer, offset: 0, index: 0)
                    sceneEncoder.setVertexBuffer(shells.beamFlagBuffer, offset: 0, index: 2)
                    sceneEncoder.setVertexBuffer(shells.beamDisplayBuffer, offset: 0, index: 3)
                    sceneEncoder.drawPrimitives(
                        type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: shells.beamCount)
                }
            }
        }
        if freestandingCount > 0, let freestandingBuffer {
            var mesh = MeshUniforms(
                eye: SIMD4(eye, 1), right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
                projection: SIMD4(
                    1 / (halfHeight * aspectRatio), 1 / halfHeight, Self.nearPlane, Self.farPlane),
                lattice: .zero, dims: .zero, sun: sun)
            sceneEncoder.setRenderPipelineState(freestandingPipeline)
            sceneEncoder.setDepthStencilState(meshDepthState)
            sceneEncoder.setCullMode(.none)
            sceneEncoder.setVertexBuffer(freestandingBuffer, offset: 0, index: 0)
            sceneEncoder.setVertexBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            sceneEncoder.setFragmentBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 0)
            sceneEncoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: freestandingCount)
        }
        if dotCount > 0, let dotBuffer {
            var mesh = MeshUniforms(
                eye: SIMD4(eye, 1), right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
                projection: SIMD4(
                    1 / (halfHeight * aspectRatio), 1 / halfHeight, Self.nearPlane, Self.farPlane),
                lattice: .zero, dims: .zero, sun: sun)
            // The dot's size in pixels: points scaled as the drawable is to the view.
            var viewport = SIMD4<Float>(
                Float(destination.width), Float(destination.height), settings.dotSize * pixelsPerPoint, 0)
            sceneEncoder.setRenderPipelineState(dotPipeline)
            sceneEncoder.setDepthStencilState(meshDepthState)
            sceneEncoder.setVertexBuffer(dotBuffer, offset: 0, index: 0)
            sceneEncoder.setVertexBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 1)
            sceneEncoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            sceneEncoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: dotCount)
        }
        for glass in transparentBodies {
            sceneEncoder.setRenderPipelineState(glassPipeline)
            sceneEncoder.setDepthStencilState(glassDepthState)
            var mesh = MeshUniforms(
                eye: SIMD4(eye, 1), right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
                projection: SIMD4(
                    1 / (halfHeight * aspectRatio), 1 / halfHeight, Self.nearPlane, Self.farPlane),
                lattice: .zero, dims: .zero, sun: sun)
            var transparent: UInt32 = 0
            for (n, material) in glass.materials.enumerated() where material.isTransparent && n < 32 {
                transparent |= 1 << UInt32(n)
            }
            sceneEncoder.setVertexBuffer(glass.nodeBuffer, offset: 0, index: 1)
            sceneEncoder.setVertexBuffer(glass.referenceBuffer, offset: 0, index: 5)
            sceneEncoder.setVertexBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 4)
            sceneEncoder.setFragmentBytes(&mesh, length: MemoryLayout<MeshUniforms>.stride, index: 0)
            sceneEncoder.setVertexBytes(&transparent, length: 4, index: 6)
            sceneEncoder.setVertexBuffer(glass.elementBuffer, offset: 0, index: 0)
            sceneEncoder.setVertexBuffer(glass.flagBuffer, offset: 0, index: 2)
            sceneEncoder.setVertexBuffer(glass.displayBuffer, offset: 0, index: 3)
            var draw: UInt32 = 2
            sceneEncoder.setVertexBytes(&draw, length: 4, index: 7)
            sceneEncoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: glass.elementCount)
        }
        sceneEncoder.endEncoding()

        // Pass 2: the blast wave over the finished scene.
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<RenderUniforms>.stride, index: 0)
        encoder.setFragmentTexture(colourTarget, index: 0)
        encoder.setFragmentTexture(depthTarget, index: 1)
        encoder.setFragmentTexture(field, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// Offscreen colour and depth targets matching the destination, recreated when it resizes.
    private func targets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let colourTarget, let depthTarget, colourTarget.width == width, colourTarget.height == height {
            return (colourTarget, depthTarget)
        }
        func texture(_ format: MTLPixelFormat) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            return device.makeTexture(descriptor: descriptor)
        }
        guard let colour = texture(Self.pixelFormat), let depth = texture(Self.depthFormat) else {
            return nil
        }
        colourTarget = colour
        depthTarget = depth
        return (colour, depth)
    }

    /// Renders one frame offscreen and returns it, blocking until the GPU has finished.
    public func snapshot(
        commandQueue: MTLCommandQueue, width: Int, height: Int, camera: OrbitCamera
    ) -> (image: CGImage, gpuSeconds: Double)? {
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: textureDescriptor),
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        encode(into: commandBuffer, descriptor: pass, camera: camera)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(
            &pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return (image, commandBuffer.gpuEndTime - commandBuffer.gpuStartTime)
    }
}
