import Testing

@testable import BombCAD

@Suite struct PressureMeasurementTests {
    private func point(_ time: Double, _ value: Double) -> SavedSimulationRun.Point {
        .init(time: time, value: value)
    }

    @Test func interpolatesArrivalAndZeroCrossings() {
        let result = PressureMeasurements(
            points: [point(0, 0), point(0.002, 4), point(0.006, -4)], threshold: 1)
        #expect(abs(result.arrival! - 0.0005) < 1e-12)
        #expect(abs(result.positivePhaseDuration! - 0.0035) < 1e-12)
        #expect(abs(result.positiveImpulse - 8) < 1e-12)
        #expect(abs(result.signedImpulse - 4) < 1e-12)
        #expect(!result.phaseIsIncomplete)
    }

    @Test func integratesAllPositiveLobesButUsesFirstPhase() {
        let result = PressureMeasurements(
            points: [point(0, -2), point(0.002, 2), point(0.004, -2), point(0.006, 2)], threshold: 1)
        #expect(abs(result.positiveImpulse - 3) < 1e-12)
        #expect(abs(result.signedImpulse) < 1e-12)
        #expect(abs(result.arrival! - 0.0015) < 1e-12)
        #expect(abs(result.positivePhaseDuration! - 0.0015) < 1e-12)
    }

    @Test func censoredAndUndetectedTraces() {
        let startsHigh = PressureMeasurements(points: [point(0.001, 2), point(0.002, -1)], threshold: 1)
        #expect(startsHigh.startsAboveThreshold)
        #expect(startsHigh.arrival == nil)
        #expect(startsHigh.positivePhaseDuration == nil)
        let unfinished = PressureMeasurements(points: [point(0, 0), point(0.002, 2)], threshold: 1)
        #expect(unfinished.phaseIsIncomplete)
        let quiet = PressureMeasurements(points: [point(0, 0), point(0.002, 0.5)], threshold: 1)
        #expect(quiet.arrival == nil)
        #expect(!quiet.phaseIsIncomplete)
        #expect(PressureMeasurements(points: [], threshold: 1).positiveImpulse == 0)
    }

    @Test func invalidThresholdDoesNotEraseImpulse() {
        for threshold in [0.0, -1.0, Double.nan, Double.infinity] {
            let result = PressureMeasurements(points: [point(0, 0), point(0.002, 2)], threshold: threshold)
            #expect(result.positiveImpulse == 2)
            #expect(result.arrival == nil)
        }
    }

    @Test func gridGroupingRejectsConfoundingInputs() throws {
        let coarse = try SavedRunTests().fixture()
        var fine = coarse
        fine.settings.resolution = "fine"
        fine.inputSHA256 = try SavedSimulationRun.fingerprint(fine.scenario, settings: fine.settings)
        #expect(GridMeasurementStudy(runs: [fine, coarse]).isComparable)
        #expect(!GridMeasurementStudy(runs: [coarse, coarse]).isComparable)
        fine.scenario.charge.mass += 1
        #expect(!GridMeasurementStudy(runs: [coarse, fine]).isComparable)
        fine = coarse
        fine.settings.resolution = "fine"
        fine.solverVersion = "another-solver"
        #expect(!GridMeasurementStudy(runs: [coarse, fine]).isComparable)
    }
}
