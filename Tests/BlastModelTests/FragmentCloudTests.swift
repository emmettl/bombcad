import Foundation
import Testing
import simd

@testable import BlastModel

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
        // Below Mach 0.5: a constant drag coefficient of 0.82, Hansche and Rinehart's tumbling cubes at Mach 0.5.
        let (a, b) = uniform(density: 1.2, duration: 0.05)
        cloud.advance(from: a, to: b)
        let k = 1.2 * 0.82 * area / (2 * mass)
        let expected = 100 / (1 + k * 100 * 0.05)
        #expect(abs(cloud.particles[0].velocity.x / expected - 1) < 0.01)
    }

    @Test("Mott's scaling gives Cooper's Example 27.7: 140 fragments, 1 over 10 g, 87 over 0.1 g")
    func cooperExample() throws {
        // A steel cylinder 1 in inside, a quarter-inch wall, 1 in long, B = 0.08 (Detasheet).
        var spec = FragmentSpec()
        spec.wallThickness = 0.25 * 0.0254
        spec.innerDiameter = 0.0254
        spec.mottCoefficient = 0.08
        spec.casingMass = 0.279 * 0.453_592_37
        spec.count = 200_000
        let factor = try #require(spec.mottFactor)
        #expect(abs(factor - 0.0315) < 0.0001)
        #expect(abs(spec.realFragmentCount - 140.6) < 0.2)
        let scenario = Scenario(
            name: "Cylinder", domainSize: SIMD3(repeating: 10), boxes: [],
            charge: Charge(mass: 0.0114, position: SIMD3(5, 5, 1)))
        let cloud = FragmentCloud(spec: spec, scenario: scenario)
        // Each flown fragment stands for as many real ones as share the casing's mass: Mott's
        // masses vary by √5 times their mean, so 200,000 drawn are within about 1% of it.
        let weight = cloud.particles[0].weight
        #expect(cloud.particles.allSatisfy { $0.weight == weight })
        #expect(abs(Double(weight) * 200_000 / spec.realFragmentCount - 1) < 0.02)
        // Counts over each mass, as Cooper's table has them (rounded down: 1, 2, 5, 13, 31, 87).
        for (grams, expected) in [(10.0, 1.26), (5.0, 5.02), (1.0, 31.7), (0.1, 87.7)] {
            let over =
                Double(weight) * Double(cloud.particles.filter { Double($0.mass) > grams / 1000 }.count)
            #expect(abs(over / expected - 1) < 0.05, "over \(grams) g: \(over)")
        }
        // Gurney, his Example 27.8: M/C 6.39, √(2E) 2,357 m/s, 0.898 km/s.
        var gurney = FragmentSpec()
        gurney.casingMass = 6.39
        gurney.gurneyVelocity = 2357
        #expect(abs(gurney.launchSpeed(chargeMass: 1) - 898) < 1)
    }

    @Test("Grady's exponent keeps the mean and the casing's mass, and an explosive sets B and √(2E)")
    func exponentAndExplosive() throws {
        var spec = FragmentSpec()
        spec.casingMass = 10
        spec.count = 20_000
        spec.massExponent = 1
        let scenario = Scenario(
            name: "Cased", domainSize: SIMD3(repeating: 40), boxes: [],
            charge: Charge(mass: 10, position: SIMD3(20, 20, 1)))
        let masses = FragmentCloud(spec: spec, scenario: scenario).particles.map(\.mass)
        #expect(abs(masses.reduce(0, +) / 10 - 1) < 1e-3)
        // Exponential: the median is the mean times ln 2.
        let median = masses.sorted()[masses.count / 2]
        #expect(abs(median / (10 / 20_000 * 0.6931) - 1) < 0.05)
        let decoded = try JSONDecoder().decode(
            FragmentSpec.self,
            from: Data(#"{"explosive": "composition b", "casingMass": 1, "count": 10}"#.utf8))
        #expect(decoded.gurneyVelocity == 2720 && decoded.massExponent == 0.5)
        #expect(throws: (any Error).self) {
            var bad = decoded
            bad.explosive = "Plastic"
            try bad.validate()
        }
        // Saved as it was before the exponent, when it is Mott's.
        let saved = try #require(String(data: JSONEncoder().encode(decoded), encoding: .utf8))
        #expect(!saved.contains("massExponent"))
    }

    @Test("Fragments in the air when the blast ends fly on in still air until they land")
    func landing() {
        var cloud = FragmentCloud(particles: [
            .init(position: SIMD3(5, 50, 1), velocity: SIMD3(300, 0, 20), mass: 0.01, area: 1e-4),
            .init(position: SIMD3(8, 8, 8), velocity: .zero, mass: 0, area: 0),
        ])
        let (a, b) = uniform(density: 1.2, duration: 0.01)
        cloud.advance(from: a, to: b)
        #expect(cloud.airborne == 2)
        cloud.land(in: Primitive(density: 1.2, pressure: 101_325))
        #expect(cloud.impacts.count == 1 && cloud.impacts[0].surface == "ground")
        #expect(cloud.impacts[0].position.x > 100 && cloud.impacts[0].speed < 300)
        // The tracer stays where it was, still in the air.
        #expect(!cloud.particles[1].landed && cloud.particles[1].position == SIMD3(8, 8, 8))
    }

    @Test("The drag coefficient follows the measured tumbling curve")
    func dragCurve() {
        #expect(FragmentCloud.dragCoefficient(mach: 0.2) == 0.82)
        #expect(abs(FragmentCloud.dragCoefficient(mach: 1.25) - 1.25) < 1e-6)
        #expect(abs(FragmentCloud.dragCoefficient(mach: 3) - 1.1) < 1e-6)
        #expect(FragmentCloud.dragCoefficient(mach: 6) == 1.1)
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
}
