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
        /// The air's equation of state.
        public var airModel: AirModel = .idealGas
        /// Where loose debris returns to the air what it takes from it: four `Int32` per air cell
        /// of `exchangeRegion`. Without it, debris is not loaded by the air.
        public var exchange: MTLBuffer?
        /// The frontal area of the loose debris in each air cell of `exchangeRegion`, one `Int32`
        /// each, summed before the substeps and cleared after.
        public var debrisArea: MTLBuffer?
        /// The parent collected every body's area before advancing any body.
        var debrisAreasPrepared = false
        public var exchangeRegion: (origin: SIMD3<Int>, dims: SIMD3<Int>)?
        var couplingMap: MTLBuffer?
        var couplingMapCount: UInt32 = 0
        /// Where the air is refined: which block each patch refines, the patches' fine cells,
        /// the ratio and the grid of blocks' size. Faces then read the fine cells beside them.
        var refinement:
            (patchOfTile: MTLBuffer, fine: MTLBuffer, mask: MTLBuffer, ratio: Int, blocks: SIMD3<Int>)?
        /// Where the air has a second level: its cells along a coarse cell's edge, its grid of
        /// blocks, and where its patches' list and cells start in the first level's buffers.
        var deepRefinement: (ratio: Int, blocks: SIMD3<Int>, patchOffset: Int, cellOffset: Int)?
    }

    /// Bytes of state per element (`ElementState` in Structure.metal).
    public static let stateStride = 192
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
    /// The way gravity pulls, down unless turned (to turn a whole problem against the lattice); a
    /// footing's own weight always acts down.
    public var gravityDirection = SIMD3<Float>(0, 0, -1)
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

    /// Let the air push loose debris (nodes no longer attached to any intact element) by its
    /// pressure gradient and drag, when coupled to the air.
    public var debrisDrag = true

    /// A pressure history applied to one face, for running the structure without the air.
    public var appliedLoad: PressureLoad? {
        didSet { writeLoadTable() }
    }

    /// Simulated time accumulated by `advance(steps:)`.
    public internal(set) var time: Double = 0

    // Exposed for rendering. Element data (state, forces, reinforcement and their histories) is
    // stored compactly, one entry per element the body started with, in the order of
    // `instanceBuffer`, and nodes likewise, one per node of those elements in lattice order;
    // flags cover the whole lattice.
    public let nodeBuffer: MTLBuffer
    /// For every lattice node, its compact index in `nodeBuffer`, or `UInt32.max` where there is
    /// none.
    public let nodeMapBuffer: MTLBuffer
    public let flagBuffer: MTLBuffer
    public let stateBuffer: MTLBuffer
    /// Lattice indices of the initial elements, one `UInt32` each.
    public let instanceBuffer: MTLBuffer
    /// For every lattice cell, its element's compact index, or `UInt32.max` where there is none.
    private let cellElementBuffer: MTLBuffer

    private let forceBuffer: MTLBuffer
    /// Reinforcement ratios of every element.
    private let steelBuffer: MTLBuffer
    /// Cyclic history of the reinforcement, 96 bytes per element (a placeholder without steel).
    private let barHistoryBuffer: MTLBuffer
    /// Nonlocal crushing: each element's crushing history, written in alternate substeps to one
    /// buffer while the other, from the substep before, is read. 16 bytes per element each
    /// (placeholders when crushing is local).
    private let crushBuffers: [MTLBuffer]
    /// Bar plastic strains along each axis, written in alternate substeps like `crushBuffers`, so
    /// that rupture can be judged over a debonded length.
    private let barPlasticBuffers: [MTLBuffer]
    /// Each element's stretching rate along the lattice axes, for bars that take their rate
    /// over their debonded length (`StructureModel.barRateAlongBars`), even and odd substeps.
    private let barRateBuffers: [MTLBuffer]
    /// The structure's materials, `model.material` first; each element names one.
    public let materials: [StructureMaterial]
    /// Per material, the most steel any of its elements holds along one direction (the largest
    /// lattice ratio plus any inclined bars), for the time step.
    private var densestSteel: [Float] = []
    /// The lattice axes the body has bars along somewhere, as bits 0 to 2.
    private var barAxes: UInt32 = 0
    /// Whether each material's masonry is meshed as units and mortar joints.
    private let jointed: [Bool]
    /// Index into `materials` of every element's material in the low four bits of one byte each;
    /// bits 4 to 6 mark the mortar joints the element holds, across x, y and z.
    let materialIndexBuffer: MTLBuffer
    private let loadTableBuffer: MTLBuffer
    private static let maxLoadPoints = 256
    /// Lattice indices of the nodes that belong to at least one element, in ascending order.
    let nodeListBuffer: MTLBuffer
    public let nodeCount: Int
    private let placeholderBuffer: MTLBuffer
    private let elementPipeline: MTLComputePipelineState
    /// Builds the element kernel with the work trace compiled in (`tracesWork`).
    private let traceElementPipeline: () -> MTLComputePipelineState?
    private var tracingPipeline: MTLComputePipelineState?
    private let nodePipeline: MTLComputePipelineState
    /// The node kernel with gravity turned from straight down, made when first needed.
    private let turnedNodePipeline: () -> MTLComputePipelineState?
    private lazy var turnedNodes: MTLComputePipelineState? = turnedNodePipeline()
    private let contactClearPipeline: MTLComputePipelineState
    private let contactHashPipeline: MTLComputePipelineState
    private let contactForcePipeline: MTLComputePipelineState
    private let debrisAreaPipeline: MTLComputePipelineState
    /// Contact table over element-sized cells of all space, wrapping periodically: a header per
    /// entry, and four node slots per entry.
    let contactHeadBuffer: MTLBuffer
    let contactSlotBuffer: MTLBuffer
    private let contactPeriod: SIMD3<Int>
    private let contactGridOrigin: SIMD3<Float>
    /// Contact force on each listed node.
    let contactForceBuffer: MTLBuffer
    /// Non-zero once any element has failed.
    private let failureGateBuffer: MTLBuffer
    /// Bars that slip (`StructureModel.bondSlip`): each node's slip state along each axis (three
    /// `SIMD4<Float>`: slip, its rate, plastic slip, largest slip); the bond's area and the slip's
    /// stiffness at each node along each axis (two `SIMD4<Float>`); and each element's bar force
    /// along each axis. Placeholders with perfect bond.
    private var slipBuffer: MTLBuffer
    /// The work trace (`tracesWork`): each element's work by mechanism since it was last folded
    /// into `workSums`, `WorkChannel.allCases.count` floats per element.
    private var workBuffer: MTLBuffer?
    private var workSums: [Double] = []
    private var slipSupportBuffer: MTLBuffer
    private var barForceBuffer: MTLBuffer
    /// The base's connection to the ground, three `SIMD4<Float>` per node (see `anchorForce` in
    /// Structure.metal); a placeholder when the base is clamped or free.
    private let anchorBuffer: MTLBuffer
    private let anchorLawBuffer: MTLBuffer
    /// The connection's stiffnesses per unit area, when the base has one.
    private let anchorStiffness: (normal: Float, shear: Float)?
    /// The largest square angular frequency, in 1/s², of a node on its connection alone.
    private var anchorFrequencySquared: Float = 0
    /// Rigid footings under connections that have them (`Footing`).
    private(set) var footings: FootingSystem?
    /// Connections between two parts of the body (`Anchorage.betweenParts`), when it has any.
    private var pairs: PartPairs?
    private let pairPipeline: MTLComputePipelineState
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
            try ShaderLibrary.pipeline(name, in: library)
        }
        // The element kernel is specialised for structures of a single material without joints.
        let constants = MTLFunctionConstantValues()
        func showsJoints(_ material: StructureMaterial) -> Bool {
            model.unitJoints && material.model == .concrete
                && material.units?.isResolved(byElementsOf: model.elementSize) == true
        }
        var single = model.materials.count == 1 && !model.materials.contains(where: showsJoints)
        constants.setConstantValue(&single, type: .bool, index: 0)
        var traced = false
        constants.setConstantValue(&traced, type: .bool, index: 3)
        elementPipeline = try ShaderLibrary.pipeline("structureElements", in: library, constants: constants)
        traceElementPipeline = {
            let tracing = MTLFunctionConstantValues()
            var single = single
            var traced = true
            tracing.setConstantValue(&single, type: .bool, index: 0)
            tracing.setConstantValue(&traced, type: .bool, index: 3)
            return try? ShaderLibrary.pipeline("structureElements", in: library, constants: tracing)
        }
        // Keep the general connection law out of kernels for ordinary clamped/free bodies.
        let nodeConstants = MTLFunctionConstantValues()
        var connected = model.connectionStiffness != nil
        nodeConstants.setConstantValue(&connected, type: .bool, index: 1)
        nodePipeline = try ShaderLibrary.pipeline("structureNodes", in: library, constants: nodeConstants)
        var turned = true
        nodeConstants.setConstantValue(&turned, type: .bool, index: 4)
        turnedNodePipeline = { [library] in
            try? ShaderLibrary.pipeline("structureNodes", in: library, constants: nodeConstants)
        }
        pairPipeline = try pipeline("structurePairs")
        contactClearPipeline = try pipeline("contactClear")
        contactHashPipeline = try pipeline("contactHash")
        contactForcePipeline = try pipeline("contactForces")
        debrisAreaPipeline = try pipeline("debrisAreas")

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let cells = ex * ey * ez
        let nodes = (ex + 1) * (ey + 1) * (ez + 1)
        flagBuffer = try buffer(cells, "structure flags")
        var materialList = model.materials
        cellElementBuffer = try buffer(cells * 4, "structure cell to element")
        loadTableBuffer = try buffer(Self.maxLoadPoints * 8, "applied load table")
        placeholderBuffer = try buffer(64, "structure placeholder")

        // Mark the lattice cells whose centre lies inside the body, and number their elements.
        var active: [UInt32] = []
        var elementMaterials: [UInt8] = []
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        let cellElements = cellElementBuffer.contents().bindMemory(to: UInt32.self, capacity: cells)
        for k in 0..<ez {
            for j in 0..<ey {
                for i in 0..<ex {
                    let centre = origin + (SIMD3(Float(i), Float(j), Float(k)) + 0.5) * h
                    let index = i + ex * (j + ey * k)
                    if model.occupies(centre) {
                        flags[index] = ElementFlag.active.rawValue
                        cellElements[index] = UInt32(active.count)
                        active.append(UInt32(index))
                        elementMaterials.append(
                            materialList.count > 1 ? UInt8(model.materialIndex(at: centre)) : 0)
                    } else {
                        flags[index] = ElementFlag.empty.rawValue
                        cellElements[index] = .max
                    }
                }
            }
        }
        elementCount = active.count
        let elements = max(elementCount, 1)

        // Where two materials meet, the elements on the weaker one's side carry only the bond
        // across the boundary (a material of their own, with the bond's strength and energy).
        if let bond = model.interfaceBond, materialList.count > 1 {
            let base = elementMaterials
            let (ex, ey, ez) = (self.ex, self.ey, self.ez)
            var bonded: [Int: Int] = [:]
            for (n, index) in active.enumerated() {
                let own = Int(base[n])
                guard materialList[own].model == .concrete else { continue }
                let cell = (Int(index) % ex, (Int(index) / ex) % ey, Int(index) / (ex * ey))
                let weaker = [(-1, 0, 0), (1, 0, 0), (0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1)].contains {
                    let (i, j, k) = (cell.0 + $0.0, cell.1 + $0.1, cell.2 + $0.2)
                    guard i >= 0, j >= 0, k >= 0, i < ex, j < ey, k < ez else { return false }
                    let neighbour = cellElements[i + ex * (j + ey * k)]
                    guard neighbour != .max else { return false }
                    let other = Int(base[Int(neighbour)])
                    guard other != own else { return false }
                    let mine = materialList[own].tensileStrength
                    let theirs =
                        materialList[other].model == .concrete
                        ? materialList[other].tensileStrength : .infinity
                    return mine < theirs || (mine == theirs && own > other)
                }
                guard weaker else { continue }
                let joint: Int
                if let known = bonded[own] {
                    joint = known
                } else {
                    var material = materialList[own]
                    material.name += " at a joint"
                    material.tensileStrength = min(material.tensileStrength, bond.x)
                    material.fractureEnergy = min(material.fractureEnergy, bond.y)
                    if let units = material.units {
                        material.units?.tensileStrength = min(units.tensileStrength, bond.x)
                        material.units?.fractureEnergy = min(units.fractureEnergy, bond.y)
                    }
                    materialList.append(material)
                    joint = materialList.count - 1
                    bonded[own] = joint
                }
                elementMaterials[n] = UInt8(joint)
            }
        }
        materials = materialList
        guard materials.count <= StructureModel.maxMaterials else {
            throw BlastError.tooManyMaterials(materials.count)
        }
        // Masonry fine enough to show its units: mark the elements its mortar joints pass through.
        jointed = materials.map(showsJoints)
        if jointed.contains(true) {
            let (ex, ey) = (self.ex, self.ey)
            for (n, index) in active.enumerated() {
                let own = Int(elementMaterials[n])
                guard jointed[own], let units = materials[own].units else { continue }
                let cell = SIMD3(
                    Float(Int(index) % ex), Float((Int(index) / ex) % ey), Float(Int(index) / (ex * ey)))
                elementMaterials[n] |= model.jointPlanes(inElementAt: origin + cell * h, units: units) << 4
            }
        }

        stateBuffer = try buffer(elements * Self.stateStride, "structure element state")
        forceBuffer = try buffer(elements * Self.forceStride, "structure element forces")
        steelBuffer = try buffer(elements * 16, "structure reinforcement")
        let hasSteel = materials.contains { $0.steel != nil }
        barHistoryBuffer = try buffer(hasSteel ? elements * 128 : 128, "structure reinforcement history")
        let averagesCrushing = materials.contains { Self.crushRadius(of: $0, elementSize: h) > 0 }
        let crushLength = averagesCrushing ? elements * 16 : 16
        let materialIndex = try buffer(elements, "structure material indices")
        materialIndex.copy(elementMaterials)
        materialIndexBuffer = materialIndex
        crushBuffers = [try buffer(crushLength, "crushing, even"), try buffer(crushLength, "crushing, odd")]
        let spreadsRupture = materials.contains { Self.barReach(of: $0, elementSize: h) > 0 }
        let barPlasticLength = spreadsRupture ? elements * 16 : 16
        barPlasticBuffers = [
            try buffer(barPlasticLength, "bar plastic strain, even"),
            try buffer(barPlasticLength, "bar plastic strain, odd"),
        ]
        let barRateLength = spreadsRupture && model.barRateAlongBars ? elements * 16 : 16
        barRateBuffers = [
            try buffer(barRateLength, "bar strain rate, even"),
            try buffer(barRateLength, "bar strain rate, odd"),
        ]

        // Smear each reinforcement layer into the elements it overlaps, in proportion to the
        // share of the element's volume inside the layer.
        memset(steelBuffer.contents(), 0, steelBuffer.length)
        var densest = [Float](repeating: 0, count: materials.count)
        if hasSteel {
            let ratios = steelBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: elements)
            // Bars are ignored in elements whose material has no steel.
            for (n, index) in active.enumerated() where materials[Int(elementMaterials[n] & 15)].steel != nil
            {
                let (i, j, k) = (Int(index) % ex, (Int(index) / ex) % ey, Int(index) / (ex * ey))
                let low = origin + SIMD3(Float(i), Float(j), Float(k)) * h
                var ratio = SIMD3<Float>.zero
                for layer in model.reinforcement {
                    let overlap = simd_max(
                        simd_min(low + h, layer.region.max) - simd_max(low, layer.region.min), .zero)
                    ratio += layer.ratio * (overlap.x * overlap.y * overlap.z / (h * h * h))
                }
                ratios[n] = SIMD4(ratio, 0)
                for axis in 0..<3 where ratio[axis] > 0 { barAxes |= 1 << UInt32(axis) }
                // Inclined bars: each layer is spread across a band sqrt(2) elements wide (two of
                // the diagonal rows its elements form), as a hat centred on the bars, so that its
                // steel is kept exactly. In one row, on fine meshes where the bars overlap a mat
                // as they anchor into a member, the steel's stiffness outran the time step.
                let centre = low + 0.5 * h
                let band = h * Float(2).squareRoot()
                var best: (ratio: Float, code: UInt16) = (0, 0)
                for bars in model.inclinedBars {
                    guard let axes = bars.axes, bars.span.contains(centre[axes.third]) else { continue }
                    let direction = simd_normalize(bars.direction)
                    var offset = centre - bars.start
                    offset[axes.third] = 0
                    let along = simd_dot(offset, direction)
                    guard along >= -0.25 * band, along <= bars.length + 0.25 * band else { continue }
                    let across = simd_length(offset - along * direction)
                    let weight = max(0, 1 - across / band)
                    let share = bars.areaPerMetre * weight / band
                    if share > best.ratio { best = (share, axes.code) }
                }
                let own = Int(elementMaterials[n] & 15)
                densest[own] = max(densest[own], ratio.max() + best.ratio)
                if best.ratio > 0 {
                    // Inclined bars lie between two of the axes (see `ElementSteel`).
                    let plane = (Int(best.code) - 1) / 2
                    barAxes |= (1 << UInt32(plane)) | (1 << UInt32((plane + 1) % 3))
                    let base = steelBuffer.contents().advanced(by: n * 16 + 12)
                    base.storeBytes(of: Float16(best.ratio), as: Float16.self)
                    base.advanced(by: 2).storeBytes(of: best.code, as: UInt16.self)
                }
            }
        }
        func indexBuffer(_ indices: [UInt32], _ label: String) throws -> MTLBuffer {
            let result = try buffer(indices.count * MemoryLayout<UInt32>.stride, label)
            result.copy(indices)
            return result
        }
        densestSteel = densest
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
        nodeBuffer = try buffer(max(nodeCount, 1) * MemoryLayout<StructureNode>.stride, "structure nodes")
        nodeMapBuffer = try buffer(nodes * 4, "structure lattice to node")
        let nodeMap = nodeMapBuffer.contents().bindMemory(to: UInt32.self, capacity: nodes)
        nodeMap.update(repeating: .max, count: nodes)
        for (compact, index) in nodeList.enumerated() {
            nodeMap[Int(index)] = UInt32(compact)
        }

        // Contact cells map into a table that wraps space periodically, offset by half an element
        // so that every undeformed node sits in the middle of its cell. Each period is the
        // structure's extent plus a few cells, rounded up to a power of two, then halved along the
        // longest axis until the table has no more than about four entries per node (of eight
        // slots each).
        contactGridOrigin = origin - 0.5 * h
        func powerOfTwo(atLeast value: Int) -> Int {
            var result = 1
            while result < value { result *= 2 }
            return result
        }
        var period = SIMD3(
            powerOfTwo(atLeast: ex + 4), powerOfTwo(atLeast: ey + 4), powerOfTwo(atLeast: ez + 4))
        while period.x * period.y * period.z > max(4 * nodeCount, 4096) {
            let axis = period.x >= period.y && period.x >= period.z ? 0 : (period.y >= period.z ? 1 : 2)
            period[axis] /= 2
        }
        contactPeriod = period
        let gridCells = period.x * period.y * period.z
        contactHeadBuffer = try buffer(gridCells * 4, "contact grid headers")
        contactSlotBuffer = try buffer(gridCells * 32, "contact grid slots")
        memset(contactHeadBuffer.contents(), 0xFF, contactHeadBuffer.length)
        contactForceBuffer = try buffer(nodeList.count * 12, "contact forces")
        failureGateBuffer = try buffer(16, "failure gate")
        // Placeholders, replaced once the body is set up if its bars slip (`setUpBondSlip`).
        slipSupportBuffer = try buffer(16, "slip support")
        slipBuffer = try buffer(16, "bar slip")
        barForceBuffer = try buffer(16, "bar forces")
        try model.validateAnchorages()
        if let stiffness = model.connectionStiffness {
            anchorStiffness = stiffness
            anchorBuffer = try buffer(nodeList.count * 48, "anchors")
        } else {
            anchorStiffness = nil
            anchorBuffer = try buffer(16, "anchors")
        }
        anchorLawBuffer = try buffer(
            (anchorStiffness != nil ? max(nodeList.count, 1) : 1) * MemoryLayout<AnchorageParameters>.stride,
            "connection laws")
        try setUpBondSlip()
        reset()
        if let anchorStiffness {
            let stiffest = max(anchorStiffness.normal, anchorStiffness.shear)
            let anchors = anchorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * nodeCount)
            mutateNodes { nodes in
                for n in 0..<nodeCount where anchors[3 * n].x > 0 && nodes[n].mass > 0 {
                    anchorFrequencySquared = max(
                        anchorFrequencySquared, stiffest * anchors[3 * n].x / nodes[n].mass)
                }
            }
            try setUpFootings(library: library)
            try setUpPairs()
        }
    }

    /// The share of a quarter face that `corner` of the element at `element` carries for a joint
    /// whose normal is `across`: of each face it lies on that faces the support with no element
    /// beyond it, the cosine between them. A joint at an angle to the lattice is tied over the
    /// staircase of faces that stands for it, whose shares add up to the joint's own area.
    private func tributary(_ across: SIMD3<Float>, corner: Int, element: (Int, Int, Int)) -> Float {
        var share: Float = 0
        for axis in 0..<3 {
            let positive = (corner >> axis) & 1 == 1
            let weight = positive ? -across[axis] : across[axis]
            guard weight > 1e-4 else { continue }
            var beyond = [element.0, element.1, element.2]
            beyond[axis] += positive ? 1 : -1
            if compactIndex(beyond[0], beyond[1], beyond[2]) == nil { share += weight }
        }
        return share
    }

    /// Makes the connections between two parts of the body: each node on faces that face such a
    /// joint, tied to the nearest node of the other part straight across the gap (on faces that
    /// face back across it), with how far that part's faces in the region reach from it along
    /// the joint, its seat.
    private func setUpPairs() throws {
        let slots = Set(
            model.supports.indices.filter { model.anchorage(ofSupport: $0)?.betweenParts == true }.map {
                $0 + 1
            })
        guard !slots.isEmpty else { return }
        let h = model.elementSize
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        var owners: [Int: (area: Float, slot: Int, position: SIMD3<Float>)] = [:]
        var partners: [Int: [Int: SIMD3<Float>]] = [:]
        for n in 0..<elementCount {
            let (i, j, k) = elementCoordinates(Int(instances[n]))
            for corner in 0..<8 {
                let (ci, cj, ck) = (i + (corner & 1), j + ((corner >> 1) & 1), k + ((corner >> 2) & 1))
                let point = referencePosition(ci, cj, ck)
                guard !model.isClampedBySupport(at: point), let slot = model.connectionSlot(at: point),
                    slots.contains(slot), let law = model.connection(inSlot: slot)
                else { continue }
                let index = nodeIndex(ci, cj, ck)
                let share = tributary(law.across, corner: corner, element: (i, j, k))
                if share > 0 { owners[index, default: (0, slot, point)].area += h * h / 4 * share }
                if tributary(-law.across, corner: corner, element: (i, j, k)) > 0 {
                    partners[slot, default: [:]][index] = point
                }
            }
        }
        var masses = [Float](repeating: 0, count: nodeCount)
        mutateNodes { nodes in for n in nodes.indices { masses[n] = nodes[n].mass } }
        var found: [PartPairs.Pair] = []
        for (owner, entry) in owners.sorted(by: { $0.key < $1.key }) {
            guard let law = model.connection(inSlot: entry.slot), let side = partners[entry.slot] else {
                continue
            }
            let normal = law.across
            // The nearest node across the gap, straight across it within half an element.
            var best: (node: Int, gap: Float, offset: Float)?
            for (node, position) in side where node != owner {
                let apart = entry.position - position
                let gap = simd_dot(apart, normal)
                let offset = simd_length(apart - gap * normal)
                guard gap > 1e-3 * h, offset < 0.5 * h else { continue }
                if best.map({
                    gap < $0.gap - 1e-4 * h || (abs(gap - $0.gap) <= 1e-4 * h && offset < $0.offset)
                })
                    ?? true
                {
                    best = (node, gap, offset)
                }
            }
            guard let best, let base = side[best.node] else { continue }
            // How far the other part's faces reach from the partner along each axis of the joint,
            // and half an element more (the last node's own share), less how far the node sits
            // from it already.
            let axes = Anchorage.jointAxes(law.isUnder ? .zero : normal)
            let start = entry.position - base
            var seat = SIMD4<Float>(repeating: 0)
            for (slot, direction) in [axes.along, -axes.along, axes.other, -axes.other].enumerated() {
                var reach: Float = 0
                for position in side.values {
                    let apart = position - base
                    let along = simd_dot(apart, direction)
                    guard abs(simd_dot(apart, normal)) < 0.5 * h,
                        simd_length(apart - along * direction - simd_dot(apart, normal) * normal) < 0.5 * h
                    else { continue }
                    reach = max(reach, along)
                }
                seat[slot] = reach + h / 2 - simd_dot(start, direction)
            }
            let reduced = masses[owner] * masses[best.node] / max(masses[owner] + masses[best.node], 1e-30)
            found.append(
                PartPairs.Pair(
                    owner: owner, partner: best.node, area: entry.area, slot: entry.slot, seat: seat,
                    reducedMass: reduced,
                    law: AnchorageParameters(law, material: model.material, elementSize: h)))
        }
        guard !found.isEmpty else { return }
        pairs = try PartPairs(device: device, pairs: found, nodeCount: nodeCount)
        let stiffest = max(anchorStiffness?.normal ?? 0, anchorStiffness?.shear ?? 0)
        for pair in found where pair.reducedMass > 0 {
            anchorFrequencySquared = max(anchorFrequencySquared, stiffest * pair.area / pair.reducedMass)
        }
    }

    /// The connections between parts of the body after the last step, those of support region
    /// `support` alone if given, or nil without any.
    public func pairSummary(support: Int? = nil) -> PartPairs.Summary? {
        pairs?.summary(slot: support.map { $0 + 1 }, nodes: { body in mutateNodes(body) })
    }

    /// Makes the footings of connections that have one, under the nodes they tie.
    private func setUpFootings(library: MTLLibrary) throws {
        let anchors = anchorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * nodeCount)
        let lattice = nodeListBuffer.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        var members: [FootingSystem.Member] = []
        var bodyMass: Float = 0
        mutateNodes { nodes in
            for n in 0..<nodeCount {
                bodyMass += nodes[n].mass
                guard anchors[3 * n].x > 0, !nodes[n].isFixed else { continue }
                let index = Int(lattice[n])
                let rest = referencePosition(
                    index % (ex + 1), (index / (ex + 1)) % (ey + 1), index / ((ex + 1) * (ey + 1)))
                guard let slot = model.connectionSlot(at: rest), let law = model.connection(at: rest),
                    law.footing != nil
                else { continue }
                members.append(
                    FootingSystem.Member(
                        entity: n, rest: rest, area: anchors[3 * n].x, slot: slot, law: law,
                        stiffness: law.stiffness(material: model.material, elementSize: model.elementSize)))
            }
        }
        footings = try FootingSystem(
            device: device, library: library, members: members, entityCount: nodeCount, bodyMass: bodyMass,
            contactDamping: contactDamping)
    }

    /// The footings under the base after the last step, in the order of their connections (the
    /// ground's, then the support regions'); empty without any.
    public func footingSummaries() -> [FootingSummary] { footings?.summaries() ?? [] }

    /// With bars that slip, makes their buffers: the slip state, each element's bar forces, and
    /// the bond's area at each node along each axis, a share of the bars' surface in the elements
    /// around it (4 rho / d per unit volume), with the slip's stiffness there, from the bars' own
    /// stretch across those elements and the bond's initial stiffness. An element's bars tie the
    /// slip at each of its corners to that at all eight, so the stretch counts eight times its
    /// own corner's share, E_s rho h / 16 (a Gershgorin bound): counted once, the slip rang
    /// without settling. (Done after the initialiser has set everything else up: written inline
    /// there, the loop made the optimised build trap, as one did in `ShellSolver`'s.)
    private func setUpBondSlip() throws {
        guard let bond = model.bondSlip, materials.contains(where: { $0.steel != nil }) else { return }
        let h = model.elementSize
        let law = bond.law(compressiveStrength: model.material.compressiveStrength)
        let bondStiffness = law.peak * pow(0.02, law.alpha) / (0.02 * law.s1)
        let barModulus = model.material.steel?.youngsModulus ?? 200e9
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        let ratios = steelBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: max(elementCount, 1))
        let nodeMap = nodeMapBuffer.contents().bindMemory(
            to: UInt32.self, capacity: (ex + 1) * (ey + 1) * (ez + 1))
        var support = [SIMD4<Float>](repeating: .zero, count: 2 * max(nodeCount, 1))
        for n in 0..<elementCount {
            let (i, j, k) = elementCoordinates(Int(instances[n]))
            let ratio = SIMD3(ratios[n].x, ratios[n].y, ratios[n].z)
            guard any(ratio .> 0) else { continue }
            let area = 4 * ratio / bond.barDiameter * (h * h * h / 8)
            let stiffness = barModulus * h / 2 * ratio + bondStiffness * area
            for corner in 0..<8 {
                let lattice =
                    (i + (corner & 1)) + (ex + 1)
                    * ((j + ((corner >> 1) & 1)) + (ey + 1) * (k + ((corner >> 2) & 1)))
                let node = Int(nodeMap[lattice])
                support[2 * node] += SIMD4(area, 0)
                support[2 * node + 1] += SIMD4(stiffness, 0)
            }
        }
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        slipSupportBuffer = try buffer(support.count * 16, "slip support")
        slipSupportBuffer.copy(support)
        slipBuffer = try buffer(3 * nodeCount * 16, "bar slip")
        barForceBuffer = try buffer(max(elementCount, 1) * 32, "bar forces")
    }

    // MARK: - State

    /// Restores the undeformed, stress-free, stationary body.
    public func reset() {
        time = 0
        failureGateBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        failedAtCheckpoint = nil
        memset(contactForceBuffer.contents(), 0, contactForceBuffer.length)
        let h = model.elementSize
        let cells = ex * ey * ez
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: cells)
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        for n in 0..<elementCount {
            flags[Int(instances[n])] = ElementFlag.active.rawValue
        }
        memset(stateBuffer.contents(), 0, stateBuffer.length)
        if let workBuffer {
            memset(workBuffer.contents(), 0, workBuffer.length)
            workSums = workSums.map { _ in 0 }
        }
        memset(slipBuffer.contents(), 0, slipBuffer.length)
        memset(barForceBuffer.contents(), 0, barForceBuffer.length)
        memset(forceBuffer.contents(), 0, forceBuffer.length)
        memset(barHistoryBuffer.contents(), 0, barHistoryBuffer.length)
        for crushBuffer in crushBuffers + barPlasticBuffers + barRateBuffers {
            memset(crushBuffer.contents(), 0, crushBuffer.length)
        }

        footings?.reset()
        pairs?.reset()
        let materialIndices = materialIndexBuffer.contents().bindMemory(
            to: UInt8.self, capacity: max(elementCount, 1))
        let onGround = model.fixedBase && abs(origin.z) < 0.5 * h
        // A connected base gets each ground node's share of the base area instead of a clamp.
        let anchored = anchorStiffness != nil
        let anchors = anchorBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: max(3 * nodeCount, 1))
        if anchored { memset(anchorBuffer.contents(), 0, anchorBuffer.length) }
        let laws = anchorLawBuffer.contents().bindMemory(
            to: AnchorageParameters.self, capacity: max(nodeCount, 1))
        let turned = model.hasTurnedJoints
        mutateNodes { nodes in
            nodes.update(repeating: StructureNode())
            for n in 0..<elementCount {
                let element = Int(instances[n])
                let (i, j, k) = elementCoordinates(element)
                let cornerMass = materials[Int(materialIndices[n] & 15)].density * h * h * h / 8
                for corner in 0..<8 {
                    let index = nodeIndex(i + (corner & 1), j + ((corner >> 1) & 1), k + ((corner >> 2) & 1))
                    nodes[index].mass += cornerMass
                    let nk = k + ((corner >> 2) & 1)
                    let point = referencePosition(i + (corner & 1), j + ((corner >> 1) & 1), nk)
                    // Tributary area on exposed faces on the joint's side (lower faces, unless a
                    // support's joint faces another way); finite supports never pin interior nodes.
                    if anchored && (turned || corner < 4 && (k == 0 || compactIndex(i, j, k - 1) == nil)),
                        let law = model.connection(at: point), law.betweenParts != true,
                        case let share = tributary(law.across, corner: corner, element: (i, j, k)), share > 0
                    {
                        anchors[3 * index].x += h * h / 4 * share
                        laws[index] = AnchorageParameters(law, material: model.material, elementSize: h)
                    } else if onGround && nk == 0 && model.baseAnchorage == nil {
                        nodes[index].isFixed = true
                    }
                }
            }
        }
        holdSupports()
    }

    /// Holds the nodes inside the model's support regions (with a little tolerance, so that a
    /// region ending on a face holds the nodes on it).
    private func holdSupports() {
        guard !model.supports.isEmpty else { return }
        mutateNodes { nodes in
            for k in 0...ez {
                for j in 0...ey {
                    for i in 0...ex {
                        guard let n = storedNode(i, j, k) else { continue }
                        let p = referencePosition(i, j, k)
                        if model.isClampedBySupport(at: p) {
                            nodes[n].isFixed = true
                        }
                    }
                }
            }
        }
    }

    /// Direct access to the nodes, for setting supports and initial velocities. Index them with
    /// `nodeIndex(_:_:_:)`.
    public func mutateNodes(_ body: (UnsafeMutableBufferPointer<StructureNode>) throws -> Void) rethrows {
        let pointer = nodeBuffer.contents().bindMemory(to: StructureNode.self, capacity: max(nodeCount, 1))
        try body(UnsafeMutableBufferPointer(start: pointer, count: nodeCount))
    }

    /// Where node (i, j, k) is stored, if any element uses it.
    public func storedNode(_ i: Int, _ j: Int, _ k: Int) -> Int? {
        guard i >= 0, j >= 0, k >= 0, i <= ex, j <= ey, k <= ez else { return nil }
        let value = nodeMapBuffer.contents().load(
            fromByteOffset: (i + (ex + 1) * (j + (ey + 1) * k)) * 4, as: UInt32.self)
        return value == .max ? nil : Int(value)
    }

    /// Where node (i, j, k) is stored. The node must belong to an element.
    public func nodeIndex(_ i: Int, _ j: Int, _ k: Int) -> Int {
        guard let index = storedNode(i, j, k) else {
            preconditionFailure("No element uses node (\(i), \(j), \(k))")
        }
        return index
    }

    @inlinable
    public func elementIndex(_ i: Int, _ j: Int, _ k: Int) -> Int { i + ex * (j + ey * k) }

    /// The mechanisms the work trace (`tracesWork`) separates, in the order of `workChannels` in
    /// Structure.metal. Concrete's stresses are split in its crack axes.
    public enum WorkChannel: Int, CaseIterable, Sendable {
        /// Concrete's normal stresses where tensile, on planes not cracked open (see
        /// `tensionCracked`).
        case tensionNormal
        /// Concrete's normal stresses where compressive, on axes not crushed past their peak
        /// (see `compressionCrushed`).
        case compressionNormal
        /// Shear on planes no crack has opened.
        case uncrackedShear
        /// Shear across cracks held at their cap, in proportion to the cap's parts: aggregate
        /// interlock, the bars' dowel action and their kinking.
        case interlock, dowel, kink
        /// The bars' own stretching, and the bond on their slip (with `bondSlip`).
        case bars, bond
        /// Hourglass control.
        case hourglass
        /// The rest of the concrete's work (second cracks, compaction, large rotations), and
        /// elements of other materials.
        case other
        /// Bulk viscosity.
        case viscosity
        /// Shear across cracks below their cap: the cracked plane's own stiffness.
        case crackShear
        /// `interlock` and `crackShear` where the crack is pressed shut (compression across it).
        case interlockPressed, crackShearPressed
        /// `tensionNormal` on planes cracked 0.1 mm open or more, and `compressionNormal` on
        /// axes crushed past their peak.
        case tensionCracked, compressionCrushed
        /// `tensionNormal` on planes cracked, but by less than 0.1 mm: the concrete between
        /// cracks, as far as the mesh separates it.
        case tensionHairline

        public var label: String {
            [
                "tension", "compression", "uncracked shear", "interlock", "dowel", "kinking", "bars", "bond",
                "hourglass", "other", "viscosity", "crack shear", "interlock, pressed",
                "crack shear, pressed",
                "tension, cracked", "compression, crushed", "tension, hairline",
            ][rawValue]
        }
    }

    /// Adds each element's work by mechanism to a trace (`workTotals`), as a diagnostic of where
    /// a structure's stiffness and strength come from. Off by default; it costs a buffer of
    /// seventeen floats per element.
    public var tracesWork = false {
        didSet {
            guard tracesWork, workBuffer == nil else { return }
            tracingPipeline = traceElementPipeline()
            let length = max(elementCount * WorkChannel.allCases.count * 4, 16)
            workBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            if let workBuffer { memset(workBuffer.contents(), 0, workBuffer.length) }
            workSums = [Double](repeating: 0, count: elementCount * WorkChannel.allCases.count)
        }
    }

    /// The work (J) each mechanism has done since the trace began, summed over the elements
    /// `include` accepts by their lattice coordinates; indexed by `WorkChannel`. Call between
    /// steps; it folds the GPU's single-precision sums into double precision as it goes, so
    /// call it every few thousand steps at least.
    public func workTotals(where include: ((Int, Int, Int) -> Bool)? = nil) -> [Double] {
        let channels = WorkChannel.allCases.count
        guard let workBuffer else { return [Double](repeating: 0, count: channels) }
        let raw = workBuffer.contents().bindMemory(to: Float.self, capacity: elementCount * channels)
        for n in 0..<(elementCount * channels) {
            workSums[n] += Double(raw[n])
        }
        memset(workBuffer.contents(), 0, workBuffer.length)
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        var totals = [Double](repeating: 0, count: channels)
        for n in 0..<elementCount {
            if let include {
                let (i, j, k) = elementCoordinates(Int(instances[n]))
                guard include(i, j, k) else { continue }
            }
            for c in 0..<channels { totals[c] += workSums[n * channels + c] }
        }
        return totals
    }

    public func elementCoordinates(_ index: Int) -> (i: Int, j: Int, k: Int) {
        (index % ex, (index / ex) % ey, index / (ex * ey))
    }

    /// Where element (i, j, k)'s data is stored, if the body started with an element there.
    func compactIndex(_ i: Int, _ j: Int, _ k: Int) -> Int? {
        guard i >= 0, j >= 0, k >= 0, i < ex, j < ey, k < ez else { return nil }
        let value = cellElementBuffer.contents().load(
            fromByteOffset: elementIndex(i, j, k) * 4, as: UInt32.self)
        return value == .max ? nil : Int(value)
    }

    /// A float in element (i, j, k)'s state, or zero where there is no element.
    private func stateValue(_ i: Int, _ j: Int, _ k: Int, offset: Int) -> Float {
        guard let index = compactIndex(i, j, k) else { return 0 }
        return stateBuffer.contents().load(fromByteOffset: index * Self.stateStride + offset, as: Float.self)
    }

    /// Node (i, j, k), or an empty node where no element uses it.
    public func node(_ i: Int, _ j: Int, _ k: Int) -> StructureNode {
        guard let index = storedNode(i, j, k) else { return StructureNode() }
        return nodeBuffer.contents().load(
            fromByteOffset: index * MemoryLayout<StructureNode>.stride, as: StructureNode.self)
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
        (0..<6).map { stateValue(i, j, k, offset: $0 * 4) }
    }

    /// Reinforcement ratios of an element along x, y and z.
    public func steelRatio(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        guard let index = compactIndex(i, j, k) else { return .zero }
        let value = steelBuffer.contents().load(fromByteOffset: index * 16, as: SIMD4<Float>.self)
        return SIMD3(value.x, value.y, value.z)
    }

    /// Damage index of an element: 0 is sound, 1 is at the point of failure.
    /// Concrete: the tensile strength's strain-rate factor, frozen when the element first
    /// cracked (zero until then).
    public func crackingFactor(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateValue(i, j, k, offset: 108)
    }

    /// Running average of the element's effective strain rate (1/s).
    public func strainRate(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateValue(i, j, k, offset: 104)
    }

    public func damage(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateValue(i, j, k, offset: 28)
    }

    /// Largest tensile strain a concrete element has seen across any of the lattice planes.
    public func crackStrain(_ i: Int, _ j: Int, _ k: Int) -> Float {
        (0..<3).map { stateValue(i, j, k, offset: 80 + $0 * 4) }.max() ?? 0
    }

    /// Concrete: the running confinement gain of element (i, j, k) along each crack axis (the
    /// strength factor less one).
    public func confinement(_ i: Int, _ j: Int, _ k: Int) -> [Float] {
        (0..<3).map { stateValue(i, j, k, offset: 112 + 4 * $0) }
    }

    /// Concrete: the largest tensile strain element (i, j, k) has seen across each of its three
    /// crack planes, with the planes' normals in the lattice axes (the lattice's own until it
    /// first cracks), and the largest compressive strain along each.
    public func crackPlanes(_ i: Int, _ j: Int, _ k: Int) -> (
        history: SIMD3<Float>, normals: [SIMD3<Float>], crush: SIMD3<Float>
    ) {
        let history = SIMD3((0..<3).map { stateValue(i, j, k, offset: 80 + 4 * $0) })
        let crush = SIMD3((0..<3).map { stateValue(i, j, k, offset: 124 + 4 * $0) })
        guard let n = compactIndex(i, j, k) else { return (history, [], crush) }
        let base = stateBuffer.contents().advanced(by: n * Self.stateStride)
        let q = (0..<4).map { Float(base.load(fromByteOffset: 136 + 2 * $0, as: Float16.self)) }
        let rotation = simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])
        let turned = simd_length(rotation.vector) > 0.5
        let normals = (0..<3).map { axis -> SIMD3<Float> in
            var unit = SIMD3<Float>.zero
            unit[axis] = 1
            return turned ? simd_normalize(rotation).act(unit) : unit
        }
        return (history, normals, crush)
    }

    /// The largest volumetric compression, V0 / V - 1, that element (i, j, k)'s pores have been
    /// crushed to; zero until it passes the crushing pressure while confined.
    public func compaction(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateValue(i, j, k, offset: 144)
    }

    /// Net force (N) that the elements around a node exerted on it in the last step. At a
    /// restrained or prescribed node this is minus the reaction.
    public func nodalForce(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        for corner in 0..<8 {
            let (a, b, c) = (i - (corner & 1), j - ((corner >> 1) & 1), k - ((corner >> 2) & 1))
            guard a >= 0, b >= 0, c >= 0, a < ex, b < ey, c < ez,
                flag(a, b, c) == .active || flag(a, b, c) == .bare,
                let index = compactIndex(a, b, c)
            else { continue }
            let base = forceBuffer.contents().advanced(by: index * Self.forceStride + corner * 12)
            total += SIMD3(
                base.load(as: Float.self), base.load(fromByteOffset: 4, as: Float.self),
                base.load(fromByteOffset: 8, as: Float.self))
        }
        return total
    }

    /// Von Mises: equivalent plastic strain. Concrete: largest compressive strain so far.
    public func plasticStrain(_ i: Int, _ j: Int, _ k: Int) -> Float {
        stateValue(i, j, k, offset: 24)
    }

    /// Concrete: the plastic strain of its bars along the lattice axes (positive stretched; a
    /// ruptured set reads 1e9).
    public func barPlasticStrain(_ i: Int, _ j: Int, _ k: Int) -> SIMD3<Float> {
        SIMD3((0..<3).map { stateValue(i, j, k, offset: 92 + 4 * $0) })
    }

    /// The state of the base's connection to the ground, when it has one (`Anchorage`).
    public struct AnchorSummary: Sendable {
        /// Nodes tied to the ground (for shells, points of their footprint), and those whose tie
        /// has lost all its strength (none for a body resting on the ground, which has none to
        /// lose).
        public var nodes = 0
        public var separated = 0
        /// The fraction of the tie's strength lost, averaged over the base area.
        public var meanDamage: Float = 0
        /// Total force the ground puts on the body through the connection, in N.
        public var reaction = SIMD3<Float>.zero
        /// Its moment about the base's centre of area, in N m.
        public var moment = SIMD3<Float>.zero
        /// The largest slip and the largest opening of any node, in metres.
        public var maxSlip: Float = 0
        public var maxOpening: Float = 0
        /// The deepest the ground has yielded and let the base settle for good, in metres.
        public var maxSettlement: Float = 0
        /// The work the connection's sliding has dissipated, in joules (solid elements' ground and
        /// support connections not on a footing).
        public var dissipated: Float = 0
    }

    /// The connection's state after the last step, or nil when the base is clamped or free.
    public func anchorSummary() -> AnchorSummary? {
        guard anchorStiffness != nil else { return nil }
        let anchors = anchorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * nodeCount)
        let lattice = nodeListBuffer.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        var summary = AnchorSummary()
        var area: Float = 0
        var centre = SIMD3<Float>.zero
        var points: [(SIMD3<Float>, SIMD3<Float>)] = []
        mutateNodes { nodes in
            for n in 0..<nodeCount where anchors[3 * n].x > 0 {
                let state = anchors[3 * n]
                let force = SIMD3(anchors[3 * n + 1].x, anchors[3 * n + 1].y, anchors[3 * n + 1].z)
                summary.maxSettlement = max(summary.maxSettlement, -anchors[3 * n + 2].x)
                summary.dissipated += anchors[3 * n + 2].y
                let index = Int(lattice[n])
                let (i, j) = (index % (ex + 1), (index / (ex + 1)) % (ey + 1))
                let k = index / ((ex + 1) * (ey + 1))
                let position = referencePosition(i, j, k)
                guard let anchorage = model.connection(at: position), !nodes[n].isFixed else { continue }
                let stiffness = anchorage.stiffness(material: model.material, elementSize: model.elementSize)
                let remaining = anchorage.remaining(
                    peak: anchors[3 * n + 1].w, wear: state.w, normalStiffness: stiffness.normal)
                summary.nodes += 1
                if remaining <= 0 { summary.separated += 1 }
                summary.meanDamage += state.x * (1 - remaining)
                summary.reaction += force
                summary.maxSlip = max(summary.maxSlip, simd_length(SIMD2(state.y, state.z)))
                // On a footing, the opening is from the footing's top as it has moved.
                let ground = footings?.footing(ofEntity: n).map {
                    footings!.displacement(ofPointAt: position, footing: $0).z
                }
                let across = anchorage.across
                summary.maxOpening = max(
                    summary.maxOpening, simd_dot(nodes[n].displacement, across) - (ground ?? 0))
                area += state.x
                centre += state.x * position
                points.append((position, force))
            }
        }
        guard area > 0 else { return summary }
        summary.meanDamage /= area
        centre /= area
        summary.moment = points.reduce(.zero) { $0 + simd_cross($1.0 - centre, $1.1) }
        return summary
    }

    /// The nodes a connection ties, at rest, with the area each is tied over.
    func tiedPoints() -> [(position: SIMD3<Float>, area: Float)] {
        guard anchorStiffness != nil else { return [] }
        let anchors = anchorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * nodeCount)
        let lattice = nodeListBuffer.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        return (0..<nodeCount).compactMap { n in
            guard anchors[3 * n].x > 0 else { return nil }
            let index = Int(lattice[n])
            let position = referencePosition(
                index % (ex + 1), (index / (ex + 1)) % (ey + 1), index / ((ex + 1) * (ey + 1)))
            return (position, anchors[3 * n].x)
        }
    }

    /// Actual un-clamped bearing area assigned to a finite support, in square metres.
    /// Read only while the GPU is idle, as with `anchorSummary()`.
    public func supportBearingArea(at support: Int) -> Float {
        guard anchorStiffness != nil, model.supports.indices.contains(support) else { return 0 }
        let anchors = anchorBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * nodeCount)
        let lattice = nodeListBuffer.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        var area: Float = 0
        mutateNodes { nodes in
            for n in nodes.indices where !nodes[n].isFixed && anchors[3 * n].x > 0 {
                let index = Int(lattice[n])
                let point = referencePosition(
                    index % (ex + 1), (index / (ex + 1)) % (ey + 1), index / ((ex + 1) * (ey + 1)))
                if model.finiteSupportIndex(at: point) == support { area += anchors[3 * n].x }
            }
        }
        return area + (pairs?.area(inSlot: 1 + support) ?? 0)
    }

    /// Concrete's cracks in the slice of elements at lattice row `j`, top row first, one character an
    /// element: `.` none open past `threshold` (a strain), else the crack plane's direction in
    /// the x–z plane (`|` vertical, `-` horizontal, `/` and `\\` inclined), and a space where
    /// there is no element (`x` where one has been removed). A diagnostic.
    public func crackMap(row j: Int, threshold: Float = 1e-3) -> [String] {
        (0..<ez).reversed().map { k in
            String((0..<ex).map { i in crackSymbol(i, j, k, threshold: threshold, plan: false) })
        }
    }

    /// The same for the layer of elements `k`, in plan, the last row along y first: the crack
    /// plane's direction in the x–y plane (`|` across x, `-` across y). What a photograph of a
    /// slab's face shows.
    public func crackPlan(layer k: Int, threshold: Float = 1e-3) -> [String] {
        (0..<ey).reversed().map { j in
            String((0..<ex).map { i in crackSymbol(i, j, k, threshold: threshold, plan: true) })
        }
    }

    /// The largest crack opening (strain) of element (i, j, k), zero where there is none.
    public func crackOpening(_ i: Int, _ j: Int, _ k: Int) -> Float {
        guard let n = compactIndex(i, j, k), flag(i, j, k) == .active || flag(i, j, k) == .bare else {
            return 0
        }
        let base = stateBuffer.contents().advanced(by: n * Self.stateStride)
        return (0..<3).map { base.load(fromByteOffset: 80 + 4 * $0, as: Float.self) }.max() ?? 0
    }

    private func crackSymbol(_ i: Int, _ j: Int, _ k: Int, threshold: Float, plan: Bool) -> Character {
        guard let n = compactIndex(i, j, k) else { return " " }
        if flag(i, j, k) != .active && flag(i, j, k) != .bare { return "x" }
        let base = stateBuffer.contents().advanced(by: n * Self.stateStride)
        let history = SIMD3((0..<3).map { base.load(fromByteOffset: 80 + 4 * $0, as: Float.self) })
        let widest = history.x >= history.y && history.x >= history.z ? 0 : (history.y >= history.z ? 1 : 2)
        guard history[widest] > threshold else { return "." }
        let q = (0..<4).map { Float(base.load(fromByteOffset: 136 + 2 * $0, as: Float16.self)) }
        var axis = SIMD3<Float>.zero
        axis[widest] = 1
        let rotation = simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])
        let normal = simd_length(rotation.vector) > 0.5 ? simd_normalize(rotation).act(axis) : axis
        // The angle of the normal from x, in the plane drawn.
        let angle = atan2(plan ? normal.y : normal.z, normal.x) * 180 / .pi
        let folded = angle < -90 ? angle + 180 : (angle > 90 ? angle - 180 : angle)
        if abs(folded) < 22.5 { return "|" }
        if abs(folded) > 67.5 { return "-" }
        return folded > 0 ? "\\" : "/"
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
                    fromByteOffset: n * Self.stateStride + 24, as: Float.self)
                summary.maxPlasticStrain = max(summary.maxPlasticStrain, strain)
                summary.maxDamage = max(
                    summary.maxDamage,
                    stateBuffer.contents().load(fromByteOffset: n * Self.stateStride + 28, as: Float.self)
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
            nodeListBuffer, nodeMapBuffer, cellElementBuffer, materialIndexBuffer,
            contactHeadBuffer, contactSlotBuffer, contactForceBuffer,
        ].reduce(0) { $0 + $1.length }
    }

    /// True once any element has failed since the last reset.
    public var hasFailed: Bool { failureGateBuffer.contents().load(as: UInt32.self) != 0 }
    /// Whether something had failed as of the coupled solver's last checkpoint, which then
    /// stands in for `hasFailed` in deciding what to encode, so that contact and debris join at
    /// a step that does not depend on how the steps were batched. Nil on its own.
    var failedAtCheckpoint: Bool?
    /// What decides whether contact and debris loading are encoded.
    var encodesAsFailed: Bool { failedAtCheckpoint ?? hasFailed }

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
    /// The time step every substep takes: the stable one, unless another body sharing the
    /// substeps needs a shorter one.
    public var criticalTimeStep: Float { stepOverride ?? stableTimeStep }
    /// Set by a body this one is tied to, so both take the same steps.
    public var stepOverride: Float?

    /// Largest stable time step of this body alone, in seconds: the time a compression wave takes
    /// to cross an element, its speed raised by the bars where they are densest.
    public var stableTimeStep: Float {
        let speeds = materials.enumerated().map { n, material -> Float in
            guard let steel = material.steel, n < densestSteel.count, densestSteel[n] > 0 else {
                return material.dilatationalWaveSpeed
            }
            let modulus =
                material.lameLambda + 2 * material.shearModulus + steel.youngsModulus * densestSteel[n]
            return (modulus / material.density).squareRoot()
        }
        let step = timeStepSafety * model.elementSize / (speeds.max() ?? 1)
        // A node on a stiff connection to the ground: its frequency on the connection adds to
        // the highest the elements alone can give it, 2 c / h; the bearing's damping shortens the
        // stable step by √(1 + ζ²) − ζ, and the step keeps a tenth in hand.
        let footingFrequencySquared = footings?.frequencySquared ?? 0
        guard anchorFrequencySquared > 0 || footingFrequencySquared > 0 else { return step }
        let elementFrequency = 2 * (speeds.max() ?? 1) / model.elementSize
        let frequency =
            (elementFrequency * elementFrequency + anchorFrequencySquared + footingFrequencySquared)
            .squareRoot()
        let damping = (1 + contactDamping * contactDamping).squareRoot() - contactDamping
        return min(step, 0.9 * 2 * damping / frequency)
    }

    /// Substeps to encode per fluid step so that a fluid step of `fluidStepBound` seconds can be
    /// covered within the structural stability limit.
    public func substeps(forFluidStepBound fluidStepBound: Float) -> Int {
        min(max(Int((fluidStepBound / criticalTimeStep).rounded(.up)), 1), 96)
    }

    /// Encodes `count` substeps. With a fluid binding, the substeps share out the fluid's current
    /// time step and apply blast loads; without one, each advances by `criticalTimeStep`.
    public func encodeSubsteps(_ encoder: MTLComputeCommandEncoder, count: Int, fluid: FluidBinding?) {
        encodeSubsteps(encoder, count: count, fluid: fluid, interface: nil, beforeNodes: nil, afterNodes: nil)
    }

    func encodeDebrisAreas(_ encoder: MTLComputeCommandEncoder, fluid: FluidBinding) {
        var uniforms = makeUniforms(fluid: fluid)
        let group = MTLSize(width: elementPipeline.threadExecutionWidth, height: 1, depth: 1)
        if nodeCount > 0, uniforms.debrisLoading != 0, encodesAsFailed, let area = fluid.debrisArea {
            encoder.setComputePipelineState(debrisAreaPipeline)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(flagBuffer, offset: 0, index: 1)
            encoder.setBuffer(fluid.control, offset: 0, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 3)
            encoder.setBuffer(nodeListBuffer, offset: 0, index: 4)
            encoder.setBuffer(fluid.mask, offset: 0, index: 5)
            encoder.setBuffer(area, offset: 0, index: 6)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 7)
            encoder.setBuffer(fluid.couplingMap ?? placeholderBuffer, offset: 0, index: 8)
            encoder.dispatchThreads(
                MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
        }
    }

    /// Shell nodes tied into this body's elements: the links, how many, each lattice node's
    /// entries among them (start per compact node, then (link, corner) pairs), and the force and
    /// moment each tied node hands over.
    struct InterfaceBuffers {
        var links: MTLBuffer
        var count: Int
        var start: MTLBuffer
        var entries: MTLBuffer
        var loads: MTLBuffer
    }

    /// Encodes `count` substeps, running `beforeNodes` after each substep's element and contact
    /// passes (with the substep and its uniforms) and `afterNodes` after its node pass, for a body
    /// tied to this one.
    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: FluidBinding?, interface: InterfaceBuffers?,
        beforeNodes: ((Int, StructureUniforms) -> Void)?, afterNodes: ((Int) -> Void)?
    ) {
        var uniforms = makeUniforms(fluid: fluid)
        uniforms.interfaceLinks = UInt32(interface?.count ?? 0)
        var parameters = zip(materials, jointed).map { material, jointed in
            Self.parameters(
                for: material, elementSize: model.elementSize, hourglassCoefficient: hourglassCoefficient,
                jointed: jointed, bondSlip: model.bondSlip != nil)
        }
        guard elementCount > 0 else { return }
        // One SIMD group per threadgroup. The element kernel needs many registers, and groups of
        // the largest allowed size (1,024 threads) let too few run at once on each GPU core: they
        // are a third slower than groups of 32 to 512, of which 32 is the fastest.
        let group = MTLSize(width: elementPipeline.threadExecutionWidth, height: 1, depth: 1)

        // Until something has failed there is nothing to collide, so the contact kernels are
        // left out; they join in from the first batch encoded after a failure (coupled to the
        // air, from its first checkpoint after one).
        let encodeContact = contactMode == .always || (contactMode == .afterFailure && encodesAsFailed)

        // Loose debris adds up its frontal area in each air cell before the substeps, for the
        // implicit form of its drag. There is none until something has failed.
        if let fluid, !fluid.debrisAreasPrepared { encodeDebrisAreas(encoder, fluid: fluid) }

        for substep in 0..<count {
            uniforms.substep = UInt32(substep)
            uniforms.loadTime = Float(time + Double(substep) * Double(criticalTimeStep))
            encoder.setComputePipelineState(tracesWork ? tracingPipeline ?? elementPipeline : elementPipeline)
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
            encoder.setBytes(
                &parameters, length: parameters.count * MemoryLayout<MaterialParameters>.stride, index: 15)
            encoder.setBuffer(materialIndexBuffer, offset: 0, index: 16)
            encoder.setBuffer(crushBuffers[substep % 2], offset: 0, index: 13)
            encoder.setBuffer(crushBuffers[1 - substep % 2], offset: 0, index: 14)
            encoder.setBuffer(barPlasticBuffers[substep % 2], offset: 0, index: 17)
            encoder.setBuffer(barPlasticBuffers[1 - substep % 2], offset: 0, index: 18)
            encoder.setBuffer(cellElementBuffer, offset: 0, index: 19)
            encoder.setBuffer(nodeMapBuffer, offset: 0, index: 20)
            encoder.setBuffer(fluid?.refinement?.patchOfTile ?? placeholderBuffer, offset: 0, index: 21)
            encoder.setBuffer(fluid?.refinement?.fine ?? placeholderBuffer, offset: 0, index: 22)
            encoder.setBuffer(fluid?.refinement?.mask ?? placeholderBuffer, offset: 0, index: 23)
            encoder.setBuffer(slipBuffer, offset: 0, index: 24)
            encoder.setBuffer(barForceBuffer, offset: 0, index: 25)
            encoder.setBuffer(barRateBuffers[substep % 2], offset: 0, index: 26)
            encoder.setBuffer(barRateBuffers[1 - substep % 2], offset: 0, index: 27)
            encoder.setBuffer(
                tracesWork ? workBuffer ?? placeholderBuffer : placeholderBuffer, offset: 0, index: 28)
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

            beforeNodes?(substep, uniforms)
            if let pairs {
                uniforms.pairs = UInt32(pairs.count)
                encoder.setComputePipelineState(pairPipeline)
                encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
                encoder.setBuffer(pairs.nodes, offset: 0, index: 1)
                encoder.setBuffer(pairs.state, offset: 0, index: 2)
                encoder.setBuffer(pairs.seats, offset: 0, index: 3)
                encoder.setBuffer(pairs.laws, offset: 0, index: 4)
                encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 5)
                encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 6)
                encoder.dispatchThreads(
                    MTLSize(width: pairs.count, height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            let down = gravityDirection.x == 0 && gravityDirection.y == 0 && gravityDirection.z < 0
            encoder.setComputePipelineState(down ? nodePipeline : turnedNodes ?? nodePipeline)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(forceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 3)
            encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 4)
            encoder.setBuffer(nodeListBuffer, offset: 0, index: 5)
            encoder.setBuffer(contactForceBuffer, offset: 0, index: 6)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 7)
            encoder.setBuffer(cellElementBuffer, offset: 0, index: 8)
            encoder.setBuffer(fluid?.state ?? placeholderBuffer, offset: 0, index: 9)
            encoder.setBuffer(fluid?.mask ?? placeholderBuffer, offset: 0, index: 10)
            encoder.setBuffer(fluid?.exchange ?? placeholderBuffer, offset: 0, index: 11)
            encoder.setBuffer(fluid?.debrisArea ?? placeholderBuffer, offset: 0, index: 12)
            encoder.setBuffer(interface?.start ?? placeholderBuffer, offset: 0, index: 13)
            encoder.setBuffer(interface?.entries ?? placeholderBuffer, offset: 0, index: 14)
            encoder.setBuffer(interface?.links ?? placeholderBuffer, offset: 0, index: 15)
            encoder.setBuffer(interface?.loads ?? placeholderBuffer, offset: 0, index: 16)
            encoder.setBuffer(anchorBuffer, offset: 0, index: 17)
            encoder.setBuffer(slipBuffer, offset: 0, index: 18)
            encoder.setBuffer(slipSupportBuffer, offset: 0, index: 19)
            encoder.setBuffer(barForceBuffer, offset: 0, index: 20)
            encoder.setBuffer(anchorLawBuffer, offset: 0, index: 21)
            encoder.setBuffer(fluid?.couplingMap ?? placeholderBuffer, offset: 0, index: 22)
            encoder.setBuffer(footings?.footingOfBuffer ?? placeholderBuffer, offset: 0, index: 23)
            encoder.setBuffer(footings?.constantBuffer ?? placeholderBuffer, offset: 0, index: 24)
            encoder.setBuffer(footings?.stateBuffer ?? placeholderBuffer, offset: 0, index: 25)
            encoder.setBuffer(footings?.linkBuffer ?? placeholderBuffer, offset: 0, index: 26)
            encoder.setBuffer(pairs?.state ?? placeholderBuffer, offset: 0, index: 27)
            encoder.setBuffer(pairs?.nodeStart ?? placeholderBuffer, offset: 0, index: 28)
            encoder.setBuffer(pairs?.nodeEntries ?? placeholderBuffer, offset: 0, index: 29)
            encoder.dispatchThreads(
                MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            footings?.encode(
                encoder,
                uniforms: FootingSystem.Uniforms(
                    fixedStep: uniforms.fixedStep, criticalStep: criticalTimeStep, substep: UInt32(substep),
                    gravity: gravity, damping: damping, footings: 0),
                control: fluid?.control ?? placeholderBuffer)
            afterNodes?(substep)
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
        let h = model.elementSize
        var uniforms = StructureUniforms(
            ex: UInt32(ex), ey: UInt32(ey), ez: UInt32(ez),
            h: h, originX: origin.x, originY: origin.y, originZ: origin.z,
            bulkLinear: 0.06,
            bulkQuadratic: 1.5,
            criticalStep: criticalTimeStep,
            gravity: gravity,
            damping: damping,
            minVolumeRatio: 0.25,
            groundFriction: groundContact ? 8 : -1,
            contactMode: contactMode.rawValue,
            contactNx: UInt32(contactPeriod.x), contactNy: UInt32(contactPeriod.y),
            contactNz: UInt32(contactPeriod.z),
            gridOriginX: contactGridOrigin.x, gridOriginY: contactGridOrigin.y,
            gridOriginZ: contactGridOrigin.z,
            contactStiffness: contactStiffness / (criticalTimeStep * criticalTimeStep),
            contactDamping: contactDamping,
            contactFriction: contactFriction)
        let down = simd_normalize(gravityDirection)
        (uniforms.gravityX, uniforms.gravityY, uniforms.gravityZ) = (down.x, down.y, down.z)
        // Time constant of the running averages of strain rate and confinement: 50 steps.
        uniforms.rateFilter = 1 / (50 * criticalTimeStep)
        uniforms.orientedCracks = model.crackAxes.uniform
        uniforms.secondCracks = model.secondCracks ? 1 : 0
        uniforms.bareBars = model.bareBars ? 1 : 0
        uniforms.crackSlip = model.crackSlip ? (model.slipWidensCracks ? 1 : 2) : 0
        uniforms.barAxes = barAxes
        uniforms.crackShearStiffness = model.crackShearStiffness ? 1 : 0
        uniforms.pressedInterlock = model.pressedInterlock ? 1 : 0
        uniforms.barRateAlongBars = model.barRateAlongBars ? 1 : 0
        if let bond = model.bondSlip, materials.contains(where: { $0.steel != nil }) {
            let law = bond.law(compressiveStrength: model.material.compressiveStrength)
            uniforms.bondSlip = 1
            uniforms.bondPeak = law.peak
            uniforms.bondResidual = law.residual
            uniforms.bondS1 = law.s1
            uniforms.bondS2 = law.s2
            uniforms.bondS3 = law.s3
            uniforms.bondAlpha = law.alpha
            // Bond lost where bars have yielded, from their curve: the plastic strain at their
            // ultimate strength, and b = (2 - f_u / f_y)^2.
            if bond.yieldedBondLoss, let steel = model.material.steel,
                let top = steel.curve.max(by: { $0.y < $1.y }), top.x > 0
            {
                uniforms.bondYieldRange = top.x
                let excess = 2 - top.y / steel.curve[0].y
                uniforms.bondYieldExponent = max(excess * excess, 0.1)
            }
        }
        if anchorStiffness != nil {
            uniforms.anchored = 1
        }
        if footings != nil { uniforms.footings = 1 }
        if let anchorStiffness, let anchorage = model.baseAnchorage {
            uniforms.anchorNormalStiffness = anchorStiffness.normal
            uniforms.anchorShearStiffness = anchorStiffness.shear
            uniforms.anchorTension = anchorage.tensileStrength
            uniforms.anchorPlateau = anchorage.tensionPlateau
            uniforms.anchorOpening = anchorage.tensionOpening
            uniforms.anchorCohesion = anchorage.cohesion
            uniforms.anchorCohesionSlip = anchorage.cohesionSlip
            uniforms.anchorFriction = anchorage.friction
        }
        if let appliedLoad, fluid == nil {
            uniforms.loadCount = UInt32(min(appliedLoad.history.count, Self.maxLoadPoints))
            uniforms.loadFace = UInt32(2 * appliedLoad.axis + (appliedLoad.positiveSide ? 1 : 0))
        }
        if let fluid {
            uniforms.coupled = 1
            // Debris is loaded only where the air can be given the reaction.
            if debrisDrag, fluid.exchange != nil, fluid.debrisArea != nil, let region = fluid.exchangeRegion {
                uniforms.debrisLoading = 1
                uniforms.couplingMapCount = fluid.couplingMapCount
                uniforms.exchangeX = Int32(region.origin.x)
                uniforms.exchangeY = Int32(region.origin.y)
                uniforms.exchangeZ = Int32(region.origin.z)
                uniforms.exchangeNx = Int32(region.dims.x)
                uniforms.exchangeNy = Int32(region.dims.y)
                uniforms.exchangeNz = Int32(region.dims.z)
            }
            uniforms.ambientPressure = fluid.ambientPressure
            uniforms.fluidGamma = fluid.gamma
            uniforms.fluidAirModel = fluid.airModel.rawValue
            if let refinement = fluid.refinement {
                uniforms.fluidRefine = UInt32(refinement.ratio)
                uniforms.fluidBlocksX = UInt32(refinement.blocks.x)
                uniforms.fluidBlocksY = UInt32(refinement.blocks.y)
            }
            if let deep = fluid.deepRefinement {
                uniforms.fluidDeepRatio = UInt32(deep.ratio)
                uniforms.fluidDeepBlocksX = UInt32(deep.blocks.x)
                uniforms.fluidDeepBlocksY = UInt32(deep.blocks.y)
                uniforms.fluidDeepPatchOffset = UInt32(deep.patchOffset)
                uniforms.fluidDeepCellOffset = UInt32(deep.cellOffset)
            }
            uniforms.fluidCell = fluid.grid.cellSize
            uniforms.fluidNx = UInt32(fluid.grid.nx)
            uniforms.fluidNy = UInt32(fluid.grid.ny)
            uniforms.fluidNz = UInt32(fluid.grid.nz)
        } else {
            uniforms.fixedStep = criticalTimeStep
        }
        return uniforms
    }

    /// Elements either side over which a material's crushing is averaged; zero when it is local.
    static func crushRadius(of material: StructureMaterial, elementSize h: Float) -> Int {
        material.model == .concrete ? Int((material.crushLength / h).rounded()) : 0
    }

    /// Half the debonded length over which a bar's rupture is judged, in elements; the debonded
    /// length is taken as the material's crack spacing. Zero below one element.
    static func barReach(of material: StructureMaterial, elementSize h: Float) -> Float {
        guard material.model == .concrete, material.steel != nil, material.bondSpreading,
            material.crackSpacing > h
        else { return 0 }
        return material.crackSpacing / 2 / h
    }

    /// The mortar joints element (i, j, k) holds, as bits 0 to 2 for joints across x, y and z.
    public func jointPlanes(_ i: Int, _ j: Int, _ k: Int) -> UInt8 {
        guard let index = compactIndex(i, j, k) else { return 0 }
        return materialIndexBuffer.contents().load(fromByteOffset: index, as: UInt8.self) >> 4
    }

    /// A material's properties as the GPU needs them, for elements of size `h`; `jointed` when
    /// its masonry is meshed as units and mortar joints.
    static func parameters(
        for material: StructureMaterial, elementSize h: Float, hourglassCoefficient: Float = 1,
        jointed: Bool = false, bondSlip: Bool = false
    ) -> MaterialParameters {
        var parameters = MaterialParameters(
            density: material.density,
            lambda: material.lameLambda,
            mu: material.shearModulus,
            yieldStress: material.yieldStress,
            hardening: material.hardeningModulus,
            failureStrain: material.failureStrain,
            // Bending stiffness of a cube in an hourglass mode: E h / 48 per unit modal amplitude.
            hourglassStiffness: hourglassCoefficient * material.youngsModulus * h / 48,
            soundSpeed: material.dilatationalWaveSpeed)
        parameters.youngsModulus = material.youngsModulus
        guard material.model == .concrete else { return parameters }
        // Strengths at blast strain rates; softening scaled to the element so that the energy
        // per unit area of crack or crush band is the material's, whatever the mesh.
        let fc = material.compressiveStrength * material.concreteRateFactor
        // With its joints meshed, masonry away from them has its units' tensile strength.
        let units = jointed ? material.units : nil
        let ft = (units?.tensileStrength ?? material.tensileStrength) * material.concreteRateFactor
        let onset = ft / material.youngsModulus
        let peak = 2 * fc / material.youngsModulus
        let end = peak + 2 * material.crushingEnergy / (max(h, material.crushBand) * 0.8 * fc)
        parameters.materialModel = MaterialModel.concrete.rawValue
        parameters.compressiveStrength = fc
        parameters.tensileStrength = ft
        parameters.crackOnset = onset
        // Bars spread cracking over the crack spacing, unless they slip, when the slip spreads
        // their strain and each crack keeps to its own element.
        let band = material.steel == nil || bondSlip ? h : max(h, material.crackSpacing)
        let fractureEnergy = units?.fractureEnergy ?? material.fractureEnergy
        parameters.crackSoftening = max(fractureEnergy / (band * ft) - onset / 2, onset / 2)
        parameters.crackSofteningAlone = max(fractureEnergy / (h * ft) - onset / 2, onset / 2)
        if let units {
            // A joint is one element's plane: its opening and sliding are smeared over the
            // element, and its energies kept as a crack's is. Sliding by s wears the joint as
            // opening by s (c / G_II) (G_I / f_t) does, so that its cohesion c is spent over
            // G_II of sliding as its bond f_t is over G_I of opening (Lourenço and Rots).
            let bond = units.bondStrength * material.concreteRateFactor
            let bondOnset = bond / material.youngsModulus
            parameters.jointStrength = bond / ft
            parameters.jointSoftening = max(
                units.bondFractureEnergy / (band * bond) - bondOnset / 2, bondOnset / 2)
            parameters.jointCohesion = units.cohesion
            parameters.jointFriction = units.friction
            parameters.jointSlipDamage =
                (h / band) * units.cohesion * units.bondFractureEnergy / (units.shearFractureEnergy * bond)
        }
        // Aggregate interlock: v = 0.18 sqrt(fc) / (0.31 + 24 w / (a + 16)), in MPa and mm.
        parameters.crackBand = band
        parameters.interlockStrength = material.interlockFactor * 0.18e6 * (fc / 1e6).squareRoot()
        parameters.interlockWidthScale = 24_000 / (material.aggregateSize * 1000 + 16)
        parameters.crackResidual = material.crackResidual
        parameters.dowelFactor = material.dowelFactor
        parameters.fractureRateExponent = material.fractureRateExponent
        parameters.tensionRateLaw = material.tensionRateLaw == .modelCode2010 ? 1 : 0
        parameters.crackDilatancy = material.crackDilatancy
        parameters.crushRadius = UInt32(Self.crushRadius(of: material, elementSize: h))
        parameters.barReach = bondSlip ? 0 : Self.barReach(of: material, elementSize: h)
        parameters.crushPeak = peak
        parameters.crushEnd = end
        // The crack strain at which the removal width is reached in one element. (It was once
        // capped at 0.5, which on elements under 10 mm removed them at narrower cracks.)
        parameters.erosionStrain = material.erosionOpening / h
        // Removed once crushed to twice the strain at which softening ends.
        parameters.crushErosion = 1
        parameters.confinement = material.confinementCoefficient
        if let steel = material.steel {
            // The fixed rate factor is applied at yield and fades out towards ultimate
            // strength, which is barely rate-sensitive.
            let curve = steel.curve
            let first = curve[0].y
            let top = curve.map(\.y).max() ?? first
            parameters.steelModulus = steel.youngsModulus
            // Yield asymptotes for cyclic loading: the secant from yield to ultimate strength.
            if let peak = curve.max(by: { $0.y < $1.y }), peak.x > 0, peak.y > first {
                parameters.steelHardeningRatio = (peak.y - first) / (peak.x * steel.youngsModulus)
            }
            parameters.steelPoints = UInt32(curve.count)
            withUnsafeMutableBytes(of: &parameters.steelStrain) { strains in
                withUnsafeMutableBytes(of: &parameters.steelStress) { stresses in
                    for (n, point) in curve.enumerated() {
                        let along = top > first ? (point.y - first) / (top - first) : 0
                        let factor = max(1 + (material.steelRateFactor - 1) * (1 - along), 1)
                        strains.storeBytes(of: point.x, toByteOffset: n * 4, as: Float.self)
                        stresses.storeBytes(of: point.y * factor, toByteOffset: n * 4, as: Float.self)
                    }
                }
            }
        }
        if material.rateDependent {
            let megapascals = material.compressiveStrength / 1e6
            parameters.concreteRateCompression = 1 / (5 + 9 * megapascals / 10)
            parameters.concreteRateTension = 1 / (1 + 8 * megapascals / 10)
            if let steel = material.steel, material.steelRateDependent {
                switch material.steelRateLaw {
                case .malvarCrawford:
                    parameters.steelRateYield = 0.074 - 0.040 * steel.yieldStress / 414e6
                    parameters.steelRateUltimate = 0.019 - 0.009 * steel.yieldStress / 414e6
                case .ceb:
                    parameters.steelRateLog = 1
                    parameters.steelRateYield = 6 / (steel.yieldStress / 1e6)
                    parameters.steelRateUltimate = 7 / (steel.ultimateStress / 1e6)
                }
            }
        }
        return parameters
    }
}
