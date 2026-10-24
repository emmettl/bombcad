import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Failed concrete that becomes particles keeping its mass (`StructureModel.rubbleParticles`).
@Suite("Rubble particles", .gpuThreads)
struct RubbleParticleTests {
    let device: MTLDevice

    init() throws {
        device = try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    private func solver(_ blocks: [Box], h: Float, rubble: Bool = true, fixedBase: Bool = false) throws
        -> StructureSolver
    {
        let material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6)
        var model = StructureModel(solids: blocks, material: material, elementSize: h, fixedBase: fixedBase)
        model.rubbleParticles = rubble
        return try StructureSolver(device: device, model: model)
    }

    @Test("Mass, momentum and energy pass across from the nodes to the particles")
    func conservation() throws {
        let h: Float = 0.05
        let solver = try solver([Box(min: SIMD3(0, 0, 1), max: SIMD3(0.2, 0.2, 1.2))], h: h)
        solver.gravity = 0
        solver.groundContact = false
        // Moving as a rigid body, turning and travelling, so the element passes put no force on
        // its nodes in the first step and what changes is the conversion alone.
        let centre = SIMD3<Float>(0.1, 0.1, 1.1)
        let spin = SIMD3<Float>(30, -20, 45)
        let drift = SIMD3<Float>(3, -1, 2)
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k) else { continue }
                        let r = solver.referencePosition(i, j, k) - centre
                        nodes[n].velocity = drift + simd_cross(spin, r)
                    }
                }
            }
        }
        let before = solver.massMomentumEnergy()
        let corner = solver.node(2, 1, 1)
        // Two neighbours and one on its own.
        for cell in [(1, 1, 1), (2, 1, 1), (0, 3, 2)] { solver.failElement(cell.0, cell.1, cell.2) }
        solver.advance(steps: 1)
        let after = solver.massMomentumEnergy()
        let particles = solver.rubbleParticles()
        #expect(particles.count == 3)
        let elementMass = 2400 * h * h * h
        for (_, p) in particles {
            #expect(abs(p.mass - elementMass) < 1e-4 * elementMass)
            #expect(abs(p.reach - 0.8660254 * h) < 1e-3 * h)
            #expect(p.internalEnergy > 0)
        }
        // The node shared by both neighbours gave a quarter of an element.
        #expect(abs(corner.mass - solver.node(2, 1, 1).mass - 0.25 * elementMass) < 1e-4 * elementMass)
        #expect(abs(after.mass - before.mass) < 1e-6 * before.mass)
        let momentum = simd_length(before.momentum)
        #expect(simd_length(after.momentum - before.momentum) < 1e-5 * momentum)
        // Energy: what the particles cannot carry as motion they keep inside.
        #expect(after.internalEnergy > 0)
        #expect(abs(after.kinetic + after.internalEnergy - before.kinetic) < 1e-5 * before.kinetic)
        // Each particle moves with its element's centre of mass.
        for (element, p) in particles {
            let (i, j, k) = solver.elementCoordinates(element)
            let middle = solver.referencePosition(i, j, k) + 0.5 * h - centre
            let expected = drift + simd_cross(spin, middle)
            #expect(simd_length(p.velocity - expected) < 1e-3 * simd_length(expected))
        }
    }

    @Test("Rubble rests on what is left of the body and on itself, where loose nodes fall through")
    func carriesCompression() throws {
        let h: Float = 0.05
        // A block on the ground, four elements high; its top two layers fail at once.
        func settle(rubble: Bool) throws -> Float {
            let solver = try solver(
                [Box(min: SIMD3(0, 0, 0), max: SIMD3(0.15, 0.15, 0.2))], h: h, rubble: rubble, fixedBase: true
            )
            solver.damping = 20
            for k in 2..<4 {
                for j in 0..<3 {
                    for i in 0..<3 { solver.failElement(i, j, k) }
                }
            }
            solver.advance(steps: Int((0.1 / Double(solver.criticalTimeStep)).rounded()))
            if rubble {
                let particles = solver.rubbleParticles()
                #expect(particles.count == 18)
                return particles.map { $0.particle.z }.min() ?? 0
            }
            // Without rubble, the failed layers' mass stays on their nodes; the top layer's
            // nodes are loose and fall into the block.
            return (0...solver.ey).flatMap { j in
                (0...solver.ex).map { i in
                    solver.referencePosition(i, j, 4).z + solver.displacement(i, j, 4).z
                }
            }.min() ?? 0
        }
        let rubbleLowest = try settle(rubble: true)
        // The lower layer's particles sat half an element above the block's intact top (0.1 m).
        #expect(rubbleLowest > 0.1 + 0.4 * h)
        let looseLowest = try settle(rubble: false)
        #expect(looseLowest < 0.2 - 0.5 * h)
    }

    @Test("A joint between parts eases as the concrete at it turns to rubble, and its bare nodes stay steady")
    func jointAtRubble() throws {
        // A block seated across a gap on another (`Anchorage.betweenParts`), floating, pressed on
        // it, and its bottom row's concrete gone at once, leaving its bars: the joint's nodes keep
        // a few per cent of their mass. With the pairs as stiff as for whole nodes they rang far
        // beyond the step; on the large-panel block a node was driven to 18 km/s (#36).
        let h: Float = 0.05
        let lower = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.5, 0.5, 1.25))
        let upper = Box(min: SIMD3(0, 0, 1.25 + h), max: SIMD3(0.5, 0.5, 1.5 + h))
        let steel = SteelProperties(
            yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        let material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6, steel: steel)
        var model = StructureModel(
            solids: [lower, upper], material: material, elementSize: h, fixedBase: false)
        model.addMat(to: upper, thicknessAxis: 2, areaPerMetre: 5e-4, depth: 0.025)
        model.supports = [
            Box(min: SIMD3(-0.01, -0.01, 1.24), max: SIMD3(0.51, 0.51, 1.26 + h))
        ]
        var joint = Anchorage.constructionJoint
        joint.betweenParts = true
        model.supportAnchorages = [joint]
        model.rubbleParticles = true
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in 0...solver.ex {
                        guard let n = solver.storedNode(i, j, k),
                            solver.referencePosition(i, j, k).z > 1.25 + h / 2
                        else { continue }
                        nodes[n].velocity = SIMD3(0, 0, -0.1)
                    }
                }
            }
        }
        solver.advance(steps: 200)
        for k in 0..<solver.ez {
            for j in 0..<solver.ey {
                for i in 0..<solver.ex where solver.flag(i, j, k) == .active {
                    if abs(solver.referencePosition(i, j, k).z - (1.25 + h)) < h / 2 {
                        solver.failElement(i, j, k, leavingBars: true)
                    }
                }
            }
        }
        solver.advance(steps: 2000)
        var largest: Float = 0
        var lightest = Float.infinity
        for k in 0...solver.ez {
            for j in 0...solver.ey {
                for i in 0...solver.ex where solver.storedNode(i, j, k) != nil {
                    let node = solver.node(i, j, k)
                    largest = max(largest, simd_length(node.velocity))
                    if node.mass > 0 { lightest = min(lightest, node.mass) }
                }
            }
        }
        // The joint's nodes kept only their bars' share.
        #expect(lightest < 0.1 * 2400 * h * h * h / 4)
        #expect(largest.isFinite && largest < 1, "fastest node \(largest) m/s")
    }

    @Test("Bars left bare when their concrete becomes rubble hold their nodes steadily")
    func bareBars() throws {
        let h: Float = 0.05
        let beam = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.6, 0.1, 1.1))
        let steel = SteelProperties(
            yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        let material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6, steel: steel)
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        model.addMat(to: beam, thicknessAxis: 2, areaPerMetre: 2e-4, depth: 0.025)
        model.rubbleParticles = true
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        // Held at both ends, its middle two columns' concrete gone at once, leaving their bars.
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in [0, solver.ex] { nodes[solver.nodeIndex(i, j, k)].isFixed = true }
                }
            }
        }
        for i in 5...6 {
            for j in 0..<solver.ey {
                for k in 0..<solver.ez { solver.failElement(i, j, k, leavingBars: true) }
            }
        }
        solver.advance(steps: 4000)
        let particles = solver.rubbleParticles()
        #expect(particles.count == 2 * solver.ey * solver.ez)
        // The concrete's mass left; the bars' stayed.
        let concrete = 2400 * h * h * h
        #expect(particles.allSatisfy { $0.particle.mass <= concrete && $0.particle.mass > 0.95 * concrete })
        #expect(particles.contains { $0.particle.mass < 0.999 * concrete })
        var largest: Float = 0
        for k in 0...solver.ez {
            for j in 0...solver.ey {
                for i in 0...solver.ex where solver.storedNode(i, j, k) != nil {
                    largest = max(largest, simd_length(solver.node(i, j, k).velocity))
                }
            }
        }
        #expect(largest.isFinite && largest < 5)
    }

    @Test("A particle its element's corners close in on is crushed, not sprung")
    func cagedParticleIsCrushed() throws {
        // An elastic block, floating, its middle element turned to rubble: its corners, still
        // held by the elements round them, cage the particle. With its reach grown by a third
        // they overlap it by 14 mm, as corners closing in did on the large-panel block (#36),
        // where the capped push drove them out every substep. Crushed instead, the particle gives
        // up its reach at once and puts in no more than a step's push.
        let h: Float = 0.05
        var material = StructureMaterial.concrete(name: "Elastic", compressiveStrength: 30e6)
        material.tensileStrength = 1e12
        var model = StructureModel(
            solids: [Box(min: SIMD3(0, 0, 1), max: SIMD3(0.15, 0.15, 1.15))], material: material,
            elementSize: h,
            fixedBase: false)
        model.rubbleParticles = true
        let solver = try StructureSolver(device: device, model: model)
        solver.gravity = 0
        solver.groundContact = false
        solver.tracesWork = true
        solver.failElement(1, 1, 1)
        solver.advance(steps: 1)
        let rubble = try #require(solver.rubbleSystem)
        let particles = rubble.particles.contents().bindMemory(
            to: RubbleParticle.self, capacity: rubble.count)
        let slot = try #require((0..<rubble.count).first { particles[$0].alive != 0 })
        let grown = 1.33 * particles[slot].reach
        particles[slot].reach = grown
        solver.advance(steps: 2000)
        let state = solver.massMomentumEnergy()
        let energy = state.kinetic + state.internalEnergy + solver.workTotals().reduce(0, +)
        #expect(particles[slot].reach < grown - 0.01)
        #expect(energy < 20, "\(energy) J")
    }

    @Test("Bars that break pass their steel to the particle their concrete became, leaving no node grams")
    func brokenBarsJoinTheirParticle() throws {
        // As `bareBars`: a beam held at both ends, its middle two columns' concrete gone to rubble
        // and their bars left. Then the bars break. Their steel used to stay on the nodes, and the
        // middle column's nodes, with no element left, held a few grams each: on the large-panel
        // block such nodes flew off at 50-130 m/s (#36). Now the shares of nodes nothing else holds
        // join the particles.
        let h: Float = 0.05
        let beam = Box(min: SIMD3(0, 0, 1), max: SIMD3(0.6, 0.1, 1.1))
        let steel = SteelProperties(
            yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        let material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6, steel: steel)
        var model = StructureModel(solids: [beam], material: material, elementSize: h, fixedBase: false)
        model.addMat(to: beam, thicknessAxis: 2, areaPerMetre: 2e-4, depth: 0.025)
        model.rubbleParticles = true
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.mutateNodes { nodes in
            for k in 0...solver.ez {
                for j in 0...solver.ey {
                    for i in [0, solver.ex] { nodes[solver.nodeIndex(i, j, k)].isFixed = true }
                }
            }
        }
        for i in 5...6 {
            for j in 0..<solver.ey {
                for k in 0..<solver.ez { solver.failElement(i, j, k, leavingBars: true) }
            }
        }
        solver.advance(steps: 10)
        let concrete = solver.rubbleParticles().map(\.particle.mass).reduce(0, +)
        let before = solver.massMomentumEnergy()
        let held = (0...solver.ez).flatMap { k in (0...solver.ey).map { j in solver.node(5, j, k).mass } }
        for i in 5...6 {
            for j in 0..<solver.ey {
                for k in 0..<solver.ez { solver.breakBars(i, j, k) }
            }
        }
        solver.advance(steps: 1)
        let after = solver.massMomentumEnergy()
        let particles = solver.rubbleParticles()
        let element = 2400 * h * h * h
        #expect(particles.count == 2 * solver.ey * solver.ez)
        // The particles have the steel of the corners nothing else holds; the column at i = 5,
        // still held by the whole elements beside it, keeps its share.
        #expect(particles.allSatisfy { $0.particle.mass <= element * 1.0001 })
        #expect(particles.map(\.particle.mass).reduce(0, +) > concrete * 1.001)
        let kept = (0...solver.ez).flatMap { k in (0...solver.ey).map { j in solver.node(5, j, k).mass } }
        #expect(zip(held, kept).allSatisfy { abs($0 - $1) < 1e-6 * $0 })
        #expect(abs(after.mass - before.mass) < 1e-5 * before.mass)
        #expect(after.internalEnergy >= before.internalEnergy)
        // The middle column's nodes had no element left: they hold nothing.
        for k in 0...solver.ez {
            for j in 0...solver.ey {
                #expect(
                    solver.node(6, j, k).mass == 0,
                    "node (6, \(j), \(k)) keeps \(solver.node(6, j, k).mass) kg")
            }
        }
    }

    @Test("A bare element pulled apart across its bars goes past twice its volume, its steel with it")
    func barePulledApartGoes() throws {
        // One element, bars along x and y only, its concrete gone to rubble; then its top pulled
        // up at 50 m/s, across its bars, which nothing ruptures. It used to stay bare however far
        // it went: on the large-panel block one reached a thousand times its volume, turned inside
        // out and threw a corner at 200 m/s (#36). Past twice its volume it goes now, and with no
        // other element holding its corners, its steel joins its particle.
        let h: Float = 0.05
        let cube = Box(min: SIMD3(0, 0, 1), max: SIMD3(h, h, 1 + h))
        let steel = SteelProperties(
            yieldStress: 500e6, ultimateStress: 600e6, ultimateStrain: 0.1, ruptureStrain: 0.15)
        let material = StructureMaterial.concrete(name: "C30", compressiveStrength: 30e6, steel: steel)
        var model = StructureModel(solids: [cube], material: material, elementSize: h, fixedBase: false)
        model.addMat(to: cube, thicknessAxis: 2, areaPerMetre: 2e-4, depth: 0.025)
        model.rubbleParticles = true
        let solver = try StructureSolver(device: device, model: model)
        solver.groundContact = false
        solver.gravity = 0
        solver.failElement(0, 0, 0, leavingBars: true)
        solver.advance(steps: 2)
        let concrete = try #require(solver.rubbleParticle(0, 0, 0)).mass
        solver.mutateNodes { nodes in
            for j in 0...1 {
                for i in 0...1 { nodes[solver.nodeIndex(i, j, 1)].velocity = SIMD3(0, 0, 50) }
            }
        }
        solver.advance(steps: Int((0.003 / Double(solver.criticalTimeStep)).rounded()))
        let particle = try #require(solver.rubbleParticle(0, 0, 0))
        #expect(particle.mass > concrete * 1.001, "\(particle.mass) kg against \(concrete) kg of concrete")
        for k in 0...1 {
            for j in 0...1 {
                for i in 0...1 {
                    #expect(
                        solver.node(i, j, k).mass == 0,
                        "node (\(i), \(j), \(k)) keeps \(solver.node(i, j, k).mass) kg")
                }
            }
        }
    }
}
