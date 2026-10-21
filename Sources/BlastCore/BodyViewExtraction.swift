import Foundation
import Metal
import simd

/// Only the changing node and element values used by a view. Extracting these on the GPU avoids
/// copying velocities, stresses and constitutive history to the CPU for every recorded frame.
public struct BodyViewFields: Sendable {
    public var displacements: [SIMD3<Float>]
    public var rotations: [SIMD4<Float>]
    public var damage: [Float]
}

final class BodyViewExtractor {
    struct Part {
        var nodes: MTLBuffer
        var rotations: MTLBuffer
        var damage: MTLBuffer
        var nodeCount: Int
        var elementCount: Int
    }
    private let solidPipeline: MTLComputePipelineState
    private let shellPipeline: MTLComputePipelineState
    private let damagePipeline: MTLComputePipelineState
    private var parts: [(solid: Part?, shell: Part?)] = []

    init(library: MTLLibrary) throws {
        solidPipeline = try ShaderLibrary.pipeline("extractSolidViewNodes", in: library)
        shellPipeline = try ShaderLibrary.pipeline("extractShellViewNodes", in: library)
        damagePipeline = try ShaderLibrary.pipeline("extractSolidViewDamage", in: library)
    }

    func encode(
        _ encoder: MTLComputeCommandEncoder, bodies: [StructuralBody], control: MTLBuffer,
        layout: SIMD4<UInt32>
    ) {
        if parts.count != bodies.count { parts = Array(repeating: (nil, nil), count: bodies.count) }
        func sized(_ old: Part?, nodes: Int, elements: Int, shell: Bool) -> Part? {
            if let old, old.nodeCount == nodes, old.elementCount == elements { return old }
            let device = solidPipeline.device
            guard let positions = device.makeBuffer(length: max(16, nodes * 16), options: .storageModeShared),
                let rotations = device.makeBuffer(
                    length: max(16, shell ? nodes * 16 : 0), options: .storageModeShared),
                let damage = device.makeBuffer(length: max(4, elements * 4), options: .storageModeShared)
            else { return nil }
            return Part(
                nodes: positions, rotations: rotations, damage: damage, nodeCount: nodes,
                elementCount: elements)
        }
        func dispatch(_ pipeline: MTLComputePipelineState, count: Int) {
            guard count > 0 else { return }
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        }
        var layout = layout
        encoder.setBuffer(control, offset: 0, index: 0)
        encoder.setBytes(&layout, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
        for (index, body) in bodies.enumerated() {
            if let solid = body.solids {
                parts[index].solid = sized(
                    parts[index].solid, nodes: solid.nodeCount, elements: solid.elementCount, shell: false)
                if let part = parts[index].solid {
                    encoder.setBuffer(solid.nodeBuffer, offset: 0, index: 1)
                    encoder.setBuffer(part.nodes, offset: 0, index: 2)
                    dispatch(solidPipeline, count: part.nodeCount)
                    encoder.setBuffer(solid.stateBuffer, offset: 0, index: 1)
                    encoder.setBuffer(part.damage, offset: 0, index: 2)
                    dispatch(damagePipeline, count: part.elementCount)
                }
            } else {
                parts[index].solid = nil
            }
            if let shell = body.shells {
                let count = shell.elementCount + shell.beamCount == 0 ? 0 : shell.referenceBuffer.length / 16
                parts[index].shell = sized(parts[index].shell, nodes: count, elements: 0, shell: true)
                if let part = parts[index].shell {
                    encoder.setBuffer(shell.nodeBuffer, offset: 0, index: 1)
                    encoder.setBuffer(part.nodes, offset: 0, index: 2)
                    encoder.setBuffer(part.rotations, offset: 0, index: 3)
                    dispatch(shellPipeline, count: part.nodeCount)
                }
            } else {
                parts[index].shell = nil
            }
        }
    }

    func fields() -> [(solids: BodyViewFields?, shells: BodyViewFields?)] {
        func read<T>(_ buffer: MTLBuffer, count: Int) -> [T] {
            Array(
                UnsafeBufferPointer(
                    start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
        }
        func fields(_ part: Part?, shell: Bool) -> BodyViewFields? {
            part.map {
                BodyViewFields(
                    displacements: read($0.nodes, count: $0.nodeCount),
                    rotations: read($0.rotations, count: shell ? $0.nodeCount : 0),
                    damage: read($0.damage, count: $0.elementCount))
            }
        }
        return parts.map { (fields($0.solid, shell: false), fields($0.shell, shell: true)) }
    }
}

extension BlastSolver {
    /// Display values extracted with a requested or recorded field at this completed batch.
    /// Nil when not captured; callers can read the source buffers between batches instead.
    public func capturedBodyViewFields() -> [(solids: BodyViewFields?, shells: BodyViewFields?)]? {
        precondition(!batchInFlight, "Cannot read bodies while a batch is in flight")
        return frameExtractor?.bodyFields(time: time, steps: stepCount)
    }
}
