import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Checks the concrete and reinforcement model against its own uniaxial curves and against
/// the standard section analysis for a reinforced beam.
@Suite("Concrete model")
struct ConcreteModelTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Concrete with no Poisson effect, so that a stretched cube is in pure uniaxial stress.
    private static func concrete(steel: SteelProperties? = nil) -> StructureMaterial {
        var material = StructureMaterial.concrete(name: "Test", compressiveStrength: 30e6, steel: steel)
        material.poissonRatio = 0
        return material
    }

    /// One cubic element, clamped on its low-x face and pulled or pushed on the other at a steady
    /// rate. Returns the nominal stress against strain, sampled as it goes.
    private func strainCube(
        size: Float, material: StructureMaterial, steelRatio: Float = 0, to strains: [Float],
        samplesPerLeg: Int = 150
    ) throws -> (curve: [(strain: Float, stress: Float)], solver: StructureSolver) {
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
        var model = StructureModel(solids: [cube], material: material, elementSize: size, fixedBase: false)
        if steelRatio > 0 {
            model.reinforcement = [ReinforcementLayer(region: cube, ratio: SIMD3(steelRatio, 0, 0))]
        }
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false

        var curve: [(strain: Float, stress: Float)] = []
        var strain: Float = 0
        let stepsPerSample = 20
        for target in strains {
            // Each leg covers its change in strain in a fixed number of steps.
            let rate = (target - strain) / (Float(samplesPerLeg * stepsPerSample) * solver.criticalTimeStep)
            solver.mutateNodes { nodes in
                for k in 0...1 {
                    for j in 0...1 {
                        nodes[solver.nodeIndex(0, j, k)].isFixed = true
                        nodes[solver.nodeIndex(1, j, k)].isPrescribed = true
                        nodes[solver.nodeIndex(1, j, k)].velocity = SIMD3(rate * size, 0, 0)
                    }
                }
            }
            for _ in 0..<samplesPerLeg {
                solver.advance(steps: stepsPerSample)
                var force: Float = 0
                for k in 0...1 {
                    for j in 0...1 { force += solver.nodalForce(1, j, k).x }
                }
                curve.append((solver.displacement(1, 0, 0).x / size, -force / (size * size)))
            }
            strain = target
        }
        return (curve, solver)
    }

    /// Area under a stress-strain curve, by the trapezium rule.
    private func energyDensity(_ curve: [(strain: Float, stress: Float)]) -> Float {
        zip(curve, curve.dropFirst()).reduce(0) {
            $0 + 0.5 * ($1.0.stress + $1.1.stress) * ($1.1.strain - $1.0.strain)
        }
    }

    @Test(
        "Concrete cracks at its tensile strength and releases its fracture energy on any mesh",
        arguments: [0.05, 0.1] as [Float])
    func tensionSoftening(size: Float) throws {
        let material = Self.concrete()
        // A slow first leg resolves the sharp peak; the second opens the crack fully.
        let (curve, solver) = try strainCube(size: size, material: material, to: [0.0003, 0.008])

        let peak = curve.map(\.stress).max() ?? 0
        #expect(abs(peak - material.tensileStrength) / material.tensileStrength < 0.03, "peak \(peak) Pa")
        // Energy per unit area of crack is the area under the curve times the element size.
        let released = energyDensity(curve) * size
        #expect(
            abs(released - material.fractureEnergy) / material.fractureEnergy < 0.05,
            "released \(released) J/m²")
        #expect((curve.last?.stress ?? 1) < 0.02 * material.tensileStrength)
        #expect(solver.crackStrain(0, 0, 0) > 0.007)
    }

    /// One cubic element of 50 mm stretched uniformly along `direction`, every node prescribed,
    /// first slowly to `strains[0]`, then on to `strains[1]`. Returns the stress along the
    /// direction against the strain.
    private func pullCube(
        along direction: SIMD3<Float>, crackAxes: CrackAxes, to strains: [Float]
    ) throws -> [(strain: Float, stress: Float)] {
        let size: Float = 0.05
        let d = simd_normalize(direction)
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))], material: Self.concrete(),
            elementSize: size, fixedBase: false)
        model.crackAxes = crackAxes
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let corners = (0...1).flatMap { k in (0...1).flatMap { j in (0...1).map { i in SIMD3(i, j, k) } } }
        var curve: [(strain: Float, stress: Float)] = []
        var strain: Float = 0
        let samples = 150
        let stepsPerSample = 20
        for target in strains {
            let rate = (target - strain) / (Float(samples * stepsPerSample) * solver.criticalTimeStep)
            solver.mutateNodes { nodes in
                for c in corners {
                    let index = solver.nodeIndex(c.x, c.y, c.z)
                    nodes[index].isPrescribed = true
                    nodes[index].velocity = rate * simd_dot(d, size * SIMD3<Float>(c)) * d
                }
            }
            for _ in 0..<samples {
                solver.advance(steps: stepsPerSample)
                // The power the nodes put in, over the volume and the strain rate, is the stress.
                var power: Float = 0
                for c in corners {
                    power -= simd_dot(
                        solver.nodalForce(c.x, c.y, c.z), rate * simd_dot(d, size * SIMD3<Float>(c)) * d)
                }
                strain += rate * Float(stepsPerSample) * solver.criticalTimeStep
                curve.append((strain, power / (size * size * size * rate)))
            }
            strain = target
        }
        return curve
    }

    @Test("Concrete pulled across the lattice's diagonals cracks once, releasing its fracture energy")
    func diagonalCrack() throws {
        let material = Self.concrete()
        let size: Float = 0.05
        for direction in [SIMD3<Float>(1, 0, 0), SIMD3(1, 1, 0), SIMD3(1, 1, 1)] {
            for axes in [CrackAxes.turningUntilOpen, .fixedAtFirstCrack] {
                let curve = try pullCube(along: direction, crackAxes: axes, to: [0.0003, 0.008])
                let peak = curve.map(\.stress).max() ?? 0
                #expect(
                    abs(peak - material.tensileStrength) / material.tensileStrength < 0.03,
                    "\(axes), \(direction): peak \(peak) Pa")
                let released = energyDensity(curve) * size
                #expect(
                    abs(released - material.fractureEnergy) / material.fractureEnergy < 0.05,
                    "\(axes), \(direction): released \(released) J/m²")
            }
        }
        // On the lattice planes interlock carries tension across a diagonal crack: about 1.2
        // times the strength and 6.6 times the energy along a face diagonal.
        let lattice = try pullCube(along: SIMD3(1, 1, 0), crackAxes: .lattice, to: [0.0003, 0.008])
        #expect((lattice.map(\.stress).max() ?? 0) > 1.1 * material.tensileStrength)
        #expect(energyDensity(lattice) * size > 3 * material.fractureEnergy)
    }

    @Test("Concrete crushes at its compressive strength and softens to a residual")
    func compression() throws {
        let material = Self.concrete()
        let peakStrain = 2 * material.compressiveStrength / material.youngsModulus
        let (curve, solver) = try strainCube(size: 0.05, material: material, to: [-0.006, -0.065])

        let peak = -(curve.map(\.stress).min() ?? 0)
        #expect(
            abs(peak - material.compressiveStrength) / material.compressiveStrength < 0.02, "peak \(peak) Pa")
        let atPeak = curve.min { $0.stress < $1.stress }?.strain ?? 0
        #expect(abs(-atPeak - peakStrain) / peakStrain < 0.1, "strain at peak \(atPeak)")
        // Half of peak strain should sit on the parabola: 0.75 fc.
        let half = curve.min { abs($0.strain + peakStrain / 2) < abs($1.strain + peakStrain / 2) }
        #expect(abs(-(half?.stress ?? 0) / material.compressiveStrength - 0.75) < 0.03)
        // The crushing energy is spread over the element, then a fifth of the strength remains.
        let softened = peakStrain + 2 * material.crushingEnergy / (0.05 * 0.8 * material.compressiveStrength)
        let late = curve.first { -$0.strain > softened * 1.02 }
        let residual = -(late?.stress ?? 0) / material.compressiveStrength
        #expect(abs(residual - 0.2) < 0.02, "residual \(residual)")
        #expect(solver.flag(0, 0, 0) == .active)
    }

    @Test("Concrete held in from the sides is far stronger, by Richart's rule, then compacts")
    func confinement() throws {
        // With Poisson's ratio restored, the cube's held faces stop it spreading, so pushing on
        // it loads the sides as well. The sides can supply up to the unconfined strength, and
        // each unit of that support is worth 4.1 units of axial strength. Squeezed further, its
        // pores collapse and the pressure follows the compaction curve, rising without end.
        var material = Self.concrete()
        material.poissonRatio = 0.2
        let (curve, solver) = try strainCube(
            size: 0.05, material: material, to: [-0.0004, -0.12], samplesPerLeg: 200)

        // The confined strength, 5.1 fc, is passed, and the stress never falls.
        let richart = (1 + 4.1) * material.compressiveStrength
        #expect(-(curve.map(\.stress).min() ?? 0) > richart)
        let falls = zip(curve, curve.dropFirst()).contains { $1.stress > $0.stress + 0.01 * abs($0.stress) }
        #expect(!falls, "the stress should only grow while the cube is squeezed")
        // At 12% the stress the compaction acts on (the second Piola-Kirchhoff stress, the
        // nominal stress over the stretch 0.88) is the curve's pressure plus a small deviator.
        let mu: Float = 1 / (1 - 0.12) - 1
        let lock: Float = 0.8e9
        let m = (mu - 0.1) / 1.1
        let pressure = lock + m * (85e9 + m * (-171e9 + m * 208e9))
        let final = -(curve.last?.stress ?? 0) / 0.88
        #expect(final > 0.98 * pressure && final < 1.2 * pressure, "\(final) Pa against \(pressure) Pa")
        #expect(abs(solver.compaction(0, 0, 0) - mu) < 0.01, "compaction \(solver.compaction(0, 0, 0))")
        #expect(solver.flag(0, 0, 0) == .active, "confined concrete should not be removed as crushed")

        // At small strain the response is still elastic, with the stiffness of a laterally
        // restrained solid.
        let early = try #require(curve.first { -$0.strain > 0.0002 })
        let constrained = material.lameLambda + 2 * material.shearModulus
        #expect(abs(early.stress / early.strain - constrained) / constrained < 0.08)
    }

    @Test("Crushed concrete keeps a permanent strain when the load comes off")
    func compressionUnloading() throws {
        let material = Self.concrete()
        let peakStrain = 2 * material.compressiveStrength / material.youngsModulus
        // Squeeze to twice the strain at peak strength, release fully, then squeeze again.
        let (curve, _) = try strainCube(
            size: 0.05, material: material, to: [-2 * peakStrain, 0, -2 * peakStrain], samplesPerLeg: 200)
        let loading = curve[..<200]
        let unloading = curve[200..<400]
        let reloading = curve[400...]

        // Karsan and Jirsa: the plastic strain is 0.145 x^2 + 0.13 x peak strains, x = 2 here.
        let expected = peakStrain * (0.145 * 4 + 0.13 * 2)
        let released = try #require(unloading.first { $0.stress > -1 })
        #expect(abs(-released.strain - expected) / expected < 0.03, "plastic strain \(-released.strain)")
        // Below that strain crushed concrete carries nothing; it does not pull.
        #expect(unloading.allSatisfy { $0.stress < 1 })
        #expect(abs(unloading.last?.stress ?? 1) < 1)
        // Halfway down the unloading line the stress is half what it was at the turn.
        let turn = try #require(loading.last)
        let halfway = (-turn.strain + expected) / 2
        let middle = try #require(unloading.min { abs(-$0.strain - halfway) < abs(-$1.strain - halfway) })
        #expect(abs(middle.stress / turn.stress - 0.5) < 0.03)
        // Squeezed again, it comes back to where it left the envelope.
        let back = try #require(reloading.last)
        #expect(abs(back.stress - turn.stress) / abs(turn.stress) < 0.01)
    }

    @Test("A diagonal crack leaves no residual opening across a plane held closed")
    func residualOnlyWhereOpened() throws {
        // Lattice planes, so that the diagonal crack is shared between the x and y planes, and a
        // large residual fraction, which before this rule pushed the x faces apart from nothing
        // and made every structure tested run away.
        var material = Self.concrete()
        material.crackResidual = 0.5
        let onset = material.tensileStrength / material.youngsModulus
        let size: Float = 0.05
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
        var model = StructureModel(solids: [cube], material: material, elementSize: size, fixedBase: false)
        model.crackAxes = .lattice
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false

        // Every node moves with a uniform strain rate: squeezed along x, then sheared in xy.
        func drive(_ rate: simd_float3x3, steps: Int) {
            solver.mutateNodes { nodes in
                for k in 0...1 {
                    for j in 0...1 {
                        for i in 0...1 {
                            let position = SIMD3(Float(i), Float(j), Float(k)) * size
                            nodes[solver.nodeIndex(i, j, k)].isPrescribed = true
                            nodes[solver.nodeIndex(i, j, k)].velocity = rate * position
                        }
                    }
                }
            }
            solver.advance(steps: steps)
        }
        let steps = 3000
        let time = Float(steps) * solver.criticalTimeStep
        drive(simd_float3x3(diagonal: SIMD3(-0.5 * onset / time, 0, 0)), steps: steps)
        let squeezed = solver.stress(0, 0, 0)[0]
        var shear = simd_float3x3()
        shear[1][0] = 20 * onset / time  // x velocity grows along y
        drive(shear, steps: steps)
        #expect(solver.crackStrain(0, 0, 0) > 5 * onset, "the shear should crack it diagonally")
        let sheared = solver.stress(0, 0, 0)[0]
        #expect(squeezed < 0)
        #expect(abs(sheared - squeezed) < 0.05 * abs(squeezed), "sigma_xx \(squeezed) -> \(sheared) Pa")
    }

    /// One cubic element whose eight nodes are all driven, so that its strain is uniform and
    /// follows a prescribed path; `work` adds up the work done on it, per unit volume.
    private final class DrivenCube {
        let solver: StructureSolver
        let size: Float = 0.05
        private(set) var strain = simd_float3x3()
        private(set) var work: Double = 0

        init(
            device: MTLDevice, material: StructureMaterial, secondCracks: Bool = true,
            reinforcement: [ReinforcementLayer] = [], inclinedBars: [InclinedBars] = []
        ) throws {
            let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
            var model = StructureModel(
                solids: [cube], material: material, elementSize: size, fixedBase: false)
            model.secondCracks = secondCracks
            model.reinforcement = reinforcement
            model.inclinedBars = inclinedBars
            solver = try StructureSolver(device: device, model: model)
            solver.gravity = 0
            solver.groundContact = false
        }

        /// The stress tensor (Pa).
        var stress: simd_float3x3 {
            let s = solver.stress(0, 0, 0)
            return simd_float3x3(rows: [
                SIMD3(s[0], s[3], s[5]), SIMD3(s[3], s[1], s[4]), SIMD3(s[5], s[4], s[2]),
            ])
        }

        /// Takes the strain to `target` at a steady rate over `steps` steps.
        func drive(to target: simd_float3x3, steps: Int = 3000, sample: (() -> Void)? = nil) {
            let dt = solver.criticalTimeStep
            let rate = (target - strain) * (1 / (Float(steps) * dt))
            let size = self.size
            solver.mutateNodes { nodes in
                for n in 0..<8 {
                    let position = SIMD3(Float(n & 1), Float((n >> 1) & 1), Float(n >> 2)) * size
                    nodes[solver.nodeIndex(n & 1, (n >> 1) & 1, n >> 2)].isPrescribed = true
                    nodes[solver.nodeIndex(n & 1, (n >> 1) & 1, n >> 2)].velocity = rate * position
                }
            }
            for _ in 0..<(steps / 20) {
                solver.advance(steps: 20)
                var power: Double = 0
                for n in 0..<8 {
                    let position = SIMD3(Float(n & 1), Float((n >> 1) & 1), Float(n >> 2)) * size
                    power -= Double(simd_dot(solver.nodalForce(n & 1, (n >> 1) & 1, n >> 2), rate * position))
                }
                work += power * Double(20 * dt) / Double(size * size * size)
                sample?()
            }
            strain = target
        }
    }

    /// A strain of `xx`, `yy` and shear `xy` (engineering shear 2 xy), in units of `unit`.
    private static func plane(_ xx: Float, _ yy: Float, _ xy: Float, _ unit: Float) -> simd_float3x3 {
        simd_float3x3(columns: (SIMD3(xx, xy, 0), SIMD3(xy, yy, 0), .zero)) * unit
    }

    @Test("Tension turned 45 degrees from a fixed crack opens a second crack instead of locking")
    func secondCrackRelievesLocking() throws {
        var material = Self.concrete()
        material.poissonRatio = 0
        let onset = material.tensileStrength / material.youngsModulus
        var carried: [Float] = []
        for second in [false, true] {
            let cube = try DrivenCube(device: device, material: material, secondCracks: second)
            // A crack across x, opened far enough to fix its axes, then closed.
            cube.drive(to: Self.plane(5, 0, 0, onset))
            cube.drive(to: Self.plane(0, 0, 0, onset))
            // Then stretched far along the diagonal, where a crack softens to nothing.
            cube.drive(to: Self.plane(30, 30, 30, onset), steps: 12000)
            let n = simd_normalize(SIMD3<Float>(1, 1, 0))
            carried.append(simd_dot(n, cube.stress * n) / material.tensileStrength)
        }
        // Without it the first crack's interlock carries the tension; with it, much less is.
        #expect(carried[0] > 0.5, "locked at \(carried[0]) f_t")
        #expect(carried[1] < 0.75 * carried[0], "with a second crack \(carried[1]) f_t")
    }

    @Test("With a second crack, closed cycles of strain still dissipate energy")
    func secondCrackDissipates() throws {
        for residual: Float in [0.1, 0.5] {
            var material = Self.concrete()
            material.poissonRatio = 0.2
            material.crackResidual = residual
            let onset = material.tensileStrength / material.youngsModulus
            let cube = try DrivenCube(device: device, material: material)
            cube.drive(to: Self.plane(5, 0, 0, onset))
            cube.drive(to: Self.plane(0, 0, 0, onset))
            cube.drive(to: Self.plane(10, 10, 10, onset))
            let corners = [(4, 4, 2), (4, -2, 6), (-2, -2, 1), (6, 1, -3), (4, 4, 2)].map {
                Self.plane(Float($0.0), Float($0.1), Float($0.2), onset)
            }
            cube.drive(to: corners[0])
            for loop in 0..<3 {
                let before = cube.work
                for corner in corners.dropFirst() { cube.drive(to: corner) }
                #expect(
                    cube.work - before > 0, "loop \(loop) at residual \(residual): \(cube.work - before) J/m3"
                )
            }
        }
    }

    @Test("Bars at 45 degrees pulled along their length carry what the same bars along an axis do")
    func inclinedBarsMatchAxisBars() throws {
        let steel = SteelProperties.grade500
        let material = Self.concrete(steel: steel)
        let ratio: Float = 0.01
        let size: Float = 0.05
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
        // Pulled to 1% along the bars, past their yield.
        let axial = try DrivenCube(
            device: device, material: material,
            reinforcement: [ReinforcementLayer(region: cube, ratio: SIMD3(ratio, 0, 0))])
        axial.drive(to: Self.plane(0.01, 0, 0, 1), steps: 6000)
        let alongAxis = axial.stress[0][0]
        // The same ratio of bars along the xy diagonal, through the element's centre: smeared
        // across a band h sqrt(2) wide, so the area per metre is ratio times that.
        let rowWidth = size * Float(2).squareRoot()
        let bars = InclinedBars(
            start: SIMD3(0, 0, 0), direction: SIMD3(1, 1, 0), length: 1, span: 0...2,
            areaPerMetre: ratio * rowWidth)
        let diagonal = try DrivenCube(device: device, material: material, inclinedBars: [bars])
        let n = simd_normalize(SIMD3<Float>(1, 1, 0))
        diagonal.drive(to: Self.plane(0.005, 0.005, 0.005, 1), steps: 6000)
        let alongDiagonal = simd_dot(n, diagonal.stress * n)
        #expect(alongAxis > 0.9 * ratio * steel.yieldStress, "axis bars carry \(alongAxis) Pa")
        #expect(
            abs(alongDiagonal / alongAxis - 1) < 0.05, "diagonal \(alongDiagonal) Pa against \(alongAxis) Pa")
    }

    @Test("A cracked element recovers its compressive stiffness once the crack closes")
    func crackClosure() throws {
        let material = Self.concrete()
        let onset = material.tensileStrength / material.youngsModulus
        let (curve, _) = try strainCube(size: 0.05, material: material, to: [6 * onset, -2 * onset])

        // Unloading follows a straight line to the crack's residual opening, a tenth of its
        // inelastic opening when it stopped opening.
        let softening = material.fractureEnergy / (0.05 * material.tensileStrength) - onset / 2
        let atTurn = material.tensileStrength * exp(-5 * onset / softening)
        let residual = material.crackResidual * (6 * onset - atTurn / material.youngsModulus)
        let halfway = try #require(curve[150...].first { $0.strain < 3 * onset })
        let line = atTurn * (halfway.strain - residual) / (6 * onset - residual)
        #expect(abs(halfway.stress - line) / atTurn < 0.03)
        #expect(atTurn < 0.6 * material.tensileStrength)
        let closed = try #require(curve[150...].first { $0.stress <= 0 })
        #expect(
            abs(closed.strain - residual) < 0.1 * onset, "closed at \(closed.strain), expected \(residual)")
        // ...after which the element behaves in compression as if it had never cracked.
        let final = try #require(curve.last)
        let ratio = (2 * onset + residual) / (2 * material.compressiveStrength / material.youngsModulus)
        let expected = -material.compressiveStrength * (2 * ratio - ratio * ratio)
        #expect(
            abs(final.stress - expected) / abs(expected) < 0.03, "stress \(final.stress) vs \(expected) Pa")
    }

    @Test("Reinforcement carries a cracked element up to yield, hardens, then ruptures")
    func reinforcedTie() throws {
        let steel = SteelProperties.grade500
        let material = Self.concrete(steel: steel)
        let ratio: Float = 0.01
        let (curve, solver) = try strainCube(size: 0.05, material: material, steelRatio: ratio, to: [0.05])

        // Well past cracking and just past yield, the steel alone carries the load.
        let yielded = try #require(curve.first { $0.strain > 0.01 })
        let hardening = (steel.ultimateStress - steel.yieldStress) / steel.ultimateStrain
        let plastic = yielded.strain - steel.yieldStress / steel.youngsModulus
        let expected = ratio * (steel.yieldStress + hardening * plastic)
        #expect(
            abs(yielded.stress - expected) / expected < 0.03, "stress \(yielded.stress) vs \(expected) Pa")
        // The steel holds the element together although the concrete is fully cracked.
        #expect(solver.flag(0, 0, 0) == .active)
        #expect(solver.damage(0, 0, 0) > 0.3 && solver.damage(0, 0, 0) < 0.6)

        // Stretched beyond the steel's rupture strain, the element is lost.
        let (broken, brokenSolver) = try strainCube(
            size: 0.05, material: material, steelRatio: ratio, to: [0.14])
        #expect(brokenSolver.flag(0, 0, 0) == .eroded)
        #expect(abs(broken.last?.stress ?? 1) < 1)
        // The peak load reached the steel's ultimate strength.
        let peak = broken.map(\.stress).max() ?? 0
        #expect(abs(peak - ratio * steel.ultimateStress) / (ratio * steel.ultimateStress) < 0.03)
    }

    @Test("Reinforcement loaded back after yielding softens early, by the Menegotto-Pinto law")
    func bauschinger() throws {
        let steel = SteelProperties.grade500
        let material = Self.concrete(steel: steel)
        let ratio: Float = 0.01
        // Stretch well past yield, then shorten by 8 mm/m. The crack stays open throughout, so
        // the bars carry the load alone.
        let (curve, _) = try strainCube(
            size: 0.05, material: material, steelRatio: ratio, to: [0.02, 0.012], samplesPerLeg: 200)
        let reversal = try #require(curve[199...].first)

        // The same law evaluated here: the elastic line from the reversal point meets the
        // compressive yield asymptote at the target, and the curve bends towards it with a
        // sharpness that falls with the size of the earlier plastic excursion.
        let modulus = steel.youngsModulus
        let b = (steel.ultimateStress - steel.yieldStress) / (steel.ultimateStrain * modulus)
        let reversalStress = reversal.stress / ratio
        let span =
            (-steel.yieldStress * (1 - b) - (reversalStress - b * modulus * reversal.strain))
            / (modulus * (1 - b))
        let target = (strain: reversal.strain + span, stress: reversalStress + modulus * span)
        let excursion = abs(target.strain) / (steel.yieldStress / modulus)
        let r = 20 - 18.5 * excursion / (0.15 + excursion)
        func expected(_ strain: Float) -> Float {
            let x = (strain - reversal.strain) / span
            let y = b * x + (1 - b) * x / pow(1 + pow(abs(x), r), 1 / r)
            return reversalStress + y * (target.stress - reversalStress)
        }
        for sample in curve[220...].enumerated().filter({ $0.offset.isMultiple(of: 30) }).map(\.element) {
            let stress = sample.stress / ratio
            #expect(
                abs(stress - expected(sample.strain)) < 0.03 * steel.yieldStress,
                "at \(sample.strain): \(stress / 1e6) MPa, expected \(expected(sample.strain) / 1e6) MPa")
        }
        // Halfway to the target the bar is already well below the elastic line...
        let middle = try #require(curve[200...].first { $0.strain < reversal.strain + span / 2 })
        let elastic = reversalStress + modulus * (middle.strain - reversal.strain)
        #expect(middle.stress / ratio > elastic + 0.05 * steel.yieldStress)
        // ...and at the end it is in compression but well short of its yield stress, where a
        // bar that unloaded elastically would have yielded.
        let end = try #require(curve.last).stress / ratio
        #expect(end < -0.4 * steel.yieldStress && end > -0.8 * steel.yieldStress, "end \(end / 1e6) MPa")
    }

    @Test("A reinforced tie with one crack fails at the same opening on two meshes")
    func tieFailureOpening() throws {
        /// Pulls a 0.4 m tie, 1% steel, with a weaker slice in the middle so the crack gathers
        /// there, and returns the end displacement at which it loses its load.
        func failureOpening(elementSize h: Float) throws -> (opening: Float, peak: Float) {
            let steel = SteelProperties.grade500
            let material = Self.concrete(steel: steel)
            var weak = material
            weak.tensileStrength *= 0.8
            weak.name = "Weak"
            let tie = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.4, 0.1, 1.1))
            let slice = Box(min: SIMD3(0.2, 0, 1), max: SIMD3(0.2 + h, 0.1, 1.1))
            var model = StructureModel(
                solids: [tie, slice], material: material, elementSize: h, fixedBase: false)
            model.setMaterial(weak, of: 1)
            // A fifth less steel across the slice, so its bars reach their ultimate strength
            // before the rest of the tie yields, as at a real crack.
            model.reinforcement = [
                ReinforcementLayer(region: tie, ratio: SIMD3(0.01, 0, 0)),
                ReinforcementLayer(region: slice, ratio: SIMD3(-0.002, 0, 0)),
            ]
            let solver = try StructureSolver(device: device, model: model)
            solver.gravity = 0
            solver.groundContact = false
            solver.damping = 200
            let rate: Float = 0.2  // m/s
            solver.mutateNodes { nodes in
                for k in 0...solver.ez {
                    for j in 0...solver.ey {
                        nodes[solver.nodeIndex(0, j, k)].isFixed = true
                        nodes[solver.nodeIndex(solver.ex, j, k)].isPrescribed = true
                        nodes[solver.nodeIndex(solver.ex, j, k)].velocity = SIMD3(rate, 0, 0)
                    }
                }
            }
            var peak: Float = 0
            let stepsPerSample = Int(0.0002 / solver.criticalTimeStep)
            while solver.time < 0.15 {
                solver.advance(steps: stepsPerSample)
                var force: Float = 0
                for k in 0...solver.ez {
                    for j in 0...solver.ey { force += solver.nodalForce(solver.ex, j, k).x }
                }
                force = -force
                peak = max(peak, force)
                if peak > 0 && force < 0.1 * peak && solver.time > 0.005 {
                    return (Float(solver.time) * rate, peak)
                }
            }
            return (.infinity, peak)
        }
        let coarse = try failureOpening(elementSize: 0.02)
        let fine = try failureOpening(elementSize: 0.01)
        // Both reach the slice's bar strength, and lose it at the same opening, well beyond the
        // 0.12 h (2.4 mm and 1.2 mm) at which a bar strained only in the cracked element would
        // break.
        let strength = 0.008 * 0.1 * 0.1 * SteelProperties.grade500.ultimateStress
        #expect(
            coarse.peak > 0.95 * strength && fine.peak > 0.95 * strength, "\(coarse.peak), \(fine.peak) N")
        // (16% apart since the time step allows for the bars' stiffness; 15% was the limit before.)
        #expect(
            abs(fine.opening - coarse.opening) / coarse.opening < 0.2,
            "\(coarse.opening) m and \(fine.opening) m")
        #expect(fine.opening > 0.005, "fine \(fine.opening) m")
    }

    @Test("An unreinforced element is removed once its crack is fully open")
    func plainErosion() throws {
        // A 5 mm crack in a 50 mm element is a strain of 10%.
        let (_, intact) = try strainCube(size: 0.05, material: Self.concrete(), to: [0.09])
        #expect(intact.flag(0, 0, 0) == .active)
        let (_, solver) = try strainCube(size: 0.05, material: Self.concrete(), to: [0.11])
        #expect(solver.flag(0, 0, 0) == .eroded)
        #expect(solver.hasFailed)
    }

    @Test("Reinforcement is shared between the elements a layer straddles")
    func smearedLayers() throws {
        let slab = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.4, 0.4, 1.2))
        var model = StructureModel(
            solids: [slab], material: Self.concrete(steel: .grade500), elementSize: 0.05, fixedBase: false)
        // Bars 50 mm above the underside sit on the boundary between the first two layers.
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 500e-6, depth: 0.05, faces: (low: true, high: false))
        let solver = try StructureSolver(device: device, model: model)

        let lower = solver.steelRatio(3, 3, 0)
        let upper = solver.steelRatio(3, 3, 1)
        #expect(abs(lower.x - 0.005) < 1e-5 && abs(upper.x - 0.005) < 1e-5)
        #expect(lower.x == lower.y && lower.z == 0)
        #expect(solver.steelRatio(3, 3, 2) == .zero)
        // Summed through the depth, the steel area per metre is what was asked for.
        let total = (0..<4).reduce(Float(0)) { $0 + solver.steelRatio(3, 3, $1).x * 0.05 }
        #expect(abs(total - 500e-6) < 1e-8)
    }

    @Test("A reinforced beam reaches the moment capacity given by section analysis")
    func beamCapacity() throws {
        // Section analysis with a rectangular stress block.
        let fc: Float = 30e6
        let yield = SteelProperties.grade500.yieldStress
        let width: Float = 0.1
        let barArea: Float = 500e-6  // per metre width
        let depth: Float = 0.15 - 0.0375
        let tension = barArea * width * yield
        let block = tension / (0.85 * fc * width)
        // The load spreads over a 50 mm plate, so the moment at mid-span is P (L/4 - w/8).
        let expected = tension * (depth - block / 2) / (1.2 / 4 - 0.05 / 8)

        let coarse = try beamLoad(elementSize: 0.025)
        let fine = try beamLoad(elementSize: 0.0125)
        // The hourglass forces of squeezed elements add some bending strength where the
        // compression zone (10 mm) is thinner than an element, so the model runs 10-15% strong.
        #expect(abs(coarse - expected) / expected < 0.15, "coarse: \(coarse) N against \(expected) N")
        #expect(abs(fine - expected) / expected < 0.15, "fine: \(fine) N against \(expected) N")
        // Six and twelve elements deep give the same answer.
        #expect(abs(fine - coarse) / coarse < 0.03, "coarse \(coarse) N, fine \(fine) N")
    }

    /// Plateau load of a 1.2 m span, 100 mm wide, 150 mm deep reinforced beam in three-point
    /// bending under displacement control.
    private func beamLoad(elementSize h: Float) throws -> Float {
        var steel = SteelProperties.grade500
        // No hardening, for a clean plateau; with nothing to spread the yielding, all the strain
        // gathers in one row of elements, so the bars are not allowed to rupture here.
        steel.ultimateStress = steel.yieldStress
        steel.ruptureStrain = 10
        var material = StructureMaterial.concrete(name: "Test", compressiveStrength: 30e6, steel: steel)
        material.poissonRatio = 0.2
        let beam = Box(min: SIMD3(0, 0, 1), max: SIMD3(1.3, 0.1, 1.15))
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        model.addMat(
            to: beam, thicknessAxis: 2, areaPerMetre: 500e-6, transverseAreaPerMetre: 0, longitudinalAxis: 0,
            depth: 0.0375, faces: (low: true, high: false))
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100

        let rate: Float = 0.12  // m/s, slow against the beam's 6 ms period
        let left = Int((0.05 / h).rounded())
        let right = Int((1.25 / h).rounded())
        let middle = Int((0.65 / h).rounded())
        // The load goes through a rigid plate 50 mm wide: through a single line of nodes it would
        // crush the elements beneath it on a fine mesh.
        let plate = Int((0.025 / h).rounded())
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                // Both supports are rollers; the loading plate holds the beam in place lengthwise,
                // so no arch can form between a support and the load.
                nodes[solver.nodeIndex(left, j, 0)].restrain(y: true, z: true)
                nodes[solver.nodeIndex(right, j, 0)].restrain(y: true, z: true)
                for i in (middle - plate)...(middle + plate) {
                    let load = solver.nodeIndex(i, j, solver.ez)
                    nodes[load].isPrescribed = true
                    nodes[load].velocity = SIMD3(0, 0, -rate)
                }
            }
        }

        var plateau: [Float] = []
        let stepsPerSample = Int(0.0008 / solver.criticalTimeStep)
        while solver.time < 0.1 {
            solver.advance(steps: stepsPerSample)
            let deflection = -solver.displacement(middle, solver.ey / 2, solver.ez).z
            var reaction: Float = 0
            for j in 0...solver.ey {
                for i in (middle - plate)...(middle + plate) {
                    reaction += solver.nodalForce(i, j, solver.ez).z
                }
            }
            if deflection > 0.006 { plateau.append(reaction) }
        }
        // Unreinforced cover may spall off the tension face, but the bars' layer stays.
        let bars = Int((0.0375 / h).rounded(.down))
        #expect(solver.flag(middle, solver.ey / 2, bars) == .active)
        #expect(solver.flag(middle, solver.ey / 2, solver.ez - 1) == .active)
        return plateau.reduce(0, +) / Float(plateau.count)
    }

    @Test("Concrete loaded quickly is stronger, by the published rate law")
    func rateStrengthening() throws {
        var material = Self.concrete()
        material.rateDependent = true
        // Pull at 0.1 per second: slow enough for the running average of the rate to settle
        // before the cube cracks.
        let size: Float = 0.05
        let step = 0.5 * size / material.dilatationalWaveSpeed
        let (curve, _) = try strainCube(
            size: size, material: material, to: [0.1 * step * 20 * 600], samplesPerLeg: 600)

        // Malvar and Ross: (rate / 1e-6)^delta with delta = 1 / (1 + 8 fc / 10 MPa).
        let delta = 1 / (1 + 8 * material.compressiveStrength / 10e6)
        let expected = material.tensileStrength * pow(0.1 / 1e-6, delta)
        let peak = curve.map(\.stress).max() ?? 0
        #expect(abs(peak - expected) / expected < 0.06, "peak \(peak) Pa against \(expected) Pa")
        #expect(expected > 1.5 * material.tensileStrength)
    }

    @Test("Concrete crushed at 100 per second is stronger, by the CEB-FIP law above 30 per second")
    func fastCrushing() throws {
        var material = Self.concrete()
        material.rateDependent = true
        // A 1 mm cube, so that its time steps are short enough for the running average of the
        // strain rate to settle well before the peak.
        let size: Float = 0.001
        let step = 0.5 * size / material.dilatationalWaveSpeed
        let rate: Float = 100
        let samples = 40
        let (curve, _) = try strainCube(
            size: size, material: material, to: [-rate * step * 20 * Float(samples)], samplesPerLeg: samples)

        // CEB-FIP Model Code 1990 above 30 per second: gamma (rate / 30e-6)^(1/3), with
        // log gamma = 6.156 alpha - 2 and alpha = 1 / (5 + 9 fc / 10 MPa).
        // The model's rate is the equivalent (von Mises) strain rate, which for a strain along one
        // axis alone, as here with no Poisson effect, is sqrt(2/3) of it: 82 per second.
        let effective = rate * (2.0 / 3.0 as Float).squareRoot()
        let alpha = 1 / (5 + 9 * material.compressiveStrength / 10e6)
        let factor = pow(10, 6.156 * alpha - 2) * pow(effective / 30e-6, 1 / 3)
        let expected = material.compressiveStrength * factor
        let peak = -(curve.map(\.stress).min() ?? 0)
        #expect(
            abs(peak - expected) / expected < 0.06, "peak \(peak / 1e6) MPa against \(expected / 1e6) MPa")
        #expect(factor > 2)
    }

    @Test("A cracked plane still carries shear by aggregate interlock, less as it opens")
    func aggregateInterlock() throws {
        // Open a crack across x to a set width, then shear the cube across it.
        let material = Self.concrete()
        let size: Float = 0.05
        func shearCapacity(opening: Float) throws -> Float {
            let (_, solver) = try strainCube(size: size, material: material, to: [opening / size])
            solver.mutateNodes { nodes in
                for k in 0...1 {
                    for j in 0...1 { nodes[solver.nodeIndex(1, j, k)].velocity = SIMD3(0, 0, 0.02) }
                }
            }
            var peak: Float = 0
            for _ in 0..<60 {
                solver.advance(steps: 20)
                var force: Float = 0
                for k in 0...1 {
                    for j in 0...1 { force += solver.nodalForce(1, j, k).z }
                }
                peak = max(peak, -force / (size * size))
            }
            return peak
        }

        // Vecchio and Collins: 0.18 sqrt(fc) / (0.31 + 24 w / (a + 16)), in MPa and mm.
        func expected(opening: Float) -> Float {
            let onset = material.tensileStrength / material.youngsModulus
            let width = (opening - onset * size) * 1000
            return 0.18e6 * (material.compressiveStrength / 1e6).squareRoot()
                / (0.31 + 24 * width / (material.aggregateSize * 1000 + 16))
        }
        for opening in [0.0002, 0.001] as [Float] {
            let capacity = try shearCapacity(opening: opening)
            let target = expected(opening: opening)
            #expect(
                abs(capacity - target) / target < 0.05,
                "\(opening * 1000) mm: \(capacity) Pa against \(target) Pa")
        }
    }
}

