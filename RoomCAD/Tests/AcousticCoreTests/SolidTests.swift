import Foundation
import Testing
import simd

@testable import AcousticCore

@Suite("Solids")
struct SolidTests {
    static let materials = [SurfaceMaterial.uniform(0.1, name: "Plaster"), .uniform(0.3, name: "Seating")]

    private func room(_ solid: Solid) throws -> ShoeboxRoom {
        var room = ShoeboxRoom(size: [1, 1, 1], material: Self.materials[0])
        room.mesh = solid.room(materials: Self.materials)
        room = room.fittingMesh()
        try room.validate()
        return room
    }

    @Test("Unions, cuts and intersections of boxes and prisms enclose the volumes they should")
    func volumes() throws {
        let a = Solid.box([0, 0, 0], [6, 4, 3], material: 0)
        let b = Solid.box([4, 1, 0], [9, 3, 2], material: 0)
        #expect(abs(try room(a.union(b)).volume - (72 + 20 - 8)) < 1e-6)
        // A balcony slab cut out of the air: it touches the walls, so the room wraps round it.
        let slab = Solid.box([0, 0, 1.5], [6, 1, 1.8], material: 1)
        let cut = try room(a.subtracting(slab))
        #expect(abs(cut.volume - (72 - 1.8)) < 1e-6)
        // A raked hall: a long section with a floor rising 1.5 m over 10 m and a ceiling falling 1 m,
        // across a fan-shaped plan 12 m wide at the back and 8 m at the front.
        let section = Solid.extrusion(
            [[0, 0], [10, 1.5], [10, 7], [0, 8]], along: 1, from: -10, to: 10, sides: [1, 0, 0, 0],
            ends: (0, 0))
        let plan = Solid.extrusion(
            [[0, -4], [10, -6], [10, 6], [0, 4]], along: 2, from: -1, to: 10, sides: [0, 0, 0, 0],
            ends: (0, 0))
        let hall = try room(section.intersection(plan))
        // Height 8 - 0.25 x and width 8 + 0.4 x, integrated over x from 0 to 10.
        let expected = (0...1000).map { i -> Double in
            let x = Double(i) / 100
            return (8 - 0.25 * x) * (8 + 0.4 * x) * (i == 0 || i == 1000 ? 0.5 : 1) / 100
        }.reduce(0, +)
        #expect(abs(hall.volume / expected - 1) < 1e-6)
        // The raked floor kept its seating.
        #expect(hall.mesh!.faces.contains { $0.material == 1 && hall.mesh!.normalAndArea(0).area > 0 })
    }

    @Test("A box built in two pieces, its walls cut in two, has exactly the box's image sources")
    func fragmentedBox() throws {
        let joined = Solid.box([0, 0, 0], [3, 4, 3], material: 0).union(
            Solid.box([3, 0, 0], [5, 4, 3], material: 0))
        let pieces = try room(joined)
        #expect(pieces.mesh!.faces.count > 6)
        let box = ShoeboxRoom(size: [5, 4, 3], material: Self.materials[0])
        let source = SIMD3<Double>(1.3, 1.1, 1.2)
        let receiver = SIMD3<Double>(3.7, 2.4, 1.6)
        var expected: [Int] = []
        _ = ImageSourceModel(room: box, source: source, atmosphere: .standard, airAbsorption: false)
            .forEachArrival(at: receiver, duration: 0.3, maximumOrder: 3) { delay, _, _ in
                expected.append(Int((delay * 48_000).rounded()))
            }
        let images = MeshImageSources(geometry: .of(pieces.mesh!), source: source).images(
            maximumOrder: 3, reach: 100)
        var found: [Int] = []
        func collect(_ delay: Double, _: Int, _: [Double]) { found.append(Int((delay * 48_000).rounded())) }
        _ = ImageSourceModel(room: pieces, source: source, atmosphere: .standard, airAbsorption: false)
            .forEachMeshArrival(
                at: receiver, images: images.images, order: images.order, microphone: .omni, duration: 0.3,
                maximumOrder: 3, includeDirect: true, stop: { false }, collect)
        #expect(expected.sorted() == found.sorted())
    }

    @Test("Rays never slip through the seams of a hall built from pieces, and the wave solver fills it")
    func watertight() throws {
        let section = Solid.extrusion(
            [[0, 0], [12, 2], [12, 8], [0, 9]], along: 1, from: -8, to: 8, sides: [0, 0, 0, 0], ends: (0, 0))
        let plan = Solid.extrusion(
            [[0, -5], [12, -7], [12, 7], [0, 5]], along: 2, from: -1, to: 10, sides: [0, 0, 0, 0],
            ends: (0, 0))
        let balcony = Solid.box([9, -8, 4.5], [13, 8, 5.0], material: 0)
        var hall = try room(section.intersection(plan).subtracting(balcony))
        // Rigid and fully scattering: energy can only leave through a gap.
        hall.mesh!.materials = [
            SurfaceMaterial(
                name: "Rigid", absorption: Array(repeating: 0, count: 8),
                scattering: Array(repeating: 1, count: 8), reference: "Test")
        ]
        try hall.validate()
        let tracer = DiffuseRayTracer(
            room: hall, source: [2, 7, 3], atmosphere: .standard, airAbsorption: false, rayCount: 10_000,
            seed: 5)
        let energy = tracer.trace(receivers: [[7, 9, 3]], duration: 0.4)[0][4]
        let early = energy[100..<150].reduce(0, +)
        let late = energy[350..<400].reduce(0, +)
        #expect(abs(late / early - 1) < 0.1, "\(late / early)")

        var solver = WaveSolver(room: hall, sampleRate: 48_000, topFrequency: 80, atmosphere: .standard)
        solver.engine = .cpu
        let layout = solver.gridLayout(source: [2, 7, 3], receivers: [([7, 9, 3], .omni)])
        let cell = solver.spacing.x * solver.spacing.y * solver.spacing.z
        // The simulated cells fill the hall's volume, within the staircase's error.
        #expect(abs(Double(layout.inside.filter { $0 == 1 }.count) * cell / hall.volume - 1) < 0.05)
    }
}
