import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Bars that slip in their concrete (`BondSlip`), against the fib Model Code 2010's crack
/// spacing and tension stiffening for a reinforced tie.
@Suite("Bond slip")
struct BondSlipTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    static let ratio: Float = 0.02
    static let diameter: Float = 0.012
    static let material = StructureMaterial.concrete(
        name: "C30", compressiveStrength: 30e6, steel: .grade500)

    /// A 1 m tie, 100 mm square, 2% steel of 12 mm bars, held at one end and pulled at the other
    /// to 1.5 mm. Returns which elements along its middle have cracked open past 0.1% strain, and
    /// the load, averaged over the last millisecond.
    private func pull(elementSize h: Float, bond: BondSlip?) throws -> (cracks: [Int], load: Float) {
        let tie = Box(min: SIMD3(0, 0, 1), max: SIMD3(1, 0.1, 1.1))
        var model = StructureModel(solids: [tie], material: Self.material, elementSize: h, fixedBase: false)
        model.reinforcement = [ReinforcementLayer(region: tie, ratio: SIMD3(Self.ratio, 0, 0))]
        model.bondSlip = bond
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 200
        let rate: Float = 0.05
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    nodes[solver.nodeIndex(0, j, k)].isFixed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].isPrescribed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].velocity = SIMD3(rate, 0, 0)
                }
            }
        }
        let end = 0.0015 / Double(rate)
        solver.advance(steps: Int(((end - 0.001) / Double(solver.criticalTimeStep)).rounded()))
        var load: Float = 0
        let samples = 20
        for _ in 0..<samples {
            solver.advance(
                steps: max(1, Int((0.001 / Double(samples) / Double(solver.criticalTimeStep)).rounded())))
            var force: Float = 0
            for k in 0...solver.ez {
                for j in 0...solver.ey { force -= solver.nodalForce(solver.ex, j, k).x }
            }
            load += force / Float(samples)
        }
        let cracks = (0..<solver.ex).filter { solver.crackStrain($0, solver.ey / 2, solver.ez / 2) > 1e-3 }
        return (cracks, load)
    }

    @Test("A tie cracks at the Model Code's spacing, the same on two meshes, and stiffens as it says")
    func tie() throws {
        let bond = BondSlip(condition: .pullOut, barDiameter: Self.diameter)
        let coarse = try pull(elementSize: 0.02, bond: bond)
        let fine = try pull(elementSize: 0.01, bond: bond)
        // Transfer length l_t = f_ctm d / (4 tau_bms rho), with the mean bond stress while
        // cracks form tau_bms = 1.8 f_ctm (MC2010 7.6.4): cracks l_t to 2 l_t apart, so between
        // 1 / (2 l_t) and 1 / l_t of them in the metre.
        let transfer = Self.diameter / (4 * 1.8 * Self.ratio)
        for cracks in [coarse.cracks.count, fine.cracks.count] {
            #expect(
                Float(cracks) >= 1 / (2 * transfer) - 1 && Float(cracks) <= 1 / transfer + 1,
                "\(cracks) cracks")
        }
        #expect(abs(coarse.cracks.count - fine.cracks.count) <= 1)
        // Tension stiffening (MC2010 7.6.5, beta = 0.4): at a mean strain of 1.5e-3 the bars at
        // the cracks carry E_s eps + beta f_ctm (1 + alpha_e rho) / rho.
        let fctm = Self.material.tensileStrength
        let modularRatio = 200e9 / Self.material.youngsModulus
        let barStress = 200e9 * 1.5e-3 + 0.4 * fctm * (1 + modularRatio * Self.ratio) / Self.ratio
        let expected = barStress * Self.ratio * 0.01
        for load in [coarse.load, fine.load] {
            #expect(abs(load - expected) / expected < 0.1, "\(load / 1000) kN, expected \(expected / 1000)")
        }
        // Perfectly bonded, the same tie cracks along its whole length at once.
        let bonded = try pull(elementSize: 0.02, bond: nil)
        #expect(bonded.cracks.count > 40)
    }

    @Test("Without bars that slip, nothing changes; a model's bond is saved")
    func persistence() throws {
        var model = StructureModel(solids: [Box(min: .zero, max: SIMD3(1, 1, 1))], elementSize: 0.25)
        #expect(model.bondSlip == nil)
        model.bondSlip = BondSlip(condition: .splitting, barDiameter: 0.02)
        let data = try JSONEncoder().encode(model)
        #expect(try JSONDecoder().decode(StructureModel.self, from: data) == model)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["bondSlip"] = nil
        let old = try JSONDecoder().decode(
            StructureModel.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(old.bondSlip == nil)
    }

    @Test("The bond laws follow the Model Code's table")
    func laws() {
        let fc: Float = 30e6
        let pullOut = BondSlip(condition: .pullOut).law(compressiveStrength: fc)
        let pullOutPeak: Float = 2.5 * Float(30).squareRoot() * 1e6
        #expect(abs(pullOut.peak - pullOutPeak) < 1e3)
        #expect(pullOut.s1 == 1e-3 && pullOut.s2 == 2e-3 && abs(pullOut.residual - 0.4 * pullOut.peak) < 1)
        let splitting = BondSlip(condition: .splitting).law(compressiveStrength: fc)
        let splittingPeak: Float = 7 * pow(Float(1.2), 0.25) * 1e6
        #expect(abs(splitting.peak - splittingPeak) < 1e3)
        #expect(splitting.residual == 0 && abs(splitting.s3 - 1.2 * splitting.s1) < 1e-9)
        // At its peak slip, the pull-out curve's rising branch reaches the splitting strength.
        let reached: Float = pullOut.peak * pow(splitting.s1 / 1e-3, 0.4)
        #expect(abs(reached - splitting.peak) < 1e3)
    }
}
