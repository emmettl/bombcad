import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Uniform air over a 100 m cube of 10 m cells, as two slices `duration` apart.
private func uniform(
    density: Float, velocity: SIMD3<Float> = .zero, pressure: Float = 101_325, from start: Double = 0,
    duration: Double
) -> (AirSlice, AirSlice) {
    let counts = SIMD3<Int32>(repeating: 10)
    var values: [Float16] = []
    for _ in 0..<1000 {
        values += [
            Float16(density), Float16(velocity.x), Float16(velocity.y), Float16(velocity.z),
            Float16(pressure / 1e6),
        ]
    }
    let ambient = Primitive(density: density, pressure: pressure)
    let a = AirSlice(
        time: start, cellSize: 10, grid: counts, first: .zero, counts: counts, stride: 1, values: values,
        ambient: ambient)
    var b = a
    b.time = start + duration
    return (a, b)
}

@Suite("Fragments and air slices")
struct FragmentCloudTests {
    @Test("Fragment scenes include every structural owner and preserve legacy decoding")
    func structuralOwners() throws {
        var scenario = Scenario(
            name: "Two walls", domainSize: SIMD3(repeating: 100), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(10, 50, 5)),
            structure: StructureModel(
                solids: [Box(x: 40...41, y: 40...60, height: 10)],
                material: .plainConcrete, elementSize: 0.5))
        let second = try scenario.addStructureObject(
            StructureModel(
                solids: [Box(x: 20...21, y: 40...60, height: 10)],
                material: .plainConcrete, elementSize: 0.5), name: "Near wall")
        let scene = FragmentScene(scenario)
        #expect(scene.structure.count == 2 && scene.structureOwners?.count == 2)
        try scenario.reorderObjects(scenario.objects.map(\.id).reversed())
        #expect(FragmentScene(scenario) == scene)
        let restored = try JSONDecoder().decode(FragmentScene.self, from: JSONEncoder().encode(scene))
        #expect(restored == scene)
        var cloud = FragmentCloud(
            particles: [
                .init(position: SIMD3(10, 50, 5), velocity: SIMD3(500, 0, 0), mass: 0.02, area: 1e-4)
            ],
            structure: restored.structure, structureOwners: restored.structureOwners)
        let (a, b) = uniform(density: 0, duration: 0.1)
        cloud.advance(from: a, to: b)
        let impact = try #require(cloud.impacts.first)
        #expect(impact.objectID == second && impact.surface == "structure")
        #expect(abs(impact.position.x - 20) < 1e-3)
        let legacy = Data(
            "{\"fragment\":0,\"time\":0.1,\"position\":[20,50,5],\"speed\":500,\"energy\":2500,\"surface\":\"structure\"}"
                .utf8)
        #expect(try JSONDecoder().decode(FragmentImpact.self, from: legacy).objectID == nil)
        var raw = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(scene)) as? [String: Any])
        raw.removeValue(forKey: "structureOwners")
        #expect(
            try JSONDecoder().decode(FragmentScene.self, from: JSONSerialization.data(withJSONObject: raw))
                .structureOwners == nil)
    }

    @Test("Gurney speeds and Mott masses")
    func launch() {
        var spec = FragmentSpec()
        spec.casingMass = 10
        spec.count = 20_000
        #expect(abs(spec.launchSpeed(chargeMass: 10) - 2440 / sqrt(1.5)) < 0.5)
        spec.casing = .sphere
        #expect(abs(spec.launchSpeed(chargeMass: 10) - 2440 / sqrt(1.6)) < 0.5)
        let scenario = Scenario(
            name: "Cased", domainSize: SIMD3(repeating: 40), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(20, 20, 1)))
        let cloud = FragmentCloud(spec: spec, scenario: scenario)
        let masses = cloud.particles.map(\.mass)
        #expect(cloud.fragmentCount == 20_000)
        // Their total is the casing's; Mott's median is μ (ln 2)², μ half the mean.
        #expect(abs(masses.reduce(0, +) / 10 - 1) < 1e-3)
        let median = masses.sorted()[masses.count / 2]
        let mu: Float = 10 / 20_000 / 2
        #expect(abs(median / (mu * 0.4805) - 1) < 0.06, "median \(median)")
        #expect(cloud.particles.allSatisfy { abs(simd_length($0.velocity) - cloud.launchSpeed) < 1e-3 })
    }

    @Test("Without air, a fragment falls on a parabola")
    func parabola() {
        var cloud = FragmentCloud(particles: [
            .init(position: SIMD3(10, 50, 20), velocity: SIMD3(15, 0, 0), mass: 0.01, area: 1e-4)
        ])
        var t = 0.0
        while cloud.airborne > 0, t < 5 {
            let (a, b) = uniform(density: 0, from: t, duration: 0.01)
            cloud.advance(from: a, to: b)
            t += 0.01
        }
        let fall = sqrt(2 * 20 / 9.81)
        let impact = cloud.impacts[0]
        #expect(impact.surface == "ground")
        #expect(abs(impact.time - Double(fall)) < 1e-3)
        #expect(abs(impact.position.x - (10 + 15 * Float(fall))) < 0.02)
    }

    @Test("In still air, drag slows a fragment as 1/(1 + k v₀ t)")
    func drag() {
        let mass: Float = 0.001
        let area: Float = 1e-4
        var cloud = FragmentCloud(particles: [
            .init(position: SIMD3(5, 50, 50), velocity: SIMD3(100, 0, 0), mass: mass, area: area)
        ])
        // Subsonic: a constant drag coefficient of 0.9.
        let (a, b) = uniform(density: 1.2, duration: 0.05)
        cloud.advance(from: a, to: b)
        let k = 1.2 * 0.9 * area / (2 * mass)
        let expected = 100 / (1 + k * 100 * 0.05)
        #expect(abs(cloud.particles[0].velocity.x / expected - 1) < 0.01)
    }

    @Test("A tracer goes with the air")
    func tracer() {
        var cloud = FragmentCloud(particles: [
            .init(position: SIMD3(10, 10, 10), velocity: .zero, mass: 0, area: 0)
        ])
        let (a, b) = uniform(density: 1.2, velocity: SIMD3(10, -5, 0), duration: 0.5)
        cloud.advance(from: a, to: b)
        #expect(simd_distance(cloud.particles[0].position, SIMD3(15, 7.5, 10)) < 0.01)
    }

    @Test("Impacts on a block are recorded at its face, with their energy")
    func impacts() {
        let block = Box(min: SIMD3(20, 40, 0), max: SIMD3(30, 60, 10))
        var cloud = FragmentCloud(
            particles: [
                .init(position: SIMD3(10, 50, 5), velocity: SIMD3(500, 0, 0), mass: 0.02, area: 1e-4)
            ],
            blocks: [block])
        let (a, b) = uniform(density: 0, duration: 0.1)
        cloud.advance(from: a, to: b)
        let impact = cloud.impacts[0]
        #expect(impact.surface == "block 0")
        #expect(abs(impact.position.x - 20) < 1e-3)
        #expect(abs(impact.time - 0.02) < 1e-4)
        #expect(abs(impact.energy - 0.5 * 0.02 * 500 * 500) / 2500 < 0.01)
        #expect(cloud.airborne == 0)
    }

    @Test("The region asked for covers every airborne particle and how far it can go")
    func region() throws {
        let cloud = FragmentCloud(particles: [
            .init(position: SIMD3(10, 10, 10), velocity: SIMD3(100, 0, 0), mass: 1, area: 1e-3),
            .init(position: SIMD3(20, 30, 5), velocity: .zero, mass: 1, area: 1e-3),
        ])
        let region = try #require(cloud.region(ahead: 0.1))
        #expect(region.speed == 100)
        #expect(region.box.min == SIMD3(0, 0, -5) && region.box.max == SIMD3(30, 40, 20))
    }

    @Test("A slice of the solver's air gives back its state, every cell or every second")
    func slice() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let scenario = Scenario(
            name: "Slice", domainSize: SIMD3(8, 8, 8), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.5)
        // Density rising along x, a wind along y.
        solver.mutateState { cells in
            for k in 0..<16 {
                for j in 0..<16 {
                    for i in 0..<16 {
                        cells[solver.grid.index(i, j, k)] = CellState(
                            Primitive(density: 1 + Float(i) * 0.1, velocity: SIMD3(0, 20, 0), pressure: 2e5),
                            gamma: 1.4)
                    }
                }
            }
        }
        for stride in [1, 2] {
            let slice = solver.airSlice(region: Box(min: SIMD3(1, 1, 1), max: SIMD3(6, 6, 6)), stride: stride)
            // Cell 5's centre is at 2.75 m: halfway to cell 6, 0.15 below cell 6's density.
            let air = try #require(slice.sample(SIMD3(3.0, 3, 3)))
            #expect(abs(air.density - 1.55) < 0.01)
            #expect(abs(air.velocity.y - 20) < 0.05 && abs(air.pressure - 2e5) < 200)
            // Outside the slice but inside the domain: unknown. Outside the domain: still air.
            #expect(slice.sample(SIMD3(7.8, 3, 3)) == nil)
            #expect(slice.sample(SIMD3(-1, 3, 3)) == slice.ambient)
        }
    }
}
