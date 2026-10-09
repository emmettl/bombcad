import simd

/// Reconstruct CONSERVED densities at final member gas centroids. A common slope factor
/// bounds all member values by one-ring extrema. Weighted offsets sum to zero, and a
/// largest-volume member receives the packet remainder. Nonlinear Euler admissibility is
/// checked after packet construction; reduce slopes, never floor mass or pressure.
enum LimitedMovingGroupScatter {
    struct Result {
        let cells: [FractionalGasTransport.Cell]
        let limitedGroups: Int
        let positivityReducedGroups: Int
        let rankDeficientGroups: Int
    }
    static func scatter(
        _ plan: MovingConnectedGasGroups.Plan, updated: [FractionalGasTransport.Cell]
    ) throws -> Result {
        guard let centres = plan.finalCentres, let memberCentres = plan.memberFinalCentres,
            let faces = plan.finalFaces, updated.count == plan.members.count,
            centres.count == updated.count, memberCentres.count == plan.memberFinalVolumes.count
        else { throw MovingConnectedGasGroups.Failure.invalidGeometry }
        _ = try FractionalGasTransport.advance(updated, newVolumes: updated.map(\.volume), transfers: [])
        let wet = plan.members.map { $0.filter { plan.memberFinalVolumes[$0] > 0 } }
        let active = wet.map { $0.count > 1 }
        let states = updated.map { $0.amount / $0.volume }
        var neighbours = [[(Int, Double)]](repeating: [], count: updated.count)
        var matrices = [simd_double3x3](
            repeating: .init(columns: (.zero, .zero, .zero)), count: updated.count)
        for face in faces {
            let d = centres[face.b] - centres[face.a]
            guard simd_length_squared(d) > 0 else { throw MovingConnectedGasGroups.Failure.invalidGeometry }
            let weight = face.area / simd_length_squared(d)
            let matrix = weight * simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
            for (a, b) in [(face.a, face.b), (face.b, face.a)] where active[a] {
                neighbours[a].append((b, weight))
                matrices[a] += matrix
            }
        }
        var amounts = [SIMD8<Double>](repeating: .zero, count: memberCentres.count)
        var limited = 0
        var reduced = 0
        var deficient = 0
        for n in updated.indices {
            guard abs(updated[n].volume - plan.finalVolumes[n]) <= 1e-10 * plan.finalVolumes[n],
                let remainder = wet[n].max(by: { plan.memberFinalVolumes[$0] < plan.memberFinalVolumes[$1] })
            else { throw MovingConnectedGasGroups.Failure.invalidState }
            if !active[n] {
                amounts[remainder] = updated[n].amount
                continue
            }
            let scale = matrices[n][0][0] + matrices[n][1][1] + matrices[n][2][2]
            var gradients = [SIMD3<Double>](repeating: .zero, count: 5)
            var factor = 1.0
            if scale.isFinite && scale > 0 && simd_determinant((1 / scale) * matrices[n]) > 1e-10 {
                let inverse = simd_inverse(matrices[n])
                for component in 0..<5 {
                    var rhs = SIMD3<Double>.zero
                    var low = states[n][component]
                    var high = states[n][component]
                    for (other, weight) in neighbours[n] {
                        rhs +=
                            weight * (states[other][component] - states[n][component])
                            * (centres[other] - centres[n])
                        low = min(low, states[other][component])
                        high = max(high, states[other][component])
                    }
                    gradients[component] = inverse * rhs
                    for member in wet[n] {
                        let delta = simd_dot(gradients[component], memberCentres[member] - centres[n])
                        if delta > 0 { factor = min(factor, (high - states[n][component]) / delta) }
                        if delta < 0 { factor = min(factor, (low - states[n][component]) / delta) }
                    }
                }
                factor = min(1, max(0, factor))
                if factor < 1 - 1e-12 { limited += 1 }
            } else {
                deficient += 1
            }
            let order = wet[n].filter { $0 != remainder } + [remainder]
            func packets(_ theta: Double) -> [FractionalGasTransport.Cell] {
                var remaining = updated[n].amount
                return order.map { member in
                    let packet: SIMD8<Double>
                    if member == remainder {
                        packet = remaining
                    } else {
                        var density = states[n]
                        for c in 0..<5 {
                            density[c] += theta * simd_dot(gradients[c], memberCentres[member] - centres[n])
                        }
                        packet = plan.memberFinalVolumes[member] * density
                    }
                    remaining -= packet
                    return .init(volume: plan.memberFinalVolumes[member], amount: packet)
                }
            }
            func admissible(_ proposal: [FractionalGasTransport.Cell]) -> Bool {
                (try? FractionalGasTransport.advance(
                    proposal, newVolumes: proposal.map(\.volume), transfers: [])) != nil
            }
            var proposed = packets(factor)
            if !admissible(proposed) {
                guard admissible(packets(0)) else { throw FractionalGasTransport.Failure.invalidState }
                var low = 0.0
                var high = factor
                for _ in 0..<40 {
                    let mid = (low + high) / 2
                    if admissible(packets(mid)) { low = mid } else { high = mid }
                }
                proposed = packets(0.99 * low)
                reduced += 1
            }
            for (member, cell) in zip(order, proposed) { amounts[member] = cell.amount }
        }
        let cells = amounts.indices.map {
            FractionalGasTransport.Cell(volume: plan.memberFinalVolumes[$0], amount: amounts[$0])
        }
        return Result(
            cells: try FractionalGasTransport.advance(
                cells,
                newVolumes: plan.memberFinalVolumes, transfers: []), limitedGroups: limited,
            positivityReducedGroups: reduced, rankDeficientGroups: deficient)
    }
}
