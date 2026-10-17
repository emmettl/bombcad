import Foundation
import Metal
import simd

/// One part of an envelope building that responds on its own in a damage model: a wall, slab or
/// roof panel between its supports, a pane, or a block's façade strip or roof. Derived from the
/// geometry alone (docs/building-envelopes.md, "Envelope components"; the component spec agreed
/// with the damage model, v1.2).
public struct EnvelopeComponent: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case wall, slab, roof, pane, facade }

    /// "<owner>/<kind>/<source>.<panel>", or "<owner>/opening/<opening>" for an opening recorded as
    /// a pane. `source` is the solid's index in `solids` (wall, slab, roof), the pane's in `panes`,
    /// or the façade strip's. Stable across runs of the same envelope on the same grid.
    public var id: String
    public var owner: UUID
    public var kind: Kind
    /// The component's box: the panel of its solid, the pane, or the façade strip.
    public var region: Box
    /// The thin axis (0, 1, 2), the one its load acts along.
    public var axis: Int
    /// +1 or -1: the side facing the outside along `axis`.
    public var outward: Int
    public var source: Int
    public var panel: Int
    /// Whether each of the region's edges is supported (lies on another solid of the building or
    /// on the ground): [-u, +u, -v, +v], with u and v the in-plane axes in increasing index order,
    /// `axis` skipped. A pane's four edges are its frame.
    public var supportEdges: [Bool]

    /// The in-plane axes, in increasing index order.
    public var inPlaneAxes: (u: Int, v: Int) {
        let axes = (0..<3).filter { $0 != axis }
        return (axes[0], axes[1])
    }

    /// A wall standing free: its foot held and its top not, so a cantilever (`EnvelopeDamageAssessment`).
    /// A wall's in-plane axes are horizontal then z, so its foot and top are the third and fourth edges.
    public var isFreestanding: Bool {
        kind == .wall && axis != 2 && supportEdges.count == 4 && supportEdges[2] && !supportEdges[3]
    }

    /// The region's sizes along u and v, in metres.
    public var spans: SIMD2<Float> {
        let (u, v) = inPlaneAxes
        return SIMD2(region.size[u], region.size[v])
    }
}

extension BuildingEnvelope {
    /// The most a wall panel spans, horizontally and vertically, and a slab's along x and y.
    static let wallSpan = SIMD2<Float>(6, 3)
    static let slabSpan = SIMD2<Float>(6, 6)
    /// Façade strips are a storey tall; a remainder under a metre joins the strip below.
    static let storey: Float = 3

    /// How a solid of the envelope is read.
    enum SolidRole: Equatable {
        /// Thin along an axis: a wall (x or y), or a slab or roof (z).
        case plate(axis: Int)
        /// Two sizes small against the third: left out.
        case column
        case block
    }

    /// Plate-like when the smallest size is at most a metre and at most half the middle one; a
    /// column when the middle size is too; otherwise a block.
    static func role(_ box: Box) -> SolidRole {
        let size = box.size
        let order = (0..<3).sorted { size[$0] < size[$1] }
        let (small, middle, large) = (size[order[0]], size[order[1]], size[order[2]])
        if small <= 1, small <= 0.5 * middle { return .plate(axis: order[0]) }
        if middle <= 1, middle <= 0.5 * large { return .column }
        return .block
    }

    /// The building's components, in a fixed order: the solids' panels in solid order, then the
    /// façade strips and roofs of blocks, then the panes. `cellSize` snaps panel cuts to the air
    /// grid's cells, which start at the origin, as the recorder sees them; nil leaves them exact.
    public func components(owner: UUID, cellSize: Float? = nil) -> [EnvelopeComponent] {
        componentLayout(owner: owner, cellSize: cellSize).map(\.component)
    }

    /// A component and how faces are found for it.
    struct LaidOut {
        var component: EnvelopeComponent
        /// Panel cuts along u and v (the region's edges come from these).
        var uCuts: [Float]
        var vCuts: [Float]
    }

