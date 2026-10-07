import Foundation
import Metal
import simd

/// A body meshed partly with solid elements and partly with shells and beams: solid elements
/// where the stress through a wall's thickness matters, near a charge, and shells elsewhere.
///
/// Each shell node that lies in a solid element (where a shell's midsurface runs into a solid
/// part) is tied by a rigid link to the line of the solid's nodes that spans the shell's
/// thickness there, along its normal. It moves as the line does, with the line's mean
/// displacement and its rotation about the line's middle, and its force and moment are handed
/// to the line as the duals of those (the force in equal shares, the moment as forces across
/// the line), so the tie does no work of its own. Its mass is carried by the line. Both parts
/// take the shorter of their two time steps.
///
/// Each substep runs the solid elements, then a whole shell substep (in which the tied nodes
/// report their loads instead of moving), then the solid nodes, which take those loads, and
/// last the tied shell nodes, which follow.
///
/// Once contact is on in either part, it is on in both, and the parts meet each other too: in
/// each substep, after both have found their own contacts and before either moves, each solid
/// surface node and each shell node is pushed by the nodes of the other part within half the sum
/// of their spheres' widths (see `crossContactSolid` and `crossContactShell`).
public final class MixedStructure {
    public let solids: StructureSolver
    public let shells: ShellSolver
    public let model: StructureModel
    /// Shell nodes tied into solid elements.
    public let tiedNodes: [Int]

    private let interface: StructureSolver.InterfaceBuffers
    private let shellLink: MTLBuffer
    private let followPipeline: MTLComputePipelineState
    private let crossSolidPipeline: MTLComputePipelineState
    private let crossShellPipeline: MTLComputePipelineState
    private let placeholder: MTLBuffer
    /// Per shell node: found within reach of a solid node this substep.
    private let nearSolid: MTLBuffer
    private let commandQueue: MTLCommandQueue
    private let links: [(shellNode: Int, nodes: [Int], arms: [SIMD3<Float>])]

    public var criticalTimeStep: Float { solids.criticalTimeStep }
    public var time: Double { solids.time }

