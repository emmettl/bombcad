import Foundation
import Metal
import simd

/// The bed of springs a rigid footing stands on: points over its base, each bearing in
/// compression only, sliding with Coulomb friction and yielding past its share of the bearing
/// capacity, so that the footing's heel can lift and its contact shift as it turns.
///
/// The points lie on a grid of 17 by 17 over the base, from edge to edge. A bed of equal springs
/// turns two and a half times too easily for its vertical stiffness: a rigid footing on an
/// elastic half-space bears hardest at its edges. So each point's stiffness is its share of
/// (1 − s²)^−a (1 − t²)^−b over the base, s and t running from −1 to 1 across it: the rigid
/// punch's pressure when a = b = 1/2, more and more at the edges as they near 1, and towards the
/// middle below 0. Each
/// exponent is set so that the bed turns about its axis as stiffly, against its vertical
/// stiffness, as the half-space does (`FootingImpedance`), and the bed is scaled to the
/// half-space's vertical stiffness. A long footing turns about its long axis more stiffly than
/// any bed of its width can; there the exponent stops at 0.95 and the bed is scaled to turn as
/// stiffly as the half-space, which makes it stiffer vertically (1.6 times over a strip ten times
/// as long as it is wide). `stiffness` says what the bed gives.
public struct FootingBed: Sendable {
    public struct Point: Sendable {
        /// From the base centre, in metres.
        public var place: SIMD2<Float>
        public var area: Float
        /// N/m.
        public var vertical: Float
        public var horizontal: SIMD2<Float>
    }

    public static let pointsAcross = 17
    /// The greatest exponent of the bed's weighting towards the edges.
    static let steepest = 0.95

    public var points: [Point]
    /// What the bed gives, by `FootingImpedance.Mode`.
    public var stiffness: [Float]
    /// The cones fitted to it.
    public var impedance: FootingImpedance

    /// The bed under a footing `width` along x and `length` along y on `soil`.
    public init(width: Float, length: Float, soil: Soil) {
        var radiating = soil
        radiating.radiationDamping = true
        let halfSpace = FootingImpedance(width: width, length: length, soil: radiating)
        // Massless soil over a layer is stiffer as the cones' echoes say, statically. (The
        // half-space's rocking stiffness already has the layer's.)
        let target = FootingImpedance.Mode.allCases.map {
            soil.radiationDamping ? halfSpace.stiffness[$0.rawValue] : halfSpace.staticStiffness($0)
        }
        let n = Self.pointsAcross
        // Scaled to the vertical stiffness, or stiffer if the rocking needs it: the bed's rocking
        // stiffness over its vertical is mean(s²) (extent / 2)².
        let steepest = Self.punchWeights(n, exponent: Self.steepest).meanSquare
        let scale = max(
            Double(target[0]), Double(target[4]) / (steepest * Double(width * width) / 4),
            Double(target[3]) / (steepest * Double(length * length) / 4))
        // Along each axis: the weights, and the mean square of s they give.
        func axis(_ extent: Float, rocking: Float) -> (weights: [Double], meanSquare: Double) {
            let wanted = Double(rocking) / scale / Double(extent * extent / 4)
            // Below zero the weights gather towards the middle instead.
            var low = -1.0
            var high = Self.steepest
            var best = Self.punchWeights(n, exponent: high)
            if best.meanSquare > wanted {
                for _ in 0..<40 {
                    let middle = 0.5 * (low + high)
                    let trial = Self.punchWeights(n, exponent: middle)
                    if trial.meanSquare > wanted { high = middle } else { low = middle }
                }
                best = Self.punchWeights(n, exponent: 0.5 * (low + high))
            }
            return best
        }
        let alongX = axis(width, rocking: target[4])
        let alongY = axis(length, rocking: target[3])
        let area = width * length
        let total = scale * alongX.weights.reduce(0, +) * alongY.weights.reduce(0, +)
        var points: [Point] = []
        for i in 0..<n {
            for j in 0..<n {
                let s = Float(i) / Float(n - 1) * 2 - 1
                let t = Float(j) / Float(n - 1) * 2 - 1
                // The trapezoid rule's areas, from edge to edge.
                let a =
                    (i == 0 || i == n - 1 ? 0.5 : 1) * (j == 0 || j == n - 1 ? 0.5 : 1)
                    * area / Float((n - 1) * (n - 1))
                // Along the base, the same share: a rigid footing's shear, like its pressure,
                // gathers at its edges, and a point slides when its own share of the footing's
                // friction is used up, all at once.
                let k = scale * alongX.weights[i] * alongY.weights[j]
                points.append(
                    Point(
                        place: SIMD2(s * width / 2, t * length / 2), area: a, vertical: Float(k),
                        horizontal: SIMD2(target[1], target[2]) * Float(k / total)))
            }
        }
        self.points = points
        let vertical = points.reduce(0) { $0 + $1.vertical }
        let aboutX = points.reduce(0) { $0 + $1.vertical * $1.place.y * $1.place.y }
        let aboutY = points.reduce(0) { $0 + $1.vertical * $1.place.x * $1.place.x }
        stiffness = [vertical, target[1], target[2], aboutX, aboutY]
        impedance = FootingImpedance(width: width, length: length, soil: soil, stiffness: stiffness)
    }

