import simd

/// Positive-volume reconstruction and stationary time stepping. Moving drivers reuse traces
/// with their own volume bookkeeping; the SSPRK2 advance below remains stationary.
/// Weighted least squares reconstructs primitive
/// variables; one-ring extrema limit every supplied face and wall trace. Rank-deficient
/// stencils retain constant states. This does not claim angular-momentum conservation.
enum LimitedGroupedGasFlux {
    enum Failure: Error {
        case invalidGeometry
        case stageLimit(Double)
    }
    struct PressureReconstruction {
        let value: Double
        let gradient: SIMD3<Double>  // Unbounded least-squares fit; diagnostic only.
        let factor: Double
        let lower: Double
        let upper: Double
        let rankDeficient: Bool
    }
    struct Traces {
        let faces: [FractionalEulerFlux.Face]
        let walls: [FractionalEulerFlux.Wall]
        var pressureDiagnostics: [PressureReconstruction]? = nil
    }
    struct Geometry {
        let centres: [SIMD3<Double>]
        let faces: [ConnectedGasGroups.Face]
        let boundaries: [ConnectedGasGroups.Boundary]
        private let neighbours: [[(Int, Double)]]
        private let offsets: [[SIMD3<Double>]]
        private let inverses: [simd_double3x3?]

        init(
            centres: [SIMD3<Double>], faces: [ConnectedGasGroups.Face],
            boundaries: [ConnectedGasGroups.Boundary]
        ) throws {
            guard !centres.isEmpty && centres.allSatisfy({ p in (0..<3).allSatisfy { p[$0].isFinite } })
            else {
                throw Failure.invalidGeometry
            }
            var neighbours = [[(Int, Double)]](repeating: [], count: centres.count)
            var offsets = [[SIMD3<Double>]](repeating: [], count: centres.count)
            let zero = simd_double3x3(columns: (.zero, .zero, .zero))
            var matrices = [simd_double3x3](repeating: zero, count: centres.count)
            for face in faces {
                guard centres.indices.contains(face.a), centres.indices.contains(face.b), face.a != face.b,
                    face.area.isFinite && face.area > 0,
                    (0..<3).allSatisfy({ face.centroid[$0].isFinite })
                else { throw Failure.invalidGeometry }
                let d = centres[face.b] - centres[face.a]
                guard simd_length_squared(d) > 0 else { throw Failure.invalidGeometry }
                let weight = face.area / simd_length_squared(d)
                let matrix = weight * simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
                for (a, b) in [(face.a, face.b), (face.b, face.a)] {
                    neighbours[a].append((b, weight))
                    matrices[a] += matrix
                    offsets[a].append(face.centroid - centres[a])
                }
            }
            for wall in boundaries {
                guard centres.indices.contains(wall.cell), wall.area.isFinite && wall.area >= 0,
                    (0..<3).allSatisfy({ wall.centroid[$0].isFinite })
                else { throw Failure.invalidGeometry }
                if wall.area > 0 { offsets[wall.cell].append(wall.centroid - centres[wall.cell]) }
            }
            self.centres = centres
            self.faces = faces
            self.boundaries = boundaries
            self.neighbours = neighbours
            self.offsets = offsets
            self.inverses = matrices.map { matrix in
                let scale = matrix[0][0] + matrix[1][1] + matrix[2][2]
                guard scale.isFinite && scale > 0, simd_determinant((1 / scale) * matrix) > 1e-10 else {
                    return nil
                }
                return simd_inverse(matrix)
            }
        }

