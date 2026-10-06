import Foundation
import Metal
import simd

/// Full-scale reinforced concrete slabs under charges hung 0.5 m and 1 m above them: M. Chiquito,
/// L. M. López, R. Castedo, A. P. Santos and A. Pérez-Caldentey, "Full-scale field tests on
/// concrete slabs subjected to close-in blast loads", *Buildings* 13, 2068 (2023), and, for the
/// second campaign's damage on each face, S. Martínez-Almajano et al., "Field test and numerical
/// modelling of RC slabs at different scaled distances with two types of external
/// reinforcement", *International Journal of Computational Methods and Experimental
/// Measurements* 9(3), 2021. Both open access.
///
/// Slabs 4.40 × 1.46 × 0.15 m of C25/30 concrete (25 MPa, 20 mm aggregate) with B500 bars, laid
/// across two concrete blocks 0.9 m high and clamped to them by steel bars bolted through the
/// slab 0.2 m from each end (4.00 m apart). The first campaign (S) had 12 mm bars at 150 mm in
/// both faces; the second (P), 10 mm bars at 300 mm in the face towards the charge and 12 mm at
/// 150 mm in the other, both ways, with about 30 mm of cover. Only the slabs without added
/// protection are used. Pressure gauges sat flush in the tops of blocks beside the slab, level
/// with its top face, 1 m and 2 m from its centre across its width.
///
/// Assumed: the charge's height is to its centre; the clamps are hinges that hold the slab down
/// and lengthwise at mid-depth on the bolt line, the slab's ends resting on the blocks behind
/// them; the blocks beside the slab carrying the gauges are 0.55 m long and reach from 0.83 m to
/// 2.4 m from the slab's centre, read off the paper's Figure 4.
public enum CloseInSlabTest {
    public struct Test: Sendable {
        public var name: String
        /// TNT-equivalent mass (kg) and height of its centre above the slab's top face (m).
        public var charge: Float
        public var standoff: Float
        /// The second campaign's bars (10 mm at 300 mm towards the charge) rather than the first's.
        public var lightTopMat: Bool
        /// Measured permanent deflection at mid-span (m), where it was measured.
        public var deflection: Float?
        /// Spalled area as a fraction of the slab's face, on the side towards the charge and the
        /// side away from it, where reported.
        public var damagedTop: Float?
        public var damagedBottom: Float?
        public var perforated: Bool
        /// Peak pressure measured at the gauges 1 m and 2 m from the centre (Pa), where recorded.
        public var nearGauge: ClosedRange<Float>?
        public var farGauge: ClosedRange<Float>?
        public var remark: String
    }

    public static let tests: [Test] = [
        Test(
            name: "S1-S3", charge: 2.0, standoff: 1.0, lightTopMat: false, deflection: nil, damagedTop: 0,
            damagedBottom: 0, perforated: false, nearGauge: 2.5e6...3.6e6, farGauge: 0.47e6...0.58e6,
            remark: "calibration shots: minor cracks only; the text gives 2.5 and 0.5 MPa at G1 and G3, its Figure 9 peaks of 3.3-3.6 and 0.47-0.58"),
        Test(
            name: "P1", charge: 1.74, standoff: 1.0, lightTopMat: true, deflection: 0, damagedTop: 0,
            damagedBottom: 0, perforated: false, nearGauge: 2.01e6...2.01e6, farGauge: nil,
            remark: "calibration shot: minor cracks; one gauge, 1 m from the centre"),
        Test(
            name: "S4", charge: 15, standoff: 1.0, lightTopMat: false, deflection: nil, damagedTop: 0.03,
            damagedBottom: nil, perforated: false, nearGauge: nil, farGauge: nil,
            remark: "bent at mid-span, hanging as a membrane"),
        Test(
            name: "P7", charge: 13.05, standoff: 1.0, lightTopMat: true, deflection: 0.34, damagedTop: 0.0338,
            damagedBottom: 0.1034, perforated: false, nearGauge: nil, farGauge: nil,
            remark: "bent at mid-span, hanging as a membrane"),
        Test(
            name: "S5", charge: 15, standoff: 0.5, lightTopMat: false, deflection: nil, damagedTop: 0.07,
            damagedBottom: nil, perforated: true, nearGauge: nil, farGauge: nil,
            remark: "punched through under the charge"),
        Test(
            name: "P2", charge: 13.05, standoff: 0.5, lightTopMat: true, deflection: 0.51, damagedTop: 0.0819,
            damagedBottom: 0.1862, perforated: true, nearGauge: nil, farGauge: nil,
            remark: "punched through under the charge, the bars left across the hole"),
    ]

