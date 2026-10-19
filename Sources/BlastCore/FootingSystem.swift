import BlastModel
import Foundation
import Metal
import simd

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
        var sides: SIMD4<UInt32> = .zero
        var embedded: SIMD4<Float> = .zero
        var cyclic: SIMD4<Float> = .zero
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
        var elastic: SIMD4<Float> = .zero
        var sideForce: SIMD4<Float> = .zero
    }

    /// Layout matches `SidePoint` in Footing.metal.
    struct SidePoint {
        var placeAndArea: SIMD4<Float>
        var normalAndStiffness: SIMD4<Float>
        var pressures: SIMD4<Float>
    }

    /// Layout matches `BedPoint` in Footing.metal.
    struct BedPoint {
        var placeAndBearing: SIMD4<Float>
        var shearAndDamping: SIMD4<Float>
        /// Cyclic sand: the point's first-loading stiffness against its unloading one (0: off).
        var virgin: SIMD4<Float> = .zero
    }

    /// Layout matches `FootingUniforms`.
    struct Uniforms {
        var fixedStep: Float
        var criticalStep: Float
        var substep: UInt32
        var gravity: Float
        var damping: Float
        var footings: UInt32
        /// The ground's acceleration (`StructureSolver.groundAcceleration`).
        var groundX: Float = 0
        var groundY: Float = 0
        var groundZ: Float = 0
        var unused: UInt32 = 0
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
    private let sideBuffer: MTLBuffer
    private let sideStateBuffer: MTLBuffer
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
    /// for the damping of a bed of massless soil. On `terrain`, each is set in the ground it
    /// stands in (`FootingGround`).
    init?(
        device: MTLDevice, library: MTLLibrary, members: [Member], entityCount: Int, bodyMass: Float,
        contactDamping: Float, terrain: Terrain? = nil
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
        var sidePoints: [SidePoint] = []
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
            // On a terrain, the ground the footing stands in: its embedment as deep as the
            // surface stands over the base round its sides, on average for the stiffness and on
            // the shallowest side for the overburden that bears on the base; none out of it.
            let ground = terrain.map {
                FootingGround(terrain: $0, centre: middle, base: top - thickness, size: size)
            }
            var embedment = footing.embedment
            var overburden = footing.embedment
            if let ground, let given = footing.embedment {
                let perimeter = (0..<16).flatMap { k -> [Float] in
                    let s = (Float(k) + 0.5) / 16 - 0.5
                    return [
                        ground.depth(at: SIMD2(size.x / 2, s * size.y)),
                        ground.depth(at: SIMD2(-size.x / 2, s * size.y)),
                        ground.depth(at: SIMD2(s * size.x, size.y / 2)),
                        ground.depth(at: SIMD2(s * size.x, -size.y / 2)),
                    ]
                }
                let mean = perimeter.reduce(0) { $0 + max($1, 0) } / Float(perimeter.count)
                let least = perimeter.min() ?? 0
                embedment =
                    mean > 1e-3
                    ? Embedment(
                        depth: mean, frictionAngle: given.frictionAngle, sideFriction: given.sideFriction)
                    : nil
                overburden =
                    least > 1e-3
                    ? Embedment(
                        depth: least, frictionAngle: given.frictionAngle, sideFriction: given.sideFriction)
                    : nil
            }
            let soilBed = FootingBed(
                width: size.x, length: size.y, soil: footing.soil, embedment: embedment,
                thickness: thickness)
            let sides = embedment.map {
                FootingSides(
                    width: size.x, length: size.y, thickness: thickness, soil: footing.soil, embedment: $0,
                    base: soilBed.stiffness, ground: ground)
            }
            // Set into the soil, the base bears the overburden's share as well; on a slope, less.
            let slopeFactor =
                ground?.bearingFactor(frictionAngle: footing.embedment?.frictionAngle ?? 35 * .pi / 180) ?? 1
            let capacity = footing.soil.bearingCapacity.map { surface in
                (overburden?.bearingCapacity(
                    surface: surface, width: size.x, length: size.y, material: footing.soil.material)
                    ?? surface) * slopeFactor
            }
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
            // Cyclic sand unloads and reloads stiffer than it is first loaded.
            let unloading = footing.soil.cyclic.map { 1 / $0.elasticShare } ?? 1
            func vertical(_ point: FootingBed.Point) -> Float { unloading * point.vertical }
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
                            point.place.x, point.place.y, vertical(point),
                            (capacity ?? 0) * point.area),
                        shearAndDamping: SIMD4(
                            point.horizontal.x, point.horizontal.y, dashpots.x, dashpots.y),
                        virgin: SIMD4(footing.soil.cyclic?.elasticShare ?? 0, 0, 0, 0)))
            }
            let firstSide = sidePoints.count
            for point in sides?.points ?? [] {
                sidePoints.append(
                    SidePoint(
                        placeAndArea: SIMD4(point.place, point.area),
                        normalAndStiffness: SIMD4(point.normal.x, point.normal.y, point.across, point.along),
                        pressures: SIMD4(point.pressures, footing.embedment?.wallFriction ?? 0)))
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
                $0 + vertical($1) * SIMD3(1, $1.place.x * $1.place.x, $1.place.y * $1.place.y)
            }
            // Cyclic sand: on, its memory, and its heave by Gajan's 1 − 1/FS.
            var cyclic = SIMD4<Float>.zero
            if let sand = footing.soil.cyclic {
                let safety = (capacity ?? .infinity) * area / max(bearingMass * 9.81, 1e-30)
                cyclic = SIMD4(1, sand.memory, sand.heave * max(1 - 1 / safety, 0), 0)
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
                    totals: SIMD4(sums, footing.soil.friction),
                    sides: SIMD4(UInt32(firstSide), UInt32(sides?.points.count ?? 0), 0, 0),
                    embedded: SIMD4(
                        lowHalf: sides?.rocking ?? .zero, highHalf: sides?.rockingLimit ?? .zero),
                    cyclic: cyclic))
            summaries.append(
                FootingSummary(
                    baseCentre: SIMD3(middle.x, middle.y, top - thickness), size: size, displacement: .zero,
                    rotation: .zero, velocity: .zero, soilForce: .zero, soilMoment: .zero, jointForce: .zero,
                    bearing: 1, uplift: 0, settlement: 0,
                    contact: SIMD4(-size.x / 2, size.x / 2, -size.y / 2, size.y / 2),
                    mass: mass, groundSlope: ground?.gradient ?? .zero, bearingFactor: slopeFactor,
                    capacity: capacity.map { $0 * area } ?? .infinity))
            // Its highest frequency on the connection and the soil, as a free rigid body: each
            // spring alone against the mass or the least moment of inertia, and the dashpots'
            // rate.
            var translation: Float = soilBed.points.reduce(0) {
                $0 + max(vertical($1), $1.horizontal.max())
            }
            var rotation: Float = soilBed.points.reduce(0) {
                $0 + max(vertical($1), $1.horizontal.max())
                    * (simd_length_squared($1.place) + thickness * thickness / 4)
            }
            for point in sides?.points ?? [] {
                let k = max(point.across, point.along) * point.area
                translation += k
                rotation += k * simd_length_squared(point.place + SIMD3(0, 0, -thickness / 2))
            }
            rotation += sides.map { max($0.rocking.x, $0.rocking.y) } ?? 0
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
        bedStateBuffer = try buffer(bed.count * 32, "footing bed states")
        sideBuffer = try buffer(sidePoints.count * MemoryLayout<SidePoint>.stride, "footing sides")
        sideBuffer.copy(sidePoints)
        sideStateBuffer = try buffer(sidePoints.count * 16, "footing side states")
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
        memset(sideStateBuffer.contents(), 0, sideStateBuffer.length)
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
        encoder.setBuffer(sideBuffer, offset: 0, index: 10)
        encoder.setBuffer(sideStateBuffer, offset: 0, index: 11)
        encoder.dispatchThreadgroups(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: Self.threads, height: 1, depth: 1))
    }

    /// Each footing's state after the last step; read while the GPU is idle.
    /// The first footing's bed: each point's place from the base centre and how far the soil's
    /// surface under it has sunk for good (m, positive down); read while the GPU is idle.
    func bedSurface() -> [(place: SIMD2<Float>, sunk: Float)] {
        guard let c = constants.first else { return [] }
        let points = bedBuffer.contents().bindMemory(
            to: BedPoint.self, capacity: bedBuffer.length / MemoryLayout<BedPoint>.stride)
        let states = bedStateBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: bedStateBuffer.length / 16)
        return (Int(c.ranges.x)..<Int(c.ranges.x + c.ranges.y)).map { p in
            (SIMD2(points[p].placeAndBearing.x, points[p].placeAndBearing.y), -states[2 * p].z)
        }
    }

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
            summary.sideForce = SIMD3(state.sideForce.x, state.sideForce.y, state.sideForce.z)
            summary.sideGiveWay = state.sideForce.w
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
