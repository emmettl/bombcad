import simd

/// Diagnostic scalar reconstruction from volume averages. No numerical gas stage uses
/// this fit. Quadratic basis functions subtract their local volume mean, so the fitted
/// polynomial retains the supplied average even on asymmetric merged gas volumes.
enum FiniteVolumePressureFit {
    struct Sample {
        let centre: SIMD3<Double>
        let covariance: simd_double3x3
        let average: Double
    }
    struct Fit {
        let cell: Sample
        let scale: Double
        let coefficients: [Double]
        let volumeAware: Bool
        let lower: Double
        let upper: Double
        let stencilSize: Int

        var degree: Int { coefficients.count == 9 ? 2 : (coefficients.count == 3 ? 1 : 0) }
        func value(at point: SIMD3<Double>) -> Double {
            let covariance = volumeAware ? (-1 / (scale * scale)) * cell.covariance : zero
            let terms = basis((point - cell.centre) / scale, covariance: covariance)
            return cell.average + zip(coefficients, terms).reduce(0) { $0 + $1.0 * $1.1 }
        }

        /// One factor scales every mean-free polynomial term. This bounds the supplied
        /// control points and preserves the volume average; it is not a bound everywhere
        /// between those points. No pointwise clamp changes the polynomial's integral.
        func limited(at points: [SIMD3<Double>]) -> BoundedFit {
            precondition(volumeAware)
            var factor = 1.0
            for point in points {
                let delta = value(at: point) - cell.average
                if delta > 0 { factor = min(factor, (upper - cell.average) / delta) }
                if delta < 0 { factor = min(factor, (lower - cell.average) / delta) }
            }
            return .init(fit: self, factor: max(0, min(1, factor)))
        }
    }
    struct BoundedFit {
        let fit: Fit
        let factor: Double

        func value(at point: SIMD3<Double>) -> Double {
            fit.cell.average + factor * (fit.value(at: point) - fit.cell.average)
        }
    }
    static let zero = simd_double3x3(columns: (.zero, .zero, .zero))

    // Coefficients are g*h, Hxx*h², Hyy*h², Hzz*h², Hxy*h², Hxz*h², Hyz*h².
    private static func basis(_ d: SIMD3<Double>, covariance c: simd_double3x3) -> [Double] {
        [
            d.x, d.y, d.z, (d.x * d.x + c[0][0]) / 2,
            (d.y * d.y + c[1][1]) / 2, (d.z * d.z + c[2][2]) / 2,
            d.x * d.y + c[0][1], d.x * d.z + c[0][2], d.y * d.z + c[1][2],
        ]
    }

    static func fit(
        cell: Sample, neighbours: [Sample], scale: Double, quadratic: Bool, volumeAware: Bool
    ) -> Fit {
        precondition(scale.isFinite && scale > 0)
        let rows = neighbours.map { neighbour -> [Double] in
            let d = (neighbour.centre - cell.centre) / scale
            let difference = simd_double3x3(
                columns: (
                    neighbour.covariance[0] - cell.covariance[0],
                    neighbour.covariance[1] - cell.covariance[1],
                    neighbour.covariance[2] - cell.covariance[2]
                ))
            let covariance = volumeAware ? (1 / (scale * scale)) * difference : zero
            return basis(d, covariance: covariance)
        }
        // Identical distance weights and neighbour sets for all diagnostic modes.
        let weights = neighbours.map { scale / simd_distance($0.centre, cell.centre) }
        let rhs = neighbours.map { $0.average - cell.average }
        func solve(_ count: Int) -> [Double]? {
            leastSquares(
                rows: rows.enumerated().map { n, row in row.prefix(count).map { $0 * weights[n] } },
                rhs: zip(rhs, weights).map { $0.0 * $0.1 })
        }
        let coefficients = (quadratic ? solve(9) : nil) ?? solve(3) ?? []
        return .init(
            cell: cell, scale: scale, coefficients: coefficients, volumeAware: volumeAware,
            lower: neighbours.reduce(cell.average) { min($0, $1.average) },
            upper: neighbours.reduce(cell.average) { max($0, $1.average) },
            stencilSize: neighbours.count)
    }

    /// Column-pivoted modified Gram-Schmidt with reorthogonalization. Scaling coordinates
    /// by h avoids mixed physical units; rank failure falls back to linear/constant fits.
    private static func leastSquares(rows: [[Double]], rhs: [Double]) -> [Double]? {
        guard let width = rows.first?.count, rows.count >= width else { return nil }
        var columns = (0..<width).map { j in rows.map { $0[j] } }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }
        let initialNorm = columns.map { sqrt(dot($0, $0)) }.max()!
        guard initialNorm.isFinite && initialNorm > 0 else { return nil }
        var permutation = Array(0..<width)
        var upper = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var projected = [Double](repeating: 0, count: width)
        for k in 0..<width {
            let pivot = (k..<width).max { dot(columns[$0], columns[$0]) < dot(columns[$1], columns[$1]) }!
            columns.swapAt(k, pivot)
            permutation.swapAt(k, pivot)
            for j in 0..<k { upper[j].swapAt(k, pivot) }
            let norm = sqrt(dot(columns[k], columns[k]))
            guard norm.isFinite && norm > 1e-10 * initialNorm else { return nil }
            upper[k][k] = norm
            let q = columns[k].map { $0 / norm }
            projected[k] = dot(q, rhs)
            for j in (k + 1)..<width {
                for _ in 0..<2 {
                    let projection = dot(q, columns[j])
                    upper[k][j] += projection
                    columns[j] = zip(columns[j], q).map { $0.0 - projection * $0.1 }
                }
            }
        }
        var solution = [Double](repeating: 0, count: width)
        for k in (0..<width).reversed() {
            let known = ((k + 1)..<width).reduce(0) { $0 + upper[k][$1] * solution[$1] }
            solution[k] = (projected[k] - known) / upper[k][k]
        }
        guard solution.allSatisfy(\.isFinite) else { return nil }
        var ordered = solution
        for k in 0..<width { ordered[permutation[k]] = solution[k] }
        return ordered
    }
}
