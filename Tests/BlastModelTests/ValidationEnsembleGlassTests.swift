import Foundation
import Testing

@testable import BlastModel

/// The calibration's glass cases on the CPU (`ValidationEnsemble+Glass`; docs/calibration.md).
@Suite("The calibration's glass cases")
struct ValidationEnsembleGlassTests {
    @Test("The calibration's glass cases give the record's figures at today's flaw constant and move with it")
    func calibrationGlass() throws {
        let today = try ValidationEnsemble.monkBreakTimes(flawFactor: 1)
        // docs/validation.md, "Window glass": 2.92, 3.01, 3.21 and 2.97 ms.
        #expect(abs((today["t1-1"] ?? 0) - 2.92) < 0.02 && abs((today["t1-1.7"] ?? 0) - 3.21) < 0.02)
        let stronger = try ValidationEnsemble.monkBreakTimes(flawFactor: 0.1)
        #expect(today.keys.allSatisfy { (stronger[$0] ?? 0) > (today[$0] ?? .infinity) })
        // E1300's: 0.57–0.72 of its load resistance with the whole pane at its largest stress.
        let resistances = ValidationEnsemble.e1300Resistances(flawFactor: 1)
        for pane in ValidationEnsemble.e1300Panes {
            let ratio = (resistances["lr" + pane.name] ?? 0) / pane.load
            #expect((0.56...0.73).contains(ratio), "\(pane.name): \(ratio)")
        }
    }
}
