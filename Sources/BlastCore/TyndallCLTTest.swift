import Foundation
import Metal
import simd

/// Full-scale cross-laminated timber buildings under open-air charges at Tyndall Air Force Base:
/// Weaver, Newberry, O'Laughlin and Podesto, *Results from Blast Tests of Full-Scale
/// Cross-Laminated Timber Structures*, Karagozian & Case TR-17-17.1 for WoodWorks (2017), and its
/// Phase 2, TR-18-06.2 (2018); both open.
///
/// Three single-bay, two-storey buildings, 15 ft (4.57 m) square, stood on a concrete slab 75 ft
/// (22.86 m) from charges of flake TNT. Walls and roof are 3-ply (105 mm) with the walls' outer
/// lamellae vertical; the second floor is 5-ply (175 mm); walls bear on steel angles screwed and
/// anchored to the slab, and meet the floors on clip angles. The front, facing the charge, has
/// no openings; a door and a window (boarded) are on the sides. The Nordic E1 building (the
/// centre one) is modelled: 12 ft first-storey panels, second-storey panels of 14 ft 4 in with a
/// 2 ft parapet. Measured (Phase 1, Table 4-2): the front wall's centre at the first and second
/// floors, inbound and rebound; and the mean reflected pressure and impulse on the front.
///
/// The model: the building alone (its neighbours, 11 ft away on the same 75 ft arc, turned
/// towards the charge, are left out), as CLT shells of E1 as Poulin's panels are made, its
/// strength along the grain the one calibrated on Poulin's static tests (`PoulinCLTTest`); the
/// walls' bases held at the slab, the panels joined rigidly where they meet (the tests' screwed
/// angles are not), the door and the boarded window closed.
public enum TyndallCLTTest {
    public struct Test: Sendable {
        public var number: Int
        /// TNT (kg) and the height of its centre (m): the cylinder's base 18 in up, plus half
        /// its height.
        public var charge: Float
        public var height: Float
        /// Measured mean reflected peak (Pa) and impulse (Pa s) on the front.
        public var reflected: Float
        public var impulse: Float
        /// Measured mean incident peak (Pa) and impulse (Pa s) at the free-field gauges, 75 ft out.
        public var incident: Float
        public var incidentImpulse: Float
        /// Measured front-wall centre displacements (m), first floor then second, inbound and
        /// rebound (rebound negative, away from the charge).
        public var firstFloor: SIMD2<Float>
        public var secondFloor: SIMD2<Float>
        public var damage: String
    }

    static let inch: Float = 0.0254
    static let psi: Float = 6894.76

    public static let tests: [Test] = [
        Test(
            number: 1, charge: 14.5, height: (18 + 7.24 / 2) * inch, reflected: 5.05 * psi,
            impulse: 19.9e-3 * psi, incident: 2.41 * psi, incidentImpulse: 10.9e-3 * psi,
            firstFloor: SIMD2(1.09, -1.77) * inch, secondFloor: SIMD2(0.83, -1.38) * inch,
            damage: "superficial"),
        Test(
            number: 2, charge: 30.4, height: (18 + 9.17 / 2) * inch, reflected: 7.94 * psi,
            impulse: 32.9e-3 * psi, incident: 3.45 * psi, incidentImpulse: 18.0e-3 * psi,
            firstFloor: SIMD2(1.96, -2.75) * inch, secondFloor: SIMD2(1.47, -2.15) * inch,
            damage: "superficial"),
        Test(
            number: 3, charge: 90.3, height: (18 + 15.3 / 2) * inch, reflected: 13.2 * psi,
            impulse: 65.2e-3 * psi, incident: 5.15 * psi, incidentImpulse: 33.3e-3 * psi,
            firstFloor: SIMD2(3.90, -6.12) * inch, secondFloor: SIMD2(3.07, -3.84) * inch,
            damage: "moderate: the first-storey front cracked at mid-span"),
    ]

