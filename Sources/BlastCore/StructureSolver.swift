import Foundation
import Metal
import simd

/// GPU explicit finite-element solver for one deformable body on a regular lattice of
/// hexahedral elements.
///
/// It runs either on its own (`advance(steps:)`, used for verification) or as substeps of a
/// `BlastSolver` step, in which case exposed element faces are loaded by the air pressure.
/// Like `BlastSolver`, it is not thread-safe.
public final class StructureSolver {
    /// The fluid fields the structure reads its loads from.
    public struct FluidBinding {
        public var state: MTLBuffer
        public var mask: MTLBuffer
        public var control: MTLBuffer
        public var grid: Grid
        public var gamma: Float
        public var ambientPressure: Float
    }

    static let stateStride = 136
    static let forceStride = 96

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let model: StructureModel
    /// Number of lattice cells along each axis; only some hold an element.
    public let ex: Int
    public let ey: Int
    public let ez: Int
    /// World position of the lattice's low corner.
    public let origin: SIMD3<Float>
    /// Number of elements the body starts with.
    public let elementCount: Int

    /// Downward acceleration in m/s².
    public var gravity: Float = 9.81
    /// Mass-proportional damping rate in 1/s.
    public var damping: Float = 0
    /// Hourglass stiffness as a multiple of the element's physical bending stiffness.
    public var hourglassCoefficient: Float = 1
    /// Fraction of the element transit time used as the stable time step.
    public var timeStepSafety: Float = 0.5
    /// Let nodes that fall to z = 0 land instead of passing through.
    public var groundContact = true
    /// Whether separate pieces of the structure, and loose debris, collide with each other.
    public var contactMode = ContactMode.afterFailure
    /// Contact spring stiffness as a fraction of the stiffest spring the time step allows.
    public var contactStiffness: Float = 0.1
    /// Contact damping as a fraction of critical.
    public var contactDamping: Float = 0.3
    public var contactFriction: Float = 0.5

    /// A pressure history applied to one face, for running the structure without the air.
    public var appliedLoad: PressureLoad? {
        didSet { writeLoadTable() }
    }

    /// Simulated time accumulated by `advance(steps:)`.
    public private(set) var time: Double = 0

    // Exposed for rendering.
    public let nodeBuffer: MTLBuffer
    public let flagBuffer: MTLBuffer
    public let stateBuffer: MTLBuffer
    /// Lattice indices of the initial elements, one `UInt32` each.
    public let instanceBuffer: MTLBuffer

    private let forceBuffer: MTLBuffer
    /// Reinforcement ratios of every lattice cell.
    private let steelBuffer: MTLBuffer
    /// Cyclic history of the reinforcement, 96 bytes per element (a placeholder without steel).
    private let barHistoryBuffer: MTLBuffer
    /// Nonlocal crushing: each element's crushing history, written in alternate substeps to one
    /// buffer while the other, from the substep before, is read. 16 bytes per lattice cell each
    /// (placeholders when crushing is local).
    private let crushBuffers: [MTLBuffer]
    /// Elements either side over which crushing is averaged; zero when it is local.
    let crushRadius: Int
    private let loadTableBuffer: MTLBuffer
    private static let maxLoadPoints = 256
    /// Indices of the nodes that belong to at least one element.
    private let nodeListBuffer: MTLBuffer
    private let nodeCount: Int
    private let placeholderBuffer: MTLBuffer
    private let elementPipeline: MTLComputePipelineState
    private let nodePipeline: MTLComputePipelineState
    private let contactClearPipeline: MTLComputePipelineState
    private let contactHashPipeline: MTLComputePipelineState
    private let contactForcePipeline: MTLComputePipelineState
    /// Contact grid over the space around the structure: a header per element-sized cell, and
    /// four node slots per cell.
    private let contactHeadBuffer: MTLBuffer
    private let contactSlotBuffer: MTLBuffer
    private let contactGridDims: SIMD3<Int>
    private let contactGridOrigin: SIMD3<Float>
    /// Contact force on each listed node.
    private let contactForceBuffer: MTLBuffer
    /// Non-zero once any element has failed.
    private let failureGateBuffer: MTLBuffer
    private var stamp: UInt32 = 0

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

