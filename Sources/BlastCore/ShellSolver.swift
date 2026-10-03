import Foundation
import Metal
import simd

/// Layout matches `ShellUniforms` in `Shell.metal`.
struct ShellUniforms {
    var elementCount: UInt32 = 0
    var nodeCount: UInt32 = 0
    var layers: UInt32 = 0
    var barSlots: UInt32 = 0
    var substep: UInt32 = 0
    var criticalStep: Float = 0
    var fixedStep: Float = 0
    var gravity: Float = 0
    var damping: Float = 0
    var ambientPressure: Float = 0
    var fluidGamma: Float = 0
    var fluidCell: Float = 0
    var fluidNx: UInt32 = 0
    var fluidNy: UInt32 = 0
    var fluidNz: UInt32 = 0
    var coupled: UInt32 = 0
    var groundFriction: Float = -1
    var rateFilter: Float = 0
    var loadTime: Float = 0
    var loadCount: UInt32 = 0
    var loadFace: UInt32 = 0
    var shearFactor: Float = 5.0 / 6.0
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

/// Layout matches `ShellElement` in `Shell.metal`.
struct ShellElementData {
    var n0: UInt32
    var n1: UInt32
    var n2: UInt32
    var n3: UInt32
    var axis: UInt32
    var material: UInt32
    var barCount: UInt32
    var thickness: Float
    var a: Float
    var b: Float
}

/// Node of a shell mesh as stored on the GPU. Layout matches `ShellNode` in `Shell.metal`.
public struct ShellNode: Sendable {
    /// Displacement from the node's reference position, in metres.
    public var ux: Float = 0
    public var uy: Float = 0
    public var uz: Float = 0
    public var mass: Float = 0
    public var vx: Float = 0
    public var vy: Float = 0
    public var vz: Float = 0
    /// Bits 0-2 hold the node still along x, y, z; bit 3 keeps its motion as set; bit 4 lets it
    /// rise but not fall; bit 6 holds its rotation.
    public var flags: UInt32 = 0
    /// Angular velocity, in radians per second.
    public var wx: Float = 0
    public var wy: Float = 0
    public var wz: Float = 0
    public var inertia: Float = 0
    /// Rotation from the reference orientation, as a unit quaternion.
    public var qx: Float = 0
    public var qy: Float = 0
    public var qz: Float = 0
    public var qw: Float = 1

    public init() {}

    public var displacement: SIMD3<Float> {
        get { SIMD3(ux, uy, uz) }
        set { (ux, uy, uz) = (newValue.x, newValue.y, newValue.z) }
    }

    public var velocity: SIMD3<Float> {
        get { SIMD3(vx, vy, vz) }
        set { (vx, vy, vz) = (newValue.x, newValue.y, newValue.z) }
    }

    public var spin: SIMD3<Float> {
        get { SIMD3(wx, wy, wz) }
        set { (wx, wy, wz) = (newValue.x, newValue.y, newValue.z) }
    }

    public var rotation: simd_quatf {
        get { simd_quatf(ix: qx, iy: qy, iz: qz, r: qw) }
        set { (qx, qy, qz, qw) = (newValue.imag.x, newValue.imag.y, newValue.imag.z, newValue.real) }
    }

    /// Held still in every direction, and against rotation: a clamped edge.
    public var isClamped: Bool {
        get { flags & 71 == 71 }
        set { flags = newValue ? flags | 71 : flags & ~71 }
    }

    /// Holds the node still along the chosen axes only.
    public mutating func restrain(x: Bool = false, y: Bool = false, z: Bool = false, rotation: Bool = false) {
        flags |= (x ? 1 : 0) | (y ? 2 : 0) | (z ? 4 : 0) | (rotation ? 64 : 0)
    }

    /// Moves at its current velocity and spin regardless of the forces on it.
    public var isPrescribed: Bool {
        get { flags & 8 != 0 }
        set { flags = newValue ? flags | 8 : flags & ~8 }
    }

