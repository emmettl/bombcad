import Foundation
import Metal
import simd

/// The normal-strength slab of the 2013 Blast Blind Simulation Contest (UMKC with ACI
/// Committees 447 and 370), tested in the Blast Loading Simulator at the US Army Engineer
/// Research and Development Center.
///
/// Figures are taken from T. H. Kewaisy, A. A. Khalil and A. ElFouly, "Advanced Modeling of
/// Blast Response of Reinforced Concrete Walls with and without FRP Retrofit", ACI Spring
/// Convention 2018, which reproduces the contest's specimen drawing, material curves, pressure
/// record and measured displacement history.
public enum SlabBenchmark {
    static let inch: Float = 0.0254
    static let psi: Float = 6894.76

    /// Peak mid-span displacement measured in the test, in metres (about 4.25 in at 30 ms).
    public static let measuredPeak: Float = 4.25 * inch
    public static let measuredPeakTime: Float = 0.030
    /// Displacement at the end of the record, in metres (about 3.6 in at 70 ms).
    public static let measuredResidual: Float = 3.6 * inch

    public static let statedPeakPressure: Float = 50 * psi
    public static let statedImpulse: Float = 1020 * psi * 1e-3

    /// The reflected pressure record "Set-1a", read off the published plot (ms, psi) and scaled
    /// to the stated impulse of 1,020 psi ms.
    public static var load: PressureLoad {
        let points: [(Float, Float)] = [
            (0, 0), (0.2, 31), (1.2, 29), (2.5, 36.5), (3.3, 35), (4.2, 34.5), (5.5, 41.5), (6.8, 49.8),
            (7.6, 44), (8.3, 40.5), (9.2, 39), (10, 34), (11, 30), (11.5, 28.5), (12.2, 29), (13, 24.5),
            (14, 22.5), (15.5, 20.5), (17, 18), (18.5, 15.8), (19.5, 15), (20.5, 17), (22, 16.5),
            (24, 15.8), (26, 16.2), (28, 15), (30, 13.5), (31.5, 11.2), (33.5, 13), (35, 11.5), (37, 10),
            (38.5, 8), (40.3, 11), (42, 9), (43.3, 6.5), (45, 8.5), (46.2, 7), (47.5, 8.3), (49.5, 6.5),
            (52, 6.2), (55, 4.5), (57, 3.8), (60, 3), (62, 2.3), (64, 2.5), (66, 1.3), (70, 1), (74, 0.8),
            (78, 0.5), (80, 0),
        ]
        var load = PressureLoad(
            axis: 2, positiveSide: true, history: points.map { SIMD2($0.0 * 1e-3, $0.1 * psi) })
        let scale = statedImpulse / load.impulse
        load.history = load.history.map { SIMD2($0.x, $0.y * scale) }
        return load
    }

    /// How closely the hand-read record matched the stated impulse before it was scaled.
    public static var digitisationScale: Float {
        let raw = load.impulse
        return raw / statedImpulse  // 1 after scaling; kept for symmetry with `load`
    }

    /// How strength is raised for the speed of the loading.
    public enum RateTreatment: String, CaseIterable, Sendable {
        /// Static strengths.
        case none
        /// The fixed design factors of UFC 3-340-02 for bending in the far range.
        case designFactors
        /// Strain-rate laws evaluated element by element.
        case strainRate
    }

    /// Concrete of 5,400 psi and the bars' published stress-strain curve: yield at 72 ksi, a
    /// short plateau, 118 ksi at 8% strain and rupture at about 15%.
    public static func material(rate: RateTreatment) -> StructureMaterial {
        var steel = SteelProperties(
            yieldStress: 72_000 * psi, ultimateStress: 118_000 * psi, ultimateStrain: 0.08,
            ruptureStrain: 0.155)
        // Read off the published engineering stress-strain curve (plastic strain, ksi).
        let curve: [(Float, Float)] = [
            (0, 72), (0.006, 74), (0.021, 94), (0.026, 107), (0.052, 115), (0.08, 118), (0.12, 112),
            (0.155, 98),
        ]
        steel.measuredCurve = curve.map { SIMD2($0.0, $0.1 * 1000 * psi) }
        var material = StructureMaterial.concrete(
            name: "Contest slab", compressiveStrength: 5400 * psi, steel: steel)
        switch rate {
        case .none: break
        case .designFactors:
            material.concreteRateFactor = 1.19
            material.steelRateFactor = 1.17
        case .strainRate:
            material.rateDependent = true
        }
        return material
    }

    /// The slab: 64 in long, 33.75 in wide and 4 in thick, with nine No. 3 bars along its length
    /// one inch from the unloaded face and No. 3 bars at 12 in across them.
    public static func model(elementsThroughThickness: Int, rate: RateTreatment) -> StructureModel {
        let h = 4 * inch / Float(elementsThroughThickness)
        // Lifted clear of the ground plane; the test slab stood vertically, so gravity is ignored.
        let base = (1 / h).rounded() * h
        let slab = Box(min: SIMD3(0, 0, base), max: SIMD3(64 * inch, 33.75 * inch, base + 4 * inch))
        var model = StructureModel(
            solids: [slab], material: material(rate: rate), elementSize: h,
            fixedBase: false)
        let barArea: Float = 71e-6  // No. 3 bar, m²
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 9 * barArea / (33.75 * inch),
            transverseAreaPerMetre: barArea / (12 * inch), longitudinalAxis: 0, depth: 1 * inch,
            faces: (low: true, high: false))
        return model
    }

    public struct Result: Sendable {
        /// Mid-span displacement of the unloaded face, in metres, against time in seconds.
        public var history: [SIMD2<Float>]
        public var peak: Float
        public var peakTime: Float
        /// Mean displacement over the last 10 ms of the run.
        public var residual: Float
        public var summary: StructureSummary
        public var elementCount: Int
        public var wallSeconds: Double
    }

    /// Runs the slab under the recorded pressure for 80 ms.
    public static func run(
        device: MTLDevice, elementsThroughThickness: Int = 8, rate: RateTreatment = .strainRate,
        loadScale: Float = 1, adjust: (inout StructureMaterial) -> Void = { _ in }
    ) throws -> Result {
        var model = model(elementsThroughThickness: elementsThroughThickness, rate: rate)
        adjust(&model.material)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        var load = load
        load.history = load.history.map { SIMD2($0.x, $0.y * loadScale) }
        solver.appliedLoad = load

        // Simple supports 52 in apart on the unloaded face: a pin and a roller.
        let h = model.elementSize
        let first = Int((6 * inch / h).rounded())
        let second = Int((58 * inch / h).rounded())
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                nodes[solver.nodeIndex(first, j, 0)].restrain(x: true, z: true)
                nodes[solver.nodeIndex(second, j, 0)].restrain(z: true)
            }
        }

        let start = ContinuousClock.now
        var history: [SIMD2<Float>] = []
        let stepsPerSample = max(1, Int(0.00025 / solver.criticalTimeStep))
        while solver.time < 0.08 {
            solver.advance(steps: stepsPerSample)
            history.append(SIMD2(Float(solver.time), -solver.displacement(solver.ex / 2, solver.ey / 2, 0).z))
        }
        let elapsed = ContinuousClock.now - start
        let peak = history.max { $0.y < $1.y } ?? .zero
        let tail = history.filter { $0.x >= 0.07 }
        return Result(
            history: history, peak: peak.y, peakTime: peak.x,
            residual: tail.reduce(0) { $0 + $1.y } / Float(max(tail.count, 1)),
            summary: solver.summary(), elementCount: solver.elementCount,
            wallSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
