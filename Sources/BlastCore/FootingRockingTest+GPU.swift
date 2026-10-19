import BlastModel
import Foundation
import Metal
import simd

extension FootingRockingTest {
    /// The soil's surface under the footing along x, averaged across it.
    static func profile(_ solver: StructureSolver) -> [SIMD2<Float>] {
        let points = solver.footingBedSurface()
        let xs = Set(points.map(\.place.x)).sorted()
        return xs.map { x in
            let row = points.filter { $0.place.x == x }
            return SIMD2(x, row.map(\.sunk).reduce(0, +) / Float(row.count))
        }
    }

    /// Rocks the wall through `packets`, on sand of `shearModulus`, its cycles no faster than
    /// `speed` m/s at the actuator, the actuator's push set every `interval` seconds.
    public static func run(
        device: MTLDevice, shearModulus: Float = 40e6, bearingCapacity: Float = Self.bearingCapacity,
        friction: Float = 0.6, packets: [Packet] = Self.packets, speed: Float = 0.2, interval: Double = 1e-3,
        cyclic: CyclicSand? = CyclicSand(), progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let started = ContinuousClock.now
        let h: Float = 0.2
        let wallHeight: Float = 8.6
        let thickness: Float = 0.65
        let wall = Box(min: .zero, max: SIMD3(length, 0.6, wallHeight))
        // Masses: the footing's and the wall's, so that together they weigh 29 Mg with their
        // centre of mass 4.5 m above the footing's base.
        let wallCentre = thickness + wallHeight / 2
        let wallMass = mass * (4.5 - thickness / 2) / (wallCentre - thickness / 2)
        let footingMass = mass - wallMass
        let material = StructureMaterial.elastic(
            density: wallMass / (length * 0.6 * wallHeight), youngsModulus: 10e9, poissonRatio: 0.2)
        var model = StructureModel(solids: [wall], material: material, elementSize: h, fixedBase: true)
        // Cast into the footing: a joint far stronger than anything the test asks of it.
        var joint = Anchorage(
            tensileStrength: 1e9, tensionOpening: 1, cohesion: 1e9, cohesionSlip: 1, friction: 1)
        joint.footing = Footing(
            overhang: SIMD2(0, (width - 0.6) / 2), thickness: thickness,
            density: footingMass / (length * width * thickness),
            soil: Soil(
                material: SoilMaterial(shearModulus: shearModulus, poissonRatio: 0.3, density: 1657),
                bearingCapacity: bearingCapacity, friction: friction))
        joint.footing?.soil.cyclic = cyclic
        model.baseAnchorage = joint
        // The test's Teflon guides, which kept the wall from falling over sideways: bearings
        // against both its faces across y over its top 2 m, with friction 0.1 and no tie.
        for side in [JointSide.negativeY, .positiveY] {
            let y: Float = side == .negativeY ? 0 : 0.6
            model.supports.append(
                Box(
                    min: SIMD3(-0.01, y - 0.01, wallHeight - 2.01),
                    max: SIMD3(length + 0.01, y + 0.01, wallHeight + 0.01)))
            var guide = Anchorage.resting(friction: 0.1)
            guide.side = side
            model.supportAnchorages.append(guide)
        }
        let solver = try StructureSolver(device: device, model: model)
        let weight = mass * solver.gravity
        let face = 0.6 * wallHeight
        let lever = thickness + wallHeight / 2  // the push's height above the footing's base

        // Settle under gravity.
        solver.damping = 200
        solver.advance(steps: Int((0.5 / Double(solver.criticalTimeStep)).rounded()))
        solver.damping = 1
        guard let rest = solver.footingSummaries().first else {
            throw ImportedMesh.ImportError.invalid("The rocking test's wall has no footing.")
        }

        var result = Result()
        // The actuator as a spring and dashpot to the displacement asked for, three times as stiff
        // at the push as the footing's elastic rocking, with a slow integral (0.5 s) to take up
        // what the spring leaves short; updated every `interval`.
        let elastic = FootingBed(width: length, length: width, soil: joint.footing!.soil).stiffness[4]
        let spring = 3 * elastic / (lever * lever)
        var inertia: Float = 0
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k) else { continue }
                        let x = Float(i) * h - length / 2
                        let z = Float(k) * h + thickness
                        inertia += nodes[n].mass * (x * x + z * z)
                    }
                }
            }
        }
        let dashpot = (spring * inertia / (lever * lever)).squareRoot()  // half critical
        let steps = max(1, Int((interval / Double(solver.criticalTimeStep)).rounded()))
        var time = 0.0
        var lastSample = -1.0
        var integral: Float = 0
        var lastActuator: Float = 0
        for packet in packets {
            let period = max(2, Double(2 * Float.pi * packet.amplitude / speed))
            var record = Result.Packet(name: packet.name)
            let begin = time
            while time < begin + 3 * period {
                let phase = 2 * Double.pi * (time - begin) / period
                let target = packet.amplitude * Float(sin(phase))
                let targetSpeed = packet.amplitude * Float(2 * Double.pi / period * cos(phase))
                guard let footing = solver.footingSummaries().first else { break }
                let rotation = footing.rotation.y
                let actuator = footing.displacement.x - rest.displacement.x + rotation * lever
                let speedNow = time > 0 ? (actuator - lastActuator) / Float(interval) : 0
                lastActuator = actuator
                let error = target - actuator
                integral += spring * error * Float(interval) / 0.5
                let push = spring * error + dashpot * (targetSpeed - speedNow) + integral
                solver.appliedLoad = PressureLoad(
                    axis: 0, positiveSide: false, history: [SIMD2(0, push / face), SIMD2(1e6, push / face)])
                solver.advance(steps: steps)
                time += interval
                let moment = -footing.soilMoment.y * 2 / (length * weight)
                let settlement = -(footing.displacement.z - rest.displacement.z) / length
                record.peakRotation = max(record.peakRotation, abs(rotation))
                record.moment = SIMD2(max(record.moment.x, moment), max(record.moment.y, -moment))
                // Settlement as the database takes it: where it peaks, upright, in the last cycle.
                if time > begin + 2 * period { record.settlement = max(record.settlement, settlement) }
                record.lag = max(record.lag, abs(error))
                if time - lastSample >= 0.01 {
                    lastSample = time
                    result.history.append(SIMD3(rotation, moment, settlement))
                }
            }
            result.packets.append(record)
            result.profiles.append(profile(solver))
            progress?(
                String(
                    format: "packet %@: rotation %.4f rad, moment %.3f / %.3f, settlement %.4f L",
                    packet.name,
                    record.peakRotation, record.moment.x, record.moment.y, record.settlement))
        }
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