    /// Rests on a support that pushes up but does not hold down.
    public var restsOnSupport: Bool {
        get { flags & 16 != 0 }
        set { flags = newValue ? flags | 16 : flags & ~16 }
    }
}

/// Explicit dynamics of a structure of walls and slabs meshed with shell elements.
///
/// Each wall or slab becomes a plate of four-node shells on its midsurface (see `ShellMesh`),
/// with `model.shellLayers` layers through the thickness and its bars as layers of their own.
/// The materials are those of the solid elements, in plane stress.
public final class ShellSolver {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let model: StructureModel
    public let materials: [StructureMaterial]
    public let elementCount: Int
    public let nodeCount: Int
    public let layers: Int
    /// Bar layers stored per element.
    let barSlots: Int
    let mesh: ShellMesh

    /// Acceleration of gravity in m/s², acting along -z.
    public var gravity: Float = 9.81
    /// Mass-proportional damping rate in 1/s.
    public var damping: Float = 0
    /// Fraction of the element transit time used as the stable time step.
    public var timeStepSafety: Float = 0.5
    /// Let nodes that fall to z = 0 land instead of passing through.
    public var groundContact = true
    /// A pressure history applied to one face, for running the structure without the air.
    public var appliedLoad: PressureLoad? {
        didSet { writeLoadTable() }
    }
    /// Simulated time accumulated by `advance(steps:)`.
    public private(set) var time: Double = 0

    public let nodeBuffer: MTLBuffer
    /// Reference position of every node, as four floats.
    public let referenceBuffer: MTLBuffer
    let elementBuffer: MTLBuffer
    public let flagBuffer: MTLBuffer
    /// Damage of each element, 0 (sound) to 1 (failing), for display.
    public let displayBuffer: MTLBuffer
    private let layerBuffer: MTLBuffer
    private let barLayoutBuffer: MTLBuffer
    private let barBuffer: MTLBuffer
    private let forceBuffer: MTLBuffer
    private let neighbourBuffer: MTLBuffer
    /// Each bar layer's plastic strain per element, written in alternate substeps to one buffer
    /// while the other, from the substep before, is read, so that rupture can be judged over a
    /// debonded length.
    private let barPlasticBuffers: [MTLBuffer]
    private let incidenceStartBuffer: MTLBuffer
    private let incidenceBuffer: MTLBuffer
    private let loadTableBuffer: MTLBuffer
    private let failureGateBuffer: MTLBuffer
    private let placeholderBuffer: MTLBuffer
    private let elementPipeline: MTLComputePipelineState
    private let nodePipeline: MTLComputePipelineState
    private static let maxLoadPoints = 256
    /// Gauss-Legendre points and weights through the thickness, from -1 to 1.
    private let thicknessRule: [SIMD2<Float>]
    private static let layerStride = 32
    private static let barStride = 36

    public init(
        device: MTLDevice, commandQueue: MTLCommandQueue? = nil, library: MTLLibrary? = nil,
        model: StructureModel
    ) throws {
        self.device = device
        self.model = model
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw BlastError.allocationFailed("command queue")
        }
        self.commandQueue = queue
        materials = model.materials
        guard materials.count <= StructureModel.maxMaterials else {
            throw BlastError.tooManyMaterials(materials.count)
        }
        mesh = try ShellMesh(model: model)
        elementCount = mesh.elements.count
        nodeCount = mesh.positions.count
        layers = max(1, model.shellLayers)
        barSlots = max(1, mesh.elements.map(\.bars.count).max() ?? 0)
        thicknessRule = Self.gaussLegendre(layers)