/// The model against a real test: the normal-strength slab of the Blast Blind Simulation Contest.
@Suite("Slab benchmark")
struct SlabBenchmarkTests {
    @Test("The recorded load has the stated peak and impulse")
    func load() {
        let load = SlabBenchmark.load
        #expect(abs(load.impulse - SlabBenchmark.statedImpulse) / SlabBenchmark.statedImpulse < 1e-4)
        let peak = load.history.map(\.y).max() ?? 0
        #expect(abs(peak - SlabBenchmark.statedPeakPressure) / SlabBenchmark.statedPeakPressure < 0.03)
    }

    @Test("The predicted peak deflection is within 15% of the measured 108 mm")
    func peakDeflection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let result = try SlabBenchmark.run(device: device, elementsThroughThickness: 4)
        #expect(
            abs(result.peak - SlabBenchmark.measuredPeak) / SlabBenchmark.measuredPeak < 0.15,
            "peak \(result.peak) m")
        #expect(abs(result.peakTime - SlabBenchmark.measuredPeakTime) < 0.006, "at \(result.peakTime) s")
        #expect(result.summary.erodedElements == 0)
        // The slab is left with most of that deflection, as in the test.
        #expect(result.residual > 0.6 * result.peak)
        // The whole history stays close to the measured one, not just its peak. (The coarse mesh
        // rebounds too far, so this is looser than the 9 mm a 16-layer mesh achieves.)
        #expect(result.historyError < 0.016, "history differs by \(result.historyError) m")
    }

    @Test("Shells give a peak within 20% of the measured one, the same on two meshes")
    func shellPeakDeflection() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let coarse = try SlabBenchmark.runShells(device: device, elementSize: 2 * 0.0254)
        let fine = try SlabBenchmark.runShells(device: device, elementSize: 1 * 0.0254)
        for result in [coarse, fine] {
            #expect(
                abs(result.peak - SlabBenchmark.measuredPeak) / SlabBenchmark.measuredPeak < 0.2,
                "peak \(result.peak) m")
            #expect(result.summary.erodedElements == 0)
            // Shells rebound about as little as the specimen did.
            #expect(
                abs(result.residual - SlabBenchmark.measuredResidual) / SlabBenchmark.measuredResidual < 0.15)
            #expect(result.historyError < 0.012, "history differs by \(result.historyError) m")
        }
        #expect(abs(fine.peak - coarse.peak) / coarse.peak < 0.03)
        #expect(throws: BlastError.self) {
            _ = try SlabBenchmark.runShells(device: device, elementSize: 4 * 0.0254)
        }
    }
}

