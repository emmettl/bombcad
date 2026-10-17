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
    var contactMode: UInt32 = 0
    var stamp: UInt32 = 0
    var contactNx: UInt32 = 1
    var contactNy: UInt32 = 1
    var contactNz: UInt32 = 1
    var contactRadius: Float = 1
    var gridOriginX: Float = 0
    var gridOriginY: Float = 0
    var gridOriginZ: Float = 0
    var contactStiffness: Float = 0
    var contactDamping: Float = 0
    var contactFriction: Float = 0
    var neighbourDistance: Float = 0
    var beamCount: UInt32 = 0
    var elementSize: Float = 0
    var debrisLoading: UInt32 = 0
    var exchangeX: Int32 = 0
    var exchangeY: Int32 = 0
    var exchangeZ: Int32 = 0
    var exchangeNx: Int32 = 0
    var exchangeNy: Int32 = 0
    var exchangeNz: Int32 = 0
    var fluidAirModel: UInt32 = 0
    var fluidRefine: UInt32 = 0
    var fluidBlocksX: UInt32 = 0
    var fluidBlocksY: UInt32 = 0
    var crackSlip: UInt32 = 0
    var anchored: UInt32 = 0
    var anchorNormalStiffness: Float = 0
    var anchorShearStiffness: Float = 0
    var anchorTension: Float = 0
    var anchorPlateau: Float = 0
    var anchorOpening: Float = 0
    var anchorCohesion: Float = 0
    var anchorCohesionSlip: Float = 0
    var anchorFriction: Float = 0
    var couplingMapCount: UInt32 = 0
    var footings: UInt32 = 0
    var fluidDeepRatio: UInt32 = 0
    var fluidDeepBlocksX: UInt32 = 0
    var fluidDeepBlocksY: UInt32 = 0
    var fluidDeepPatchOffset: UInt32 = 0
    var fluidDeepCellOffset: UInt32 = 0
    var gravityX: Float = 0
    var gravityY: Float = 0
    var gravityZ: Float = -1
    var removesFragments: UInt32 = 0
    /// 1 when the applied pressure acts on each element by its share, stored after the table.
    var loadShares: UInt32 = 0
    /// 1 when the applied load also acts on nodes by their shares, after the elements'.
    var loadNodeShares: UInt32 = 0
    /// Fastened sheets' links (`ShellMesh.Link`): how many, and where in the load table's buffer
    /// (bytes) their records, each node's first entry and the entries begin.
    var linkCount: UInt32 = 0
    var linkRecords: UInt32 = 0
    var linkStarts: UInt32 = 0
    var linkEntries: UInt32 = 0
    /// Connections between two parts of the body (`Anchorage.betweenParts`).
    var pairs: UInt32 = 0
    /// 1 when contact's forces were found this substep (if it is on).
    var contactEncoded: UInt32 = 0
}

/// Layout matches `BeamElement` in `Shell.metal`.
struct BeamElementData {
    var n0: UInt32
    var n1: UInt32
    var axis: UInt32
    var material: UInt32
    var width: Float
    var depth: Float
    var length: Float
    var barCount: UInt32
    var tieRatio: Float
    var bowed: Float = 0
    var padding1: Float = 0
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
    /// Another member's element facing this one below and above it (-1: none), for the air's
    /// load (`ShellMesh.shields`).
    var shieldBelow: Int32 = -1
    var shieldAbove: Int32 = -1
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
    /// Beam elements, on the centrelines of columns.
    public let beamCount: Int
    public let nodeCount: Int
    public let layers: Int
    /// Bar layers stored per element.
    let barSlots: Int
    let mesh: ShellMesh

    /// Acceleration of gravity in m/s², acting along -z.
    public var gravity: Float = 9.81
    /// The way gravity pulls, as `StructureSolver.gravityDirection`.
    public var gravityDirection = SIMD3<Float>(0, 0, -1)
    /// Mass-proportional damping rate in 1/s.
    public var damping: Float = 0
    /// Fraction of the element transit time used as the stable time step.
    public var timeStepSafety: Float = 0.5
    /// Let nodes that fall to z = 0 land instead of passing through.
    public var groundContact = true
    /// Let the air push loose nodes (those of no intact element), when coupled to the air.
    public var debrisDrag = true
    /// Whether separate pieces, and loose debris, collide with each other.
    public var contactMode = ContactMode.afterFailure
    /// For timing contact's parts alone: with true, contact fills its table each substep but
    /// finds no forces (`blastbench contact-profile`). Never for a result.
    public var contactTableOnly = false
    /// Contact spring stiffness as a fraction of the stiffest the time step allows.
    public var contactStiffness: Float = 0.1
    public var contactDamping: Float = 0.3
    public var contactFriction: Float = 0.5
    /// A pressure history applied to one face, for running the structure without the air.
    public var appliedLoad: PressureLoad? {
        didSet { writeLoadTable() }
    }
    /// Simulated time accumulated by `advance(steps:)`.
    public internal(set) var time: Double = 0

    public let nodeBuffer: MTLBuffer
    /// Reference position of every node, as four floats.
    public let referenceBuffer: MTLBuffer
    public let elementBuffer: MTLBuffer
    public let flagBuffer: MTLBuffer
    /// Damage of each element, 0 (sound) to 1 (failing), for display.
    public let displayBuffer: MTLBuffer
    let layerBuffer: MTLBuffer
    private let barLayoutBuffer: MTLBuffer
    private let barBuffer: MTLBuffer
    private let forceBuffer: MTLBuffer
    private let neighbourBuffer: MTLBuffer
    /// Punching at column heads and shear failure of sections (see `MemberShearBuffers`).
    private let punching: MemberShearBuffers
    /// Each bar layer's plastic strain per element, written in alternate substeps to one buffer
    /// while the other, from the substep before, is read, so that rupture can be judged over a
    /// debonded length.
    private let barPlasticBuffers: [MTLBuffer]
    private let tiedStartBuffer: MTLBuffer
    /// The body's connections, when it has any (`Anchorage`): for each node, where its points
    /// (`ShellMesh.jointPoints`) start in the lists that follow (one more entry than nodes); each
    /// point's (offset, area) and (the node's whole area, 0, 0, 0), its state (slip x, slip y,
    /// wear, largest opening) and the force on it in the last substep. Placeholders otherwise.
    private let fibreStartBuffer: MTLBuffer
    private let fibreGeometryBuffer: MTLBuffer
    private let fibreStateBuffer: MTLBuffer
    private let fibreForceBuffer: MTLBuffer
    private let fibreLawBuffer: MTLBuffer
    private let fibreCount: Int
    /// Each point's connection slot (as `StructureModel.connectionSlot`).
    private let fibreSlots: [Int]
    /// The connection's stiffnesses per unit area, when the base has one.
    private let anchorStiffness: (normal: Float, shear: Float)?
    /// The largest square angular frequency, in 1/s², of a node on its connection alone.
    private var anchorFrequencySquared: Float = 0
    /// Rigid footings under connections that have them (`Footing`), tied to points of the
    /// footprint.
    private(set) var footings: FootingSystem?
    /// Points through a wall's thickness, and along each side of a column, at which the base's
    /// connection is evaluated, from face to face.
    static let fibresAcross = 9
    private let tiedBuffer: MTLBuffer
    private let tieBuffer: MTLBuffer
    private let tiePipeline: MTLComputePipelineState
    /// Fastened sheets' links: their pass, and where their data begin in the load table's buffer.
    private let linkPipeline: MTLComputePipelineState?
    private let linkLayout: (records: Int, starts: Int, entries: Int)
    /// Nodes tied rigidly to a column's node at a slab.
    public var tieCount: Int { mesh.ties.count }
    private let incidenceStartBuffer: MTLBuffer
    private let incidenceBuffer: MTLBuffer
    let loadTableBuffer: MTLBuffer
    private let failureGateBuffer: MTLBuffer
    private let placeholderBuffer: MTLBuffer
    private let elementPipeline: MTLComputePipelineState
    private let debrisAreaPipeline: MTLComputePipelineState
    private let beamPipeline: MTLComputePipelineState
    private let nodePipeline: MTLComputePipelineState
    /// The node kernel with gravity turned from straight down, made when first needed.
    private let turnedNodePipeline: () -> MTLComputePipelineState?
    private lazy var turnedNodes: MTLComputePipelineState? = turnedNodePipeline()
    public let beamBuffer: MTLBuffer
    /// The bowed beams' offsets (`MemberImperfection`), nil with none bowed.
    let beamBowBuffer: MTLBuffer?
    public let beamFlagBuffer: MTLBuffer
    /// Damage of each beam, 0 (sound) to 1 (failing), for display.
    public let beamDisplayBuffer: MTLBuffer
    let beamFibreBuffer: MTLBuffer
    private let beamBarBuffer: MTLBuffer
    private let beamForceBuffer: MTLBuffer
    /// Bar groups of each beam: position across the section and area, eight per beam.
    private let beamBarLayoutBuffer: MTLBuffer
    private let contactPipelines: [MTLComputePipelineState]
    private let pairPipelines: [MTLComputePipelineState]
    /// Connections between two parts of the body (`Anchorage.betweenParts`), when it has any.
    private var pairs: PartPairs?
    let contactHeadBuffer: MTLBuffer
    let contactSlotBuffer: MTLBuffer
    /// Per table entry, the last substep's stamp at which it held a node that had moved far
    /// enough to touch one that had not (see `shellContactMoved` in Shell.metal).
    let contactMovedBuffer: MTLBuffer
    let contactForceBuffer: MTLBuffer
    private let contactPeriod: SIMD3<Int>
    private let contactOrigin: SIMD3<Float>
    private var stamp: UInt32 = 0
    private static let maxLoadPoints = 256
    /// Gauss-Legendre points and weights through the thickness, from -1 to 1.
    private let thicknessRule: [SIMD2<Float>]
    private static let layerStride = 40
    private static let barStride = 36

