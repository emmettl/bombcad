import Foundation
import simd

/// Layout matches `ShellUniforms` in `Shell.metal`.
package struct ShellUniforms {
    package var elementCount: UInt32 = 0
    package var nodeCount: UInt32 = 0
    package var layers: UInt32 = 0
    package var barSlots: UInt32 = 0
    package var substep: UInt32 = 0
    package var criticalStep: Float = 0
    package var fixedStep: Float = 0
    package var gravity: Float = 0
    package var damping: Float = 0
    package var ambientPressure: Float = 0
    package var fluidGamma: Float = 0
    package var fluidCell: Float = 0
    package var fluidNx: UInt32 = 0
    package var fluidNy: UInt32 = 0
    package var fluidNz: UInt32 = 0
    package var coupled: UInt32 = 0
    package var groundFriction: Float = -1
    package var rateFilter: Float = 0
    package var loadTime: Float = 0
    package var loadCount: UInt32 = 0
    package var loadFace: UInt32 = 0
    var shearFactor: Float = 5.0 / 6.0
    package var contactMode: UInt32 = 0
    package var stamp: UInt32 = 0
    package var contactNx: UInt32 = 1
    package var contactNy: UInt32 = 1
    package var contactNz: UInt32 = 1
    package var contactRadius: Float = 1
    package var gridOriginX: Float = 0
    package var gridOriginY: Float = 0
    package var gridOriginZ: Float = 0
    package var contactStiffness: Float = 0
    package var contactDamping: Float = 0
    package var contactFriction: Float = 0
    package var neighbourDistance: Float = 0
    package var beamCount: UInt32 = 0
    package var elementSize: Float = 0
    package var debrisLoading: UInt32 = 0
    package var exchangeX: Int32 = 0
    package var exchangeY: Int32 = 0
    package var exchangeZ: Int32 = 0
    package var exchangeNx: Int32 = 0
    package var exchangeNy: Int32 = 0
    package var exchangeNz: Int32 = 0
    package var fluidAirModel: UInt32 = 0
    package var fluidRefine: UInt32 = 0
    package var fluidBlocksX: UInt32 = 0
    package var fluidBlocksY: UInt32 = 0
    package var crackSlip: UInt32 = 0
    package var anchored: UInt32 = 0
    package var anchorNormalStiffness: Float = 0
    package var anchorShearStiffness: Float = 0
    package var anchorTension: Float = 0
    package var anchorPlateau: Float = 0
    package var anchorOpening: Float = 0
    package var anchorCohesion: Float = 0
    package var anchorCohesionSlip: Float = 0
    package var anchorFriction: Float = 0
    package var couplingMapCount: UInt32 = 0
    package var footings: UInt32 = 0
    package var fluidDeepRatio: UInt32 = 0
    package var fluidDeepBlocksX: UInt32 = 0
    package var fluidDeepBlocksY: UInt32 = 0
    package var fluidDeepPatchOffset: UInt32 = 0
    package var fluidDeepCellOffset: UInt32 = 0
    package var gravityX: Float = 0
    package var gravityY: Float = 0
    package var gravityZ: Float = -1
    package var removesFragments: UInt32 = 0
    /// 1 when the applied pressure acts on each element by its share, stored after the table.
    package var loadShares: UInt32 = 0
    /// 1 when the applied load also acts on nodes by their shares, after the elements'.
    package var loadNodeShares: UInt32 = 0
    /// Fastened sheets' links (`ShellMesh.Link`): how many, and where in the load table's buffer
    /// (bytes) their records, each node's first entry and the entries begin.
    package var linkCount: UInt32 = 0
    package var linkRecords: UInt32 = 0
    package var linkStarts: UInt32 = 0
    package var linkEntries: UInt32 = 0
    /// Connections between two parts of the body (`Anchorage.betweenParts`).
    package var pairs: UInt32 = 0
    /// 1 when contact's forces were found this substep (if it is on).
    package var contactEncoded: UInt32 = 0
    /// Panes of laminated glass that can fragment (the solids), or 0 (`MaterialParameters.fragments`).
    package var fragmentPanes: UInt32 = 0
    /// Steel connections' hinges (`ShellMesh.Hinge`), and where their data begin in the load table
    /// (bytes): eight records a hinge, then each node's first entry, then the entries.
    package var hingeCount: UInt32 = 0
    package var hingeRecords: UInt32 = 0
    package var hingeStarts: UInt32 = 0
    package var hingeEntries: UInt32 = 0
    /// With timber shells beside others, the through-thickness rule holds the others' points first,
    /// `legendrePoints` of them, then the timber's, `timberPoints` (`thicknessRule`); 0: one rule.
    package var legendrePoints: UInt32 = 0
    package var timberPoints: UInt32 = 0

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        elementCount: UInt32 = 0,
        nodeCount: UInt32 = 0,
        layers: UInt32 = 0,
        barSlots: UInt32 = 0,
        substep: UInt32 = 0,
        criticalStep: Float = 0,
        fixedStep: Float = 0,
        gravity: Float = 0,
        damping: Float = 0,
        ambientPressure: Float = 0,
        fluidGamma: Float = 0,
        fluidCell: Float = 0,
        fluidNx: UInt32 = 0,
        fluidNy: UInt32 = 0,
        fluidNz: UInt32 = 0,
        coupled: UInt32 = 0,
        groundFriction: Float = -1,
        rateFilter: Float = 0,
        loadTime: Float = 0,
        loadCount: UInt32 = 0,
        loadFace: UInt32 = 0,
        shearFactor: Float = 5.0 / 6.0,
        contactMode: UInt32 = 0,
        stamp: UInt32 = 0,
        contactNx: UInt32 = 1,
        contactNy: UInt32 = 1,
        contactNz: UInt32 = 1,
        contactRadius: Float = 1,
        gridOriginX: Float = 0,
        gridOriginY: Float = 0,
        gridOriginZ: Float = 0,
        contactStiffness: Float = 0,
        contactDamping: Float = 0,
        contactFriction: Float = 0,
        neighbourDistance: Float = 0,
        beamCount: UInt32 = 0,
        elementSize: Float = 0,
        debrisLoading: UInt32 = 0,
        exchangeX: Int32 = 0,
        exchangeY: Int32 = 0,
        exchangeZ: Int32 = 0,
        exchangeNx: Int32 = 0,
        exchangeNy: Int32 = 0,
        exchangeNz: Int32 = 0,
        fluidAirModel: UInt32 = 0,
        fluidRefine: UInt32 = 0,
        fluidBlocksX: UInt32 = 0,
        fluidBlocksY: UInt32 = 0,
        crackSlip: UInt32 = 0,
        anchored: UInt32 = 0,
        anchorNormalStiffness: Float = 0,
        anchorShearStiffness: Float = 0,
        anchorTension: Float = 0,
        anchorPlateau: Float = 0,
        anchorOpening: Float = 0,
        anchorCohesion: Float = 0,
        anchorCohesionSlip: Float = 0,
        anchorFriction: Float = 0,
        couplingMapCount: UInt32 = 0,
        footings: UInt32 = 0,
        fluidDeepRatio: UInt32 = 0,
        fluidDeepBlocksX: UInt32 = 0,
        fluidDeepBlocksY: UInt32 = 0,
        fluidDeepPatchOffset: UInt32 = 0,
        fluidDeepCellOffset: UInt32 = 0,
        gravityX: Float = 0,
        gravityY: Float = 0,
        gravityZ: Float = -1,
        removesFragments: UInt32 = 0,
        loadShares: UInt32 = 0,
        loadNodeShares: UInt32 = 0,
        linkCount: UInt32 = 0,
        linkRecords: UInt32 = 0,
        linkStarts: UInt32 = 0,
        linkEntries: UInt32 = 0,
        pairs: UInt32 = 0,
        contactEncoded: UInt32 = 0,
        fragmentPanes: UInt32 = 0,
        hingeCount: UInt32 = 0,
        hingeRecords: UInt32 = 0,
        hingeStarts: UInt32 = 0,
        hingeEntries: UInt32 = 0,
        legendrePoints: UInt32 = 0,
        timberPoints: UInt32 = 0
    ) {
        self.elementCount = elementCount
        self.nodeCount = nodeCount
        self.layers = layers
        self.barSlots = barSlots
        self.substep = substep
        self.criticalStep = criticalStep
        self.fixedStep = fixedStep
        self.gravity = gravity
        self.damping = damping
        self.ambientPressure = ambientPressure
        self.fluidGamma = fluidGamma
        self.fluidCell = fluidCell
        self.fluidNx = fluidNx
        self.fluidNy = fluidNy
        self.fluidNz = fluidNz
        self.coupled = coupled
        self.groundFriction = groundFriction
        self.rateFilter = rateFilter
        self.loadTime = loadTime
        self.loadCount = loadCount
        self.loadFace = loadFace
        self.shearFactor = shearFactor
        self.contactMode = contactMode
        self.stamp = stamp
        self.contactNx = contactNx
        self.contactNy = contactNy
        self.contactNz = contactNz
        self.contactRadius = contactRadius
        self.gridOriginX = gridOriginX
        self.gridOriginY = gridOriginY
        self.gridOriginZ = gridOriginZ
        self.contactStiffness = contactStiffness
        self.contactDamping = contactDamping
        self.contactFriction = contactFriction
        self.neighbourDistance = neighbourDistance
        self.beamCount = beamCount
        self.elementSize = elementSize
        self.debrisLoading = debrisLoading
        self.exchangeX = exchangeX
        self.exchangeY = exchangeY
        self.exchangeZ = exchangeZ
        self.exchangeNx = exchangeNx
        self.exchangeNy = exchangeNy
        self.exchangeNz = exchangeNz
        self.fluidAirModel = fluidAirModel
        self.fluidRefine = fluidRefine
        self.fluidBlocksX = fluidBlocksX
        self.fluidBlocksY = fluidBlocksY
        self.crackSlip = crackSlip
        self.anchored = anchored
        self.anchorNormalStiffness = anchorNormalStiffness
        self.anchorShearStiffness = anchorShearStiffness
        self.anchorTension = anchorTension
        self.anchorPlateau = anchorPlateau
        self.anchorOpening = anchorOpening
        self.anchorCohesion = anchorCohesion
        self.anchorCohesionSlip = anchorCohesionSlip
        self.anchorFriction = anchorFriction
        self.couplingMapCount = couplingMapCount
        self.footings = footings
        self.fluidDeepRatio = fluidDeepRatio
        self.fluidDeepBlocksX = fluidDeepBlocksX
        self.fluidDeepBlocksY = fluidDeepBlocksY
        self.fluidDeepPatchOffset = fluidDeepPatchOffset
        self.fluidDeepCellOffset = fluidDeepCellOffset
        self.gravityX = gravityX
        self.gravityY = gravityY
        self.gravityZ = gravityZ
        self.removesFragments = removesFragments
        self.loadShares = loadShares
        self.loadNodeShares = loadNodeShares
        self.linkCount = linkCount
        self.linkRecords = linkRecords
        self.linkStarts = linkStarts
        self.linkEntries = linkEntries
        self.pairs = pairs
        self.contactEncoded = contactEncoded
        self.fragmentPanes = fragmentPanes
        self.hingeCount = hingeCount
        self.hingeRecords = hingeRecords
        self.hingeStarts = hingeStarts
        self.hingeEntries = hingeEntries
        self.legendrePoints = legendrePoints
        self.timberPoints = timberPoints
    }
}

