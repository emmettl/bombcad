import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Paths of the solid structure solver that no other test reaches: settling's restart and its
/// guards, soft ground on the terrain, and the load the air puts on a structure's cut cells.
@Suite("Solid structure solver: untested paths", .gpuThreads)
struct StructureSolverGapTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// The cantilever of `SettleTests`: 1.75 m long, 100 mm thick, clamped at its root; no charge.
    private func cantilever() -> Scenario {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0.25, 0.5, 1.0), max: SIMD3(2.0, 0.6, 1.1))],
            material: .elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2), elementSize: 0.05,
            fixedBase: false)
        model.supports = [Box(min: SIMD3(0.2, 0.4, 0.9), max: SIMD3(0.5, 0.7, 1.2))]
        return Scenario(
            name: "Cantilever", domainSize: SIMD3(2.5, 1.0, 2.0), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(2.2, 0.5, 0.5)), structure: model)
    }

    /// The tip's vertical displacement at the free end's middle node.
    private func tip(_ structure: StructureSolver) -> Float {
        structure.displacement(structure.ex, structure.ey / 2, structure.ez / 2).z
    }

    /// `BlastSolver.restart()` resets each body (`StructuralBody.reset`), which must forget the
    /// settled shape (`StructureSolver.settledDisplacements`) along with the settlements, so that
    /// a rerun settles afresh rather than measuring its deflections from the old run's sag. The
    /// cantilever then settles a second time to the same sag, since it starts from the same state.
    @Test("After a restart a settled body starts undeformed, and settles again to the same sag")
    func restartSettlesAgain() throws {
        let solver = try BlastSolver(device: device, scenario: cantilever(), cellSize: 0.25)
        let structure = try #require(solver.structure)
        solver.settleStructures()
        #expect(try #require(solver.settlements.first).settled)
        let firstSag = structure.summary().selfWeightSag
        let firstTip = tip(structure)
        #expect(structure.settledDisplacements != nil && firstSag > 0)

        solver.restart()
        #expect(solver.settlements.isEmpty && !solver.structuresSettled)
        #expect(structure.settledDisplacements == nil)
        #expect(structure.summary().selfWeightSag == 0 && tip(structure) == 0)

        solver.settleStructures()
        let again = try #require(solver.settlements.first)
        #expect(solver.settlements.count == 1 && again.settled)
        #expect(structure.time == 0 && solver.time == 0)
        // The two settles run the same kernels from the same state. Measured on the Studio, 19 October 2026: the tip (0.87 mm)
        // and the sag agree to every digit printed; 1e-5 allows for an order-dependent reduction.
        #expect(
            abs(tip(structure) - firstTip) <= 1e-5 * abs(firstTip), "tip \(tip(structure)) vs \(firstTip)")
        #expect(abs(structure.summary().selfWeightSag - firstSag) <= 1e-5 * firstSag)
    }

    /// `settleStructures()` leaves alone a body whose motion the scene sets
    /// (`StructuralBody.hasSetMotion`: a node with bit 3 or bit 6) and one no longer as loaded
    /// (`StructuralBody.isAsLoaded`: a node already moving). Settling either would overwrite what
    /// the scene asked for, so neither gets a settlement nor a settled shape, though the solver
    /// still counts settling as done.
    @Test("A body with motion set by the scene, or already moving, is not settled")
    func guardsLeaveBodiesAlone() throws {
        func check(_ prepare: (StructureSolver) -> Void, _ label: String) throws {
            let solver = try BlastSolver(device: device, scenario: cantilever(), cellSize: 0.25)
            let structure = try #require(solver.structure)
            prepare(structure)
            solver.settleStructures()
            #expect(solver.settlements.isEmpty, "\(label): \(solver.settlements.count) settlements")
            #expect(solver.structuresSettled, "\(label)")
            #expect(structure.settledDisplacements == nil, "\(label)")
            #expect(structure.summary().selfWeightSag == 0, "\(label)")
        }
        try check(
            { structure in
                structure.mutateNodes { nodes in
                    nodes[structure.nodeIndex(structure.ex, 0, 0)].isPrescribed = true
                }
            }, "prescribed tip node")
        try check(
            { structure in
                structure.mutateNodes { nodes in
                    nodes[structure.nodeIndex(structure.ex, 0, 0)].isPushedVertically = true
                }
            }, "tip node pushed vertically")
        try check(
            { structure in
                structure.mutateNodes { nodes in
                    nodes[structure.nodeIndex(structure.ex, 0, 0)].velocity = SIMD3(0, 0, 0.01)
                }
            }, "tip node already moving")
    }

    /// Soft ground (`StructureSolver.groundStiffness`) on the terrain goes through its own branch
    /// of `structureTerrainLanding` (Structure.metal), not the floor's that `MasonryDebrisTests`
    /// checks. A 1 m square block, 0.5 m deep, set down on a gentle slope should sink into a
    /// Winkler bed of 2 MPa/m by its weight over the bed, each bottom node bearing on h², as on
    /// the floor; on the hard ground it stays within a millimetre of the surface.
    @Test("On soft terrain a block sinks by its weight over the bed; on hard terrain it does not")
    func softGroundOnTerrain() throws {
        // A slope of 1 in 50, 2.2 m up at x = 10 m.
        let terrain = Terrain.sampled(domain: SIMD3(20, 20, 12), spacing: 0.5) { 2 + 0.02 * $0.x }
        let h: Float = 0.25
        var model = StructureModel(
            solids: [Box(min: SIMD3(9.5, 9.5, 2.25), max: SIMD3(10.5, 10.5, 2.75))],
            material: .elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2), elementSize: h,
            fixedBase: false)
        model = model.standing(on: terrain)
        #expect(model.ground != nil)
        let modulus: Float = 2e6
        func sunk(stiffness: Float) throws -> (mean: Float, expected: Float) {
            let solver = try StructureSolver(device: device, model: model)
            solver.groundFrictionCoefficient = 0.6
            solver.groundStiffness = stiffness
            solver.damping = 2
            solver.advance(steps: max(1, Int((1.0 / Double(solver.criticalTimeStep)).rounded())))
            var mass: Float = 0
            solver.mutateNodes { nodes in for node in nodes { mass += node.mass } }
            var total: Float = 0
            var count = 0
            for j in 0...solver.ey {
                for i in 0...solver.ex where solver.node(i, j, 0).mass > 0 {
                    let position = solver.position(i, j, 0)
                    total += terrain.height(at: position) - position.z
                    count += 1
                }
            }
            let bearing = Float(count) * h * h
            return (total / Float(count), stiffness > 0 ? mass * solver.gravity / (stiffness * bearing) : 0)
        }
        let hard = try sunk(stiffness: 0)
        #expect(abs(hard.mean) < 1e-3, "hard: \(hard.mean * 1e3) mm in")
        let soft = try sunk(stiffness: modulus)
        // About 3.8 mm. Measured on the Studio, 19 October 2026: 3.750 mm against 3.767 mm, 0.5% short (the slope tilts the
        // block a little); on the hard ground the nodes rest 0.05 mm above the surface.
        #expect(
            abs(soft.mean - soft.expected) < 0.03 * soft.expected,
            "soft: \(soft.mean * 1e3) mm in against \(soft.expected * 1e3) mm")
    }

    /// With `SolverConfiguration.structureCutCells` the element kernel is specialised
    /// (`StructureSolver.readStructureCutCells`) so that faces read the pressure at the wall
    /// (`cutFaceOverpressure`). `StructureCutCellsTests` checks that the gas is conserved and
    /// that an on-lattice wall is unchanged, but nothing checks that an off-lattice wall is still
    /// loaded: a specialisation that read no pressure would pass both. The wall must deflect,
    /// and by about as much as without cut cells.
    @Test("A wall off the lattice is loaded through its cut cells about as much as without them")
    func cutCellsLoadTheWall() throws {
        func deflection(cut: Bool) throws -> Float {
            var model = StructureModel(
                solids: [Box(min: SIMD3(5.075, 2.5, 0), max: SIMD3(5.375, 3.5, 1))],
                material: .elastic(density: 2400, youngsModulus: 30e9, poissonRatio: 0.2), elementSize: 0.025)
            model.elementKind = .solid
            let scenario = Scenario(
                name: "Wall", domainSize: SIMD3(10, 6, 4), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(2, 3, 0)), structure: model)
            var configuration = SolverConfiguration()
            configuration.settlesStructures = false
            configuration.structureCutCells = cut
            let solver = try BlastSolver(
                device: device, scenario: scenario, cellSize: 0.25, configuration: configuration)
            if cut { #expect(solver.structureCut != nil) }
            // The wave reaches the wall, 3 m off, in about 4 ms.
            #expect(solver.advance(until: 0.01).isStable)
            return try #require(solver.bodySummary()).maxDisplacement
        }
        let without = try deflection(cut: false)
        let with = try deflection(cut: true)
        #expect(without > 0 && with > 0, "without \(without * 1e3) mm, with \(with * 1e3) mm")
        // The cut cells move the face's load to where the face really is. Measured on the Studio, 19 October 2026: 0.124 mm with
        // them against 0.115 mm without, 8% more (the structure cut cells' peaks run about 12%
        // high too).
        #expect(
            with > 0.8 * without && with < 1.3 * without, "without \(without * 1e3) mm, with \(with * 1e3) mm"
        )
    }
}

