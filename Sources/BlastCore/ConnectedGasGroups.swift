import simd

/// Static connected control-volume aggregation. Exterior patches retain their original
/// normals and centroids; evolving geometry and angular-momentum transport remain separate.
enum ConnectedGasGroups {
    enum Failure: Error { case invalidGeometry, unmergeable, groupLimit, invalidState }
    struct Face {
        let a: Int
        let b: Int
        let area: Double
        let normal: SIMD3<Double>  // From a to b.
        let centroid: SIMD3<Double>
    }
    struct SurfaceSample {
        let point: SIMD3<Double>
        let area: Double
    }
    struct Boundary {
        let cell: Int
        let area: Double
        let normal: SIMD3<Double>  // Outward from gas.
        let centroid: SIMD3<Double>
        let owner: Int
        let samples: [SurfaceSample]?
        init(
            cell: Int, area: Double, normal: SIMD3<Double>, centroid: SIMD3<Double>, owner: Int = 0,
            samples: [SurfaceSample]? = nil
        ) {
            self.cell = cell
            self.area = area
            self.normal = normal
            self.centroid = centroid
            self.owner = owner
            self.samples = samples
        }
    }
    /// Expand pressure evaluation locations while preserving ownership and paired gas loads.
    /// Call after build has checked area, first moment and coplanarity of supplied samples.
    static func sampledBoundaries(_ boundaries: [Boundary]) -> [Boundary] {
        boundaries.flatMap { boundary in
            guard let samples = boundary.samples else { return [boundary] }
            return samples.map {
                .init(
                    cell: boundary.cell, area: $0.area, normal: boundary.normal,
                    centroid: $0.point, owner: boundary.owner)
            }
        }
    }
    struct Group {
        let members: [Int]
        let cell: FractionalGasTransport.Cell
        let centre: SIMD3<Double>
    }
    struct Plan {
        let groups: [Group]
        let cellToGroup: [Int]  // -1 for dry cells.
        let faces: [Face]
        let boundaries: [Boundary]
        let memberVolumes: [Double]
        let maximumAreaResidual: Double
        let maximumMomentResidual: Double

        /// Constant-state splitting at the original geometry. A largest-volume member
        /// receives the packet remainder, avoiding roundoff amplification in tiny members.
        func scatter(_ updated: [FractionalGasTransport.Cell]) throws -> [FractionalGasTransport.Cell] {
            guard updated.count == groups.count else { throw Failure.invalidState }
            _ = try FractionalGasTransport.advance(updated, newVolumes: updated.map(\.volume), transfers: [])
            var amounts = [SIMD8<Double>](repeating: .zero, count: memberVolumes.count)
            for n in groups.indices {
                let volume = groups[n].cell.volume
                guard abs(updated[n].volume - volume) <= 1e-12 * volume else { throw Failure.invalidState }
                var remaining = updated[n].amount
                let remainderMember = groups[n].members.max { memberVolumes[$0] < memberVolumes[$1] }!
                let order = groups[n].members.filter { $0 != remainderMember } + [remainderMember]
                for member in order {
                    let packet =
                        member == remainderMember
                        ? remaining
                        : updated[n].amount * (memberVolumes[member] / volume)
                    amounts[member] = packet
                    remaining -= packet
                }
            }
            let cells = memberVolumes.indices.map {
                FractionalGasTransport.Cell(volume: memberVolumes[$0], amount: amounts[$0])
            }
            return try FractionalGasTransport.advance(cells, newVolumes: memberVolumes, transfers: [])
        }
    }