/// Layout matches `BeamElement` in `Shell.metal`.
package struct BeamElementData {
    package var n0: UInt32
    package var n1: UInt32
    package var axis: UInt32
    package var material: UInt32
    package var width: Float
    package var depth: Float
    package var length: Float
    package var barCount: UInt32
    package var tieRatio: Float
    package var bowed: Float = 0
    var padding1: Float = 0

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        n0: UInt32,
        n1: UInt32,
        axis: UInt32,
        material: UInt32,
        width: Float,
        depth: Float,
        length: Float,
        barCount: UInt32,
        tieRatio: Float,
        bowed: Float = 0,
        padding1: Float = 0
    ) {
        self.n0 = n0
        self.n1 = n1
        self.axis = axis
        self.material = material
        self.width = width
        self.depth = depth
        self.length = length
        self.barCount = barCount
        self.tieRatio = tieRatio
        self.bowed = bowed
        self.padding1 = padding1
    }
}

/// Layout matches `ShellElement` in `Shell.metal`.
package struct ShellElementData {
    package var n0: UInt32
    package var n1: UInt32
    package var n2: UInt32
    package var n3: UInt32
    package var axis: UInt32
    package var material: UInt32
    package var barCount: UInt32
    package var thickness: Float
    package var a: Float
    package var b: Float
    /// Another member's element facing this one below and above it (-1: none), for the air's
    /// load (`ShellMesh.shields`).
    package var shieldBelow: Int32 = -1
    package var shieldAbove: Int32 = -1
    /// The solid it was made from, whose laminated glass fragments as one.
    package var pane: UInt32 = 0

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        n0: UInt32,
        n1: UInt32,
        n2: UInt32,
        n3: UInt32,
        axis: UInt32,
        material: UInt32,
        barCount: UInt32,
        thickness: Float,
        a: Float,
        b: Float,
        shieldBelow: Int32 = -1,
        shieldAbove: Int32 = -1,
        pane: UInt32 = 0
    ) {
        self.n0 = n0
        self.n1 = n1
        self.n2 = n2
        self.n3 = n3
        self.axis = axis
        self.material = material
        self.barCount = barCount
        self.thickness = thickness
        self.a = a
        self.b = b
        self.shieldBelow = shieldBelow
        self.shieldAbove = shieldAbove
        self.pane = pane
    }
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
