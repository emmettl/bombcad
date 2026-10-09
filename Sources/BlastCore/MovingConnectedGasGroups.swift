import simd

/// Interval-local aggregation of time-averaged geometry. Active members include cells
/// wet only during the interval; each group needs positive old AND final gas capacity.
/// The static builder validates mean area/first-moment closure, using disposable unit
/// states solely to describe geometric support. Actual group inventories come only from
/// old gas, never from those geometric placeholders or from newly exposed-cell guesses.
enum MovingConnectedGasGroups {
    enum Failure: Error { case invalidGeometry, unsupportedGroup, invalidState }
    struct Boundary {
        let geometry: ConnectedGasGroups.Boundary  // Time-averaged area and area-weighted centroid.
        let meanTime: Double  // Area-weighted time; used for torque about a translating COM.
    }
    struct Plan {
        let members: [[Int]]
        let cellToGroup: [Int]
        let cells: [FractionalGasTransport.Cell]  // Extensive OLD inventories.
        let finalVolumes: [Double]
        let memberFinalVolumes: [Double]
        let faces: [ConnectedGasGroups.Face]
        let boundaries: [Boundary]
        let duration: Double
        let velocity: SIMD3<Double>
        let oldCentres: [SIMD3<Double>]?
        let finalCentres: [SIMD3<Double>]?
        let memberFinalCentres: [SIMD3<Double>]?
        let finalFaces: [ConnectedGasGroups.Face]?
        let maximumAreaResidual: Double
        let maximumMomentResidual: Double
        let maximumVolumeResidual: Double

        /// Split only the accepted group inventory, in proportion to FINAL gas volume.
        /// Dry members receive zero; a largest member takes the floating-point remainder.
        func scatter(_ updated: [FractionalGasTransport.Cell]) throws -> [FractionalGasTransport.Cell] {
            guard updated.count == cells.count else { throw Failure.invalidState }
            _ = try FractionalGasTransport.advance(updated, newVolumes: updated.map(\.volume), transfers: [])
            var amounts = [SIMD8<Double>](repeating: .zero, count: memberFinalVolumes.count)
            for group in members.indices {
                guard abs(updated[group].volume - finalVolumes[group]) <= 1e-10 * finalVolumes[group] else {
                    throw Failure.invalidState
                }
                let wet = members[group].filter { memberFinalVolumes[$0] > 0 }
                guard let remainder = wet.max(by: { memberFinalVolumes[$0] < memberFinalVolumes[$1] }) else {
                    throw Failure.invalidState
                }
                var remaining = updated[group].amount
                for member in wet.filter({ $0 != remainder }) + [remainder] {
                    let packet =
                        member == remainder
                        ? remaining
                        : updated[group].amount * (memberFinalVolumes[member] / finalVolumes[group])
                    amounts[member] = packet
                    remaining -= packet
                }
            }
            let result = memberFinalVolumes.indices.map {
                FractionalGasTransport.Cell(volume: memberFinalVolumes[$0], amount: amounts[$0])
            }
            return try FractionalGasTransport.advance(result, newVolumes: memberFinalVolumes, transfers: [])
        }
    }

