import Testing
import simd

@testable import BlastCore

@Suite("Limited moving gas reconstruction")
struct LimitedMovingReconstructionTests {
    /// A 3³ group stencil; the middle unit cube has two half-width final members.
    /// This tests redistribution independently of box clipping and the flux integrator.
    private func plan(_ cells: [FractionalGasTransport.Cell], connected: Bool = true)
        -> MovingConnectedGasGroups.Plan
    {
        let centres: [SIMD3<Double>] = (0..<27).map { n in
            let x = Double(n % 3) + 0.5
            let y = Double((n / 3) % 3) + 0.5
            let z = Double(n / 9) + 0.5
            return SIMD3(x, y, z)
        }
        var members = (0..<27).map { [$0] }
        members[13] = [13, 27]
        var points = centres
        points[13].x -= 0.25
        points.append(centres[13] + SIMD3(0.25, 0, 0))
        var volumes = [Double](repeating: 1, count: 28)
        volumes[13] = 0.5
        volumes[27] = 0.5
        var faces: [ConnectedGasGroups.Face] = []
        for n in 0..<27 {
            for axis in 0..<3 where [n % 3, (n / 3) % 3, n / 9][axis] < 2 {
                let other = n + [1, 3, 9][axis]
                var normal = SIMD3<Double>.zero
                normal[axis] = 1
                faces.append(
                    .init(
                        a: n, b: other, area: 1, normal: normal,
                        centroid: (centres[n] + centres[other]) / 2))
            }
        }
        return .init(
            members: members, cellToGroup: Array(0..<27) + [13], cells: cells,
            finalVolumes: [Double](repeating: 1, count: 27), memberFinalVolumes: volumes,
            faces: faces, boundaries: [], duration: 1, velocity: .zero,
            oldCentres: centres, finalCentres: centres, memberFinalCentres: points,
            finalFaces: connected ? faces : [], maximumAreaResidual: 0,
            maximumMomentResidual: 0, maximumVolumeResidual: 0)
    }
    private func total(_ cells: [FractionalGasTransport.Cell]) -> SIMD8<Double> {
        cells.reduce(.zero) { $0 + $1.amount }
    }

