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
        let expected = 4 * tension * (depth - block / 2) / 1.2

        let coarse = try beamLoad(elementSize: 0.025)
        let fine = try beamLoad(elementSize: 0.0125)
        // The compression zone (10 mm) is thinner than an element on either mesh, so the
        // element's bending carries part of the moment and the coarse mesh overestimates it
        // slightly; refining the mesh closes in on the section analysis.
        #expect(abs(coarse - expected) / expected < 0.15, "coarse: \(coarse) N against \(expected) N")
        #expect(abs(fine - expected) / expected < 0.1, "fine: \(fine) N against \(expected) N")
        #expect(abs(fine - expected) < abs(coarse - expected), "coarse \(coarse) N, fine \(fine) N")
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
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                // Both supports are rollers; the loading line holds the beam in place lengthwise,
                // so no arch can form between a support and the load.
                nodes[solver.nodeIndex(left, j, 0)].restrain(y: true, z: true)
                nodes[solver.nodeIndex(right, j, 0)].restrain(y: true, z: true)
                let load = solver.nodeIndex(middle, j, solver.ez)
                nodes[load].isPrescribed = true
                nodes[load].velocity = SIMD3(0, 0, -rate)
            }
        }

        var plateau: [Float] = []
        let stepsPerSample = Int(0.0008 / solver.criticalTimeStep)
        while solver.time < 0.1 {
            solver.advance(steps: stepsPerSample)
            let deflection = -solver.displacement(middle, solver.ey / 2, solver.ez).z
            var reaction: Float = 0
            for j in 0...solver.ey { reaction += solver.nodalForce(middle, j, solver.ez).z }
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
}