        func traces(
            _ cells: [FractionalGasTransport.Cell], recordPressureDiagnostics: Bool = false
        ) throws -> Traces {
            guard cells.count == centres.count && cells.allSatisfy({ $0.volume > 0 }) else {
                throw Failure.invalidGeometry
            }
            _ = try FractionalGasTransport.advance(cells, newVolumes: cells.map(\.volume), transfers: [])
            let states = cells.map { cell in
                SIMD8(
                    cell.amount[0] / cell.volume, cell.velocity.x, cell.velocity.y, cell.velocity.z,
                    cell.pressure(), 0, 0, 0)
            }
            var gradients = [[SIMD3<Double>]](
                repeating: [.zero, .zero, .zero, .zero, .zero], count: cells.count)
            var diagnostics: [PressureReconstruction]? =
                recordPressureDiagnostics
                ? states.indices.map { n in
                    .init(
                        value: states[n][4], gradient: .zero, factor: 0,
                        lower: states[n][4], upper: states[n][4], rankDeficient: inverses[n] == nil)
                } : nil
            var lower = states
            var upper = states
            for n in cells.indices {
                guard let inverse = inverses[n] else { continue }
                for component in 0..<5 {
                    let value = states[n][component]
                    var rhs = SIMD3<Double>.zero
                    var low = value
                    var high = value
                    for (other, weight) in neighbours[n] {
                        let next = states[other][component]
                        rhs += weight * (next - value) * (centres[other] - centres[n])
                        low = min(low, next)
                        high = max(high, next)
                    }
                    lower[n][component] = low
                    upper[n][component] = high
                    let gradient = inverse * rhs
                    var factor = 1.0
                    for offset in offsets[n] {
                        let delta = simd_dot(gradient, offset)
                        if delta > 0 { factor = min(factor, (high - value) / delta) }
                        if delta < 0 { factor = min(factor, (low - value) / delta) }
                    }
                    gradients[n][component] = max(0, factor) * gradient
                    if component == 4 && recordPressureDiagnostics {
                        diagnostics![n] = .init(
                            value: value, gradient: gradient, factor: max(0, factor),
                            lower: low, upper: high, rankDeficient: false)
                    }
                }
            }
            func trace(_ n: Int, _ point: SIMD3<Double>) -> FractionalGasTransport.Cell {
                var state = states[n]
                for c in 0..<5 {  // Clamp trace roundoff to the same stencil extrema used by the limiter.
                    state[c] = min(
                        upper[n][c],
                        max(
                            lower[n][c],
                            state[c] + simd_dot(gradients[n][c], point - centres[n])))
                }
                return .init(
                    volume: 1, density: state[0], velocity: SIMD3(state[1], state[2], state[3]),
                    pressure: state[4])
            }
            return Traces(
                faces: faces.map {
                    .init(
                        a: $0.a, b: $0.b, normal: $0.normal, area: $0.area,
                        leftState: trace($0.a, $0.centroid), rightState: trace($0.b, $0.centroid))
                },
                walls: boundaries.map {
                    .init(cell: $0.cell, normal: $0.normal, area: $0.area, state: trace($0.cell, $0.centroid))
                }, pressureDiagnostics: diagnostics)
        }

        /// SSPRK2 averages extensive gas updates and the matching wall impulse/work.
        /// The caller must retry a shorter step if the second stage's CFL shrinks.
        func advance(
            _ old: [FractionalGasTransport.Cell], traces firstTraces: Traces,
            duration: Double, cfl: Double,
            reconstruct: (([FractionalGasTransport.Cell]) throws -> Traces)? = nil
        ) throws -> FractionalEulerFlux.Result {
            let first = try FractionalEulerFlux.advanceWithWalls(
                old, faces: firstTraces.faces,
                walls: firstTraces.walls, duration: duration, cfl: cfl)
            let secondTraces = try reconstruct?(first.cells) ?? traces(first.cells)
            let limit = try FractionalEulerFlux.maximumStep(
                first.cells, faces: secondTraces.faces,
                walls: secondTraces.walls, cfl: cfl)
            guard duration <= limit else { throw Failure.stageLimit(limit) }
            let second = try FractionalEulerFlux.advanceWithWalls(
                first.cells, faces: secondTraces.faces,
                walls: secondTraces.walls, duration: duration, cfl: cfl)
            let cells = old.indices.map {
                FractionalGasTransport.Cell(
                    volume: old[$0].volume, amount: (old[$0].amount + second.cells[$0].amount) / 2)
            }
            let checked = try FractionalGasTransport.advance(
                cells, newVolumes: cells.map(\.volume), transfers: [])
            return .init(
                cells: checked,
                wallImpulses: boundaries.indices.map {
                    (first.wallImpulses[$0] + second.wallImpulses[$0]) / 2
                },
                wallWork: boundaries.indices.map { (first.wallWork[$0] + second.wallWork[$0]) / 2 })
        }
    }
}
