import simd

/// Prescribed pressure traces integrated on a translating wall. This is a load/quadrature
/// reference, not an Euler solution or feedback into the moving-group time integrator.
enum MovingWallPressureQuadrature {
    enum Failure: Error { case invalidSamples, invalidPressure }
    struct Load {
        let impulse: SIMD3<Double>
        let angularImpulse: SIMD3<Double>
        let work: Double

        /// The same pressure packet applies with opposite signs to gas and body.
        func gasReaction(cell: Int) -> FractionalGasTransport.WallExchange {
            .init(cell: cell, impulse: -impulse, gasWork: -work)
        }
    }

    static func integrate(
        _ patch: TranslatingBoxSpaceTimeGeometry.PatchIntegral,
        cellCentre: SIMD3<Double>, initialCentreOfMass: SIMD3<Double>, velocity: SIMD3<Double>,
        duration: Double, lengthScale: Double,
        pressure: (SIMD3<Double>, Double) throws -> Double
    ) throws -> Load {
        guard let samples = patch.samples,
            duration.isFinite && duration > 0, lengthScale.isFinite && lengthScale > 0,
            patch.areaTime.isFinite && patch.areaTime >= 0,
            (0..<3).allSatisfy({
                cellCentre[$0].isFinite && initialCentreOfMass[$0].isFinite && velocity[$0].isFinite
                    && patch.normal[$0].isFinite && patch.firstMomentTime[$0].isFinite
            }), abs(simd_length_squared(patch.normal) - 1) < 1e-12,
            patch.timeWeightedArea.isFinite
        else { throw Failure.invalidSamples }
        let areaScale = max(patch.areaTime, lengthScale * lengthScale * duration * 1e-12)
        var area = 0.0
        var moment = SIMD3<Double>.zero
        var timeMoment = 0.0
        for sample in samples {
            guard sample.areaTime.isFinite && sample.areaTime > 0,
                sample.time.isFinite && sample.time >= 0 && sample.time <= duration,
                (0..<3).allSatisfy({ sample.point[$0].isFinite }), patch.areaTime > 0
            else { throw Failure.invalidSamples }
            area += sample.areaTime
            moment += sample.areaTime * (sample.point - cellCentre)
            timeMoment += sample.time * sample.areaTime
            let meanPoint = cellCentre + patch.firstMomentTime / patch.areaTime
            let meanTime = patch.timeWeightedArea / patch.areaTime
            // The samples follow one translating plane, rather than lying on the
            // time-averaged plane. Applying the static coplanarity check would be wrong.
            let distance = simd_dot(
                sample.point - meanPoint - (sample.time - meanTime) * velocity, patch.normal)
            guard abs(distance) < 1e-8 * lengthScale else { throw Failure.invalidSamples }
        }
        guard abs(area - patch.areaTime) <= 1e-8 * areaScale,
            simd_length(moment - patch.firstMomentTime) <= 1e-8 * areaScale * lengthScale,
            abs(timeMoment - patch.timeWeightedArea) <= 1e-8 * areaScale * duration
        else { throw Failure.invalidSamples }
        var impulse = SIMD3<Double>.zero
        var angular = SIMD3<Double>.zero
        var work = 0.0
        for sample in samples {
            let p = try pressure(sample.point, sample.time)
            guard p.isFinite && p > 0 else { throw Failure.invalidPressure }
            let packet = sample.areaTime * p * patch.normal  // Gas-outward normal acts on body.
            impulse += packet
            angular += simd_cross(sample.point - initialCentreOfMass - sample.time * velocity, packet)
            work += simd_dot(velocity, packet)
        }
        return .init(impulse: impulse, angularImpulse: angular, work: work)
    }
}