    func componentLayout(owner: UUID, cellSize: Float?) -> [LaidOut] {
        let all = solids + panes
        let bounds = Box(
            min: all.map(\.min).reduce(SIMD3(repeating: .greatestFiniteMagnitude), simd_min),
            max: all.map(\.max).reduce(SIMD3(repeating: -.greatestFiniteMagnitude), simd_max))
        let centre = (bounds.min + bounds.max) / 2
        let eps: Float = 1e-3
        func snap(_ x: Float) -> Float { cellSize.map { ($0 == 0 ? x : (x / $0).rounded() * $0) } ?? x }
        func outward(_ box: Box, _ axis: Int) -> Int {
            ((box.min[axis] + box.max[axis]) / 2 - centre[axis]) < 0 ? -1 : 1
        }
        /// Whether `other` touches or overlaps `box` (within `eps`).
        func touches(_ a: Box, _ b: Box) -> Bool {
            (0..<3).allSatisfy { a.min[$0] <= b.max[$0] + eps && b.min[$0] <= a.max[$0] + eps }
        }
        /// Cuts at `positions` inside (lo, hi), then each piece into equal parts at most `span`
        /// long, snapped; the cuts' list includes both ends.
        func cuts(_ lo: Float, _ hi: Float, supports: [Float], span: Float?) -> [Float] {
            var points = [snap(lo)]
            let inner = supports.map(snap).filter { $0 > snap(lo) + eps && $0 < snap(hi) - eps }.sorted()
            for end in inner + [snap(hi)] {
                let start = points.last!
                guard end > start + eps else { continue }
                if let span {
                    let parts = max(1, Int(((end - start) / span - 1e-4).rounded(.up)))
                    for part in 1..<parts {
                        points.append(snap(start + (end - start) * Float(part) / Float(parts)))
                    }
                }
                if end > points.last! + eps { points.append(end) }
            }
            if points.count == 1 { points.append(snap(hi)) }
            return points
        }
        /// Whether the edge of `region` (thin along `thin`) on the low or high side of axis `along`
        /// lies on another of `others`, touching it and running along it, or on the ground.
        func supported(_ region: Box, thin: Int, along: Int, high: Bool, others: [Box]) -> Bool {
            var edge = region
            let at = high ? region.max[along] : region.min[along]
            edge.min[along] = at
            edge.max[along] = at
            if along == 2 && !high && at <= eps { return true }
            let length = 3 - thin - along
            return others.contains { other in
                touches(edge, other)
                    && min(edge.max[length], other.max[length]) - max(edge.min[length], other.min[length])
                        > eps
            }
        }
        var result: [LaidOut] = []
        let roles = solids.map(Self.role)
        // Panels of plate-like solids.
        for (index, solid) in solids.enumerated() {
            guard case .plate(let axis) = roles[index] else { continue }
            let others = all.enumerated().filter { $0.offset != index }.map(\.element)
            let u = (0..<3).filter { $0 != axis }[0]
            let v = (0..<3).filter { $0 != axis }[1]
            let kind: EnvelopeComponent.Kind
            var uSupports: [Float] = []
            var vSupports: [Float] = []
            var span: (u: Float?, v: Float?)
            var caps: [Box] = []
            if axis == 2 {
                // Roof if nothing of the building stands above it, else a slab; cut where walls
                // meet it from below.
                let above = solids.enumerated().contains { other in
                    other.offset != index && other.element.min.z >= solid.max.z - eps
                        && min(other.element.max.x, solid.max.x) - max(other.element.min.x, solid.min.x) > eps
                        && min(other.element.max.y, solid.max.y) - max(other.element.min.y, solid.min.y) > eps
                }
                kind = above ? .slab : .roof
                // Only walls standing inside its span, not at its edges.
                for (n, other) in solids.enumerated() where n != index && touches(other, solid) {
                    guard case .plate(let wallAxis) = roles[n], wallAxis != 2,
                        other.max.z <= solid.min.z + eps, other.min[wallAxis] > solid.min[wallAxis] + eps,
                        other.max[wallAxis] < solid.max[wallAxis] - eps
                    else { continue }
                    let middle = (other.min[wallAxis] + other.max[wallAxis]) / 2
                    if wallAxis == u { uSupports.append(middle) } else { vSupports.append(middle) }
                }
                span = (Self.slabSpan.x, Self.slabSpan.y)
            } else {
                kind = .wall
                // A slab or roof on the wall's top that rests on no other wall (a cap or canopy
                // carried by this wall alone) does not hold it: the wall stands free under it.
                caps = solids.enumerated().filter { n, other in
                    guard n != index, case .plate(2) = roles[n], abs(other.min.z - solid.max.z) <= eps,
                        touches(other, solid)
                    else { return false }
                    return !solids.enumerated().contains { m, wall in
                        guard m != index, m != n, case .plate(let wallAxis) = roles[m], wallAxis != 2 else {
                            return false
                        }
                        return abs(wall.max.z - other.min.z) <= eps && touches(wall, other)
                    }
                }.map(\.element)
                var held = false
                for (n, other) in solids.enumerated() where n != index && touches(other, solid) {
                    guard case .plate(let otherAxis) = roles[n] else { continue }
                    if otherAxis == 2 {
                        // A slab or roof meets the wall: where it crosses the wall's height, a
                        // support; touching its top or foot, it holds the wall (but for a cap).
                        if !caps.contains(other) { held = true }
                        if other.min.z > solid.min.z + eps && other.max.z < solid.max.z - eps {
                            vSupports.append((other.min.z + other.max.z) / 2)
                        }
                    } else if otherAxis == u, other.min[u] > solid.min[u] + eps,
                        other.max[u] < solid.max[u] - eps
                    {
                        // A wall meeting it inside its span, not at its ends.
                        uSupports.append((other.min[u] + other.max[u]) / 2)
                    }
                }
                // Cut at storey heights only where no slab or roof holds it.
                span = (Self.wallSpan.x, held ? nil : Self.wallSpan.y)
            }
            let us = cuts(solid.min[u], solid.max[u], supports: uSupports, span: span.u)
            let vs = cuts(solid.min[v], solid.max[v], supports: vSupports, span: span.v)
            for j in 0..<(vs.count - 1) {
                for i in 0..<(us.count - 1) {
                    var region = solid
                    region.min[u] = us[i]
                    region.max[u] = us[i + 1]
                    region.min[v] = vs[j]
                    region.max[v] = vs[j + 1]
                    // A cut at a support is supported; one only for width is not.
                    func isSupportCut(_ x: Float, _ list: [Float]) -> Bool {
                        list.map(snap).contains { abs($0 - x) <= eps }
                    }
                    let edges = [
                        i == 0
                            ? supported(region, thin: axis, along: u, high: false, others: others)
                            : isSupportCut(us[i], uSupports),
                        i == us.count - 2
                            ? supported(region, thin: axis, along: u, high: true, others: others)
                            : isSupportCut(us[i + 1], uSupports),
                        j == 0
                            ? supported(region, thin: axis, along: v, high: false, others: others)
                            : isSupportCut(vs[j], vSupports),
                        j == vs.count - 2
                            ? supported(
                                region, thin: axis, along: v, high: true,
                                others: others.filter { !caps.contains($0) })
                            : isSupportCut(vs[j + 1], vSupports),
                    ]
                    let panel = i + (us.count - 1) * j
                    result.append(
                        LaidOut(
                            component: EnvelopeComponent(
                                id: "\(owner.uuidString)/\(kind.rawValue)/\(index).\(panel)", owner: owner,
                                kind: kind, region: region, axis: axis,
                                outward: axis == 2 ? 1 : outward(solid, axis), source: index, panel: panel,
                                supportEdges: edges),
                            uCuts: us, vCuts: vs))
                }
            }
        }
        // Façade strips and roofs of blocks: sides -x, +x, -y, +y, a storey at a time.
        var strip = 0
        let depth = cellSize ?? 0.5
        for (index, block) in solids.enumerated() where roles[index] == .block {
            var heights = [block.min.z]
            while block.max.z - heights.last! > Self.storey + 1 - 1e-4 {
                heights.append(heights.last! + Self.storey)
            }
            heights.append(block.max.z)
            heights = heights.map(snap)
            for axis in 0..<2 {
                for high in [false, true] {
                    for level in 0..<(heights.count - 1) {
                        var region = block
                        region.min.z = heights[level]
                        region.max.z = heights[level + 1]
                        if high {
                            region.min[axis] = block.max[axis] - depth
                        } else {
                            region.max[axis] = block.min[axis] + depth
                        }
                        result.append(
                            LaidOut(
                                component: EnvelopeComponent(
                                    id: "\(owner.uuidString)/facade/\(strip).0", owner: owner, kind: .facade,
                                    region: region, axis: axis, outward: high ? 1 : -1, source: strip,
                                    panel: 0,
                                    supportEdges: [false, false, level == 0 && block.min.z <= 1e-3, false]),
                                uCuts: [], vCuts: [heights[level], heights[level + 1]]))
                        strip += 1
                    }
                }
            }
            var top = block
            top.min.z = block.max.z - depth
            result.append(
                LaidOut(
                    component: EnvelopeComponent(
                        id: "\(owner.uuidString)/roof/\(index).0", owner: owner, kind: .roof, region: top,
                        axis: 2,
                        outward: 1, source: index, panel: 0, supportEdges: [false, false, false, false]),
                    uCuts: [], vCuts: []))
        }
        // Panes: each one component, held in its frame.
        for (index, pane) in panes.enumerated() {
            let size = pane.size
            let axis = (0..<3).min { size[$0] < size[$1] }!
            result.append(
                LaidOut(
                    component: EnvelopeComponent(
                        id: "\(owner.uuidString)/pane/\(index).0", owner: owner, kind: .pane, region: pane,
                        axis: axis,
                        outward: axis == 2 ? 1 : outward(pane, axis), source: index, panel: 0,
                        supportEdges: [true, true, true, true]),
                    uCuts: [], vCuts: []))
        }
        return result
    }
}

