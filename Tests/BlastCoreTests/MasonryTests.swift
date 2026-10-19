import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Masonry meshed as units and mortar joints.
@Suite("Masonry units and joints", .gpuThreads)
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

    @Test("Reinforced blockwork struck by a blast pulse stays bounded")
    func reinforcedBlockworkBounded() throws {
        // A 0.2 m strip of Alsubaei's reinforced blockwork wall, its ends held as in the middle of
        // the wall, its face struck by the 25 kg charge's 2.5 MPa. The base course, squeezed from
        // every side, followed the concrete compaction curve, which for a material this soft was
        // five to fifty times stiffer than the block itself and outran the time step: its nodes
        // reached thousands of m/s within 30 ms and more than half the strip was removed.
        let panel = try PerimeterWallTests.blockworkPanel(device: device)
        #expect(panel.fastest < 50, "fastest node \(panel.fastest) m/s")
        #expect(panel.erodedFraction < 0.15, "\(panel.erodedFraction * 100)% removed")
        #expect(panel.peakTop > 0.02 && panel.peakTop < 0.3, "top \(panel.peakTop) m")
    }

    @Test("Reinforced blockwork broken up by a larger blast throws nothing faster than the blast could")
    func reinforcedBlockworkBreakUp() throws {
        // The 125 kg charge's 12.7 MPa on a 0.4 m strip: it comes apart, as the wall did. The
        // pulse's impulse on the front row of elements alone would throw it at about 80 m/s.
        // Elements left as bare bars, which run only up the wall and along it, were flattened
        // across its thickness or turned inside out and kept, and flung their nodes at 500 m/s.
        let panel = try PerimeterWallTests.blockworkPanel(
            device: device, length: 0.4, peak: 12.7e6, duration: 0.9e-3, time: 0.12)
        #expect(panel.fastest < 150, "fastest node \(panel.fastest) m/s")
        // Nothing kept past a quarter of its volume (V0 / V - 1 = 3), but for the step in which it
        // went; before, a bare element was squeezed to a seven-thousandth.
        #expect(panel.compaction < 3.5, "compacted to \(panel.compaction)")
    }

    @Test("Block crushed from one side and then held in compacts only from there")
    func compactionCountsFromConfinement() throws {
        // A cube of blockwork squashed by 5% with its sides free, losing 3% of its volume, then
        // held at the sides and squashed a further 0.5%. The pores it crushed losing volume from
        // one side say nothing (the model does not let crushed concrete swell), so held in it
        // compacts only from where it is. Counted from its undeformed volume, the curve took over
        // at once: here at 48 MPa, three times the 14 MPa it carries, and in the 125 kg wall, from
        // 40% lost unconfined, at several GPa, flinging nodes at hundreds of m/s.
        let size: Float = 0.05
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(size, size, 1 + size))
        let model = StructureModel(
            solids: [cube], material: .concreteBlock, elementSize: size, fixedBase: false)
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        // Squashed downwards: the bottom nodes on rollers, one of them pinned, the top ones
        // pushed down at a set speed and free sideways until the sides are held.
        func squash(by strain: Float, steps: Int, heldSides: Bool) -> Float {
            let rate = strain * size / (Float(steps) * solver.criticalTimeStep)
            solver.mutateNodes { nodes in
                for k in 0...1 {
                    for j in 0...1 {
                        for i in 0...1 {
                            let n = solver.nodeIndex(i, j, k)
                            if k == 0 {
                                nodes[n].restrain(x: i == 0 && j == 0, y: i == 0 && j == 0, z: true)
                            } else {
                                nodes[n].isPushedVertically = true
                                nodes[n].velocity.z = -rate
                            }
                            if heldSides {
                                nodes[n].velocity.x = 0
                                nodes[n].velocity.y = 0
                                nodes[n].restrain(x: true, y: true)
                            }
                        }
                    }
                }
            }
            var largest: Float = 0
            for _ in 0..<(steps / 20) {
                solver.advance(steps: 20)
                var force: Float = 0
                for j in 0...1 {
                    for i in 0...1 { force += solver.nodalForce(i, j, 1).z }
                }
                largest = max(largest, force / (size * size))
            }
            return largest
        }
        _ = squash(by: 0.05, steps: 20_000, heldSides: false)
        let held = squash(by: 0.005, steps: 2_000, heldSides: true)
        #expect(solver.flag(0, 0, 0) == .active)
        #expect(held < 25e6, "held in, it pushed back at \(held / 1e6) MPa")
        #expect(solver.compaction(0, 0, 0) < 0.01, "compaction \(solver.compaction(0, 0, 0))")
    }
}
