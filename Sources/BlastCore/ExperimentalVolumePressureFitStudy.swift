import simd

/// Read-only wider-stencil comparisons. Only the error audit receives the known field;
/// the fits use actual group averages and geometric moments without analytic gradients.
enum ExperimentalVolumePressureFitStudy {
    static func evaluate(
        plan: MovingConnectedGasGroups.Plan, body: RigidBoxBody, h: Double,
        traces: [MovingGroupedGasFlux.InitialWallTrace], reference: BoxSurfacePressureReference.Load,
        pressure: (SIMD3<Double>) -> Double
    ) throws -> ExperimentalInitialWallTraceStudy.VolumeFitDiagnostics {
        let centres = plan.oldCentres!
        var adjacency = [Set<Int>](repeating: [], count: plan.cells.count)
        for face in plan.faces {
            adjacency[face.a].insert(face.b)
            adjacency[face.b].insert(face.a)
        }
        let wallGroups = Set(traces.map(\.cell)).sorted()
        var stencils: [Int: [Int]] = [:]
        var needed = Set(wallGroups)
        for group in wallGroups {
            var stencil = adjacency[group]
            for neighbour in adjacency[group] { stencil.formUnion(adjacency[neighbour]) }
            stencil.remove(group)
            stencils[group] = stencil.sorted()
            needed.formUnion(stencil)
        }
        let geometry = FractionalBoxGeometry(body)
        let count = Int((2 / h).rounded())
        var samples: [Int: FiniteVolumePressureFit.Sample] = [:]
        var maximumResidual = 0.0
        for group in needed.sorted() {
            var volume = 0.0
            var first = SIMD3<Double>.zero
            var second = FiniteVolumePressureFit.zero
            for member in plan.members[group] {
                let lower =
                    h
                    * SIMD3<Double>(
                        Double(member % count), Double((member / count) % count),
                        Double(member / (count * count)))
                for node in geometry.gasQuadrature(lower: lower, cellSize: h) {
                    let offset = node.point - centres[group]
                    volume += node.weight
                    first += node.weight * offset
                    second +=
                        node.weight
                        * simd_double3x3(
                            columns: (offset * offset.x, offset * offset.y, offset * offset.z))
                }
            }
            guard volume.isFinite && volume > 0 else {
                throw ExperimentalInitialWallTraceStudy.Failure.invalidReference
            }
            let residual = max(
                abs(volume - plan.cells[group].volume) / (h * h * h * Double(plan.members[group].count)),
                simd_length(first) / (volume * h))
            maximumResidual = max(maximumResidual, residual)
            guard residual < 1e-8 else { throw ExperimentalInitialWallTraceStudy.Failure.invalidReference }
            samples[group] = .init(
                centre: centres[group], covariance: (1 / volume) * second,
                average: plan.cells[group].pressure() - 101325)
        }
        let kinds = ["twoRingLinear", "pointQuadratic", "volumeQuadratic"]
        var fits: [String: [Int: FiniteVolumePressureFit.Fit]] = [:]
        for kind in kinds {
            fits[kind] = Dictionary(
                uniqueKeysWithValues: wallGroups.map { group in
                    (
                        group,
                        FiniteVolumePressureFit.fit(
                            cell: samples[group]!, neighbours: stencils[group]!.map { samples[$0]! },
                            scale: h,
                            quadratic: kind != "twoRingLinear", volumeAware: kind == "volumeQuadratic")
                    )
                })
        }
        let area = traces.reduce(0) { $0 + $1.area }
        var modes: [ExperimentalInitialWallTraceStudy.DiagnosticMode] = []
        for kind in kinds {
            var force = SIMD3<Double>.zero
            var torque = SIMD3<Double>.zero
            var error = 0.0
            var scale = 0.0
            var minimum = Double.infinity
            var maximum = -Double.infinity
            var negative = 0.0
            var outside = 0.0
            var nonpositive = 0
            for trace in traces {
                let fit = fits[kind]![trace.cell]!
                let value = fit.value(at: trace.point)
                let point = trace.point - trace.time * plan.velocity
                let exact = pressure(point)
                let packet = trace.area * value * trace.normal
                force += packet
                torque += simd_cross(point - body.position, packet)
                error += trace.area * abs(value - exact)
                scale += trace.area * exact
                minimum = min(minimum, 101325 + value)
                maximum = max(maximum, 101325 + value)
                if 101325 + value <= 0 { nonpositive += 1 }
                if value < -1e-5 { negative += trace.area }
                if value < fit.lower - 1e-5 || value > fit.upper + 1e-5 { outside += trace.area }
            }
            modes.append(
                .init(
                    kind: kind,
                    loads: .init(
                        force: force, torque: torque, power: simd_dot(plan.velocity, force),
                        relativeForceError: simd_distance(force, reference.force)
                            / simd_length(reference.force),
                        relativeTorqueError: simd_distance(torque, reference.torque)
                            / simd_length(reference.torque),
                        relativePressureL1: error / scale),
                    minimumPressure: minimum, maximumPressure: maximum,
                    nonpositivePressureSamples: nonpositive,
                    negativeExcessAreaFraction: negative / area, outsideStencilAreaFraction: outside / area))
        }
        return .init(
            modes: modes,
            quadraticFallbackAreaFraction: traces.reduce(0) {
                $0 + (fits["volumeQuadratic"]![$1.cell]!.degree < 2 ? $1.area : 0)
            } / area,
            pointQuadraticFallbackAreaFraction: traces.reduce(0) {
                $0 + (fits["pointQuadratic"]![$1.cell]!.degree < 2 ? $1.area : 0)
            } / area,
            linearFallbackAreaFraction: traces.reduce(0) {
                $0 + (fits["twoRingLinear"]![$1.cell]!.degree < 1 ? $1.area : 0)
            } / area,
            meanStencilSize: traces.reduce(0) {
                $0 + $1.area * Double(fits["volumeQuadratic"]![$1.cell]!.stencilSize)
            } / area,
            maximumMomentResidual: maximumResidual)
    }
}
