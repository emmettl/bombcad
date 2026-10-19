import BlastModel
import Foundation
import Metal
import simd

extension FootingShakingTest {
    /// Shakes `test`'s structure through its events one after another, a second's rest between,
    /// on sand of `shearModulus`; the base's acceleration is set every `interval` seconds.
    public static func run(
        device: MTLDevice, test: Test, series: [Series], shearModulus: Float = 80e6,
        bearingCapacity: Float = Self.bearingCapacity, friction: Float = 0.6, damping: Float = 0.2,
        cyclic: CyclicSand? = CyclicSand(), radiationDamping: Bool = true, interval: Double = 1e-3,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let started = ContinuousClock.now
        let h: Float = 0.2
        let parts = wallParts(test.structure, h: h)
        let stem = Box(min: .zero, max: SIMD3(length, 0.6, parts.split))
        let top = Box(min: SIMD3(0, 0, parts.split), max: SIMD3(length, 0.6, parts.height))
        // Both parts as stiff as each other, so that the wall bends as one.
        func material(_ density: Float) -> StructureMaterial {
            .elastic(density: density, youngsModulus: 10e9, poissonRatio: 0.2)
        }
        var model = StructureModel(
            solids: [stem, top], material: material(parts.densities.x), elementSize: h, fixedBase: true)
        model.setMaterial(material(parts.densities.y), of: 1)
        var joint = Anchorage(
            tensileStrength: 1e9, tensionOpening: 1, cohesion: 1e9, cohesionSlip: 1, friction: 1)
        var soil = Soil(
            material: SoilMaterial(shearModulus: shearModulus, poissonRatio: 0.3, density: 1657),
            bearingCapacity: bearingCapacity, friction: friction)
        soil.cyclic = cyclic
        soil.radiationDamping = radiationDamping
        joint.footing = Footing(
            overhang: SIMD2(0, (width - 0.6) / 2), thickness: thickness,
            density: footingMass / (length * width * thickness), soil: soil,
            embedment: test.structure.embedment > 0
                ? Embedment(depth: test.structure.embedment, frictionAngle: frictionAngle) : nil)
        model.baseAnchorage = joint
        // What kept the walls upright across the shaking: bearings against both faces over the
        // top 2 m, without friction or tie.
        for side in [JointSide.negativeY, .positiveY] {
            let y: Float = side == .negativeY ? 0 : 0.6
            model.supports.append(
                Box(
                    min: SIMD3(-0.01, y - 0.01, parts.height - 2.01),
                    max: SIMD3(length + 0.01, y + 0.01, parts.height + 0.01)))
            var guide = Anchorage.resting(friction: 0)
            guide.side = side
            model.supportAnchorages.append(guide)
        }
        let solver = try StructureSolver(device: device, model: model)
        let weight = (test.structure.wallMass + footingMass) * solver.gravity

        // Settle under gravity.
        solver.damping = 200
        solver.advance(steps: Int((0.5 / Double(solver.criticalTimeStep)).rounded()))
        solver.damping = damping
        guard let rest = solver.footingSummaries().first else {
            throw ImportedMesh.ImportError.invalid("The shaken wall has no footing.")
        }
        var result = Result()
        result.pressure = rest.soilForce.z / (length * width)
        let steps = max(1, Int((interval / Double(solver.criticalTimeStep)).rounded()))
        for (name, record) in zip(test.events, series) {
            var modelled = Series()
            let end = Double(record.time.last!) + 1
            var time = Double(record.time.first!)
            var lastSample = -1.0
            while time < end {
                let a = record.acceleration(at: time + interval / 2)
                solver.groundAcceleration = SIMD3(a * solver.gravity, 0, 0)
                solver.advance(steps: steps)
                time += interval
                guard time - lastSample >= 0.01 - 1e-9, let footing = solver.footingSummaries().first else {
                    continue
                }
                lastSample = time
                modelled.append(
                    Float(time), a, footing.rotation.y, -footing.soilMoment.y * 2 / (length * weight),
                    -footing.soilForce.x / weight, (footing.displacement.x - rest.displacement.x) / length,
                    -(footing.displacement.z - rest.displacement.z) / length)
            }
            solver.groundAcceleration = .zero
            result.events.append(modelled)
            result.profiles.append(FootingRockingTest.profile(solver))
            let s = modelled.summary
            progress?(
                String(
                    format:
                        "%@: rotation %+.4f / %+.4f rad, moment %.3f / %.3f, settlement %.4f L, energy %.4f",
                    name, s.rotation.x, s.rotation.y, s.moment.x, s.moment.y, s.settlement, s.energy))
        }
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