    public static let standoff: Float = 22.86
    public static let side: Float = 4.57

    /// The building with its front at x = 24 m, centred on y = 8 m, the domain's faces moved out by
    /// `pad` (behind the charge, each side, above); the charge on the axis; a free-field gauge on
    /// the ground on the same 75 ft arc, 7 m to the side.
    public static func scenario(
        _ test: Test, elementSize: Float = 0.15, pad: SIMD3<Float> = .zero
    ) -> Scenario {
        let t3: Float = 0.105
        let t5: Float = 0.175
        let x0: Float = 24 + pad.x
        let yc: Float = 8 + pad.y
        let (y0, y1) = (yc - side / 2, yc + side / 2)
        let x1 = x0 + side
        let floor: Float = 12 * 12 * inch
        let roof = floor + (14 * 12 + 4 - 24) * inch
        let top = roof + 24 * inch
        let walls: [Box] = [
            Box(min: SIMD3(x0, y0, 0), max: SIMD3(x0 + t3, y1, top)),  // front
            Box(min: SIMD3(x1 - t3, y0, 0), max: SIMD3(x1, y1, top)),  // back
            Box(min: SIMD3(x0 + t3, y0, 0), max: SIMD3(x1 - t3, y0 + t3, top)),  // sides
            Box(min: SIMD3(x0 + t3, y1 - t3, 0), max: SIMD3(x1 - t3, y1, top)),
        ]
        let plates = [
            Box(min: SIMD3(x0 + t3, y0 + t3, floor - t5), max: SIMD3(x1 - t3, y1 - t3, floor)),
            Box(min: SIMD3(x0 + t3, y0 + t3, roof - t3), max: SIMD3(x1 - t3, y1 - t3, roof)),
        ]
        let wallMaterial = Self.material(lamellae: 3, grainAxis: 2)
        var model = StructureModel(
            solids: walls + plates, material: wallMaterial, elementSize: elementSize, fixedBase: true)
        model.setMaterial(Self.material(lamellae: 5, grainAxis: 0), of: walls.count)
        model.setMaterial(Self.material(lamellae: 3, grainAxis: 0), of: walls.count + 1)
        model.elementKind = .shell
        let centre = SIMD3<Float>(x0 - standoff, yc, test.height)
        let aside: Float = 7
        return Scenario(
            name: "Tyndall test \(test.number)", domainSize: SIMD3(32 + pad.x, 16 + 2 * pad.y, 12 + pad.z),
            boxes: [],
            charge: Charge(mass: test.charge, position: centre),
            gauges: [
                Gauge("Front, first storey", at: SIMD3(x0 - 0.05, yc, 1.8)),
                Gauge("Front, second storey", at: SIMD3(x0 - 0.05, yc, floor + 1.8)),
                Gauge("Front, first storey edge", at: SIMD3(x0 - 0.05, y0 + 0.3, 1.8)),
                Gauge("Roof", at: SIMD3(x0 + side / 2, yc, top + 0.1)),
                Gauge("Back", at: SIMD3(x1 + 0.05, yc, 1.8)),
                Gauge("Side", at: SIMD3(x0 + side / 2, y0 - 0.05, 1.8)),
                Gauge(
                    "Free field, 75 ft",
                    at: SIMD3(
                        centre.x + (standoff * standoff - aside * aside).squareRoot(), yc + aside, 0.05)),
            ], structure: model)
    }

    /// E1 CLT as Poulin's panels (`PoulinCLTTest.material`), its outer lamellae along
    /// `grainAxis`, with the dynamic increase Poulin found.
    static func material(lamellae: Int, grainAxis: Int) -> StructureMaterial {
        var material = PoulinCLTTest.material(plies: lamellae, rate: 1.28)
        material.timber?.grainAxis = grainAxis
        material.name = "E1 CLT, \(lamellae) lamellae"
        return material
    }

