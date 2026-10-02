import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Verification of the explicit finite-element solver against beam and wave theory.
@Suite("Structure verification")
struct StructureVerificationTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A free-floating bar along x, raised clear of the ground.
    private func makeBar(
        length: Float, side: Float, elementSize: Float, material: StructureMaterial
    ) throws -> StructureSolver {
        let model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(length, side, 1 + side))], material: material,
            elementSize: elementSize, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        return solver
    }

    @Test("Nodal masses add up to the mass of the body")
    func lumpedMass() throws {
        let material = StructureMaterial.reinforcedConcrete
        let model = StructureModel(
            solids: [Box(x: 0...2, y: 0...0.25, height: 1.5)],
            openings: [Box(min: SIMD3(0.5, 0, 0.5), max: SIMD3(1.5, 0.25, 1))],
            material: material, elementSize: 0.125)
        let solver = try StructureSolver(device: device, model: model)

        #expect(solver.elementCount == (16 * 12 - 8 * 4) * 2)
        var mass: Float = 0
        var fixed = 0
        solver.mutateNodes { nodes in
            for node in nodes {
                mass += node.mass
                if node.isFixed { fixed += 1 }
            }
        }
        let expected = material.density * (2 * 1.5 - 1 * 0.5) * 0.25
        #expect(abs(mass - expected) / expected < 1e-4)
        #expect(fixed == 17 * 3)
        #expect(solver.flag(0, 0, 0) == .active)
        #expect(solver.flag(8, 0, 6) == .empty)
    }

    @Test("A bar striking a rigid wall sends back a stress wave of rho c v at speed c")
    func elasticWave() throws {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0)
        let length: Float = 2
        let solver = try makeBar(length: length, side: 0.1, elementSize: 0.05, material: material)
        let impactSpeed: Float = 1
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        let index = solver.nodeIndex(i, j, k)
                        nodes[index].vx = -impactSpeed
                        if i == 0 {
                            nodes[index].isFixed = true
                            nodes[index].vx = 0
                        }
                    }
                }
            }
        }

        let waveSpeed = (material.youngsModulus / material.density).squareRoot()
        let steps = Int((0.6 * length / waveSpeed / solver.criticalTimeStep).rounded())
        solver.advance(steps: steps)
        let front = Float(solver.time) * waveSpeed
        #expect(abs(front - 0.6 * length) < 0.05)

        // Behind the front the bar has stopped and carries the full impact stress.
        let expectedStress = -material.density * waveSpeed * impactSpeed
        let behind = Int(0.3 * length / 0.05)
        #expect(abs(solver.stress(behind, 0, 0)[0] - expectedStress) / abs(expectedStress) < 0.05)
        #expect(abs(solver.node(behind, 1, 1).vx) < 0.05)
        // Ahead of it the bar is still moving freely.
        let ahead = Int(0.85 * length / 0.05)
        #expect(abs(solver.stress(ahead, 0, 0)[0]) / abs(expectedStress) < 0.05)
        #expect(abs(solver.node(ahead, 1, 1).vx + impactSpeed) < 0.05)
    }

    /// A 2 m cantilever of 250 mm square section along x, clamped at x = 0.
    private func makeCantilever() throws -> StructureSolver {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)
        let model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(2, 0.25, 1.25))], material: material,
            elementSize: 0.0625, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey { nodes[solver.nodeIndex(0, j, k)].isFixed = true }
            }
        }
        return solver
    }

    private struct CantileverTheory {
        let load: Float = 2400 * 9.81 * 0.0625  // weight per metre
        let stiffness: Float = 20e9 * 0.25 * 0.25 * 0.25 * 0.25 / 12  // E I
        let length: Float = 2

        /// Tip deflection under self-weight, including shear deformation.
        var deflection: Float {
            let shear: Float = 20e9 / 2.4 * (5 / 6) * 0.0625
            return load * pow(length, 4) / (8 * stiffness) + load * length * length / (2 * shear)
        }

        /// Period of the first bending mode (Euler-Bernoulli).
        var period: Float {
            2 * .pi * length * length / 3.516 * (2400 * 0.0625 / stiffness).squareRoot()
        }
    }

    @Test("A cantilever sags under its own weight as beam theory predicts")
    func cantileverDeflection() throws {
        let solver = try makeCantilever()
        let theory = CantileverTheory()
        // Near-critical damping of the first mode brings the beam to rest quickly.
        solver.damping = 2 * 2 * .pi / theory.period
        solver.advance(steps: Int(5 * theory.period / solver.criticalTimeStep))

        let tip = solver.displacement(solver.ex, 2, 2)
        #expect(abs(-tip.z - theory.deflection) / theory.deflection < 0.05, "tip deflection \(-tip.z) m")
        #expect(abs(tip.y) < 1e-6)
        #expect(solver.summary().erodedElements == 0)
    }

    @Test("A released cantilever swings at its first natural frequency")
    func cantileverPeriod() throws {
        let solver = try makeCantilever()
        let theory = CantileverTheory()
        let stride = 20
        let samples = Int(1.5 * theory.period / solver.criticalTimeStep) / stride
        var lowest: (time: Double, deflection: Float) = (0, 0)
        for _ in 0..<samples {
            solver.advance(steps: stride)
            let deflection = -solver.displacement(solver.ex, 2, 2).z
            if deflection > lowest.deflection { lowest = (solver.time, deflection) }
        }

        // Released from rest, the tip reaches its lowest point after half a period, at about
        // twice the static deflection.
        let halfPeriod = Double(theory.period) / 2
        #expect(abs(lowest.time - halfPeriod) / halfPeriod < 0.05, "half period \(lowest.time) s")
        #expect(abs(lowest.deflection / theory.deflection - 2) < 0.15, "overshoot \(lowest.deflection) m")
    }

    @Test("A spinning body keeps its shape, energy and angular momentum")
    func rigidRotation() throws {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)
        let solver = try makeBar(length: 0.8, side: 0.4, elementSize: 0.1, material: material)
        let centre = SIMD3<Float>(0.4, 0.2, 1.2)
        let spin: Float = 50  // rad/s about z
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        let r = solver.referencePosition(i, j, k) - centre
                        nodes[solver.nodeIndex(i, j, k)].velocity = SIMD3(-spin * r.y, spin * r.x, 0)
                    }
                }
            }
        }

        func invariants() -> (energy: Double, angularMomentum: Double) {
            var energy = 0.0
            var momentum = 0.0
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        let node = solver.node(i, j, k)
                        let r = solver.position(i, j, k) - centre
                        energy += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                        momentum += Double(node.mass) * Double(r.x * node.vy - r.y * node.vx)
                    }
                }
            }
            return (energy, momentum)
        }

        let before = invariants()
        // A quarter turn.
        solver.advance(steps: Int((Float.pi / 2 / spin / solver.criticalTimeStep).rounded()))
        let after = invariants()
        #expect(abs(after.energy - before.energy) / before.energy < 0.01)
        #expect(abs(after.angularMomentum - before.angularMomentum) / before.angularMomentum < 0.005)

        // The long edge started along x and should now lie along y, at its original length.
        let edge = solver.position(solver.ex, 0, 0) - solver.position(0, 0, 0)
        #expect(abs(simd_length(edge) - 0.8) < 1e-3)
        #expect(abs(edge.x) < 0.02 && abs(edge.y - 0.8) < 1e-3, "edge \(edge)")
        // Only the small centrifugal stress should be present, not stress from the rotation itself.
        let stress = solver.stress(4, 2, 2).map { abs($0) }.max() ?? 0
        #expect(stress < 1e6, "stress \(stress) Pa")
    }

    private static let ductile = StructureMaterial(
        name: "Test", density: 2400, youngsModulus: 20e9, poissonRatio: 0.2, yieldStress: 7e6,
        failureStrain: 0.02)

    /// Starts every cross-section of a 1 m bar stretching at the same strain rate.
    private func stretch(_ solver: StructureSolver, strainRate: Float) {
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        nodes[solver.nodeIndex(i, j, k)].vx = strainRate * (Float(i) * 0.05 - 0.5)
                    }
                }
            }
        }
    }

    @Test("A stretched bar yields on the von Mises surface")
    func yielding() throws {
        let material = Self.ductile
        let solver = try makeBar(length: 1, side: 0.1, elementSize: 0.05, material: material)
        let strainRate: Float = 20
        stretch(solver, strainRate: strainRate)

        // Three times the yield strain, before release waves from the free ends reach the middle.
        let yieldStrain = material.yieldStress / material.youngsModulus
        solver.advance(steps: Int(3 * yieldStrain / strainRate / solver.criticalTimeStep))

        let s = solver.stress(10, 0, 0)
        let mean = (s[0] + s[1] + s[2]) / 3
        let deviatoric = pow(s[0] - mean, 2) + pow(s[1] - mean, 2) + pow(s[2] - mean, 2)
        let equivalent = (1.5 * (deviatoric + 2 * (s[3] * s[3] + s[4] * s[4] + s[5] * s[5]))).squareRoot()
        #expect(
            abs(equivalent - material.yieldStress) / material.yieldStress < 0.01, "von Mises \(equivalent) Pa"
        )
        #expect(s[0] > 0.9 * material.yieldStress, "axial stress \(s[0]) Pa")
        #expect(solver.plasticStrain(10, 0, 0) > 0.5 * yieldStrain)
        #expect(solver.summary().erodedElements == 0)
    }

    @Test("A notched bar breaks at the notch and nowhere else")
    func failureAtNotch() throws {
        // Remove half of the cross-section at mid-length.
        let model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(1, 0.1, 1.1))],
            openings: [Box(min: SIMD3(0.5, 0, 1.05), max: SIMD3(0.55, 0.1, 1.1))],
            material: Self.ductile, elementSize: 0.05, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        stretch(solver, strainRate: 20)
        solver.advance(steps: Int(0.006 / solver.criticalTimeStep))

        let summary = solver.summary()
        #expect(
            summary.erodedElements >= 2 && summary.erodedElements <= 12, "eroded \(summary.erodedElements)")
        for k in 0..<solver.ez {
            for j in 0..<solver.ey {
                for i in 0..<solver.ex where solver.flag(i, j, k) == .eroded {
                    #expect(abs(i - 10) <= 1, "element \(i) eroded away from the notch")
                }
            }
        }
        // The two halves have parted company.
        let length = solver.position(solver.ex, 0, 0).x - solver.position(0, 0, 0).x
        #expect(length > 1.02, "end-to-end length \(length) m")
    }

    // MARK: Contact

    @Test("Each part of a structure takes its own material's density, stiffness and time step")
    func severalMaterials() throws {
        let soft = StructureMaterial.elastic(density: 1000, youngsModulus: 2e9, poissonRatio: 0)
        let stiff = StructureMaterial.elastic(density: 8000, youngsModulus: 200e9, poissonRatio: 0)
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(1, 0.25, 1.25)),
                Box(min: SIMD3(1, 0, 1), max: SIMD3(2, 0.25, 1.25)),
            ], material: soft, elementSize: 0.125, fixedBase: false)
        model.setMaterial(stiff, of: 1)
        #expect(model.materials == [soft, stiff])
        #expect(model.materialIndex(at: SIMD3(1.5, 0.1, 1.1)) == 1)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false

        // Mass: each half its own density.
        var mass: Float = 0
        solver.mutateNodes { nodes in mass = nodes.reduce(0) { $0 + $1.mass } }
        let volume: Float = 1 * 0.25 * 0.25
        #expect(abs(mass - (1000 + 8000) * volume) / mass < 1e-5)
        // The time step is set by the stiffer material's wave speed.
        #expect(
            abs(solver.criticalTimeStep - solver.timeStepSafety * 0.125 / stiff.dilatationalWaveSpeed) < 1e-9)

        // Pulled slowly from the free end, the two halves stretch in inverse proportion to their
        // stiffness, like springs in series.
        let rate: Float = 0.004
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    nodes[solver.nodeIndex(0, j, k)].isFixed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].isPrescribed = true
                    nodes[solver.nodeIndex(solver.ex, j, k)].velocity = SIMD3(rate, 0, 0)
                }
            }
        }
        solver.damping = 500
        solver.advance(steps: Int(0.25 / solver.criticalTimeStep))
        let joint = solver.displacement(8, 1, 1).x
        let end = solver.displacement(16, 1, 1).x
        let ratio = joint / (end - joint)
        #expect(abs(ratio - 100) / 100 < 0.05, "soft half stretched \(ratio) times as much as the stiff one")
        // The same stress runs through both, and the soft half's follows its own modulus.
        let softStress = solver.stress(3, 0, 0)[0]
        let stiffStress = solver.stress(12, 0, 0)[0]
        #expect(abs(softStress - stiffStress) / softStress < 0.03, "\(softStress) and \(stiffStress) Pa")
        let softStrain = (solver.displacement(4, 1, 1).x - solver.displacement(3, 1, 1).x) / 0.125
        #expect(abs(softStress - soft.youngsModulus * softStrain) / softStress < 0.03)
    }

    @Test("Where solids overlap the later one's material wins, and plain materials ignore bars")
    func materialAssignment() throws {
        let concrete = StructureMaterial.reinforcedConcrete
        let masonry = StructureMaterial.masonry
        let wall = Box(x: 0...0.25, y: 0...2, height: 2)
        let panel = Box(min: SIMD3(0, 0.5, 0.5), max: SIMD3(0.25, 1.5, 1.5))
        var model = StructureModel(solids: [wall, panel], material: concrete, elementSize: 0.0625)
        model.setMaterial(masonry, of: 1)
        model.autoReinforce()
        let solver = try StructureSolver(device: device, model: model)
        #expect(solver.materials == [concrete, masonry])
        // Inside the panel: masonry, so no steel even though the wall's mats run through it.
        let inside = solver.elementIndex(1, 16, 16)
        let outside = solver.elementIndex(1, 4, 4)
        #expect(solver.steelRatio(1, 16, 16) == .zero)
        #expect(solver.steelRatio(1, 4, 4) != .zero || solver.steelRatio(0, 4, 4) != .zero)
        _ = (inside, outside)
        // Removing the panel takes its material setting with it.
        model.removeSolid(at: 1)
        #expect(model.materials == [concrete])
        // At most eight materials.
        var crowded = StructureModel(
            solids: (0..<9).map { Box(x: Float($0)...Float($0) + 0.5, y: 0...0.5, height: 0.5) },
            elementSize: 0.125)
        for index in 1..<9 {
            crowded.setMaterial(
                .elastic(density: 2000 + Float(index), youngsModulus: 1e9, poissonRatio: 0.2), of: index)
        }
        #expect(throws: BlastError.self) { try StructureSolver(device: device, model: crowded) }
    }

    @Test("Two blocks that collide head-on bounce apart without overlapping")
    func collision() throws {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)
        let model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(0.5, 0.5, 1.5)),
                Box(min: SIMD3(0.75, 0, 1), max: SIMD3(1.25, 0.5, 1.5)),
            ], material: material, elementSize: 0.125, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.contactMode = .always
        let speed: Float = 4
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex { nodes[solver.nodeIndex(i, j, k)].vx = i <= 4 ? speed : -speed }
                }
            }
        }

        /// Mean x velocity of each block, and the gap between their facing surfaces.
        func observe() -> (left: Float, right: Float, gap: Float) {
            var sums = SIMD2<Float>.zero
            var gap = Float.infinity
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        let node = solver.node(i, j, k)
                        guard node.mass > 0 else { continue }
                        sums[i <= 4 ? 0 : 1] += node.vx / 125
                    }
                    gap = min(gap, solver.position(6, j, k).x - solver.position(4, j, k).x)
                }
            }
            return (sums[0], sums[1], gap)
        }

        // The surfaces meet after about 760 steps; watch that interval closely.
        solver.advance(steps: 700)
        var closest = Float.infinity
        for _ in 0..<100 {
            solver.advance(steps: 4)
            closest = min(closest, observe().gap)
        }
        solver.advance(steps: 1000)
        let after = observe()
        // Nodes are spheres one element across, so surfaces meet when they are 0.125 m apart.
        #expect(closest > 0.1 && closest < 0.125, "closest approach \(closest) m")
        #expect(after.left < -1 && after.right > 1, "velocities \(after.left), \(after.right) m/s")
        #expect(after.gap > 0.125)
        let momentum = solver.momentum().x
        #expect(abs(momentum) < 0.01 * Double(material.density * 0.125 * speed), "momentum \(momentum)")
    }

    @Test("A node resting on a support is held up but not held down")
    func oneSidedSupport() throws {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)
        let model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(0.5, 0.5, 1.5))], material: material,
            elementSize: 0.125, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        solver.damping = 20
        solver.mutateNodes { nodes in
            for j in 0...solver.ey {
                for i in 0...solver.ex { nodes[solver.nodeIndex(i, j, 0)].restsOnSupport = true }
            }
        }
        // Under its own weight it sits on the support...
        solver.advance(steps: Int(0.3 / solver.criticalTimeStep))
        for (i, j) in [(0, 0), (2, 2), (4, 4)] {
            #expect(solver.node(i, j, 0).uz >= 0 && solver.node(i, j, 0).uz < 1e-6)
        }
        #expect(abs(solver.node(2, 2, 4).vz) < 0.01)
        // ...and thrown upwards it leaves it, in free flight.
        solver.damping = 0
        solver.mutateNodes { nodes in
            for index in nodes.indices where nodes[index].mass > 0 { nodes[index].velocity = SIMD3(0, 0, 2) }
        }
        let flight = 0.1
        solver.advance(steps: Int(flight / Double(solver.criticalTimeStep)))
        let expected = Float(2 * flight - 0.5 * 9.81 * flight * flight)
        #expect(abs(solver.node(2, 2, 0).uz - expected) < 0.01, "rose \(solver.node(2, 2, 0).uz) m")
    }

    @Test("A block dropped onto another comes to rest on it")
    func stacking() throws {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.2)
        // The upper block starts two elements clear of the lower, which is clamped to the ground.
        let model = StructureModel(
            solids: [
                Box(x: 0...0.5, y: 0...0.5, height: 0.5),
                Box(min: SIMD3(0, 0, 0.75), max: SIMD3(0.5, 0.5, 1.25)),
            ], material: material, elementSize: 0.125)
        let solver = try StructureSolver(device: device, model: model)
        solver.contactMode = .always
        solver.damping = 20
        solver.advance(steps: Int(0.5 / solver.criticalTimeStep))

        // It falls one element (surfaces touch when nodes are an element apart) and stays there.
        for (i, j) in [(0, 0), (2, 2), (4, 4)] {
            let node = solver.node(i, j, 6)
            #expect(abs(node.uz + 0.125) < 2e-3, "drop \(node.uz) m")
            #expect(abs(node.vz) < 0.02, "velocity \(node.vz) m/s")
        }
        #expect(abs(solver.node(2, 2, 10).ux) < 2e-3)
    }
}
