import Foundation
import Metal
import simd

// Yao, Li, Zhang, Deng and Zhou (2023), "Dynamic Response and Damage Characteristics of Large
// Reinforced Concrete Slabs under Explosion", Applied Sciences 13, 12552, doi:10.3390/app132312552,
// CC BY 4.0. Values transcribed in Fixtures/Yao2023 (see its README for what was read off plots).

extension TwoFaceSlabTests {
    public struct YaoTest: Sendable {
        public var name: String
        /// TNT (kg) and the height of its centre above the top face (m).
        public var charge: Float
        public var standoff: Float
        /// Measured, read off the paper's Figure 7b: the largest displacement of the underside (m)
        /// at the centre, 1 m towards a supported long side, 1 m towards a free short side, and 1 m
        /// along the diagonal; nil where not measured.
        public var displacements: [Float]?
        /// Read off its Figure 6b: the largest pressure on the top face (Pa) at the centre and 1 m
        /// out (its long- and short-side gauges read alike).
        public var centrePressure: Float?
        public var sidePressure: Float?
        public var remark: String
    }

    public static let yaoTests: [YaoTest] = [
        YaoTest(
            name: "T1", charge: 0.5, standoff: 1.0, displacements: [0.00035, 0.00033, 0.00020, 0.00018],
            centrePressure: 1.7e6, sidePressure: 0.5e6, remark: "no visible damage"),
        YaoTest(
            name: "T2", charge: 1.0, standoff: 1.0, displacements: [0.00047, 0.00042, 0.00028, 0.00024],
            centrePressure: 4.2e6, sidePressure: 1.25e6, remark: "no visible damage"),
        YaoTest(
            name: "T3", charge: 1.0, standoff: 0.8, displacements: [0.00086, 0.00078, 0.00053, 0.00046],
            centrePressure: 8.6e6, sidePressure: 1.9e6, remark: "no visible damage"),
        YaoTest(
            name: "T4", charge: 20, standoff: 1.0,
            remark: "top crater 1.02 x 0.76 m, bars exposed and unbroken; underside spalled, bars bent, "
                + "over 10 long cracks; bent along the centre line (moderate damage)"),
    ]

    // Coordinates: x across the 4 m span, y along the 5 m supported sides, z up from the ground.
    // The slab's underside is assumed 1 m above the ground (the supports' height is not given).
    public static let yaoSlab = Box(min: SIMD3(0.5, 0.5, 1.0), max: SIMD3(4.5, 5.5, 1.15))
    /// The L-shaped supports' bearing, 150 mm on each long side.
    public static let yaoBearing: Float = 0.15
    static let yaoDomain = SIMD3<Float>(5.0, 6.0, 2.8)

    public static var yaoCentre: SIMD3<Float> {
        SIMD3((yaoSlab.min.x + yaoSlab.max.x) / 2, (yaoSlab.min.y + yaoSlab.max.y) / 2, yaoSlab.max.z)
    }

