import Foundation
import Metal
import simd

/// One object's independently allocated mechanics, sharing the parent solver's air domain.
public final class StructuralBody: Identifiable {
    public let id: UUID
    public let name: String
    public let model: StructureModel
    public let solids: StructureSolver?
    public let shells: ShellSolver?
    public let mixed: MixedStructure?
    public internal(set) var time: Double = 0
    let shellEnvelopeMargin: Float

    init(object: SceneObject, device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) throws {
        guard let model = object.structure else { throw SceneObjectError.unsupportedRepresentation }
        id = object.id
        name = object.name
        self.model = model
        if model.isMixed {
            let mixed = try MixedStructure(
                device: device, commandQueue: queue, library: library, model: model)
            self.mixed = mixed
            solids = mixed.solids
            shells = mixed.shells
        } else if model.elementKind == .shell {
            shells = try ShellSolver(device: device, commandQueue: queue, library: library, model: model)
            solids = nil
            mixed = nil
        } else {
            solids = try StructureSolver(device: device, commandQueue: queue, library: library, model: model)
            shells = nil
            mixed = nil
        }
        shellEnvelopeMargin =
            0.5
            * max(
                shells?.mesh.elements.map(\.thickness).max() ?? 0,
                shells?.mesh.beams.map { simd_length($0.section) }.max() ?? 0)
    }

    public var criticalTimeStep: Float { solids?.criticalTimeStep ?? shells!.criticalTimeStep }
    public var memoryFootprint: Int { (solids?.memoryFootprint ?? 0) + (shells?.memoryFootprint ?? 0) }

    public func summary() -> StructureSummary? {
        switch (solids?.summary(), shells?.summary()) {
        case (let solid?, let shell?): solid.combined(with: shell)
        case (let solid?, nil): solid
        case (nil, let shell?): shell
        default: nil
        }
    }

    func reset() {
        time = 0
        if let mixed {
            mixed.reset()
        } else {
            solids?.reset()
            shells?.reset()
        }
    }

    /// The gravity the body falls under: its parts' largest.
    var gravity: Float { max(solids?.gravity ?? 0, shells?.gravity ?? 0) }

    /// Whether any node's motion is set by the scene (bit 3 of either kind of node, or bit 6 of a
    /// solid's), which a settle would disturb.
    var hasSetMotion: Bool {
        var set = false
        solids?.mutateNodes { nodes in set = set || nodes.contains { $0.flags & 72 != 0 } }
        shells?.mutateNodes { nodes in set = set || nodes.contains { $0.flags & 8 != 0 } }
        return set
    }

    /// Mass-proportional damping of every part, 1/s.
    var damping: Float {
        get { solids?.damping ?? shells!.damping }
        set {
            solids?.damping = newValue
            shells?.damping = newValue
        }
    }

    /// Advances the body alone, without the air, by `steps` of its critical step.
    func advanceAlone(steps: Int) {
        if let mixed {
            mixed.advance(steps: steps)
        } else {
            solids?.advance(steps: steps)
            shells?.advance(steps: steps)
        }
    }

    /// The body's kinetic energy of translation (J) and its mass (kg).
    func motion() -> (energy: Double, mass: Double) {
        var energy = 0.0
        var mass = 0.0
        solids?.mutateNodes { nodes in
            for node in nodes where node.mass > 0 {
                energy += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                mass += Double(node.mass)
            }
        }
        shells?.mutateNodes { nodes in
            // Tied shell nodes (bit 8) move with the solid, which carries their mass.
            for node in nodes where node.mass > 0 && node.flags & 256 == 0 {
                energy += 0.5 * Double(node.mass) * Double(simd_length_squared(node.velocity))
                mass += Double(node.mass)
            }
        }
        return (energy, mass)
    }