/// Material and model set-up on the CPU that no test checks: steel's rate law by grade, the
/// timber strength classes and cross-laminated panels, and per-solid assignments.
@Suite("Structure materials and models: untested paths")
struct StructureModelGapTests {
    /// `StructureMaterial.structuralSteel` has `rateLaw = .byGrade`, which `resolvingRateLaw`
    /// turns into Cowper and Symonds's constants for its yield (`SteelRateLaw.constants`), and
    /// `StructureSolver.parameters(for:elementSize:)` passes to the element kernel. Every other
    /// test gives explicit constants, so a mistake in the grade bands or in resolving would
    /// leave every by-grade steel without its strain-rate gain unnoticed.
    @Test("Steel's rate law by grade resolves to its grade's constants and reaches the kernel")
    func rateLawByGrade() throws {
        let steel = StructureMaterial.structuralSteel
        #expect(steel.rateLaw == .byGrade)
        // S355: 300 to 400 MPa, fitted to A992.
        #expect(steel.resolvingRateLaw().rateLaw == .cowperSymonds(d: 68.8, q: 5.8))
        // The yield given overrides the material's, as a section's equivalent needs.
        #expect(steel.resolvingRateLaw(yield: 250e6).rateLaw == .cowperSymonds(d: 40.4, q: 5))
        #expect(steel.resolvingRateLaw(yield: 450e6).rateLaw == .cowperSymonds(d: 94.4, q: 4))
        // A material with explicit constants, or none, is left as it is.
        var explicit = steel
        explicit.rateLaw = .cowperSymonds(d: 10, q: 3)
        #expect(explicit.resolvingRateLaw() == explicit)
        let elastic = StructureMaterial.elastic(density: 7850, youngsModulus: 210e9, poissonRatio: 0.3)
        #expect(elastic.resolvingRateLaw() == elastic)

        let parameters = StructureSolver.parameters(for: steel, elementSize: 0.1)
        #expect(parameters.rateConstant == 68.8)
        #expect(abs(parameters.rateExponent - 1 / 5.8) < 1e-6)
        let atTest = 1 + pow(StructureMaterial.tensileTestRate / 68.8, 1 / 5.8)
        #expect(abs(parameters.rateTestFactor - atTest) < 1e-5)
        // Without a law the kernel's constant stays zero (no rate effect).
        #expect(StructureSolver.parameters(for: elastic, elementSize: 0.1).rateConstant == 0)
    }