    // Coordinates: x along the span, y across it, z up from the ground.
    public static let slab = Box(min: SIMD3(1.2, 2.5, 0.9), max: SIMD3(5.6, 3.96, 1.05))
    static let boltLines: [Float] = [1.4, 5.4]
    public static var centre: SIMD3<Float> {
        SIMD3((slab.min.x + slab.max.x) / 2, (slab.min.y + slab.max.y) / 2, slab.max.z)
    }
    static let domainSize = SIMD3<Float>(6.8, 6.45, 3.0)

    /// C25/30 at the 25 MPa the papers give, 2,300 kg/m³ and 20 mm aggregate, strengthening with
    /// strain rate; B500 bars, 500 MPa at yield and 575 at ultimate.
    public static func material() -> StructureMaterial {
        let steel = SteelProperties(yieldStress: 500e6, ultimateStress: 575e6, ultimateStrain: 0.075, ruptureStrain: 0.1)
        var material = StructureMaterial.concrete(
            name: "C25/30", compressiveStrength: 25e6, density: 2300, steel: steel)
        material.aggregateSize = 0.02
        material.rateDependent = true
        return material
    }

    public static func scenario(_ test: Test, elementSize: Float = 0.025) -> Scenario {
        var model = StructureModel(solids: [slab], material: material(), elementSize: elementSize, fixedBase: false)
        // Bars 30 mm in, to the centre of the outer layer and the inner one about a bar further.
        let bottom: Float = 113.1e-6 / 0.15
        let top: Float = test.lightTopMat ? 78.5e-6 / 0.3 : bottom
        model.addMat(to: slab, thicknessAxis: 2, areaPerMetre: bottom, depth: 0.042, faces: (low: true, high: false))
        model.addMat(to: slab, thicknessAxis: 2, areaPerMetre: top, depth: 0.042, faces: (low: false, high: true))
        let c = centre
        let boxes = [
            // The supporting blocks, under the slab's ends to the bolt lines.
            Box(min: SIMD3(0.2, c.y - 1, 0), max: SIMD3(boltLines[0], c.y + 1, slab.min.z)),
            Box(min: SIMD3(boltLines[1], c.y - 1, 0), max: SIMD3(6.6, c.y + 1, slab.min.z)),
            // The gauges' blocks, either side, their tops level with the slab's.
            Box(min: SIMD3(c.x - 0.275, c.y + 0.83, 0), max: SIMD3(c.x + 0.275, c.y + 2.4, slab.max.z)),
            Box(min: SIMD3(c.x - 0.275, c.y - 2.4, 0), max: SIMD3(c.x + 0.275, c.y - 0.83, slab.max.z)),
        ]
        let lift: Float = 0.025
        let gauges = [
            Gauge("G1, 1 m", at: SIMD3(c.x, c.y + 1, slab.max.z + lift)),
            Gauge("G2, 1 m", at: SIMD3(c.x, c.y - 1, slab.max.z + lift)),
            Gauge("G3, 2 m", at: SIMD3(c.x, c.y + 2, slab.max.z + lift)),
            Gauge("G4, 2 m", at: SIMD3(c.x, c.y - 2, slab.max.z + lift)),
            // In the open, level with the charge and as far from it as G1, for the incident wave.
            Gauge("Free air, as G1", at: c + SIMD3(1.414, 0, test.standoff)),
            // On the slab's top face under the charge, where the wave strikes square on.
            Gauge("Slab centre", at: c + SIMD3(0, 0, lift)),
        ]
        return Scenario(
            name: "Close-in slab \(test.name)", domainSize: domainSize, boxes: boxes,
            charge: Charge(mass: test.charge, position: c + SIMD3(0, 0, test.standoff)), gauges: gauges,
            structure: model)
    }

    public struct Result: Sendable {
        /// Mid-span deflection of the bottom face at the centre (m, down) against time (s).
        public var history: [SIMD2<Float>]
        public var peak: Float
        /// Mean of the last fifth of the record.
        public var permanent: Float
        /// Fraction of each face whose surface element has been removed or cracked loose.
        public var damagedTop: Float
        public var damagedBottom: Float
        /// Whether a column of failed elements runs through the slab's thickness.
        public var perforated: Bool
        public var gaugePeaks: [(name: String, pressure: Float)]
        /// Impulse of each gauge's overpressure, positive phase only (Pa s).
        public var gaugeImpulses: [Float]
        /// The slab's largest downward momentum in the first 5 ms (N s): about the impulse the
        /// blast gave it, before the supports have taken much.
        public var impulse: Float
        public var summary: StructureSummary
        public var wallSeconds: Double
    }

