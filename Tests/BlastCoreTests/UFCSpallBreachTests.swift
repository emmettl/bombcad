import Foundation
import Testing

@testable import BlastCore

/// UFC 3-340-02 §4-55's threshold spall and breach curves (`UFCSpallBreach`).
@Suite("UFC spall and breach")
struct UFCSpallBreachTests {
    @Test("The breach threshold, equation 4-179, is Figure 4-65a's curve as the UFC's data plot it")
    func curve() {
        // (Ψ, h/R) on the plotted breach curve (ufc_3_340_02_dplot_v2.zip, Plots/04_065a.grf).
        let plotted: [(Double, Double)] = [
            (1.795, 2.16036), (3.504, 0.85456), (5.214, 0.46476), (6.923, 0.29349), (8.632, 0.20255),
            (10.342, 0.14835), (12.051, 0.11339), (13.761, 0.08952),
        ]
        for (psi, ratio) in plotted {
            #expect(abs(UFCSpallBreach.breachRatio(psi: psi) / ratio - 1) < 0.04, "Ψ \(psi)")
        }
        // Spall comes before breach: a thicker slab spalls where a thinner one is breached.
        for psi in stride(from: 0.5, through: 14, by: 0.5) {
            #expect(UFCSpallBreach.spallRatio(psi: psi) > UFCSpallBreach.breachRatio(psi: psi))
        }
    }

    @Test("Hupfauf's contact slabs: every one breached is, and the upper bound breaches two that held")
    func hupfauf() {
        // The TNT sphere touching the slab: range its radius; the cylinder strength 0.8 of the cube's.
        var predicted: [String: UFCSpallBreach.Outcome] = [:]
        for test in ContactSlabTest.tests {
            let mass = Double(test.tntSphere)
            let radius = cbrt(3 * mass / (4 * .pi * 1_600))
            predicted[test.name] = UFCSpallBreach.outcome(
                thickness: Double(test.thickness), range: radius, strength: 0.8 * 42.7e6, charge: mass,
                surface: true, contact: true)
        }
        for test in ContactSlabTest.tests where test.breach {
            #expect(predicted[test.name] == .breached, "\(test.name)")
        }
        let held = ContactSlabTest.tests.filter { !$0.breach }
        #expect(held.filter { predicted[$0.name] == .breached }.map(\.name).sorted() == ["SN147", "SN175"])
        #expect(held.allSatisfy { predicted[$0.name] != UFCSpallBreach.Outcome.none })
    }
}
