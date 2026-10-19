import BlastModel
import Foundation
import Metal
import simd

// Yao, Li, Zhang, Deng and Zhou (2023), "Dynamic Response and Damage Characteristics of Large
// Reinforced Concrete Slabs under Explosion", Applied Sciences 13, 12552, doi:10.3390/app132312552,
// CC BY 4.0. Values transcribed in Fixtures/Yao2023 (see its README for what was read off plots).

extension TwoFaceSlabTests {
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