    /// The shares of (1 − s²)^−a over `n` points from s = −1 to 1, each over half the gap to its
    /// neighbours, summing to one, and the mean of s² they give.
    static func punchWeights(_ n: Int, exponent a: Double) -> (weights: [Double], meanSquare: Double) {
        // ∫ (1 − s²)^−a ds from s to 1 is ∫ sin^c ψ dψ from 0 to arccos s, c = 1 − 2a; with
        // τ = ψ^(c+1) / (c + 1) the integrand becomes (sin ψ / ψ)^c, smooth, for Simpson's rule.
        let c = 1 - 2 * a
        func tail(_ s: Double) -> Double {
            let end = pow(acos(min(max(s, -1), 1)), c + 1) / (c + 1)
            let m = 64
            var total = 0.0
            for k in 0...(2 * m) {
                let tau = end * Double(k) / Double(2 * m)
                let psi = pow((c + 1) * tau, 1 / (c + 1))
                let f = psi > 0 ? pow(sin(psi) / psi, c) : 1
                total += f * (k == 0 || k == 2 * m ? 1 : (k % 2 == 1 ? 4 : 2))
            }
            return total * end / Double(6 * m)
        }
        // Over [s0, s1] with 0 ≤ s0 ≤ s1 ≤ 1.
        func cell(_ s0: Double, _ s1: Double) -> Double { tail(s0) - tail(s1) }
        let gap = 1 / Double(n - 1)
        var weights: [Double] = []
        var total = 0.0
        var squares = 0.0
        for i in 0..<n {
            let s = Double(i) * 2 * gap - 1
            let low = max(-1, s - gap)
            let high = min(1, s + gap)
            let w =
                low < 0 && high > 0
                ? cell(0, -low) + cell(0, high) : high <= 0 ? cell(-high, -low) : cell(low, high)
            weights.append(w)
            total += w
            squares += w * s * s
        }
        return (weights.map { $0 / total }, squares / total)
    }
}

/// A footing's state after the last step (`StructureSolver.footingSummaries()`).
public struct FootingSummary: Sendable {
    /// The plan: centre of the base at rest, and its extent along x and y.
    public var baseCentre: SIMD3<Float>
    public var size: SIMD2<Float>
    /// Displacement of the base centre, and the footing's rotation as a rotation vector (radians).
    public var displacement: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public var velocity: SIMD3<Float>
    /// The soil's force on the footing, and its moment about the base centre.
    public var soilForce: SIMD3<Float>
    public var soilMoment: SIMD3<Float>
    /// The body's force on the footing through the connection.
    public var jointForce: SIMD3<Float>
    /// The fraction of the bed's stiffness that bears, the largest lift of any point of the base
    /// off the soil, and the deepest the soil has yielded under it, in metres.
    public var bearing: Float
    public var uplift: Float
    public var settlement: Float
    /// The part of the base that bears, from the base centre: least and greatest x, least and
    /// greatest y (empty, least above greatest, when none does).
    public var contact: SIMD4<Float>
    public var mass: Float
}

