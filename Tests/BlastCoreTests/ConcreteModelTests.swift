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

    @Test("Concrete held in from the sides is far stronger, by Richart's rule")
    func confinement() throws {
        // With Poisson's ratio restored, the cube's held faces stop it spreading, so pushing on
        // it loads the sides as well. The sides can supply up to the unconfined strength, and
        // each unit of that support is worth 4.1 units of axial strength.
        var material = Self.concrete()
        material.poissonRatio = 0.2
        let (curve, solver) = try strainCube(
            size: 0.05, material: material, to: [-0.0004, -0.12], samplesPerLeg: 200)

        let peak = -(curve.map(\.stress).min() ?? 0)
        let expected = (1 + 4.1) * material.compressiveStrength
        #expect(abs(peak - expected) / expected < 0.03, "peak \(peak) Pa against \(expected) Pa")
        #expect(solver.flag(0, 0, 0) == .active, "confined concrete should not be removed as crushed")

        // At small strain the response is still elastic, with the stiffness of a laterally
        // restrained solid.
        let early = try #require(curve.first { -$0.strain > 0.0002 })
        let constrained = material.lameLambda + 2 * material.shearModulus
        #expect(abs(early.stress / early.strain - constrained) / constrained < 0.08)
    }

    @Test("A cracked element recovers its compressive stiffness when the crack closes")
    func crackClosure() throws {
        let material = Self.concrete()
        let onset = material.tensileStrength / material.youngsModulus
        let (curve, _) = try strainCube(size: 0.05, material: material, to: [6 * onset, -2 * onset])

        // Unloading follows the secant: at half the opening, half the stress the crack was
        // carrying when it stopped opening.
        let softening = material.fractureEnergy / (0.05 * material.tensileStrength) - onset / 2
        let atTurn = material.tensileStrength * exp(-5 * onset / softening)
        let halfway = try #require(curve[150...].first { $0.strain < 3 * onset })
        #expect(abs(halfway.stress - atTurn * halfway.strain / (6 * onset)) / atTurn < 0.03)
        #expect(atTurn < 0.6 * material.tensileStrength)
        // ...but in compression the element behaves as if it had never cracked.
        let final = try #require(curve.last)
        let ratio = 2 * onset / (2 * material.compressiveStrength / material.youngsModulus)
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
        // Three-point bending under displacement control: 1.2 m span, 100 mm wide, 150 mm deep.
        var steel = SteelProperties.grade500
        // No hardening, for a clean plateau; with nothing to spread the yielding, all the strain
        // gathers in one row of elements, so the bars are not allowed to rupture here.
        steel.ultimateStress = steel.yieldStress
        steel.ruptureStrain = 10
        var material = StructureMaterial.concrete(name: "Test", compressiveStrength: 30e6, steel: steel)
        material.poissonRatio = 0.2
        let h: Float = 0.025
        let beam = Box(min: SIMD3(0, 0, 1), max: SIMD3(1.3, 0.1, 1.15))
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        let barArea: Float = 500e-6  // per metre width
        model.addMat(
            to: beam, thicknessAxis: 2, areaPerMetre: barArea, transverseAreaPerMetre: 0, longitudinalAxis: 0,
            depth: 0.0375, faces: (low: true, high: false))
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100

        let rate: Float = 0.12  // m/s, slow against the beam's 6 ms period
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                // Both supports are rollers; the loading line holds the beam in place lengthwise,
                // so no arch can form between a support and the load.
                nodes[solver.nodeIndex(2, j, 0)].restrain(y: true, z: true)
                nodes[solver.nodeIndex(50, j, 0)].restrain(y: true, z: true)
                let load = solver.nodeIndex(26, j, solver.ez)
                nodes[load].isPrescribed = true
                nodes[load].velocity = SIMD3(0, 0, -rate)
            }
        }

        var plateau: [Float] = []
        let stepsPerSample = 400
        while solver.time < 0.1 {
            solver.advance(steps: stepsPerSample)
            let deflection = -solver.displacement(26, 2, solver.ez).z
            var reaction: Float = 0
            for j in 0...solver.ey { reaction += solver.nodalForce(26, j, solver.ez).z }
            if deflection > 0.006 { plateau.append(reaction) }
        }
        let load = plateau.reduce(0, +) / Float(plateau.count)

        // Section analysis with a rectangular stress block.
        let width: Float = 0.1
        let depth: Float = 0.15 - 0.0375
        let tension = barArea * width * steel.yieldStress
        let block = tension / (0.85 * material.compressiveStrength * width)
        let moment = tension * (depth - block / 2)
        let expected = 4 * moment / 1.2
        #expect(abs(load - expected) / expected < 0.1, "load \(load) N against \(expected) N")
        // Unreinforced cover may spall off the tension face, but the bars' layer stays.
        #expect(solver.flag(26, 2, 1) == .active)
        #expect(solver.flag(26, 2, 5) == .active)
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
    }
}