    static func build(
        cells: [FractionalGasTransport.Cell], centres: [SIMD3<Double>], nominalVolume: Double,
        faces: [Face], boundaries: [Boundary], minimumFraction: Double = 0.25,
        maximumMembers: Int = 64, tolerance: Double = 1e-8
    ) throws -> Plan {
        guard !cells.isEmpty, centres.count == cells.count, nominalVolume.isFinite && nominalVolume > 0,
            minimumFraction.isFinite && minimumFraction > 0 && minimumFraction <= 1,
            maximumMembers > 0, tolerance.isFinite && tolerance > 0
        else { throw Failure.invalidGeometry }
        guard centres.allSatisfy({ point in (0..<3).allSatisfy { point[$0].isFinite } }) else {
            throw Failure.invalidGeometry
        }
        _ = try FractionalGasTransport.advance(cells, newVolumes: cells.map(\.volume), transfers: [])
        var areaVectors = [SIMD3<Double>](repeating: .zero, count: cells.count)
        var areas = [Double](repeating: 0, count: cells.count)
        var moments = [simd_double3x3](
            repeating: simd_double3x3(columns: (.zero, .zero, .zero)), count: cells.count)
        var adjacency = [[Int]](repeating: [], count: cells.count)
        func patch(_ cell: Int, _ area: Double, _ normal: SIMD3<Double>, _ centroid: SIMD3<Double>) throws {
            guard cells.indices.contains(cell), area.isFinite && area >= 0,
                (0..<3).allSatisfy({ normal[$0].isFinite && centroid[$0].isFinite }),
                abs(simd_length_squared(normal) - 1) < 1e-12,
                area == 0 || cells[cell].volume > 0
            else { throw Failure.invalidGeometry }
            let vector = area * normal
            areaVectors[cell] += vector
            areas[cell] += area
            let r = centroid - centres[cell]
            moments[cell] += simd_double3x3(columns: (r * vector.x, r * vector.y, r * vector.z))
        }
        for (n, face) in faces.enumerated() {
            guard face.a != face.b else { throw Failure.invalidGeometry }
            try patch(face.a, face.area, face.normal, face.centroid)
            try patch(face.b, face.area, -face.normal, face.centroid)
            if face.area > 0 {
                adjacency[face.a].append(n)
                adjacency[face.b].append(n)
            }
        }
        for boundary in boundaries {
            try patch(boundary.cell, boundary.area, boundary.normal, boundary.centroid)
            if let samples = boundary.samples {
                let length = pow(nominalVolume, 1.0 / 3)
                var area = 0.0
                var moment = SIMD3<Double>.zero
                for sample in samples {
                    guard sample.area.isFinite && sample.area > 0,
                        (0..<3).allSatisfy({ sample.point[$0].isFinite }),
                        abs(simd_dot(sample.point - boundary.centroid, boundary.normal)) <= tolerance * length
                    else { throw Failure.invalidGeometry }
                    area += sample.area
                    moment += sample.area * (sample.point - boundary.centroid)
                }
                guard boundary.area == 0 || !samples.isEmpty,
                    abs(area - boundary.area) <= tolerance * max(boundary.area, 1e-300),
                    simd_length(moment) <= tolerance * max(boundary.area, 1e-300) * length
                else { throw Failure.invalidGeometry }
            }
        }
        var areaResidual = 0.0
        var momentResidual = 0.0
        for n in cells.indices {
            let a = simd_length(areaVectors[n]) / max(areas[n], 1e-300)
            let difference = moments[n] - matrix_identity_double3x3 * cells[n].volume
            let m =
                sqrt((0..<3).reduce(0.0) { $0 + simd_length_squared(difference[$1]) })
                / max(nominalVolume, cells[n].volume)
            guard a <= tolerance && m <= tolerance else { throw Failure.invalidGeometry }
            areaResidual = max(areaResidual, a)
            momentResidual = max(momentResidual, m)
        }
        var parent = Array(cells.indices)
        var members = cells.indices.map { cells[$0].volume > 0 ? [$0] : [] }
        var volumes = cells.map(\.volume)
        func root(_ n: Int) -> Int {
            var r = n
            while parent[r] != r { r = parent[r] }
            return r
        }
        while let small = cells.indices.filter({
            !members[$0].isEmpty && volumes[$0] < minimumFraction * nominalVolume
        })
        .min(by: { volumes[$0] == volumes[$1] ? $0 < $1 : volumes[$0] < volumes[$1] }) {
            var shared: [Int: Double] = [:]
            for member in members[small] {
                for index in adjacency[member] {
                    let face = faces[index]
                    let other = root(face.a == member ? face.b : face.a)
                    if other != small { shared[other, default: 0] += face.area }
                }
            }
            guard !shared.isEmpty else { throw Failure.unmergeable }
            let available = shared.keys.filter { members[small].count + members[$0].count <= maximumMembers }
            guard
                let other = available.sorted(by: {
                    if shared[$0]! != shared[$1]! { return shared[$0]! > shared[$1]! }
                    if volumes[$0] != volumes[$1] { return volumes[$0] > volumes[$1] }
                    return $0 < $1
                }).first
            else { throw Failure.groupLimit }
            let keep = min(small, other)
            let remove = max(small, other)
            parent[remove] = keep
            members[keep] = (members[keep] + members[remove]).sorted()
            members[remove] = []
            volumes[keep] += volumes[remove]
            volumes[remove] = 0
        }
        let roots = cells.indices.filter { !members[$0].isEmpty }
        let lookup = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1, $0) })
        let mapping = cells.indices.map { cells[$0].volume > 0 ? lookup[root($0)]! : -1 }
        let groups = roots.map { n in
            let amount = members[n].reduce(SIMD8<Double>.zero) { $0 + cells[$1].amount }
            let centre =
                members[n].reduce(SIMD3<Double>.zero) { $0 + cells[$1].volume * centres[$1] } / volumes[n]
            return Group(members: members[n], cell: .init(volume: volumes[n], amount: amount), centre: centre)
        }
        _ = try FractionalGasTransport.advance(
            groups.map(\.cell), newVolumes: groups.map { $0.cell.volume }, transfers: [])
        let external = faces.compactMap { face -> Face? in
            guard face.area > 0 && mapping[face.a] != mapping[face.b] else { return nil }
            return Face(
                a: mapping[face.a], b: mapping[face.b], area: face.area,
                normal: face.normal, centroid: face.centroid)
        }
        let outer = boundaries.filter { $0.area > 0 }.map {
            Boundary(
                cell: mapping[$0.cell], area: $0.area, normal: $0.normal, centroid: $0.centroid,
                owner: $0.owner, samples: $0.samples)
        }
        var groupVectors = [SIMD3<Double>](repeating: .zero, count: groups.count)
        var groupAreas = [Double](repeating: 0, count: groups.count)
        var groupMoments = [simd_double3x3](
            repeating: simd_double3x3(columns: (.zero, .zero, .zero)), count: groups.count)
        func groupPatch(_ n: Int, _ area: Double, _ normal: SIMD3<Double>, _ centroid: SIMD3<Double>) {
            let vector = area * normal
            let r = centroid - groups[n].centre
            groupVectors[n] += vector
            groupAreas[n] += area
            groupMoments[n] += simd_double3x3(columns: (r * vector.x, r * vector.y, r * vector.z))
        }
        for face in external {
            groupPatch(face.a, face.area, face.normal, face.centroid)
            groupPatch(face.b, face.area, -face.normal, face.centroid)
        }
        for boundary in outer { groupPatch(boundary.cell, boundary.area, boundary.normal, boundary.centroid) }
        for n in groups.indices {
            let a = simd_length(groupVectors[n]) / max(groupAreas[n], 1e-300)
            let difference = groupMoments[n] - matrix_identity_double3x3 * groups[n].cell.volume
            let m =
                sqrt((0..<3).reduce(0.0) { $0 + simd_length_squared(difference[$1]) })
                / max(nominalVolume, groups[n].cell.volume)
            guard a <= tolerance && m <= tolerance else { throw Failure.invalidGeometry }
            areaResidual = max(areaResidual, a)
            momentResidual = max(momentResidual, m)
        }
        return Plan(
            groups: groups, cellToGroup: mapping, faces: external, boundaries: outer,
            memberVolumes: cells.map(\.volume), maximumAreaResidual: areaResidual,
            maximumMomentResidual: momentResidual)
    }
}
