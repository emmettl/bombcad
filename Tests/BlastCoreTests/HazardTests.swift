import Foundation
import Testing
import simd

@testable import BlastCore

@Suite("Fragment, glass and debris hazards")
struct HazardTests {
    private func impact(
        _ x: Float, _ y: Float = 0, energy: Float, weight: Float? = nil, surface: String = "ground"
    ) -> FragmentImpact {
        FragmentImpact(
            fragment: 0, time: 0, position: SIMD3(x, y, 0), speed: 1, energy: energy, surface: surface,
            weight: weight)
    }

    @Test("The hazard distance is the outer edge of the furthest cell over one per 55.7 m²")
    func hazardDistance() {
        // Along +x, a sector 10 m deep from 20 to 30 m covers 196 m², so 4 hazardous fragments
        // there are over the criterion (3.5); from 30 to 40 m it covers 275 m², and 3 are under.
        let impacts =
            Array(repeating: impact(25, energy: 100), count: 4)
            + Array(repeating: impact(35, energy: 100), count: 3)
            + [
                impact(55, energy: 100), impact(15, energy: 20), impact(15, energy: 1),
                impact(5, energy: 500, surface: "structure"),
            ]
        let tens: [Float] = stride(from: 0, through: 60, by: 10).map(Float.init)
        let hazard = GroundHazard(impacts: impacts, centre: .zero, edges: tens)
        #expect(hazard.rings == 6 && hazard.sectors == 8)
        #expect(hazard.sectorDistances[0] == 30)
        #expect(hazard.sectorDistances.dropFirst().allSatisfy { $0 == nil })
        #expect(hazard.hazardDistance == 30 && hazard.samplesAtDistance == 4)
        #expect(hazard.furthestHazardous == 55 && hazard.stoppedHazardous == 1)
        #expect(abs(hazard.hazardousShare - 0.8) < 1e-6 && abs(hazard.injuriousShare - 0.9) < 1e-6)
        #expect(abs(hazard.area(ring: 2) - .pi * 500 / 8) < 1e-3)
        // One flown fragment standing for five, behind the charge: over the criterion there too,
        // but set by one sample.
        let weighted = GroundHazard(
            impacts: impacts + [impact(-25, energy: 100, weight: 5)], centre: .zero, edges: tens)
        #expect(weighted.sectorDistances[4] == 30 && weighted.hazard(sector: 4) > 0.02)
        #expect(weighted.summary.contains("hazardous fragment distance 30 m (set by 4 flown; fly more)"))
    }

    @Test("Rings grow by a tenth from a metre out, past the furthest landing")
    func ringEdges() {
        let edges = GroundHazard.edges(reaching: 240)
        #expect(edges[0] == 0 && edges[1] == 1 && abs(edges[2] - 1.1) < 1e-6)
        #expect(edges.last! > 240 && edges[edges.count - 2] <= 240)
        #expect(zip(edges.dropFirst(2), edges.dropFirst()).allSatisfy { abs($0 / $1 - 1.1) < 1e-5 })
        let hazard = GroundHazard(impacts: [impact(240, 0, energy: 1)], centre: .zero)
        #expect(hazard.rings == edges.count - 1 && hazard.hazardDistance == nil)
        // A dense patch of hazardous fragments between 100 and 110 m: the distance is the edge
        // just past it, within a tenth.
        let patch = (0..<400).map { impact(100 + Float($0 % 10), energy: 100) }
        let near = GroundHazard(impacts: patch, centre: .zero)
        #expect(near.hazardDistance! >= 110 && near.hazardDistance! < 121)
    }

