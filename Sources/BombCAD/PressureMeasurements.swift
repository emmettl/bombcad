import Foundation

/// Derived from full saved samples using linear interpolation, never chart downsampling.
struct PressureMeasurements {
    var positiveImpulse = 0.0  // kPa·ms, numerically equal to Pa·s
    var signedImpulse = 0.0
    var arrival: Double?
    var positivePhaseDuration: Double?
    var startsAboveThreshold = false
    var phaseIsIncomplete = false

    init(points: [SavedSimulationRun.Point], threshold: Double) {
        guard let first = points.first else { return }
        let validThreshold = threshold.isFinite && threshold > 0
        startsAboveThreshold = validThreshold && first.value >= threshold
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = b.time - a.time
            guard dt > 0 else { continue }
            signedImpulse += (a.value + b.value) * 0.5 * dt * 1000
            if a.value >= 0 && b.value >= 0 {
                positiveImpulse += (a.value + b.value) * 0.5 * dt * 1000
            } else if a.value > 0 || b.value > 0 {
                let positive = max(a.value, b.value)
                positiveImpulse += 0.5 * positive * dt * positive / abs(b.value - a.value) * 1000
            }
            if validThreshold && !startsAboveThreshold && arrival == nil && a.value < threshold
                && b.value >= threshold
            {
                arrival = a.time + dt * (threshold - a.value) / (b.value - a.value)
            }
            if let arrival, positivePhaseDuration == nil, a.time >= arrival || b.time > arrival,
                a.value > 0, b.value <= 0
            {
                let end = a.time + dt * a.value / (a.value - b.value)
                positivePhaseDuration = end - arrival
            }
        }
        phaseIsIncomplete = (arrival != nil || startsAboveThreshold) && positivePhaseDuration == nil
    }
}

/// Conservative grouping: only air-grid resolution may differ. Resampled geometry is excluded.
struct GridMeasurementStudy {
    let runs: [SavedSimulationRun]

    init(runs: [SavedSimulationRun]) {
        self.runs = runs.sorted {
            (Resolution(rawValue: $0.settings.resolution)?.cellSize ?? 0)
                > (Resolution(rawValue: $1.settings.resolution)?.cellSize ?? 0)
        }
    }

    var isComparable: Bool {
        guard runs.count >= 2, let first = runs.first,
            Set(runs.map { $0.settings.resolution }).count == runs.count
        else { return false }
        return runs.allSatisfy { run in
            var settings = run.settings
            settings.resolution = first.settings.resolution
            return run.solverVersion == first.solverVersion
                && (try? SavedSimulationRun.fingerprint(run.scenario, settings: settings))
                    == first.inputSHA256
        }
    }
}