/// Janney's reinforced beam, bent slowly to failure.
@Suite("Beam benchmark")
struct BeamBenchmarkTests {
    @Test("The beam's moment follows the measured curve, on two meshes")
    func momentAgainstTest() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        let coarse = try BeamBenchmark.run(device: device, elementsThroughDepth: 6, deflection: 0.04)
        let fine = try BeamBenchmark.run(device: device, elementsThroughDepth: 12, deflection: 0.04)
        let measured = BeamBenchmark.measuredPeakMoment
        // Six elements through the depth run about 10% strong, as coarse meshes do in bending.
        #expect(abs(coarse.peakMoment - measured) / measured < 0.15, "coarse: \(coarse.peakMoment) N m")
        #expect(abs(fine.peakMoment - measured) / measured < 0.06, "fine: \(fine.peakMoment) N m")
        #expect(fine.curveError(upTo: 0.04) < 0.12 * measured, "rms \(fine.curveError(upTo: 0.04)) N m")
        // The test beam failed in flexure at 42 mm; the model's must not fail long before that.
        #expect(fine.moment(at: 0.035) > 0.9 * measured, "at 35 mm: \(fine.moment(at: 0.035)) N m")
    }
}

/// Vecchio and Shim's beam OA1, with no stirrups, failing in diagonal tension.
@Suite("Shear beam benchmark")
struct ShearBeamBenchmarkTests {
    @Test("A beam without stirrups fails suddenly in shear, near the measured load")
    func diagonalTension() throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
        // A 92 mm slice of the beam, 24 elements deep: within 5% of the whole beam's answer.
        let result = try ShearBeamBenchmark.run(device: device, elementsThroughDepth: 24, slice: 0.092)
        let measured = ShearBeamBenchmark.measuredPeak
        #expect(abs(result.peak - measured) / measured < 0.2, "peak \(result.peak) N against \(measured) N")
        // Brittle: within 1.5 mm of the peak the load has fallen below half of it, before the
        // bars have yielded (they would at about 470 kN).
        let after = result.curve.filter {
            $0.x > result.peakDeflection && $0.x < result.peakDeflection + 0.0015
        }
        #expect((after.map(\.y).min() ?? result.peak) < 0.5 * result.peak, "no sudden drop after the peak")
        #expect(result.peak < 450e3)
    }
}