    public init(
        device: MTLDevice, commandQueue: MTLCommandQueue? = nil, library: MTLLibrary? = nil,
        model: StructureModel
    ) throws {
        // Profiled sheets as their skins and ribs.
        let model = model.expandingSheets()
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
        beamCount = mesh.beams.count
        nodeCount = mesh.positions.count
        barSlots = max(1, mesh.elements.map(\.bars.count).max() ?? 0)
        thicknessRule = Self.thicknessRule(layers: max(1, model.shellLayers), materials: materials)
        layers = thicknessRule.count

        let library = try library ?? ShaderLibrary.make(device: device)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library)
        }
        elementPipeline = try pipeline("shellElements")
        beamPipeline = try pipeline("beamElements")
        debrisAreaPipeline = try pipeline("shellDebrisAreas")
        // Keep the general connection law out of kernels for ordinary clamped/free bodies.
        let nodeConstants = MTLFunctionConstantValues()
        var connected = model.connectionStiffness != nil
        nodeConstants.setConstantValue(&connected, type: .bool, index: 1)
        var sprung = !model.springSupports.isEmpty
        nodeConstants.setConstantValue(&sprung, type: .bool, index: 22)
        var linked = !mesh.links.isEmpty
        nodeConstants.setConstantValue(&linked, type: .bool, index: 23)
        nodePipeline = try ShaderLibrary.pipeline("shellNodes", in: library, constants: nodeConstants)
        var turned = true
        nodeConstants.setConstantValue(&turned, type: .bool, index: 4)
        turnedNodePipeline = { [library] in
            try? ShaderLibrary.pipeline("shellNodes", in: library, constants: nodeConstants)
        }
        tiePipeline = try pipeline("shellTies")
        linkPipeline = mesh.links.isEmpty ? nil : try pipeline("shellLinks")
        contactPipelines = try ["shellContactClear", "shellContactHash", "shellContactForces"].map(pipeline)
        pairPipelines = try ["shellPairs", "shellPairGather"].map(pipeline)

        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        let elements = max(elementCount, 1)
        let beams = max(beamCount, 1)
        let nodes = max(nodeCount, 1)
        beamBuffer = try buffer(beams * MemoryLayout<BeamElementData>.stride, "beams")
        beamFlagBuffer = try buffer(beams, "beam flags")
        beamDisplayBuffer = try buffer(beams * 4, "beam damage")
        beamFibreBuffer = try buffer(beams * 16 * Self.layerStride, "beam fibres")
        beamBarBuffer = try buffer(beams * ShellMesh.maxBeamBars * Self.barStride, "beam bars")
        beamBarLayoutBuffer = try buffer(beams * ShellMesh.maxBeamBars * 16, "beam bar layout")
        beamForceBuffer = try buffer(beams * 48, "beam forces")
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
        punching = try MemberShearBuffers(
            device: device, mesh: mesh, materials: materials, shells: model.shellSectionShear,
            checksBeams: model.appliesBeamSectionShear)
        barPlasticBuffers = [
            try buffer(hasBars ? elements * barSlots * 2 * 4 : 16, "shell bar plastic, even"),
            try buffer(hasBars ? elements * barSlots * 2 * 4 : 16, "shell bar plastic, odd"),
        ]
        // The contact table: cells as large as an element over the structure's extent, rounded up
        // to powers of two and then shrunk to about eight entries per node.
        let low = mesh.positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0, $1) }
        let high = mesh.positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0, $1) }
        let radius = model.elementSize
        contactOrigin = nodeCount > 0 ? low - 0.5 * radius : .zero
        func powerOfTwo(atLeast value: Int) -> Int {
            var result = 1
            while result < value { result *= 2 }
            return result
        }
        let span = nodeCount > 0 ? (high - low) / radius : .zero
        var period = SIMD3(
            powerOfTwo(atLeast: Int(span.x) + 4), powerOfTwo(atLeast: Int(span.y) + 4),
            powerOfTwo(atLeast: Int(span.z) + 4))
        while period.x * period.y * period.z > max(8 * nodeCount, 4096) {
            let axis = period.x >= period.y && period.x >= period.z ? 0 : (period.y >= period.z ? 1 : 2)
            period[axis] /= 2
        }
        contactPeriod = period
        let tableEntries = period.x * period.y * period.z
        contactHeadBuffer = try buffer(tableEntries * 4, "shell contact headers")
        contactSlotBuffer = try buffer(tableEntries * 32, "shell contact slots")
        contactMovedBuffer = try buffer(tableEntries * 4, "shell contact movement")
        contactForceBuffer = try buffer(nodes * 12, "shell contact forces")
        memset(contactHeadBuffer.contents(), 0xFF, contactHeadBuffer.length)
        memset(contactMovedBuffer.contents(), 0xFF, contactMovedBuffer.length)
        // The table, then each element's share of it.
        // ...and then the spring supports' nodes and laws (below), from the next 16 bytes.
        // ...then the fastened sheets' links: six records a link, each node's first entry, and the
        // entries, two a link.
        let springEnd =
            ((Self.maxLoadPoints * 8 + (max(elements, 1) + max(mesh.positions.count, 1)) * 4 + 15) & ~15)
            + (3 * mesh.positions.count + 6 * model.springSupports.count) * 16
        let linkStarts = springEnd + 6 * mesh.links.count * 16
        let linkEntries = linkStarts + ((mesh.positions.count + 1) * 4 + 15) & ~15
        linkLayout = (springEnd, linkStarts, linkEntries)
        loadTableBuffer = try buffer(linkEntries + 2 * mesh.links.count * 4, "applied load table")
        failureGateBuffer = try buffer(16, "failure gate")
        placeholderBuffer = try buffer(64, "shell placeholder")

        // The fourth component is the node's volume as loose debris. (Worked out in a method of
        // its own: the same loop written inline here made the optimised build crash in `reset`,
        // although the code is sound and runs under the address sanitiser.)
        let volumes = mesh.debrisVolumes()
        let references = referenceBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: nodes)
        for (n, position) in mesh.positions.enumerated() {
            references[n] = SIMD4(position, volumes[n])
        }
        let data = elementBuffer.contents().bindMemory(to: ShellElementData.self, capacity: elements)
        let layout = barLayoutBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: elements * barSlots)
        var incidence = [[UInt32]](repeating: [], count: nodes)
        let shields = mesh.shields()
        for (e, element) in mesh.elements.enumerated() {
            data[e] = ShellElementData(
                n0: element.nodes.x, n1: element.nodes.y, n2: element.nodes.z, n3: element.nodes.w,
                axis: UInt32(element.axis), material: UInt32(element.material),
                barCount: UInt32(element.bars.count),
                thickness: element.thickness, a: element.size.x, b: element.size.y,
                shieldBelow: shields[e].below, shieldAbove: shields[e].above)
            for s in 0..<barSlots {
                layout[e * barSlots + s] = s < element.bars.count ? SIMD4(element.bars[s], 0) : .zero
            }
            for corner in 0..<4 {
                incidence[Int(element.nodes[corner])].append(UInt32(e * 4 + corner))
            }
        }
        let beamData = beamBuffer.contents().bindMemory(to: BeamElementData.self, capacity: beams)
        let bows = MemberImperfection.bows(mesh: mesh, model: model, materials: materials)
        if let bows {
            let bytes = bows.count * MemoryLayout<SIMD4<Float>>.stride
            beamBowBuffer = try buffer(bytes, "beam bows")
            beamBowBuffer!.contents().copyMemory(from: bows, byteCount: bytes)
        } else {
            beamBowBuffer = nil
        }
        for (b, beam) in mesh.beams.enumerated() {
            beamData[b] = BeamElementData(
                n0: beam.nodes.x, n1: beam.nodes.y, axis: UInt32(beam.axis), material: UInt32(beam.material),
                width: beam.section.x, depth: beam.section.y, length: beam.length,
                barCount: UInt32(beam.bars.count), tieRatio: beam.tieRatio,
                bowed: bows?[MemberImperfection.perBeam * b].w ?? 0)
            let layout = beamBarLayoutBuffer.contents().bindMemory(
                to: SIMD4<Float>.self, capacity: beams * ShellMesh.maxBeamBars)
            for slot in 0..<ShellMesh.maxBeamBars {
                layout[b * ShellMesh.maxBeamBars + slot] =
                    slot < beam.bars.count ? SIMD4(beam.bars[slot], 0) : .zero
            }
            for end in 0..<2 {
                incidence[Int(beam.nodes[end])].append(0x8000_0000 | UInt32(b * 4 + end))
            }
        }
        var starts: [UInt32] = [0]
        var entries: [UInt32] = []
        for list in incidence {
            entries += list
            starts.append(UInt32(entries.count))
        }
        var tiedLists = [[UInt32]](repeating: [], count: nodes)
        for tie in mesh.ties { tiedLists[Int(tie.master)].append(tie.slave) }
        var tiedStarts: [UInt32] = [0]
        var tiedEntries: [UInt32] = []
        for list in tiedLists {
            tiedEntries += list
            tiedStarts.append(UInt32(tiedEntries.count))
        }
        let tiedStartStorage = try buffer(tiedStarts.count * 4, "shell tied starts")
        let tiedStorage = try buffer(tiedEntries.count * 4, "shell tied nodes")
        tiedStartStorage.copy(tiedStarts)
        tiedStorage.copy(tiedEntries)
        tiedStartBuffer = tiedStartStorage

        // A connected base: the nodes on the ground carry points of their footprint instead of
        // being clamped.
        var fibreStarts: [UInt32] = [0]
        var fibreGeometry: [SIMD4<Float>] = []
        try model.validateAnchorages()
        var fibreLaws: [AnchorageParameters] = []
        var slots: [Int] = []
        if let stiffness = model.connectionStiffness {
            anchorStiffness = stiffness
            // The ground's connection ties only nodes on the ground; a support's, the points of
            // faces in its region that face its joint.
            let lists = mesh.jointPoints(across: Self.fibresAcross, normals: model.connectionNormals) {
                point, node in
                guard let slot = model.connectionSlot(at: point), slot != 0 || abs(node.z) < 1e-4,
                    let law = model.connection(inSlot: slot), law.betweenParts != true
                else { return nil }
                return (slot, law.across)
            }
            for list in lists {
                let area = list.reduce(0) { $0 + $1.area }
                for point in list {
                    fibreGeometry += [SIMD4(point.arm, point.area), SIMD4(area, 0, 0, 0)]
                    fibreLaws.append(
                        AnchorageParameters(
                            model.connection(inSlot: point.slot)!, material: model.material,
                            elementSize: model.elementSize))
                    slots.append(point.slot)
                }
                fibreStarts.append(UInt32(slots.count))
            }
        } else {
            anchorStiffness = nil
        }
        fibreSlots = slots
        fibreCount = slots.count
        let fibreStartStorage = try buffer(fibreStarts.count * 4, "shell anchor starts")
        let fibreGeometryStorage = try buffer(fibreCount * 32, "shell anchor points")
        fibreStartStorage.copy(fibreStarts)
        fibreGeometryStorage.copy(fibreGeometry)
        fibreStartBuffer = fibreStartStorage
        fibreGeometryBuffer = fibreGeometryStorage
        fibreStateBuffer = try buffer(fibreCount * 16, "shell anchor state")
        fibreForceBuffer = try buffer(fibreCount * 16, "shell anchor forces")
        let lawStorage = try buffer(
            max(fibreCount, 1) * MemoryLayout<AnchorageParameters>.stride, "shell connection laws")
        lawStorage.copy(fibreLaws)
        fibreLawBuffer = lawStorage
        // Spring supports: the nodes in each region, each with its share of the edge's length.
        // Spring supports: the nodes in each region, each with its share of the edge's length;
        // then the supports' laws, each as (stiffness, yield, hardening of the yield per plastic
        // movement) per metre, and the axes.
        let positions = mesh.positions
        var springs = [SIMD4<Float>](repeating: .zero, count: 3 * positions.count)
        // The turning spring acts only where beams end (a profiled sheet's ribs, which carry its
        // bending), shared among them; the others at every node.
        let beamEnds = Set(mesh.beams.flatMap { [Int($0.nodes.x), Int($0.nodes.y)] })
        for (s, support) in model.springSupports.enumerated() {
            let held = positions.indices.filter { support.region.contains(positions[$0]) }
            func shares(_ nodes: [Int]) -> [Int: Float] {
                let stations = Array(Set(nodes.map { positions[$0][support.edge] })).sorted()
                var result: [Int: Float] = [:]
                for n in nodes {
                    let value = positions[n][support.edge]
                    guard let i = stations.firstIndex(of: value) else { continue }
                    let low = i > 0 ? stations[i - 1] : value
                    let high = i + 1 < stations.count ? stations[i + 1] : value
                    result[n] = 0.5 * (high - low)
                }
                return result
            }
            let turning =
                held.contains { beamEnds.contains($0) } ? held.filter { beamEnds.contains($0) } : held
            let along = shares(held)
            let about = shares(turning)
            for n in held { springs[3 * n] = SIMD4(Float(s + 1), along[n] ?? 0, about[n] ?? 0, 0) }
        }
        func packed(_ law: SpringLaw) -> SIMD4<Float> {
            let k = law.stiffness
            let h = law.hardening
            return SIMD4(k, min(law.yield, 1e30), k == h ? 0 : k * h / (k - h), 0)
        }
        for support in model.springSupports {
            springs += [
                packed(support.pull), packed(support.across), packed(support.turnPositive),
                packed(support.turnNegative),
                SIMD4(
                    Float(support.edge), Float(support.along), Float(support.acrossAxis),
                    support.releases == true ? 1 : 0),
                packed(support.acrossNegative ?? support.across),
            ]
        }
        // After the applied load's table and shares, from the next 16 bytes, where `shellNodes`
        // finds them.
        let springOffset =
            (Self.maxLoadPoints * 8 + (max(elementCount, 1) + max(positions.count, 1)) * 4 + 15) & ~15
        if !springs.isEmpty {
            (loadTableBuffer.contents() + springOffset).copyMemory(
                from: springs, byteCount: springs.count * MemoryLayout<SIMD4<Float>>.stride)
        }
        // The links: their nodes, normal and way off (axis + 3 if +), and length; their tension per
        // metre (stiffness, strength, and its softening to nothing over a tenth of its stretch at
        // failure, as `SpringLaw` packs it) and shear (stiffness, strength); state, movement and
        // force zero. Then each node's links, the sheet's end even, the beam's odd.
        if !mesh.links.isEmpty {
            var records: [SIMD4<Float>] = []
            var lists = [[UInt32]](repeating: [], count: positions.count)
            for (n, link) in mesh.links.enumerated() {
                let fastening = model.sheetFastenings[link.fastening].fastening
                let k = fastening.stiffness * fastening.perMetre
                let h = -10 * k
                records += [
                    SIMD4(
                        Float(link.sheet), Float(link.beam), Float(link.normal + (link.off > 0 ? 3 : 0)),
                        link.length),
                    SIMD4(k, fastening.tension * fastening.perMetre, k * h / (k - h), 0),
                    SIMD4(k, fastening.shear * fastening.perMetre, 0, 0),
                    .zero, .zero, .zero,
                ]
                lists[Int(link.sheet)].append(UInt32(2 * n))
                lists[Int(link.beam)].append(UInt32(2 * n + 1))
            }
            (loadTableBuffer.contents() + linkLayout.records).copyMemory(
                from: records, byteCount: records.count * MemoryLayout<SIMD4<Float>>.stride)
            var starts: [UInt32] = [0]
            for list in lists { starts.append(starts.last! + UInt32(list.count)) }
            let entries = lists.flatMap { $0 }
            (loadTableBuffer.contents() + linkLayout.starts).copyMemory(
                from: starts, byteCount: starts.count * 4)
            (loadTableBuffer.contents() + linkLayout.entries).copyMemory(
                from: entries, byteCount: entries.count * 4)
        }
        tiedBuffer = tiedStorage
        tieBuffer = try buffer(mesh.ties.count * 8, "shell ties")
        let tiePairs = tieBuffer.contents().bindMemory(
            to: SIMD2<UInt32>.self, capacity: max(mesh.ties.count, 1))
        for (n, tie) in mesh.ties.enumerated() { tiePairs[n] = SIMD2(tie.slave, tie.master) }
        incidenceStartBuffer = try buffer(starts.count * 4, "shell incidence starts")
        incidenceBuffer = try buffer(entries.count * 4, "shell incidence")
        incidenceStartBuffer.copy(starts)
        incidenceBuffer.copy(entries)
        reset()
        if let anchorStiffness, fibreCount > 0 {
            let starts = fibreStartBuffer.contents().bindMemory(to: UInt32.self, capacity: nodes + 1)
            let points = fibreGeometryBuffer.contents().bindMemory(
                to: SIMD4<Float>.self, capacity: 2 * fibreCount)
            let stiffest = max(anchorStiffness.normal, anchorStiffness.shear)
            mutateNodes { nodes in
                for n in nodes.indices where starts[n + 1] > starts[n] && nodes[n].mass > 0 {
                    var area: Float = 0
                    var second: Float = 0
                    for f in Int(starts[n])..<Int(starts[n + 1]) {
                        let point = points[2 * f]
                        area += point.w
                        second += point.w * (point.x * point.x + point.y * point.y + point.z * point.z)
                    }
                    let frequency = max(area / nodes[n].mass, second / max(nodes[n].inertia, 1e-30))
                    anchorFrequencySquared = max(anchorFrequencySquared, stiffest * frequency)
                }
            }
            // Footings, under the points of the footprint their connections tie.
            var members: [FootingSystem.Member] = []
            var bodyMass: Float = 0
            mutateNodes { nodes in
                for n in nodes.indices {
                    bodyMass += nodes[n].mass
                    guard starts[n + 1] > starts[n], !nodes[n].isClamped else { continue }
                    for f in Int(starts[n])..<Int(starts[n + 1]) {
                        let slot = fibreSlots[f]
                        guard let law = model.connection(inSlot: slot), law.footing != nil else { continue }
                        let point = points[2 * f]
                        members.append(
                            FootingSystem.Member(
                                entity: f, rest: mesh.positions[n] + SIMD3(point.x, point.y, point.z),
                                area: point.w, slot: slot, law: law,
                                stiffness: law.stiffness(
                                    material: model.material, elementSize: model.elementSize)))
                    }
                }
            }
            footings = try FootingSystem(
                device: device, library: library, members: members, entityCount: fibreCount,
                bodyMass: bodyMass,
                contactDamping: contactDamping)
        }
        try setUpPairs()
    }

    /// Makes the connections between two parts of the body (`Anchorage.betweenParts`). In each
    /// such support region, every node on faces of the region that face its joint (as a
    /// connection to the ground finds them, `ShellMesh.jointPoints`) is tied to the nearest node
    /// in the region of a member it does not share, within eight elements, on the joint's side of
    /// it or level with it,
    /// over the faces' area. Its seat is the region and half an element past it (the node's own
    /// share): once it has slid that far, relative to its partner, it is off the seat for good.
    private func setUpPairs() throws {
        let slots = Set(
            model.supports.indices.filter { model.anchorage(ofSupport: $0)?.betweenParts == true }.map {
                $0 + 1
            })
        guard !slots.isEmpty else { return }
        let positions = mesh.positions
        let h = model.elementSize
        // The members each node belongs to.
        var members = [Set<Int>](repeating: [], count: positions.count)
        for element in mesh.elements {
            for corner in 0..<4 { members[Int(element.nodes[corner])].insert(element.solid) }
        }
        for beam in mesh.beams {
            for end in 0..<2 { members[Int(beam.nodes[end])].insert(beam.solid) }
        }
        for tie in mesh.ties { members[Int(tie.slave)].formUnion(members[Int(tie.master)]) }
        // Each region's points on their own, where regions overlap.
        var points = [[ShellMesh.JointPoint]](repeating: [], count: positions.count)
        for slot in slots.sorted() {
            guard let law = model.connection(inSlot: slot) else { continue }
            let found = mesh.jointPoints(across: Self.fibresAcross, normals: [law.across]) { point, _ in
                model.containsSupport(slot - 1, at: point) ? (slot, law.across) : nil
            }
            for n in found.indices { points[n] += found[n] }
        }
        var masses = [Float](repeating: 0, count: positions.count)
        mutateNodes { nodes in for n in nodes.indices { masses[n] = nodes[n].mass } }
        // Each region's nodes, by cells an element across.
        func cell(_ p: SIMD3<Float>) -> SIMD3<Int32> { SIMD3<Int32>((p / h).rounded(.down)) }
        var cells: [Int: [SIMD3<Int32>: [Int]]] = [:]
        for slot in slots {
            var grid: [SIMD3<Int32>: [Int]] = [:]
            for (n, position) in positions.enumerated() where model.containsSupport(slot - 1, at: position) {
                grid[cell(position), default: []].append(n)
            }
            cells[slot] = grid
        }
        var found: [PartPairs.Pair] = []
        for (owner, list) in points.enumerated() where !list.isEmpty {
            for slot in Set(list.map(\.slot)).sorted() {
                guard let law = model.connection(inSlot: slot), let grid = cells[slot] else { continue }
                let region = model.supports[slot - 1]
                let area = list.filter { $0.slot == slot }.reduce(0) { $0 + $1.area }
                let at = positions[owner]
                guard area > 0, model.containsSupport(slot - 1, at: at) else { continue }
                // The nearest within eight elements, searching shells of cells outwards until none
                // can be nearer.
                var best: (node: Int, distance: Float)?
                let centre = cell(at)
                let reach: Int32 = 8
                var ring: Int32 = 0
                while ring <= reach, best.map({ $0.distance > Float(ring - 1) * h }) ?? true {
                    for i in -ring...ring {
                        for j in -ring...ring {
                            for k in -ring...ring where max(abs(i), abs(j), abs(k)) == ring {
                                for n in grid[centre &+ SIMD3(i, j, k)] ?? []
                                where n != owner && members[n].isDisjoint(with: members[owner])
                                    && simd_dot(at - positions[n], law.across) > -1e-3 * h
                                {
                                    let distance = simd_distance(at, positions[n])
                                    if best.map({
                                        distance < $0.distance - 1e-6
                                            || (abs(distance - $0.distance) <= 1e-6 && n < $0.node)
                                    }) ?? true {
                                        best = (n, distance)
                                    }
                                }
                            }
                        }
                    }
                    ring += 1
                }
                guard let best else { continue }
                // How far the owner can slide along each axis of the joint before it leaves the
                // region.
                let axes = Anchorage.jointAxes(law.isUnder ? .zero : law.across)
                var seat = SIMD4<Float>(repeating: 0)
                for (k, direction) in [axes.along, -axes.along, axes.other, -axes.other].enumerated() {
                    var reach = Float.infinity
                    for axis in 0..<3 where abs(direction[axis]) > 1e-6 {
                        let bound = direction[axis] > 0 ? region.max[axis] : region.min[axis]
                        reach = min(reach, (bound - at[axis]) / direction[axis])
                    }
                    seat[k] = max(reach, 0) + h / 2
                }
                let reduced =
                    masses[owner] * masses[best.node] / max(masses[owner] + masses[best.node], 1e-30)
                found.append(
                    PartPairs.Pair(
                        owner: owner, partner: best.node, area: area, slot: slot, seat: seat,
                        reducedMass: reduced,
                        law: AnchorageParameters(law, material: model.material, elementSize: h)))
            }
        }
        guard !found.isEmpty else { return }
        pairs = try PartPairs(device: device, pairs: found, nodeCount: positions.count)
        for pair in found where pair.reducedMass > 0 {
            let stiffest = max(
                pair.law.stiffnessAndTension.x, pair.law.stiffnessAndTension.y,
                pair.law.closing.x > 0 ? pair.law.closing.y : 0)
            anchorFrequencySquared = max(anchorFrequencySquared, stiffest * pair.area / pair.reducedMass)
        }
    }

    /// The connections between parts of the body after the last step, those of support region
    /// `support` alone if given, or nil without any.
    public func pairSummary(support: Int? = nil) -> PartPairs.Summary? {
        guard let pairs else { return nil }
        var summary = PartPairs.Summary()
        mutateNodes { nodes in
            summary = pairs.summary(slot: support.map { $0 + 1 }, displacement: { nodes[$0].displacement })
        }
        return summary
    }

    // MARK: - State

    /// Restores the undeformed, stress-free, stationary structure.
    public func reset() {
        time = 0
        footings?.reset()
        pairs?.reset()
        failureGateBuffer.contents().storeBytes(of: 0, as: UInt32.self)
        failedAtCheckpoint = nil
        memset(flagBuffer.contents(), Int32(ElementFlag.active.rawValue), flagBuffer.length)
        memset(beamFlagBuffer.contents(), Int32(ElementFlag.active.rawValue), beamFlagBuffer.length)
        punching.reset()
        for buffer in [
            beamFibreBuffer, beamBarBuffer, beamForceBuffer, beamDisplayBuffer, punching.beamSheared,
        ] {
            memset(buffer.contents(), 0, buffer.length)
        }
        for buffer in [
            layerBuffer, barBuffer, forceBuffer, displayBuffer, contactForceBuffer, punching.punched,
            fibreStateBuffer, fibreForceBuffer,
        ]
            + barPlasticBuffers + punching.shear
        {
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
            for beam in mesh.beams {
                let share =
                    materials[beam.material].density * beam.section.x * beam.section.y * beam.length / 2
                let radius = (beam.length * beam.length + simd_length_squared(beam.section)) / 12
                for end in 0..<2 {
                    let n = Int(beam.nodes[end])
                    nodes[n].mass += share
                    nodes[n].inertia += share * radius
                }
            }
            if model.fixedBase {
                // Nodes with points of a connected footprint are held by it instead.
                let starts = fibreStartBuffer.contents().bindMemory(
                    to: UInt32.self, capacity: nodes.count + 1)
                for n in nodes.indices where abs(mesh.positions[n].z) < 1e-4 {
                    if fibreCount == 0 || starts[n + 1] == starts[n] { nodes[n].isClamped = true }
                }
            }
            for n in nodes.indices
            where model.isClampedBySupport(at: mesh.positions[n]) {
                nodes[n].isClamped = true
            }
            // A spring support holds its nodes along its edge, as the weld along it does.
            for support in model.springSupports {
                for n in nodes.indices where support.region.contains(mesh.positions[n]) {
                    nodes[n].restrain(x: support.edge == 0, y: support.edge == 1, z: support.edge == 2)
                }
            }
            // A tied node's mass and inertia move with the node it is tied to.
            for tie in mesh.ties {
                let slave = Int(tie.slave)
                let master = Int(tie.master)
                let arm = simd_length_squared(mesh.positions[slave] - mesh.positions[master])
                nodes[master].mass += nodes[slave].mass
                nodes[master].inertia += nodes[slave].inertia + nodes[slave].mass * arm
                nodes[slave].flags |= 128
            }
        }
    }

    /// Fastened sheets' links (`ShellMesh.links`): how many, and how many have let go, the sheet
    /// pulled off its screws there.
    public var linkCount: Int { mesh.links.count }
    public var linksReleased: Int {
        let records = (loadTableBuffer.contents() + linkLayout.records).bindMemory(
            to: SIMD4<Float>.self, capacity: max(6 * mesh.links.count, 1))
        return (0..<mesh.links.count).filter { records[6 * $0 + 3].w > 0.5 }.count
    }

    /// Direct access to the nodes, for setting supports and initial velocities.
    public func mutateNodes(_ body: (UnsafeMutableBufferPointer<ShellNode>) throws -> Void) rethrows {
        let pointer = nodeBuffer.contents().bindMemory(to: ShellNode.self, capacity: max(nodeCount, 1))
        try body(UnsafeMutableBufferPointer(start: pointer, count: nodeCount))
    }

    /// The connection's state after the last step, or nil when the base is clamped or free. Its
    /// counts are of points of the faces rather than nodes.
    public func anchorSummary() -> StructureSolver.AnchorSummary? {
        guard anchorStiffness != nil, fibreCount > 0 else { return nil }
        let starts = fibreStartBuffer.contents().bindMemory(to: UInt32.self, capacity: nodeCount + 1)
        let points = fibreGeometryBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: 2 * fibreCount)
        let states = fibreStateBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: fibreCount)
        let forces = fibreForceBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: fibreCount)
        var summary = StructureSolver.AnchorSummary()
        var area: Float = 0
        var centre = SIMD3<Float>.zero
        var loads: [(SIMD3<Float>, SIMD3<Float>)] = []
        mutateNodes { nodes in
            for n in 0..<nodeCount where !nodes[n].isClamped && nodes[n].flags & 384 == 0 {
                for f in Int(starts[n])..<Int(starts[n + 1]) {
                    guard let anchorage = model.connection(inSlot: fibreSlots[f]) else { continue }
                    let stiffness = anchorage.stiffness(
                        material: model.material, elementSize: model.elementSize)
                    let point = points[2 * f]
                    let arm = SIMD3(point.x, point.y, point.z)
                    let position = mesh.positions[n] + arm
                    let force = SIMD3(forces[f].x, forces[f].y, forces[f].z)
                    let remaining = anchorage.remaining(
                        peak: states[f].w, wear: states[f].z, normalStiffness: stiffness.normal)
                    let moved = nodes[n].displacement + nodes[n].rotation.act(arm) - arm
                    summary.nodes += 1
                    if remaining <= 0 { summary.separated += 1 }
                    summary.meanDamage += point.w * (1 - remaining)
                    summary.reaction += force
                    summary.maxSlip = max(summary.maxSlip, simd_length(SIMD2(states[f].x, states[f].y)))
                    // On a footing, the opening is from the footing's top as it has moved.
                    let ground = footings?.footing(ofEntity: f).map {
                        footings!.displacement(ofPointAt: position, footing: $0).z
                    }
                    summary.maxOpening = max(
                        summary.maxOpening, simd_dot(moved, anchorage.across) - (ground ?? 0))
                    summary.maxSettlement = max(summary.maxSettlement, -forces[f].w)
                    area += point.w
                    centre += point.w * position
                    loads.append((position, force))
                }
            }
        }
        guard area > 0 else { return summary }
        summary.meanDamage /= area
        centre /= area
        summary.moment = loads.reduce(.zero) { $0 + simd_cross($1.0 - centre, $1.1) }
        return summary
    }

    /// Actual bearing area of a finite support's points, excluding held or slave nodes. Read only
    /// while the GPU is idle.
    public func supportBearingArea(at support: Int) -> Float {
        guard fibreCount > 0, model.supports.indices.contains(support) else { return 0 }
        let starts = fibreStartBuffer.contents().bindMemory(to: UInt32.self, capacity: nodeCount + 1)
        let points = fibreGeometryBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: 2 * fibreCount)
        var area: Float = 0
        mutateNodes { nodes in
            for n in nodes.indices where !nodes[n].isClamped && nodes[n].flags & 384 == 0 {
                for f in Int(starts[n])..<Int(starts[n + 1]) where fibreSlots[f] == 1 + support {
                    area += points[2 * f].w
                }
            }
        }
        return area
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

    /// Whether an element beside a column head has punched through.
    public func isPunched(_ element: Int) -> Bool {
        punching.punched.contents().load(fromByteOffset: element, as: UInt8.self) & 1 != 0
    }

    /// Whether a shell's section has failed in shear, across its first or second axis.
    public func hasShearFailed(_ element: Int) -> Bool {
        punching.punched.contents().load(fromByteOffset: element, as: UInt8.self) & 6 != 0
    }

    /// Turns the check of each section's shear off (see `MemberShearBuffers`), leaving shear to
    /// the layers' and fibres' interlock and dowel action alone.
    public func disableSectionShear() {
        punching.disableSectionShear()
    }

    /// Whether a beam's section has failed in shear.
    public func beamHasShearFailed(_ beam: Int) -> Bool {
        punching.beamSheared.contents().load(fromByteOffset: beam, as: UInt8.self) != 0
    }

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
            if entries[i] & 0x8000_0000 != 0 {
                let beam = Int((entries[i] & 0x7FFF_FFFF) >> 2)
                let end = Int(entries[i] & 3)
                guard beamFlag(beam) == .active else { continue }
                let base = beamForceBuffer.contents().advanced(by: beam * 48 + end * 12)
                total += SIMD3(
                    base.load(as: Float.self), base.load(fromByteOffset: 4, as: Float.self),
                    base.load(fromByteOffset: 8, as: Float.self))
                continue
            }
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

    /// Reference centre of each element.
    public func elementCentre(_ element: Int) -> SIMD3<Float> {
        let corners = mesh.elements[element].nodes
        return (0..<4).reduce(SIMD3<Float>.zero) { $0 + mesh.positions[Int(corners[$1])] } / 4
    }

    /// Removes elements by hand, as if they had failed, chosen by their reference centres.
    public func beamFlag(_ beam: Int) -> ElementFlag {
        ElementFlag(rawValue: beamFlagBuffer.contents().load(fromByteOffset: beam, as: UInt8.self)) ?? .eroded
    }

    /// Reference midpoint of each beam.
    public func beamCentre(_ beam: Int) -> SIMD3<Float> {
        let ends = mesh.beams[beam].nodes
        return 0.5 * (mesh.positions[Int(ends.x)] + mesh.positions[Int(ends.y)])
    }

    public func erode(where shouldErode: (SIMD3<Float>) -> Bool) {
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: max(elementCount, 1))
        let beamFlags = beamFlagBuffer.contents().bindMemory(to: UInt8.self, capacity: max(beamCount, 1))
        var any = false
        for b in 0..<beamCount where beamFlags[b] == ElementFlag.active.rawValue && shouldErode(beamCentre(b))
        {
            beamFlags[b] = ElementFlag.eroded.rawValue
            any = true
        }
        for e in 0..<elementCount
        where flags[e] == ElementFlag.active.rawValue && shouldErode(elementCentre(e)) {
            flags[e] = ElementFlag.eroded.rawValue
            any = true
        }
        if any { failureGateBuffer.contents().storeBytes(of: 1, as: UInt32.self) }
    }

    public var hasFailed: Bool { failureGateBuffer.contents().load(as: UInt32.self) != 0 }
    /// Whether something had failed as of the coupled solver's last checkpoint, which then
    /// stands in for `hasFailed` in deciding what to encode, so that contact and debris join at
    /// a step that does not depend on how the steps were batched. Nil on its own.
    var failedAtCheckpoint: Bool?
    /// What decides whether contact and debris loading are encoded.
    var encodesAsFailed: Bool { failedAtCheckpoint ?? hasFailed }

    /// Total linear momentum in kg m/s.
    public func momentum() -> SIMD3<Double> {
        var total = SIMD3<Double>.zero
        mutateNodes { nodes in
            // Tied nodes' mass is counted in the nodes they are tied to.
            for node in nodes where node.flags & 128 == 0 {
                total += SIMD3<Double>(node.velocity) * Double(node.mass)
            }
        }
        return total
    }

    /// Kinetic energy of translation and rotation, in joules.
    public func kineticEnergy() -> Double {
        var total = 0.0
        mutateNodes { nodes in
            for node in nodes where node.flags & 128 == 0 {
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
        let beamDamage = beamDisplayBuffer.contents().bindMemory(to: Float.self, capacity: max(beamCount, 1))
        for (b, beam) in mesh.beams.enumerated() {
            if beamFlag(b) == .active {
                summary.activeElements += 1
                summary.maxDamage = max(summary.maxDamage, beamDamage[b])
                for end in 0..<2 { attached[Int(beam.nodes[end])] = true }
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
            barLayoutBuffer, beamBuffer, beamFlagBuffer, beamDisplayBuffer, beamFibreBuffer, beamBarBuffer,
            beamForceBuffer, beamBarLayoutBuffer,
            barBuffer, forceBuffer, incidenceStartBuffer, incidenceBuffer, contactHeadBuffer,
            contactSlotBuffer, contactMovedBuffer,
            contactForceBuffer,
        ].reduce(0) { $0 + $1.length }
    }

    private func writeLoadTable() {
        guard let appliedLoad else { return }
        let table = loadTableBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: Self.maxLoadPoints)
        for (n, point) in appliedLoad.history.prefix(Self.maxLoadPoints).enumerated() {
            table[n] = point
        }
        let stored = (loadTableBuffer.contents() + Self.maxLoadPoints * 8).bindMemory(
            to: Float.self, capacity: elementCount + nodeCount)
        if let shares = appliedLoad.elementShares {
            for e in 0..<elementCount { stored[e] = e < shares.count ? shares[e] : 0 }
        } else if appliedLoad.nodeShares != nil {
            // On the nodes alone.
            for e in 0..<elementCount { stored[e] = 0 }
        }
        if let shares = appliedLoad.nodeShares {
            for n in 0..<nodeCount { stored[elementCount + n] = n < shares.count ? shares[n] : 0 }
        }
    }

    // MARK: - Stepping

    /// Largest stable time step in seconds: the time a compression wave in the plane takes to
    /// cross the smallest element, times `timeStepSafety`.
    /// The time step every substep takes: the stable one, unless another body sharing the
    /// substeps needs a shorter one.
    public var criticalTimeStep: Float { stepOverride ?? stableTimeStep }
    /// Set by a body this one is tied to, so both take the same steps.
    public var stepOverride: Float?

    /// Largest stable time step of this body alone, in seconds.
    public var stableTimeStep: Float {
        var step = Float.infinity
        for element in mesh.elements {
            let speed = materials[element.material].plateWaveSpeed
            step = min(step, min(element.size.x, element.size.y) / speed)
        }
        for beam in mesh.beams {
            let material = materials[beam.material]
            step = min(step, beam.length / (material.youngsModulus / material.density).squareRoot())
        }
        let shells = timeStepSafety * (step.isFinite ? step : 1e-4)
        // A node on a stiff connection to the ground, as for solid elements: its frequency on the
        // connection adds to the highest the elements alone can give it, about 2 / step.
        let footingFrequencySquared = footings?.frequencySquared ?? 0
        guard anchorFrequencySquared > 0 || footingFrequencySquared > 0, step.isFinite else { return shells }
        let elementFrequency = 2 / step
        let frequency =
            (elementFrequency * elementFrequency + anchorFrequencySquared + footingFrequencySquared)
            .squareRoot()
        let damping = (1 + contactDamping * contactDamping).squareRoot() - contactDamping
        return min(shells, 0.9 * 2 * damping / frequency)
    }

    func encodeDebrisAreas(_ encoder: MTLComputeCommandEncoder, fluid: StructureSolver.FluidBinding) {
        var uniforms = makeUniforms(fluid: fluid)
        let group = MTLSize(width: elementPipeline.threadExecutionWidth, height: 1, depth: 1)
        if nodeCount > 0, uniforms.debrisLoading != 0, encodesAsFailed, let area = fluid.debrisArea {
            encoder.setComputePipelineState(debrisAreaPipeline)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(referenceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(beamFlagBuffer, offset: 0, index: 3)
            encoder.setBuffer(incidenceStartBuffer, offset: 0, index: 4)
            encoder.setBuffer(incidenceBuffer, offset: 0, index: 5)
            encoder.setBuffer(fluid.mask, offset: 0, index: 6)
            encoder.setBuffer(area, offset: 0, index: 7)
            encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 8)
            encoder.setBuffer(fluid.control, offset: 0, index: 9)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 10)
            encoder.setBuffer(fluid.couplingMap ?? placeholderBuffer, offset: 0, index: 11)
            encoder.dispatchThreads(
                MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
        }
    }

    /// Encodes `count` substeps. With a fluid binding, the substeps share out the fluid's current
    /// time step and apply blast loads; without one, each advances by `criticalTimeStep`.
    public func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: StructureSolver.FluidBinding?
    ) {
        encodeSubsteps(
            encoder, substeps: 0..<count, fluid: fluid, prelude: true, interface: nil, beforeNodes: nil)
    }

    /// Encodes the substeps in `substeps`, with the once-per-batch work first if `prelude`. With
    /// an interface, nodes tied into a solid body write their force and moment to `loads`, at
    /// the link index in `link`, instead of moving. `beforeNodes` runs after each substep's
    /// contact pass, with its uniforms.
    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, substeps: Range<Int>, fluid: StructureSolver.FluidBinding?,
        prelude: Bool, interface: (link: MTLBuffer, loads: MTLBuffer)?,
        beforeNodes: ((ShellUniforms) -> Void)?, afterNodes: ((Int) -> Void)? = nil
    ) {
        guard elementCount + beamCount > 0 else { return }
        var uniforms = makeUniforms(fluid: fluid)
        var parameters = materials.map {
            StructureSolver.parameters(for: $0, elementSize: model.elementSize)
        }
        let group = MTLSize(width: elementPipeline.threadExecutionWidth, height: 1, depth: 1)
        // Until something has failed there is nothing to collide.
        let encodeContact = contactMode == .always || (contactMode == .afterFailure && encodesAsFailed)

        // Loose debris adds up its frontal area in each air cell before the substeps.
        if prelude, let fluid, !fluid.debrisAreasPrepared { encodeDebrisAreas(encoder, fluid: fluid) }

        for substep in substeps {
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
            encoder.setBuffer(fluid?.refinement?.patchOfTile ?? placeholderBuffer, offset: 0, index: 20)
            encoder.setBuffer(fluid?.refinement?.fine ?? placeholderBuffer, offset: 0, index: 21)
            encoder.setBuffer(fluid?.refinement?.mask ?? placeholderBuffer, offset: 0, index: 22)
            encoder.setBuffer(punching.strength, offset: 0, index: 23)
            encoder.setBuffer(punching.punched, offset: 0, index: 24)
            encoder.setBuffer(punching.ringOfElement, offset: 0, index: 25)
            encoder.setBuffer(punching.ringStart, offset: 0, index: 26)
            encoder.setBuffer(punching.ringMember, offset: 0, index: 27)
            encoder.setBuffer(punching.shear[substep % 2], offset: 0, index: 28)
            encoder.setBuffer(punching.shear[1 - substep % 2], offset: 0, index: 29)
            encoder.setBuffer(punching.section, offset: 0, index: 30)
            if elementCount > 0 {
                // Four threads per element, one per in-plane point.
                encoder.dispatchThreads(
                    MTLSize(width: 4 * elementCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            if beamCount > 0 {
                encoder.setComputePipelineState(beamPipeline)
                encoder.setBuffer(beamFibreBuffer, offset: 0, index: 0)
                encoder.setBuffer(beamForceBuffer, offset: 0, index: 1)
                encoder.setBuffer(beamFlagBuffer, offset: 0, index: 2)
                encoder.setBuffer(nodeBuffer, offset: 0, index: 3)
                encoder.setBuffer(referenceBuffer, offset: 0, index: 4)
                encoder.setBuffer(beamBuffer, offset: 0, index: 5)
                encoder.setBuffer(beamBarBuffer, offset: 0, index: 6)
                encoder.setBytes(
                    &parameters, length: parameters.count * MemoryLayout<MaterialParameters>.stride, index: 7)
                encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 8)
                encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 9)
                encoder.setBuffer(fluid?.state ?? placeholderBuffer, offset: 0, index: 10)
                encoder.setBuffer(fluid?.mask ?? placeholderBuffer, offset: 0, index: 11)
                encoder.setBuffer(failureGateBuffer, offset: 0, index: 12)
                encoder.setBuffer(beamDisplayBuffer, offset: 0, index: 13)
                encoder.setBuffer(beamBarLayoutBuffer, offset: 0, index: 14)
                encoder.setBuffer(fluid?.refinement?.patchOfTile ?? placeholderBuffer, offset: 0, index: 15)
                encoder.setBuffer(fluid?.refinement?.fine ?? placeholderBuffer, offset: 0, index: 16)
                encoder.setBuffer(fluid?.refinement?.mask ?? placeholderBuffer, offset: 0, index: 17)
                encoder.setBuffer(punching.beamSection, offset: 0, index: 18)
                encoder.setBuffer(punching.beamSheared, offset: 0, index: 19)
                encoder.setBuffer(beamBowBuffer ?? placeholderBuffer, offset: 0, index: 20)
                encoder.dispatchThreads(
                    MTLSize(width: beamCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            }

            if encodeContact {
                stamp = stamp % 0x1FFF_FFF0 + 1
                uniforms.stamp = stamp
                for pipeline in contactPipelines where !(contactTableOnly && pipeline === contactPipelines[2])
                {
                    encoder.setComputePipelineState(pipeline)
                    encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
                    encoder.setBuffer(referenceBuffer, offset: 0, index: 1)
                    encoder.setBuffer(contactHeadBuffer, offset: 0, index: 2)
                    encoder.setBuffer(contactSlotBuffer, offset: 0, index: 3)
                    encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 4)
                    encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 5)
                    encoder.setBuffer(failureGateBuffer, offset: 0, index: 6)
                    encoder.setBuffer(contactForceBuffer, offset: 0, index: 7)
                    encoder.setBuffer(contactMovedBuffer, offset: 0, index: 8)
                    encoder.dispatchThreads(
                        MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
                }
            }
            if let pairs {
                uniforms.contactEncoded = encodeContact && !contactTableOnly ? 1 : 0
                encoder.setComputePipelineState(pairPipelines[0])
                encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
                encoder.setBuffer(pairs.nodes, offset: 0, index: 1)
                encoder.setBuffer(pairs.state, offset: 0, index: 2)
                encoder.setBuffer(pairs.seats, offset: 0, index: 3)
                encoder.setBuffer(pairs.laws, offset: 0, index: 4)
                encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 5)
                encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 6)
                encoder.dispatchThreads(
                    MTLSize(width: pairs.count, height: 1, depth: 1), threadsPerThreadgroup: group)
                encoder.setComputePipelineState(pairPipelines[1])
                encoder.setBuffer(pairs.state, offset: 0, index: 0)
                encoder.setBuffer(pairs.nodeStart, offset: 0, index: 1)
                encoder.setBuffer(pairs.nodeEntries, offset: 0, index: 2)
                encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 3)
                encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 4)
                encoder.setBuffer(failureGateBuffer, offset: 0, index: 5)
                encoder.setBuffer(contactForceBuffer, offset: 0, index: 6)
                encoder.dispatchThreads(
                    MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            beforeNodes?(uniforms)

            if let linkPipeline {
                encoder.setComputePipelineState(linkPipeline)
                encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
                encoder.setBuffer(loadTableBuffer, offset: 0, index: 1)
                encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 2)
                encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 3)
                encoder.dispatchThreads(
                    MTLSize(width: mesh.links.count, height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            let down = gravityDirection.x == 0 && gravityDirection.y == 0 && gravityDirection.z < 0
            encoder.setComputePipelineState(down ? nodePipeline : turnedNodes ?? nodePipeline)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
            encoder.setBuffer(forceBuffer, offset: 0, index: 1)
            encoder.setBuffer(flagBuffer, offset: 0, index: 2)
            encoder.setBuffer(incidenceStartBuffer, offset: 0, index: 3)
            encoder.setBuffer(incidenceBuffer, offset: 0, index: 4)
            encoder.setBuffer(referenceBuffer, offset: 0, index: 5)
            encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 6)
            encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 7)
            encoder.setBuffer(contactForceBuffer, offset: 0, index: 8)
            encoder.setBuffer(failureGateBuffer, offset: 0, index: 9)
            encoder.setBuffer(beamForceBuffer, offset: 0, index: 10)
            encoder.setBuffer(beamFlagBuffer, offset: 0, index: 11)
            encoder.setBuffer(tiedStartBuffer, offset: 0, index: 12)
            encoder.setBuffer(tiedBuffer, offset: 0, index: 13)
            encoder.setBuffer(fluid?.state ?? placeholderBuffer, offset: 0, index: 14)
            encoder.setBuffer(fluid?.mask ?? placeholderBuffer, offset: 0, index: 15)
            encoder.setBuffer(fluid?.exchange ?? placeholderBuffer, offset: 0, index: 16)
            encoder.setBuffer(fluid?.debrisArea ?? placeholderBuffer, offset: 0, index: 17)
            encoder.setBuffer(interface?.link ?? placeholderBuffer, offset: 0, index: 18)
            encoder.setBuffer(interface?.loads ?? placeholderBuffer, offset: 0, index: 19)
            encoder.setBuffer(fibreStartBuffer, offset: 0, index: 20)
            encoder.setBuffer(fibreGeometryBuffer, offset: 0, index: 21)
            encoder.setBuffer(fibreStateBuffer, offset: 0, index: 22)
            encoder.setBuffer(fibreForceBuffer, offset: 0, index: 23)
            encoder.setBuffer(fibreLawBuffer, offset: 0, index: 24)
            encoder.setBuffer(fluid?.couplingMap ?? placeholderBuffer, offset: 0, index: 25)
            encoder.setBuffer(footings?.footingOfBuffer ?? placeholderBuffer, offset: 0, index: 26)
            encoder.setBuffer(footings?.constantBuffer ?? placeholderBuffer, offset: 0, index: 27)
            encoder.setBuffer(footings?.stateBuffer ?? placeholderBuffer, offset: 0, index: 28)
            encoder.setBuffer(footings?.linkBuffer ?? placeholderBuffer, offset: 0, index: 29)
            encoder.setBuffer(loadTableBuffer, offset: 0, index: 30)
            encoder.dispatchThreads(
                MTLSize(width: nodeCount, height: 1, depth: 1), threadsPerThreadgroup: group)
            if !mesh.ties.isEmpty {
                var ties = UInt32(mesh.ties.count)
                encoder.setComputePipelineState(tiePipeline)
                encoder.setBuffer(nodeBuffer, offset: 0, index: 0)
                encoder.setBuffer(referenceBuffer, offset: 0, index: 1)
                encoder.setBuffer(tieBuffer, offset: 0, index: 2)
                encoder.setBytes(&ties, length: 4, index: 3)
                encoder.setBytes(&uniforms, length: MemoryLayout<ShellUniforms>.stride, index: 4)
                encoder.setBuffer(fluid?.control ?? placeholderBuffer, offset: 0, index: 5)
                encoder.dispatchThreads(
                    MTLSize(width: mesh.ties.count, height: 1, depth: 1), threadsPerThreadgroup: group)
            }
            footings?.encode(
                encoder,
                uniforms: FootingSystem.Uniforms(
                    fixedStep: uniforms.fixedStep, criticalStep: criticalTimeStep, substep: UInt32(substep),
                    gravity: gravity, damping: damping, footings: 0),
                control: fluid?.control ?? placeholderBuffer)
            afterNodes?(substep)
        }
    }

    /// The footings under the base after the last step, in the order of their connections (the
    /// ground's, then the support regions'); empty without any.
    public func footingSummaries() -> [FootingSummary] { footings?.summaries() ?? [] }

    /// Advances the structure on its own by `steps` steps of `criticalTimeStep`, blocking until done.
    public func advance(steps: Int) {
        var remaining = steps
        while remaining > 0 {
            // Up to 2,000 substeps at a time, each at its time from the start of the 2,000 and
            // with what to encode decided there, as when the 2,000 were one command buffer; they
            // go to the GPU in buffers of about `BlastSolver.commandBufferTarget` of its time, so
            // that none starves the window server. The substeps are the same however they are cut.
            let count = min(remaining, 2000)
            let checkpoint = failedAtCheckpoint
            failedAtCheckpoint = encodesAsFailed
            defer { failedAtCheckpoint = checkpoint }
            var done = 0
            while done < count {
                let part = gpuSubsteps.part(count - done)
                guard let commandBuffer = commandQueue.makeCommandBuffer(),
                    let encoder = commandBuffer.makeComputeCommandEncoder()
                else { return }
                encodeSubsteps(
                    encoder, substeps: done..<(done + part), fluid: nil, prelude: done == 0, interface: nil,
                    beforeNodes: nil)
                encoder.endEncoding()
                commandBuffer.commit()
                commandBuffer.waitUntilCompleted()
                gpuSubsteps.measure(commandBuffer, steps: part)
                done += part
            }
            time += Double(count) * Double(criticalTimeStep)
            remaining -= count
        }
    }

    /// The GPU's time for a substep lately, to size `advance`'s command buffers.
    private var gpuSubsteps = GPUStepRate()

    /// The GPU time each of `advance`'s command buffers aims at, `BlastSolver.commandBufferTarget`
    /// unless set; the substeps are the same whatever it is.
    public var commandBufferSeconds: Double {
        get { gpuSubsteps.target }
        set { gpuSubsteps.target = newValue }
    }

    /// Points and weights through the thickness: the `layers`-point Gauss-Legendre rule, or, with
    /// timber, Gauss-Lobatto points in each of its lamellae (in each piece between any material's
    /// lamellae): three in each of several, which is exact for their elastic bending where one rule
    /// over the whole thickness would not be, their stiffness jumping from one to the next, and
    /// `layers` (three to five) in one. Lobatto's points include the faces, where timber breaks
    /// in bending; Legendre's innermost-to-the-face point sits 14% in from it in a 3-ply panel's
    /// outer lamella, which broke 12% late.
    static func thicknessRule(layers: Int, materials: [StructureMaterial]) -> [SIMD2<Float>] {
        guard materials.contains(where: { $0.model == .timber }) else { return gaussLegendre(layers) }
        var tops: [Float] = []
        for material in materials where material.model == .timber {
            guard let timber = material.timber, timber.lamellae.count > 1 else { continue }
            for top in timber.lamellaTops.dropLast() where !tops.contains(where: { abs($0 - top) < 1e-4 }) {
                tops.append(top)
            }
        }
        let bounds = [-1] + tops.sorted() + [1]
        let rule = gaussLobatto(tops.isEmpty ? min(max(layers, 3), 5) : 3)
        // A point on a lamella's face is nudged just inside it, so that the kernel finds which
        // lamella it belongs to.
        return zip(bounds, bounds.dropFirst()).flatMap { low, high in
            rule.map {
                let inset = 1e-5 * (high - low)
                let zeta = min(max(low + (high - low) * (1 + $0.x) / 2, low + inset), high - inset)
                return SIMD2(zeta, $0.y * (high - low) / 2)
            }
        }
    }

    /// Points and weights of the n-point Gauss-Lobatto rule on [-1, 1], for 3 to 5 points.
    static func gaussLobatto(_ n: Int) -> [SIMD2<Float>] {
        switch n {
        case 3: return [SIMD2(-1, 1.0 / 3), SIMD2(0, 4.0 / 3), SIMD2(1, 1.0 / 3)]
        case 4:
            let x = Float(1 / 5.0.squareRoot())
            return [SIMD2(-1, 1.0 / 6), SIMD2(-x, 5.0 / 6), SIMD2(x, 5.0 / 6), SIMD2(1, 1.0 / 6)]
        default:
            let x = Float((3 / 7.0).squareRoot())
            return [
                SIMD2(-1, 0.1), SIMD2(-x, 49.0 / 90), SIMD2(0, 32.0 / 45), SIMD2(x, 49.0 / 90), SIMD2(1, 0.1),
            ]
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
        uniforms.crackSlip = model.crackSlip ? 1 : 0
        uniforms.removesFragments = model.removesFragments ? 1 : 0
        if fibreCount > 0 { uniforms.anchored = 1 }
        uniforms.pairs = UInt32(pairs?.count ?? 0)
        if footings != nil { uniforms.footings = 1 }
        if let anchorStiffness, let anchorage = model.baseAnchorage, fibreCount > 0 {
            uniforms.anchorNormalStiffness = anchorStiffness.normal
            uniforms.anchorShearStiffness = anchorStiffness.shear
            uniforms.anchorTension = anchorage.tensileStrength
            uniforms.anchorPlateau = anchorage.tensionPlateau
            uniforms.anchorOpening = anchorage.tensionOpening
            uniforms.anchorCohesion = anchorage.cohesion
            uniforms.anchorCohesionSlip = anchorage.cohesionSlip
            uniforms.anchorFriction = anchorage.friction
        }
        uniforms.elementCount = UInt32(elementCount)
        uniforms.beamCount = UInt32(beamCount)
        uniforms.elementSize = model.elementSize
        uniforms.nodeCount = UInt32(nodeCount)
        uniforms.layers = UInt32(layers)
        uniforms.barSlots = UInt32(barSlots)
        uniforms.criticalStep = criticalTimeStep
        uniforms.gravity = gravity
        let down = simd_normalize(gravityDirection)
        (uniforms.gravityX, uniforms.gravityY, uniforms.gravityZ) = (down.x, down.y, down.z)
        uniforms.damping = damping
        uniforms.groundFriction = groundContact ? 8 : -1
        uniforms.rateFilter = 1 / (model.strainRateWindow ?? 50 * criticalTimeStep)
        uniforms.contactMode = contactMode.rawValue
        uniforms.contactNx = UInt32(contactPeriod.x)
        uniforms.contactNy = UInt32(contactPeriod.y)
        uniforms.contactNz = UInt32(contactPeriod.z)
        uniforms.contactRadius = model.elementSize
        (uniforms.gridOriginX, uniforms.gridOriginY, uniforms.gridOriginZ) =
            (contactOrigin.x, contactOrigin.y, contactOrigin.z)
        uniforms.contactStiffness = contactStiffness / (criticalTimeStep * criticalTimeStep)
        uniforms.contactDamping = contactDamping
        uniforms.contactFriction = contactFriction
        // Nodes of one element, or of elements meeting at a corner, never repel.
        uniforms.neighbourDistance = 1.5 * model.elementSize
        if let appliedLoad, fluid == nil {
            uniforms.loadCount = UInt32(min(appliedLoad.history.count, Self.maxLoadPoints))
            uniforms.loadFace = UInt32(2 * appliedLoad.axis + (appliedLoad.positiveSide ? 1 : 0))
            uniforms.loadShares = appliedLoad.elementShares == nil && appliedLoad.nodeShares == nil ? 0 : 1
            uniforms.loadNodeShares = appliedLoad.nodeShares == nil ? 0 : 1
        }
        uniforms.linkCount = UInt32(mesh.links.count)
        uniforms.linkRecords = UInt32(linkLayout.records)
        uniforms.linkStarts = UInt32(linkLayout.starts)
        uniforms.linkEntries = UInt32(linkLayout.entries)
        if let fluid {
            uniforms.coupled = 1
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
            // Debris is loaded only where the air can be given the reaction.
            if debrisDrag, fluid.exchange != nil, fluid.debrisArea != nil, let region = fluid.exchangeRegion {
                uniforms.debrisLoading = 1
                uniforms.couplingMapCount = fluid.couplingMapCount
                (uniforms.exchangeX, uniforms.exchangeY, uniforms.exchangeZ) =
                    (Int32(region.origin.x), Int32(region.origin.y), Int32(region.origin.z))
                (uniforms.exchangeNx, uniforms.exchangeNy, uniforms.exchangeNz) =
                    (Int32(region.dims.x), Int32(region.dims.y), Int32(region.dims.z))
            }
        } else {
            uniforms.fixedStep = criticalTimeStep
        }
        return uniforms
    }
}

