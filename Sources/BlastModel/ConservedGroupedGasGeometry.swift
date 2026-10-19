import simd

/// Endpoint volume moments and positive control nodes for an experimental grouped fit.
/// Old and final shapes are distinct; neither substitutes interval-mean volume moments.
struct ConservedGroupedGasGeometry {
    let centres: [SIMD3<Double>]
    let covariance: [simd_double3x3]
    let volumePoints: [[SIMD3<Double>]]
    let scale: Double

    static func build(
        plan: MovingConnectedGasGroups.Plan, shape: FractionalBoxGeometry, cellSize h: Double,
        final: Bool
    ) throws -> Self {
        guard h.isFinite && h > 0 else { throw ConservedGasReconstruction.Failure.invalidGeometry }
        guard let centres = final ? plan.finalCentres : plan.oldCentres else {
            throw ConservedGasReconstruction.Failure.invalidGeometry
        }
        let count = Int((2 / h).rounded())
        guard Double(count) * Double(count) * Double(count) == Double(plan.memberFinalVolumes.count) else {
            throw ConservedGasReconstruction.Failure.invalidGeometry
        }
        let volumes = final ? plan.finalVolumes : plan.cells.map(\.volume)
        var covariances: [simd_double3x3] = []
        var controls: [[SIMD3<Double>]] = []
        for group in plan.members.indices {
            var volume = 0.0
            var first = SIMD3<Double>.zero
            var second = FiniteVolumePressureFit.zero
            var points: [SIMD3<Double>] = []
            for member in plan.members[group] {
                let lower =
                    h
                    * SIMD3<Double>(
                        Double(member % count), Double((member / count) % count),
                        Double(member / (count * count)))
                for node in shape.gasQuadrature(lower: lower, cellSize: h) {
                    let offset = node.point - centres[group]
                    volume += node.weight
                    first += node.weight * offset
                    second +=
                        node.weight
                        * simd_double3x3(columns: (offset * offset.x, offset * offset.y, offset * offset.z))
                    points.append(node.point)
                }
            }
            guard volume > 0 && volume.isFinite,
                abs(volume - volumes[group]) < 1e-8 * h * h * h * Double(plan.members[group].count),
                simd_length(first) < 1e-8 * volume * h
            else { throw ConservedGasReconstruction.Failure.invalidGeometry }
            covariances.append((1 / volume) * second)
            controls.append(points)
        }
        return .init(centres: centres, covariance: covariances, volumePoints: controls, scale: h)
    }

    func traces(
        _ cells: [FractionalGasTransport.Cell], centres supplied: [SIMD3<Double>],
        faces: [ConnectedGasGroups.Face], walls: [ConnectedGasGroups.Boundary]
    ) throws -> LimitedGroupedGasFlux.Traces {
        guard supplied.count == cells.count, cells.count >= centres.count,
            covariance.count == centres.count, volumePoints.count == centres.count,
            zip(supplied, centres).allSatisfy({ simd_distance($0, $1) < 1e-10 * scale })
        else { throw ConservedGasReconstruction.Failure.invalidGeometry }
        guard
            faces.allSatisfy({ f in
                cells.indices.contains(f.a) && cells.indices.contains(f.b) && f.a != f.b
                    && f.area.isFinite && f.area > 0 && (0..<3).allSatisfy { f.centroid[$0].isFinite }
            }),
            walls.allSatisfy({ w in
                centres.indices.contains(w.cell) && w.area.isFinite && w.area >= 0
                    && (0..<3).allSatisfy { w.centroid[$0].isFinite }
            })
        else { throw ConservedGasReconstruction.Failure.invalidGeometry }
        var adjacency = [Set<Int>](repeating: [], count: cells.count)
        var controls = volumePoints
        for face in faces {
            adjacency[face.a].insert(face.b)
            adjacency[face.b].insert(face.a)
            for group in [face.a, face.b] where group < centres.count {
                controls[group].append(face.centroid)
            }
        }
        for wall in walls { controls[wall.cell].append(wall.centroid) }
        let samples = cells.indices.map { n in
            ConservedGasReconstruction.Sample(
                centre: supplied[n],
                covariance: n < centres.count ? covariance[n] : FiniteVolumePressureFit.zero,
                density: cells[n].amount / cells[n].volume)
        }
        let fits = try centres.indices.map { n in
            var neighbours = adjacency[n]
            for other in adjacency[n] { neighbours.formUnion(adjacency[other]) }
            neighbours.remove(n)
            return try ConservedGasReconstruction.fit(
                cell: samples[n], neighbours: neighbours.sorted().map { samples[$0] },
                controls: controls[n], scale: scale)
        }
        func trace(_ n: Int, _ point: SIMD3<Double>) -> FractionalGasTransport.Cell {
            n < fits.count ? fits[n].state(at: point) : cells[n]
        }
        return .init(
            faces: faces.map {
                .init(
                    a: $0.a, b: $0.b, normal: $0.normal, area: $0.area,
                    leftState: trace($0.a, $0.centroid), rightState: trace($0.b, $0.centroid))
            },
            walls: walls.map {
                .init(cell: $0.cell, normal: $0.normal, area: $0.area, state: trace($0.cell, $0.centroid))
            })
    }
}