    @Test("Final scatter reproduces affine conserved averages and preserves every packet lane")
    func affineScatter() throws {
        func density(_ point: SIMD3<Double>) -> Double { 1 + 0.1 * point.x + 0.05 * point.y - 0.02 * point.z }
        let cells = (0..<27).map { n in
            let point = SIMD3<Double>(Double(n % 3) + 0.5, Double((n / 3) % 3) + 0.5, Double(n / 9) + 0.5)
            return FractionalGasTransport.Cell(
                volume: 1, density: density(point), velocity: SIMD3(2, -1, 0.5), pressure: 101325)
        }
        let p = plan(cells)
        let r = try LimitedMovingGroupScatter.scatter(p, updated: cells)
        for n in [13, 27] {
            #expect(abs(r.cells[n].amount[0] / r.cells[n].volume - density(p.memberFinalCentres![n])) < 1e-13)
            #expect(abs(r.cells[n].pressure() / 101325 - 1) < 1e-13)
        }
        let error = total(r.cells) - total(cells)
        for component in 0..<8 { #expect(abs(error[component]) < 1e-8) }
        #expect(r.positivityReducedGroups == 0 && r.rankDeficientGroups == 0)
    }

    @Test("Nonlinear Euler positivity reduces slopes while conserving mass, momentum and energy")
    func positivity() throws {
        var cells = [FractionalGasTransport.Cell](
            repeating: .init(volume: 1, amount: SIMD8(1, 0, 0, 0, 1, 0, 0, 0)), count: 27)
        cells[13] = .init(volume: 1, amount: SIMD8(1, 0, 0, 0, 0.01, 0, 0, 0))
        cells[12] = .init(volume: 1, amount: SIMD8(1, -1.4, 0, 0, 1, 0, 0, 0))
        cells[14] = .init(volume: 1, amount: SIMD8(1, 1.4, 0, 0, 1, 0, 0, 0))
        let r = try LimitedMovingGroupScatter.scatter(plan(cells), updated: cells)
        #expect(r.positivityReducedGroups == 1)
        #expect(r.cells.allSatisfy { $0.pressure() > 0 })
        #expect(abs(r.cells[13].velocity.x) > 0 && abs(r.cells[13].velocity.x) < 0.35)
        let error = total(r.cells) - total(cells)
        for component in 0..<8 { #expect(abs(error[component]) < 1e-10) }
    }

    @Test("Insufficient final neighbours fall back to constant conservative splitting")
    func rankDeficient() throws {
        let cells = [FractionalGasTransport.Cell](
            repeating: .init(volume: 1, density: 1.225, pressure: 101325), count: 27)
        let r = try LimitedMovingGroupScatter.scatter(plan(cells, connected: false), updated: cells)
        #expect(r.rankDeficientGroups == 1)
        #expect(r.cells[13].amount == 0.5 * cells[13].amount)
        #expect(r.cells[27].amount == 0.5 * cells[13].amount)
    }

    @Test("Old gas centroids and exterior stencil points reproduce interior affine face traces")
    func faceTraces() throws {
        let domain = try ExperimentalMovingGroupsStudy.domain(
            h: 0.4, angle: 0.23,
            start: 0, duration: 0.000002, reconstruct: true)
        let p = domain.plan
        var centres = p.oldCentres!
        func state(_ point: SIMD3<Double>, _ volume: Double = 1) -> FractionalGasTransport.Cell {
            .init(
                volume: volume, density: 1.225 + 0.02 * point.x - 0.01 * point.y + 0.03 * point.z,
                velocity: p.velocity, pressure: 101325)
        }
        var cells = p.cells.indices.map { state(centres[$0], p.cells[$0].volume) }
        var faces = p.faces
        for boundary in p.boundaries where boundary.geometry.owner == 0 {
            let b = boundary.geometry
            let point = centres[b.cell] - 2 * simd_dot(centres[b.cell] - b.centroid, b.normal) * b.normal
            faces.append(
                .init(a: b.cell, b: cells.count, area: b.area, normal: b.normal, centroid: b.centroid))
            centres.append(point)
            cells.append(state(point))
        }
        let geometry = try LimitedGroupedGasFlux.Geometry(
            centres: centres, faces: faces,
            boundaries: p.boundaries.filter { $0.geometry.owner == 1 }.map(\.geometry))
        let traces = try geometry.traces(cells)
        var checked = 0
        for (f, trace) in zip(faces, traces.faces)
        where f.b < p.cells.count && all(centres[f.a] .< SIMD3<Double>(repeating: 0.4)) {
            let expected = state(f.centroid).amount[0]
            #expect(abs(trace.leftState!.amount[0] - expected) < 1e-12)
            checked += 1
        }
        #expect(checked > 0)
    }

    @Test("Limited original-speed windows preserve uniform gas through changing groups")
    func uniformWindow() throws {
        let rows = try ExperimentalMovingTrajectoryStudy.run(
            cellSizes: [0.2],
            duration: 0.000064, velocityScale: 1, nearCrossing: true, limited: true)
        for r in rows {
            let f = r.frames.last!
            #expect(r.reconstruction == "limited")
            #expect(
                f.dryToWetCells == r.referenceDryToWetCells && f.wetToDryCells == r.referenceWetToDryCells)
            #expect(f.maximumRelativeDensityError < 1e-9 && f.maximumRelativePressureError < 1e-9)
            #expect(f.maximumVelocityError < 1e-7)
            #expect(abs(f.energyBudgetResidual) < 1e-6)
        }
    }

    @Test("Limited advection improves spatial accuracy while retaining gas and wall budgets")
    func convergence() throws {
        let rows = try ExperimentalMovingEntropyStudy.run(
            cellSizes: [0.4, 0.2], rotations: [0], cfls: [0.2], limited: true)
        #expect(rows[0].frames.last!.transport!.relativeDensityL1 < 0.1)
        #expect(rows[1].frames.last!.transport!.relativeDensityL1 < 0.05)
        #expect(
            rows[1].frames.last!.transport!.relativeDensityL1
                < rows[0].frames.last!.transport!.relativeDensityL1)
        for r in rows {
            for f in r.frames {
                #expect(f.maximumRelativePressureError < 1e-9 && f.maximumVelocityError < 1e-7)
                #expect(abs(f.massBudgetResidual) < 1e-10 && abs(f.energyBudgetResidual) < 1e-6)
                #expect(simd_length(f.momentumBudgetResidual) < 1e-8)
                #expect(f.minimumPressure > 0 && f.transport!.minimumDensity > 0)
                #expect(abs(f.impulseWorkResidual) < 1e-9)
            }
        }
    }
}
