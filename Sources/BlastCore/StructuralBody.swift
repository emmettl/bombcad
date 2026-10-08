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
}