/// What the component recorder keeps: the bins' width and window, the memory they may take, and
/// two options.
public struct EnvelopeHistoryOptions: Codable, Hashable, Sendable {
    /// Bin width, in seconds.
    public var binS: Double
    /// How long the window is kept, from t = 0; steps past it are not binned (`truncated`).
    public var windowS: Double
    /// Bytes allowed for all histories. Where the window over `binS` would take more, `binS`
    /// widens to a whole multiple of itself.
    public var memoryBudget: Int
    /// Also keep each side's largest step value within each bin (twice the memory).
    public var binMaxima: Bool
    /// Also record each opening across a wall or slab as a two-sided `pane`, measured just
    /// outside it in the open opening (ids "<owner>/opening/<i>"): what the inside sees once glass
    /// has gone.
    public var openingsAsPanes: Bool
    /// Start each component's window when the air at its faces first moves, rather than at t = 0,
    /// so that `windowS` need only cover the load on one component, not the blast's crossing of a
    /// district: a building 2 km out keeps the few hundred milliseconds that load it.
    public var windowFromArrival: Bool

    public init(
        windowS: Double, binS: Double = 1e-4, memoryBudget: Int = 256 << 20, binMaxima: Bool = false,
        openingsAsPanes: Bool = false, windowFromArrival: Bool = false
    ) {
        self.binS = binS
        self.windowS = windowS
        self.memoryBudget = memoryBudget
        self.binMaxima = binMaxima
        self.openingsAsPanes = openingsAsPanes
        self.windowFromArrival = windowFromArrival
    }
}