        let library = try library ?? ShaderLibrary.make(device: device)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw BlastError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        elementPipeline = try pipeline("shellElements")
        nodePipeline = try pipeline("shellNodes")

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let elements = max(elementCount, 1)
        let nodes = max(nodeCount, 1)
        nodeBuffer = try buffer(nodes * MemoryLayout<ShellNode>.stride, "shell nodes")
        referenceBuffer = try buffer(nodes * 16, "shell node positions")
        elementBuffer = try buffer(elements * MemoryLayout<ShellElementData>.stride, "shell elements")
        flagBuffer = try buffer(elements, "shell flags")
        displayBuffer = try buffer(elements * 4, "shell damage")
        layerBuffer = try buffer(elements * 4 * layers * Self.layerStride, "shell layers")
        barLayoutBuffer = try buffer(elements * barSlots * 16, "shell bar layout")
        let hasBars = mesh.elements.contains { !$0.bars.isEmpty }
        barBuffer = try buffer(hasBars ? elements * 4 * barSlots * 2 * Self.barStride : 64, "shell bars")
        forceBuffer = try buffer(elements * 96, "shell forces")
        neighbourBuffer = try buffer(elements * 16, "shell neighbours")
        let neighbours = neighbourBuffer.contents().bindMemory(to: SIMD4<Int32>.self, capacity: elements)
        for (e, element) in mesh.elements.enumerated() { neighbours[e] = element.neighbours }
        barPlasticBuffers = [
            try buffer(hasBars ? elements * barSlots * 2 * 4 : 16, "shell bar plastic, even"),
            try buffer(hasBars ? elements * barSlots * 2 * 4 : 16, "shell bar plastic, odd"),
        ]
        loadTableBuffer = try buffer(Self.maxLoadPoints * 8, "applied load table")
        failureGateBuffer = try buffer(16, "failure gate")
        placeholderBuffer = try buffer(64, "shell placeholder")

