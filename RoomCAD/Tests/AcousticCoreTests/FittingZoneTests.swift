import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Fitted zones")
struct FittingZoneTests {
    let size: SIMD3<Double> = [5, 4, 3]
    let source: SIMD3<Double> = [1.3, 1.1, 1.2]
    let receiver: SIMD3<Double> = [3.7, 2.9, 1.6]

    /// Seating up to 1 m over most of the floor.
    static let seating = FittingZone(
        name: "Seats", low: [0.5, 0.5, 0], high: [4.5, 3.5, 1], density: 0.8,
        absorption: Array(repeating: 0.2, count: 8))

    @Test("The direct sound loses exp(−q d) of its energy crossing d metres of a zone")
    func direct() {
        var room = ShoeboxRoom(size: size, material: .anechoic)
        // A slab 1 m thick across the whole room, between x = 2 and 3.
        room.fittings = [
            FittingZone(
                name: "Slab", low: [2, 0, 0], high: [3, 4, 3], density: 0.7,
                absorption: Array(repeating: 0, count: 8))
        ]
        let model = ImageSourceModel(room: room, source: source, atmosphere: .standard, airAbsorption: false)
        var gains: [Double] = []
        model.forEachArrival(at: receiver, duration: 0.1, maximumOrder: 0) { _, _, g in gains.append(g[0]) }
        let r = simd_distance(source, receiver)
        // The path crosses the slab over 1 m of x, so r / (3.7 − 1.3) metres of its length.
        let inside = r / 2.4
        #expect(gains.count == 1)
        #expect(abs(gains[0] * gains[0] * r * r - exp(-0.7 * inside)) < 1e-12)
    }

