import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Footings on a hillside (`FootingGround`): level footings stepped into the slope, their soil read
/// from the terrain, against Vesić's ground factor on the bearing capacity and Coulomb's earth
/// pressures on sloping ground.
@Suite("Footings on a slope", .gpuThreads)
struct FootingSlopeTests {
    let material = StructureMaterial.elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2)
    let g: Float = 9.81
    let angle: Float = 20
    /// The ground stands 4 m up at x = 10, where the blocks stand, rising along +x from below x = 0.
    var terrain: Terrain {
        let rise = tan(angle * .pi / 180)
        return .slope(domain: SIMD3(20, 20, 10), spacing: 0.5, foot: 10 - 4 / rise, angle: angle)
    }

    @Test(
        "Coulomb's pressures are Rankine's on level ground; downhill the passive falls, uphill the active rises"
    )
    func pressures() {
        let embedment = Embedment(depth: 0.5)
        let phi = embedment.frictionAngle
        let level = embedment.sloping(rise: 0)
        #expect(
            abs(level.active / embedment.active - 1) < 1e-5
                && abs(level.passive / embedment.passive - 1) < 1e-5)
        #expect(level.atRest == embedment.atRest)
        // At the steepest slope the soil stands, both wedges lie along it: cos²φ.
        #expect(abs(embedment.sloping(rise: -tan(phi)).passive / pow(cos(phi), 2) - 1) < 1e-4)
        #expect(abs(embedment.sloping(rise: tan(phi)).active / pow(cos(phi), 2) - 1) < 1e-4)
        let down = embedment.sloping(rise: -tan(angle * .pi / 180))
        let up = embedment.sloping(rise: tan(angle * .pi / 180))
        #expect(down.passive < 0.55 * level.passive && up.passive > level.passive)
        #expect(up.active > level.active && down.active < level.active)
        #expect(up.atRest >= up.active)
    }

    @Test(
        "A plane's slope is read exactly; the uphill side is buried deeper; the ground factor is (1 − tan β)²"
    )
    func ground() {
        let ground = FootingGround(terrain: terrain, centre: SIMD2(10, 10), base: 3.5, size: SIMD2(2, 2))
        let rise = tan(angle * .pi / 180)
        #expect(abs(ground.gradient.x - rise) < 1e-4 && abs(ground.gradient.y) < 1e-5)
        #expect(abs(ground.depth(at: .zero) - 0.5) < 1e-4)
        #expect(abs(ground.depth(at: SIMD2(-1, 0)) - (0.5 - rise)) < 1e-4)
        #expect(abs(ground.rise(away: SIMD2(-1, 0)) + rise) < 1e-4)
        #expect(abs(ground.fall - rise) < 1e-4 && simd_distance(ground.downhill, SIMD2(-1, 0)) < 1e-4)
        #expect(abs(ground.bearingFactor(frictionAngle: 35 * .pi / 180) - pow(1 - rise, 2)) < 1e-4)
        // On a plateau b back from its crest (at x = 12), the fall over 4B is (1 − b/4B) of the
        // slope's: at the crest the face's, from 4B back none.
        let plateau = Terrain.sampled(domain: SIMD3(30, 20, 10), spacing: 0.5) { min(4, ($0.x - 1) * rise) }
        func fall(back b: Float) -> Float {
            FootingGround(terrain: plateau, centre: SIMD2(13 + b, 10), base: 3.5, size: SIMD2(2, 2)).fall
        }
        for b in [0, 2, 4, 6] as [Float] {
            #expect(abs(fall(back: b) / rise - max(1 - b / 8, 0)) < 0.02, "\(b): \(fall(back: b) / rise)")
        }
    }

    @Test(
        "Sides in the slope: the uphill side bears from deeper and gives more passive, and the stiffness holds"
    )
    func sides() {
        let soil = Soil(bearingCapacity: nil, cyclic: nil)
        let embedment = Embedment(depth: 0.5)
        let bed = FootingBed(width: 2, length: 2, soil: soil, embedment: embedment, thickness: 0.5)
        let level = FootingSides(
            width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment, base: bed.stiffness)
        // The ground as deep over the base everywhere as the level embedment: the same sides.
        let flat = Terrain.sampled(domain: SIMD3(20, 20, 10), spacing: 0.5) { _ in 4 }
        let even = FootingSides(
            width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment, base: bed.stiffness,
            ground: FootingGround(terrain: flat, centre: SIMD2(10, 10), base: 3.5, size: SIMD2(2, 2)))
        for (a, b) in zip(level.stiffness, even.stiffness) { #expect(abs(a / b - 1) < 1e-4) }
        let sloped = FootingSides(
            width: 2, length: 2, thickness: 0.5, soil: soil, embedment: embedment, base: bed.stiffness,
            ground: FootingGround(terrain: terrain, centre: SIMD2(10, 10), base: 3.5, size: SIMD2(2, 2)))
        func deepest(_ normal: SIMD2<Float>) -> SIMD3<Float> {
            sloped.points.filter { $0.normal == normal }.map(\.pressures).max { $0.z < $1.z } ?? .zero
        }
        let uphill = deepest(SIMD2(1, 0))
        let downhill = deepest(SIMD2(-1, 0))
        #expect(uphill.x > 2 * downhill.x && uphill.z > 4 * downhill.z)
        // Every point lies within the side's height in the ground.
        #expect(sloped.points.allSatisfy { $0.place.z <= 0.5 + 1e-6 && $0.pressures.x >= 0 })
    }

    /// A 1 m block on a footing 2 m square and 0.5 m thick, standing on the slope at x = 10 through
    /// a support region at the ground's height there, its base `embedment` below it (or on it).
    private func block(embedment: Embedment?, soil: Soil, height: Float = 1) throws -> StructureSolver {
        let device = try #require(MTLCreateSystemDefaultDevice(), "This test needs a Metal device")
        let top: Float = 4 + (embedment == nil ? 0.5 : 0.5 - embedment!.depth)
        var model = StructureModel(
            solids: [Box(min: SIMD3(9.5, 9.5, top), max: SIMD3(10.5, 10.5, top + height))],
            material: material,
            elementSize: 0.25, fixedBase: false)
        model.supports = [Box(min: SIMD3(9.49, 9.49, top - 0.01), max: SIMD3(10.51, 10.51, top + 0.01))]
        var joint = Anchorage.dowelled(ratio: BaseConnection.dowelRatio)
        joint.footing = Footing(overhang: SIMD2(0.5, 0.5), thickness: 0.5, soil: soil, embedment: embedment)
        model.setAnchorage(joint, ofSupport: 0)
        return try StructureSolver(device: device, model: model.standing(on: terrain))
    }

    private func steps(_ solver: StructureSolver, seconds: Double) -> Int {
        max(1, Int((seconds / Double(solver.criticalTimeStep)).rounded()))
    }

    @Test(
        "On the slope a footing bears (1 − tan β)² of the level capacity: past it it sinks, below it it holds"
    )
    func bearing() throws {
        let soil = Soil(bearingCapacity: 300e3, radiationDamping: false, cyclic: nil)
        func sink(_ fraction: Float) throws -> (sunk: Float, factor: Float) {
            // On the surface, its base on the ground at its centre.
            let solver = try block(embedment: nil, soil: soil)
            solver.groundContact = false
            let footing = solver.footingSummaries()[0]
            var bodyMass: Float = 0
            solver.mutateNodes { bodyMass = $0.reduce(0) { $0 + $1.mass } }
            let weight = (bodyMass + footing.mass) * g
            solver.damping = 100
            for n in 1...20 {
                solver.gravity = g * fraction * footing.capacity / weight * Float(n) / 20
                solver.advance(steps: steps(solver, seconds: 0.01))
            }
            solver.advance(steps: steps(solver, seconds: 0.3))
            let before = solver.footingSummaries()[0].displacement.z
            solver.advance(steps: steps(solver, seconds: 0.2))
            return (before - solver.footingSummaries()[0].displacement.z, footing.bearingFactor)
        }
        let holds = try sink(0.8)
        let sinks = try sink(1.2)
        let rise = tan(angle * .pi / 180)
        #expect(abs(holds.factor - pow(1 - rise, 2)) < 1e-3, "\(holds.factor)")
        // The load, and so the excess the damped block sinks under, is the slope's share of level
        // ground's: it sinks the slower for it, but far faster than below the capacity.
        #expect(holds.sunk < 2e-3, "\(holds.sunk)")
        #expect(sinks.sunk > 0.01 && sinks.sunk > 10 * holds.sunk, "\(sinks.sunk)")
    }

    /// How far the embedded block's footing slides along x in 0.4 s under `push` newtons on its
    /// face (towards +x, uphill, when positive), after settling.
    private func slide(push: Float) throws -> (settled: Float, slid: Float) {
        let soil = Soil(bearingCapacity: nil, friction: 0.5, cyclic: nil)
        let solver = try block(embedment: Embedment(depth: 0.5), soil: soil, height: 0.5)
        solver.damping = 200
        solver.advance(steps: steps(solver, seconds: 0.1))
        solver.damping = 0
        let start = Float(solver.time)
        let settled = solver.footingSummaries()[0].displacement.x
        solver.appliedLoad = PressureLoad(
            axis: 0, positiveSide: push < 0,
            history: [
                SIMD2(0, 0), SIMD2(start, 0), SIMD2(start + 0.05, abs(push) / 0.5),
                SIMD2(start + 10, abs(push) / 0.5),
            ])
        solver.advance(steps: steps(solver, seconds: 0.4))
        return (settled, solver.footingSummaries()[0].displacement.x - settled)
    }

    @Test(
        "Embedded in the slope a footing stands, holds a push uphill and slides under the same push downhill")
    func passive() throws {
        // The level footing's resistance (EmbedmentTests.passive): base friction, (Kₚ − Kₐ) γ D² / 2
        // across the faces and the sides' friction on the pressure at rest.
        let embedment = Embedment(depth: 0.5)
        let gamma: Float = 1900 * 9.81
        let pressure = gamma * 0.5 * 0.5 / 2
        let probe = try block(embedment: embedment, soil: Soil(friction: 0.5, cyclic: nil), height: 0.5)
        var bodyMass: Float = 0
        probe.mutateNodes { bodyMass = $0.reduce(0) { $0 + $1.mass } }
        let weight = (bodyMass + probe.footingSummaries()[0].mass) * g
        let resistance =
            0.5 * weight + (embedment.passive - embedment.active) * pressure * 2
            + 2 * embedment.wallFriction * embedment.atRest * pressure * 2
        let uphill = try slide(push: 0.8 * resistance)
        let downhill = try slide(push: -0.8 * resistance)
        // The deeper uphill side pushes it down the slope, and its base holds it.
        #expect(abs(uphill.settled) < 2e-3, "\(uphill.settled)")
        #expect(abs(uphill.slid) < 5e-3, "\(uphill.slid)")
        #expect(downhill.slid < -0.05, "\(downhill.slid)")
    }
}
