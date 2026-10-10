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

    static let diameter = TieBenchmark.diameter
    static let material = TieBenchmark.material

    @Test("A tie cracks at the Model Code's spacing, the same on two meshes, and stiffens as it says")
    func tie() throws {
        let bond = BondSlip(condition: .pullOut, barDiameter: Self.diameter)
        let coarse = try TieBenchmark.run(device: device, elementSize: 0.02, bond: bond)
        let fine = try TieBenchmark.run(device: device, elementSize: 0.01, bond: bond)
        // Transfer length l_t = f_ctm d / (4 tau_bms rho), with the mean bond stress while
        // cracks form tau_bms = 1.8 f_ctm (MC2010 7.6.4): cracks l_t to 2 l_t apart, so between
        // 1 / (2 l_t) and 1 / l_t of them in the metre.
        let transfer = TieBenchmark.transferLength()
        for cracks in [coarse.cracks.count, fine.cracks.count] {
            #expect(
                Float(cracks) >= 1 / (2 * transfer) - 1 && Float(cracks) <= 1 / transfer + 1,
                "\(cracks) cracks")
        }
        #expect(abs(coarse.cracks.count - fine.cracks.count) <= 1)
        // Tension stiffening (MC2010 7.6.5, beta = 0.4): at a mean strain of 1.5e-3 the bars at
        // the cracks carry E_s eps + beta f_ctm (1 + alpha_e rho) / rho.
        let expected = TieBenchmark.expectedLoad(
            strain: 1.5e-3, beta: 0.4, strength: Self.material.tensileStrength)
        for load in [coarse.load, fine.load] {
            #expect(abs(load - expected) / expected < 0.1, "\(load / 1000) kN, expected \(expected / 1000)")
        }
        // Perfectly bonded, the same tie cracks along its whole length at once.
        let bonded = try TieBenchmark.run(device: device, elementSize: 0.02, bond: nil)
        #expect(bonded.cracks.count > 40)
    }

    @Test(
        "With the concrete's strengths raised as at blast rates and the bond not, the tie still stiffens as the Model Code says"
    )
    func raisedTie() throws {
        // The tension the concrete between cracks carries comes only through the bond: raised
        // by half, the tensile strength sets it, and the static bond spaces the cracks further.
        let factor: Float = 1.5
        let bond = BondSlip(condition: .pullOut, barDiameter: Self.diameter)
        let transfer = TieBenchmark.transferLength(raised: factor)
        let expected = TieBenchmark.expectedLoad(
            strain: 1.5e-3, beta: 0.4, strength: Self.material.tensileStrength * factor)
        for h: Float in [0.02, 0.01] {
            let result = try TieBenchmark.run(device: device, elementSize: h, bond: bond) { material in
                material.concreteRateFactor = factor
                material.fractureEnergy *= factor.squareRoot()
            }
            let cracks = Float(result.cracks.count)
            #expect(
                cracks >= 1 / (2 * transfer) - 1 && cracks <= 1 / transfer + 1, "\(cracks) cracks on \(h) m")
            // (82.6 and 74.0 kN on 20 and 10 mm elements when written, against 80.1 kN.)
            #expect(
                abs(result.load - expected) / expected < 0.1,
                "\(result.load / 1000) kN, expected \(expected / 1000)")
        }
    }

    @Test("Bars that lose bond where they yield yield over a longer length")
    func yieldedBond() throws {
        /// A 0.6 m tie, 50 mm square, 1% of 12 mm bars, with a weaker slice in the middle, pulled
        /// until its bars have yielded across the crack there: the length along which they have
        /// yielded. Their hardening, 500 to 575 MPa, spreads yield only some 16 mm / Omega_y either
        /// side of the crack, so the elements are 10 mm.
        func yieldedLength(loss: Bool) throws -> Float {
            let h: Float = 0.01
            var weak = Self.material
            weak.tensileStrength *= 0.8
            weak.name = "Weak"
            let tie = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.6, 0.05, 1.05))
            let slice = Box(min: SIMD3(0.3, 0, 1), max: SIMD3(0.3 + h, 0.05, 1.05))
            var model = StructureModel(
                solids: [tie, slice], material: Self.material, elementSize: h, fixedBase: false)
            model.setMaterial(weak, of: 1)
            model.reinforcement = [ReinforcementLayer(region: tie, ratio: SIMD3(0.01, 0, 0))]
            model.bondSlip = BondSlip(condition: .pullOut, barDiameter: Self.diameter, yieldedBondLoss: loss)
            let solver = try StructureSolver(device: device, model: model)
            solver.gravity = 0
            solver.groundContact = false
            solver.damping = 200
            let rate: Float = 0.05
            solver.mutateNodes { nodes in
                for k in 0...solver.ez {
                    for j in 0...solver.ey {
                        if let n = solver.storedNode(0, j, k) { nodes[n].isFixed = true }
                        if let n = solver.storedNode(solver.ex, j, k) {
                            nodes[n].isPrescribed = true
                            nodes[n].velocity = SIMD3(rate, 0, 0)
                        }
                    }
                }
            }
            solver.advance(steps: Int((0.006 / rate / solver.criticalTimeStep).rounded()))
            // Along the tie, the elements in which any bar has yielded.
            let yielded = (0..<solver.ex).filter { i in
                (0..<solver.ey).contains { j in
                    (0..<solver.ez).contains { k in
                        solver.flag(i, j, k) == .active && solver.barPlasticStrain(i, j, k).x > 0
                    }
                }
            }
            return Float(yielded.count) * h
        }
        let losing = try yieldedLength(loss: true)
        let keeping = try yieldedLength(loss: false)
        #expect(keeping > 0)
        // (0.20 m against 0.15 m when written.)
        #expect(losing > 1.2 * keeping, "\(losing) m against \(keeping) m")
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
