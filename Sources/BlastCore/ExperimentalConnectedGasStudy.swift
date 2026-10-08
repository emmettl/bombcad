import simd

/// Static clipped-box geometry linked to connected aggregation and a uniform-gas flux check.
public enum ExperimentalConnectedGasStudy {
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let wetCells: Int
        public let groups: Int
        public let maximumGroupMembers: Int
        public let minimumCellFraction: Double
        public let initialStep: Double
        public let groupedStep: Double
        public let areaResidual: Double
        public let momentResidual: Double
        public let maximumRelativePressureError: Double
        public let relativeMassChange: Double
        public let relativeEnergyChange: Double
        public let momentumChange: SIMD3<Double>
    }
    enum Failure: Error { case inconsistentFace }
    public static func run(progress: (Result) throws -> Void = { _ in }) throws -> [Result] {
        var results: [Result] = []
        for h in [0.2, 0.1] {
            for angle in [0.0, 0.23] {
                let n = Int((2 / h).rounded())
                let geometry = FractionalBoxGeometry(
                    try RigidBoxBody(
                        mass: 2, size: SIMD3(repeating: 0.8),
                        position: SIMD3(1.013, 1.027, 1.041),
                        orientation: simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3)))))
                var cells: [FractionalGasTransport.Cell] = []
                var centres: [SIMD3<Double>] = []
                var patches: [[FractionalBoxGeometry.SurfacePatch]] = []
                var boundaries: [ConnectedGasGroups.Boundary] = []
                func index(_ i: Int, _ j: Int, _ k: Int) -> Int { (k * n + j) * n + i }
                for k in 0..<n {
                    for j in 0..<n {
                        for i in 0..<n {
                            let lower = h * SIMD3<Double>(Double(i), Double(j), Double(k))
                            let fraction = 1 - geometry.solidVolumeFraction(lower: lower, cellSize: h)
                            let volume = fraction < 1e-12 ? 0 : fraction * h * h * h
                            let id = cells.count
                            cells.append(.init(volume: volume, density: 1.225, pressure: 101325))
                            centres.append(lower + SIMD3(repeating: h / 2))
                            let open = geometry.openFacePatches(lower: lower, cellSize: h)
                            patches.append(open)
                            if volume > 0 {
                                for wall in geometry.wallPatches(lower: lower, cellSize: h) {
                                    boundaries.append(
                                        .init(
                                            cell: id, area: wall.area, normal: -wall.normal,
                                            centroid: wall.centroid))
                                }
                                for side in 0..<6 {
                                    let coordinate = [i, j, k][side / 2]
                                    if (side % 2 == 0 && coordinate == 0)
                                        || (side % 2 == 1 && coordinate == n - 1)
                                    {
                                        boundaries.append(
                                            .init(
                                                cell: id, area: open[side].area,
                                                normal: open[side].normal, centroid: open[side].centroid))
                                    }
                                }
                            }
                        }
                    }
                }
                var faces: [ConnectedGasGroups.Face] = []
                for k in 0..<n {
                    for j in 0..<n {
                        for i in 0..<n {
                            let a = index(i, j, k)
                            for axis in 0..<3 {
                                var adjacent = [i, j, k]
                                adjacent[axis] += 1
                                guard adjacent[axis] < n else { continue }
                                let b = index(adjacent[0], adjacent[1], adjacent[2])
                                let left = patches[a][2 * axis + 1]
                                let right = patches[b][2 * axis]
                                guard abs(left.area - right.area) < 1e-10 * h * h else {
                                    throw Failure.inconsistentFace
                                }
                                let area = (left.area + right.area) / 2
                                if area > h * h * 1e-12 {
                                    guard cells[a].volume > 0 && cells[b].volume > 0 else {
                                        throw Failure.inconsistentFace
                                    }
                                    faces.append(
                                        .init(
                                            a: a, b: b, area: area, normal: left.normal,
                                            centroid: (left.centroid + right.centroid) / 2))
                                }
                            }
                        }
                    }
                }
                let plan = try ConnectedGasGroups.build(
                    cells: cells, centres: centres,
                    nominalVolume: h * h * h, faces: faces, boundaries: boundaries)
                func fluxFaces(_ f: [ConnectedGasGroups.Face]) -> [FractionalEulerFlux.Face] {
                    f.map { .init(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area) }
                }
                func walls(_ b: [ConnectedGasGroups.Boundary]) -> [FractionalEulerFlux.Wall] {
                    b.map { .init(cell: $0.cell, normal: $0.normal, area: $0.area) }
                }
                let initialStep = try FractionalEulerFlux.maximumStep(
                    cells, faces: fluxFaces(faces), walls: walls(boundaries))
                let grouped = plan.groups.map(\.cell)
                let step = try FractionalEulerFlux.maximumStep(
                    grouped, faces: fluxFaces(plan.faces), walls: walls(plan.boundaries))
                let updated = try FractionalEulerFlux.advanceWithWalls(
                    grouped, faces: fluxFaces(plan.faces),
                    walls: walls(plan.boundaries), duration: step)
                let scattered = try plan.scatter(updated.cells)
                let before = cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                let after = scattered.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
                let result = Result(
                    cellSize: h, rotation: angle, wetCells: cells.filter { $0.volume > 0 }.count,
                    groups: grouped.count,
                    maximumGroupMembers: plan.groups.map { $0.members.count }.max() ?? 0,
                    minimumCellFraction: cells.filter { $0.volume > 0 }.map { $0.volume / (h * h * h) }
                        .min()!,
                    initialStep: initialStep, groupedStep: step,
                    areaResidual: plan.maximumAreaResidual, momentResidual: plan.maximumMomentResidual,
                    maximumRelativePressureError: scattered.filter { $0.volume > 0 }.map {
                        abs($0.pressure() / 101325 - 1)
                    }.max()!,
                    relativeMassChange: after[0] / before[0] - 1,
                    relativeEnergyChange: after[4] / before[4] - 1,
                    momentumChange: SIMD3(after[1] - before[1], after[2] - before[2], after[3] - before[3]))
                results.append(result)
                try progress(result)
            }
        }
        return results
    }
}
