import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Checks the shell elements against plate and beam theory.
@Suite("Shell elements")
struct ShellTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Elastic, without Poisson's ratio, so that a strip bends exactly as a beam.
    private static let elastic = StructureMaterial.elastic(
        density: 2400, youngsModulus: 20e9, poissonRatio: 0)

    @Test("Walls and roof share nodes along the lines where they meet, and openings are left out")
    func buildingMesh() throws {
        var model = try #require(ScenarioPreset.concreteBox.scenario.structure)
        model.elementKind = .shell
        model.elementSize = 0.25
        let mesh = try ShellMesh(model: model)
        // The front wall's midsurface is at x = 16.125, the roof's at z = 3.375.
        let front = mesh.positions.indices.filter { abs(mesh.positions[$0].x - 16.125) < 1e-4 }
        let roof = Set(mesh.positions.indices.filter { abs(mesh.positions[$0].z - 3.375) < 1e-4 })
        let shared = front.filter { roof.contains($0) }
        // Along y from 11.125 to 20.875 on 0.25 m elements (with the window edges as breakpoints).
        #expect(shared.count >= 40, "\(shared.count) nodes shared by the front wall and the roof")
        // No element is larger than asked for, nor much smaller.
        for element in mesh.elements {
            #expect(element.size.max() <= 0.25 + 1e-4)
            #expect(element.size.min() >= 0.1)
        }
        // A window in the front wall: no element centre inside it.
        for element in mesh.elements
        where element.axis == 0 && abs(mesh.positions[Int(element.nodes.x)].x - 16.125) < 1e-4 {
            let corners = (0..<4).map { mesh.positions[Int(element.nodes[$0])] }
            let centre = corners.reduce(SIMD3<Float>.zero, +) / 4
            #expect(!(centre.y > 12.5 && centre.y < 14.5 && centre.z > 1 && centre.z < 2.25))
        }
        // Every wall has a mat of bars near each face.
        for element in mesh.elements {
            #expect(element.bars.count == 2)
        }
        #expect(throws: BlastError.self) {
            var columns = model
            // A block as long as it is wide is neither a wall nor a column.
            columns.solids.append(Box(x: 18...18.4, y: 15...15.4, height: 0.4))
            _ = try ShellMesh(model: columns)
        }
    }

    /// A strip 2 m long, 0.5 m wide and 100 mm thick, clamped at x = 0.
    private func cantilever(elementSize: Float = 0.125) throws -> ShellSolver {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(2, 0.5, 1.1))], material: Self.elastic,
            elementSize: elementSize, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        let clamped = solver.nodes { $0.x < 1e-4 }
        solver.mutateNodes { nodes in
            for n in clamped { nodes[n].isClamped = true }
        }
        return solver
    }

    @Test("A cantilever strip sags under its own weight as beam theory says")
    func cantileverSag() throws {
        let solver = try cantilever()
        solver.damping = 40
        solver.advance(steps: Int(1.5 / solver.criticalTimeStep))
        // w = q L^4 / (8 E I) with q = rho g t and I = t^3 / 12 per unit width; shear adds
        // q L^2 / (2 k G t), under 1%.
        let bending = 12 * 2400 * 9.81 * pow(2, 4) / (8 * 20e9 * 0.01)
        let shear = 2400 * 9.81 * 0.1 * 4 / (2 * (5.0 / 6.0) * 10e9 * 0.1)
        let expected = Float(bending + shear)
        for y: Float in [0, 0.25, 0.5] {
            let tip = solver.node(solver.nearestNode(to: SIMD3(2, y, 1.05))).displacement.z
            #expect(abs(-tip - expected) / expected < 0.02, "tip \(tip) m, expected \(-expected) m")
        }
    }

    @Test("Released, it swings at the cantilever's natural period")
    func cantileverPeriod() throws {
        let solver = try cantilever()
        let tip = solver.nearestNode(to: SIMD3(2, 0.25, 1.05))
        // Gravity applied suddenly: the tip oscillates about its static sag.
        var samples: [(Double, Float)] = []
        let step = solver.criticalTimeStep
        let chunk = max(1, Int(0.002 / step))
        while solver.time < 0.8 {
            solver.advance(steps: chunk)
            samples.append((solver.time, solver.node(tip).displacement.z))
        }
        // Times at which the tip passes back up through its mean position.
        let mean = samples.map(\.1).reduce(0, +) / Float(samples.count)
        var crossings: [Double] = []
        for (before, after) in zip(samples, samples.dropFirst()) where before.1 < mean && after.1 >= mean {
            let fraction = Double((mean - before.1) / (after.1 - before.1))
            crossings.append(before.0 + fraction * (after.0 - before.0))
        }
        let period = try #require(
            crossings.count >= 2 ? (crossings.last! - crossings.first!) / Double(crossings.count - 1) : nil)
        // f = (1.875^2 / 2 pi) sqrt(E I / (rho A L^4)).
        let frequency = 1.875 * 1.875 / (2 * Double.pi) * (20e9 * 0.001 / 12 / (2400 * 0.1 * 16)).squareRoot()
        #expect(abs(period * frequency - 1) < 0.03, "period \(period) s, expected \(1 / frequency) s")
    }

    @Test("A plate hanging from its top edge stretches under its own weight")
    func hangingStretch() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 0), max: SIMD3(1, 0.1, 4))], material: Self.elastic,
            elementSize: 0.25, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 2
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.damping = 400
        let top = solver.nodes { $0.z > 4 - 1e-4 }
        solver.mutateNodes { nodes in
            for n in top { nodes[n].isClamped = true }
        }
        solver.advance(steps: Int(0.1 / solver.criticalTimeStep))
        // Elongation of a bar under its own weight: rho g L^2 / (2 E).
        let expected: Float = 2400 * 9.81 * 16 / (2 * 20e9)
        let bottom = solver.node(solver.nearestNode(to: SIMD3(0.5, 0.05, 0))).displacement.z
        #expect(
            abs(-bottom - expected) / expected < 0.02, "bottom moved \(bottom) m, expected \(-expected) m")
    }

    @Test("A simply supported square plate under pressure deflects as Navier's solution")
    func navierPlate() throws {
        let material = StructureMaterial.elastic(density: 2400, youngsModulus: 20e9, poissonRatio: 0.3)
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(2, 2, 1.04))], material: material,
            elementSize: 0.125,
            fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 4
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.damping = 30
        let pressure: Float = 2000
        solver.appliedLoad = PressureLoad(
            axis: 2, positiveSide: true, history: [SIMD2(0, pressure), SIMD2(100, pressure)])
        let edges = solver.nodes { $0.x < 1e-4 || $0.x > 2 - 1e-4 || $0.y < 1e-4 || $0.y > 2 - 1e-4 }
        let corner = solver.nearestNode(to: SIMD3(0, 0, 1.02))
        let side = solver.nearestNode(to: SIMD3(2, 0, 1.02))
        solver.mutateNodes { nodes in
            for n in edges { nodes[n].restrain(z: true) }
            nodes[corner].restrain(x: true, y: true)
            nodes[side].restrain(y: true)
        }
        solver.advance(steps: Int(1.0 / solver.criticalTimeStep))
        // w = 0.00406 q a^4 / D, D = E t^3 / (12 (1 - nu^2)).
        let rigidity = 20e9 * pow(0.04, 3) / (12 * (1 - 0.09))
        let expected = Float(0.00406 * Double(pressure) * 16 / rigidity)
        let middle = solver.node(solver.nearestNode(to: SIMD3(1, 1, 1.02))).displacement.z
        #expect(abs(-middle - expected) / expected < 0.03, "middle \(middle) m, expected \(-expected) m")
    }

    @Test("A free plate spun through a right angle stays unstrained")
    func rigidRotation() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(-1, -0.5, -0.05), max: SIMD3(1, 0.5, 0.05))], material: Self.elastic,
            elementSize: 0.25, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 2
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        // Spinning about the y axis, in the plane of the plate: a rotation that tilts the normals.
        let rate: Float = 2
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            for n in nodes.indices {
                nodes[n].velocity = cross(SIMD3(0, rate, 0), positions[n])
                nodes[n].spin = SIMD3(0, rate, 0)
            }
        }
        let energy = solver.kineticEnergy()
        let quarter = Double.pi / 2 / Double(rate)
        solver.advance(steps: Int(quarter / Double(solver.criticalTimeStep)))
        // The ends have swung from x = +-1 to z = -+1, give or take the last part step, and the
        // plate's length is unchanged.
        let a = solver.position(solver.nearestNode(to: SIMD3(1, 0, 0)))
        let b = solver.position(solver.nearestNode(to: SIMD3(-1, 0, 0)))
        #expect(abs(simd_distance(a, b) - 2) < 1e-3, "length \(simd_distance(a, b)) m")
        #expect(abs(a.z + 1) < 0.02 && abs(a.x) < 0.02, "end at \(a)")
        // All the energy is still in the rotation: nothing went into straining the plate.
        #expect(abs(solver.kineticEnergy() - energy) / energy < 1e-3)
    }

    @Test("A reinforced concrete strip reaches the moment capacity given by section analysis")
    func beamCapacity() throws {
        // Section analysis with a rectangular stress block, as for the solid elements.
        let fc: Float = 30e6
        let yield = SteelProperties.grade500.yieldStress
        let width: Float = 0.4
        let depth: Float = 0.15 - 0.0375
        let tension = 500e-6 * width * yield
        let block = tension / (0.85 * fc * width)
        let expected = tension * (depth - block / 2) / (1.2 / 4 - 0.05 / 8)

        let coarse = try beamLoad(elementSize: 0.05)
        let fine = try beamLoad(elementSize: 0.025)
        #expect(abs(coarse - expected) / expected < 0.1, "coarse: \(coarse) N against \(expected) N")
        #expect(abs(fine - expected) / expected < 0.1, "fine: \(fine) N against \(expected) N")
        #expect(abs(fine - coarse) / coarse < 0.05, "coarse \(coarse) N, fine \(fine) N")
    }

    /// Plateau load of a 1.2 m span, 400 mm wide, 150 mm deep reinforced strip in three-point
    /// bending under displacement control, through a loading plate 50 mm wide.
    private func beamLoad(elementSize h: Float) throws -> Float {
        var steel = SteelProperties.grade500
        steel.ultimateStress = steel.yieldStress
        steel.ruptureStrain = 10
        var material = StructureMaterial.concrete(name: "Test", compressiveStrength: 30e6, steel: steel)
        material.poissonRatio = 0.2
        let beam = Box(min: SIMD3(0, 0, 1), max: SIMD3(1.3, 0.4, 1.15))
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        model.addMat(
            to: beam, thicknessAxis: 2, areaPerMetre: 500e-6, transverseAreaPerMetre: 0, longitudinalAxis: 0,
            depth: 0.0375, faces: (low: true, high: false))
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100
        let rate: Float = 0.12
        let supports = solver.nodes { abs($0.x - 0.05) < 1e-4 || abs($0.x - 1.25) < 1e-4 }
        let load = solver.nodes { abs($0.x - 0.65) <= 0.025 + 1e-4 }
        let middle = solver.nearestNode(to: SIMD3(0.65, 0.2, 1.075))
        solver.mutateNodes { nodes in
            for n in supports { nodes[n].restrain(y: true, z: true) }
            for n in load {
                nodes[n].isPrescribed = true
                nodes[n].velocity = SIMD3(0, 0, -rate)
            }
        }
        var plateau: [Float] = []
        let stepsPerSample = max(1, Int(0.0008 / solver.criticalTimeStep))
        while solver.time < 0.1 {
            solver.advance(steps: stepsPerSample)
            let deflection = -solver.node(middle).displacement.z
            let reaction = load.reduce(Float(0)) { $0 + solver.nodalForce($1).z }
            if deflection > 0.006 { plateau.append(reaction) }
        }
        #expect(!plateau.isEmpty)
        return plateau.reduce(0, +) / Float(max(plateau.count, 1))
    }

    @Test("Two plates thrown face-on at each other bounce apart instead of passing through")
    func collision() throws {
        var model = StructureModel(
            solids: [
                Box(min: SIMD3(0, 0, 1), max: SIMD3(0.1, 1, 2)),
                Box(min: SIMD3(1, 0, 1), max: SIMD3(1.1, 1, 2)),
            ], material: Self.elastic, elementSize: 0.25, fixedBase: false)
        model.elementKind = .shell
        model.shellLayers = 2
        let solver = try ShellSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.contactMode = .always
        let speed: Float = 4
        let positions = solver.referencePositions
        solver.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].vx = positions[n].x < 0.5 ? speed : -speed }
        }
        func gap() -> Float {
            let left = solver.nodes { $0.x < 0.5 }.map { solver.position($0).x }.max() ?? 0
            let right = solver.nodes { $0.x > 0.5 }.map { solver.position($0).x }.min() ?? 0
            return right - left
        }
        var closest = Float.infinity
        let chunk = max(1, Int(0.002 / solver.criticalTimeStep))
        while solver.time < 0.25 {
            solver.advance(steps: chunk)
            closest = min(closest, gap())
        }
        // Nodes are spheres one element (0.25 m) across, so the plates turn back at about that
        // (sampled every 2 ms, which can miss the closest moment).
        #expect(closest > 0.15 && closest < 0.27, "closest approach \(closest) m")
        #expect(gap() > 0.25, "gap at the end \(gap()) m")
        let momentum = solver.momentum().x
        #expect(abs(momentum) < 0.01 * 2400 * 0.1 * 1 * Double(speed), "momentum \(momentum)")
    }

    // MARK: Beams

    @Test("Frames mesh with beams on their columns, sharing nodes with the slabs")
    func frameMesh() throws {
        var model = try #require(ScenarioPreset.threeStorey.scenario.structure)
        model.elementKind = .shell
        model.elementSize = 0.25
        let mesh = try ShellMesh(model: model)
        // Twelve columns, each from the ground to the roof slab's midsurface.
        let columnCentres = Set(
            mesh.beams.map { beam -> SIMD2<Float> in
                let p = mesh.positions[Int(beam.nodes.x)]
                return SIMD2(p.x, p.y)
            })
        #expect(columnCentres.count == 12)
        #expect(mesh.beams.allSatisfy { $0.axis == 2 && $0.bars.count == 4 && $0.tieRatio > 0 })
        // Every column node at a slab's midsurface is also a node of that slab.
        let slabNodes = Set(
            mesh.elements.filter { $0.axis == 2 }.flatMap { e in (0..<4).map { Int(e.nodes[$0]) } })
        let levels: [Float] = [3.375, 6.875, 10.375]
        for beam in mesh.beams {
            for end in 0..<2 {
                let n = Int(beam.nodes[end])
                if levels.contains(where: { abs(mesh.positions[n].z - $0) < 1e-4 }) {
                    #expect(slabNodes.contains(n))
                }
            }
        }
        let top = mesh.beams.map { max(mesh.positions[Int($0.nodes.x)].z, mesh.positions[Int($0.nodes.y)].z) }
            .max()
        #expect(abs((top ?? 0) - 10.375) < 1e-4)
    }

    /// A beam 3 m long along x with a 200 mm wide, 300 mm deep section, clamped at x = 0.
    private func cantileverBeam() throws -> ShellSolver {
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(3, 0.2, 1.3))], material: Self.elastic,
            elementSize: 0.25,
            fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        #expect(solver.beamCount == 12 && solver.elementCount == 0)
        solver.groundContact = false
        let clamped = solver.nodes { $0.x < 1e-4 }
        solver.mutateNodes { nodes in
            for n in clamped { nodes[n].isClamped = true }
        }
        return solver
    }

    @Test("A cantilever beam sags under its own weight as beam theory says")
    func beamSag() throws {
        let solver = try cantileverBeam()
        solver.damping = 40
        solver.advance(steps: Int(1.5 / solver.criticalTimeStep))
        // q L^4 / (8 E I) with I = b d^3 / 12, plus q L^2 / (2 k G A) for shear.
        let q = 2400 * 9.81 * 0.06
        let expected = Float(q * 81 / (8 * 20e9 * 0.2 * 0.027 / 12) + q * 9 / (2 * (5.0 / 6.0) * 10e9 * 0.06))
        let tip = solver.node(solver.nearestNode(to: SIMD3(3, 0.1, 1.15))).displacement.z
        #expect(abs(-tip - expected) / expected < 0.02, "tip \(tip) m, expected \(-expected) m")
    }

    @Test("A free beam spun through a right angle stays unstrained")
    func beamRigidRotation() throws {
        var model = StructureModel(
            solids: [Box(min: SIMD3(-1.5, -0.1, -0.15), max: SIMD3(1.5, 0.1, 0.15))], material: Self.elastic,
            elementSize: 0.25, fixedBase: false)
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        let rate: Float = 2
        let positions = solver.referencePositions
        // About z, which bends the beam's axis towards y, and about x, which twists it.
        for axis in [SIMD3<Float>(0, 0, rate), SIMD3<Float>(rate, 0, 0)] {
            solver.reset()
            solver.mutateNodes { nodes in
                for n in nodes.indices {
                    nodes[n].velocity = cross(axis, positions[n])
                    nodes[n].spin = axis
                }
            }
            let energy = solver.kineticEnergy()
            solver.advance(steps: Int(Double.pi / 2 / Double(rate) / Double(solver.criticalTimeStep)))
            let a = solver.position(solver.nearestNode(to: SIMD3(1.5, 0, 0)))
            let b = solver.position(solver.nearestNode(to: SIMD3(-1.5, 0, 0)))
            #expect(abs(simd_distance(a, b) - 3) < 1e-3, "length \(simd_distance(a, b)) m")
            #expect(abs(solver.kineticEnergy() - energy) / energy < 1e-3)
        }
    }

    @Test("A reinforced concrete beam reaches the moment capacity given by section analysis")
    func beamElementCapacity() throws {
        let yield = SteelProperties.grade500.yieldStress
        let width: Float = 0.1
        let depth: Float = 0.15 - 0.0375
        let tension = 500e-6 * width * yield
        let block = tension / (0.85 * 30e6 * width)
        let expected = tension * (depth - block / 2) / (1.2 / 4)
        let coarse = try beamElementLoad(elementSize: 0.05)
        let fine = try beamElementLoad(elementSize: 0.025)
        #expect(abs(coarse - expected) / expected < 0.1, "coarse: \(coarse) N against \(expected) N")
        #expect(abs(fine - expected) / expected < 0.1, "fine: \(fine) N against \(expected) N")
        #expect(abs(fine - coarse) / coarse < 0.05, "coarse \(coarse) N, fine \(fine) N")
    }

    /// Plateau load of the solid elements' test beam, 1.2 m span, 100 mm wide and 150 mm deep,
    /// meshed with beams and loaded at mid-span under displacement control.
    private func beamElementLoad(elementSize h: Float) throws -> Float {
        var steel = SteelProperties.grade500
        steel.ultimateStress = steel.yieldStress
        steel.ruptureStrain = 10
        var material = StructureMaterial.concrete(name: "Test", compressiveStrength: 30e6, steel: steel)
        material.poissonRatio = 0.2
        let beam = Box(min: SIMD3(0, 0, 1), max: SIMD3(1.3, 0.1, 1.15))
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        model.addMat(
            to: beam, thicknessAxis: 2, areaPerMetre: 500e-6, transverseAreaPerMetre: 0, longitudinalAxis: 0,
            depth: 0.0375, faces: (low: true, high: false))
        model.elementKind = .shell
        let solver = try ShellSolver(device: device, model: model)
        #expect(solver.beamCount > 0)
        solver.gravity = 0
        solver.groundContact = false
        solver.damping = 100
        let supports = solver.nodes { abs($0.x - 0.05) < 1e-4 || abs($0.x - 1.25) < 1e-4 }
        let load = solver.nearestNode(to: SIMD3(0.65, 0.05, 1.075))
        solver.mutateNodes { nodes in
            for n in supports { nodes[n].restrain(y: true, z: true) }
            nodes[load].isPrescribed = true
            nodes[load].velocity = SIMD3(0, 0, -0.12)
        }
        var plateau: [Float] = []
        let stepsPerSample = max(1, Int(0.0008 / solver.criticalTimeStep))
        while solver.time < 0.1 {
            solver.advance(steps: stepsPerSample)
            if -solver.node(load).displacement.z > 0.006 { plateau.append(solver.nodalForce(load).z) }
        }
        #expect(!plateau.isEmpty)
        return plateau.reduce(0, +) / Float(max(plateau.count, 1))
    }
}