/// The rigid footings under a body's connected bases (`Footing`), moved on the GPU by
/// `footingStep` after each node pass. A connection with a footing makes one footing under all
/// the points of the body tied by it: the ground's connection one, each support region's
/// another.
final class FootingSystem {
    /// Layout matches `FootingConstants` in Structure.metal.
    struct Constants {
        var rest: SIMD4<Float>
        var inertia: SIMD4<Float>
        var base: SIMD4<Float>
        var ranges: SIMD4<UInt32>
        var rocking: SIMD4<Float>
        var stiffness: SIMD4<Float>
        var moreStiffness: SIMD4<Float>
        var layer: SIMD4<Float>
        var history: SIMD4<UInt32>
        var totals: SIMD4<Float>
        var unused: SIMD4<Float> = .zero
    }

    /// Layout matches `FootingState`.
    struct State {
        var centre: SIMD4<Float> = .zero
        var rotation = SIMD4<Float>(0, 0, 0, 1)
        var velocity: SIMD4<Float> = .zero
        var spin: SIMD4<Float> = .zero
        var cone: SIMD4<Float> = .zero
        var soilForce: SIMD4<Float> = .zero
        var soilMoment: SIMD4<Float> = .zero
        var jointForce: SIMD4<Float> = .zero
        var contact: SIMD4<Float> = .zero
    }

    /// Layout matches `BedPoint` in Footing.metal.
    struct BedPoint {
        var placeAndBearing: SIMD4<Float>
        var shearAndDamping: SIMD4<Float>
    }

    /// Layout matches `FootingUniforms`.
    struct Uniforms {
        var fixedStep: Float
        var criticalStep: Float
        var substep: UInt32
        var gravity: Float
        var damping: Float
        var footings: UInt32
        var unused0: UInt32 = 0
        var unused1: UInt32 = 0
    }

    /// A point of the body tied to a footing: its index among the solver's connected entities
    /// (nodes, or points of a shell's footprint), where it starts, its area, which connection
    /// (0 the ground's, 1 + n support region n's) and its law.
    struct Member {
        var entity: Int
        var rest: SIMD3<Float>
        var area: Float
        var slot: Int
        var law: Anchorage
        var stiffness: (normal: Float, shear: Float)
    }

    static let threads = 256
    static let samplesPerTrip = 32
    static let echoSlots = 64
    static var historyCapacity: Int { (echoSlots + 1) * samplesPerTrip + 4 }

    let count: Int
    let summariesAtRest: [FootingSummary]
    private let pipeline: MTLComputePipelineState
    let stateBuffer: MTLBuffer
    let constantBuffer: MTLBuffer
    private let bedBuffer: MTLBuffer
    private let bedStateBuffer: MTLBuffer
    private let memberBuffer: MTLBuffer
    /// For each connected entity, its footing plus one (zero: on the ground).
    let footingOfBuffer: MTLBuffer
    /// For each connected entity, the force it puts on its footing and that force's moment about
    /// the footing's centre (two `SIMD4<Float>`).
    let linkBuffer: MTLBuffer
    private let historyBuffer: MTLBuffer
    private let echoBuffer: MTLBuffer
    /// The largest square angular frequency of a footing on its connection and soil, 1/s².
    let frequencySquared: Float
    private let constants: [Constants]