    public init(
        device: MTLDevice, commandQueue: MTLCommandQueue? = nil, library: MTLLibrary? = nil,
        model: StructureModel
    ) throws {
        guard let solidPart = model.part(.solid), let shellPart = model.part(.shell) else {
            throw BlastError.allocationFailed("a mixed body needs both solid elements and shells")
        }
        guard let queue = commandQueue ?? device.makeCommandQueue() else {
            throw BlastError.allocationFailed("command queue")
        }
        self.commandQueue = queue
        self.model = model
        let library = try library ?? ShaderLibrary.make(device: device)
        let solids = try StructureSolver(
            device: device, commandQueue: queue, library: library, model: solidPart)
        let shells = try ShellSolver(device: device, commandQueue: queue, library: library, model: shellPart)
        self.solids = solids
        self.shells = shells
        let step = min(solids.stableTimeStep, shells.stableTimeStep)
        solids.stepOverride = step
        shells.stepOverride = step
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw BlastError.missingFunction(name)
            }
            return try device.makeComputePipelineState(function: function)
        }
        followPipeline = try pipeline("shellFollowSolid")
        crossSolidPipeline = try pipeline("crossContactSolid")
        crossShellPipeline = try pipeline("crossContactShell")
        guard let placeholder = device.makeBuffer(length: 64, options: .storageModeShared) else {
            throw BlastError.allocationFailed("body interface")
        }
        self.placeholder = placeholder
        guard let near = device.makeBuffer(length: max(shells.nodeCount, 1) * 4, options: .storageModeShared)
        else { throw BlastError.allocationFailed("body interface") }
        nearSolid = near

        // Shell nodes inside, or on the surface of, a solid element (other than those already
        // tied to a column head) are tied to the line of the solid's nodes that spans the
        // shell's thickness there, along its normal.
        let h = solids.model.elementSize
        let slaves = Set(shells.mesh.ties.map { Int($0.slave) })
        var normal = Array(repeating: (axis: -1, thickness: Float(0)), count: shells.nodeCount)
        for element in shells.mesh.elements {
            for node in [element.nodes.x, element.nodes.y, element.nodes.z, element.nodes.w] {
                if element.thickness > normal[Int(node)].thickness {
                    normal[Int(node)] = (element.axis, element.thickness)
                }
            }
        }
        var found: [(shellNode: Int, nodes: [Int], arms: [SIMD3<Float>])] = []
        for (n, position) in shells.referencePositions.enumerated()
        where !slaves.contains(n) && normal[n].axis >= 0 {
            let g = (position - solids.origin) / h
            // Inside or on a solid element?
            let tolerance: Float = 1e-3
            let inside = (0..<8).contains { corner in
                let nudge = SIMD3<Float>(
                    corner & 1 == 0 ? -tolerance : tolerance, corner & 2 == 0 ? -tolerance : tolerance,
                    corner & 4 == 0 ? -tolerance : tolerance)
                let cell = (g + nudge).rounded(.down)
                let (i, j, k) = (Int(cell.x), Int(cell.y), Int(cell.z))
                return i >= 0 && j >= 0 && k >= 0 && i < solids.ex && j < solids.ey && k < solids.ez
                    && solids.flag(i, j, k) != .empty
            }
            guard inside else { continue }
            // The lattice line through the nearest lattice point, along the normal, within half
            // the thickness either side.
            let axis = normal[n].axis
            let nearest = g.rounded(.toNearestOrAwayFromZero)
            let reach = Int((0.5 * normal[n].thickness / h + tolerance).rounded(.down))
            var line: [(Int, SIMD3<Float>)] = []
            for offset in -reach...reach {
                var lattice = SIMD3<Int>(Int(nearest.x), Int(nearest.y), Int(nearest.z))
                lattice[axis] = Int((g[axis]).rounded(.toNearestOrAwayFromZero)) + offset
                if let node = solids.storedNode(lattice.x, lattice.y, lattice.z) {
                    line.append((node, solids.origin + SIMD3<Float>(lattice) * h))
                }
            }
            guard line.count >= 2, line.count <= 8 else { continue }
            let middle = line.reduce(SIMD3<Float>.zero) { $0 + $1.1 } / Float(line.count)
            found.append((n, line.map(\.0), line.map { $0.1 - middle }))
        }
        links = found
        tiedNodes = found.map(\.shellNode)

        // Each solid node's entries: which links reach it, as which member of the line.
        var perNode = Array(repeating: [SIMD2<UInt32>](), count: solids.nodeCount)
        for (index, link) in found.enumerated() {
            for (a, node) in link.nodes.enumerated() {
                perNode[node].append(SIMD2(UInt32(index), UInt32(a)))
            }
        }
        var start: [UInt32] = [0]
        var entries: [SIMD2<UInt32>] = []
        for list in perNode {
            entries += list
            start.append(UInt32(entries.count))
        }
        // GPU layout of `InterfaceLink`: shell node, count, eight nodes, eight packed arms, and
        // the inverse second moment.
        var linkWords: [UInt32] = []
        for link in found {
            linkWords += [UInt32(link.shellNode), UInt32(link.nodes.count)]
            linkWords += (0..<8).map { $0 < link.nodes.count ? UInt32(link.nodes[$0]) : 0 }
            for a in 0..<8 {
                let arm = a < link.arms.count ? link.arms[a] : .zero
                linkWords += [arm.x.bitPattern, arm.y.bitPattern, arm.z.bitPattern]
            }
            let second = link.arms.reduce(Float(0)) { $0 + simd_length_squared($1) }
            linkWords.append((1 / second).bitPattern)
        }
        var linkOf = Array(repeating: UInt32.max, count: shells.nodeCount)
        for (index, link) in found.enumerated() { linkOf[link.shellNode] = UInt32(index) }
        func buffer<T>(_ values: [T], minimum: Int = 16) throws -> MTLBuffer {
            let length = max(values.count * MemoryLayout<T>.stride, minimum)
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw BlastError.allocationFailed("body interface")
            }
            values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    buffer.contents().copyMemory(from: base, byteCount: bytes.count)
                }
            }
            return buffer
        }
        interface = StructureSolver.InterfaceBuffers(
            links: try buffer(linkWords), count: found.count, start: try buffer(start),
            entries: try buffer(entries),
            loads: try buffer(Array(repeating: SIMD4<Float>.zero, count: 2 * max(found.count, 1))))
        shellLink = try buffer(linkOf)
        reset()
    }

    /// Returns both parts to their undeformed state and ties them again.
    public func reset() {
        solids.reset()
        shells.reset()
        memset(nearSolid.contents(), 0, nearSolid.length)
        // The tied shell nodes move with the solid, which carries their mass.
        var masses: [(node: Int, mass: Float)] = []
        shells.mutateNodes { nodes in
            for link in links {
                masses.append((link.shellNode, nodes[link.shellNode].mass))
                nodes[link.shellNode].flags |= 256
            }
        }
        solids.mutateNodes { nodes in
            for (link, entry) in zip(links, masses) {
                for node in link.nodes { nodes[node].mass += entry.mass / Float(link.nodes.count) }
            }
        }
    }

    /// Encodes `count` substeps of both parts, tied.
    public func encodeSubsteps(
        _ encoder: MTLComputeCommandEncoder, count: Int, fluid: StructureSolver.FluidBinding?
    ) {
        let tie = (link: shellLink, loads: interface.loads)
        // Contact between the parts needs both parts' tables, so once either part would collide,
        // both do, for this batch (coupled to the air, from its first checkpoint after either
        // fails).
        let modes = (solids.contactMode, shells.contactMode)
        let failed = solids.encodesAsFailed || shells.encodesAsFailed
        let touching =
            modes.0 != .off && modes.1 != .off
            && (modes.0 == .always || modes.1 == .always || failed)
        if touching {
            solids.contactMode = .always
            shells.contactMode = .always
        }
        defer { (solids.contactMode, shells.contactMode) = modes }
        // Spheres of the two sizes touch at half the sum of their widths; nodes that began within
        // 1.5 of the larger element never repel, as within each part.
        var cross = SIMD2<Float>(
            0.5 * (solids.model.elementSize + shells.model.elementSize),
            1.5 * max(solids.model.elementSize, shells.model.elementSize))
        var first = true
        solids.encodeSubsteps(
            encoder, count: count, fluid: fluid, interface: links.isEmpty ? nil : interface,
            beforeNodes: { [self] substep, solidUniforms in
                shells.encodeSubsteps(
                    encoder, substeps: substep..<(substep + 1), fluid: fluid, prelude: first, interface: tie,
                    beforeNodes: { [self] shellUniforms in
                        guard touching else { return }
                        encodeCrossContact(encoder, solidUniforms, shellUniforms, &cross, fluid: fluid)
                    })
                first = false
            },
            afterNodes: { [self] _ in
                guard !links.isEmpty else { return }
                var linkCount = UInt32(links.count)
                encoder.setComputePipelineState(followPipeline)
                encoder.setBuffer(shells.nodeBuffer, offset: 0, index: 0)
                encoder.setBuffer(solids.nodeBuffer, offset: 0, index: 1)
                encoder.setBuffer(interface.links, offset: 0, index: 2)
                encoder.setBytes(&linkCount, length: 4, index: 3)
                encoder.dispatchThreads(
                    MTLSize(width: links.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(
                        width: followPipeline.threadExecutionWidth, height: 1, depth: 1))
            })
    }

    /// Each part's nodes against the other's, both from the substep's starting positions.
    private func encodeCrossContact(
        _ encoder: MTLComputeCommandEncoder, _ solidUniforms: StructureUniforms,
        _ shellUniforms: ShellUniforms,
        _ cross: inout SIMD2<Float>, fluid: StructureSolver.FluidBinding?
    ) {
        var solidUniforms = solidUniforms
        var shellUniforms = shellUniforms
        let control = fluid?.control ?? placeholder
        let pairs: [(MTLComputePipelineState, Int, [MTLBuffer], [MTLBuffer])] = [
            (
                crossSolidPipeline, solids.nodeCount,
                [solids.nodeListBuffer, solids.nodeBuffer, solids.contactSlotBuffer],
                [
                    solids.contactForceBuffer, shells.nodeBuffer, shells.referenceBuffer,
                    shells.contactHeadBuffer,
                    shells.contactSlotBuffer,
                ]
            ),
            (
                crossShellPipeline, shells.nodeCount,
                [shells.nodeBuffer, shells.referenceBuffer, shells.contactSlotBuffer],
                [
                    shells.contactForceBuffer, solids.nodeListBuffer, solids.nodeBuffer,
                    solids.contactHeadBuffer,
                    solids.contactSlotBuffer,
                ]
            ),
        ]
        for (index, (pipeline, count, own, other)) in pairs.enumerated() where count > 0 {
            let solidFirst = index == 0
            encoder.setComputePipelineState(pipeline)
            for (slot, buffer) in own.enumerated() { encoder.setBuffer(buffer, offset: 0, index: slot) }
            if solidFirst {
                encoder.setBytes(&solidUniforms, length: MemoryLayout<StructureUniforms>.stride, index: 3)
            } else {
                encoder.setBytes(&shellUniforms, length: MemoryLayout<ShellUniforms>.stride, index: 3)
            }
            encoder.setBuffer(control, offset: 0, index: 4)
            for (slot, buffer) in other.enumerated() { encoder.setBuffer(buffer, offset: 0, index: 5 + slot) }
            if solidFirst {
                encoder.setBytes(&shellUniforms, length: MemoryLayout<ShellUniforms>.stride, index: 10)
            } else {
                encoder.setBytes(&solidUniforms, length: MemoryLayout<StructureUniforms>.stride, index: 10)
            }
            encoder.setBytes(&cross, length: MemoryLayout<SIMD2<Float>>.stride, index: 11)
            encoder.setBuffer(nearSolid, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        }
    }

    /// Advances the body on its own by `steps` steps, blocking until done.
    public func advance(steps: Int) {
        var remaining = steps
        while remaining > 0 {
            let count = min(remaining, 2000)
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeComputeCommandEncoder()
            else { return }
            encodeSubsteps(encoder, count: count, fluid: nil)
            encoder.endEncoding()
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            solids.time += Double(count) * Double(criticalTimeStep)
            shells.time += Double(count) * Double(criticalTimeStep)
            remaining -= count
        }
    }
}
