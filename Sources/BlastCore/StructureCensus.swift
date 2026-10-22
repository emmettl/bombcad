import BlastModel
import Foundation
import Metal
import simd

/// A count, read on the CPU between batches, of what a long run of a failing structure is made
/// of: its contact tables' load, its motion and its energy (`blastbench wholeevent`,
/// emmettl/bombcad-work#36). It reads the buffers only, so the run is the same to the bit with
/// it or without it.
public struct StructureCensus: Sendable {
    /// Nodes that still carry mass, and of them those contact lists (not buried in intact solid).
    public var nodes = 0
    public var listedNodes = 0
    /// Listed nodes that have moved far enough to touch a stranger (`contactMoved`).
    public var movedNodes = 0
    /// Listed nodes the last substep pushed by contact (a node or a particle).
    public var nodesInContact = 0
    /// Table entries holding listed nodes; those holding more than the table keeps (8), and the
    /// nodes so left out of contact; entries shared by two or more cells a period apart.
    public var nodeEntries = 0
    public var nodeEntriesFull = 0
    public var nodesDropped = 0
    public var nodeEntriesAliased = 0
    /// Rubble: particles, those the last substep pushed, and their table's load as the nodes'.
    public var particles = 0
    public var particlesInContact = 0
    public var particleEntriesFull = 0
    public var particlesDropped = 0
    public var particlesOnGround = 0
    /// Kinetic energy (J) of the nodes and the particles, the particles' internal energy, and
    /// the sum of mass times height above where it started (kg m), whose change times g is the
    /// work gravity has taken out.
    public var nodeKinetic = 0.0
    public var particleKinetic = 0.0
    public var particleInternal = 0.0
    public var massTimesRise = 0.0
    /// Mass on the nodes and in the particles (kg).
    public var nodeMass = 0.0
    public var particleMass = 0.0
    /// Fastest node and particle (m/s), and whether any value read is not finite.
    public var fastestNode: Float = 0
    public var fastestParticle: Float = 0
    public var notFinite = false
    /// The joints between parts: the work their slip has dissipated so far (J), and the power
    /// (W) their pairs, contact on the nodes and contact on the particles are putting into the
    /// body at this instant (the last substep's forces on the present velocities).
    public var jointSlipWork = 0.0
    public var jointPower = 0.0
    public var contactPower = 0.0
    public var particleContactPower = 0.0
    /// How far the lowest node and particle lie below the ground (m; positive below).
    public var deepestNode: Float = 0
    public var deepestParticle: Float = 0
}

extension StructureSolver {
    /// Contact slots per table entry (ContinuumKit's `cksSlotCount`).
    static let censusSlots = 8