    /// Footings for `members`, or nil when no connection has one. `bodyMass` stands on them,
    /// for the damping of a bed of massless soil.
    init?(
        device: MTLDevice, library: MTLLibrary, members: [Member], entityCount: Int, bodyMass: Float,
        contactDamping: Float
    ) throws {
        let slots = Array(Set(members.filter { $0.law.footing != nil }.map(\.slot))).sorted()
        guard !slots.isEmpty else { return nil }
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        var constants: [Constants] = []
        var bed: [BedPoint] = []
        var memberList: [UInt32] = []
        var footingOf = [UInt32](repeating: 0, count: max(entityCount, 1))
        var echoes: [Float] = []
        var summaries: [FootingSummary] = []
        var historyLength = 0
        var frequencySquared: Float = 0
        for (index, slot) in slots.enumerated() {
            let tied = members.filter { $0.slot == slot }
            guard let footing = tied.first?.law.footing else { continue }
            var low = SIMD2<Float>(repeating: .infinity)
            var high = SIMD2<Float>(repeating: -.infinity)
            var top = Float.infinity
            for member in tied {
                low = simd_min(low, SIMD2(member.rest.x, member.rest.y))
                high = simd_max(high, SIMD2(member.rest.x, member.rest.y))
                top = min(top, member.rest.z)
            }
            low -= footing.overhang
            high += footing.overhang
            let size = simd_max(high - low, SIMD2(repeating: 0.01))
            let middle = 0.5 * (low + high)
            let thickness = footing.thickness
            let centre = SIMD3(middle.x, middle.y, top - thickness / 2)
            let mass = footing.density * size.x * size.y * thickness
            let soilBed = FootingBed(width: size.x, length: size.y, soil: footing.soil)
            let impedance = soilBed.impedance
            typealias Mode = FootingImpedance.Mode
            let damped = footing.soil.radiationDamping
            let inertia = SIMD3<Float>(
                mass * (size.y * size.y + thickness * thickness) / 12
                    + impedance.trappedMass[Mode.rockingX.rawValue],
                mass * (size.x * size.x + thickness * thickness) / 12
                    + impedance.trappedMass[Mode.rockingY.rawValue],
                mass * (size.x * size.x + size.y * size.y) / 12)
            let first = bed.count
            let area = size.x * size.y
            let bearingMass = mass + bodyMass
            for point in soilBed.points {
                // Each point's dashpots in proportion to its springs, so that a point's dashpot
                // never outweighs its share of the bearing until the whole footing's does.
                let share = SIMD2(repeating: point.vertical / soilBed.stiffness[0])
                let dashpots: SIMD2<Float> =
                    damped
                    ? SIMD2(
                        impedance.dashpot[Mode.vertical.rawValue],
                        impedance.dashpot[Mode.horizontalX.rawValue])
                        * share
                    : 2 * contactDamping
                        * SIMD2(
                            (point.vertical * bearingMass * share.x).squareRoot(),
                            (point.horizontal.x * bearingMass * share.y).squareRoot())
                bed.append(
                    BedPoint(
                        placeAndBearing: SIMD4(
                            point.place.x, point.place.y, point.vertical,
                            (footing.soil.bearingCapacity ?? 0) * point.area),
                        shearAndDamping: SIMD4(point.horizontal.x, point.horizontal.y, dashpots.x, dashpots.y)
                    ))
            }
            let firstMember = memberList.count
            for member in tied {
                memberList.append(UInt32(member.entity))
                footingOf[member.entity] = UInt32(index + 1)
            }
            // Over a layer, with the soil's mass: the echoes.
            let layered = damped && impedance.layerDepth != nil && footing.soil.layerDepth != nil
            let firstEcho = echoes.count
            for mode in Mode.allCases {
                let weights = layered ? impedance.echoes(mode) : []
                echoes += weights + [Float](repeating: 0, count: Self.echoSlots - weights.count)
            }
            let depth = footing.soil.layerDepth ?? 0
            let trips = SIMD2(
                2 * depth / impedance.waveSpeed[Mode.vertical.rawValue],
                2 * depth / impedance.waveSpeed[Mode.horizontalX.rawValue])
            let firstHistory = historyLength
            if layered { historyLength += 10 * Self.historyCapacity }
            let rockingDashpot = SIMD2(
                impedance.dashpot[Mode.rockingX.rawValue], impedance.dashpot[Mode.rockingY.rawValue])
            let rockingStiffness = SIMD2(soilBed.stiffness[3], soilBed.stiffness[4])
            // The cone's internal rotary mass, ρ I z₀ = 3 C² / K.
            let rockingMass = SIMD2<Float>(
                rockingStiffness.x > 0 ? 3 * rockingDashpot.x * rockingDashpot.x / rockingStiffness.x : 0,
                rockingStiffness.y > 0 ? 3 * rockingDashpot.y * rockingDashpot.y / rockingStiffness.y : 0)
            let sums = soilBed.points.reduce(SIMD3<Float>.zero) {
                $0 + $1.vertical * SIMD3(1, $1.place.x * $1.place.x, $1.place.y * $1.place.y)
            }
            constants.append(
                Constants(
                    rest: SIMD4(centre, mass),
                    inertia: SIMD4(inertia, impedance.trappedMass[Mode.vertical.rawValue]),
                    base: SIMD4(0, 0, -thickness / 2, damped ? 0 : 1),
                    ranges: SIMD4(
                        UInt32(first), UInt32(soilBed.points.count), UInt32(firstMember), UInt32(tied.count)),
                    rocking: SIMD4(lowHalf: rockingDashpot, highHalf: rockingMass),
                    stiffness: SIMD4(
                        soilBed.stiffness[0], soilBed.stiffness[1], soilBed.stiffness[2], layered ? 1 : 0),
                    moreStiffness: SIMD4(
                        lowHalf: rockingStiffness,
                        highHalf: SIMD2(
                            impedance.dashpot[Mode.vertical.rawValue],
                            impedance.dashpot[Mode.horizontalX.rawValue])),
                    layer: SIMD4(lowHalf: trips, highHalf: trips / Float(Self.samplesPerTrip)),
                    history: SIMD4(
                        UInt32(firstHistory), UInt32(firstEcho), UInt32(Self.historyCapacity),
                        UInt32(Self.echoSlots)),
                    totals: SIMD4(sums, footing.soil.friction)))
            summaries.append(
                FootingSummary(
                    baseCentre: SIMD3(middle.x, middle.y, top - thickness), size: size, displacement: .zero,
                    rotation: .zero, velocity: .zero, soilForce: .zero, soilMoment: .zero, jointForce: .zero,
                    bearing: 1, uplift: 0, settlement: 0,
                    contact: SIMD4(-size.x / 2, size.x / 2, -size.y / 2, size.y / 2),
                    mass: mass))
            // Its highest frequency on the connection and the soil, as a free rigid body: each
            // spring alone against the mass or the least moment of inertia, and the dashpots'
            // rate.
            var translation: Float = soilBed.points.reduce(0) { $0 + max($1.vertical, $1.horizontal.max()) }
            var rotation: Float = soilBed.points.reduce(0) {
                $0 + max($1.vertical, $1.horizontal.max())
                    * (simd_length_squared($1.place) + thickness * thickness / 4)
            }
            for member in tied {
                let k = max(member.stiffness.normal, member.stiffness.shear) * member.area
                translation += k
                rotation += k * simd_length_squared(member.rest - centre)
            }
            let damping =
                bed[first...].reduce(Float(0)) { $0 + $1.shearAndDamping.z + $1.shearAndDamping.w } / mass
            frequencySquared = max(
                frequencySquared, translation / mass + rotation / inertia.min() + damping * damping)
        }
        count = constants.count
        guard count > 0 else { return nil }
        self.constants = constants
        self.frequencySquared = frequencySquared
        summariesAtRest = summaries
        pipeline = try ShaderLibrary.pipeline("footingStep", in: library)
        guard pipeline.maxTotalThreadsPerThreadgroup >= Self.threads else {
            throw BlastError.allocationFailed("footing threadgroup")
        }
        stateBuffer = try buffer(count * MemoryLayout<State>.stride, "footing states")
        constantBuffer = try buffer(count * MemoryLayout<Constants>.stride, "footing constants")
        constantBuffer.copy(constants)
        bedBuffer = try buffer(bed.count * MemoryLayout<BedPoint>.stride, "footing beds")
        bedBuffer.copy(bed)
        bedStateBuffer = try buffer(bed.count * 16, "footing bed states")
        memberBuffer = try buffer(memberList.count * 4, "footing members")
        memberBuffer.copy(memberList)
        footingOfBuffer = try buffer(footingOf.count * 4, "footing of each point")
        footingOfBuffer.copy(footingOf)
        linkBuffer = try buffer(max(entityCount, 1) * 32, "footing links")
        historyBuffer = try buffer(historyLength * 4, "footing echoes' history")
        echoBuffer = try buffer(echoes.count * 4, "footing echoes")
        echoBuffer.copy(echoes)
        reset()
    }