/// A component's load through a run: each side's area-weighted mean overpressure, integrated over
/// each bin, and the peaks of every step.
public struct EnvelopeComponentHistory: Codable, Sendable {
    public var component: EnvelopeComponent
    /// The resolved area of its outer side (faces whose normal is +outward along its axis) and its
    /// inner side.
    public var outerAreaM2: Double
    public var innerAreaM2: Double
    public var faceCount: Int
    public var binS: Double
    /// Where the bins start, with `windowFromArrival`: the start of the bin in which the air at the
    /// component first moved; nil when they start at t = 0, or when it never did.
    public var windowStartS: Double?
    /// ∫ pOuter dt and ∫ pInner dt over each bin [i binS, (i + 1) binS) from the window's start, in
    /// Pa s, up to the time recorded (the last bin may be partial). A step of width dt holding pressure p (its right
    /// endpoint) adds p times its overlap with each bin it crosses, so the impulse is exact
    /// whatever the step and bin widths. A side with no faces reads 0.
    public var outerImpulsePaS: [Float]
    public var innerImpulsePaS: [Float]
    /// The largest of each side's pressure, and of the net (outer - inner), over every step,
    /// including the state at the start.
    public var peakOuterPa: Float
    public var peakInnerPa: Float
    public var peakNetPa: Float
    /// Each side's largest step value within each bin, when asked for (`binMaxima`).
    public var outerMaxPa: [Float]?
    public var innerMaxPa: [Float]?
    /// Steps past the window were not binned (their impulse is lost).
    public var truncated: Bool
    /// Some face's solid/fluid pair changed during the run.
    public var invalid: Bool

    /// The net impulse over each bin, outer less inner: positive pushes the component inward.
    public var netImpulsePaS: [Float] { zip(outerImpulsePaS, innerImpulsePaS).map { $0 - $1 } }
}

/// Records each envelope component's two sides through a run, on the GPU after every complete
/// fluid step, as the surface recorder records faces: the same cell-centre pressures, the same
/// right-endpoint rule. Every face's pressure is taken a thread a face, then a SIMD group a component sums them in a fixed order, so the result
/// repeats bit for bit.
final class EnvelopeComponentRecorder {
    /// A component's faces: outer side then inner, as ranges into `faces`.
    struct Sides {
        var outerFirst: UInt32
        var outerCount: UInt32
        var innerFirst: UInt32
        var innerCount: UInt32
    }
    /// The fluid cell read and the solid cell that must stay solid (`noSolid` for an opening).
    struct Face {
        var fluid: UInt32
        var solid: UInt32
    }
    static let noSolid = UInt32.max
    /// Whether a face in a tile of still air reads the still air rather than its cell, which
    /// holds the same; off only to show that the two agree.
    var skipStillTiles = true
    /// Whether a face in refined air reads the finest cells against it (their mean), rather than
    /// its coarse cell, which averages them over the whole cell: the reflected load at a wall is
    /// sharper than the cell beside it. Off only to compare.
    var readsRefinedAir = true
    /// Components to a threadgroup, a SIMD group of 32 lanes each (Solver.metal).
    static let componentsPerGroup = 4

