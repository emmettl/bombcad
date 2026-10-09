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
        var samples: [TranslatingBoxSpaceTimeGeometry.WallSample]? = nil
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
        var oldConservedGeometry: ConservedGroupedGasGeometry? = nil
        var finalConservedGeometry: ConservedGroupedGasGeometry? = nil

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
            if let samples = boundary.samples {
                let b = boundary.geometry
                guard b.owner == 1, old.indices.contains(b.cell), centres.count == old.count else {
                    throw Failure.invalidGeometry
                }
                let areaTime = duration * b.area
                let patch = TranslatingBoxSpaceTimeGeometry.PatchIntegral(
                    normal: b.normal, areaTime: areaTime,
                    firstMomentTime: areaTime * (b.centroid - centres[b.cell]),
                    timeWeightedArea: areaTime * boundary.meanTime, samples: samples)
                _ = try MovingWallPressureQuadrature.integrate(
                    patch, cellCentre: centres[b.cell], initialCentreOfMass: .zero, velocity: velocity,
                    duration: duration, lengthScale: pow(nominalVolume, 1.0 / 3), pressure: { _, _ in 1 })
            }
        }
        let support = try ConnectedGasGroups.build(
            cells: meanVolumes.map { .init(volume: $0, density: 1, pressure: 1) }, centres: centres,
            nominalVolume: nominalVolume, faces: faces, boundaries: boundaries.map(\.geometry),
            minimumFraction: minimumFraction, maximumMembers: maximumMembers, tolerance: tolerance,
            areaScale: pow(nominalVolume, 2.0 / 3))
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
                    centroid: b.centroid, owner: b.owner), meanTime: boundary.meanTime,
                samples: boundary.samples)
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

