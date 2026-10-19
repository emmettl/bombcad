import Foundation
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

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        id: String,
        owner: UUID,
        kind: Kind,
        region: Box,
        axis: Int,
        outward: Int,
        source: Int,
        panel: Int,
        supportEdges: [Bool]
    ) {
        self.id = id
        self.owner = owner
        self.kind = kind
        self.region = region
        self.axis = axis
        self.outward = outward
        self.source = source
        self.panel = panel
        self.supportEdges = supportEdges
    }
}

extension BuildingEnvelope {
    /// The most a wall panel spans, horizontally and vertically, and a slab's along x and y.
    static let wallSpan = SIMD2<Float>(6, 3)
    static let slabSpan = SIMD2<Float>(6, 6)
    /// Façade strips are a storey tall; a remainder under a metre joins the strip below.
    package static let storey: Float = 3

    /// How a solid of the envelope is read.
    package enum SolidRole: Equatable {
        /// Thin along an axis: a wall (x or y), or a slab or roof (z).
        case plate(axis: Int)
        /// Two sizes small against the third: left out.
        case column
        case block
    }

    /// Plate-like when the smallest size is at most a metre and at most half the middle one; a
    /// column when the middle size is too; otherwise a block.
    package static func role(_ box: Box) -> SolidRole {
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
    package struct LaidOut {
        package var component: EnvelopeComponent
        /// Panel cuts along u and v (the region's edges come from these).
        var uCuts: [Float]
        var vCuts: [Float]
    }

    package func componentLayout(owner: UUID, cellSize: Float?) -> [LaidOut] {
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
    /// Start each component's window when the blast reaches it, rather than at t = 0, so that
    /// `windowS` need only cover the load on one component, not the blast's crossing of a
    /// district: a building 2 km out keeps the few hundred milliseconds that load it.
    public var windowFromArrival: Bool
    /// With `windowFromArrival`, the overpressure on either side of a component (its faces' mean,
    /// Pa) that starts its window; 0 starts it when the air at its faces first moves, as before
    /// 18 October 2026. The air wakes a tile and a margin ahead of the shock, which on 8 m cells
    /// opened Beirut's windows about 0.35 s before the load (0.13 s on 3 m) and on refined air,
    /// whose weak disturbances wake it farther ahead, closed many before the load came.
    public var arrivalPa: Float
    /// Also record each wall, slab, roof and pane's equivalent uniform loads (`EnvelopeComponentHistory
    /// .plate`, `.strip`), which its damage is judged on.
    public var governingBands: Bool

    public init(
        windowS: Double, binS: Double = 1e-4, memoryBudget: Int = 256 << 20, binMaxima: Bool = false,
        openingsAsPanes: Bool = false, windowFromArrival: Bool = false, governingBands: Bool = true,
        arrivalPa: Float = 500
    ) {
        self.governingBands = governingBands
        self.arrivalPa = arrivalPa
        self.binS = binS
        self.windowS = windowS
        self.memoryBudget = memoryBudget
        self.binMaxima = binMaxima
        self.openingsAsPanes = openingsAsPanes
        self.windowFromArrival = windowFromArrival
    }

    enum CodingKeys: String, CodingKey {
        case binS, windowS, memoryBudget, binMaxima, openingsAsPanes, windowFromArrival, governingBands,
            arrivalPa
    }

    /// Options saved before the bands were recorded read as recording them, and those saved before
    /// the arrival's overpressure as starting their windows when the air moves.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binS = try c.decode(Double.self, forKey: .binS)
        windowS = try c.decode(Double.self, forKey: .windowS)
        memoryBudget = try c.decode(Int.self, forKey: .memoryBudget)
        binMaxima = try c.decode(Bool.self, forKey: .binMaxima)
        openingsAsPanes = try c.decode(Bool.self, forKey: .openingsAsPanes)
        windowFromArrival = try c.decode(Bool.self, forKey: .windowFromArrival)
        governingBands = try c.decodeIfPresent(Bool.self, forKey: .governingBands) ?? true
        arrivalPa = try c.decodeIfPresent(Float.self, forKey: .arrivalPa) ?? 0
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
    /// The component's equivalent uniform loads, where kept (`EnvelopeComponentRecorder`): `plate`,
    /// its faces weighted by its deflected shape; `strip`, the middle third across its span
    /// weighted along it, for a construction whose ribs span on their own (profiled sheeting).
    public var plate: Equivalent?
    public var strip: Equivalent?
    /// Steps past the window were not binned (their impulse is lost).
    public var truncated: Bool
    /// Some face's solid/fluid pair changed during the run.
    public var invalid: Bool

    /// The net impulse over each bin, outer less inner: positive pushes the component inward.
    public var netImpulsePaS: [Float] { zip(outerImpulsePaS, innerImpulsePaS).map { $0 - $1 } }

    /// An equivalent uniform load of a component: the region it is taken over, its sides'
    /// resolved areas there, their weighted bins as the component's (the same width and start), and
    /// its largest net pressure.
    public struct Equivalent: Codable, Sendable {
        public var region: Box
        public var outerAreaM2: Double
        public var innerAreaM2: Double
        public var outerImpulsePaS: [Float]
        public var innerImpulsePaS: [Float]
        public var peakNetPa: Float

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            region: Box,
            outerAreaM2: Double,
            innerAreaM2: Double,
            outerImpulsePaS: [Float],
            innerImpulsePaS: [Float],
            peakNetPa: Float
        ) {
            self.region = region
            self.outerAreaM2 = outerAreaM2
            self.innerAreaM2 = innerAreaM2
            self.outerImpulsePaS = outerImpulsePaS
            self.innerImpulsePaS = innerImpulsePaS
            self.peakNetPa = peakNetPa
        }
    }

    /// The memberwise initialiser, written out so that BlastCore can use it.
    package init(
        component: EnvelopeComponent,
        outerAreaM2: Double,
        innerAreaM2: Double,
        faceCount: Int,
        binS: Double,
        windowStartS: Double? = nil,
        outerImpulsePaS: [Float],
        innerImpulsePaS: [Float],
        peakOuterPa: Float,
        peakInnerPa: Float,
        peakNetPa: Float,
        outerMaxPa: [Float]? = nil,
        innerMaxPa: [Float]? = nil,
        plate: Equivalent? = nil,
        strip: Equivalent? = nil,
        truncated: Bool,
        invalid: Bool
    ) {
        self.component = component
        self.outerAreaM2 = outerAreaM2
        self.innerAreaM2 = innerAreaM2
        self.faceCount = faceCount
        self.binS = binS
        self.windowStartS = windowStartS
        self.outerImpulsePaS = outerImpulsePaS
        self.innerImpulsePaS = innerImpulsePaS
        self.peakOuterPa = peakOuterPa
        self.peakInnerPa = peakInnerPa
        self.peakNetPa = peakNetPa
        self.outerMaxPa = outerMaxPa
        self.innerMaxPa = innerMaxPa
        self.plate = plate
        self.strip = strip
        self.truncated = truncated
        self.invalid = invalid
    }
}
