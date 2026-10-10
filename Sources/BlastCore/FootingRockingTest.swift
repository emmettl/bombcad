import Foundation
import Metal
import simd

/// A footing rocked slowly to and fro on dry sand, against a measured one: test SSG02_03 of
/// S. Gajan and B. L. Kutter's centrifuge experiments at UC Davis ("Capacity, settlement, and
/// energy dissipation of shallow footings subjected to rocking", J. Geotech. Geoenviron. Eng.
/// 134(8), 2008), from the FoRCy database (M. Hakhamaneshi, B. L. Kutter, A. G. Gavras and
/// others, DesignSafe PRJ-6414, doi:10.13019/t0cq-qf64, Open Data Commons Attribution).
///
/// In prototype units: an essentially rigid shear wall of 29.0 Mg, its centre of mass 4.5 m above
/// the base of a surface footing 2.8 m long (along the load) and 0.65 m wide, on dry Nevada sand
/// at a relative density of 80% (1,657 kg/m³, friction angle about 42°), its ultimate bearing
/// pressure 814 kPa against the 157 kPa the wall puts on it. An actuator pinned to the wall
/// 4.9 m above the footing's base pushed it to and fro in five packets of three slow sinusoidal
/// cycles, each larger than the last. The measured values here are from the database's time
/// histories (`Samples/FoRCy`): the moment about the base centre normalized by L P / 2, the
/// settlement by L.
///
/// The model: the wall as a stiff elastic block 2.8 × 0.6 × 8.6 m on a footing 0.65 m thick
/// reaching 25 mm beyond it each side across, so 0.65 m wide; their densities set so that the two
/// weigh 29.0 Mg with their centre of mass 4.5 m up. A uniform push on the wall's end face acts
/// 4.95 m above the footing's base. It is driven, as the actuator drove the wall, by the
/// displacement there: each millisecond the push is set by a spring and dashpot to the
/// displacement asked for, with a slow integral to make up what the spring leaves short.
/// Bearings with friction 0.1 against the wall's faces near its top stand for the test's Teflon
/// guides, without which the wall falls over sideways. The soil is the footing's elastic
/// half-space with a bearing capacity, the sand's shear modulus the one input not measured.
public enum FootingRockingTest {
    /// One packet of three cycles.
    public struct Packet: Sendable {
        public var name: String
        /// The actuator's amplitude, in metres.
        public var amplitude: Float
        /// Measured: the largest rotation either way (radians), the largest normalized moment
        /// each way, and the settlement at the packet's end, over L.
        public var peakRotation: Float
        public var moment: SIMD2<Float>
        public var settlement: Float
    }

    /// SSG02_03's packets a to e, from the database's time histories.
    public static let packets: [Packet] = [
        Packet(
            name: "a", amplitude: 0.015, peakRotation: 0.0032, moment: SIMD2(0.525, 0.366), settlement: 0.0027
        ),
        Packet(
            name: "b", amplitude: 0.0335, peakRotation: 0.0066, moment: SIMD2(0.691, 0.623),
            settlement: 0.0065),
        Packet(
            name: "c", amplitude: 0.0715, peakRotation: 0.0140, moment: SIMD2(0.779, 0.779),
            settlement: 0.0108),
        Packet(
            name: "d", amplitude: 0.1493, peakRotation: 0.0296, moment: SIMD2(0.837, 0.908),
            settlement: 0.0173),
        Packet(
            name: "e", amplitude: 0.307, peakRotation: 0.0629, moment: SIMD2(0.874, 0.960), settlement: 0.0295
        ),
    ]

    public static let length: Float = 2.8
    public static let width: Float = 0.65
    public static let mass: Float = 29_000
    public static let bearingCapacity: Float = 814e3

    public struct Result: Sendable {
        public struct Packet: Sendable {
            public var name: String
            public var peakRotation: Float = 0
            /// Largest normalized moment pushing forward and back.
            public var moment = SIMD2<Float>.zero
            /// Settlement of the base centre at its largest in the packet's last cycle, over L.
            public var settlement: Float = 0
            /// The largest the actuator's displacement fell short of what was asked, in metres.
            public var lag: Float = 0
        }
        public var packets: [Packet] = []
        /// (rotation, normalized moment, settlement over L) every 10 ms.
        public var history: [SIMD3<Float>] = []
        public var wallSeconds: Double = 0
    }

    /// Rocks the wall through `packets`, on sand of `shearModulus`, its cycles no faster than
    /// `speed` m/s at the actuator, the actuator's push set every `interval` seconds.
    public static func run(
        device: MTLDevice, shearModulus: Float = 40e6, bearingCapacity: Float = Self.bearingCapacity,
        friction: Float = 0.6, packets: [Packet] = Self.packets, speed: Float = 0.2, interval: Double = 1e-3,
        cyclic: CyclicSand? = nil, progress: ((String) -> Void)? = nil
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
        // (Cyclic sand, softer as it is first loaded, takes longer.)
        solver.damping = 200
        solver.advance(steps: Int(((cyclic == nil ? 0.5 : 2) / Double(solver.criticalTimeStep)).rounded()))
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