    /// The census of the body as it is now (call between batches).
    public func census() -> StructureCensus {
        var c = StructureCensus()
        let h = model.elementSize
        let period = contactPeriod
        func entry(_ position: SIMD3<Float>) -> (entry: Int, cell: SIMD3<Int32>) {
            let cell = SIMD3<Int32>(((position - contactGridOrigin) / h).rounded(.down))
            let w = SIMD3<Int>(
                Int(cell.x) & (period.x - 1), Int(cell.y) & (period.y - 1), Int(cell.z) & (period.z - 1))
            return (w.x + period.x * (w.y + period.y * w.z), cell)
        }
        let nodesX = ex + 1
        let nodesY = ey + 1
        let list = nodeListBuffer.contents().bindMemory(to: UInt32.self, capacity: max(nodeCount, 1))
        let forces = contactForceBuffer.contents().bindMemory(to: Float.self, capacity: max(3 * nodeCount, 3))
        let still = 0.45 * h
        var counts: [Int: (count: Int, cell: SIMD3<Int32>, aliased: Bool)] = [:]
        mutateNodes { nodes in
            for n in 0..<nodes.count {
                let node = nodes[n]
                guard node.mass > 0 else { continue }
                c.nodes += 1
                let v = node.velocity
                let u = node.displacement
                let speed = simd_length(v)
                if !speed.isFinite || !simd_length(u).isFinite || !node.mass.isFinite {
                    c.notFinite = true
                    continue
                }
                c.fastestNode = max(c.fastestNode, speed)
                c.nodeMass += Double(node.mass)
                c.nodeKinetic += 0.5 * Double(node.mass) * Double(speed * speed)
                c.massTimesRise += Double(node.mass) * Double(u.z)
                let index = Int(list[n])
                let lattice = SIMD3<Float>(
                    Float(index % nodesX), Float((index / nodesX) % nodesY), Float(index / (nodesX * nodesY)))
                let position = origin + lattice * h + u
                c.deepestNode = max(c.deepestNode, -position.z)
                guard node.flags & 32 == 0 else { continue }  // buried in intact solid
                c.listedNodes += 1
                if simd_length_squared(u) >= still * still { c.movedNodes += 1 }
                let f = SIMD3(forces[3 * n], forces[3 * n + 1], forces[3 * n + 2])
                if simd_length_squared(f) > 0 {
                    c.nodesInContact += 1
                    c.contactPower += Double(simd_dot(f, v))
                }
                let (e, cell) = entry(position)
                if var held = counts[e] {
                    held.count += 1
                    if held.cell != cell { held.aliased = true }
                    counts[e] = held
                } else {
                    counts[e] = (1, cell, false)
                }
            }
        }
        c.nodeEntries = counts.count
        for held in counts.values {
            if held.count > Self.censusSlots {
                c.nodeEntriesFull += 1
                c.nodesDropped += held.count - Self.censusSlots
            }
            if held.aliased { c.nodeEntriesAliased += 1 }
        }
        if let rubble = rubbleSystem {
            let cells = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
            let pushed = rubble.forces.contents().bindMemory(
                to: SIMD4<Float>.self, capacity: max(rubble.count, 1))
            let particles = rubble.particles.contents().bindMemory(
                to: RubbleParticle.self, capacity: rubble.count)
            var table: [Int: Int] = [:]
            for n in 0..<rubble.count where particles[n].alive != 0 {
                let p = particles[n]
                c.particles += 1
                let speed = simd_length(p.velocity)
                if !speed.isFinite || !simd_length(p.position).isFinite {
                    c.notFinite = true
                    continue
                }
                c.fastestParticle = max(c.fastestParticle, speed)
                c.particleMass += Double(p.mass)
                c.particleKinetic += 0.5 * Double(p.mass) * Double(speed * speed)
                c.particleInternal += Double(p.internalEnergy)
                let (i, j, k) = elementCoordinates(Int(cells[n]))
                let start = origin + (SIMD3<Float>(Float(i), Float(j), Float(k)) + 0.5) * h
                c.massTimesRise += Double(p.mass) * Double(p.position.z - start.z)
                c.deepestParticle = max(c.deepestParticle, -p.position.z)
                if p.position.z <= 1e-4 { c.particlesOnGround += 1 }
                let f = SIMD3(pushed[n].x, pushed[n].y, pushed[n].z)
                if simd_length_squared(f) > 0 {
                    c.particlesInContact += 1
                    c.particleContactPower += Double(simd_dot(f, p.velocity))
                }
                table[entry(p.position).entry, default: 0] += 1
            }
            for count in table.values where count > Self.censusSlots {
                c.particleEntriesFull += 1
                c.particlesDropped += count - Self.censusSlots
            }
        }
        if let pairs {
            // Each pair's force on its first node is +force, on its second −force
            // (`structurePairs`); its slip's dissipated work is kept in its third word's w.
            let ends = pairs.nodes.contents().bindMemory(
                to: SIMD2<UInt32>.self, capacity: max(pairs.count, 1))
            let state = pairs.state.contents().bindMemory(
                to: SIMD4<Float>.self, capacity: max(3 * pairs.count, 3))
            let nodes = nodeBuffer.contents().bindMemory(to: StructureNode.self, capacity: max(nodeCount, 1))
            for p in 0..<pairs.count {
                let force = state[3 * p + 1]
                let a = nodes[Int(ends[p].x)].velocity
                let b = nodes[Int(ends[p].y)].velocity
                c.jointPower += Double(simd_dot(SIMD3(force.x, force.y, force.z), a - b))
                c.jointSlipWork += Double(state[3 * p + 2].w)
            }
        }
        return c
    }
}
