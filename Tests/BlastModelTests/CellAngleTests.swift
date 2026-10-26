import Foundation
import Testing

@testable import BlastModel

/// The judges' split by the line's angle to the solver's cells (`CellAngle`,
/// emmettl/bombcad-work#107): the classes, the diagonal figure and the balance.
@Suite("Judges by angle to the cells")
struct CellAngleTests {
    @Test("Lines are classed by the nearer cell axis, in every quadrant")
    func classes() {
        #expect(CellAngle(dx: 100, dy: 0) == .axis)
        #expect(CellAngle(dx: 0, dy: -100) == .axis)
        #expect(CellAngle(dx: -100, dy: 20) == .axis)
        #expect(CellAngle(dx: 100, dy: 40) == .between)
        #expect(CellAngle(dx: -40, dy: -100) == .between)
        #expect(CellAngle(dx: 100, dy: 100) == .diagonal)
        #expect(CellAngle(dx: -100, dy: 70) == .diagonal)
        #expect(abs(CellAngle.degrees(dx: -3, dy: 3) - 45) < 1e-9)
        #expect(abs(CellAngle.degrees(dx: 1, dy: -0.0001)) < 0.01)
    }

    @Test("The balance weights each class alike and leaves out a thin one")
    func balance() {
        // 90 axis sides all broken, 30 diagonal sides none broken, 5 between sides broken.
        let classes =
            [CellAngle](repeating: .axis, count: 90) + .init(repeating: .diagonal, count: 30)
            + .init(repeating: .between, count: 5)
        let values =
            [Double](repeating: 1, count: 90) + .init(repeating: 0, count: 30) + .init(repeating: 1, count: 5)
        let f = CellAngle.mean(values, classes)
        #expect(abs(f.all - 95.0 / 125) < 1e-12)
        #expect(f.diagonal == 0)
        #expect(abs(f.balanced! - 0.5) < 1e-12)
        #expect(f.counts == [90, 5, 30])
        // Too few diagonal sides: no diagonal figure, the balance the axis class alone.
        let thin = CellAngle.mean([1, 1, 0], [.axis, .axis, .diagonal])
        #expect(thin.diagonal == nil)
        #expect(thin.balanced == nil)
    }

    @Test("Medians: all as the judges take it, the diagonal alone, the weighted median balanced")
    func medians() {
        let classes = [CellAngle](repeating: .axis, count: 60) + .init(repeating: .diagonal, count: 40)
        let logs = [Double](repeating: log(1.2), count: 60) + .init(repeating: log(0.95), count: 40)
        let f = CellAngle.median(logs, classes)
        #expect(abs(f.all - 1.2) < 1e-12)
        #expect(abs(f.diagonal! - 0.95) < 1e-12)
        // Weighted alike, half the weight sits at 0.95: the weighted median is its top.
        #expect(abs(f.balanced! - 0.95) < 1e-12)
    }

    @Test("A weighted reliability with equal weights is the plain one")
    func reliability() {
        let predicted = (0..<300).map { Double($0 % 10) / 10 + 0.05 }
        let observed = (0..<300).map { $0 % 3 == 0 ? 1.0 : 0 }
        let plain = GlassCalibration.reliability("plain", predicted: predicted, observed: observed)
        let weighted = GlassCalibration.reliability(
            "weighted", predicted: predicted, observed: observed, weights: .init(repeating: 2, count: 300))
        #expect(abs(plain.brier - weighted.brier) < 1e-12)
        #expect(abs(plain.climatology - weighted.climatology) < 1e-12)
        #expect(plain.bins.count == weighted.bins.count)
        for (a, b) in zip(plain.bins, weighted.bins) {
            #expect(a.count == b.count)
            #expect(abs(a.predicted - b.predicted) < 1e-12)
            #expect(abs(a.observed - b.observed) < 1e-12)
        }
    }
}
