import Foundation
import simd

/// An initially smooth pressure pulse evolves around a prescribed translating box.
/// Matched pulse energy permits grid/CFL comparisons of numerical impulse and torque.
/// This is not an exact Euler solution, blast validation or free-body response.
public enum ExperimentalMovingLoadStudy {
    public struct Frame: Codable, Sendable {
        public let time: Double
        public let steps: Int
        public let rejectedSteps: Int
        public let dryToWetCells: Int
        public let wetToDryCells: Int
        public let partitionChangedSteps: Int
        public let minimumPressure: Double
        public let minimumDensity: Double
        public let maximumRelativeDensityDeparture: Double
        public let maximumRelativePressureDeparture: Double
        public let maximumPerturbationSpeed: Double
        public let bodyImpulse: SIMD3<Double>
        public let bodyAngularImpulse: SIMD3<Double>
        public let bodyWork: Double
        public let massBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let energyBudgetResidual: Double
        public let volumeResidual: Double
        public let impulseWorkResidual: Double
        public let wallSampleFallbacks: Int
        public let scatterPositivityReducedGroups: Int
        public let scatterRankDeficientGroups: Int
    }
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let cfl: Double
        public let duration: Double
        public let velocity: SIMD3<Double>
        public let displacement: SIMD3<Double>
        public let targetPulseEnergy: Double
        public let initialPulseEnergy: Double
        public let pulseAmplitude: Double
        public let pulseCentre: SIMD3<Double>
        public let pulseWidth: SIMD3<Double>
        public let initialMass: Double
        public let initialEnergy: Double
        public let maximumInitialPressure: Double
        public let maximumRelativeQuadratureVolumeResidual: Double
        public let maximumRelativeGeometryResidual: Double
        public let maximumMembers: Int
        public let minimumOldGroupFraction: Double
        public let minimumFinalGroupFraction: Double
        public let referenceDryToWetCells: Int
        public let referenceWetToDryCells: Int
        public let transport: String
        public let wallIntegration: String
        public let computeSeconds: Double
        public let frames: [Frame]
    }
    enum Failure: Error { case invalidConfiguration, invalidQuadrature }
    static let pulseCentre = SIMD3<Double>(0.45, 1.18, 1.10)
    static let pulseWidth = SIMD3<Double>(0.14, 0.18, 0.18)
    struct InitialState {
        let cells: [FractionalGasTransport.Cell]
        let amplitude: Double
        let pulseEnergy: Double
        let mass: Double
        let energy: Double
        let maximumPressure: Double
        let quadratureResidual: Double
    }
    /// Compensated reductions separate state/geometry errors from long inventory sums.
    private struct Sum {
        var value = 0.0
        private var correction = 0.0
        mutating func add(_ term: Double) {
            let increment = term - correction
            let next = value + increment
            correction = (next - value) - increment
            value = next
        }
    }
    static func initialState(h: Double, angle: Double, targetEnergy: Double) throws -> InitialState {
        guard h.isFinite && h >= 0.05 && h <= 0.2, abs(2 / h - (2 / h).rounded()) < 1e-10,
            angle.isFinite, targetEnergy.isFinite && targetEnergy >= 0
        else { throw Failure.invalidConfiguration }
        let body = try ExperimentalMovingGroupsStudy.body(angle: angle, time: 0)
        let geometry = FractionalBoxGeometry(body)
        let count = Int((2 / h).rounded())
        var volumes: [Double] = []
        var averages: [Double] = []
        var coefficient = Sum()
        var residual = 0.0
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let lower = h * SIMD3(Double(x), Double(y), Double(z))
                    let volume = geometry.gasVolume(lower: lower, cellSize: h)
                    var average = 0.0
                    if volume > 0 {
                        let nodes = geometry.gasQuadrature(lower: lower, cellSize: h)
                        let weight = nodes.reduce(0) { $0 + $1.weight }
                        guard weight.isFinite && weight > 0 else { throw Failure.invalidQuadrature }
                        let error = abs(weight - volume) / (h * h * h)
                        guard error < 1e-8 else { throw Failure.invalidQuadrature }
                        residual = max(residual, error)
                        average =
                            nodes.reduce(0) {
                                let offset = ($1.point - pulseCentre) / pulseWidth
                                return $0 + $1.weight * exp(-0.5 * simd_length_squared(offset))
                            } / weight
                        coefficient.add(volume * average / (1.4 - 1))
                    }
                    volumes.append(volume)
                    averages.append(average)
                }
            }
        }
        guard coefficient.value.isFinite && coefficient.value > 0 else { throw Failure.invalidQuadrature }
        let amplitude = targetEnergy / coefficient.value
        var mass = Sum()
        var energy = Sum()
        var pulse = Sum()
        var maximumPressure = 101325.0
        let velocity = 100 * ExperimentalMovingGroupsStudy.velocity
        let cells = volumes.indices.map { n in
            let pressure = 101325 + amplitude * averages[n]
            let cell = FractionalGasTransport.Cell(
                volume: volumes[n], density: 1.225,
                velocity: velocity, pressure: pressure)
            mass.add(cell.amount[0])
            energy.add(cell.amount[4])
            if volumes[n] > 0 {
                // Audit the realized pressure field, rather than returning targetEnergy.
                pulse.add(volumes[n] * (cell.pressure() - 101325) / (1.4 - 1))
                maximumPressure = max(maximumPressure, cell.pressure())
            }
            return cell
        }
        _ = try FractionalGasTransport.advance(cells, newVolumes: volumes, transfers: [])
        return .init(
            cells: cells, amplitude: amplitude, pulseEnergy: pulse.value, mass: mass.value,
            energy: energy.value, maximumPressure: maximumPressure, quadratureResidual: residual)
    }
    public static func run(
        cellSizes: [Double] = [0.2, 0.1, 0.05], rotations: [Double] = [0, 0.23],
        cfls: [Double] = [0.2, 0.1], duration: Double = 0.0002, targetPulseEnergy: Double = 6400,
        progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard duration.isFinite && duration > 0 && duration <= 0.0008,
            targetPulseEnergy.isFinite && targetPulseEnergy >= 0,
            !cellSizes.isEmpty && !rotations.isEmpty && !cfls.isEmpty,
            cfls.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 0.5 })
        else { throw Failure.invalidConfiguration }
        var rows: [Result] = []
        for h in cellSizes {
            for angle in rotations {
                let initial = try initialState(h: h, angle: angle, targetEnergy: targetPulseEnergy)
                for cfl in cfls {
                    let run = try ExperimentalMovingTrajectoryStudy.solve(
                        h: h, angle: angle, start: 0, duration: duration, velocityScale: 100,
                        cfl: cfl, maximumStep: h * 0.00008,
                        limited: true, secondOrder: true, surfaceQuadrature: true, initialCells: initial.cells
                    )
                    let frames = run.frames.map { f in
                        Frame(
                            time: f.time, steps: f.steps, rejectedSteps: f.rejectedSteps,
                            dryToWetCells: f.dryToWetCells, wetToDryCells: f.wetToDryCells,
                            partitionChangedSteps: f.partitionChangedSteps,
                            minimumPressure: min(101325, f.minimumPressure),
                            minimumDensity: min(1.225, f.minimumDensity),
                            maximumRelativeDensityDeparture: f.maximumRelativeDensityError,
                            maximumRelativePressureDeparture: max(
                                initial.maximumPressure / 101325 - 1, f.maximumRelativePressureError),
                            maximumPerturbationSpeed: f.maximumVelocityError,
                            bodyImpulse: f.bodyImpulse, bodyAngularImpulse: f.bodyAngularImpulse,
                            bodyWork: f.bodyWork,
                            massBudgetResidual: f.massBudgetResidual,
                            momentumBudgetResidual: f.momentumBudgetResidual,
                            energyBudgetResidual: f.energyBudgetResidual, volumeResidual: f.volumeResidual,
                            impulseWorkResidual: f.impulseWorkResidual,
                            wallSampleFallbacks: f.wallSampleFallbacks,
                            scatterPositivityReducedGroups: f.scatterPositivityReducedGroups,
                            scatterRankDeficientGroups: f.scatterRankDeficientGroups)
                    }
                    let row = Result(
                        cellSize: h, rotation: angle, cfl: cfl, duration: duration,
                        velocity: run.velocity, displacement: run.displacement,
                        targetPulseEnergy: targetPulseEnergy, initialPulseEnergy: initial.pulseEnergy,
                        pulseAmplitude: initial.amplitude, pulseCentre: pulseCentre, pulseWidth: pulseWidth,
                        initialMass: initial.mass, initialEnergy: initial.energy,
                        maximumInitialPressure: initial.maximumPressure,
                        maximumRelativeQuadratureVolumeResidual: initial.quadratureResidual,
                        maximumRelativeGeometryResidual: run.maximumRelativeGeometryResidual,
                        maximumMembers: run.maximumMembers,
                        minimumOldGroupFraction: run.minimumOldGroupFraction,
                        minimumFinalGroupFraction: run.minimumFinalGroupFraction,
                        referenceDryToWetCells: run.referenceDryToWetCells,
                        referenceWetToDryCells: run.referenceWetToDryCells,
                        transport: "limitedHeun", wallIntegration: run.wallIntegration,
                        computeSeconds: run.computeSeconds, frames: frames)
                    rows.append(row)
                    try progress(row)
                }
            }
        }
        return rows
    }
}