    static func build(
        old: [FractionalGasTransport.Cell], finalVolumes: [Double], meanVolumes: [Double],
        centres: [SIMD3<Double>], nominalVolume: Double, faces: [ConnectedGasGroups.Face],
        boundaries: [Boundary], duration: Double, velocity: SIMD3<Double>,
        oldGasCentres: [SIMD3<Double>]? = nil, finalGasCentres: [SIMD3<Double>]? = nil,
        finalFaces: [ConnectedGasGroups.Face]? = nil,
        minimumFraction: Double = 0.25, maximumMembers: Int = 64, tolerance: Double = 1e-8
    ) throws -> Plan {
        guard old.count == finalVolumes.count, old.count == meanVolumes.count,
            duration.isFinite && duration > 0, (0..<3).allSatisfy({ velocity[$0].isFinite }),
            finalVolumes.allSatisfy({ $0.isFinite && $0 >= 0 }),
            meanVolumes.allSatisfy({ $0.isFinite && $0 >= 0 })
        else { throw Failure.invalidGeometry }
        _ = try FractionalGasTransport.advance(old, newVolumes: old.map(\.volume), transfers: [])
        guard
            [oldGasCentres != nil, finalGasCentres != nil, finalFaces != nil].allSatisfy({ $0 })
                || (oldGasCentres == nil && finalGasCentres == nil && finalFaces == nil)
        else { throw Failure.invalidGeometry }
        for points in [oldGasCentres, finalGasCentres].compactMap({ $0 }) {
            guard points.count == old.count,
                points.allSatisfy({ p in (0..<3).allSatisfy { p[$0].isFinite } })
            else { throw Failure.invalidGeometry }
        }
        for face in finalFaces ?? [] {
            guard old.indices.contains(face.a), old.indices.contains(face.b), face.a != face.b,
                finalVolumes[face.a] > 0 && finalVolumes[face.b] > 0, face.area.isFinite && face.area > 0,
                (0..<3).allSatisfy({ face.normal[$0].isFinite && face.centroid[$0].isFinite }),
                abs(simd_length_squared(face.normal) - 1) < 1e-12
            else { throw Failure.invalidGeometry }
        }
        for n in old.indices {
            guard meanVolumes[n] > 0 || (old[n].volume == 0 && finalVolumes[n] == 0) else {
                throw Failure.invalidGeometry
            }
        }
        for boundary in boundaries {
            guard boundary.meanTime.isFinite, boundary.meanTime >= 0, boundary.meanTime <= duration,
                boundary.geometry.owner == 0 || boundary.geometry.owner == 1,
                boundary.geometry.samples == nil
            else { throw Failure.invalidGeometry }
        }
        let support = try ConnectedGasGroups.build(
            cells: meanVolumes.map { .init(volume: $0, density: 1, pressure: 1) }, centres: centres,
            nominalVolume: nominalVolume, faces: faces, boundaries: boundaries.map(\.geometry),
            minimumFraction: minimumFraction, maximumMembers: maximumMembers, tolerance: tolerance)
        // Validate geometric volume change per original cell, BEFORE internal faces cancel.
        var swept = [Double](repeating: 0, count: old.count)
        for boundary in boundaries where boundary.geometry.owner == 1 {
            let wall = boundary.geometry
            swept[wall.cell] += duration * wall.area * simd_dot(velocity, wall.normal)
        }
        var volumeResidual = 0.0
        for n in old.indices {
            let residual = abs(finalVolumes[n] - old[n].volume - swept[n]) / nominalVolume
            guard residual <= tolerance else { throw Failure.invalidGeometry }
            volumeResidual = max(volumeResidual, residual)
        }
        var members = support.groups.map(\.members)
        var parent = Array(members.indices)
        var initial = members.map { indices in indices.reduce(0) { $0 + old[$1].volume } }
        var final = members.map { indices in indices.reduce(0) { $0 + finalVolumes[$1] } }
        var adjacency = [[Int]](repeating: [], count: members.count)
        for (n, face) in support.faces.enumerated() {
            adjacency[face.a].append(n)
            adjacency[face.b].append(n)
        }
        func root(_ n: Int) -> Int {
            var r = n
            while parent[r] != r { r = parent[r] }
            return r
        }
        let required = minimumFraction * nominalVolume
        while let small = members.indices.filter({
            !members[$0].isEmpty && min(initial[$0], final[$0]) < required
        }).min(by: {
            let a = min(initial[$0], final[$0])
            let b = min(initial[$1], final[$1])
            return a == b ? $0 < $1 : a < b
        }) {
            var shared: [Int: Double] = [:]
            // Original support-group adjacency is retained through unions.
            for original in support.groups.indices where root(original) == small {
                for index in adjacency[original] {
                    let face = support.faces[index]
                    let other = root(face.a == original ? face.b : face.a)
                    if other != small { shared[other, default: 0] += face.area }
                }
            }
            let available = shared.keys.filter { members[small].count + members[$0].count <= maximumMembers }
            guard
                let other = available.sorted(by: {
                    if shared[$0]! != shared[$1]! { return shared[$0]! > shared[$1]! }
                    return $0 < $1
                }).first
            else { throw Failure.unsupportedGroup }
            let keep = min(small, other)
            let remove = max(small, other)
            parent[remove] = keep
            members[keep] = (members[keep] + members[remove]).sorted()
            members[remove] = []
            initial[keep] += initial[remove]
            final[keep] += final[remove]
        }
        let roots = members.indices.filter { !members[$0].isEmpty }
        let lookup = Dictionary(uniqueKeysWithValues: roots.enumerated().map { ($1, $0) })
        let mapping = support.cellToGroup.map { $0 < 0 ? -1 : lookup[root($0)]! }
        let groups = roots.map { n in
            FractionalGasTransport.Cell(
                volume: initial[n], amount: members[n].reduce(.zero) { $0 + old[$1].amount })
        }
        _ = try FractionalGasTransport.advance(groups, newVolumes: groups.map(\.volume), transfers: [])
        let external = faces.compactMap { face -> ConnectedGasGroups.Face? in
            guard face.area > 0 && mapping[face.a] != mapping[face.b] else { return nil }
            return .init(
                a: mapping[face.a], b: mapping[face.b], area: face.area,
                normal: face.normal, centroid: face.centroid)
        }
        let outer = boundaries.filter { $0.geometry.area > 0 }.map { boundary in
            let b = boundary.geometry
            return Boundary(
                geometry: .init(
                    cell: mapping[b.cell], area: b.area, normal: b.normal,
                    centroid: b.centroid, owner: b.owner), meanTime: boundary.meanTime)
        }
        func groupCentres(_ points: [SIMD3<Double>], _ volumes: [Double]) -> [SIMD3<Double>] {
            roots.map { n in
                let total = members[n].reduce(0) { $0 + volumes[$1] }
                let origin = points[members[n].max(by: { volumes[$0] < volumes[$1] })!]
                return origin + members[n].reduce(SIMD3<Double>.zero) {
                    $0 + volumes[$1] * (points[$1] - origin)
                } / total
            }
        }
        let endFaces = finalFaces.map { raw in
            raw.compactMap { face -> ConnectedGasGroups.Face? in
                guard mapping[face.a] != mapping[face.b] else { return nil }
                return .init(
                    a: mapping[face.a], b: mapping[face.b], area: face.area,
                    normal: face.normal, centroid: face.centroid)
            }
        }
        return Plan(
            members: roots.map { members[$0] }, cellToGroup: mapping, cells: groups,
            finalVolumes: roots.map { final[$0] }, memberFinalVolumes: finalVolumes,
            faces: external, boundaries: outer, duration: duration, velocity: velocity,
            oldCentres: oldGasCentres.map { groupCentres($0, old.map(\.volume)) },
            finalCentres: finalGasCentres.map { groupCentres($0, finalVolumes) },
            memberFinalCentres: finalGasCentres, finalFaces: endFaces,
            maximumAreaResidual: support.maximumAreaResidual,
            maximumMomentResidual: support.maximumMomentResidual, maximumVolumeResidual: volumeResidual)
    }
}