    @Test("A folded box path runs from the receiver to the source and stays in the room")
    func folding() {
        #expect(abs(fold(-0.3, length: 2) - 0.3) < 1e-12)
        #expect(abs(fold(4.5, length: 2) - 0.5) < 1e-12)
        #expect(abs(fold(2.5, length: 2) - 1.5) < 1e-12)
        let model = ImageSourceModel(
            room: ShoeboxRoom(size: size, material: .anechoic), source: source, atmosphere: .standard,
            airAbsorption: false)
        let images = model.axisImages(
            length: size.x, source: source.x, receiver: receiver.x, reach: 30, low: [1], high: [1])
        for image in images.prefix(8) {
            // The image along x, with the source's own y and z.
            let unfolded = SIMD3(receiver.x + image.offset, source.y, source.z)
            let path = ImageSourceModel.boxPath(from: receiver, to: unfolded, size: size)
            #expect(simd_distance(path.first!, receiver) < 1e-12)
            #expect(simd_distance(path.last!, source) < 1e-9)
            #expect(path.count == image.order + 2)
            // Folding keeps the length.
            let length = zip(path, path.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
            #expect(abs(length - simd_distance(receiver, unfolded)) < 1e-9)
        }
    }

    /// Arrivals as (delay in samples, 1 kHz gain), sorted.
    private func arrivals(_ room: ShoeboxRoom, source: SIMD3<Double>, receiver: SIMD3<Double>, order: Int)
        -> [(Int, Double)]
    {
        let model = ImageSourceModel(room: room, source: source, atmosphere: .standard, airAbsorption: false)
        var result: [(Int, Double)] = []
        func add(_ delay: Double, _: Int, _ gains: [Double]) {
            result.append((Int((delay * 48_000).rounded()), gains[4]))
        }
        if let mesh = room.mesh {
            let images = MeshImageSources(geometry: .of(mesh), source: source).images(
                maximumOrder: order, reach: 100)
            _ = model.forEachMeshArrival(
                at: receiver, images: images.images, order: images.order, microphone: .omni, duration: 0.3,
                maximumOrder: order, includeDirect: true, stop: { false }, add)
        } else if let plan = room.plan {
            let images = PlanImageSources(room: room, plan: plan, source: source).images(
                maximumOrder: order, reach: 100)
            _ = model.forEachPlanArrival(
                at: receiver, images: images.images, wallOrder: images.order, microphone: .omni,
                duration: 0.3,
                maximumOrder: order, includeDirect: true, stop: { false }, add)
        } else {
            model.forEachArrival(at: receiver, duration: 0.3, maximumOrder: order, add)
        }
        return result.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
    }

    @Test("Box, floor-plan and mesh image sources lose the same energy crossing a zone")
    func imageSourcesAgree() {
        var box = ShoeboxRoom(size: size, material: .uniform(0.2, name: "Plaster"))
        box.fittings = [Self.seating]
        let rectangle = RoomMeshTests.meshRoom(box)
        var plan = box
        plan.plan = .rectangle([5, 4], material: box.west)
        let reference = arrivals(box, source: source, receiver: receiver, order: 3)
        // The zone weakens some arrivals.
        var bare = box
        bare.fittings = nil
        let unweakened = arrivals(bare, source: source, receiver: receiver, order: 3)
        #expect(zip(reference, unweakened).contains { $0.1 < 0.9 * $1.1 })
        for other in [rectangle, plan] {
            let found = arrivals(other, source: source, receiver: receiver, order: 3)
            #expect(found.count == reference.count)
            for (a, b) in zip(reference, found) {
                #expect(a.0 == b.0 && abs(a.1 - b.1) < 1e-9, "\(a) against \(b)")
            }
        }
        // An L-shaped plan and its mesh, with the zone in the corner the notch leaves.
        var l = RoomMeshTests.lShape
        l.fittings = [
            FittingZone(
                name: "Desks", low: [0.5, 0.5, 0], high: [3.5, 5.5, 0.8], density: 1.2,
                absorption: Array(repeating: 0.1, count: 8))
        ]
        let lSource: SIMD3<Double> = [6.5, 1.2, 1.4]
        let lReceiver: SIMD3<Double> = [1.0, 5.5, 1.2]
        let planned = arrivals(l, source: lSource, receiver: lReceiver, order: 2)
        let meshed = arrivals(RoomMeshTests.meshRoom(l), source: lSource, receiver: lReceiver, order: 2)
        #expect(planned.count == meshed.count)
        for (a, b) in zip(planned, meshed) {
            #expect(a.0 == b.0 && abs(a.1 - b.1) < 1e-9, "\(a) against \(b)")
        }
    }

    @Test("Rays keep their energy in a zone that does not absorb: a rigid room still fills at 4πc/V")
    func raysConserveEnergy() {
        var room = ShoeboxRoom(size: size, material: .rigid)
        room.fittings = [
            FittingZone(
                name: "Everything", low: [0, 0, 0], high: size, density: 0.5,
                absorption: Array(repeating: 0, count: 8))
        ]
        let tracer = DiffuseRayTracer(
            room: room, source: source, atmosphere: .standard, airAbsorption: false, rayCount: 20_000, seed: 3
        )
        let energy = tracer.trace(receivers: [receiver], duration: 0.5)
        let expected = 4 * Double.pi * Atmosphere.standard.soundSpeed / room.volume
        // By 200 ms almost every ray has met an object (q c t ≈ 34), so the rays carry all the energy.
        let rate = energy[0][4][200..<500].reduce(0, +) / 0.3
        #expect(abs(rate / expected - 1) < 0.03)
    }

    @Test("Objects that absorb make a rigid room decay at c q α, as Sabine's formula with 4 q α V predicts")
    func absorbingObjects() throws {
        // Objects 5 m apart on average, the room's size. Much denser objects make sound spread by diffusion,
        // so a receiver away from the source sees the room's decay only once the energy has spread.
        var room = ShoeboxRoom(size: size, material: .rigid)
        let zone = FittingZone(
            name: "Everything", low: [0, 0, 0], high: size, density: 0.2,
            absorption: Array(repeating: 0.5, count: 8))
        room.fittings = [zone]
        let c = Atmosphere.standard.soundSpeed
        let expected = 6 * log(10) / (c * 0.2 * 0.5)
        let eyring = try #require(
            room.eyringReverberationTime(atmosphere: .standard, airAbsorption: false)[4])
        #expect(abs(eyring / expected - 1) < 1e-12)
        #expect(abs(zone.absorptionArea[4] - 4 * 0.2 * 0.5 * 60) < 1e-9)
        let settings = RoomResponseSettings(
            room: room, source: RoomPoint(name: "S", position: source),
            receivers: [RoomPoint(name: "R", position: receiver)], airAbsorption: false, duration: 0.6,
            maximumReflectionOrder: 40, diffuseRays: 20_000, lowFrequencyModel: false)
        let result = try RoomResponseGenerator.generate(settings)
        // Single bands of one random realization vary by a few percent, with the specular part's
        // interference early on, so compare their mean.
        var times: [Double] = []
        for band in 4...6 {
            let filtered = DecayAnalysis.octaveBand(
                result.response.channels[0], sampleRate: 48_000, band: band)
            times.append(try #require(DecayAnalysis.reverberationTime(filtered, sampleRate: 48_000)))
        }
        let mean = times.reduce(0, +) / Double(times.count)
        #expect(abs(mean / expected - 1) < 0.04, "\(times) s against \(expected) s")
    }

    @Test("Zones must be valid and inside the room, and rooms saved without them still load")
    func validation() throws {
        var room = ShoeboxRoom(size: size, material: .uniform(0.2, name: "Plaster"))
        room.fittings = [Self.seating]
        try room.validate()
        var outside = room
        outside.fittings![0].high.x = 6
        #expect(throws: AcousticError.self) { try outside.validate() }
        var dense = room
        dense.fittings![0].density = -1
        #expect(throws: AcousticError.self) { try dense.validate() }
        var overlapping = room
        overlapping.fittings!.append(Self.seating)
        overlapping.fittings![1].low.z = 0.5
        overlapping.fittings![1].high.z = 2
        #expect(throws: AcousticError.self) { try overlapping.validate() }
        var touching = room
        touching.fittings!.append(Self.seating)
        touching.fittings![1].low.z = 1
        touching.fittings![1].high.z = 2
        try touching.validate()
        var inverted = room
        inverted.fittings![0].low.z = 2
        #expect(throws: AcousticError.self) { try inverted.validate() }
        // A room encoded before zones existed.
        var plain = room
        plain.fittings = nil
        let data = try JSONEncoder().encode(plain)
        let decoded = try JSONDecoder().decode(ShoeboxRoom.self, from: data)
        #expect(decoded.fittings == nil)
        #expect(try JSONDecoder().decode(ShoeboxRoom.self, from: JSONEncoder().encode(room)) == room)
        // Objects counted in a zone give their density.
        let chairs = FittingZone.objects(
            "Chairs", low: [0, 0, 0], high: [10, 5, 1], count: 100, area: 2,
            absorption: Array(repeating: 0, count: 8))
        #expect(abs(chairs.density - 100 * 2 / (4 * 50)) < 1e-12)
    }
}
