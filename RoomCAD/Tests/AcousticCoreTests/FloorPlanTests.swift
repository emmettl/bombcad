import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Floor plans")
struct FloorPlanTests {
    let material = SurfaceMaterial.uniform(0.2, scattering: 0.3, name: "Plaster")
    let source = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "S", position: [1.3, 1.1, 1.2])
    let receiver = RoomPoint(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "R", position: [3.7, 2.9, 1.6])

    private func boxAndPlan(_ size: SIMD3<Double>) -> (box: ShoeboxRoom, plan: ShoeboxRoom) {
        let box = ShoeboxRoom(size: size, material: material)
        var plan = box
        plan.plan = .rectangle([size.x, size.y], material: material)
        return (box, plan)
    }

    @Test("A rectangular plan gives exactly the box's image-source arrivals")
    func rectangleImages() {
        let (box, plan) = boxAndPlan([5, 4, 3])
        let boxModel = ImageSourceModel(
            room: box, source: source.position, atmosphere: .standard, airAbsorption: true)
        let planModel = ImageSourceModel(
            room: plan, source: source.position, atmosphere: .standard, airAbsorption: true)
        var boxArrivals: [(Double, Double)] = []
        boxModel.forEachArrival(at: receiver.position, duration: 0.2, maximumOrder: 4) { d, _, g in
            boxArrivals.append((d, g[3]))
        }
        let images = PlanImageSources(room: plan, plan: plan.plan!, source: source.position).images(
            maximumOrder: 4, reach: 0.2 * 343.2)
        var planArrivals: [(Double, Double)] = []
        let never = { false }
        _ = planModel.forEachPlanArrival(
            at: receiver.position, images: images.images, wallOrder: images.order, microphone: .omni,
            duration: 0.2, maximumOrder: 4, includeDirect: true, stop: never
        ) { d, _, g in planArrivals.append((d, g[3])) }
        #expect(planArrivals.count == boxArrivals.count)
        // Images the same distance away sort by gain.
        func sorted(_ arrivals: [(Double, Double)]) -> [(Double, Double)] {
            arrivals.sorted { abs($0.0 - $1.0) > 1e-12 ? $0.0 < $1.0 : $0.1 < $1.1 }
        }
        let a = sorted(boxArrivals)
        let b = sorted(planArrivals)
        let worst = zip(a, b).map { max(abs($0.0 - $1.0), abs($0.1 - $1.1)) }.max() ?? 0
        #expect(worst < 1e-12, "worst difference \(worst)")
    }

    @Test("A rectangular plan gives the box's scattered energy and its wave field")
    func rectangleRaysAndWaves() throws {
        let (box, plan) = boxAndPlan([5, 4, 3])
        func rays(_ room: ShoeboxRoom) -> Double {
            DiffuseRayTracer(
                room: room, source: source.position, atmosphere: .standard, airAbsorption: false,
                rayCount: 20_000, seed: 2
            )
            .trace(receivers: [receiver.position], duration: 0.3)[0][4].reduce(0, +)
        }
        #expect(abs(rays(plan) / rays(box) - 1) < 0.03)
        func wave(_ room: ShoeboxRoom) throws -> [Double] {
            let solver = WaveSolver(room: room, sampleRate: 48_000, topFrequency: 150, atmosphere: .standard)
            let result = solver.simulate(
                source: source.position, receivers: [(receiver.position, .omni)], steps: 2_048,
                stop: { false })
            return try #require(result)[0]
        }
        let a = try wave(box)
        let b = try wave(plan)
        let difference = zip(a, b).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
        #expect(difference < 1e-8 * a.reduce(0) { $0 + $1 * $1 })
    }

    /// An L: 8 × 6 m without its north-east 4 × 3 m.
    let lRoom: ShoeboxRoom = {
        var room = ShoeboxRoom(size: [8, 6, 3], material: .uniform(0.2, scattering: 0.3, name: "Plaster"))
        room.plan = .lShape(
            [8, 6], notch: [4, 3], material: .uniform(0.2, scattering: 0.3, name: "Plaster"))
        return room
    }()

    @Test("Round the corner of an L there is no direct sound, but there are reflections")
    func occlusion() throws {
        // The source in the south-east arm; one receiver out of sight in the north-west arm.
        let source = RoomPoint(name: "S", position: [7, 1.5, 1.5])
        let hidden = RoomPoint(name: "Hidden", position: [1.5, 5, 1.5])
        let visible = RoomPoint(name: "Visible", position: [2, 1.5, 1.5])
        let model = ImageSourceModel(
            room: lRoom, source: source.position, atmosphere: .standard, airAbsorption: false)
        let images = PlanImageSources(room: lRoom, plan: lRoom.plan!, source: source.position).images(
            maximumOrder: 6, reach: 0.3 * 343.2)
        func first(_ point: RoomPoint) -> (delay: Double, count: Int) {
            var delays: [Double] = []
            let never = { false }
            _ = model.forEachPlanArrival(
                at: point.position, images: images.images, wallOrder: images.order, microphone: .omni,
                duration: 0.3, maximumOrder: 6, includeDirect: true, stop: never
            ) { d, _, _ in delays.append(d) }
            return (delays.min() ?? .infinity, delays.count)
        }
        let c = Atmosphere.standard.soundSpeed
        let hiddenFirst = first(hidden)
        #expect(hiddenFirst.delay > simd_distance(source.position, hidden.position) / c + 1e-4)
        #expect(hiddenFirst.count > 0)
        #expect(abs(first(visible).delay - simd_distance(source.position, visible.position) / c) < 1e-12)
        // A whole response there works too.
        let settings = RoomResponseSettings(
            room: lRoom, source: source, receivers: [hidden], airAbsorption: false, duration: 0.3,
            diffuseRays: 5_000)
        let result = try RoomResponseGenerator.generate(settings, cancellation: CancellationFlag())
        #expect(result.response.channels[0].contains { $0 != 0 })
    }

    @Test("Rays in a rigid, fully scattering L arrive at the diffuse-field rate 4πc/V")
    func lShapeNormalization() {
        var rigid = lRoom
        rigid.floor = .uniform(0, scattering: 1, name: "Rigid")
        rigid.ceiling = rigid.floor
        rigid.plan!.walls = Array(repeating: rigid.floor, count: 6)
        #expect(abs(rigid.volume - 108) < 1e-9)
        let energy = DiffuseRayTracer(
            room: rigid, source: [7, 1.5, 1.5], atmosphere: .standard, airAbsorption: false, rayCount: 20_000,
            seed: 3
        ).trace(receivers: [[2, 1.5, 1.5], [1.5, 5, 1.5]], duration: 0.5)
        let expected = 4 * Double.pi * Atmosphere.standard.soundSpeed / rigid.volume
        for receiver in energy {
            #expect(abs(receiver[4][200..<500].reduce(0, +) / 0.3 / expected - 1) < 0.05)
        }
    }

    @Test("Plans must be simple, anticlockwise, inside the room's bounds, and contain the points")
    func validation() {
        let base = RoomResponseSettings(
            room: lRoom, source: RoomPoint(name: "S", position: [7, 1.5, 1.5]),
            receivers: [RoomPoint(name: "R", position: [2, 1.5, 1.5])])
        #expect(throws: Never.self) { try base.validate() }
        var outside = base
        outside.receivers[0].position = [6, 5, 1.5]  // in the missing corner
        #expect(throws: AcousticError.self) { try outside.validate() }
        var clockwise = base
        clockwise.room.plan!.corners.reverse()
        #expect(throws: AcousticError.self) { try clockwise.validate() }
        var crossed = base
        crossed.room.plan = FloorPlan(corners: [[0, 0], [8, 6], [8, 0], [0, 6]], material: material)
        #expect(throws: AcousticError.self) { try crossed.validate() }
        #expect(abs(lRoom.surfaceArea - (2 * 36 + 28 * 3)) < 1e-9)
    }
}