/// One frozen-state Rusanov/wall update using time-averaged areas. No extra remap flux is
/// applied: wall displacement enters endpoint volumes exactly once. Positivity and the
/// acoustic/contraction CFL are checked by the existing Euler reference, then final member
/// volumes receive conservative group packets. Nonuniform temporal accuracy is not validated.
enum MovingGroupedGasFlux {
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        let wallImpulses: [SIMD3<Double>]
        let wallWork: [Double]
        /// Extensive gas gain from prescribed outer reservoirs, in packet lane order.
        let reservoirExchange: SIMD8<Double>
        let maximumStep: Double
        let scatterLimitedGroups: Int
        let scatterPositivityReducedGroups: Int
        let scatterRankDeficientGroups: Int
    }
    static func advance(
        _ plan: MovingConnectedGasGroups.Plan, exterior: FractionalGasTransport.Cell,
        cfl: Double = 0.2, limited: Bool = false
    ) throws -> Result {
        guard exterior.volume > 0 else { throw MovingConnectedGasGroups.Failure.invalidState }
        _ = try FractionalGasTransport.advance([exterior], newVolumes: [exterior.volume], transfers: [])
        return try advance(
            plan, exteriorAt: { _ in exterior }, cfl: cfl, limited: limited,
            reconstructionExteriorAt: limited ? { _, _ in exterior } : nil)
    }
    /// Boundary-specific supplied states permit spatial/time-dependent reservoirs. The
    /// caller owns trace quadrature; numerical transfers remain paired and audited.
    static func advance(
        _ plan: MovingConnectedGasGroups.Plan,
        exteriorAt: (MovingConnectedGasGroups.Boundary) throws -> FractionalGasTransport.Cell,
        cfl: Double = 0.2, limited: Bool = false,
        reconstructionExteriorAt: (
            (MovingConnectedGasGroups.Boundary, SIMD3<Double>) throws -> FractionalGasTransport.Cell
        )? = nil
    ) throws -> Result {
        var cells = plan.cells
        if limited && (plan.oldCentres == nil || reconstructionExteriorAt == nil) {
            throw MovingConnectedGasGroups.Failure.invalidGeometry
        }
        var centres = plan.oldCentres ?? []
        var reconstructionStates = plan.cells
        var reconstructionFaces = plan.faces
        var faces = plan.faces.map {
            FractionalEulerFlux.Face(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area)
        }
        var walls: [FractionalEulerFlux.Wall] = []
        for boundary in plan.boundaries {
            let b = boundary.geometry
            if b.owner == 1 {
                walls.append(.init(cell: b.cell, normal: b.normal, area: b.area, velocity: plan.velocity))
            } else {
                let exterior = try exteriorAt(boundary)
                guard exterior.volume > 0 else { throw MovingConnectedGasGroups.Failure.invalidState }
                _ = try FractionalGasTransport.advance(
                    [exterior], newVolumes: [exterior.volume], transfers: [])
                // A separate finite buffer per patch makes the existing paired flux usable
                // for a prescribed reservoir. Its inventory change is returned explicitly.
                faces.append(.init(a: b.cell, b: cells.count, normal: b.normal, area: b.area))
                if limited {
                    let point =
                        centres[b.cell] - 2 * simd_dot(centres[b.cell] - b.centroid, b.normal) * b.normal
                    let state = try reconstructionExteriorAt!(boundary, point)
                    guard state.volume > 0 else { throw MovingConnectedGasGroups.Failure.invalidState }
                    _ = try FractionalGasTransport.advance([state], newVolumes: [state.volume], transfers: [])
                    reconstructionFaces.append(
                        .init(
                            a: b.cell, b: cells.count, area: b.area,
                            normal: b.normal, centroid: b.centroid))
                    centres.append(point)
                    reconstructionStates.append(state)
                }
                cells.append(
                    .init(
                        volume: 1, density: exterior.amount[0] / exterior.volume,
                        velocity: exterior.velocity, pressure: exterior.pressure()))
            }
        }
        if limited {
            let geometry = try LimitedGroupedGasFlux.Geometry(
                centres: centres, faces: reconstructionFaces,
                boundaries: plan.boundaries.filter { $0.geometry.owner == 1 }.map(\.geometry))
            let traces = try geometry.traces(reconstructionStates)
            faces = traces.faces.map { f in
                .init(
                    a: f.a, b: f.b, normal: f.normal, area: f.area,
                    leftState: f.leftState, rightState: f.b < plan.cells.count ? f.rightState : cells[f.b])
            }
            walls = traces.walls.map { w in
                .init(cell: w.cell, normal: w.normal, area: w.area, velocity: plan.velocity, state: w.state)
            }
        }
        let limit = try FractionalEulerFlux.maximumStep(cells, faces: faces, walls: walls, cfl: cfl)
        let advanced = try FractionalEulerFlux.advanceWithWalls(
            cells, faces: faces, walls: walls, duration: plan.duration, cfl: cfl)
        var updated: [FractionalGasTransport.Cell] = []
        for n in plan.cells.indices {
            guard abs(advanced.cells[n].volume - plan.finalVolumes[n]) <= 1e-8 * plan.finalVolumes[n] else {
                throw MovingConnectedGasGroups.Failure.invalidGeometry
            }
            updated.append(.init(volume: plan.finalVolumes[n], amount: advanced.cells[n].amount))
        }
        var reservoir = SIMD8<Double>.zero
        for n in plan.cells.count..<cells.count { reservoir += cells[n].amount - advanced.cells[n].amount }
        let scattered = limited ? try LimitedMovingGroupScatter.scatter(plan, updated: updated) : nil
        return Result(
            cells: try scattered?.cells ?? plan.scatter(updated), wallImpulses: advanced.wallImpulses,
            wallWork: advanced.wallWork, reservoirExchange: reservoir, maximumStep: limit,
            scatterLimitedGroups: scattered?.limitedGroups ?? 0,
            scatterPositivityReducedGroups: scattered?.positivityReducedGroups ?? 0,
            scatterRankDeficientGroups: scattered?.rankDeficientGroups ?? 0)
    }
}
