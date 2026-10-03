import BlastCore
import CoreGraphics
import Foundation
import Metal
import simd

/// Camera orbiting a target point; z is up.
public struct OrbitCamera: Sendable, Hashable {
    public var target: SIMD3<Float>
    public var distance: Float
    /// Angle around the vertical axis in radians.
    public var azimuth: Float
    /// Angle above the horizon in radians.
    public var elevation: Float
    /// Vertical field of view in radians.
    public var fieldOfView: Float = 0.75

    public init(target: SIMD3<Float>, distance: Float, azimuth: Float, elevation: Float) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = elevation
    }

    /// A three-quarter view that frames the whole scenario.
    public static func framing(_ scenario: Scenario) -> OrbitCamera {
        if let structure = scenario.structure {
            // Close in on the structure and the charge rather than the whole domain.
            let bounds = structure.bounds
            let low = simd_min(bounds.min, scenario.charge.position)
            let high = simd_max(bounds.max, scenario.charge.position)
            let centre = (bounds.min + bounds.max) / 2
            return OrbitCamera(
                target: SIMD3(centre.x, centre.y, bounds.max.z * 0.4),
                distance: 1.3 * simd_length(high - low), azimuth: -2.45, elevation: 0.5)
        }
        let size = scenario.domainSize
        return OrbitCamera(
            target: SIMD3(size.x / 2, size.y / 2, size.z * 0.2),
            distance: 1.55 * max(size.x, size.y), azimuth: -2.75, elevation: 0.8)
    }

    public var eye: SIMD3<Float> {
        let horizontal = cos(elevation)
        return target + distance * SIMD3(horizontal * cos(azimuth), horizontal * sin(azimuth), sin(elevation))
    }

    /// The ray through a point of the view, given in normalised device coordinates (x right and
    /// y up, both from -1 to 1).
    public func ray(ndc: SIMD2<Float>, aspectRatio: Float) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)
    {
        let origin = eye
        let forward = simd_normalize(target - origin)
        let right = simd_normalize(simd_cross(forward, SIMD3(0, 0, 1)))
        let up = simd_cross(right, forward)
        let halfHeight = tan(fieldOfView / 2)
        let direction = forward + right * (ndc.x * halfHeight * aspectRatio) + up * (ndc.y * halfHeight)
        return (origin, simd_normalize(direction))
    }

    /// Where that ray meets the ground plane z = 0, if it does.
    public func groundPoint(ndc: SIMD2<Float>, aspectRatio: Float) -> SIMD3<Float>? {
        let (origin, direction) = ray(ndc: ndc, aspectRatio: aspectRatio)
        guard direction.z < -1e-6 else { return nil }
        return origin - direction * (origin.z / direction.z)
    }

    public mutating func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation = min(max(elevation + deltaElevation, 0.03), 1.55)
    }

    public mutating func zoom(by factor: Float) {
        distance = min(max(distance * factor, 3), 600)
    }

    /// Slides the target parallel to the ground, in view-relative directions.
    public mutating func pan(right: Float, forward: Float) {
        let ahead = SIMD3(-cos(azimuth), -sin(azimuth), 0)
        let side = SIMD3(-ahead.y, ahead.x, 0)
        target += (side * -right + ahead * forward) * distance
    }
}

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
    public static let maxBoxes = 64
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
    private let compositePipeline: MTLRenderPipelineState
    private let sceneDepthState: MTLDepthStencilState
    private let meshDepthState: MTLDepthStencilState
    private let boxBuffer: MTLBuffer
    private let gaugeBuffer: MTLBuffer
    private var boxCount = 0
    private var gaugeCount = 0
    private var scenario: Scenario?
    private var cellSize: Float = 1
    private var field: MTLTexture?
    private var structure: StructureSolver?
    private var shells: ShellSolver?
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
        func pipeline(vertex: String, fragment: String, depth: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            if depth {
                descriptor.depthAttachmentPixelFormat = Self.depthFormat
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        scenePipeline = try pipeline(vertex: "fullscreenVertex", fragment: "sceneFragment", depth: true)
        meshPipeline = try pipeline(vertex: "structureVertex", fragment: "structureFragment", depth: true)
        shellPipeline = try pipeline(vertex: "shellVertex", fragment: "structureFragment", depth: true)
        beamPipeline = try pipeline(vertex: "beamVertex", fragment: "structureFragment", depth: true)
        compositePipeline = try pipeline(
            vertex: "fullscreenVertex", fragment: "compositeFragment", depth: false)

        func depthState(_ compare: MTLCompareFunction) throws -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = true
            guard let state = device.makeDepthStencilState(descriptor: descriptor) else {
                throw BlastError.allocationFailed("depth state")
            }
            return state
        }
        sceneDepthState = try depthState(.always)
        meshDepthState = try depthState(.less)

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
        structure = solver.structure
        shells = solver.shells
        ambientPressure = scenario.atmosphere.pressure

        boxCount = min(scenario.boxes.count, Self.maxBoxes)
        let boxes = boxBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: Self.maxBoxes * 2)
        for (n, box) in scenario.boxes.prefix(boxCount).enumerated() {
            boxes[2 * n] = SIMD4(box.min, 0)
            boxes[2 * n + 1] = SIMD4(box.max, 0)
        }
        gaugeCount = min(scenario.gauges.count, BlastSolver.maxGauges)
        let gauges = gaugeBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: BlastSolver.maxGauges)
        for (n, gauge) in scenario.gauges.prefix(gaugeCount).enumerated() {
            gauges[n] = SIMD4(gauge.position, 0.35)
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

        if let structure, structure.elementCount > 0 {
            var mesh = MeshUniforms(
                eye: SIMD4(eye, 1), right: SIMD4(right, 0), up: SIMD4(up, 0), forward: SIMD4(forward, 0),
                projection: SIMD4(
                    1 / (halfHeight * aspectRatio), 1 / halfHeight, Self.nearPlane, Self.farPlane),
                lattice: SIMD4(structure.origin, structure.model.elementSize),
                dims: SIMD4(
                    Float(structure.ex), Float(structure.ey), Float(structure.ez),
                    0),
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
        if let shells, shells.elementCount + shells.beamCount > 0 {
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
            if shells.elementCount > 0 {
                sceneEncoder.drawPrimitives(
                    type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: shells.elementCount)
            }
            if shells.beamCount > 0 {
                sceneEncoder.setRenderPipelineState(beamPipeline)
                sceneEncoder.setVertexBuffer(shells.beamBuffer, offset: 0, index: 0)
                sceneEncoder.setVertexBuffer(shells.beamFlagBuffer, offset: 0, index: 2)
                sceneEncoder.setVertexBuffer(shells.beamDisplayBuffer, offset: 0, index: 3)
                sceneEncoder.drawPrimitives(
                    type: .triangle, vertexStart: 0, vertexCount: 36, instanceCount: shells.beamCount)
            }
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