/// Saatci's beams struck at mid-span by a falling weight.
@Suite("Impact benchmark")
struct ImpactBenchmarkTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func test(_ name: String) throws -> ImpactBenchmark.Test {
        try #require(ImpactBenchmark.tests.first { $0.name == name })
    }

    @Test("Solid elements: the light drop's peak, the heavy drop's survival, and the beam without stirrups broken")
    func solids() throws {
        // Twelve elements through the depth; 16 and 24 give much the same (docs/validation.md).
        let light = try ImpactBenchmark.run(device: device, test: test("SS0a-1"), elementsThroughDepth: 12)
        let measured = try #require(try test("SS0a-1").peak)
        #expect(abs(light.peak - measured) / measured < 0.25, "SS0a-1: \(light.peak) m")
        #expect(light.summary.erodedElements == 0)
        // With stirrups the heavy drop is survived; the model's peak is short of the test's by up
        // to a quarter, with the concrete's tensile strength raised by the strain rate.
        let heavy = try ImpactBenchmark.run(device: device, test: test("SS2b-1"), elementsThroughDepth: 12)
        let heavyMeasured = try #require(try test("SS2b-1").peak)
        #expect(heavy.peak > 0.65 * heavyMeasured && heavy.peak < 1.1 * heavyMeasured, "SS2b-1: \(heavy.peak) m")
        #expect(heavy.summary.erodedElements == 0)
        // Without stirrups, it breaks along diagonal cracks.
        let broken = try ImpactBenchmark.run(device: device, test: test("SS0b-1"), elementsThroughDepth: 12)
        #expect(broken.summary.erodedElements > 100, "SS0b-1: \(broken.summary.erodedElements) elements failed")
    }

    @Test("Beam elements, without the sectional shear check, give the measured peaks")
    func beams() throws {
        // The light drops all give 12.7 mm, against 9.3 to 12.1 mm measured; the heavy ones about
        // 38 mm, against 35.3 to 39.5 mm.
        for (name, tolerance) in [("SS0a-1", Float(0.4)), ("SS2b-1", 0.1)] {
            let result = try ImpactBenchmark.runBeams(device: device, test: test(name), sectionShear: false)
            let measured = try #require(try test(name).peak)
            #expect(abs(result.peak - measured) / measured < tolerance, "\(name): \(result.peak) m")
        }
    }
}
