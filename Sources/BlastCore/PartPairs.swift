import Foundation
import Metal
import simd

/// Connections between two parts of a body of solid elements (`Anchorage.betweenParts`): pairs of
/// nodes across a gap, each tied by its law on their relative motion (`structurePairs` in
/// Structure.metal), the first node taking the force and the second its opposite.
public final class PartPairs {
    struct Pair {
        var owner: Int
        var partner: Int
        /// Area the pair stands for, on the owner's side, in m².
        var area: Float
        /// The connection's slot (as `StructureModel.connectionSlot`).
        var slot: Int
        /// How far the owner can slide along each axis of the joint (+along, -along, +other,
        /// -other) before it is off the other part's faces.
        var seat: SIMD4<Float>
        var reducedMass: Float
        var law: AnchorageParameters
    }

    /// The pairs' state after the last step.
    public struct Summary: Sendable {
        /// Pairs, those whose tie has lost all its strength, and those slid off their seat.
        public var pairs = 0
        public var separated = 0
        public var unseated = 0
        /// The force the lower (supporting) parts put on the upper ones through the pairs, in N.
        public var force = SIMD3<Float>.zero
        /// The largest slip and opening of any pair, relative between its nodes, in metres.
        public var maxSlip: Float = 0
        public var maxOpening: Float = 0
        /// The bearing area still seated, in m².
        public var seatedArea: Float = 0
        /// The work the pairs' sliding has dissipated, in joules.
        public var dissipated: Float = 0
    }

    let count: Int
    let nodes: MTLBuffer
    let state: MTLBuffer
    let seats: MTLBuffer
    let laws: MTLBuffer
    let nodeStart: MTLBuffer
    let nodeEntries: MTLBuffer
    private let list: [Pair]
    private let initial: [SIMD4<Float>]

    init(device: MTLDevice, pairs: [Pair], nodeCount: Int) throws {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            return buffer
        }
        list = pairs
        count = pairs.count
        nodes = try buffer(count * 8, "part pair nodes")
        nodes.copy(pairs.map { SIMD2(UInt32($0.owner), UInt32($0.partner)) })
        seats = try buffer(count * 16, "part pair seats")
        seats.copy(pairs.map(\.seat))
        laws = try buffer(count * MemoryLayout<AnchorageParameters>.stride, "part pair laws")
        laws.copy(pairs.map(\.law))
        initial = pairs.flatMap {
            [SIMD4($0.area, 0, 0, 0), SIMD4<Float>.zero, SIMD4(0, 0, $0.reducedMass, 0)]
        }
        state = try buffer(count * 48, "part pair state")
        // Each node's pairs, in order: +(p + 1) where it is the first node, -(p + 1) the second.
        var lists = [[Int32]](repeating: [], count: nodeCount)
        for (p, pair) in pairs.enumerated() {
            lists[pair.owner].append(Int32(p + 1))
            lists[pair.partner].append(-Int32(p + 1))
        }
        var starts: [UInt32] = [0]
        var entries: [Int32] = []
        for list in lists {
            entries += list
            starts.append(UInt32(entries.count))
        }
        nodeStart = try buffer(starts.count * 4, "part pair starts")
        nodeStart.copy(starts)
        nodeEntries = try buffer(entries.count * 4, "part pair entries")
        nodeEntries.copy(entries)
        reset()
    }

    func reset() { state.copy(initial) }

    /// The area of the pairs in `slot`.
    func area(inSlot slot: Int) -> Float { list.filter { $0.slot == slot }.reduce(0) { $0 + $1.area } }

    /// Read only while the GPU is idle. `nodes` gives access to the body's nodes.
    func summary(slot: Int?, nodes access: ((UnsafeMutableBufferPointer<StructureNode>) -> Void) -> Void)
        -> Summary
    {
        let values = state.contents().bindMemory(to: SIMD4<Float>.self, capacity: 3 * count)
        var summary = Summary()
        access { nodes in
            for (p, pair) in list.enumerated() where slot.map({ $0 == pair.slot }) ?? true {
                let stored = values[3 * p]
                let law = pair.law
                let normal = SIMD3(law.bearing.y, law.bearing.z, law.bearing.w)
                let across = normal == .zero ? SIMD3<Float>(0, 0, 1) : normal
                let kn = law.stiffnessAndTension.x
                let strength = law.stiffnessAndTension.z
                let cohesion = law.failureAndFriction.y
                let remaining: Float
                if strength > 0 || cohesion > 0 {
                    let plateau = max(law.stiffnessAndTension.w, strength / kn)
                    let end = max(law.failureAndFriction.x, plateau)
                    let peak = values[3 * p + 1].w
                    let envelope: Float =
                        strength <= 0 || peak <= plateau
                        ? 1 : (peak >= end ? 0 : (end - peak) / (end - plateau))
                    remaining = (1 - stored.w) * envelope
                } else {
                    remaining = 1
                }
                summary.pairs += 1
                if remaining <= 0 { summary.separated += 1 }
                let unseated = values[3 * p + 2].y != 0
                if unseated { summary.unseated += 1 } else { summary.seatedArea += pair.area }
                summary.dissipated += values[3 * p + 2].w
                summary.force += SIMD3(values[3 * p + 1].x, values[3 * p + 1].y, values[3 * p + 1].z)
                summary.maxSlip = max(summary.maxSlip, simd_length(SIMD2(stored.y, stored.z)))
                let relative = nodes[pair.owner].displacement - nodes[pair.partner].displacement
                summary.maxOpening = max(summary.maxOpening, simd_dot(relative, across) - values[3 * p + 2].x)
            }
        }
        return summary
    }
}