    public struct Result: Sendable {
        /// The front wall's centre at the first and second storeys (m): largest inbound and
        /// rebound (negative).
        public var firstFloor: SIMD2<Float>
        public var secondFloor: SIMD2<Float>
        /// Reflected peak (Pa) and positive-phase impulse (Pa s) at the first-storey front gauge,
        /// and the incident ones at the free-field gauge.
        public var reflected: Float
        public var impulse: Float
        public var incident: Float
        public var incidentImpulse: Float
        public var maxDamage: Float
        public var removed: Int
    }

    public static func run(
        device: MTLDevice, test: Test, cellSize: Float = 0.25, refinement: Int = 2, elementSize: Float = 0.15,
        duration: Double = 0.25, pad: SIMD3<Float> = .zero,
        history: ((Double, Float, Float, [Float]) -> Void)? = nil,
        configure: ((inout SolverConfiguration) -> Void)? = nil,
        progress: ((String) -> Void)? = nil
    ) throws -> Result {
        let scenario = scenario(test, elementSize: elementSize, pad: pad)
        let x0 = 24 + pad.x
        let yc = 8 + pad.y
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
        solver.configuration = .recommended.balloonStart
        solver.configuration.refinement = refinement
        configure?(&solver.configuration)
        try solver.load(scenario)
        guard let shells = solver.shells else { throw BlastError.allocationFailed("shells") }
        let floor: Float = 12 * 12 * inch
        let first = shells.nearestNode(to: SIMD3(x0 + 0.05, yc, floor / 2))
        let second = shells.nearestNode(to: SIMD3(x0 + 0.05, yc, floor + 1.9))
        // Rest, under the building's own weight, settled before the blast.
        solver.settleStructures()
        let rest = (shells.node(first).displacement.x, shells.node(second).displacement.x)
        var firstFloor = SIMD2<Float>.zero
        var secondFloor = SIMD2<Float>.zero
        var nextReport = 0.02
        while solver.time < duration {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            // Inbound is away from the charge, along +x.
            let a = shells.node(first).displacement.x - rest.0
            let b = shells.node(second).displacement.x - rest.1
            history?(
                solver.time, a, b,
                solver.gaugeHistories.map { ($0.last?.pressure ?? 0) - scenario.atmosphere.pressure })
            firstFloor = SIMD2(max(firstFloor.x, a), min(firstFloor.y, a))
            secondFloor = SIMD2(max(secondFloor.x, b), min(secondFloor.y, b))
            if let progress, solver.time >= nextReport {
                nextReport += 0.02
                progress(
                    String(
                        format: "%3.0f ms: first storey %5.1f mm, second %5.1f mm", solver.time * 1000,
                        a * 1000,
                        b * 1000))
            }
        }
        let ambient = scenario.atmosphere.pressure
        // The positive phase, as the report gives it: from the shock to the pressure's first fall
        // back below ambient.
        func positive(_ samples: [GaugeSample]) -> (peak: Float, impulse: Float) {
            guard let start = samples.firstIndex(where: { $0.pressure - ambient > 0.01 * ambient }) else {
                return (0, 0)
            }
            var impulse: Float = 0
            var peak: Float = 0
            for (p, q) in zip(samples[start...], samples[(start + 1)...]) {
                if q.pressure < ambient { break }
                impulse += Float(q.time - p.time) * (0.5 * (p.pressure + q.pressure) - ambient)
                peak = max(peak, q.pressure - ambient)
            }
            return (peak, impulse)
        }
        let wall = positive(solver.gaugeHistories.first ?? [])
        let freeField = scenario.gauges.firstIndex { $0.name.hasPrefix("Free field") }
        let free = positive(freeField.map { solver.gaugeHistories[$0] } ?? [])
        let summary = shells.summary()
        return Result(
            firstFloor: firstFloor, secondFloor: secondFloor, reflected: wall.peak, impulse: wall.impulse,
            incident: free.peak, incidentImpulse: free.impulse, maxDamage: summary.maxDamage,
            removed: summary.erodedElements)
    }
}