    public static func run(
        device: MTLDevice, test: Test, cellSize: Float = 0.05, elementSize: Float = 0.025, duration: Double = 0.3,
        refinement: Int = 1, mappedCharge: Bool = true, afterburning: Bool = false, heldLengthwise: Bool = true,
        adjust: (inout Scenario) -> Void = { _ in }, progress: ((String) -> Void)? = nil
    ) throws -> Result {
        var scenario = scenario(test, elementSize: elementSize)
        adjust(&scenario)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: cellSize)
        solver.configuration.mappedCharge = mappedCharge && !afterburning
        solver.configuration.afterburning = afterburning
        solver.configuration.refinement = refinement
        try solver.load(scenario)
        guard let structure = solver.structure else { throw BlastError.allocationFailed("structure") }
        let h = structure.model.elementSize
        func index(_ value: Float, _ axis: Int) -> Int { Int(((value - structure.origin[axis]) / h).rounded()) }
        let mid = (index(slab.min.z, 2) + index(slab.max.z, 2)) / 2
        let topLayer = (0...structure.ez).last { k in structure.storedNode(index(centre.x, 0), 0, k) != nil } ?? 0
        let middleJ = index(centre.y, 1)
        structure.mutateNodes { nodes in
            for j in 0...structure.ey {
                for i in 0...structure.ex {
                    let x = structure.origin.x + Float(i) * h
                    // The ends rest on the blocks behind the bolt lines.
                    if x <= boltLines[0] + 1e-4 || x >= boltLines[1] - 1e-4, let n = structure.storedNode(i, j, 0) {
                        nodes[n].restsOnSupport = true
                    }
                    for bolt in boltLines where abs(x - bolt) <= h + 1e-4 {
                        // The clamping bar holds the top face down; the bolts hold the slab at
                        // mid-depth, lengthwise and, at the middle, across.
                        if let n = structure.storedNode(i, j, topLayer) { nodes[n].isHeldDown = true }
                        if abs(x - bolt) < 1e-4, let n = structure.storedNode(i, j, mid) {
                            nodes[n].restrain(x: heldLengthwise || bolt == boltLines[0], y: j == middleJ)
                        }
                    }
                }
            }
        }
        let ci = index(centre.x, 0)
        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        var nextReport = 0.01
        var impulse: Float = 0
        while solver.time < duration {
            let result = solver.advance(steps: 16, timeLimit: duration)
            if result.steps == 0 && !solver.airIsAsleep { break }
            history.append(SIMD2(Float(solver.time), -structure.displacement(ci, middleJ, 0).z))
            if solver.time < 0.005 { impulse = max(impulse, Float(-structure.momentum().z)) }
            if let progress, solver.time >= nextReport {
                nextReport += 0.01
                progress(
                    String(
                        format: "%3.0f ms: centre %4.0f mm, %d elements failed", solver.time * 1000,
                        history.last!.y * 1000, structure.summary().erodedElements))
            }
        }
        let elapsed = ContinuousClock.now - start
        // Spalled area: on each face, surface elements removed or cracked open past the width at
        // which a loose one would be removed (the cover holds no bars to bridge it); perforation:
        // a column removed through the thickness.
        var top = 0
        var bottom = 0
        var columns = 0
        var through = false
        for j in 0..<structure.ey {
            for i in 0..<structure.ex where structure.flag(i, j, 0) != .empty {
                columns += 1
                let failed = (0..<topLayer).map { structure.flag(i, j, $0) == .eroded }
                if failed.first == true || structure.damage(i, j, 0) >= 1 { bottom += 1 }
                if failed.last == true || structure.damage(i, j, topLayer - 1) >= 1 { top += 1 }
                if failed.allSatisfy({ $0 }) { through = true }
            }
        }
        let tail = history.suffix(max(1, history.count / 5))
        let ambient = scenario.atmosphere.pressure
        return Result(
            history: history, peak: history.map(\.y).max() ?? 0,
            permanent: tail.reduce(0) { $0 + $1.y } / Float(max(tail.count, 1)),
            damagedTop: Float(top) / Float(max(columns, 1)), damagedBottom: Float(bottom) / Float(max(columns, 1)),
            perforated: through,
            gaugePeaks: zip(scenario.gauges, solver.gaugeHistories).map { gauge, samples in
                (gauge.name, (samples.map(\.pressure).max() ?? ambient) - ambient)
            },
            gaugeImpulses: solver.gaugeHistories.map { samples in
                var total: Float = 0
                for (a, b) in zip(samples, samples.dropFirst()) {
                    total += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
                }
                return total
            },
            impulse: impulse, summary: structure.summary(),
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