    /// C35, at 0.8 of the 37.2 MPa cube mean, strengthening with strain rate; HRB400 bars at the
    /// measured 405 and 542 MPa, rupturing at the grade's minimum elongation, 16% (not given).
    public static func yaoMaterial() -> StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 405e6, ultimateStress: 542e6, ultimateStrain: 0.1, ruptureStrain: 0.16)
        var material = StructureMaterial.concrete(
            name: "C35", compressiveStrength: 0.8 * 37.2e6, density: 2314, steel: steel)
        material.rateDependent = true
        return material
    }

    /// Two mats of 10 mm bars at 85 mm both ways (1.2% through the section), their centres 25 mm in.
    /// Moved by `pad.low` with the domain grown by `pad.low + pad.high` (`Scenario.openFaceRoom`).
    public static func scenario(
        _ test: YaoTest, elementSize: Float = 0.01875,
        pad: (low: SIMD3<Float>, high: SIMD3<Float>) = (.zero, .zero)
    ) -> Scenario {
        let yaoSlab = Self.yaoSlab.moved(by: pad.low)
        var model = StructureModel(
            solids: [yaoSlab], material: yaoMaterial(), elementSize: elementSize, fixedBase: false)
        let bar: Float = .pi * 0.005 * 0.005
        model.addMat(to: yaoSlab, thicknessAxis: 2, areaPerMetre: bar / 0.085, depth: 0.025)
        let c = yaoCentre + pad.low
        let boxes = [
            Box(
                min: SIMD3(yaoSlab.min.x, yaoSlab.min.y, 0),
                max: SIMD3(yaoSlab.min.x + yaoBearing, yaoSlab.max.y, yaoSlab.min.z)),
            Box(
                min: SIMD3(yaoSlab.max.x - yaoBearing, yaoSlab.min.y, 0),
                max: SIMD3(yaoSlab.max.x, yaoSlab.max.y, yaoSlab.min.z)),
        ]
        return Scenario(
            name: "Yao \(test.name)", domainSize: yaoDomain + pad.low + pad.high, boxes: boxes,
            charge: Charge(mass: test.charge, position: c + SIMD3(0, 0, test.standoff)),
            gauges: [
                Gauge("centre", at: c + SIMD3(0, 0, 0.005)),
                Gauge("1 m towards a support", at: c + SIMD3(1, 0, 0.005)),
                Gauge("1 m towards a free edge", at: c + SIMD3(0, 1, 0.005)),
            ], structure: model)
    }

    /// Holds the slab as the tests' supports did: resting on them (pushing up only), held in plane
    /// along the first bearing's middle line and across at the centre of each, simply supported;
    /// the slab moved by `offset`.
    public static func yaoHold(
        _ structure: StructureSolver, _ nodes: UnsafeMutableBufferPointer<StructureNode>,
        offset: SIMD3<Float> = .zero, _ index: (Float, Int) -> Int
    ) {
        let yaoSlab = Self.yaoSlab.moved(by: offset)
        let yaoCentre = Self.yaoCentre + offset
        let h = structure.model.elementSize
        let bottom = index(yaoSlab.min.z, 2)
        let middle = index(yaoCentre.y, 1)
        for j in 0...structure.ey {
            for i in 0...structure.ex {
                let x = structure.origin.x + Float(i) * h
                let fromEdge = min(x - yaoSlab.min.x, yaoSlab.max.x - x)
                guard fromEdge <= yaoBearing + 1e-4, let n = structure.storedNode(i, j, bottom) else {
                    continue
                }
                nodes[n].restsOnSupport = true
                if abs(fromEdge - yaoBearing / 2) < h / 2 {
                    let first = x - yaoSlab.min.x < yaoSlab.max.x - x
                    nodes[n].restrain(x: first, y: j == middle)
                }
            }
        }
    }

    /// Runs one of Yao's tests: probes on the underside at the centre, 1 m towards a supported
    /// side, 1 m towards a free side and 1 m along the diagonal, as the paper's Figure 3 places them.
    public static func run(
        device: MTLDevice, test: YaoTest, cellSize: Float = 0.025, refinement: Int = 2,
        elementSize: Float = 0.01875, duration: Double = 0.1,
        afterburning: Bool = SolverConfiguration.recommended.afterburning,
        airModel: AirModel? = nil, openFaces: OpenFaces = SolverConfiguration.recommended.openFaces,
        roomy: Bool = false, balloonStart: Bool = false,
        adjust: (inout Scenario) -> Void = { _ in },
        prepare: ((StructureSolver) -> Void)? = nil, progress: ((String) -> Void)? = nil,
        inspect: ((StructureSolver, Double) -> Void)? = nil,
        configure: (inout SolverConfiguration) -> Void = { _ in }
    ) throws -> Result {
        // `roomy`: every open face moved out to `Scenario.structureFaceClearance`, the scene with it,
        // by multiples of 1.5 m (of 18.75 mm elements and of 25, 50 and 100 mm cells).
        let pad = roomy ? scenario(test).openFaceRoom(step: 1.5) : (low: .zero, high: .zero)
        let yaoSlab = Self.yaoSlab.moved(by: pad.low)
        let yaoCentre = Self.yaoCentre + pad.low
        var scenario = scenario(test, elementSize: elementSize, pad: pad)
        adjust(&scenario)
        let c = SIMD3(yaoCentre.x, yaoCentre.y, yaoSlab.min.z)
        let diagonal = simd_normalize(SIMD3<Float>(4, 5, 0))
        let probes: [(String, SIMD3<Float>)] = [
            ("centre", c), ("1 m towards a support", c + SIMD3(1, 0, 0)),
            ("1 m towards a free edge", c + SIMD3(0, 1, 0)), ("1 m along the diagonal", c + diagonal),
        ]
        return try run(
            device: device, scenario: scenario, slab: yaoSlab, thicknessAxis: 2, probes: probes,
            cellSize: cellSize, refinement: refinement, duration: duration, chargeTowardsLow: false,
            afterburning: afterburning, airModel: airModel, openFaces: openFaces, balloonStart: balloonStart,
            // Under its own weight, settled before the blast and read from there, as the tests'
            // sensors read from the slab resting on its supports.
            hold: { yaoHold($0, $1, offset: pad.low, $2) }, prepare: prepare, progress: progress,
            inspect: inspect, configure: configure)
    }
}