    /// The strength classes raise characteristic strengths to means by the JCSS distributions
    /// (`TimberProperties.lognormalMean`, and `weibullMean`, which solves for the Weibull shape by
    /// bisection), and each kind of timber takes its own dynamic increase factor; a
    /// cross-laminated panel takes 1.28 and its lamellae alternate. `parameters(for:)` must scale
    /// every strength by that factor and pack the lamellae for the kernel. The expected ratios are
    /// computed independently in double precision: lognormal CoV 0.25 gives 1.5455, CoV 0.2 gives
    /// 1.4125, and Weibull CoV 0.25 (shape 4.542) gives 1.7559.
    @Test("Timber classes take their distributions' means and rate factors; CLT packs its lamellae")
    func timberClasses() throws {
        #expect(abs(TimberProperties.lognormalMean(cov: 0.25) - 1.5455) < 1e-3)
        #expect(abs(TimberProperties.lognormalMean(cov: 0.2) - 1.4125) < 1e-3)
        #expect(abs(TimberProperties.weibullMean(cov: 0.25) - 1.7559) < 2e-3)

        let c24 = TimberProperties.strengthClass(.c24)
        #expect(abs(c24.tensionAlong / (24e6 * 1.5455) - 1) < 1e-3)
        #expect(abs(c24.compressionAlong / (21e6 * 1.4125) - 1) < 1e-3)
        #expect(abs(c24.tensionAcross / (0.4e6 * 1.7559) - 1) < 2e-3)
        #expect(c24.strengthFactor == 1.4)
        #expect(TimberProperties.strengthClass(.gl24h).strengthFactor == 1.14)

        let material = StructureMaterial.timber(.c24, grainAxis: 1, lamellae: 5)
        let clt = try #require(material.timber)
        #expect(material.model == .timber && material.density == 420)
        #expect(clt.strengthFactor == 1.28 && clt.grainAxis == 1)
        #expect(clt.lamellae.map(\.crossed) == [false, true, false, true, false])
        #expect(clt.tensionAlong == c24.tensionAlong)

        let parameters = StructureSolver.parameters(for: material, elementSize: 0.035)
        #expect(parameters.materialModel == MaterialModel.timber.rawValue)
        #expect(abs(parameters.tensionAlong - 1.28 * clt.tensionAlong) <= 1e-6 * parameters.tensionAlong)
        #expect(
            abs(parameters.rollingStrength - 1.28 * clt.rollingStrength) <= 1e-6 * parameters.rollingStrength)
        #expect(parameters.grainAxis == 1)
        #expect(parameters.lamellaCount == 5)
        // The second and fourth lamellae are crossed.
        #expect(parameters.lamellaCrossed == 0b01010)
        // Tops through the thickness from -1 to 1, a fifth of the depth each.
        #expect(abs(parameters.lamellaTop.0 - -0.6) < 1e-5)
        #expect(abs(parameters.lamellaTop.4 - 1) < 1e-5)
        // Timber is always meshed as shells and beams, whatever the body's kind.
        let model = StructureModel(
            solids: [Box(min: .zero, max: SIMD3(1, 1, 0.105))], material: material, elementSize: 0.1)
        #expect(model.elementKind(of: 0) == .shell && model.isAllShells)
    }

    /// `StructureModel.solidNear` meshes the pieces near a charge as solids and the rest as
    /// shells. It has three outcomes: mixed (the shells at `shellSize`), none near (all shells,
    /// the body's element size becoming `shellSize`), and all near (all solids, unchanged sizes).
    /// Per-solid buckling curves (`setBucklingCurve`) are trimmed of trailing defaults, as their
    /// encoding relies on, follow their solids through `part` and `removeSolid`, and survive
    /// encoding.
    @Test(
        "Solids near a point are meshed as solids, the rest as shells; per-solid curves keep to their solids")
    func perSolidAssignments() throws {
        let near = Box(min: SIMD3(0, 0, 0), max: SIMD3(1, 0.2, 2))
        let middle = Box(min: SIMD3(3, 0, 0), max: SIMD3(4, 0.2, 2))
        let far = Box(min: SIMD3(10, 0, 0), max: SIMD3(11, 0.2, 2))
        let model = StructureModel(solids: [near, middle, far], elementSize: 0.05)

        // Within 1 m of the first wall's face (the second is 2.5 m off).
        let mixed = model.solidNear(SIMD3(-0.5, 0.1, 1), within: 1, shellSize: 0.25)
        #expect(mixed.isMixed)
        #expect((0..<3).map { mixed.elementKind(of: $0) } == [.solid, .shell, .shell])
        #expect(mixed.shellElementSize == 0.25 && mixed.elementSize == 0.05)
        #expect(mixed.part(.shell)?.elementSize == 0.25 && mixed.part(.solid)?.solids == [near])
        // On the boundary the distance counts as near.
        let boundary = model.solidNear(SIMD3(-1, 0.1, 1), within: 1, shellSize: 0.25)
        #expect(boundary.elementKind(of: 0) == .solid)

        let none = model.solidNear(SIMD3(-20, 0.1, 1), within: 1, shellSize: 0.25)
        #expect(!none.isMixed && none.isAllShells)
        #expect(none.elementKind == .shell && none.solidElementKind.isEmpty && none.elementSize == 0.25)

        let all = model.solidNear(SIMD3(5, 0.1, 1), within: 20, shellSize: 0.25)
        #expect(!all.isMixed && !all.isAllShells && all.elementKind == .solid)
        #expect(all.elementSize == 0.05 && all.shellElementSize == nil)

        var curves = model
        curves.setBucklingCurve(.c, of: 1)
        #expect(curves.solidBucklingCurves == [nil, .c])
        #expect((0..<3).map { curves.bucklingCurve(of: $0) } == [.b, .c, .b])
        // Out of range is ignored; setting the model's default back trims the list.
        curves.setBucklingCurve(.a, of: 7)
        #expect(curves.solidBucklingCurves == [nil, .c])
        let decoded = try JSONDecoder().decode(StructureModel.self, from: JSONEncoder().encode(curves))
        #expect(decoded.solidBucklingCurves == [nil, .c] && decoded.bucklingCurve(of: 1) == .c)
        var removed = curves
        removed.removeSolid(at: 0)
        #expect(removed.bucklingCurve(of: 0) == .c && removed.bucklingCurve(of: 1) == .b)
        curves.setBucklingCurve(nil, of: 1)
        #expect(curves.solidBucklingCurves.isEmpty)
    }
}