    /// Back at rest where it was built.
    func reset() {
        let states = stateBuffer.contents().bindMemory(to: State.self, capacity: count)
        for n in 0..<count { states[n] = State() }
        memset(bedStateBuffer.contents(), 0, bedStateBuffer.length)
        memset(linkBuffer.contents(), 0, linkBuffer.length)
        memset(historyBuffer.contents(), 0, historyBuffer.length)
    }

    /// Encodes one step of every footing, after a node pass.
    func encode(_ encoder: MTLComputeCommandEncoder, uniforms: Uniforms, control: MTLBuffer) {
        var uniforms = uniforms
        uniforms.footings = UInt32(count)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(stateBuffer, offset: 0, index: 0)
        encoder.setBuffer(constantBuffer, offset: 0, index: 1)
        encoder.setBuffer(bedBuffer, offset: 0, index: 2)
        encoder.setBuffer(bedStateBuffer, offset: 0, index: 3)
        encoder.setBuffer(memberBuffer, offset: 0, index: 4)
        encoder.setBuffer(linkBuffer, offset: 0, index: 5)
        encoder.setBuffer(historyBuffer, offset: 0, index: 6)
        encoder.setBuffer(echoBuffer, offset: 0, index: 7)
        encoder.setBuffer(control, offset: 0, index: 8)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 9)
        encoder.dispatchThreadgroups(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.threads, height: 1, depth: 1))
    }

    /// Each footing's state after the last step; read while the GPU is idle.
    func summaries() -> [FootingSummary] {
        let states = stateBuffer.contents().bindMemory(to: State.self, capacity: count)
        return (0..<count).map { n in
            let state = states[n]
            let c = constants[n]
            var summary = summariesAtRest[n]
            let rotation = simd_quatf(vector: state.rotation)
            let base = SIMD3(c.base.x, c.base.y, c.base.z)
            summary.displacement =
                SIMD3(state.centre.x, state.centre.y, state.centre.z) + rotation.act(base) - base
            summary.rotation = rotation.angle * (rotation.angle == 0 ? .zero : rotation.axis)
            let spin = SIMD3(state.spin.x, state.spin.y, state.spin.z)
            summary.velocity =
                SIMD3(state.velocity.x, state.velocity.y, state.velocity.z)
                + simd_cross(spin, rotation.act(base))
            summary.soilForce = SIMD3(state.soilForce.x, state.soilForce.y, state.soilForce.z)
            summary.soilMoment = SIMD3(state.soilMoment.x, state.soilMoment.y, state.soilMoment.z)
            summary.jointForce = SIMD3(state.jointForce.x, state.jointForce.y, state.jointForce.z)
            summary.bearing = state.soilForce.w
            summary.uplift = state.soilMoment.w
            summary.settlement = state.jointForce.w
            summary.contact = state.contact
            return summary
        }
    }

    /// Where the footing's material point that started at `rest` has moved, and the footing
    /// index plus one of an entity; for reading the connection's opening against the footing.
    func displacement(ofPointAt rest: SIMD3<Float>, footing: Int) -> SIMD3<Float> {
        let states = stateBuffer.contents().bindMemory(to: State.self, capacity: count)
        let state = states[footing]
        let c = constants[footing]
        let centre = SIMD3(c.rest.x, c.rest.y, c.rest.z)
        let rotation = simd_quatf(vector: state.rotation)
        return SIMD3(state.centre.x, state.centre.y, state.centre.z) + rotation.act(rest - centre)
            - (rest - centre)
    }

    func footing(ofEntity entity: Int) -> Int? {
        let values = footingOfBuffer.contents().bindMemory(
            to: UInt32.self, capacity: footingOfBuffer.length / 4)
        guard entity < footingOfBuffer.length / 4, values[entity] > 0 else { return nil }
        return Int(values[entity]) - 1
    }
}