/// The GPU's view of members failing in shear. Punching at column heads: each element's punching
/// strength (zero away from a column head) and its state as a member, one byte each (bit 0
/// punched, bits 1 and 2 its section failed in shear across its first and second axes); each
/// element's ring around a column head (or -1) and the rings' members; and each element's mean
/// shear through its thickness, written in alternate substeps, so that a ring punches on the
/// average over its members. Sections: for each shell, across its two axes, and for each beam,
/// across its two sides, d_v over the depth and the size factor of the simplified modified
/// compression field theory (zero for other materials); and whether each beam's section has
/// failed, one byte each.
struct MemberShearBuffers {
    let strength: MTLBuffer
    let punched: MTLBuffer
    let ringOfElement: MTLBuffer
    let ringStart: MTLBuffer
    let ringMember: MTLBuffer
    let shear: [MTLBuffer]
    let section: MTLBuffer
    let beamSection: MTLBuffer
    let beamSheared: MTLBuffer

    /// d_v over the depth, and the size factor, for a section of depth `depth` whose outermost
    /// bars lie at `bars` (from -1 to 1 across it, or nil for none), of `material`, with a
    /// ratio `stirrups` of stirrups. d is to the outermost bars (half the depth beyond the
    /// middle by their position), d_v = max(0.9 d, 0.72 h); without the minimum of stirrups,
    /// 0.06 sqrt(fc) / fy, the size factor is 1300 / (1000 + s_ze), s_ze = 35 d_v / (15 + a_g)
    /// in mm (at least 0.85 d_v), a_g the aggregate size (none above 70 MPa).
    static func sectionFactors(depth: Float, bars: Float?, material: StructureMaterial, stirrups: Float)
        -> SIMD2<Float>
    {
        let d = 0.5 * depth * (1 + (bars ?? 0.6))
        let dv = max(0.9 * d, 0.72 * depth)
        let fc = material.compressiveStrength / 1e6
        let fy = (material.steel?.yieldStress ?? 0) / 1e6
        let enough = fy > 0 && stirrups * fy >= 0.06 * fc.squareRoot()
        var size: Float = 1
        if !enough {
            let aggregate = fc > 70 ? 0 : material.aggregateSize * 1000
            let spacing = max(35 * dv * 1000 / (15 + aggregate), 0.85 * dv * 1000)
            size = 1300 / (1000 + spacing)
        }
        return SIMD2(dv / depth, size)
    }