/// Paired moving Rusanov/wall updates using interval geometry. No extra remap flux is
/// applied: wall displacement enters endpoint volumes exactly once. Positivity and the
/// acoustic/contraction CFL are checked by the existing Euler reference, then final member
/// volumes receive conservative group packets. Sampled Heun walls interpolate endpoint
/// pressure packets at their actual times; gas and body receive the same corrected loads.
enum MovingGroupedGasFlux {
    enum TimeIntegration: String { case euler, heun }
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        let wallImpulses: [SIMD3<Double>]
        let wallWork: [Double]
        /// Moments about an origin translating at plan.velocity. Subtract COM0 × impulse
        /// to obtain the corresponding angular impulse about the body's translating COM.
        let wallMomentImpulses: [SIMD3<Double>]
        let wallSampleFallbacks: Int
        /// Extensive gas gain from prescribed outer reservoirs, in packet lane order.
        let reservoirExchange: SIMD8<Double>
        let maximumStep: Double
        let scatterLimitedGroups: Int
        let scatterPositivityReducedGroups: Int
        let scatterRankDeficientGroups: Int
    }
    static func advance(
        _ plan: MovingConnectedGasGroups.Plan, exterior: FractionalGasTransport.Cell,
        cfl: Double = 0.2, limited: Bool = false, timeIntegration: TimeIntegration = .euler,
        conservedQuadratic: Bool = false
    ) throws -> Result {
        guard exterior.volume > 0 else { throw MovingConnectedGasGroups.Failure.invalidState }
        _ = try FractionalGasTransport.advance([exterior], newVolumes: [exterior.volume], transfers: [])
        return try advance(
            plan, exteriorAt: { _ in exterior }, cfl: cfl, limited: limited,
            reconstructionExteriorAt: limited ? { _, _ in exterior } : nil,
            reconstructionExteriorAtEnd: limited ? { _, _ in exterior } : nil,
            timeIntegration: timeIntegration, conservedQuadratic: conservedQuadratic)
    }
    /// Boundary-specific supplied states permit spatial/time-dependent reservoirs. The
    /// caller owns trace quadrature; numerical transfers remain paired and audited.
    static func advance(
        _ plan: MovingConnectedGasGroups.Plan,
        exteriorAt: (MovingConnectedGasGroups.Boundary) throws -> FractionalGasTransport.Cell,
        cfl: Double = 0.2, limited: Bool = false,
        reconstructionExteriorAt: (
            (MovingConnectedGasGroups.Boundary, SIMD3<Double>) throws -> FractionalGasTransport.Cell
        )? = nil,
        reconstructionExteriorAtEnd: (
            (MovingConnectedGasGroups.Boundary, SIMD3<Double>) throws -> FractionalGasTransport.Cell
        )? = nil, timeIntegration: TimeIntegration = .euler, conservedQuadratic: Bool = false
    ) throws -> Result {
        guard
            !conservedQuadratic
                || (limited && plan.oldConservedGeometry != nil
                    && (timeIntegration != .heun || plan.finalConservedGeometry != nil))
        else { throw MovingConnectedGasGroups.Failure.invalidGeometry }
        let locations = wallLocations(plan)
        // Reservoir states are interval averages, sampled once and reused in both stages.
        // Endpoint point states below are ONLY for the reconstruction stencil.
        let supplied = try plan.boundaries.map { boundary -> FractionalGasTransport.Cell? in
            boundary.geometry.owner == 0 ? try exteriorAt(boundary) : nil
        }
        let first = try stage(
            plan, inventories: plan.cells, centres: plan.oldCentres, supplied: supplied,
            cfl: cfl, limited: limited, locations: locations,
            reconstructionExteriorAt: reconstructionExteriorAt,
            conservedGeometry: conservedQuadratic ? plan.oldConservedGeometry : nil)
        var updated = first.cells
        var impulses = first.wallImpulses
        var work = first.wallWork
        var reservoir = first.reservoirExchange
        var limit = first.maximumStep
        for n in updated.indices {
            guard abs(updated[n].volume - plan.finalVolumes[n]) <= 1e-8 * plan.finalVolumes[n] else {
                throw MovingConnectedGasGroups.Failure.invalidGeometry
            }
            updated[n] = .init(volume: plan.finalVolumes[n], amount: updated[n].amount)
        }
        if timeIntegration == .heun {
            // Frozen interval geometry: V1=V0+dV, V2=V0+2*dV. Averaging old and
            // stage-two EXTENSIVE inventories gives V1, preserving comoving constant
            // states and the geometric conservation law. Never scatter between stages.
            let second = try stage(
                plan, inventories: updated, centres: plan.finalCentres, supplied: supplied,
                cfl: cfl, limited: limited, locations: locations,
                reconstructionExteriorAt: reconstructionExteriorAtEnd,
                conservedGeometry: conservedQuadratic ? plan.finalConservedGeometry : nil)
            updated = updated.indices.map {
                .init(
                    volume: plan.finalVolumes[$0],
                    amount: 0.5 * (plan.cells[$0].amount + second.cells[$0].amount))
            }
            impulses = zip(first.wallImpulses, second.wallImpulses).map { 0.5 * ($0 + $1) }
            work = zip(first.wallWork, second.wallWork).map { 0.5 * ($0 + $1) }
            var corrections = [SIMD8<Double>](repeating: .zero, count: updated.count)
            for n in locations.indices where locations[n].sampled {
                let alpha = locations[n].boundary.meanTime / plan.duration
                let impulse = (1 - alpha) * first.wallImpulses[n] + alpha * second.wallImpulses[n]
                let energy = (1 - alpha) * first.wallWork[n] + alpha * second.wallWork[n]
                let delta = impulse - impulses[n]
                // The standard half-stage update is corrected with the SAME packet
                // returned to the body. This uses temporal pressure/area covariance.
                corrections[locations[n].boundary.geometry.cell] += SIMD8(
                    0, delta.x, delta.y, delta.z, energy - work[n], 0, 0, 0)
                impulses[n] = impulse
                work[n] = energy
            }
            updated = updated.indices.map {
                .init(volume: plan.finalVolumes[$0], amount: updated[$0].amount - corrections[$0])
            }
            _ = try FractionalGasTransport.advance(updated, newVolumes: plan.finalVolumes, transfers: [])
            reservoir = 0.5 * (first.reservoirExchange + second.reservoirExchange)
            limit = min(first.maximumStep, second.maximumStep)
        }
        let count = plan.boundaries.filter { $0.geometry.owner == 1 }.count
        var patchImpulses = [SIMD3<Double>](repeating: .zero, count: count)
        var patchMoments = patchImpulses
        var patchWork = [Double](repeating: 0, count: count)
        for n in locations.indices {
            let location = locations[n]
            patchImpulses[location.patch] += impulses[n]
            patchWork[location.patch] += work[n]
            patchMoments[location.patch] += simd_cross(
                location.boundary.geometry.centroid - location.boundary.meanTime * plan.velocity,
                impulses[n])
        }
        let scattered = limited ? try LimitedMovingGroupScatter.scatter(plan, updated: updated) : nil
        return Result(
            cells: try scattered?.cells ?? plan.scatter(updated), wallImpulses: patchImpulses,
            wallWork: patchWork, wallMomentImpulses: patchMoments,
            wallSampleFallbacks: plan.boundaries.filter { $0.samples?.count == 1 }.count,
            reservoirExchange: reservoir, maximumStep: limit,
            scatterLimitedGroups: scattered?.limitedGroups ?? 0,
            scatterPositivityReducedGroups: scattered?.positivityReducedGroups ?? 0,
            scatterRankDeficientGroups: scattered?.rankDeficientGroups ?? 0)
    }
    private struct WallLocation {
        let patch: Int
        let boundary: MovingConnectedGasGroups.Boundary
        let sampled: Bool
    }
    private static func wallLocations(_ plan: MovingConnectedGasGroups.Plan) -> [WallLocation] {
        plan.boundaries.filter { $0.geometry.owner == 1 }.enumerated().flatMap { index, boundary in
            guard let samples = boundary.samples else {
                return [WallLocation(patch: index, boundary: boundary, sampled: false)]
            }
            let b = boundary.geometry
            return samples.map { sample in
                WallLocation(
                    patch: index,
                    boundary: .init(
                        geometry: .init(
                            cell: b.cell, area: sample.areaTime / plan.duration,
                            normal: b.normal, centroid: sample.point, owner: 1),
                        meanTime: sample.time), sampled: true)
            }
        }
    }
    private struct Stage {
        let cells: [FractionalGasTransport.Cell]
        let wallImpulses: [SIMD3<Double>]
        let wallWork: [Double]
        let reservoirExchange: SIMD8<Double>
        let maximumStep: Double
    }
    struct InitialWallTrace {
        let cell: Int
        let point: SIMD3<Double>
        let time: Double
        let normal: SIMD3<Double>
        let area: Double
        let velocity: SIMD3<Double>
        let state: FractionalGasTransport.Cell
        var pressureReconstruction: LimitedGroupedGasFlux.PressureReconstruction? = nil
    }
    /// Diagnostic access to the exact initial reconstruction used by the numerical
    /// update. No gas inventory is advanced and no independent slope implementation is used.
    static func initialWallTraces(
        _ plan: MovingConnectedGasGroups.Plan, exterior: FractionalGasTransport.Cell, limited: Bool,
        recordPressureDiagnostics: Bool = false,
        diagnosticPressureAt: ((SIMD3<Double>) throws -> Double)? = nil
    ) throws -> [InitialWallTrace] {
        guard exterior.volume > 0 else { throw MovingConnectedGasGroups.Failure.invalidState }
        _ = try FractionalGasTransport.advance([exterior], newVolumes: [exterior.volume], transfers: [])
        var inventories = plan.cells
        if let diagnosticPressureAt {
            guard let centres = plan.oldCentres else {
                throw MovingConnectedGasGroups.Failure.invalidGeometry
            }
            // Only this read-only accessor permits point-pressure substitution. It
            // changes diagnostic energy; it is never passed into a numerical advance.
            inventories = try plan.cells.indices.map { n in
                let pressure = try diagnosticPressureAt(centres[n])
                guard pressure.isFinite && pressure > 0 else {
                    throw MovingConnectedGasGroups.Failure.invalidState
                }
                let cell = plan.cells[n]
                return .init(
                    volume: cell.volume, density: cell.amount[0] / cell.volume,
                    velocity: cell.velocity, pressure: pressure)
            }
        }
        let locations = wallLocations(plan)
        let supplied = plan.boundaries.map { $0.geometry.owner == 0 ? exterior : nil }
        let prepared = try prepare(
            plan, inventories: inventories, centres: plan.oldCentres, supplied: supplied,
            limited: limited, locations: locations,
            reconstructionExteriorAt: limited ? { _, _ in exterior } : nil,
            recordPressureDiagnostics: recordPressureDiagnostics)
        return zip(locations, prepared.walls).map { location, wall in
            .init(
                cell: wall.cell, point: location.boundary.geometry.centroid, time: location.boundary.meanTime,
                normal: wall.normal, area: wall.area, velocity: wall.velocity,
                state: wall.state ?? inventories[wall.cell],
                pressureReconstruction: prepared.pressureDiagnostics?[wall.cell])
        }
    }
    private struct Prepared {
        let cells: [FractionalGasTransport.Cell]
        let faces: [FractionalEulerFlux.Face]
        let walls: [FractionalEulerFlux.Wall]
        let pressureDiagnostics: [LimitedGroupedGasFlux.PressureReconstruction]?
    }
    private static func prepare(
        _ plan: MovingConnectedGasGroups.Plan, inventories: [FractionalGasTransport.Cell],
        centres suppliedCentres: [SIMD3<Double>]?, supplied: [FractionalGasTransport.Cell?],
        limited: Bool, locations: [WallLocation],
        reconstructionExteriorAt: (
            (MovingConnectedGasGroups.Boundary, SIMD3<Double>) throws -> FractionalGasTransport.Cell
        )?, recordPressureDiagnostics: Bool = false, conservedGeometry: ConservedGroupedGasGeometry? = nil
    ) throws -> Prepared {
        var cells = inventories
        if limited && (suppliedCentres == nil || reconstructionExteriorAt == nil) {
            throw MovingConnectedGasGroups.Failure.invalidGeometry
        }
        var centres = suppliedCentres ?? []
        var reconstructionStates = inventories
        var reconstructionFaces = plan.faces
        var faces = plan.faces.map {
            FractionalEulerFlux.Face(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area)
        }
        var walls = locations.map {
            let b = $0.boundary.geometry
            return FractionalEulerFlux.Wall(
                cell: b.cell, normal: b.normal, area: b.area, velocity: plan.velocity)
        }
        for (index, boundary) in plan.boundaries.enumerated() {
            let b = boundary.geometry
            if b.owner == 1 {
                continue
            } else {
                let exterior = supplied[index]!
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
        var pressureDiagnostics: [LimitedGroupedGasFlux.PressureReconstruction]?
        if limited {
            let traces: LimitedGroupedGasFlux.Traces
            if let conservedGeometry {
                traces = try conservedGeometry.traces(
                    reconstructionStates, centres: centres,
                    faces: reconstructionFaces, walls: locations.map { $0.boundary.geometry })
            } else {
                let geometry = try LimitedGroupedGasFlux.Geometry(
                    centres: centres, faces: reconstructionFaces,
                    boundaries: locations.map { $0.boundary.geometry })
                traces = try geometry.traces(
                    reconstructionStates, recordPressureDiagnostics: recordPressureDiagnostics)
            }
            pressureDiagnostics = traces.pressureDiagnostics
            faces = traces.faces.map { f in
                .init(
                    a: f.a, b: f.b, normal: f.normal, area: f.area,
                    leftState: f.leftState, rightState: f.b < plan.cells.count ? f.rightState : cells[f.b])
            }
            walls = traces.walls.map { w in
                .init(cell: w.cell, normal: w.normal, area: w.area, velocity: plan.velocity, state: w.state)
            }
        }
        return Prepared(cells: cells, faces: faces, walls: walls, pressureDiagnostics: pressureDiagnostics)
    }
    /// Stage two can have extrapolated volumes; only the accepted interval scatters.
    private static func stage(
        _ plan: MovingConnectedGasGroups.Plan, inventories: [FractionalGasTransport.Cell],
        centres suppliedCentres: [SIMD3<Double>]?, supplied: [FractionalGasTransport.Cell?],
        cfl: Double, limited: Bool, locations: [WallLocation],
        reconstructionExteriorAt: (
            (MovingConnectedGasGroups.Boundary, SIMD3<Double>) throws -> FractionalGasTransport.Cell
        )?, conservedGeometry: ConservedGroupedGasGeometry? = nil
    ) throws -> Stage {
        let prepared = try prepare(
            plan, inventories: inventories, centres: suppliedCentres, supplied: supplied,
            limited: limited, locations: locations, reconstructionExteriorAt: reconstructionExteriorAt,
            conservedGeometry: conservedGeometry)
        let cells = prepared.cells
        let faces = prepared.faces
        let walls = prepared.walls
        let limit = try FractionalEulerFlux.maximumStep(cells, faces: faces, walls: walls, cfl: cfl)
        let advanced = try FractionalEulerFlux.advanceWithWalls(
            cells, faces: faces, walls: walls, duration: plan.duration, cfl: cfl)
        var reservoir = SIMD8<Double>.zero
        for n in plan.cells.count..<cells.count { reservoir += cells[n].amount - advanced.cells[n].amount }
        return Stage(
            cells: Array(advanced.cells.prefix(plan.cells.count)), wallImpulses: advanced.wallImpulses,
            wallWork: advanced.wallWork, reservoirExchange: reservoir, maximumStep: limit)
    }
}