        let h = model.elementSize
        let bounds = model.bounds
        let low = (bounds.min / h + 1e-3).rounded(.down)
        origin = low * h
        let extent = ((bounds.max - origin) / h - 1e-3).rounded(.up)
        ex = max(1, Int(extent.x))
        ey = max(1, Int(extent.y))
        ez = max(1, Int(extent.z))

        let library = try library ?? ShaderLibrary.make(device: device)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw BlastError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        elementPipeline = try pipeline("structureElements")
        nodePipeline = try pipeline("structureNodes")
        contactClearPipeline = try pipeline("contactClear")
        contactHashPipeline = try pipeline("contactHash")
        contactForcePipeline = try pipeline("contactForces")

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let cells = ex * ey * ez
        let nodes = (ex + 1) * (ey + 1) * (ez + 1)
        nodeBuffer = try buffer(nodes * MemoryLayout<StructureNode>.stride, "structure nodes")
        flagBuffer = try buffer(cells, "structure flags")
        stateBuffer = try buffer(cells * Self.stateStride, "structure element state")
        forceBuffer = try buffer(cells * Self.forceStride, "structure element forces")
        steelBuffer = try buffer(cells * 16, "structure reinforcement")
        barHistoryBuffer = try buffer(
            model.material.steel == nil ? 96 : cells * 96, "structure reinforcement history")
        crushRadius =
            model.material.model == .concrete ? Int((model.material.crushLength / h).rounded()) : 0
        let crushLength = crushRadius > 0 ? cells * 16 : 16
        crushBuffers = [try buffer(crushLength, "crushing, even"), try buffer(crushLength, "crushing, odd")]
        loadTableBuffer = try buffer(Self.maxLoadPoints * 8, "applied load table")
        placeholderBuffer = try buffer(64, "structure placeholder")

