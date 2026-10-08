import simd

/// Prescribed translation geometry and exact-trace conservation probe. The uniform gas
/// moves with the box, with matching supplied outer inflow/outflow; no gas state is evolved.
public enum ExperimentalTranslatingBoxGeometryStudy {
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let duration: Double
        public let velocity: SIMD3<Double>
        public let dryToWetCells: Int
        public let wetToDryCells: Int
        public let transientlyOccupiedCells: Int
        public let geometryEvaluations: Int
        public let maximumIntervals: Int
        public let maximumRelativeAreaClosure: Double
        public let maximumRelativeMomentClosure: Double
        public let maximumRelativeVolumeChangeResidual: Double
        public let maximumRelativeSharedAreaResidual: Double
        public let maximumRelativeSharedMomentResidual: Double
        public let globalInitialVolumeResidual: Double
        public let globalFinalVolumeResidual: Double
        public let globalVolumeTimeResidual: Double
        public let uniformPressureBodyImpulse: SIMD3<Double>
        public let uniformPressureBodyAngularImpulse: SIMD3<Double>
        public let uniformPressureBodyWork: Double
        /// Exact uniform Euler/wall traces integrated on the computed geometry. Errors
        /// use nominal cell inventory, so zero final volume needs no division or floor.
        public let maximumRelativeUniformMassResidual: Double
        public let maximumRelativeUniformMomentumResidual: Double
        public let maximumRelativeUniformEnergyResidual: Double
        public let minimumPredictedVolume: Double
    }
    enum Failure: Error { case invalidConfiguration }

    public static func run(
        cellSizes: [Double] = [0.2, 0.1], rotations: [Double] = [0, 0.23],
        duration: Double = 0.08, progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard duration.isFinite, duration > 0, duration <= 0.08 else { throw Failure.invalidConfiguration }
        var results: [Result] = []
        for h in cellSizes {
            guard h.isFinite, h >= 0.025, h <= 0.5,
                abs(2 / h - (2 / h).rounded()) < 1e-10
            else { throw Failure.invalidConfiguration }
            for angle in rotations {
                guard angle.isFinite else { throw Failure.invalidConfiguration }
                let result = try measure(h: h, angle: angle, duration: duration)
                results.append(result)
                try progress(result)
            }
        }
        return results
    }

    private static func measure(h: Double, angle: Double, duration: Double) throws -> Result {
        let velocity = SIMD3<Double>(3, 1, -0.4)
        let body = try RigidBoxBody(
            mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(1.013, 1.027, 1.041),
            orientation: simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3))))
        // The box remains wholly inside the 2 m cube for every orientation and duration allowed above.
        let sweep = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: velocity)
        let count = Int((2 / h).rounded())
        let nominalVolume = h * h * h
        let areaScale = h * h * duration
        let momentScale = nominalVolume * duration
        let density = 1.225
        let pressure = 101325.0
        let energyDensity = pressure / 0.4 + 0.5 * density * simd_length_squared(velocity)
        var cells: [TranslatingBoxSpaceTimeGeometry.Result] = []
        var dryToWet = 0
        var wetToDry = 0
        var transient = 0
        var evaluations = 0
        var intervals = 0
        var areaError = 0.0
        var momentError = 0.0
        var volumeError = 0.0
        var initialTotal = 0.0
        var finalTotal = 0.0
        var volumeTimeTotal = 0.0
        var bodyImpulse = SIMD3<Double>.zero
        var angularImpulse = SIMD3<Double>.zero
        var massError = 0.0
        var momentumError = 0.0
        var energyError = 0.0
        var minimumVolume = Double.infinity
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let lower = h * SIMD3(Double(x), Double(y), Double(z))
                    let r = try sweep.integrate(lower: lower, cellSize: h, duration: duration)
                    cells.append(r)
                    if r.initialGasVolume < nominalVolume * 1e-12 && r.finalGasVolume > nominalVolume * 1e-12
                    {
                        dryToWet += 1
                    }
                    if r.finalGasVolume < nominalVolume * 1e-12 && r.initialGasVolume > nominalVolume * 1e-12
                    {
                        wetToDry += 1
                    }
                    if r.initialGasVolume > nominalVolume * (1 - 1e-12)
                        && r.finalGasVolume > nominalVolume * (1 - 1e-12)
                        && r.gasVolumeTime < momentScale * (1 - 1e-10)
                    {
                        transient += 1
                    }
                    evaluations += r.evaluations
                    intervals = max(intervals, r.eventTimes.count - 1)
                    initialTotal += r.initialGasVolume
                    finalTotal += r.finalGasVolume
                    volumeTimeTotal += r.gasVolumeTime
                    let closure = r.openAreaVector + r.wallAreaVector
                    areaError = max(areaError, simd_length(closure) / areaScale)
                    var tensor = simd_double3x3()
                    for patch in r.openFaces + r.walls {
                        for axis in 0..<3 { tensor[axis] += patch.firstMomentTime * patch.normal[axis] }
                    }
                    for axis in 0..<3 {
                        var exact = SIMD3<Double>.zero
                        exact[axis] = r.gasVolumeTime
                        momentError = max(momentError, simd_length(tensor[axis] - exact) / momentScale)
                    }
                    let sweptGas = simd_dot(velocity, r.wallAreaVector)
                    volumeError = max(
                        volumeError, abs(r.finalGasVolume - r.initialGasVolume - sweptGas) / nominalVolume)
                    bodyImpulse += pressure * r.wallAreaVector
                    angularImpulse +=
                        pressure
                        * r.pressureAngularImpulse(
                            cellCentre: lower + SIMD3(repeating: h / 2), initialCentreOfMass: body.position,
                            velocity: velocity)
                    // Integrate supplied physical Euler traces, including pressure work on the
                    // moving wall. These expressions test geometry, not a numerical flux scheme.
                    let outwardVolume = simd_dot(velocity, r.openAreaVector)
                    let predictedVolume = r.initialGasVolume - outwardVolume
                    let predictedMomentum = density * velocity * predictedVolume - pressure * closure
                    let predictedEnergy =
                        energyDensity * r.initialGasVolume
                        - (energyDensity + pressure) * outwardVolume - pressure * sweptGas
                    minimumVolume = min(minimumVolume, predictedVolume)
                    massError = max(massError, abs(predictedVolume - r.finalGasVolume) / nominalVolume)
                    momentumError = max(
                        momentumError,
                        simd_length(predictedMomentum - density * velocity * r.finalGasVolume)
                            / (density * simd_length(velocity) * nominalVolume))
                    energyError = max(
                        energyError,
                        abs(predictedEnergy - energyDensity * r.finalGasVolume)
                            / (energyDensity * nominalVolume))
                }
            }
        }
        var sharedAreaError = 0.0
        var sharedMomentError = 0.0
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let index = x + count * (y + count * z)
                    for axis in 0..<3 where [x, y, z][axis] + 1 < count {
                        let neighbor = index + [1, count, count * count][axis]
                        let a = cells[index].openFaces[2 * axis + 1]
                        let b = cells[neighbor].openFaces[2 * axis]
                        var shift = SIMD3<Double>.zero
                        shift[axis] = h
                        sharedAreaError = max(sharedAreaError, abs(a.areaTime - b.areaTime) / areaScale)
                        sharedMomentError = max(
                            sharedMomentError,
                            simd_length(a.firstMomentTime - b.firstMomentTime - shift * b.areaTime)
                                / momentScale)
                    }
                }
            }
        }
        let exactVolume = 8 - pow(0.8, 3)
        return Result(
            cellSize: h, rotation: angle, duration: duration, velocity: velocity,
            dryToWetCells: dryToWet, wetToDryCells: wetToDry, transientlyOccupiedCells: transient,
            geometryEvaluations: evaluations, maximumIntervals: intervals,
            maximumRelativeAreaClosure: areaError, maximumRelativeMomentClosure: momentError,
            maximumRelativeVolumeChangeResidual: volumeError,
            maximumRelativeSharedAreaResidual: sharedAreaError,
            maximumRelativeSharedMomentResidual: sharedMomentError,
            globalInitialVolumeResidual: initialTotal - exactVolume,
            globalFinalVolumeResidual: finalTotal - exactVolume,
            globalVolumeTimeResidual: volumeTimeTotal - exactVolume * duration,
            uniformPressureBodyImpulse: bodyImpulse, uniformPressureBodyAngularImpulse: angularImpulse,
            uniformPressureBodyWork: simd_dot(velocity, bodyImpulse),
            maximumRelativeUniformMassResidual: massError,
            maximumRelativeUniformMomentumResidual: momentumError,
            maximumRelativeUniformEnergyResidual: energyError, minimumPredictedVolume: minimumVolume)
    }
}
