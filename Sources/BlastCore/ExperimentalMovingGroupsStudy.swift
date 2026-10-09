import simd

/// A single numerical interval centred on a wet/dry event. Frozen group states feed
/// ordinary paired Rusanov and local moving-wall fluxes; matching outer reservoirs
/// support the uniform comoving case. This is not a multi-step moving-box solver.
public enum ExperimentalMovingGroupsStudy {
    public struct Result: Codable, Sendable {
        public let cellSize: Double
        public let rotation: Double
        public let transition: String
        public let pathTime: Double
        public let duration: Double
        public let rejectedSteps: Int
        public let groups: Int
        public let maximumMembers: Int
        public let minimumOldGroupFraction: Double
        public let minimumFinalGroupFraction: Double
        public let dryToWetCells: Int
        public let wetToDryCells: Int
        public let maximumStep: Double
        public let maximumRelativeDensityError: Double
        public let maximumRelativePressureError: Double
        public let maximumVelocityError: Double
        public let minimumPressure: Double
        public let maximumRelativeGeometryResidual: Double
        public let massBudgetResidual: Double
        public let momentumBudgetResidual: SIMD3<Double>
        public let energyBudgetResidual: Double
        public let bodyImpulse: SIMD3<Double>
        public let bodyAngularImpulse: SIMD3<Double>
        public let bodyWork: Double
        public let impulseWorkResidual: Double
    }
    enum Failure: Error {
        case invalidConfiguration, missingTransition, inconsistentFace, inconsistentInventory
    }
    public static func run(
        cellSizes: [Double] = [0.2, 0.1], rotations: [Double] = [0, 0.23],
        duration: Double = 0.000004, progress: (Result) throws -> Void = { _ in }
    ) throws -> [Result] {
        guard duration.isFinite, duration > 0, duration < 0.001 else { throw Failure.invalidConfiguration }
        var results: [Result] = []
        for h in cellSizes {
            guard h.isFinite, h >= 0.1, h <= 0.2, abs(2 / h - (2 / h).rounded()) < 1e-10 else {
                throw Failure.invalidConfiguration
            }
            for angle in rotations {
                guard angle.isFinite else { throw Failure.invalidConfiguration }
                for opening in [true, false] {
                    var step = duration
                    var accepted: Result?
                    for retry in 0..<16 {
                        do {
                            accepted = try measure(
                                h: h, angle: angle, opening: opening, duration: step,
                                rejectedSteps: retry)
                            break
                        } catch FractionalEulerFlux.Failure.unstableStep {
                            step /= 2
                        }
                    }
                    guard let r = accepted else { throw FractionalEulerFlux.Failure.unstableStep }
                    results.append(r)
                    try progress(r)
                }
            }
        }
        return results
    }
    static let velocity = SIMD3<Double>(3, 1, -0.4)
    static func body(angle: Double, time: Double) throws -> RigidBoxBody {
        try RigidBoxBody(
            mass: 2, size: SIMD3(repeating: 0.8),
            position: SIMD3(1.013, 1.027, 1.041) + time * velocity,
            orientation: simd_quatd(angle: angle, axis: simd_normalize(SIMD3(1, 2, 3))))
    }
    static func eventTime(h: Double, angle: Double, opening: Bool) throws -> Double {
        let count = Int((2 / h).rounded())
        let first = FractionalBoxGeometry(try body(angle: angle, time: 0))
        let last = FractionalBoxGeometry(try body(angle: angle, time: 0.08))
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let lower = h * SIMD3(Double(x), Double(y), Double(z))
                    let corners = (0..<8).map { n in
                        lower + h
                            * SIMD3<Double>(
                                n & 1 == 0 ? 0 : 1,
                                n & 2 == 0 ? 0 : 1, n & 4 == 0 ? 0 : 1)
                    }
                    let a = corners.allSatisfy(first.contains)
                    let b = corners.allSatisfy(last.contains)
                    guard opening ? (a && !b) : (!a && b) else { continue }
                    var low = 0.0
                    var high = 0.08
                    for _ in 0..<45 {
                        let time = (low + high) / 2
                        let current = FractionalBoxGeometry(try body(angle: angle, time: time))
                        if corners.allSatisfy(current.contains) == opening { low = time } else { high = time }
                    }
                    return (low + high) / 2
                }
            }
        }
        throw Failure.missingTransition
    }
    struct Domain {
        let plan: MovingConnectedGasGroups.Plan
        let old: [FractionalGasTransport.Cell]
        let body: RigidBoxBody
    }
    static func domain(
        h: Double, angle: Double, start: Double, duration: Double,
        previous: [FractionalGasTransport.Cell]? = nil, prescribedBody: RigidBoxBody? = nil,
        prescribedVelocity: SIMD3<Double> = velocity, reconstruct: Bool = false,
        surfaceQuadrature: Bool = false
    ) throws -> Domain {
        let count = Int((2 / h).rounded())
        guard previous == nil || previous!.count == count * count * count else {
            throw Failure.inconsistentInventory
        }
        let body = try prescribedBody ?? self.body(angle: angle, time: start)
        let sweep = try TranslatingBoxSpaceTimeGeometry(body: body, velocity: prescribedVelocity)
        let startGeometry = FractionalBoxGeometry(body)
        let endGeometry = FractionalBoxGeometry(body.translated(by: duration * prescribedVelocity))
        let nominalVolume = h * h * h
        var oldCentres: [SIMD3<Double>] = []
        var finalCentres: [SIMD3<Double>] = []
        var endPatches = [[FractionalBoxGeometry.SurfacePatch]?](repeating: nil, count: count * count * count)
        func gasCentre(_ g: FractionalBoxGeometry, lower: SIMD3<Double>, volume: Double) throws -> SIMD3<
            Double
        > {
            let origin = lower + SIMD3<Double>(repeating: h / 2)
            if volume == 0 || volume == nominalVolume { return origin }
            let nodes = g.gasQuadrature(lower: lower, cellSize: h)
            let weight = nodes.reduce(0) { $0 + $1.weight }
            guard weight > 0 else { throw Failure.inconsistentInventory }
            return origin + nodes.reduce(SIMD3<Double>.zero) { $0 + $1.weight * ($1.point - origin) } / weight
        }
        var geometry: [TranslatingBoxSpaceTimeGeometry.Result] = []
        var old: [FractionalGasTransport.Cell] = []
        var centres: [SIMD3<Double>] = []
        var boundaries: [MovingConnectedGasGroups.Boundary] = []
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let lower = h * SIMD3(Double(x), Double(y), Double(z))
                    let centre = lower + SIMD3(repeating: h / 2)
                    let r = try sweep.integrate(
                        lower: lower, cellSize: h, duration: duration, wallQuadrature: surfaceQuadrature)
                    let index = old.count
                    if let previous {
                        guard abs(previous[index].volume - r.initialGasVolume) <= 1e-10 * h * h * h,
                            (previous[index].volume == 0) == (r.initialGasVolume == 0)
                        else { throw Failure.inconsistentInventory }
                        old.append(previous[index])
                    } else {
                        old.append(
                            .init(
                                volume: r.initialGasVolume, density: 1.225,
                                velocity: prescribedVelocity, pressure: 101325))
                    }
                    centres.append(centre)
                    if reconstruct {
                        oldCentres.append(
                            try gasCentre(startGeometry, lower: lower, volume: r.initialGasVolume))
                        finalCentres.append(
                            try gasCentre(endGeometry, lower: lower, volume: r.finalGasVolume))
                        if r.finalGasVolume > 0 && r.finalGasVolume < nominalVolume {
                            endPatches[index] = endGeometry.openFacePatches(lower: lower, cellSize: h)
                        }
                    }
                    geometry.append(r)
                    for wall in r.walls where wall.areaTime > 0 {
                        boundaries.append(
                            .init(
                                geometry: .init(
                                    cell: index, area: wall.areaTime / duration,
                                    normal: wall.normal,
                                    centroid: centre + wall.firstMomentTime / wall.areaTime, owner: 1),
                                meanTime: wall.timeWeightedArea / wall.areaTime, samples: wall.samples))
                    }
                    for side in 0..<6 {
                        let coordinate = [x, y, z][side / 2]
                        guard (side % 2 == 0 && coordinate == 0) || (side % 2 == 1 && coordinate == count - 1)
                        else { continue }
                        let p = r.openFaces[side]
                        if p.areaTime > 0 {
                            boundaries.append(
                                .init(
                                    geometry: .init(
                                        cell: index, area: p.areaTime / duration,
                                        normal: p.normal, centroid: centre + p.firstMomentTime / p.areaTime),
                                    meanTime: p.timeWeightedArea / p.areaTime))
                        }
                    }
                }
            }
        }
        var faces: [ConnectedGasGroups.Face] = []
        var finalFaces: [ConnectedGasGroups.Face] = []
        for z in 0..<count {
            for y in 0..<count {
                for x in 0..<count {
                    let index = x + count * (y + count * z)
                    for axis in 0..<3 where [x, y, z][axis] + 1 < count {
                        let neighbor = index + [1, count, count * count][axis]
                        let a = geometry[index].openFaces[2 * axis + 1]
                        let b = geometry[neighbor].openFaces[2 * axis]
                        if reconstruct && geometry[index].finalGasVolume > 0
                            && geometry[neighbor].finalGasVolume > 0
                        {
                            let pa = endPatches[index]?[2 * axis + 1]
                            let pb = endPatches[neighbor]?[2 * axis]
                            if let pa, let pb, abs(pa.area - pb.area) > h * h * 1e-10 {
                                throw Failure.inconsistentFace
                            }
                            let area = pa?.area ?? pb?.area ?? (h * h)
                            if area > h * h * 1e-12 {
                                let point =
                                    pa?.centroid ?? pb?.centroid ?? (centres[index] + centres[neighbor]) / 2
                                finalFaces.append(
                                    .init(
                                        a: index, b: neighbor, area: area, normal: a.normal, centroid: point))
                            }
                        }
                        guard abs(a.areaTime - b.areaTime) < h * h * duration * 1e-10 else {
                            throw Failure.inconsistentFace
                        }
                        let areaTime = (a.areaTime + b.areaTime) / 2
                        if areaTime > 0 {
                            let centroid =
                                (centres[index] * a.areaTime + a.firstMomentTime
                                    + centres[neighbor] * b.areaTime + b.firstMomentTime) / (2 * areaTime)
                            faces.append(
                                .init(
                                    a: index, b: neighbor, area: areaTime / duration,
                                    normal: a.normal, centroid: centroid))
                        }
                    }
                }
            }
        }
        let plan = try MovingConnectedGasGroups.build(
            old: old,
            finalVolumes: geometry.map(\.finalGasVolume),
            meanVolumes: geometry.map { $0.gasVolumeTime / duration },
            centres: centres, nominalVolume: h * h * h, faces: faces, boundaries: boundaries,
            duration: duration, velocity: prescribedVelocity,
            oldGasCentres: reconstruct ? oldCentres : nil, finalGasCentres: reconstruct ? finalCentres : nil,
            finalFaces: reconstruct ? finalFaces : nil)
        return Domain(plan: plan, old: old, body: body)
    }
    private static func measure(
        h: Double, angle: Double, opening: Bool, duration: Double,
        rejectedSteps: Int
    ) throws -> Result {
        let time = try eventTime(h: h, angle: angle, opening: opening)
        let domain = try domain(h: h, angle: angle, start: time - duration / 2, duration: duration)
        let plan = domain.plan
        let r = try MovingGroupedGasFlux.advance(
            plan,
            exterior: .init(volume: 1, density: 1.225, velocity: velocity, pressure: 101325))
        let before = domain.old.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = r.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let impulse = r.wallImpulses.reduce(SIMD3<Double>.zero, +)
        let work = r.wallWork.reduce(0, +)
        var angular = SIMD3<Double>.zero
        for n in r.wallImpulses.indices {
            angular += r.wallMomentImpulses[n] - simd_cross(domain.body.position, r.wallImpulses[n])
        }
        let wet = r.cells.filter { $0.volume > 0 }
        return Result(
            cellSize: h, rotation: angle, transition: opening ? "dry-to-wet" : "wet-to-dry",
            pathTime: time, duration: duration, rejectedSteps: rejectedSteps, groups: plan.cells.count,
            maximumMembers: plan.members.map(\.count).max()!,
            minimumOldGroupFraction: plan.cells.map { $0.volume / (h * h * h) }.min()!,
            minimumFinalGroupFraction: plan.finalVolumes.map { $0 / (h * h * h) }.min()!,
            dryToWetCells: r.cells.indices.filter { domain.old[$0].volume == 0 && r.cells[$0].volume > 0 }
                .count,
            wetToDryCells: r.cells.indices.filter { domain.old[$0].volume > 0 && r.cells[$0].volume == 0 }
                .count,
            maximumStep: r.maximumStep,
            maximumRelativeDensityError: wet.map { abs($0.amount[0] / $0.volume / 1.225 - 1) }.max()!,
            maximumRelativePressureError: wet.map { abs($0.pressure() / 101325 - 1) }.max()!,
            maximumVelocityError: wet.map { simd_distance($0.velocity, velocity) }.max()!,
            minimumPressure: wet.map { $0.pressure() }.min()!,
            maximumRelativeGeometryResidual: plan.maximumVolumeResidual,
            massBudgetResidual: after[0] - before[0] - r.reservoirExchange[0],
            momentumBudgetResidual: SIMD3(
                after[1] - before[1] - r.reservoirExchange[1],
                after[2] - before[2] - r.reservoirExchange[2], after[3] - before[3] - r.reservoirExchange[3])
                + impulse,
            energyBudgetResidual: after[4] - before[4] - r.reservoirExchange[4] + work,
            bodyImpulse: impulse, bodyAngularImpulse: angular, bodyWork: work,
            impulseWorkResidual: work - simd_dot(velocity, impulse))
    }
}
