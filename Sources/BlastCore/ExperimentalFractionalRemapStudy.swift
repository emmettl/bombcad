import simd

/// Geometry-linked conservative remapping, not numerical air fluxes or pressure evolution.
public enum ExperimentalFractionalRemapStudy {
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let cellCount: Int
        public let transferCount: Int
        public let maximumVolumeResidual: Double
        public let maximumOutflowFraction: Double
        public let relativeMassChange: Double
        public let momentumChange: SIMD3<Double>
        public let relativeEnergyChange: Double
        public let maximumRelativePressureError: Double
    }
    public static func run(cellSizes: [Double] = [0.2, 0.1, 0.05]) throws -> [Result] {
        try cellSizes.map { h in
            let start = try RigidBoxBody(mass: 2, size: SIMD3(repeating: 0.8), position: SIMD3(2.095, 2, 2))
            let middle = try RigidBoxBody(
                mass: 2, size: start.size, position: start.position + SIMD3(0.005, 0, 0))
            let end = try RigidBoxBody(
                mass: 2, size: start.size, position: start.position + SIMD3(0.01, 0, 0))
            let geometries = [start, middle, end].map(FractionalBoxGeometry.init)
            let low = (start.corners + end.corners).reduce(SIMD3<Double>(repeating: .infinity), simd_min)
            let high = (start.corners + end.corners).reduce(SIMD3<Double>(repeating: -.infinity), simd_max)
            let first = SIMD3<Int>((low / h).rounded(.down)) &- 2
            let last = SIMD3<Int>((high / h).rounded(.up)) &+ 2
            var coordinates: [SIMD3<Int>] = []
            var old: [Double] = []
            var new: [Double] = []
            var apertures: [[Double]] = []
            func fraction(_ value: Double) -> Double {
                // Canonicalise only fractions within geometric roundoff of a dry/full cell.
                value < 1e-12 ? 0 : value > 1 - 1e-12 ? 1 : value
            }
            for k in first.z...last.z {
                for j in first.y...last.y {
                    for i in first.x...last.x {
                        let p = SIMD3(i, j, k)
                        let lower = SIMD3<Double>(p) * h
                        coordinates.append(p)
                        old.append(
                            fraction(1 - geometries[0].solidVolumeFraction(lower: lower, cellSize: h)) * h * h
                                * h)
                        new.append(
                            fraction(1 - geometries[2].solidVolumeFraction(lower: lower, cellSize: h)) * h * h
                                * h)
                        let faces = geometries.map { $0.openFaceFractions(lower: lower, cellSize: h) }
                        apertures.append((0..<6).map { side in faces.map { $0[side] }.max()! * h * h })
                    }
                }
            }
            let lookup = Dictionary(uniqueKeysWithValues: coordinates.enumerated().map { ($1, $0) })
            var faces: [FractionalVolumeRemap.Face] = []
            for n in coordinates.indices {
                for axis in 0..<3 {
                    var adjacent = coordinates[n]
                    adjacent[axis] += 1
                    guard let other = lookup[adjacent] else { continue }
                    let area = min(apertures[n][2 * axis + 1], apertures[other][2 * axis])
                    if area > h * h * 1e-12 { faces.append(.init(a: n, b: other, openArea: area)) }
                }
            }
            let plan = try FractionalVolumeRemap.build(
                old: old, new: new, faces: faces, relativeTolerance: 1e-8)
            let velocity = SIMD3<Double>(1, 2, 3)
            let cells = old.map {
                FractionalGasTransport.Cell(volume: $0, density: 1.225, velocity: velocity, pressure: 101325)
            }
            let updated = try FractionalGasTransport.advance(
                cells, newVolumes: new, transfers: plan.transfers)
            let before = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let after = updated.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
            let error = updated.filter { $0.volume > 0 }.map { abs($0.pressure() / 101325 - 1) }.max() ?? 0
            return Result(
                cellSize: h, cellCount: cells.count, transferCount: plan.transfers.count,
                maximumVolumeResidual: plan.maximumVolumeResidual,
                maximumOutflowFraction: plan.maximumOutflowFraction,
                relativeMassChange: after[0] / before[0] - 1,
                momentumChange: SIMD3(after[1] - before[1], after[2] - before[2], after[3] - before[3]),
                relativeEnergyChange: after[4] / before[4] - 1, maximumRelativePressureError: error)
        }
    }
}
