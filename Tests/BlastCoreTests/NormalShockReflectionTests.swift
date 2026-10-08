import Testing
import simd

@testable import BlastCore

@Suite("Independent normal-shock reflection")
struct NormalShockReflectionTests {
    @Test("Incident and reflected shocks satisfy mass, momentum and enthalpy jumps", arguments: [1.2, 2.0])
    func jumps(mach: Double) throws {
        let r = try NormalShockReflection(mach: mach)
        func check(rhoA: Double, pA: Double, uA: Double, rhoB: Double, pB: Double, uB: Double, speed: Double)
        {
            let a = uA - speed
            let b = uB - speed
            #expect(abs((rhoA * a) / (rhoB * b) - 1) < 1e-12)
            #expect(abs((pA + rhoA * a * a) / (pB + rhoB * b * b) - 1) < 1e-12)
            #expect(abs((3.5 * pA / rhoA + a * a / 2) / (3.5 * pB / rhoB + b * b / 2) - 1) < 1e-12)
        }
        check(
            rhoA: r.density, pA: r.pressure, uA: 0, rhoB: r.incidentDensity, pB: r.incidentPressure,
            uB: r.incidentVelocity, speed: -r.incidentSpeed)
        check(
            rhoA: r.incidentDensity, pA: r.incidentPressure, uA: r.incidentVelocity,
            rhoB: r.reflectedDensity, pB: r.reflectedPressure, uB: 0, speed: r.reflectedSpeed)
        #expect(r.interactionTime > 1.4 * r.arrivalTime)
    }
    @Test("Mach-two reflection gives closed-form pressure and density ratios")
    func knownState() throws {
        let r = try NormalShockReflection(mach: 2)
        #expect(abs(r.incidentPressure / r.pressure - 4.5) < 1e-12)
        #expect(abs(r.incidentDensity / r.density - 8.0 / 3) < 1e-12)
        #expect(abs(r.reflectedPressure / r.incidentPressure - 10.0 / 3) < 1e-12)
        #expect(abs(r.reflectedPressure / r.pressure - 15) < 1e-12)
        #expect(abs(r.reflectedDensity / r.density - 6) < 1e-12)
    }
    @Test("Exact wall load history is event-split and refuses boundary interactions")
    func histories() throws {
        let r = try NormalShockReflection(mach: 1.2)
        let area = 0.09
        let t = r.arrivalTime
        #expect(try r.wallPressure(time: 0.9 * t) == r.pressure)
        #expect(try r.wallPressure(time: 1.1 * t) == r.reflectedPressure)
        #expect(
            abs(
                try r.wallImpulse(time: 1.4 * t, area: area) - area * t
                    * (r.pressure + 0.4 * r.reflectedPressure)) < 1e-10)
        let initial = try r.cell(
            lower: r.shockPosition - 0.05, upper: r.shockPosition + 0.05, time: 0, area: area)
        #expect(abs(initial.amount[0] - 0.05 * area * (r.density + r.incidentDensity)) < 1e-12)
        #expect(throws: NormalShockReflection.Failure.self) { try r.wallPressure(time: r.interactionTime) }
        #expect(throws: NormalShockReflection.Failure.self) {
            try r.cell(lower: 1.9, upper: 2, time: t, area: area)
        }
        #expect(throws: NormalShockReflection.Failure.self) { try NormalShockReflection(mach: 1) }
        #expect(throws: NormalShockReflection.Failure.self) {
            try NormalShockReflection(mach: 2, pressure: Double.greatestFiniteMagnitude / 10)
        }
    }
    @Test("Unresolved initial wall loads record thresholds already exceeded at time zero")
    func initialRise() throws {
        let result = try #require(
            ExperimentalWallReflectionStudy.run(
                cellLengths: [1], cfls: [0.2], machNumbers: [1.2]
            ).first)
        #expect(result.rise10Time == 0)
    }
    @Test("Static channel closes budgets and reconstructed histories improve with refinement")
    func budgets() throws {
        var constantHistory = 0.0
        for limited in [false, true] {
            let rows = try ExperimentalWallReflectionStudy.run(
                cellLengths: limited ? [0.1, 0.05] : [0.1], cfls: [0.2], machNumbers: [1.2], limited: limited)
            for r in rows {
                #expect(r.frames.count == 4 && r.duration < r.interactionTime)
                #expect(abs(r.relativeMassChange) < 1e-12 && abs(r.relativeEnergyChange) < 1e-12)
                #expect(simd_length(r.momentumBudgetResidual) < 1e-10)
                #expect(r.relativePressureHistoryL1.isFinite && r.relativePressureHistoryL1 > 0)
                #expect(r.frames.last!.excessImpulse > 0)
                let t10 = try #require(r.rise10Time)
                let t50 = try #require(r.rise50Time)
                #expect(t10 < t50 && t10 >= 0 && t50 < r.duration)
                if let t90 = r.rise90Time {
                    #expect(t50 < t90 && t90 < r.duration)
                    #expect(t10 < r.arrivalTime && t90 > r.arrivalTime)
                } else {
                    // Coarse first-order transport may not finish its smeared rise by the cutoff.
                    #expect(!limited)
                }
            }
            if limited {
                let coarse = try #require(rows.first { $0.cellLength == 0.1 })
                let fine = try #require(rows.first { $0.cellLength == 0.05 })
                #expect(coarse.relativePressureHistoryL1 < 0.8 * constantHistory)
                #expect(fine.relativePressureHistoryL1 < 0.7 * coarse.relativePressureHistoryL1)
                #expect(abs(fine.frames.last!.impulseError) < abs(coarse.frames.last!.impulseError))
                let coarseWidth = try #require(coarse.rise90Time) - #require(coarse.rise10Time)
                let fineWidth = try #require(fine.rise90Time) - #require(fine.rise10Time)
                #expect(fineWidth < 0.7 * coarseWidth)
            } else {
                constantHistory = try #require(rows.first).relativePressureHistoryL1
            }
        }
    }
}