    @Test(
        "In flight: hazardous fragments crossing spheres near the horizontal, per unit area across their paths"
    )
    func inFlight() throws {
        // A hundred 100 g fragments flying level along +x from 10 m up at 300 m/s: 4.5 kJ each,
        // all in the first direction, a sphere's cell there R² (π/4) 2 sin 10° m² across, so over
        // one per 55.7 m² out to 143 m, where they still fly.
        let particles = (0..<100).map { _ in
            FragmentCloud.Particle(
                position: SIMD3(0, 0, 10), velocity: SIMD3(300, 0, 0), mass: 0.1, area: 1.5 * 0.0234 * 0.0234)
        }
        var cloud = FragmentCloud(particles: particles, centre: SIMD3(0, 0, 10))
        cloud.land(in: Primitive(density: 1.2, pressure: 101_325))
        let crossings = cloud.crossings
        let first = try #require(crossings.radii.firstIndex { $0 > 100 })
        #expect(
            crossings.counts[first * crossings.sectors] == 100
                && crossings.samples[first * crossings.sectors] == 100)
        #expect(
            crossings.counts.enumerated().allSatisfy { $0.offset % crossings.sectors == 0 || $0.element == 0 }
        )
        let hazard = GroundHazard(impacts: cloud.impacts, centre: .zero, crossings: crossings)
        let expected = try #require(
            crossings.radii.last { $0 * $0 * (.pi / 4) * 2 * sin(10 * Float.pi / 180) <= 100 * 55.7 })
        #expect(hazard.airDistances?[0] == expected && abs(expected - 142) < 1)
        // All landing together, far out, they crowd one cell on the ground, which goes further.
        #expect(hazard.airDistance == expected && hazard.groundDistance! > expected)
        #expect(hazard.hazardDistance == hazard.groundDistance && hazard.summary.contains("in flight 142 m"))
    }

    @Test("Glass is graded by where it lands: GSA's conditions and ASTM F1642's ratings")
    func glazing() {
        let still = GlazingHazard.thrown(speed: 0, height: 1.5)
        #expect(still.condition == .threeA && still.rating == .minimal && still.landsAtM == 0)
        let slow = GlazingHazard.thrown(speed: 2, height: 1.5)
        #expect(slow.condition == .threeB && slow.rating == .veryLow)
        #expect(abs(slow.landsAtM! - 2 * (3 / 9.81).squareRoot()) < 1e-9)
        let low = GlazingHazard.thrown(speed: 8, height: 1)
        #expect(low.condition == .four && low.rating == .low && low.panelHeightM! < 0.5)
        // Between ASTM's 0.5 m and GSA's 0.6 m: a 4 by GSA, high by ASTM.
        let between = GlazingHazard.thrown(speed: (9 * 4.905 / 0.8).squareRoot(), height: 1.35)
        #expect(abs(between.panelHeightM! - 0.55) < 1e-9)
        #expect(between.condition == .four && between.rating == .high)
        let fast = GlazingHazard.thrown(speed: 10, height: 1.5)
        #expect(fast.condition == .five && fast.rating == .high)
        #expect(GlazingHazard.Condition.five > .threeB && GlazingHazard.Condition.threeA > .two)
    }

    @Test("Broken glass keeps the load's push until the load stops pushing in")
    func brokenGlass() {
        var response = SDOFResponse(yieldDeflection: 0.01, equivalentElasticDeflection: 0.01, period: 0.01)
        let pressures: [Double] = [2000, 2000, 2000, -100, 2000]
        #expect(
            GlazingHazard.broken(
                response: response, netPa: pressures, binS: 1e-3, massPerArea: 15, paneHeight: 1)
                == .whole)
        response.lostResistanceAt = 1.05e-3
        response.velocityAtLoss = 5
        let hazard = GlazingHazard.broken(
            response: response, netPa: pressures, binS: 1e-3, massPerArea: 15, paneHeight: 1.2)
        // The rest of bin 1 (0.95 ms) and bin 2 at 2 kPa on 15 kg/m², then it stops.
        #expect(abs(hazard.speedMS - (5 + 2000 * 1.95e-3 / 15)) < 1e-9)
        #expect(hazard == GlazingHazard.thrown(speed: hazard.speedMS, height: 0.9 + 0.6))
        // Breaking on the rebound, moving out: it falls by the sill.
        response.velocityAtLoss = -3
        let outward = GlazingHazard.broken(
            response: response, netPa: pressures, binS: 1e-3, massPerArea: 15, paneHeight: 1.2)
        #expect(outward.speedMS == 0 && outward.condition == .threeA)
    }

    @Test("A window's damage carries its glass's hazard, and the building its worst")
    func envelopeGlazing() throws {
        let owner = UUID()
        let pane = EnvelopeComponentLoad(
            id: "pane", owner: owner, kind: .pane,
            region: Box(min: SIMD3(0, 0, 1), max: SIMD3(0.006, 1.2, 2.5)),
            axis: 0, binS: 1e-4, outerPa: Array(repeating: 60_000, count: 100), innerPa: [])
        let construction = EnvelopeConstruction.assumed(objectID: owner)
        let damage = try #require(EnvelopeDamageAssessment.assess(pane, construction: construction))
        let glazing = try #require(damage.glazing)
        #expect(damage.failedAtS != nil && glazing.speedMS > 10 && glazing.condition == .five)
        let building = EnvelopeDamageAssessment.assess(loads: [pane], constructions: { _ in construction })
        #expect(building.first?.worstGlazing == glazing)
        // A skylight is not graded.
        var skylight = pane
        skylight.axis = 2
        #expect(EnvelopeDamageAssessment.assess(skylight, construction: construction)?.glazing == nil)
    }

    @Test("Rubble flies on to land; pieces at rest lie where they are")
    func debris() {
        func piece(_ position: SIMD3<Float>, _ velocity: SIMD3<Float>, mass: Float = 2) -> RubbleParticle {
            var particle = RubbleParticle()
            (particle.x, particle.y, particle.z) = (position.x, position.y, position.z)
            (particle.vx, particle.vy, particle.vz) = (velocity.x, velocity.y, velocity.z)
            particle.mass = mass
            particle.volume = mass / 2400
            particle.reach = 0.05
            particle.alive = 1
            return particle
        }
        let rubble = [
            piece(SIMD3(10, 0, 5), SIMD3(30, 0, 0)), piece(SIMD3(8, 0, 0.05), .zero),
            piece(SIMD3(8, 0, 3), SIMD3(0.2, 0, 0)), piece(SIMD3(8, 0, 3), .zero, mass: 0),
        ]
        let result = DebrisResult(
            rubble: rubble, centre: .zero, ambient: Primitive(density: 1.2, pressure: 101_325))
        #expect(result.pieces == 3 && result.impacts.count == 3 && abs(result.mass - 6) < 1e-6)
        #expect(result.impacts.map(\.surface) == ["ground", "ground", "structure"])
        let flown = result.impacts[0]
        #expect(flown.position.x > 20 && flown.position.x < 40 && flown.energy > 79)
        #expect(result.impacts[1].energy == 0)
        #expect(result.hazard.furthestHazardous == flown.position.x)
    }
}

extension GroundHazard {
    /// The densest cell's density in a sector, per m².
    fileprivate func hazard(sector: Int) -> Float {
        (0..<rings).map { density(ring: $0, sector: sector) }.max() ?? 0
    }
}