        // Mark the lattice cells whose centre lies inside the body.
        var active: [UInt32] = []
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex {
                    let centre = origin + (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * h
                    let index = i + ex * (j + ey * k)
                    if model.occupies(centre) {
                        flags[index] = ElementFlag.active.rawValue
                        active.append(UInt32(index))
                    } else {
                        flags[index] = ElementFlag.empty.rawValue
                    }
                }
            }
        }
        elementCount = active.count

        // Smear each reinforcement layer into the elements it overlaps, in proportion to the
        // share of the element's volume inside the layer.
        memset(steelBuffer.contents(), 0, steelBuffer.length)
        if model.material.steel != nil {
            let ratios = steelBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: cells)
            for index in active {
                let (i, j, k) = (Int(index) % ex, (Int(index) / ex) % ey, Int(index) / (ex * ey))
                let low = origin + SIMD3(Float(i), Float(j), Float(k)) * h
                var ratio = SIMD3<Float>.zero
                for layer in model.reinforcement {
                    let overlap = simd_max(
                        simd_min(low + h, layer.region.max) - simd_max(low, layer.region.min), .zero)
                    ratio += layer.ratio * (overlap.x * overlap.y * overlap.z / (h * h * h))
                }
                ratios[Int(index)] = SIMD4(ratio, 0)
            }
        }
        func indexBuffer(_ indices: [UInt32], _ label: String) throws -> MTLBuffer {
            let result = try buffer(indices.count * MemoryLayout<UInt32>.stride, label)
            indices.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress, !bytes.isEmpty {
                    result.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            return result
        }
        instanceBuffer = try indexBuffer(active, "structure instances")

        // Only nodes touched by an element need integrating.
        var used = [Bool](repeating: false, count: nodes)
        for index in active {
            let (i, j, k) = (Int(index) % ex, (Int(index) / ex) % ey, Int(index) / (ex * ey))
            for corner in 0..<8 {
                used[
                    (i + (corner & 1)) + (ex + 1)
                        * ((j + ((corner >> 1) & 1)) + (ey + 1) * (k + ((corner >> 2) & 1)))] =
                    true
            }
        }
        let nodeList = used.indices.filter { used[$0] }.map { UInt32($0) }
        nodeCount = nodeList.count
        nodeListBuffer = try indexBuffer(nodeList, "structure node list")

        // The contact grid covers the structure plus room for debris to travel, shrinking the
        // margin if that would make it unreasonably large. Its cells are offset by half an
        // element so that every undeformed node sits in the middle of its own cell.
        var margin = SIMD3<Float>(4, 4, 2)
        var gridLow = SIMD3<Float>.zero
        var gridDims = SIMD3<Int>(1, 1, 1)
        while true {
            let low = simd_max(origin - margin, SIMD3(-.infinity, -.infinity, min(origin.z, 0)))
            let lowCells = ((low - origin) / h).rounded(.down)
            gridLow = origin + (lowCells - 0.5) * h
            let high = origin + SIMD3(Float(ex), Float(ey), Float(ez)) * h + margin
            let cellsF = ((high - gridLow) / h).rounded(.up)
            gridDims = SIMD3(Int(cellsF.x), Int(cellsF.y), Int(cellsF.z))
            if gridDims.x * gridDims.y * gridDims.z <= 12_000_000 || margin.x < 0.5 { break }
            margin *= 0.7
        }
        contactGridOrigin = gridLow
        contactGridDims = gridDims
        let gridCells = gridDims.x * gridDims.y * gridDims.z
        contactHeadBuffer = try buffer(gridCells * 4, "contact grid headers")
        contactSlotBuffer = try buffer(gridCells * 16, "contact grid slots")
        memset(contactHeadBuffer.contents(), 0xFF, contactHeadBuffer.length)
        contactForceBuffer = try buffer(nodeList.count * 12, "contact forces")
        failureGateBuffer = try buffer(16, "failure gate")
        reset()
    }

    // MARK: - State

    /// Restores the undeformed, stress-free, stationary body.
    public func reset() {
        time = 0
        failureGateBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        memset(contactForceBuffer.contents(), 0, contactForceBuffer.length)
        let h = model.elementSize
        let cells = ex * ey * ez
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        for n in 0..<elementCount {
            flags[Int(instances[n])] = ElementFlag.active.rawValue
        }
        memset(stateBuffer.contents(), 0, stateBuffer.length)
        memset(forceBuffer.contents(), 0, forceBuffer.length)
        memset(barHistoryBuffer.contents(), 0, barHistoryBuffer.length)
        for crushBuffer in crushBuffers {
            memset(crushBuffer.contents(), 0, crushBuffer.length)
        }

        let cornerMass = model.material.density * h * h * h / 8
        let onGround = model.fixedBase && abs(origin.z) < 0.5 * h
        mutateNodes { nodes in
            nodes.update(repeating: StructureNode())
            for n in 0..<elementCount {
                let (i, j, k) = elementCoordinates(Int(instances[n]))
                for corner in 0..<8 {
                    let index = nodeIndex(i + (corner & 1), j + ((corner >> 1) & 1), k + ((corner >> 2) & 1))
                    nodes[index].mass += cornerMass
                    if onGround && k + ((corner >> 2) & 1) == 0 {
                        nodes[index].isFixed = true
                    }
                }
            }
        }
    }

    /// Direct access to the nodes, for setting supports and initial velocities.
    public func mutateNodes(_ body: (UnsafeMutableBufferPointer<StructureNode>) throws -> Void) rethrows {
        let count = (ex + 1) * (ey + 1) * (ez + 1)
        let pointer = nodeBuffer.contents().bindMemory(to: StructureNode.self, capacity: count)
        try body(UnsafeMutableBufferPointer(start: pointer, count: count))
    }

    @inlinable
    public func nodeIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { i + (ex + 1) * (j + (ey + 1) * k) }

    @inlinable
    public func elementIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { i + ex * (j + ey * k) }

    public func elementCoordinates(_ index: Int) -> (i: Int, j: Int, k: Int) {
        (index % ex, (index / ex) % ey, index / (ex * ey))
    }

    public func node(_ i: Int, _ j: Int, _ k: Int) -> StructureNode {
        nodeBuffer.contents().load(
            fromByteOffset: nodeIndex(i, j, k) * MemoryLayout<StructureNode>.stride, as: StructureNode.self)
    }

    /// Undeformed position of a node.
    public func referencePosition(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        origin + SIMD3(Float(i), Float(j), Float(k)) * model.elementSize
    }

    public func displacement(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        node(i, j, k).displacement
    }

    /// Current position of a node.
    public func position(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        referencePosition(i, j, k) + node(i, j, k).displacement
    }

    public func flag(_ i: Int, _ j: Int, _ k: Int) -> ElementFlag {
        ElementFlag(
            rawValue: flagBuffer.contents().load(fromByteOffset: elementIndex(i, j, k), as: UInt8.self))
            ?? .empty
    }

    /// Cauchy stress of an element in Pa, ordered xx, yy, zz, xy, yz, zx.
    public func stress(_ i: Int, _ j: Int, _ k: Int) -> [Float] {
        let base = stateBuffer.contents().advanced(by: elementIndex(i, j, k) * Self.stateStride)
        return (0..<6).map { base.load(fromByteOffset: $0 * 4, as: Float.self) }
    }

    /// Reinforcement ratios of an element along x, y and z.
    public func steelRatio(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        let value = steelBuffer.contents().load(
            fromByteOffset: elementIndex(i, j, k) * 16, as: SIMD4<Float>.self)
        return SIMD3(value.x, value.y, value.z)
    }

    /// Damage index of an element: 0 is sound, 1 is at the point of failure.
    public func damage(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateBuffer.contents().load(
            fromByteOffset: elementIndex(i, j, k) * Self.stateStride + 28, as: Float.self)
    }

    /// Largest tensile strain a concrete element has seen across any of the lattice planes.
    public func crackStrain(_ i: Int, _ j: Int, _ k: Int) -> Float {
        let base = stateBuffer.contents().advanced(by: elementIndex(i, j, k) * Self.stateStride + 80)
        return (0..<3).map { base.load(fromByteOffset: $0 * 4, as: Float.self) }.max() ?? 0
    }

    /// Net force (N) that the elements around a node exerted on it in the last step. At a
    /// restrained or prescribed node this is minus the reaction.
    public func nodalForce(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        for corner in 0..<8 {
            let (a, b, c) = (i - (corner & 1), j - ((corner >> 1) & 1), k - ((corner >> 2) & 1))
            guard a >= 0, b >= 0, c >= 0, a < ex, b < ey, c < ez, flag(a, b, c) == .active else { continue }
            let base = forceBuffer.contents().advanced(
                by: elementIndex(a, b, c) * Self.forceStride + corner * 12)
            total += SIMD3(
                base.load(as: Float.self), base.load(fromByteOffset: 4, as: Float.self),
                base.load(fromByteOffset: 8, as: Float.self))
        }
        return total
    }

    /// Von Mises: equivalent plastic strain. Concrete: largest compressive strain so far.
    public func plasticStrain(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateBuffer.contents().load(
            fromByteOffset: elementIndex(i, j, k) * Self.stateStride + 24, as: Float.self)
    }

    /// Total linear momentum of the body in kg m/s.
    public func momentum() -> SIMD3<Double> {
        var total = SIMD3<Double>.zero
        mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                total += SIMD3<Double>(node.velocity) * Double(node.mass)
            }
        }
        return total
    }

    /// Scans the mesh for damage and deflection. Costs a pass over the lattice on the CPU.
    public func summary() -> StructureSummary {
        var summary = StructureSummary()
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: ex * ey * ez)
        var maxSquared: Float = 0
        mutateNodes { nodes in
            for n in 0..<elementCount {
                let index = Int(instances[n])
                guard flags[index] == ElementFlag.active.rawValue else {
                    summary.erodedElements += 1
                    continue
                }
                summary.activeElements += 1
                let strain = stateBuffer.contents().load(
                    fromByteOffset: index * Self.stateStride + 24, as: Float.self)
                summary.maxPlasticStrain = max(summary.maxPlasticStrain, strain)
                summary.maxDamage = max(
                    summary.maxDamage,
                    stateBuffer.contents().load(fromByteOffset: index * Self.stateStride + 28, as: Float.self)
                )
                let (i, j, k) = elementCoordinates(index)
                for corner in 0..<8 {
                    let (a, b, c) = (i + (corner & 1), j + ((corner >> 1) & 1), k + ((corner >> 2) & 1))
                    let squared = simd_length_squared(nodes[nodeIndex(a, b, c)].displacement)
                    if !squared.isFinite { summary.hasBlownUp = true }
                    maxSquared = max(maxSquared, squared)
                }
            }
        }
        summary.maxDisplacement = maxSquared.squareRoot()
        return summary
    }

    public var memoryFootprint: Int {
        [
            nodeBuffer, flagBuffer, stateBuffer, forceBuffer, steelBuffer, barHistoryBuffer, instanceBuffer,
            nodeListBuffer,
            contactHeadBuffer, contactSlotBuffer, contactForceBuffer,
        ].reduce(0) { $0 + $1.length }
    }

    /// True once any element has failed since the last reset.
    public var hasFailed: Bool { failureGateBuffer.contents().load(as: UInt32.self) != 0 }

    /// Removes elements by hand, as if they had reached their failure strain.
    public func erode(where shouldErode: (_ i: Int, _ j: Int, _ k: Int) -> Bool) {
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: ex * ey * ez)
        var any = false
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex where flags[elementIndex(i, j, k)] == ElementFlag.active.rawValue {
                    if shouldErode(i, j, k) {
                        flags[elementIndex(i, j, k)] = ElementFlag.eroded.rawValue
                        any = true
                    }
                }
            }
        }
        if any { failureGateBuffer.contents().storeBytes(of: 1, as: UInt32.self) }
    }

    private func writeLoadTable() {
        guard let appliedLoad else { return }
        let table = loadTableBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: Self.maxLoadPoints)
        for (n, point) in appliedLoad.history.prefix(Self.maxLoadPoints).enumerated() {
            table[n] = point
        }
    }

    // MARK: - Stepping

    /// Largest stable time step in seconds.
    public var criticalTimeStep: Float {
        timeStepSafety * model.elementSize / model.material.dilatationalWaveSpeed
    }

    /// Substeps to encode per fluid step so that a fluid step of `fluidStepBound` seconds can be
    /// covered within the structural stability limit.
    public func substeps(forFluidStepBound fluidStepBound: Float) -> Int {
        min(max(Int((fluidStepBound / criticalTimeStep).rounded(.up)), 1), 96)
    }

    /// Encodes `count` substeps. With a fluid binding, the substeps share out the fluid's current
    /// time step and apply blast loads; without one, each advances by `criticalTimeStep`.
    public func encodeSubsteps(_ encoder: MTLComputeCommandEncoder, count: Int, fluid: FluidBinding?) {
        var uniforms = makeUniforms(fluid: fluid)
        guard elementCount > 0 else { return }
        // One SIMD group per threadgroup. The element kernel needs many registers, and groups of
        // the largest allowed size (1,024 threads) let too few run at once on each GPU core: they
        // are a third slower than groups of 32 to 512, of which 32 is the fastest.
        let group = MTLSize(width: elementPipeline.threadExecutionWidth, height: 1, depth: 1)

        // Until something has failed there is nothing to collide, so the contact kernels are
        // left out; they join in from the first batch encoded after a failure.
        let encodeContact = contactMode == .always || (contactMode == .afterFailure && hasFailed)

        for substep in 0..<count {
            uniforms.substep = UInt32(substep)
            uniforms.loadTime = Float(time + Double(substep) * Double(criticalTimeStep))
            encoder.setComputePipelineState(elementPipeline)
            encoder.setBuffer(stateBuffer, offset: 0, index: 0)
            encoder.setBuffer(forceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 3)
            encoder.setBuffer(fluid?.state ?? placeholderBuffer, offset: 0, index: 4)
            encoder.setBuffer(fluid?.mask ?? placeholderBuffer, offset: 0, index: 5)
            encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 6)
            encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 7)
            encoder.setBuffer(instanceBuffer, offset: 0, index: 8)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 9)
            encoder.setBuffer(steelBuffer, offset: 0, index: 10)
            encoder.setBuffer(loadTableBuffer, offset: 0, index: 11)
            encoder.setBuffer(barHistoryBuffer, offset: 0, index: 12)
            encoder.setBuffer(crushBuffers[substep % 2], offset: 0, index: 13)
            encoder.setBuffer(crushBuffers[1 - substep % 2], offset: 0, index: 14)
            encoder.dispatchThreads(
                MTLSize(width: elementCount, height: 1, depth: 1), threadsPerThreadgroup: group)

            if encodeContact {
                // The stamp distinguishes this substep's grid entries from stale ones.
                stamp = stamp % 0x1FFF_FFF0 + 1
                uniforms.stamp = stamp
                let nodes = MTLSize(width: nodeCount, height: 1, depth: 1)
                for pipeline in [contactClearPipeline, contactHashPipeline, contactForcePipeline] {
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(nodeListBuffer, offset: 0, index: 0)
                    encoder.setBuffer(nodeBuffer, offset: 0, index: 1)
                    encoder.setBuffer(contactHeadBuffer, offset: 0, index: 2)
                    encoder.setBuffer(failureGateBuffer, offset: 0, index: 3)
                    encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 4)
                    encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 5)
                    if pipeline === contactForcePipeline {
                        encoder.setBuffer(contactForceBuffer, offset: 0, index: 7)
                        encoder.setBuffer(contactSlotBuffer, offset: 0, index: 8)
                    } else {
                        encoder.setBuffer(contactSlotBuffer, offset: 0, index: 6)
                    }
                    encoder.dispatchThreads(nodes, threadsPerThreadgroup: group)
                }
            }

            encoder.setComputePipelineState(nodePipeline)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(forceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 4)
            encoder.setBuffer(nodeListBuffer, offset: 0, index: 5)
            encoder.setBuffer(contactForceBuffer, offset: 0, index: 6)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 7)
            encoder.dispatchThreads(
                MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
        }
    }

    /// Advances the body on its own by `steps` steps of `criticalTimeStep`, blocking until done.
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

    private func makeUniforms(fluid: FluidBinding?) -> StructureUniforms {
        let material = model.material
        let h = model.elementSize
        var uniforms = StructureUniforms(
            ex: UInt32(ex), ey: UInt32(ey), ez: UInt32(ez),
            h: h, originX: origin.x, originY: origin.y, originZ: origin.z,
            density: material.density,
            lambda: material.lameLambda,
            mu: material.shearModulus,
            yieldStress: material.yieldStress,
            hardening: material.hardeningModulus,
            failureStrain: material.failureStrain,
            // Bending stiffness of a cube in an hourglass mode: E h / 48 per unit modal amplitude.
            hourglassStiffness: hourglassCoefficient * material.youngsModulus * h / 48,
            bulkLinear: 0.06,
            bulkQuadratic: 1.5,
            soundSpeed: material.dilatationalWaveSpeed,
            criticalStep: criticalTimeStep,
            gravity: gravity,
            damping: damping,
            minVolumeRatio: 0.25,
            groundFriction: groundContact ? 8 : -1,
            contactMode: contactMode.rawValue,
            gridNx: UInt32(contactGridDims.x), gridNy: UInt32(contactGridDims.y),
            gridNz: UInt32(contactGridDims.z),
            gridOriginX: contactGridOrigin.x, gridOriginY: contactGridOrigin.y,
            gridOriginZ: contactGridOrigin.z,
            contactStiffness: contactStiffness / (criticalTimeStep * criticalTimeStep),
            contactDamping: contactDamping,
            contactFriction: contactFriction)
        uniforms.youngsModulus = material.youngsModulus
        if material.model == .concrete {
            // Strengths at blast strain rates; softening scaled to the element so that the energy
            // per unit area of crack or crush band is the material's, whatever the mesh.
            let fc = material.compressiveStrength * material.concreteRateFactor
            let ft = material.tensileStrength * material.concreteRateFactor
            let onset = ft / material.youngsModulus
            let peak = 2 * fc / material.youngsModulus
            let end = peak + 2 * material.crushingEnergy / (max(h, material.crushBand) * 0.8 * fc)
            uniforms.materialModel = MaterialModel.concrete.rawValue
            uniforms.compressiveStrength = fc
            uniforms.tensileStrength = ft
            uniforms.crackOnset = onset
            let band = material.steel == nil ? h : max(h, material.crackSpacing)
            uniforms.crackSoftening = max(material.fractureEnergy / (band * ft) - onset / 2, onset / 2)
            // Aggregate interlock: v = 0.18 sqrt(fc) / (0.31 + 24 w / (a + 16)), in MPa and mm.
            uniforms.crackBand = band
            uniforms.interlockStrength = 0.18e6 * (fc / 1e6).squareRoot()
            uniforms.interlockWidthScale = 24_000 / (material.aggregateSize * 1000 + 16)
            uniforms.crackResidual = material.crackResidual
            uniforms.crushRadius = UInt32(crushRadius)
            uniforms.crushPeak = peak
            uniforms.crushEnd = end
            uniforms.erosionStrain = min(material.erosionOpening / h, 0.5)
            // Removed once crushed to twice the strain at which softening ends.
            uniforms.crushErosion = 1
            uniforms.confinement = material.confinementCoefficient
            if let steel = material.steel {
                // The fixed rate factor is applied at yield and fades out towards ultimate
                // strength, which is barely rate-sensitive.
                let curve = steel.curve
                let first = curve[0].y
                let top = curve.map(\.y).max() ?? first
                uniforms.steelModulus = steel.youngsModulus
                // Yield asymptotes for cyclic loading: the secant from yield to ultimate strength.
                if let peak = curve.max(by: { $0.y < $1.y }), peak.x > 0, peak.y > first {
                    uniforms.steelHardeningRatio = (peak.y - first) / (peak.x * steel.youngsModulus)
                }
                uniforms.steelPoints = UInt32(curve.count)
                withUnsafeMutableBytes(of: &uniforms.steelStrain) { strains in
                    withUnsafeMutableBytes(of: &uniforms.steelStress) { stresses in
                        for (n, point) in curve.enumerated() {
                            let along = top > first ? (point.y - first) / (top - first) : 0
                            let factor = max(1 + (material.steelRateFactor - 1) * (1 - along), 1)
                            strains.storeBytes(of: point.x, toByteOffset: n * 4, as: Float.self)
                            stresses.storeBytes(of: point.y * factor, toByteOffset: n * 4, as: Float.self)
                        }
                    }
                }
            }
            // Time constant of the running averages of strain rate and confinement: 50 steps.
            uniforms.rateFilter = 1 / (50 * criticalTimeStep)
            if material.rateDependent {
                let megapascals = material.compressiveStrength / 1e6
                uniforms.concreteRateCompression = 1 / (5 + 9 * megapascals / 10)
                uniforms.concreteRateTension = 1 / (1 + 8 * megapascals / 10)
                if let steel = material.steel {
                    uniforms.steelRateYield = 0.074 - 0.040 * steel.yieldStress / 414e6
                    uniforms.steelRateUltimate = 0.019 - 0.009 * steel.yieldStress / 414e6
                }
            }
        }
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
