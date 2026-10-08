import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Room meshes")
struct RoomMeshTests {
    static let plaster = SurfaceMaterial.uniform(0.1, name: "Plaster")

    static var lShape: ShoeboxRoom {
        var room = ShoeboxRoom(size: [8, 6, 2.6], material: plaster)
        room.plan = .lShape([8, 6], notch: [4, 3], material: plaster)
        return room
    }

    static func meshRoom(_ room: ShoeboxRoom) -> ShoeboxRoom {
        var meshed = room
        if let plan = room.plan {
            meshed.mesh = .extruding(plan, height: room.size.z, floor: room.floor, ceiling: room.ceiling)
        } else {
            meshed.mesh = .box(
                room.size,
                materials: Dictionary(uniqueKeysWithValues: Surface.allCases.map { ($0, room[$0]) }))
        }
        meshed.plan = nil
        return meshed
    }

    @Test("A box and an extruded floor plan make valid meshes with the right volume, area and normals")
    func shapes() throws {
        let box = Self.meshRoom(ShoeboxRoom(size: [5, 4, 3], material: Self.plaster))
        try box.validate()
        #expect(abs(box.volume - 60) < 1e-9)
        #expect(abs(box.surfaceArea - 94) < 1e-9)
        // Every normal points into the room: a point just inside each face's centre is in the room.
        for room in [box, Self.meshRoom(Self.lShape)] {
            let mesh = room.mesh!
            for face in mesh.faces.indices {
                // The centroid of the face's first triangle, which lies within these faces.
                let centre = mesh.faces[face].corners.prefix(3).map { mesh.vertices[$0] }.reduce(.zero, +) / 3
                #expect(room.contains(centre + 0.01 * mesh.normalAndArea(face).normal))
            }
        }
        let l = Self.meshRoom(Self.lShape)
        try l.validate()
        #expect(abs(l.volume - Self.lShape.volume) < 1e-9)
        #expect(abs(l.surfaceArea - Self.lShape.surfaceArea) < 1e-9)
    }

    @Test("Inside and clearance agree with the floor plan's at random points")
    func containment() {
        let plan = Self.lShape
        let mesh = Self.meshRoom(plan)
        var random = SplitMix(seed: 7)
        for _ in 0..<2_000 {
            let point = SIMD3(random.nextUnit(), random.nextUnit(), random.nextUnit()) * plan.size
            #expect(mesh.contains(point) == plan.contains(point), "\(point)")
            if plan.contains(point) {
                #expect(abs(mesh.clearance(point) - plan.clearance(point)) < 1e-9, "\(point)")
            }
        }
    }

    @Test("Open, turned or bent meshes are refused")
    func invalid() {
        let good = Self.meshRoom(ShoeboxRoom(size: [5, 4, 3], material: Self.plaster))
        var open = good
        open.mesh!.faces.removeLast()
        #expect(throws: AcousticError.self) { try open.validate() }
        var turned = good
        turned.mesh!.faces = turned.mesh!.faces.map {
            RoomMesh.Face(corners: $0.corners.reversed(), material: $0.material)
        }
        #expect(throws: AcousticError.self) { try turned.validate() }
        var bent = good
        bent.mesh!.vertices[7].z += 0.5
        #expect(throws: AcousticError.self) { try bent.validate() }
        var both = good
        both.plan = Self.lShape.plan
        #expect(throws: AcousticError.self) { try both.validate() }
    }

    /// Arrivals as (delay in samples, order, 1 kHz gain), sorted.
    private func arrivals(_ room: ShoeboxRoom, order: Int) -> [(Int, Int, Double)] {
        let source = SIMD3<Double>(1.3, 1.1, 1.2)
        let receiver = SIMD3<Double>(3.7, 2.4, 1.6)
        let model = ImageSourceModel(room: room, source: source, atmosphere: .standard, airAbsorption: false)
        var result: [(Int, Int, Double)] = []
        let add = { (delay: Double, order: Int, gains: [Double]) in
            result.append((Int((delay * 48_000).rounded()), order, gains[4]))
        }
        if let mesh = room.mesh {
            let images = MeshImageSources(geometry: .of(mesh), source: source).images(
                maximumOrder: order, reach: 100)
            _ = model.forEachMeshArrival(
                at: receiver, images: images.images, order: images.order, microphone: .omni, duration: 0.3,
                maximumOrder: order, includeDirect: true, stop: { false }, add)
        } else {
            _ = model.forEachArrival(at: receiver, duration: 0.3, maximumOrder: order, add)
        }
        return result.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
    }

    @Test("A box as a mesh has exactly the box's image sources, up to the third order")
    func imageSources() {
        var box = ShoeboxRoom(size: [5, 4, 3], material: Self.plaster)
        box.floor = .uniform(0.4, name: "Carpet")
        let expected = arrivals(box, order: 3)
        let meshed = arrivals(Self.meshRoom(box), order: 3)
        #expect(expected.count == meshed.count)
        for (a, b) in zip(expected, meshed) {
            #expect(a.0 == b.0 && a.1 == b.1 && abs(a.2 - b.2) < 1e-12, "\(a) against \(b)")
        }
    }

