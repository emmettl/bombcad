import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// The GPU's elements that bend in their cracked concrete (`StructureModel.assumedStrainCracking`,
/// emmettl/bombcad-work#20 stage 2) against stage 1's gate G1: the same law per point as at the
/// centre, the CPU reference's elastic cantilever, and a reinforced section's moment against
/// curvature against fibre section analysis with BombCAD's own concrete law.
///
/// The static checks drive the GPU's element pass through a static solve (`GPUStatics`): each
/// evaluation restores the solver's state as last committed, sets every node's displacement (and
/// its velocity to the change over a one-second step), runs one substep and reads the elements'
/// forces on the nodes; Newton's method takes its steps from the CPU reference's tangent and
/// iterates on the GPU's residual until it vanishes.
@Suite("Cracked hex on the GPU", .gpuThreads)
struct CrackedHexGPUTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    // MARK: - The harness

    /// A body on the lattice of `mesh` whose element pass gives the forces of a static solve.
    final class GPUStatics {
        let solver: StructureSolver
        let mesh: CrackedHex.BoxMesh
        private var snapshot: [(MTLBuffer, Data)] = []
        private var committed: [Double]
        /// Why the last solve that failed did.
        var lastFailure = ""
        /// Elements switched in the committed state (the pool's count).
        private var switchedCount = 0

        init(solver: StructureSolver, mesh: CrackedHex.BoxMesh) {
            self.solver = solver
            self.mesh = mesh
            solver.gravity = 0
            solver.groundContact = false
            solver.contactMode = .off
            solver.stepOverride = 1
            committed = Array(repeating: 0, count: 3 * mesh.nodeCount)
            snapshot = Self.take(solver)
            switchedCount = solver.assumedStrainSummary?.switched ?? 0
        }

        static func take(_ solver: StructureSolver) -> [(MTLBuffer, Data)] {
            SolverCheckpoint.sharedBuffers(of: solver, within: StructureSolver.checkpointSubsystems).map {
                ($0.1, Data(bytes: $0.1.contents(), count: $0.1.length))
            }
        }

        /// The elements' forces on the nodes (3 per node of `mesh`) at displacements `u`, from the
        /// committed state.
        func forces(_ u: [Double]) -> [Double] {
            for (buffer, data) in snapshot {
                data.copyBytes(to: UnsafeMutableRawBufferPointer(start: buffer.contents(), count: data.count))
            }
            solver.mutateNodes { nodes in
                for i in 0...mesh.nx {
                    for j in 0...mesh.ny {
                        for k in 0...mesh.nz {
                            let n = solver.nodeIndex(i, j, k)
                            let m = 3 * mesh.node(i, j, k)
                            nodes[n].displacement = SIMD3(Float(u[m]), Float(u[m + 1]), Float(u[m + 2]))
                            nodes[n].velocity = SIMD3(
                                Float(u[m] - committed[m]), Float(u[m + 1] - committed[m + 1]),
                                Float(u[m + 2] - committed[m + 2]))
                        }
                    }
                }
            }
            let before = switchedCount
            solver.advance(steps: 1)
            if let summary = solver.assumedStrainSummary, summary.switched > before {
                // An element that switched holds its switch for the rest of the step, as the CPU
                // reference's solve does: the committed state takes it, its points the history it had.
                var newly: Set<[Int]> = []
                for e in mesh.elements where solver.isSwitched(e.i, e.j, e.k) {
                    newly.insert([e.i, e.j, e.k])
                }
                for (buffer, data) in snapshot {
                    data.copyBytes(
                        to: UnsafeMutableRawBufferPointer(start: buffer.contents(), count: data.count))
                }
                let already = Set(
                    mesh.elements.filter { solver.isSwitched($0.i, $0.j, $0.k) }.map { [$0.i, $0.j, $0.k] })
                solver.switchToAssumedStrain { i, j, k in
                    newly.contains([i, j, k]) && !already.contains([i, j, k])
                }
                snapshot = Self.take(solver)
                switchedCount = solver.assumedStrainSummary?.switched ?? 0
                return forces(u)
            }
            var force = Array(repeating: 0.0, count: 3 * mesh.nodeCount)
            for i in 0...mesh.nx {
                for j in 0...mesh.ny {
                    for k in 0...mesh.nz {
                        let f = solver.nodalForce(i, j, k)
                        for c in 0..<3 { force[3 * mesh.node(i, j, k) + c] = Double(f[c]) }
                    }
                }
            }
            return force
        }

        /// Keeps the state of the last evaluation, at `u`.
        func commit(_ u: [Double]) {
            snapshot = Self.take(solver)
            committed = u
            switchedCount = solver.assumedStrainSummary?.switched ?? 0
        }

        /// Which of `mesh`'s elements, in its order, the GPU has switched.
        var switchedFlags: [Bool] { mesh.elements.map { solver.isSwitched($0.i, $0.j, $0.k) } }

        /// Newton's method to equilibrium under `load` (on the free dofs) from the unknowns `x`, its
        /// steps from `shadow`'s tangent (the CPU reference following the same displacements),
        /// committing both when the GPU's residual is below `tolerance` of its largest nodal force.
        func solve(
            dofs: [CrackedHex.Dof], masters: Int, load: [Double], from start: [Double],
            shadow: inout CrackedHex.Assembly, tolerance: Double = 1e-4, iterations: Int = 300
        ) -> (unknowns: [Double], displacement: [Double], force: [Double])? {
            let (index, count) = CrackedHex.Assembly.numbering(dofs, masters: masters)
            let free = count - masters
            struct Trial {
                var x: [Double]
                var u: [Double]
                var force: [Double]
                var residual: [Double]
                var norm: Double
                var scale: Double
            }
            func trial(_ x: [Double]) -> Trial {
                let u = CrackedHex.Assembly.displacement(x, dofs: dofs, index: index, free: free)
                let force = forces(u)
                var residual = Array(repeating: 0.0, count: count)
                var scale = 0.0
                for d in force.indices {
                    scale = max(scale, abs(force[d]))
                    if let (i, c) = CrackedHex.Assembly.map(d, dofs: dofs, index: index, free: free) {
                        residual[i] += c * (load[d] + force[d])
                    }
                }
                let norm = residual.reduce(0.0) { max($0, abs($1)) }
                return Trial(x: x, u: u, force: force, residual: residual, norm: norm, scale: scale)
            }
            func tangent(at u: [Double], elastic: Bool = false) -> [Double] {
                let responses =
                    elastic
                    ? CrackedHex.Assembly(
                        elements: shadow.elements, connectivity: shadow.connectivity,
                        nodeCount: shadow.nodeCount
                    ).evaluate(Array(repeating: 0, count: u.count)).responses
                    : shadow.evaluate(u, switchNow: switchedFlags).responses
                var matrix = Array(repeating: 0.0, count: count * count)
                for (e, nodes) in shadow.connectivity.enumerated() {
                    let global = nodes.flatMap { n in (0..<3).map { 3 * n + $0 } }
                    let maps = global.map {
                        CrackedHex.Assembly.map($0, dofs: dofs, index: index, free: free)
                    }
                    for p in 0..<24 {
                        guard let (i, ci) = maps[p] else { continue }
                        for q in 0..<24 {
                            guard let (j, cj) = maps[q] else { continue }
                            matrix[count * i + j] += ci * cj * responses[e].tangent[24 * p + q]
                        }
                    }
                }
                return matrix
            }
            var current = trial(start)
            // Steps from the reference's tangent while they lower the residual; then from its
            // elastic stiffness, which the GPU's softer state lets converge, if more slowly.
            var elasticStiffness: Factored?
            let tracing = ProcessInfo.processInfo.environment["CRACKED_HEX_TRACE"] != nil
            for iteration in 0..<iterations {
                if tracing { print("  iteration \(iteration): residual \(current.norm) of \(current.scale)") }
                if current.norm <= tolerance * max(current.scale, 1e-30) {
                    // The last evaluation must be the one kept.
                    let accepted = trial(current.x)
                    commit(accepted.u)
                    shadow.states = shadow.evaluate(accepted.u, switchNow: switchedFlags).responses.map(
                        \.state)
                    return (accepted.x, accepted.u, accepted.force)
                }
                if let stiffness = elasticStiffness {
                    let step = stiffness.solve(current.residual)
                    current = trial((0..<count).map { current.x[$0] + step[$0] })
                    continue
                }
                guard let step = CrackedHex.solveDense(tangent(at: current.u), current.residual, count: count)
                else { return nil }
                var best: Trial?
                var fraction = 1.0
                for _ in 0..<4 {
                    let next = trial((0..<count).map { current.x[$0] + fraction * step[$0] })
                    if best == nil || next.norm < best!.norm { best = next }
                    if next.norm < current.norm { break }
                    fraction /= 2
                }
                if best!.norm < current.norm {
                    current = best!
                } else {
                    guard let factored = Factored(tangent(at: current.u, elastic: true), count: count) else {
                        return nil
                    }
                    elasticStiffness = factored
                }
            }
            lastFailure = "residual \(current.norm) of \(current.scale) after \(iterations) iterations"
            return nil
        }
    }

    /// A square matrix factored once by Gaussian elimination with partial pivoting, for the many
    /// solves of the elastic iterations.
    struct Factored {
        let count: Int
        var lu: [Double]
        var pivots: [Int]

        init?(_ matrix: [Double], count n: Int) {
            var factors = matrix
            var pivots = Array(0..<n)
            let ok = factors.withUnsafeMutableBufferPointer { a -> Bool in
                for c in 0..<n {
                    var pivot = c
                    for r in (c + 1)..<max(n, c + 1) where abs(a[n * r + c]) > abs(a[n * pivot + c]) {
                        pivot = r
                    }
                    if abs(a[n * pivot + c]) < 1e-300 { return false }
                    if pivot != c {
                        for k in 0..<n { a.swapAt(n * c + k, n * pivot + k) }
                        pivots.swapAt(c, pivot)
                    }
                    let diagonal = a[n * c + c]
                    for r in (c + 1)..<max(n, c + 1) {
                        let f = a[n * r + c] / diagonal
                        a[n * r + c] = f
                        if f == 0 { continue }
                        for k in (c + 1)..<n { a[n * r + k] -= f * a[n * c + k] }
                    }
                }
                return true
            }
            if !ok { return nil }
            count = n
            lu = factors
            self.pivots = pivots
        }

        func solve(_ rhs: [Double]) -> [Double] {
            let n = count
            var x = pivots.map { rhs[$0] }
            lu.withUnsafeBufferPointer { a in
                for r in 0..<n {
                    for k in 0..<r { x[r] -= a[n * r + k] * x[k] }
                }
                for r in stride(from: n - 1, through: 0, by: -1) {
                    for k in (r + 1)..<max(n, r + 1) { x[r] -= a[n * r + k] * x[k] }
                    x[r] /= a[n * r + r]
                }
            }
            return x
        }
    }

    // MARK: - The law per point

    /// One element strained uniformly through cracking, unloading, crushing and shear, switched to
    /// its eight points and not: under a uniform strain each point is the centre, so the two must
    /// give the same forces (BombCAD's law, evaluated once or eight times).
    @Test("Under a uniform strain the switched element's eight points give the centre's forces")
    func uniformStrain() throws {
        var material = StructureMaterial.concrete(
            name: "Test", compressiveStrength: 30e6, steel: .grade500)
        material.youngsModulus = 30e9
        material.poissonRatio = 0.2
        let h: Float = 0.1
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(h, h, 1 + h))
        func body(_ switched: Bool) throws -> StructureSolver {
            var model = StructureModel(solids: [cube], material: material, elementSize: h, fixedBase: false)
            model.reinforcement = [ReinforcementLayer(region: cube, ratio: SIMD3(0.01, 0.005, 0))]
            model.assumedStrainCracking = switched
            let solver = try StructureSolver(device: device, model: model)
            solver.gravity = 0
            solver.groundContact = false
            solver.stepOverride = 1
            if switched { #expect(solver.switchToAssumedStrain { _, _, _ in true } == 1) }
            return solver
        }
        let solvers = [try body(false), try body(true)]
        // Strain paths: stretch along x past cracking and back, squeeze along z past the peak,
        // then shear in the cracked state.
        let onset = material.tensileStrength / material.youngsModulus
        var path: [simd_float3x3] = []
        func gradient(_ xx: Float, _ zz: Float, _ xy: Float) -> simd_float3x3 {
            simd_float3x3(columns: (SIMD3(xx, xy, 0), SIMD3(xy, -0.2 * xx, 0), SIMD3(0, 0, zz)))
        }
        for n in 1...20 { path.append(gradient(Float(n) / 20 * 4 * onset, 0, 0)) }
        for n in 1...10 { path.append(gradient(4 * onset * (1 - Float(n) / 10), 0, 0)) }
        for n in 1...20 { path.append(gradient(0, -Float(n) / 20 * 0.003, 0)) }
        for n in 1...20 { path.append(gradient(2 * onset, -0.003, Float(n) / 20 * 6 * onset)) }
        var previous = simd_float3x3(0)
        var worst: Float = 0
        var scale: Float = 0
        for g in path {
            var forces: [[SIMD3<Float>]] = []
            for solver in solvers {
                solver.mutateNodes { nodes in
                    for a in 0..<8 {
                        let (i, j, k) = (a & 1, (a >> 1) & 1, (a >> 2) & 1)
                        let x = SIMD3(Float(i), Float(j), Float(k)) * h
                        nodes[solver.nodeIndex(i, j, k)].displacement = g * x
                        nodes[solver.nodeIndex(i, j, k)].velocity = (g - previous) * x
                    }
                }
                solver.advance(steps: 1)
                forces.append((0..<8).map { a in solver.nodalForce(a & 1, (a >> 1) & 1, (a >> 2) & 1) })
            }
            for a in 0..<8 {
                worst = max(worst, simd_length(forces[0][a] - forces[1][a]))
                scale = max(scale, simd_length(forces[0][a]))
            }
            previous = g
        }
        #expect(solvers[1].isSwitched(0, 0, 0))
        #expect(scale > 1000, "the path loads the element (\(scale) N)")
        #expect(
            worst <= 2e-5 * scale, "the switched element's forces off the centre's by \(worst) N of \(scale)")
    }

    // MARK: - One element against the CPU reference

    /// The GPU's forces on one elastic cube for each of 24 displacement fields (each node moved
    /// along each axis in turn) against the CPU reference's: today's element and the switched one.
    @Test(
        "One elastic element's forces match the CPU reference's, today's and switched",
        arguments: [false, true])
    func oneElement(switched: Bool) throws {
        let h = 0.1
        let mesh = CrackedHex.BoxMesh(nx: 1, ny: 1, nz: 1, h: h)
        let base = Float(1)
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, base), max: SIMD3(Float(h), Float(h), base + Float(h)))],
            material: Self.elastic(), elementSize: Float(h), fixedBase: false)
        model.assumedStrainCracking = switched
        let solver = try StructureSolver(device: device, model: model)
        if switched { #expect(solver.switchToAssumedStrain { _, _, _ in true } == 1) }
        let statics = GPUStatics(solver: solver, mesh: mesh)
        let element = CrackedHex.Element(
            geometry: mesh.geometry(0, 0, 0), law: .elastic(youngsModulus: 30e9, poissonRatio: 0.2),
            formulation: switched ? .assumedStrain : .today)
        let nodes = mesh.elementNodes(0, 0, 0)
        var worst = 0.0
        var scale = 0.0
        for column in 0..<24 {
            var local = Array(repeating: 0.0, count: 24)
            local[column] = 1e-6
            // A second node moved too, so that every pair of modes meets.
            local[(column * 7 + 5) % 24] -= 0.5e-6
            var u = Array(repeating: 0.0, count: 3 * mesh.nodeCount)
            for (a, n) in nodes.enumerated() {
                for c in 0..<3 { u[3 * n + c] = local[3 * a + c] }
            }
            let gpu = statics.forces(u)
            let cpu = element.evaluate(local, from: element.initialState).force
            for (a, n) in nodes.enumerated() {
                for c in 0..<3 {
                    // The GPU gives the force on the node, minus the internal force.
                    worst = max(worst, abs(gpu[3 * n + c] + cpu[3 * a + c]))
                    scale = max(scale, abs(cpu[3 * a + c]))
                }
            }
            if ProcessInfo.processInfo.environment["CRACKED_HEX_TRACE"] != nil {
                print(
                    "column \(column), switched \(switched): hourglass \(solver.hourglassForces(0, 0, 0)), stress \(solver.stress(0, 0, 0))"
                )
                print("column \(column): GPU \(nodes.flatMap { n in (0..<3).map { gpu[3 * n + $0] } })")
                print("           CPU \(cpu.map { -$0 })")
            }
        }
        // Within what the parabola's curvature at the points' strains (up to 0.2% of the peak's) and
        // the large-strain kinematics leave.
        #expect(
            worst <= 2e-3 * scale,
            "switched \(switched): forces off the CPU reference's by \(worst) of \(scale) N")
    }

    // MARK: - The elastic cantilever

    /// Concrete so strong in tension that it never cracks, and squeezed by these checks to a
    /// thousandth of its strain at peak, where its parabola is within a twentieth of a per cent of
    /// elastic. (A huge compressive strength would leave the parabola's strains below the float's
    /// resolution at 1 and its stress in steps of a tenth of a megapascal.)
    static func elastic() -> StructureMaterial {
        var material = StructureMaterial.concrete(name: "Elastic", compressiveStrength: 30e6)
        material.youngsModulus = 30e9
        material.poissonRatio = 0.2
        material.tensileStrength = 1e12
        return material
    }

    /// The tip deflection over beam theory, as `CrackedHex.cantilever` gives it, of the GPU's
    /// elements: today's, or switched to their eight points from the start.
    func cantilever(elementsThroughDepth n: Int, switched: Bool) throws -> Double {
        let depth = 0.3
        let slenderness = 10
        let h = depth / Double(n)
        let mesh = CrackedHex.BoxMesh(nx: slenderness * n, ny: 1, nz: n, h: h)
        let base = (1 / Float(h)).rounded() * Float(h)
        var model = StructureModel(
            solids: [
                Box(
                    min: SIMD3(0, 0, base),
                    max: SIMD3(Float(Double(slenderness) * depth), Float(h), base + Float(depth)))
            ], material: Self.elastic(), elementSize: Float(h), fixedBase: false)
        model.assumedStrainCracking = switched
        let solver = try StructureSolver(device: device, model: model)
        #expect(solver.elementCount == mesh.elements.count)
        if switched { solver.switchToAssumedStrain { _, _, _ in true } }
        let statics = GPUStatics(solver: solver, mesh: mesh)
        // The CPU reference's elastic tangent.
        let law = CrackedHex.Law.elastic(youngsModulus: 30e9, poissonRatio: 0.2)
        var shadow = CrackedHex.Assembly(
            elements: mesh.elements.map {
                CrackedHex.Element(
                    geometry: mesh.geometry($0.i, $0.j, $0.k), law: law,
                    formulation: switched ? .assumedStrain : .today)
            },
            connectivity: mesh.elements.map { mesh.elementNodes($0.i, $0.j, $0.k) }, nodeCount: mesh.nodeCount
        )
        var dofs = Array(repeating: CrackedHex.Dof.free, count: 3 * mesh.nodeCount)
        var load = Array(repeating: 0.0, count: 3 * mesh.nodeCount)
        // Small enough that the GPU's large-strain elements turn the tip by a ten-thousandth.
        let p = 100.0
        for j in 0...mesh.ny {
            for k in 0...mesh.nz {
                for c in 0..<3 { dofs[3 * mesh.node(0, j, k) + c] = .fixed(0) }
                let share =
                    (j == 0 || j == mesh.ny ? 0.5 : 1) * (k == 0 || k == mesh.nz ? 0.5 : 1) / Double(n)
                load[3 * mesh.node(mesh.nx, j, k) + 2] = -p * share
            }
        }
        let (_, count) = CrackedHex.Assembly.numbering(dofs, masters: 0)
        let solution = statics.solve(
            dofs: dofs, masters: 0, load: load, from: Array(repeating: 0, count: count), shadow: &shadow)
        let solved = try #require(solution, "\(n) through, switched \(switched): \(statics.lastFailure)")
        let work = zip(load, solved.displacement).reduce(0.0) { $0 + $1.0 * $1.1 }
        // Beam theory's deflection is linear in the load (the reference's is for 100 kN).
        let reference = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .today)
        return work / p / (reference.beamTheory * p / 1e5)
    }

    @Test("The elastic cantilever on the GPU matches the CPU reference", arguments: [1, 2, 4])
    func cantilever(elementsThroughDepth n: Int) throws {
        let today = try cantilever(elementsThroughDepth: n, switched: false)
        let switched = try cantilever(elementsThroughDepth: n, switched: true)
        let referenceToday = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .today).ratio
        let referenceSwitched = CrackedHex.cantilever(elementsThroughDepth: n, formulation: .assumedStrain)
            .ratio
        print(
            "cantilever, \(n) through: GPU today's \(today), switched \(switched); CPU \(referenceToday), "
                + "\(referenceSwitched)")
        #expect(abs(today / referenceToday - 1) < 0.01, "today's: GPU \(today), CPU \(referenceToday)")
        #expect(
            abs(switched / referenceSwitched - 1) < 0.01,
            "switched: GPU \(switched), CPU \(referenceSwitched)")
        if n >= 2 { #expect(abs(switched - 1) < 0.05, "\(n) through: \(switched) of beam theory") }
    }

    // MARK: - A reinforced section in bending

    /// BombCAD's concrete and bars along one fibre, from the element kernel's own parameters
    /// (`StructureSolver.parameters`): the uniaxial laws of Structure.metal with no rate, Poisson
    /// effect or confinement, for the section analysis.
    struct Fibre {
        var history: Float = 0  // largest tensile strain
        var residual: Float = 0
        var crush: Float = 0

        static func tensionEnvelope(_ history: Float, _ m: MaterialParameters) -> Float {
            history <= m.crackOnset
                ? m.youngsModulus * history
                : m.tensileStrength * exp(-(history - m.crackOnset) / m.crackSoftening)
        }

        static func compressionEnvelope(_ history: Float, _ m: MaterialParameters) -> Float {
            let strength = m.compressiveStrength
            if history <= m.crushPeak {
                let exponent = m.youngsModulus * m.crushPeak / strength
                return strength * (1 - pow(max(1 - history / m.crushPeak, 0), exponent))
            }
            let fraction = min(max((history - m.crushPeak) / (m.crushEnd - m.crushPeak), 0), 1)
            return strength + (0.2 * strength - strength) * fraction
        }

        /// The stress at strain `e`, from this history, which it updates.
        mutating func stress(_ e: Float, _ m: MaterialParameters) -> Float {
            history = max(history, e)
            let open: Float =
                history <= m.crackOnset
                ? 0 : m.crackResidual * (history - Self.tensionEnvelope(history, m) / m.youngsModulus)
            residual = max(residual, min(open, e))
            let squeeze = residual - e
            crush = max(crush, squeeze)
            if squeeze <= 0 {
                guard history > 0 else { return 0 }
                return Self.tensionEnvelope(history, m) * max(e - residual, 0) / (history - residual)
            }
            let envelope = Self.compressionEnvelope(crush, m)
            if squeeze >= crush { return -envelope }
            let ratio = crush / m.crushPeak
            let plastic = min(
                max(m.crushPeak * (0.145 * ratio * ratio + 0.13 * ratio), 0),
                max(crush - envelope / m.youngsModulus, 0))
            return squeeze <= plastic ? 0 : -envelope * (squeeze - plastic) / (crush - plastic)
        }

        /// The bars' stress at strain `e` from plastic strain `plastic`, which it updates, as
        /// `smearedBar` does on the monotonic curve.
        static func bar(_ e: Float, plastic: inout Float, _ m: MaterialParameters) -> Float {
            let strains = withUnsafeBytes(of: m.steelStrain) { Array($0.bindMemory(to: Float.self)) }
            let stresses = withUnsafeBytes(of: m.steelStress) { Array($0.bindMemory(to: Float.self)) }
            var slope: Float = 0
            var yield = stresses[Int(m.steelPoints) - 1]
            for n in 1..<Int(m.steelPoints) where abs(plastic) <= strains[n] {
                slope = (stresses[n] - stresses[n - 1]) / max(strains[n] - strains[n - 1], 1e-9)
                yield = stresses[n - 1] + slope * (abs(plastic) - strains[n - 1])
                break
            }
            var stress = m.steelModulus * (e - plastic)
            if abs(stress) > yield {
                let increment = (abs(stress) - yield) / max(m.steelModulus + slope, 0.1 * m.steelModulus)
                plastic += stress > 0 ? increment : -increment
                stress = m.steelModulus * (e - plastic)
            }
            return stress
        }
    }

    /// Moment per unit width against curvature by fibre section analysis with `Fibre`.
    static func sectionAnalysis(
        depth: Float, barHeight: Float, barArea: Float, curvatures: [Double], m: MaterialParameters,
        fibres: Int = 3000
    ) -> [Double] {
        let dz = depth / Float(fibres)
        let middle = depth / 2
        var committed = [Fibre](repeating: Fibre(), count: fibres)
        var barPlastic: Float = 0
        var reference: Float = 0
        var moments: [Double] = []
        for kappa in curvatures.map({ Float($0) }) {
            func evaluate(_ e0: Float) -> (force: Double, moment: Double, fibres: [Fibre], plastic: Float) {
                var force = 0.0
                var moment = 0.0
                var trial = committed
                for f in 0..<fibres {
                    let z = (Float(f) + 0.5) * dz
                    let s = trial[f].stress(e0 - kappa * (z - middle), m)
                    force += Double(s * dz)
                    moment -= Double(s * dz * (z - middle))
                }
                var plastic = barPlastic
                let s = Fibre.bar(e0 - kappa * (barHeight - middle), plastic: &plastic, m)
                force += Double(s * barArea)
                moment -= Double(s * barArea * (barHeight - middle))
                return (force, moment, trial, plastic)
            }
            // Bisection on the mid-depth strain: the axial force grows with it.
            var low = reference - 0.01
            var high = reference + 0.01
            for _ in 0..<60 {
                let mid = 0.5 * (low + high)
                if evaluate(mid).force > 0 { high = mid } else { low = mid }
            }
            reference = 0.5 * (low + high)
            let result = evaluate(reference)
            committed = result.fibres
            barPlastic = result.plastic
            moments.append(result.moment)
        }
        return moments
    }

    /// Stage 1's curvatures, per metre: to 0.004 by 0.0002, then to 0.06 by 0.002.
    static let curvatures: [Double] =
        stride(from: 0.0002, through: 0.004, by: 0.0002).map { $0 }
        + stride(from: 0.006, through: 0.06, by: 0.002).map { $0 }

    /// Stage 1's section (`CrackedHex.ReinforcedSection.standard`) as BombCAD's material: 300 mm
    /// deep, 1% steel 45 mm above the tension face, 30 MPa concrete with E 30 GPa, f_t 2.9 MPa and
    /// G_f 140 N/m, its cracks banded over one element, without rate, Poisson effect or
    /// confinement.
    static func sectionMaterial() -> StructureMaterial {
        var material = StructureMaterial.concrete(
            name: "Section", compressiveStrength: 30e6, steel: .grade500)
        material.youngsModulus = 30e9
        material.poissonRatio = 0
        material.tensileStrength = 2.9e6
        material.fractureEnergy = 140
        material.crackSpacing = 0
        material.confinementCoefficient = 0
        return material
    }

    /// The GPU's moment per unit width at each curvature of a length of the section two elements
    /// long and one wide, `n` through its depth, its end faces turned about mid-depth with a shared
    /// axial shift that leaves no axial force (as `CrackedHex.momentCurvature`), and how many of its
    /// elements switched.
    func gpuMomentCurvature(elementsThroughDepth n: Int, option: Bool) throws -> (
        moments: [Double], switched: Int
    ) {
        let section = CrackedHex.ReinforcedSection.standard
        let h = section.depth / Double(n)
        let mesh = CrackedHex.BoxMesh(nx: 2, ny: 1, nz: n, h: h)
        let base = (1 / Float(h)).rounded() * Float(h)
        let box = Box(min: SIMD3(0, 0, base), max: SIMD3(Float(2 * h), Float(h), base + Float(section.depth)))
        var model = StructureModel(
            solids: [box], material: Self.sectionMaterial(), elementSize: Float(h), fixedBase: false)
        var band = box
        band.min.z = base + Float(section.barHeight - h / 2)
        band.max.z = base + Float(section.barHeight + h / 2)
        model.reinforcement = [
            ReinforcementLayer(region: band, ratio: SIMD3(Float(section.barAreaPerWidth / h), 0, 0))
        ]
        model.assumedStrainCracking = option
        let solver = try StructureSolver(device: device, model: model)
        let statics = GPUStatics(solver: solver, mesh: mesh)
        // The CPU reference's elements give the steps' tangent.
        var concrete = section.concrete
        concrete.bandWidth = h
        let area = section.barAreaPerWidth * h
        var elements: [CrackedHex.Element] = []
        for e in mesh.elements {
            var bars: [CrackedHex.Bar] = []
            let bottom = Double(e.k) * h
            if section.barHeight >= bottom && section.barHeight < bottom + h {
                let zeta = 2 * (section.barHeight - bottom) / h - 1
                bars.append(CrackedHex.Bar(axis: 0, area: area, position: SIMD3(0, 0, zeta), spreadAcross: 1))
            }
            elements.append(
                CrackedHex.Element(
                    geometry: mesh.geometry(e.i, e.j, e.k), law: .concrete(concrete),
                    formulation: option ? .cracked : .today, steel: section.steel, bars: bars))
        }
        var shadow = CrackedHex.Assembly(
            elements: elements, connectivity: mesh.elements.map { mesh.elementNodes($0.i, $0.j, $0.k) },
            nodeCount: mesh.nodeCount)
        let length = 2 * h
        let middle = section.depth / 2
        func dofs(_ kappa: Double) -> [CrackedHex.Dof] {
            let theta = kappa * length / 2
            var dofs = Array(repeating: CrackedHex.Dof.free, count: 3 * mesh.nodeCount)
            for i in 0...mesh.nx {
                for j in 0...mesh.ny {
                    for k in 0...mesh.nz {
                        let node = mesh.node(i, j, k)
                        dofs[3 * node + 1] = .fixed(0)
                        guard i == 0 || i == mesh.nx else { continue }
                        let side: Double = i == 0 ? -1 : 1
                        let z = Double(k) * h - middle
                        dofs[3 * node] = .linked(base: -side * theta * z, master: 0, coefficient: side)
                        dofs[3 * node + 2] = .fixed(0)
                    }
                }
            }
            return dofs
        }
        let load = Array(repeating: 0.0, count: 3 * mesh.nodeCount)
        let (_, count) = CrackedHex.Assembly.numbering(dofs(0), masters: 1)
        var x = Array(repeating: 0.0, count: count)
        var moments: [Double] = []
        var reached = 0.0
        steps: for target in Self.curvatures {
            var pending = [target]
            while let kappa = pending.last {
                let saved = shadow.states
                if let solved = statics.solve(
                    dofs: dofs(kappa), masters: 1, load: load, from: x, shadow: &shadow)
                {
                    x = solved.unknowns
                    reached = kappa
                    pending.removeLast()
                    if pending.isEmpty {
                        var moment = 0.0
                        for j in 0...mesh.ny {
                            for k in 0...mesh.nz {
                                // The internal force is minus the elements' force on the node.
                                moment +=
                                    solved.force[3 * mesh.node(mesh.nx, j, k)] * (Double(k) * h - middle)
                            }
                        }
                        moments.append(moment / h)
                    }
                } else {
                    shadow.states = saved
                    guard pending.count < 8 else { break steps }
                    pending.append((reached + kappa) / 2)
                }
            }
        }
        if moments.count < Self.curvatures.count {
            print(
                "section, \(n) through, option \(option): stopped at \(reached) per metre, \(statics.lastFailure)"
            )
        }
        return (moments, solver.assumedStrainSummary?.switched ?? 0)
    }

    @Test(
        "A reinforced section's moment–curvature on the GPU matches section analysis with BombCAD's law within 5%",
        arguments: [4, 6, 12])
    func momentCurvature(elementsThroughDepth n: Int) throws {
        let section = CrackedHex.ReinforcedSection.standard
        let h = Float(section.depth) / Float(n)
        let m = StructureSolver.parameters(for: Self.sectionMaterial(), elementSize: h)
        let reference = Self.sectionAnalysis(
            depth: Float(section.depth), barHeight: Float(section.barHeight),
            barArea: Float(section.barAreaPerWidth),
            curvatures: Self.curvatures, m: m)
        let cracked = try gpuMomentCurvature(elementsThroughDepth: n, option: true)
        #expect(cracked.moments.count == Self.curvatures.count, "the static solve stopped")
        let crackingCurvature = 2 * Double(m.crackOnset) / section.depth
        func worst(_ moments: [Double]) -> Double {
            var worst = 0.0
            for (i, kappa) in Self.curvatures.enumerated()
            where kappa >= 2 * crackingCurvature && i < moments.count {
                worst = max(worst, abs(moments[i] / reference[i] - 1))
            }
            return worst
        }
        print(
            "section, \(n) through: switched \(cracked.switched) of \(2 * n); worst off section analysis "
                + "\(worst(cracked.moments)) (\(cracked.moments.count) curvatures)")
        #expect(cracked.switched > 0)
        #expect(
            worst(cracked.moments) < 0.05, "\(n) through: off section analysis by \(worst(cracked.moments))")
        // Today's element runs strong where the compression zone is thinner than an element (13% on
        // 4 through, 7% on 6, as the CPU reference found; 2% on 12).
        if n <= 6 {
            let today = try gpuMomentCurvature(elementsThroughDepth: n, option: false)
            #expect(
                worst(today.moments) > 0.05,
                "today's \(worst(today.moments)), switched \(worst(cracked.moments))")
            print("  today's element: worst off section analysis \(worst(today.moments))")
        }
    }
}
