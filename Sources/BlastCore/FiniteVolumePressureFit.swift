import Numerics
import simd

/// Mean-preserving scalar reconstruction from volume averages. Experimental conserved
/// reconstruction reuses its geometry factors across the five Euler components.
/// Quadratic basis functions subtract their local volume mean, so the fitted polynomial
/// retains the supplied average even on asymmetric merged gas volumes.
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
        Stencil(cell: cell, neighbours: neighbours, scale: scale, volumeAware: volumeAware).fit(
            average: cell.average, neighbourAverages: neighbours.map(\.average), quadratic: quadratic)
    }

    /// Geometry is factored once and reused for all conserved components of a gas group.
    struct Stencil {
        private let cell: Sample
        private let scale: Double
        private let volumeAware: Bool
        private let weights: [Double]
        private let quadraticQR: PivotedQR?
        private let linearQR: PivotedQR?

        init(cell: Sample, neighbours: [Sample], scale: Double, volumeAware: Bool) {
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
            self.cell = cell
            self.scale = scale
            self.volumeAware = volumeAware
            let distanceWeights = neighbours.map { scale / simd_distance($0.centre, cell.centre) }
            weights = distanceWeights
            let weighted = rows.enumerated().map { n, row in row.map { $0 * distanceWeights[n] } }
            quadraticQR = try? PivotedQR(rows: weighted, relativeRankTolerance: 1e-10)
            linearQR = try? PivotedQR(
                rows: weighted.map { Array($0.prefix(3)) }, relativeRankTolerance: 1e-10)
        }

        func fit(average: Double, neighbourAverages: [Double], quadratic: Bool) -> Fit {
            precondition(neighbourAverages.count == weights.count)
            let rhs = zip(neighbourAverages, weights).map { ($0.0 - average) * $0.1 }
            let coefficients =
                (quadratic ? (try? quadraticQR?.solve(rhs: rhs).coefficients) : nil)
                ?? (try? linearQR?.solve(rhs: rhs).coefficients) ?? []
            return .init(
                cell: .init(centre: cell.centre, covariance: cell.covariance, average: average),
                scale: scale, coefficients: coefficients, volumeAware: volumeAware,
                lower: neighbourAverages.reduce(average, min), upper: neighbourAverages.reduce(average, max),
                stencilSize: neighbourAverages.count)
        }
    }

}
