import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Masonry meshed as units and mortar joints.
@Suite("Masonry units and joints")
struct MasonryTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// Blockwork with courses of three elements and units of six, so the joints fall on element
    /// rows and columns exactly.
    private let size: Float = 0.075

    @Test("Joints are laid in running bond, where the elements are fine enough to show them")
    func runningBond() throws {
        // A wall along x, twelve elements long, nine high and two thick, standing above the ground.
        let wall = Box(min: SIMD3(0, 0, 1), max: SIMD3(12 * size, 2 * size, 1 + 9 * size))
        let model = StructureModel(
            solids: [wall], material: .concreteBlock, elementSize: size, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        for k in 0..<9 {
            for i in 0..<12 {
                let planes = solver.jointPlanes(i, 0, k)
                let course = k / 3
                // Bed joints at the foot of each course; head joints every six elements, offset
                // by three in alternate courses, and none at the wall's end.
                let bed = k % 3 == 0
                let head = course % 2 == 0 ? (i == 6) : (i == 3 || i == 9)
                #expect(planes == (bed ? 4 : 0) | (head ? 1 : 0), "element \(i), \(k): \(planes)")
                #expect(solver.jointPlanes(i, 1, k) == planes)
            }
        }
        // On elements more than half a course high the wall is one material throughout.
        var coarse = model
        coarse.elementSize = 0.15
        let whole = try StructureSolver(device: device, model: coarse)
        #expect((0..<6).allSatisfy { whole.jointPlanes($0, 0, 0) == 0 })
        var off = model
        off.unitJoints = false
        let plain = try StructureSolver(device: device, model: off)
        #expect((0..<12).allSatisfy { plain.jointPlanes($0, 0, 0) == 0 })
    }

    /// A piece of blockwork wall along x, `length` by `height` elements and one thick, held at
    /// one end of `axis` and pulled at the other: the largest nominal stress it carries.
    private func pull(length: Int, height: Int, axis: Int, to strain: Float = 0.003) throws -> Float {
        let wall = Box(min: SIMD3(0, 0, 1), max: SIMD3(Float(length) * size, size, 1 + Float(height) * size))
        let model = StructureModel(
            solids: [wall], material: .concreteBlock, elementSize: size, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        let steps = 20_000
        let span = Float(axis == 0 ? length : height) * size
        let rate = strain * span / (Float(steps) * solver.criticalTimeStep)
        let end = axis == 0 ? length : height
        var pulled: [(Int, Int, Int)] = []
        solver.mutateNodes { nodes in
            for k in 0...height {
                for j in 0...1 {
                    for i in 0...length {
                        let along = axis == 0 ? i : k
                        if along == 0 {
                            nodes[solver.nodeIndex(i, j, k)].isFixed = true
                        } else if along == end {
                            nodes[solver.nodeIndex(i, j, k)].isPrescribed = true
                            nodes[solver.nodeIndex(i, j, k)].velocity[axis] = rate
                            pulled.append((i, j, k))
                        }
                    }
                }
            }
        }
        let area = Float(axis == 0 ? height : length) * size * size
        var peak: Float = 0
        for _ in 0..<(steps / 50) {
            solver.advance(steps: 50)
            let force = pulled.reduce(Float(0)) { $0 + solver.nodalForce($1.0, $1.1, $1.2)[axis] }
            peak = max(peak, -force / area)
        }
        return peak
    }

    @Test("Blockwork pulled across its bed joints parts at the bond; along them it is stronger")
    func directTension() throws {
        let units = try #require(StructureMaterial.concreteBlock.units)
        // Across the bed joints: two courses, pulled upwards.
        let across = try pull(length: 6, height: 6, axis: 2)
        #expect(abs(across - units.bondStrength) / units.bondStrength < 0.05, "across: \(across) Pa")
        // Along them, four courses of two units: the crack either runs straight, through head
        // joints and units in turn, or steps along the bed joints, shearing them over the half
        // unit by which the courses overlap. Either way it is above the bond alone and below
        // the units' strength; the head joints go first, so the two do not add in full.
        let along = try pull(length: 12, height: 12, axis: 0)
        #expect(along > 1.25 * units.bondStrength, "along: \(along) Pa")
        #expect(along < units.tensileStrength, "along: \(along) Pa")
    }

    /// A length of blockwork on its bed joint, pressed down to `pressure` and then pushed
    /// sideways: the largest shear stress the joint carries.
    private func slide(pressure: Float) throws -> Float {
        let length = 6
        let column = Box(min: SIMD3(0, 0, 1), max: SIMD3(Float(length) * size, size, 1 + 2 * size))
        let model = StructureModel(
            solids: [column], material: .concreteBlock, elementSize: size, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        // Damped, since a joint that softens as it slides lets go with a jolt.
        solver.damping = 2e4
        #expect(solver.jointPlanes(0, 0, 0) == 4 && solver.jointPlanes(0, 0, 1) == 0)
        func drive(_ velocity: SIMD3<Float>) {
            solver.mutateNodes { nodes in
                for j in 0...1 {
                    for i in 0...length {
                        nodes[solver.nodeIndex(i, j, 0)].isFixed = true
                        nodes[solver.nodeIndex(i, j, 2)].isPrescribed = true
                        nodes[solver.nodeIndex(i, j, 2)].velocity = velocity
                    }
                }
            }
        }
        let steps = 10_000
        let duration = Float(steps) * solver.criticalTimeStep
        let squeeze = pressure / StructureMaterial.concreteBlock.youngsModulus * 2 * size
        drive(SIMD3(0, 0, -squeeze / duration))
        solver.advance(steps: steps)
        drive(SIMD3(0.002 * 2 * size / duration, 0, 0))
        // The nodes between keep their height, so that the push bends nothing and the pressure
        // on the joint stays even along it.
        solver.mutateNodes { nodes in
            for j in 0...1 {
                for i in 0...length { nodes[solver.nodeIndex(i, j, 1)].restrain(z: true) }
            }
        }
        var peak: Float = 0
        for _ in 0..<(steps / 50) {
            solver.advance(steps: 50)
            var force: Float = 0
            for j in 0...1 {
                for i in 0...length { force += solver.nodalForce(i, j, 2).x }
            }
            peak = max(peak, -force / (Float(length) * size * size))
        }
        return peak
    }

    @Test("A bed joint slides at its cohesion, plus friction on what presses it shut")
    func coulombFriction() throws {
        let units = try #require(StructureMaterial.concreteBlock.units)
        let free = try slide(pressure: 0)
        #expect(abs(free - units.cohesion) / units.cohesion < 0.1, "free: \(free) Pa")
        let pressed = try slide(pressure: 0.4e6)
        let expected = units.cohesion + units.friction * 0.4e6
        #expect(abs(pressed - expected) / expected < 0.1, "pressed: \(pressed) Pa against \(expected) Pa")
    }

    @Test("A wall cracked along its joints by a push comes to rest: sliding returns no energy")
    func crackedWallSettles() throws {
        // The blockwork wall layout, its main wall thrown at 0.5 m/s and then left alone under
        // its own weight. Its joints crack, open, shut and slide as it swings; friction worked
        // out from the strain alone gave energy back here, and the wall shook itself to pieces.
        let model = try #require(ScenarioPreset.blockWall.scenario.structure)
        let solver = try StructureSolver(device: device, model: model)
        solver.mutateNodes { nodes in
            for k in 1...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...3 {
                        if let n = solver.storedNode(i, j, k) { nodes[n].velocity.x = 0.5 }
                    }
                }
            }
        }
        func kineticEnergy() -> Double {
            var total = 0.0
            solver.mutateNodes { nodes in
                for node in nodes {
                    total += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                }
            }
            return total
        }
        let initial = kineticEnergy()
        var largest = 0.0
        for _ in 0..<25 {
            solver.advance(steps: 1000)
            largest = max(largest, kineticEnergy())
        }
        #expect(largest <= initial, "kinetic energy rose to \(largest) J from \(initial) J")
        #expect(kineticEnergy() < 0.01 * initial, "still moving: \(kineticEnergy()) J of \(initial) J")
        #expect(solver.summary().erodedElements < 50)
    }
}