    /// `checksBeams` false leaves beams' sections unchecked, as the impulsive regime's defaults have it.
    init(
        device: MTLDevice, mesh: ShellMesh, materials: [StructureMaterial], shells: Bool,
        checksBeams: Bool = true
    ) throws {
        let elements = mesh.elements.count
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        strength = try buffer(elements * 4, "shell punching strengths")
        if !mesh.punching.isEmpty {
            strength.contents().copyMemory(from: mesh.punching, byteCount: mesh.punching.count * 4)
        }
        punched = try buffer(elements, "shell punched")
        var ringOf = [Int32](repeating: -1, count: elements)
        var starts: [UInt32] = [0]
        var members: [UInt32] = []
        for (r, ring) in mesh.punchingRings.enumerated() {
            for e in ring { ringOf[e] = Int32(r) }
            members += ring.map { UInt32($0) }
            starts.append(UInt32(members.count))
        }
        ringOfElement = try buffer(elements * 4, "shell punching ring of element")
        if !ringOf.isEmpty {
            ringOfElement.contents().copyMemory(from: ringOf, byteCount: ringOf.count * 4)
        }
        ringStart = try buffer(starts.count * 4, "shell punching ring starts")
        ringStart.contents().copyMemory(from: starts, byteCount: starts.count * 4)
        ringMember = try buffer(members.count * 4, "shell punching ring members")
        if !members.isEmpty {
            ringMember.contents().copyMemory(from: members, byteCount: members.count * 4)
        }
        shear = [
            try buffer(elements * 4, "shell ring shear, even"),
            try buffer(elements * 4, "shell ring shear, odd"),
        ]
        // Two vectors per element: its section's factors, then the shear it carries over its
        // strength across each axis, averaged over time (see `Shell.metal`).
        var sections = [SIMD4<Float>](repeating: .zero, count: 2 * elements)
        for (e, element) in mesh.elements.enumerated() {
            let material = materials[element.material]
            guard shells, material.model == .concrete, !mesh.punchingZone[e] else { continue }
            var factors = SIMD4<Float>.zero
            for j in 0..<2 {
                let outermost = element.bars.filter { $0[1 + j] > 0 }.map { abs($0.x) }.max()
                let f = Self.sectionFactors(
                    depth: element.thickness, bars: outermost, material: material, stirrups: 0)
                factors[2 * j] = f.x
                factors[2 * j + 1] = f.y
            }
            sections[2 * e] = factors
        }
        section = try buffer(2 * elements * 16, "shell sections")
        if !sections.isEmpty {
            section.contents().copyMemory(from: sections, byteCount: sections.count * 16)
        }
        let beams = mesh.beams.count
        var beamSections = [SIMD4<Float>](repeating: .zero, count: 2 * beams)
        for (b, beam) in mesh.beams.enumerated() where checksBeams {
            let material = materials[beam.material]
            guard material.model == .concrete else { continue }
            var factors = SIMD4<Float>.zero
            for j in 0..<2 {
                let outermost = beam.bars.map { abs($0[j]) }.max()
                let f = Self.sectionFactors(
                    depth: beam.section[j], bars: outermost, material: material, stirrups: beam.tieRatio)
                factors[2 * j] = f.x
                factors[2 * j + 1] = f.y
            }
            beamSections[2 * b] = factors
        }
        beamSection = try buffer(2 * beams * 16, "beam sections")
        if !beamSections.isEmpty {
            beamSection.contents().copyMemory(from: beamSections, byteCount: beamSections.count * 16)
        }
        beamSheared = try buffer(beams, "beam sheared")
    }

    /// Clears the time-averaged shear of every section, for a restart.
    func reset() {
        for buffer in [section, beamSection] {
            let vectors = buffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: buffer.length / 16)
            for n in stride(from: 1, to: buffer.length / 16, by: 2) { vectors[n] = .zero }
        }
    }

    /// Turns the sectional shear check off: shells and beams then carry shear only through their
    /// layers' and fibres' interlock and dowel action.
    func disableSectionShear() {
        for buffer in [section, beamSection] {
            memset(buffer.contents(), 0, buffer.length)
        }
    }
}