        let references = referenceBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: nodes)
        for (n, position) in mesh.positions.enumerated() {
            references[n] = SIMD4(position, 0)
        }
        let data = elementBuffer.contents().bindMemory(to: ShellElementData.self, capacity: elements)
        let layout = barLayoutBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: elements * barSlots)
        var incidence = [[UInt32]](repeating: [], count: nodes)
        for (e, element) in mesh.elements.enumerated() {
            data[e] = ShellElementData(
                n0: element.nodes.x, n1: element.nodes.y, n2: element.nodes.z, n3: element.nodes.w,
                axis: UInt32(element.axis), material: UInt32(element.material),
                barCount: UInt32(element.bars.count),
                thickness: element.thickness, a: element.size.x, b: element.size.y)
            for s in 0..<barSlots {
                layout[e * barSlots + s] = s < element.bars.count ? SIMD4(element.bars[s], 0) : .zero
            }
            for corner in 0..<4 {
                incidence[Int(element.nodes[corner])].append(UInt32(e * 4 + corner))
            }
        }
        var starts: [UInt32] = [0]
        var entries: [UInt32] = []
        for list in incidence {
            entries += list
            starts.append(UInt32(entries.count))
        }
        incidenceStartBuffer = try buffer(starts.count * 4, "shell incidence starts")
        incidenceBuffer = try buffer(entries.count * 4, "shell incidence")
        starts.withUnsafeBytes {
            incidenceStartBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        entries.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress, !bytes.isEmpty {
                incidenceBuffer.contents().copyMemory(from: base, byteCount: bytes.count)
            }
        }
        reset()
    }

    // MARK: - State

    /// Restores the undeformed, stress-free, stationary structure.
    public func reset() {
        time = 0
        failureGateBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        memset(flagBuffer.contents(), Int32(ElementFlag.active.rawValue), flagBuffer.length)
        for buffer in [layerBuffer, barBuffer, forceBuffer, displayBuffer] + barPlasticBuffers {
            memset(buffer.contents(), 0, buffer.length)
        }
        mutateNodes { nodes in
            nodes.update(repeating: ShellNode())
            for element in mesh.elements {
                let density = materials[element.material].density
                let area = element.size.x * element.size.y
                let share = density * area * element.thickness / 4
                // Rotational inertia is scaled up from the physical t^2 / 12 per unit mass, as is
                // usual in explicit shells, so that rotation never limits the time step; it
                // barely changes the response of members many elements long.
                let radius = (element.thickness * element.thickness + area) / 12
                for corner in 0..<4 {
                    let n = Int(element.nodes[corner])
                    nodes[n].mass += share
                    nodes[n].inertia += share * radius
                }
            }
            if model.fixedBase {
                for n in nodes.indices where abs(mesh.positions[n].z) < 1e-4 {
                    nodes[n].isClamped = true
                }
            }
        }
    }

    /// Direct access to the nodes, for setting supports and initial velocities.
    public func mutateNodes(_ body: (UnsafeMutableBufferPointer<ShellNode>) throws -> Void) rethrows {
        let pointer = nodeBuffer.contents().bindMemory(to: ShellNode.self, capacity: max(nodeCount, 1))
        try body(UnsafeMutableBufferPointer(start: pointer, count: nodeCount))
    }

    public func node(_ index: Int) -> ShellNode {
        nodeBuffer.contents().load(fromByteOffset: index * MemoryLayout<ShellNode>.stride, as: ShellNode.self)
    }

    /// Reference positions of all nodes.
    public var referencePositions: [SIMD3<Float>] { mesh.positions }

    /// The node nearest `point` in the reference configuration.
    public func nearestNode(to point: SIMD3<Float>) -> Int {
        mesh.positions.indices.min {
            simd_distance_squared(mesh.positions[$0], point)
                < simd_distance_squared(mesh.positions[$1], point)
        } ?? 0
    }

    /// Indices of the nodes whose reference position satisfies `condition`.
    public func nodes(where condition: (SIMD3<Float>) -> Bool) -> [Int] {
        mesh.positions.indices.filter { condition(mesh.positions[$0]) }
    }

    public func position(_ index: Int) -> SIMD3<Float> { mesh.positions[index] + node(index).displacement }

    public func flag(_ element: Int) -> ElementFlag {
        ElementFlag(rawValue: flagBuffer.contents().load(fromByteOffset: element, as: UInt8.self)) ?? .eroded
    }

    /// Net force (N) that the elements around a node exerted on it in the last step. At a
    /// restrained or prescribed node this is minus the reaction.
    public func nodalForce(_ index: Int) -> SIMD3<Float> {
        let starts = incidenceStartBuffer.contents().bindMemory(to: UInt32.self, capacity: nodeCount + 1)
        let entries = incidenceBuffer.contents().bindMemory(to: UInt32.self, capacity: Int(starts[nodeCount]))
        var total = SIMD3<Float>.zero
        for i in Int(starts[index])..<Int(starts[index + 1]) {
            let element = Int(entries[i] >> 2)
            let corner = Int(entries[i] & 3)
            guard flag(element) == .active else { continue }
            let base = forceBuffer.contents().advanced(by: element * 96 + corner * 12)
            total += SIMD3(
                base.load(as: Float.self), base.load(fromByteOffset: 4, as: Float.self),
                base.load(fromByteOffset: 8, as: Float.self))
        }
        return total
    }

    public var hasFailed: Bool { failureGateBuffer.contents().load(as: UInt32.self) != 0 }

    /// Total linear momentum in kg m/s.
    public func momentum() -> SIMD3<Double> {
        var total = SIMD3<Double>.zero
        mutateNodes { nodes in
            for node in nodes { total += SIMD3<Double>(node.velocity) * Double(node.mass) }
        }
        return total
    }

    /// Kinetic energy of translation and rotation, in joules.
    public func kineticEnergy() -> Double {
        var total = 0.0
        mutateNodes { nodes in
            for node in nodes {
                total += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                total += 0.5 * Double(node.inertia) * Double(simd_length_squared(node.spin))
            }
        }
        return total
    }

    public func summary() -> StructureSummary {
        var summary = StructureSummary()
        let damage = displayBuffer.contents().bindMemory(to: Float.self, capacity: max(elementCount, 1))
        var attached = [Bool](repeating: false, count: nodeCount)
        for (e, element) in mesh.elements.enumerated() {
            if flag(e) == .active {
                summary.activeElements += 1
                summary.maxDamage = max(summary.maxDamage, damage[e])
                for corner in 0..<4 { attached[Int(element.nodes[corner])] = true }
            } else {
                summary.erodedElements += 1
            }
        }
        var largest: Float = 0
        mutateNodes { nodes in
            for (n, node) in nodes.enumerated() where attached[n] {
                let squared = simd_length_squared(node.displacement)
                if !squared.isFinite { summary.hasBlownUp = true }
                largest = max(largest, squared)
            }
        }
        summary.maxDisplacement = largest.squareRoot()
        return summary
    }

    public var memoryFootprint: Int {
        [
            nodeBuffer, referenceBuffer, elementBuffer, flagBuffer, displayBuffer, layerBuffer,
            barLayoutBuffer,
            barBuffer, forceBuffer, incidenceStartBuffer, incidenceBuffer,
        ].reduce(0) { $0 + $1.length }
    }

    private func writeLoadTable() {
        guard let appliedLoad else { return }
        let table = loadTableBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: Self.maxLoadPoints)
        for (n, point) in appliedLoad.history.prefix(Self.maxLoadPoints).enumerated() {
            table[n] = point
        }
    }

    // MARK: - Stepping

    /// Largest stable time step in seconds: the time a compression wave in the plane takes to
    /// cross the smallest element, times `timeStepSafety`.
    public var criticalTimeStep: Float {
        var step = Float.infinity
        for element in mesh.elements {
            let speed = materials[element.material].plateWaveSpeed
            step = min(step, min(element.size.x, element.size.y) / speed)
        }
        return timeStepSafety * (step.isFinite ? step : 1e-4)
    }

    /// Encodes `count` substeps. With a fluid binding, the substeps share out the fluid's current
    /// time step and apply blast loads; without one, each advances by `criticalTimeStep`.
    public func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: StructureSolver.FluidBinding?
    ) {
        guard elementCount > 0 else { return }
        var uniforms = makeUniforms(fluid: fluid)
        var parameters = materials.map {
            StructureSolver.parameters(for: $0, elementSize: model.elementSize)
        }
        let group = MTLSize(width: elementPipeline.threadExecutionWidth, height: 1, depth: 1)
        for substep in 0..<count {
            uniforms.substep = UInt32(substep)
            uniforms.loadTime = Float(time + Double(substep) * Double(criticalTimeStep))
            encoder.setComputePipelineState(elementPipeline)
            encoder.setBuffer(layerBuffer, offset: 0, index: 0)
            encoder.setBuffer(forceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 3)
            encoder.setBuffer(referenceBuffer, offset: 0, index: 4)
            encoder.setBuffer(elementBuffer, offset: 0, index: 5)
            encoder.setBuffer(barLayoutBuffer, offset: 0, index: 6)
            encoder.setBuffer(barBuffer, offset: 0, index: 7)
            encoder.setBytes(
                &parameters, length: parameters.count * MemoryLayout<MaterialParameters>.stride, index: 8)
            encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 9)
            encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 10)
            encoder.setBuffer(fluid?.state ?? placeholderBuffer, offset: 0, index: 11)
            encoder.setBuffer(fluid?.mask ?? placeholderBuffer, offset: 0, index: 12)
            encoder.setBuffer(loadTableBuffer, offset: 0, index: 13)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 14)
            encoder.setBuffer(displayBuffer, offset: 0, index: 15)
            var rule = thicknessRule
            encoder.setBytes(&rule, length: rule.count * MemoryLayout<SIMD2<Float>>.stride, index: 16)
            encoder.setBuffer(neighbourBuffer, offset: 0, index: 17)
            encoder.setBuffer(barPlasticBuffers[substep % 2], offset: 0, index: 18)
            encoder.setBuffer(barPlasticBuffers[1 - substep % 2], offset: 0, index: 19)
            encoder.dispatchThreads(
                MTLSize(width: elementCount, height: 1, depth: 1), threadsPerThreadgroup: group)

            encoder.setComputePipelineState(nodePipeline)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(forceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(incidenceStartBuffer, offset: 0, index: 3)
            encoder.setBuffer(incidenceBuffer, offset: 0, index: 4)
            encoder.setBuffer(referenceBuffer, offset: 0, index: 5)
            encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 6)
            encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 7)
            encoder.dispatchThreads(
                MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
        }
    }

    /// Advances the structure on its own by `steps` steps of `criticalTimeStep`, blocking until done.
    public func advance(steps: Int) {
        var remaining = steps
        while remaining > 0 {
            let count = min(remaining, 2000)
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return }
            encodeSubsteps(encoder, count: count, fluid: nil)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            time += Double(count) * Double(criticalTimeStep)
            remaining -= count
        }
    }

    /// Points and weights of the n-point Gauss-Legendre rule on [-1, 1], by Newton's method on
    /// the Legendre polynomial.
    static func gaussLegendre(_ n: Int) -> [SIMD2<Float>] {
        var rule: [SIMD2<Float>] = []
        for i in 0..<n {
            var x = cos(Double.pi * (Double(i) + 0.75) / (Double(n) + 0.5))
            var derivative = 1.0
            for _ in 0..<100 {
                var p0 = 1.0
                var p1 = x
                for k in 2...max(n, 2) where n >= 2 {
                    let p2 = ((2 * Double(k) - 1) * x * p1 - (Double(k) - 1) * p0) / Double(k)
                    p0 = p1
                    p1 = p2
                }
                if n == 1 {
                    p1 = x
                    p0 = 1
                }
                derivative = Double(n) * (x * p1 - p0) / (x * x - 1)
                let step = p1 / derivative
                x -= step
                if abs(step) < 1e-15 { break }
            }
            rule.append(SIMD2(Float(x), Float(2 / ((1 - x * x) * derivative * derivative))))
        }
        return rule.sorted { $0.x < $1.x }
    }

    private func makeUniforms(fluid: StructureSolver.FluidBinding?) -> ShellUniforms {
        var uniforms = ShellUniforms()
        uniforms.elementCount = UInt32(elementCount)
        uniforms.nodeCount = UInt32(nodeCount)
        uniforms.layers = UInt32(layers)
        uniforms.barSlots = UInt32(barSlots)
        uniforms.criticalStep = criticalTimeStep
        uniforms.gravity = gravity
        uniforms.damping = damping
        uniforms.groundFriction = groundContact ? 8 : -1
        uniforms.rateFilter = 1 / (50 * criticalTimeStep)
        if let appliedLoad, fluid == nil {
            uniforms.loadCount = UInt32(min(appliedLoad.history.count, Self.maxLoadPoints))
            uniforms.loadFace = UInt32(2 * appliedLoad.axis + (appliedLoad.positiveSide ? 1 : 0))
        }
        if let fluid {
            uniforms.coupled = 1
            uniforms.ambientPressure = fluid.ambientPressure
            uniforms.fluidGamma = fluid.gamma
            uniforms.fluidCell = fluid.grid.cellSize
            uniforms.fluidNx = UInt32(fluid.grid.nx)
            uniforms.fluidNy = UInt32(fluid.grid.ny)
            uniforms.fluidNz = UInt32(fluid.grid.nz)
        } else {
            uniforms.fixedStep = criticalTimeStep
        }
        return uniforms
    }
}
