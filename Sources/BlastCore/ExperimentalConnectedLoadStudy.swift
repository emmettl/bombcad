import Foundation
import simd

/// Closed-domain smooth pressure pulse around a held clipped box. This is not blast validation.
public enum ExperimentalConnectedLoadStudy {
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let duration: Double
        public let cfl: Double
        public let pulseAmplitude: Double
        public let pulseEnergy: Double
        public let requestedPulseEnergy: Double?
        public let initialization: String
        public let maximumQuadratureVolumeResidual: Double
        public let steps: Int
        public let groups: Int
        public let initialMass: Double
        public let initialEnergy: Double
        public let relativeMassChange: Double
        public let relativeEnergyChange: Double
        public let bodyImpulse: SIMD3<Double>
        public let bodyAngularImpulse: SIMD3<Double>
        public let domainImpulse: SIMD3<Double>
        public let momentumBudgetResidual: SIMD3<Double>
        public let wallWork: Double
        public let minimumPressure: Double
        public let maximumSpeed: Double
    }
    enum Failure: Error { case invalidConfiguration, stepLimit }
    public static func run(
        cellSizes: [Double] = [0.2, 0.1], rotations: [Double] = [0, 0.23],
        duration: Double = 0.0005, pulseAmplitude: Double = 40000,
        cfls: [Double] = [0.2], targetPulseEnergy: Double? = nil, volumeAverage: Bool = false,
        progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard duration.isFinite && duration > 0, pulseAmplitude.isFinite && pulseAmplitude >= 0,
            cfls.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 0.5 }),
            targetPulseEnergy.map({ $0.isFinite && $0 >= 0 }) ?? true
        else {
            throw Failure.invalidConfiguration
        }
        var results: [Result] = []
        for h in cellSizes {
            for angle in rotations {
                let domain = try ExperimentalConnectedGasStudy.domain(cellSize: h, rotation: angle)
                func pulse(_ point: SIMD3<Double>) -> Double {
                    let offset = (point - SIMD3(0.45, 1.18, 1.10)) / SIMD3(0.14, 0.18, 0.18)
                    return exp(-0.5 * simd_length_squared(offset))
                }
                var quadratureResidual = 0.0
                let weights = try domain.cells.indices.map { n -> Double in
                    guard volumeAverage else { return pulse(domain.centres[n]) }
                    guard domain.cells[n].volume > 0 else { return 0 }
                    let nodes = domain.geometry.gasQuadrature(
                        lower: domain.centres[n] - SIMD3(repeating: h / 2), cellSize: h)
                    let volume = nodes.reduce(0) { $0 + $1.weight }
                    let residual = abs(volume - domain.cells[n].volume) / (h * h * h)
                    guard volume.isFinite && volume > 0 && residual < 1e-8 else {
                        throw Failure.invalidConfiguration
                    }
                    quadratureResidual = max(quadratureResidual, residual)
                    return nodes.reduce(0) { $0 + $1.weight * pulse($1.point) } / volume
                }
                var coefficient = 0.0
                var correction = 0.0
                for n in domain.cells.indices {
                    let term = domain.cells[n].volume * weights[n] / (1.4 - 1) - correction
                    let next = coefficient + term
                    correction = (next - coefficient) - term
                    coefficient = next
                }
                guard coefficient > 0 && coefficient.isFinite else { throw Failure.invalidConfiguration }
                let amplitude = targetPulseEnergy.map { $0 / coefficient } ?? pulseAmplitude
                guard amplitude.isFinite else { throw Failure.invalidConfiguration }
                let initial = domain.cells.indices.map {
                    FractionalGasTransport.Cell(
                        volume: domain.cells[$0].volume, density: 1.225,
                        pressure: 101325 + amplitude * weights[$0])
                }
                let plan = try ConnectedGasGroups.build(
                    cells: initial, centres: domain.centres,
                    nominalVolume: h * h * h, faces: domain.faces, boundaries: domain.boundaries)
                let faces = plan.faces.map {
                    FractionalEulerFlux.Face(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area)
                }
                let walls = plan.boundaries.map {
                    FractionalEulerFlux.Wall(cell: $0.cell, normal: $0.normal, area: $0.area)
                }
                for cfl in cfls {
                    var cells = plan.groups.map(\.cell)
                    let before = totalAmount(initial)
                    var elapsed = 0.0
                    var steps = 0
                    var bodyImpulse = SIMD3<Double>.zero
                    var angularImpulse = SIMD3<Double>.zero
                    var domainImpulse = SIMD3<Double>.zero
                    var wallWork = 0.0
                    while elapsed < duration {
                        let limit = try FractionalEulerFlux.maximumStep(
                            cells, faces: faces, walls: walls, cfl: cfl)
                        let step = min(limit, duration - elapsed)
                        guard steps < 10000 && step > 0 && elapsed + step > elapsed else {
                            throw Failure.stepLimit
                        }
                        let update = try FractionalEulerFlux.advanceWithWalls(
                            cells, faces: faces, walls: walls,
                            duration: step, cfl: cfl)
                        cells = update.cells
                        for n in plan.boundaries.indices {
                            let patch = plan.boundaries[n]
                            if patch.owner == 1 {
                                bodyImpulse += update.wallImpulses[n]
                                angularImpulse += simd_cross(
                                    patch.centroid - domain.bodyCentre, update.wallImpulses[n])
                            } else {
                                domainImpulse += update.wallImpulses[n]
                            }
                        }
                        wallWork += update.wallWork.reduce(0, +)
                        elapsed += step
                        steps += 1
                    }
                    let scattered = try plan.scatter(cells)
                    let after = totalAmount(scattered)
                    let result = Result(
                        cellSize: h, rotation: angle, duration: duration, cfl: cfl,
                        pulseAmplitude: amplitude, pulseEnergy: amplitude * coefficient,
                        requestedPulseEnergy: targetPulseEnergy,
                        initialization: volumeAverage ? "gasAverage" : "cellCentre",
                        maximumQuadratureVolumeResidual: quadratureResidual, steps: steps,
                        groups: cells.count, initialMass: before[0], initialEnergy: before[4],
                        relativeMassChange: after[0] / before[0] - 1,
                        relativeEnergyChange: after[4] / before[4] - 1,
                        bodyImpulse: bodyImpulse, bodyAngularImpulse: angularImpulse,
                        domainImpulse: domainImpulse,
                        momentumBudgetResidual: SIMD3(
                            after[1] - before[1], after[2] - before[2], after[3] - before[3]) + bodyImpulse
                            + domainImpulse,
                        wallWork: wallWork, minimumPressure: cells.map { $0.pressure() }.min()!,
                        maximumSpeed: cells.map { simd_length($0.velocity) }.max()!)
                    results.append(result)
                    try progress(result)
                }
            }
        }
        return results
    }

    /// Compensated diagnostics avoid confusing thousands of cell-sum roundoff errors
    /// with transport drift. Individual flux packets are unchanged.
    private static func totalAmount(_ cells: [FractionalGasTransport.Cell]) -> SIMD8<Double> {
        var total = SIMD8<Double>.zero
        var correction = SIMD8<Double>.zero
        for cell in cells {
            let adjusted = cell.amount - correction
            let next = total + adjusted
            correction = (next - total) - adjusted
            total = next
        }
        return total
    }
}