    @Test("An L-shaped plan as a mesh has the plan's image sources, hidden ones included")
    func planImageSources() throws {
        let plan = Self.lShape
        let mesh = Self.meshRoom(plan)
        let source = SIMD3<Double>(6.5, 1.2, 1.4)
        // Round the corner from the source, well clear of the line through the corner itself, where
        // whether a path is blocked is a matter of rounding.
        let receiver = SIMD3<Double>(1.0, 5.5, 1.2)
        let model = ImageSourceModel(room: plan, source: source, atmosphere: .standard, airAbsorption: false)
        let planImages = PlanImageSources(room: plan, plan: plan.plan!, source: source).images(
            maximumOrder: 2, reach: 100)
        var expected: [Int] = []
        func collectPlan(_ delay: Double, _: Int, _: [Double]) {
            expected.append(Int((delay * 48_000).rounded()))
        }
        _ = model.forEachPlanArrival(
            at: receiver, images: planImages.images, wallOrder: planImages.order, microphone: .omni,
            duration: 0.3, maximumOrder: 2, includeDirect: true, stop: { false }, collectPlan)
        let meshModel = ImageSourceModel(
            room: mesh, source: source, atmosphere: .standard, airAbsorption: false)
        let meshImages = MeshImageSources(geometry: .of(mesh.mesh!), source: source).images(
            maximumOrder: 2, reach: 100)
        var found: [Int] = []
        func collectMesh(_ delay: Double, _: Int, _: [Double]) {
            found.append(Int((delay * 48_000).rounded()))
        }
        _ = meshModel.forEachMeshArrival(
            at: receiver, images: meshImages.images, order: meshImages.order, microphone: .omni,
            duration: 0.3, maximumOrder: 2, includeDirect: true, stop: { false }, collectMesh)
        #expect(expected.sorted() == found.sorted(), "plan \(expected.sorted()) mesh \(found.sorted())")
        // No direct sound round the corner.
        let direct = Int(
            (simd_distance(source, receiver) / Atmosphere.standard.soundSpeed * 48_000).rounded())
        #expect(!found.contains(direct))
    }

    @Test("A box and an L-shaped plan as meshes give the same scattered energy and wave field")
    func tracerAndWaves() throws {
        for room in [ShoeboxRoom(size: [5, 4, 3], material: Self.plaster), Self.lShape] {
            var scattering = room
            scattering.floor.scattering = Array(repeating: 0.5, count: OctaveBands.count)
            scattering.plan?.walls[0].scattering = Array(repeating: 0.5, count: OctaveBands.count)
            scattering.west.scattering = Array(repeating: 0.5, count: OctaveBands.count)
            let meshed = Self.meshRoom(scattering)
            let receiver = SIMD3<Double>(3.5, 1.5, 1.2)
            func traced(_ room: ShoeboxRoom) -> Double {
                let tracer = DiffuseRayTracer(
                    room: room, source: [1.2, 1.1, 1.3], atmosphere: .standard, airAbsorption: false,
                    rayCount: 20_000, seed: 3)
                return tracer.trace(receivers: [receiver], duration: 0.3)[0][4].reduce(0, +)
            }
            let reference = traced(scattering)
            #expect(abs(traced(meshed) / reference - 1) < 0.05)

            var a = WaveSolver(room: scattering, sampleRate: 48_000, topFrequency: 150, atmosphere: .standard)
            var b = WaveSolver(room: meshed, sampleRate: 48_000, topFrequency: 150, atmosphere: .standard)
            a.engine = .cpu
            b.engine = .cpu
            let x = try #require(
                a.run(source: [1.2, 1.1, 1.3], receivers: [(receiver, .omni)], steps: 1024) { false })
            let y = try #require(
                b.run(source: [1.2, 1.1, 1.3], receivers: [(receiver, .omni)], steps: 1024) { false })
            let energy = x.signals[0].reduce(0) { $0 + $1 * $1 }
            let difference = zip(x.signals[0], y.signals[0]).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
            #expect(difference < 1e-8 * energy)
        }
    }

    @Test("A whole response for a box as a mesh matches the box's own")
    func generation() throws {
        var box = ShoeboxRoom(size: [6, 5, 3], material: .uniform(0.15, name: "Plaster"))
        box.floor = .uniform(0.3, name: "Carpet")
        box.floor.scattering = Array(repeating: 0.4, count: OctaveBands.count)
        var settings = RoomResponseSettings(
            room: box, source: RoomPoint(name: "S", position: [1.4, 1.2, 1.5]),
            receivers: [RoomPoint(name: "R", position: [4.3, 3.1, 1.2])], duration: 0.6,
            maximumReflectionOrder: 3,
            diffuseRays: 10_000, lowFrequencyModel: true, crossoverFrequency: 100)
        let reference = try RoomResponseGenerator.generate(settings)
        settings.room = Self.meshRoom(box)
        let meshed = try RoomResponseGenerator.generate(settings)
        for band in 0..<OctaveBands.count {
            let a = DecayAnalysis.octaveBand(reference.response.channels[0], sampleRate: 48_000, band: band)
            let b = DecayAnalysis.octaveBand(meshed.response.channels[0], sampleRate: 48_000, band: band)
            let ratio =
                b.reduce(0) { $0 + Double($1) * Double($1) } / a.reduce(0) { $0 + Double($1) * Double($1) }
            #expect(abs(10 * log10(ratio)) < 0.5, "band \(band): \(10 * log10(ratio)) dB")
        }
        #expect(meshed.diagnostics.waveCrossover == reference.diagnostics.waveCrossover)
    }
}
