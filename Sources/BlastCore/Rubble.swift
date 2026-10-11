import Foundation
import Metal
import simd

/// A particle of rubble (`StructureModel.rubbleParticles`): what an element that failed became.
/// Layout matches `RubbleParticle` in Structure.metal.
public struct RubbleParticle: Sendable {
    public var x: Float = 0
    public var y: Float = 0
    public var z: Float = 0
    /// kg; zero for a slot not in use.
    public var mass: Float = 0
    public var vx: Float = 0
    public var vy: Float = 0
    public var vz: Float = 0
    /// How near a node's centre it comes before touching it (m).
    public var reach: Float = 0
    /// The kinetic energy of its nodes' motion about its centre when it was made (J), which it
    /// keeps as its internal energy.
    public var internalEnergy: Float = 0
    /// The volume of material it stands for (m³).
    public var volume: Float = 0
    public var alive: UInt32 = 0
    var spare: Float = 0

    public var position: SIMD3<Float> { SIMD3(x, y, z) }
    public var velocity: SIMD3<Float> { SIMD3(vx, vy, vz) }
    public var kineticEnergy: Float { 0.5 * mass * simd_length_squared(velocity) }
}

/// The particles' buffers and kernels (Rubble.metal): a slot per element the body started with,
/// their own contact table, the contact force on each, and each element's mass with the share of
/// it that is steel.
final class RubbleSystem {
    let particles: MTLBuffer
    let masses: MTLBuffer
    let heads: MTLBuffer
    let slots: MTLBuffer
    let forces: MTLBuffer
    /// Four words (any particle made; one made this substep; two spare), then a bit per slot in
    /// use, so that the kernels over all the slots skip empty ones cheaply.
    let state: MTLBuffer
    let count: Int
    let convert: MTLComputePipelineState
    let nodes: MTLComputePipelineState
    let clear: MTLComputePipelineState
    let hash: MTLComputePipelineState
    let force: MTLComputePipelineState
    let move: MTLComputePipelineState
    let areas: MTLComputePipelineState

    /// `masses` is each element's mass and the share of it that is steel; zero mass for elements
    /// that do not turn to rubble.
    init(device: MTLDevice, library: MTLLibrary, masses elementMasses: [SIMD2<Float>], gridCells: Int) throws
    {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        count = elementMasses.count
        particles = try buffer(count * MemoryLayout<RubbleParticle>.stride, "rubble particles")
        masses = try buffer(count * 8, "rubble masses")
        masses.copy(elementMasses)
        heads = try buffer(gridCells * 4, "rubble contact headers")
        slots = try buffer(gridCells * 32, "rubble contact slots")
        forces = try buffer(count * 16, "rubble contact forces")
        state = try buffer((4 + (count + 31) / 32) * 4, "rubble state")
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library)
        }
        convert = try pipeline("rubbleConvert")
        nodes = try pipeline("rubbleNodes")
        clear = try pipeline("rubbleClear")
        hash = try pipeline("rubbleHash")
        force = try pipeline("rubbleForces")
        move = try pipeline("rubbleMove")
        areas = try pipeline("rubbleAreas")
        reset()
    }

    func reset() {
        memset(particles.contents(), 0, particles.length)
        memset(forces.contents(), 0, forces.length)
        memset(state.contents(), 0, state.length)
        memset(heads.contents(), 0xFF, heads.length)
    }

    var all: [RubbleParticle] {
        Array(
            UnsafeBufferPointer(
                start: particles.contents().bindMemory(to: RubbleParticle.self, capacity: count), count: count
            ))
    }
}

extension StructureSolver {
    /// The rubble's particles in use (`StructureModel.rubbleParticles`), each with the lattice
    /// cell of the element it was (as `elementCoordinates` takes it); empty without rubble.
    public func rubbleParticles() -> [(element: Int, particle: RubbleParticle)] {
        guard let rubble = rubbleSystem else { return [] }
        let cells = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        return rubble.all.enumerated().filter { $0.element.alive != 0 }.map {
            (Int(cells[$0.offset]), $0.element)
        }
    }

    /// The particle the element at lattice cell (i, j, k) became, if it has.
    public func rubbleParticle(_ i: Int, _ j: Int, _ k: Int) -> RubbleParticle? {
        guard let rubble = rubbleSystem, let n = compactIndex(i, j, k) else { return nil }
        let p = rubble.particles.contents().load(
            fromByteOffset: n * MemoryLayout<RubbleParticle>.stride, as: RubbleParticle.self)
        return p.alive != 0 ? p : nil
    }

    /// Totals over the body's nodes and its rubble: mass, momentum, kinetic energy and the rubble's
    /// internal energy, for checking what passes across when elements turn to rubble.
    public func massMomentumEnergy() -> (
        mass: Double, momentum: SIMD3<Double>, kinetic: Double, internalEnergy: Double
    ) {
        var mass = 0.0
        var momentum = SIMD3<Double>.zero
        var kinetic = 0.0
        var internalEnergy = 0.0
        let nodes = nodeBuffer.contents().bindMemory(to: StructureNode.self, capacity: max(nodeCount, 1))
        for n in 0..<nodeCount {
            let node = nodes[n]
            let v = SIMD3<Double>(Double(node.vx), Double(node.vy), Double(node.vz))
            mass += Double(node.mass)
            momentum += Double(node.mass) * v
            kinetic += 0.5 * Double(node.mass) * simd_length_squared(v)
        }
        for (_, p) in rubbleParticles() {
            let v = SIMD3<Double>(p.velocity)
            mass += Double(p.mass)
            momentum += Double(p.mass) * v
            kinetic += 0.5 * Double(p.mass) * simd_length_squared(v)
            internalEnergy += Double(p.internalEnergy)
        }
        return (mass, momentum, kinetic, internalEnergy)
    }
}

extension StructureSolver {
    /// Marks the element at lattice cell (i, j, k) as failing (3 in Structure.metal), or as losing
    /// its concrete to leave its bars (5), as the element pass marks one, so that the next substep
    /// removes it, and with rubble turns it, or its concrete, into a particle.
    public func failElement(_ i: Int, _ j: Int, _ k: Int, leavingBars: Bool = false) {
        flagBuffer.contents().storeBytes(
            of: UInt8(leavingBars ? 5 : 3), toByteOffset: elementIndex(i, j, k), as: UInt8.self)
        failureGateBuffer.contents().storeBytes(of: 1, as: UInt32.self)
    }
}