    let components: [EnvelopeComponent]
    let sides: [Sides]
    let faces: [Face]
    let binS: Double
    let capacity: Int
    let binMaxima: Bool
    let cellSize: Float
    let sideBuffer: MTLBuffer
    let faceBuffer: MTLBuffer
    /// Each face's pressure, as the last step left it.
    let pressures: MTLBuffer
    /// Each component's tiles of the air (ranges into `tiles`), whether any has woken this step,
    /// the components listed for the faces' pass and for the sums with their threadgroups (two
    /// indirect dispatches), and the still air's pressure, in 32 copies.
    let tileRanges: MTLBuffer
    let tiles: MTLBuffer
    let awake: MTLBuffer
    let faceList: MTLBuffer
    let faceDispatch: MTLBuffer
    let sumList: MTLBuffer
    let sumDispatch: MTLBuffer
    let stillPressure: MTLBuffer
    /// The bin the coming step starts in and how far into it (`ComponentClock`), kept on the GPU.
    let clock: MTLBuffer
    /// Each component's first bin: 0, or with `windowFromArrival` the clock's bin when its air
    /// first moved (`UInt32.max` until then).
    let starts: MTLBuffer
    let fromArrival: Bool
    let clockPipeline: MTLComputePipelineState
    let peaks: MTLBuffer
    let bins: MTLBuffer
    let maxima: MTLBuffer?
    let flags: MTLBuffer
    /// Each component's two sides' mean overpressures in the step just taken, for venting.
    let current: MTLBuffer
    let markPipeline: MTLComputePipelineState
    let facePipeline: MTLComputePipelineState
    let pipeline: MTLComputePipelineState

    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, mask: UnsafeBufferPointer<UInt8>,
        objects: [SceneObject], options: EnvelopeHistoryOptions
    ) throws {
        guard options.binS > 0, options.windowS > 0, options.memoryBudget > 0 else {
            throw BlastError.allocationFailed("envelope history with a positive bin, window and budget")
        }
        let resolved = try EnvelopeExposure.resolvedFaces(grid: grid, mask: mask, objects: objects)
        let dx = grid.cellSize
        var components: [EnvelopeComponent] = []
        var outer: [[Face]] = []
        var inner: [[Face]] = []
        // Each owner's components by their source (a solid or a pane), and its façade strips, to
        // find a face's: a district holds thousands of owners.
        struct Source: Hashable {
            var owner: Int
            var pane: Bool
            var index: Int
        }
        var bySource: [Source: [Int]] = [:]
        var facades: [[Int]] = Array(repeating: [], count: objects.count)
        for (owner, object) in objects.enumerated() {
            let envelope = resolved.geometry[owner]
            for laid in envelope.componentLayout(owner: object.id, cellSize: dx) {
                if laid.component.kind == .facade {
                    facades[owner].append(components.count)
                } else {
                    bySource[
                        Source(
                            owner: owner, pane: laid.component.kind == .pane, index: laid.component.source),
                        default: []
                    ].append(components.count)
                }
                components.append(laid.component)
                outer.append([])
                inner.append([])
            }
        }
        func contains(_ region: Box, _ point: SIMD3<Float>) -> Bool {
            (0..<3).allSatisfy { point[$0] >= region.min[$0] && point[$0] <= region.max[$0] }
        }
        // The cells standing for each pane (`BuildingEnvelope.paneCells`) carry its load, whichever
        // block holds them.
        var paneOfCell: [Int: Int] = [:]
        for (owner, _) in objects.enumerated() {
            let envelope = resolved.geometry[owner]
            for pane in envelope.panes.indices {
                guard let component = bySource[Source(owner: owner, pane: true, index: pane)]?.first else {
                    continue
                }
                for cell in envelope.paneCells(pane, grid: grid) { paneOfCell[cell] = component }
            }
        }
        for face in resolved.faces {
            let envelope = resolved.geometry[face.owner]
            let cell = Int(face.face.solid)
            if let pane = paneOfCell[cell] {
                guard components[pane].axis == Int(face.face.axis) else { continue }
                let entry = Face(fluid: face.face.fluid, solid: face.face.solid)
                let sign = face.face.positive != 0 ? 1 : -1
                if sign == components[pane].outward {
                    outer[pane].append(entry)
                } else {
                    inner[pane].append(entry)
                }
                continue
            }
            let point = grid.cellCentre(
                cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
            let axis = Int(face.face.axis)
            let sign = face.face.positive != 0 ? 1 : -1
            let candidates: [Int]
            switch envelope.blockSources[face.block] {
            case .pane(let index):
                candidates = bySource[Source(owner: face.owner, pane: true, index: index)] ?? []
            case .solid(let index):
                let own = bySource[Source(owner: face.owner, pane: false, index: index)] ?? []
                switch BuildingEnvelope.role(envelope.solids[index]) {
                case .plate: candidates = own
                case .column: candidates = []
                case .block:
                    candidates = axis == 2 ? own.filter { components[$0].kind == .roof } : facades[face.owner]
                }
            }
            // Its own component: on the thin axis, holding the cell; a block's façade strip or roof
            // only on its outward side.
            guard
                let match = candidates.first(where: { n in
                    let component = components[n]
                    let oneSided =
                        component.kind == .facade
                        || component.kind == .roof
                            && BuildingEnvelope.role(envelope.solids[component.source]) == .block
                    return component.axis == axis && contains(component.region, point)
                        && (!oneSided || component.outward == sign)
                })
            else { continue }
            let entry = Face(fluid: face.face.fluid, solid: face.face.solid)
            if sign == components[match].outward {
                outer[match].append(entry)
            } else {
                inner[match].append(entry)
            }
        }
        if options.openingsAsPanes {
            for (owner, object) in objects.enumerated() {
                let envelope = resolved.geometry[owner]
                for (openingIndex, opening) in envelope.openings.enumerated() {
                    var crossings = 0
                    for (index, solid) in envelope.solids.enumerated() {
                        guard case .plate(let axis) = BuildingEnvelope.role(solid) else { continue }
                        var region = Box(
                            min: simd_max(solid.min, opening.min), max: simd_min(solid.max, opening.max))
                        guard (0..<3).allSatisfy({ region.max[$0] > region.min[$0] }) else { continue }
                        region.min[axis] = solid.min[axis]
                        region.max[axis] = solid.max[axis]
                        let wall = components.first {
                            $0.owner == object.id && $0.source == index && $0.kind != .pane
                        }
                        let outward = wall?.outward ?? 1
                        let (u, v) = ((0..<3).filter { $0 != axis }[0], (0..<3).filter { $0 != axis }[1])
                        var sideCells: [[Face]] = [[], []]
                        let low = grid.cell(containing: region.min + 0.5 * dx)
                        let high = grid.cell(containing: region.max - 0.5 * dx)
                        let lo = [low.i, low.j, low.k]
                        let hi = [high.i, high.j, high.k]
                        for (n, side) in [-1, 1].enumerated() {
                            var at = [0, 0, 0]
                            at[axis] = side < 0 ? lo[axis] - 1 : hi[axis] + 1
                            for b in lo[v]...hi[v] {
                                for a in lo[u]...hi[u] {
                                    at[u] = a
                                    at[v] = b
                                    guard grid.contains(at[0], at[1], at[2]) else { continue }
                                    let index = grid.index(at[0], at[1], at[2])
                                    guard mask[index] == 0 else { continue }
                                    sideCells[n].append(Face(fluid: UInt32(index), solid: Self.noSolid))
                                }
                            }
                        }
                        let id =
                            "\(object.id.uuidString)/opening/\(openingIndex)"
                            + (crossings > 0 ? ".\(crossings)" : "")
                        crossings += 1
                        components.append(
                            EnvelopeComponent(
                                id: id, owner: object.id, kind: .pane, region: region, axis: axis,
                                outward: outward,
                                source: openingIndex, panel: 0, supportEdges: [true, true, true, true]))
                        outer.append(outward > 0 ? sideCells[1] : sideCells[0])
                        inner.append(outward > 0 ? sideCells[0] : sideCells[1])
                    }
                }
            }
        }
        // Components with no face on the air (a block's sides against its neighbours, a wall buried
        // in the terrain) are left out: a district's map buildings have many.
        let kept = components.indices.filter { !outer[$0].isEmpty || !inner[$0].isEmpty }
        components = kept.map { components[$0] }
        outer = kept.map { outer[$0] }
        inner = kept.map { inner[$0] }
        var faces: [Face] = []
        var sides: [Sides] = []
        for n in components.indices {
            let first = UInt32(faces.count)
            faces += outer[n]
            faces += inner[n]
            sides.append(
                Sides(
                    outerFirst: first, outerCount: UInt32(outer[n].count),
                    innerFirst: first + UInt32(outer[n].count), innerCount: UInt32(inner[n].count)))
        }
        // The bins: as wide as asked, or the least whole multiple of it that fits the budget.
        let perBin = max(1, components.count) * 8 * (options.binMaxima ? 2 : 1)
        var multiple = 1.0
        func bins(_ multiple: Double) -> Int {
            Int((options.windowS / (options.binS * multiple)).rounded(.up)) + 1
        }
        while perBin * bins(multiple) > options.memoryBudget && bins(multiple) > 2 { multiple += 1 }
        let width = options.binS * multiple
        let count = bins(multiple)
        guard !components.isEmpty, perBin * count <= options.memoryBudget,
            let sideBuffer = device.makeBuffer(
                bytes: sides, length: max(1, sides.count) * MemoryLayout<Sides>.stride),
            let faceBuffer = device.makeBuffer(
                bytes: faces.isEmpty ? [Face(fluid: 0, solid: 0)] : faces,
                length: max(1, faces.count) * MemoryLayout<Face>.stride),
            let peaks = device.makeBuffer(length: components.count * 16, options: .storageModeShared),
            let bins = device.makeBuffer(length: components.count * count * 8, options: .storageModeShared),
            let flags = device.makeBuffer(length: 4, options: .storageModeShared),
            let current = device.makeBuffer(
                length: max(components.count * 8, 16), options: .storageModeShared)
        else { throw BlastError.allocationFailed("envelope component histories") }
        self.components = components
        self.sides = sides
        self.faces = faces
        binS = width
        capacity = count
        binMaxima = options.binMaxima
        cellSize = dx
        self.sideBuffer = sideBuffer
        self.faceBuffer = faceBuffer
        self.peaks = peaks
        self.bins = bins
        self.flags = flags
        self.current = current
        maxima =
            options.binMaxima
            ? device.makeBuffer(length: components.count * count * 8, options: .storageModeShared) : nil
        guard !options.binMaxima || maxima != nil else {
            throw BlastError.allocationFailed("envelope component bin maxima")
        }
        // The tiles of the air each component's faces lie in (as the solver's, 8 cells).
        var ranges: [SIMD2<UInt32>] = []
        var tileList: [UInt32] = []
        let tileNx = (grid.nx + 7) / 8
        let tileNy = (grid.ny + 7) / 8
        for side in sides {
            let own = faces[Int(side.outerFirst)..<Int(side.innerFirst + side.innerCount)]
            let tiles = Set(
                own.map { face -> UInt32 in
                    let cell = Int(face.fluid)
                    let (i, j, k) = (cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
                    return UInt32(i / 8 + tileNx * (j / 8 + tileNy * (k / 8)))
                }
            ).sorted()
            ranges.append(SIMD2(UInt32(tileList.count), UInt32(tiles.count)))
            tileList += tiles
        }
        guard
            let pressures = device.makeBuffer(length: max(1, faces.count) * 4, options: .storageModePrivate),
            let tileRanges = device.makeBuffer(bytes: ranges, length: max(1, ranges.count) * 8),
            let tiles = device.makeBuffer(
                bytes: tileList.isEmpty ? [0] : tileList, length: max(1, tileList.count) * 4),
            let awake = device.makeBuffer(length: components.count * 4, options: .storageModePrivate),
            let faceList = device.makeBuffer(length: components.count * 4, options: .storageModePrivate),
            let faceDispatch = device.makeBuffer(length: 12),
            let sumList = device.makeBuffer(length: components.count * 4, options: .storageModePrivate),
            let sumDispatch = device.makeBuffer(length: 12),
            let stillPressure = device.makeBuffer(length: 32 * 4, options: .storageModePrivate),
            let clock = device.makeBuffer(length: 8, options: .storageModeShared),
            let starts = device.makeBuffer(length: max(1, components.count) * 4, options: .storageModeShared)
        else { throw BlastError.allocationFailed("envelope component face pressures") }
        self.pressures = pressures
        self.tileRanges = tileRanges
        self.tiles = tiles
        self.awake = awake
        self.faceList = faceList
        self.faceDispatch = faceDispatch
        self.sumList = sumList
        self.sumDispatch = sumDispatch
        self.stillPressure = stillPressure
        self.clock = clock
        self.starts = starts
        fromArrival = options.windowFromArrival
        clockPipeline = try ShaderLibrary.pipeline("advanceEnvelopeClock", in: library)
        markPipeline = try ShaderLibrary.pipeline("markEnvelopeComponents", in: library)
        facePipeline = try ShaderLibrary.pipeline("sampleEnvelopeComponentFaces", in: library)
        pipeline = try ShaderLibrary.pipeline("sampleEnvelopeComponents", in: library)
        reset()
    }

    var memoryFootprint: Int {
        [
            sideBuffer, faceBuffer, pressures, tileRanges, tiles, awake, faceList, faceDispatch, sumList,
            sumDispatch, stillPressure, clock, starts,
            peaks,
            bins, flags, current,
        ]
        .reduce(0) { $0 + $1.length } + (maxima?.length ?? 0)
    }

    func reset() {
        let lowest = -Float.greatestFiniteMagnitude
        let peak = peaks.contents().bindMemory(to: SIMD4<Float>.self, capacity: components.count)
        for n in components.indices { peak[n] = SIMD4(lowest, lowest, lowest, 0) }
        memset(bins.contents(), 0, bins.length)
        memset(current.contents(), 0, current.length)
        if let maxima {
            let values = maxima.contents().bindMemory(to: Float.self, capacity: maxima.length / 4)
            for n in 0..<(maxima.length / 4) { values[n] = lowest }
        }
        memset(flags.contents(), 0, flags.length)
        memset(clock.contents(), 0, clock.length)
        memset(starts.contents(), fromArrival ? 0xFF : 0, starts.length)
        // The first sample's faces' pass has one threadgroup to make the still air's row; the sums
        // none until components are listed.
        for (buffer, count) in [(faceDispatch, UInt32(1)), (sumDispatch, 0)] {
            for (n, value) in [count, 1, 1].enumerated() {
                buffer.contents().storeBytes(of: value, toByteOffset: 4 * n, as: UInt32.self)
            }
        }
    }

    /// The recording parameters for a step, or the first sample.
    func parameters(initial: Bool) -> Parameters {
        Parameters(
            components: UInt32(components.count), capacity: UInt32(capacity), initial: initial ? 1 : 0,
            maxima: binMaxima ? 1 : 0, binWidth: Float(binS), faces: UInt32(faces.count),
            fromArrival: fromArrival ? 1 : 0)
    }

    struct Parameters {
        var components: UInt32
        var capacity: UInt32
        var initial: UInt32
        var maxima: UInt32
        var binWidth: Float
        var faces: UInt32
        var fromArrival: UInt32
        var readsRefined: UInt32 = 0
        var skipStill: UInt32 = 0
    }

    func histories(elapsed: Double) -> [EnvelopeComponentHistory] {
        let recorded = min(capacity, Int((elapsed / binS - 1e-9).rounded(.up)))
        let peak = peaks.contents().bindMemory(to: SIMD4<Float>.self, capacity: components.count)
        let binned = bins.contents().bindMemory(to: SIMD2<Float>.self, capacity: components.count * capacity)
        let maximum = maxima?.contents().bindMemory(
            to: SIMD2<Float>.self, capacity: components.count * capacity)
        let truncated = flags.contents().load(as: UInt32.self) != 0
        let area = Double(cellSize * cellSize)
        func finite(_ value: Float) -> Float { value == -.greatestFiniteMagnitude ? 0 : value }
        let elapsedBins = Int((elapsed / binS - 1e-9).rounded(.up))
        let first = starts.contents().bindMemory(to: UInt32.self, capacity: components.count)
        return components.indices.map { n in
            let base = n * capacity
            let start = first[n] == .max ? nil : Int(first[n])
            let count = fromArrival ? start.map { min(capacity, max(elapsedBins - $0, 0)) } ?? 0 : recorded
            let values = (0..<max(count, 0)).map { binned[base + $0] }
            let largest = maximum.map { m in (0..<max(count, 0)).map { m[base + $0] } }
            return EnvelopeComponentHistory(
                component: components[n], outerAreaM2: Double(sides[n].outerCount) * area,
                innerAreaM2: Double(sides[n].innerCount) * area,
                faceCount: Int(sides[n].outerCount + sides[n].innerCount), binS: binS,
                windowStartS: fromArrival ? start.map { Double($0) * binS } : nil,
                outerImpulsePaS: values.map(\.x), innerImpulsePaS: values.map(\.y),
                peakOuterPa: finite(peak[n].x), peakInnerPa: finite(peak[n].y), peakNetPa: finite(peak[n].z),
                outerMaxPa: largest?.map { finite($0.x) }, innerMaxPa: largest?.map { finite($0.y) },
                truncated: fromArrival ? start.map { elapsedBins - $0 > capacity } ?? false : truncated,
                invalid: peak[n].w != 0)
        }
    }
}