    /// Stops every node where it is and starts the body's clocks again, keeping its deformation,
    /// stresses and damage.
    func holdStill() {
        solids?.mutateNodes { nodes in
            for n in nodes.indices { nodes[n].velocity = .zero }
        }
        shells?.mutateNodes { nodes in
            for n in nodes.indices {
                nodes[n].velocity = .zero
                nodes[n].spin = .zero
            }
        }
        solids?.time = 0
        shells?.time = 0
        time = 0
    }

    func checkpoint() {
        solids?.failedAtCheckpoint = solids?.hasFailed
        shells?.failedAtCheckpoint = shells?.hasFailed
    }

    func prepareDebrisAreas(_ encoder: MTLComputeCommandEncoder, fluid: StructureSolver.FluidBinding) {
        solids?.encodeDebrisAreas(encoder, fluid: fluid)
        shells?.encodeDebrisAreas(encoder, fluid: fluid)
    }

    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: StructureSolver.FluidBinding,
        afterSubstep: ((Int) -> Void)? = nil
    ) {
        if let mixed {
            mixed.encodeSubsteps(encoder, count: count, fluid: fluid, afterSubstep: afterSubstep)
        } else if let solids {
            if let afterSubstep {
                solids.encodeSubsteps(
                    encoder, count: count, fluid: fluid, interface: nil,
                    beforeNodes: nil, afterNodes: afterSubstep)
            } else {
                solids.encodeSubsteps(encoder, count: count, fluid: fluid)
            }
        } else if let shells {
            if let afterSubstep {
                shells.encodeSubsteps(
                    encoder, substeps: 0..<count, fluid: fluid, prelude: true,
                    interface: nil, beforeNodes: nil, afterNodes: afterSubstep)
            } else {
                shells.encodeSubsteps(encoder, count: count, fluid: fluid)
            }
        }
    }

    /// Contact between two bodies' parts, as `BodyContact` in BodyContact.metal.
    struct ContactParameters {
        var reach: Float
        var stiffness: Float
        var damping: Float
        var friction: Float
        var own: UInt32
        var other: UInt32
    }

    /// One part of a body as a substep sees it once the part has found its own contacts and
    /// before it moves: its solver and the substep's uniforms.
    enum ContactPart {
        case solid(StructureSolver, StructureUniforms)
        case shell(ShellSolver, ShellUniforms)
    }

    /// Encodes the substeps in `substeps`, with the once-per-batch work first if `prelude`, its
    /// contact on in every part. `beforeNodes` runs in each substep once every part has found its
    /// own contacts and before any moves, for contact with other bodies.
    func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, substeps: Range<Int>, prelude: Bool,
        fluid: StructureSolver.FluidBinding, beforeNodes: @escaping ([ContactPart]) -> Void,
        afterSubstep: ((Int) -> Void)?
    ) {
        // Contact with other bodies needs every part's own table, so each part's contact is on.
        let modes = (solids?.contactMode, shells?.contactMode)
        solids?.contactMode = .always
        shells?.contactMode = .always
        defer {
            if let mode = modes.0 { solids?.contactMode = mode }
            if let mode = modes.1 { shells?.contactMode = mode }
        }
        if let mixed {
            mixed.encodeSubsteps(
                encoder, substeps: substeps, prelude: prelude, fluid: fluid,
                beforeNodes: { [mixed] solid, shell in
                    beforeNodes([.solid(mixed.solids, solid), .shell(mixed.shells, shell)])
                }, afterSubstep: afterSubstep)
        } else if let solids {
            solids.encodeSubsteps(
                encoder, substeps: substeps, prelude: prelude, fluid: fluid, interface: nil,
                beforeNodes: { [solids] _, uniforms in beforeNodes([.solid(solids, uniforms)]) },
                afterNodes: afterSubstep)
        } else if let shells {
            shells.encodeSubsteps(
                encoder, substeps: substeps, fluid: fluid, prelude: prelude, interface: nil,
                beforeNodes: { [shells] uniforms in beforeNodes([.shell(shells, uniforms)]) },
                afterNodes: afterSubstep)
        }
    }
}
