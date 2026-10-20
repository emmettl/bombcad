import BlastModel
import Foundation
import Metal
import simd

// Concrete elements that bend in their cracked concrete (`StructureModel.assumedStrainCracking`,
// `crackedHex` in Structure.metal): the pool of their points' histories, what it holds, and a way
// to switch elements by hand for the checks against the CPU reference (`CrackedHex`).
extension StructureSolver {
    /// What the pool holds: elements switched to their eight points, the most it can switch, and
    /// whether an element that would have switched could not because it was full. Nil without
    /// `assumedStrainCracking`.
    public struct AssumedStrainSummary: Sendable, Equatable {
        public var switched: Int
        public var capacity: Int
        public var poolFull: Bool
        public var elements: Int
    }

    public var assumedStrainSummary: AssumedStrainSummary? {
        guard let header = crackedElementBuffer else { return nil }
        let words = header.contents().bindMemory(to: UInt32.self, capacity: 4)
        return AssumedStrainSummary(
            switched: min(Int(words[0]), crackedCapacity), capacity: crackedCapacity, poolFull: words[2] != 0,
            elements: elementCount)
    }

    /// Whether element (i, j, k) works at its eight points.
    public func isSwitched(_ i: Int, _ j: Int, _ k: Int) -> Bool {
        guard let entries = crackedElementBuffer, let n = compactIndex(i, j, k) else { return false }
        return entries.contents().load(fromByteOffset: (1 + n) * Self.crackedElementStride, as: UInt32.self)
            != UInt32.max
    }

    /// The natural coordinates at which element (i, j, k)'s bars along `axis` are strained, across
    /// the axes after it; nil without the option or an element there.
    public func barPlace(_ i: Int, _ j: Int, _ k: Int, axis: Int) -> SIMD2<Float>? {
        guard let entries = crackedElementBuffer, let n = compactIndex(i, j, k) else { return nil }
        let base = entries.contents().advanced(by: (1 + n) * Self.crackedElementStride + 4 + 4 * axis)
        return SIMD2(
            Float(base.load(as: Float16.self)), Float(base.advanced(by: 2).load(as: Float16.self)))
    }

    /// How far each intact element's deformation is in its hourglass modes rather than its mean
    /// strain: (4 / h) sum |q| over the modes' amplitudes q against the mean displacement gradient's
    /// size, the bound `crackedLeavesElastic` widens by. Bending through a beam n elements deep gives
    /// about 1 / n at the extreme fibre; a mode the element does not resist grows far past 1. Each
    /// element's share, and whether it is switched to its eight points.
    public func modeShares() -> [(share: Float, switched: Bool)] {
        let h = model.elementSize
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        let flags = flagBuffer.contents().bindMemory(to: UInt8.self, capacity: ex * ey * ez)
        var shares: [(share: Float, switched: Bool)] = []
        mutateNodes { nodes in
            for n in 0..<elementCount where flags[Int(instances[n])] == ElementFlag.active.rawValue {
                let (i, j, k) = elementCoordinates(Int(instances[n]))
                var gradient = simd_float3x3(0)
                var sums = [SIMD3<Float>](repeating: .zero, count: 4)
                for a in 0..<8 {
                    let s = SIMD3<Float>(
                        a & 1 == 0 ? -1 : 1, (a >> 1) & 1 == 0 ? -1 : 1, (a >> 2) & 1 == 0 ? -1 : 1)
                    let u = nodes[nodeIndex(i + (a & 1), j + ((a >> 1) & 1), k + ((a >> 2) & 1))].displacement
                    gradient.columns.0 += u * s.x
                    gradient.columns.1 += u * s.y
                    gradient.columns.2 += u * s.z
                    sums[0] += s.y * s.z * u
                    sums[1] += s.x * s.z * u
                    sums[2] += s.x * s.y * u
                    sums[3] += s.x * s.y * s.z * u
                }
                // The mean strain's size (the gradient's symmetric part: a rigid turn is no strain).
                let strain = (gradient + gradient.transpose) * (0.5 / (4 * h))
                let size =
                    (simd_length_squared(strain.columns.0) + simd_length_squared(strain.columns.1)
                    + simd_length_squared(strain.columns.2)).squareRoot()
                let reach = sums.reduce(0) { $0 + simd_length($1) } * 0.125 * 4 / h
                shares.append((reach / max(size, 1e-12), isSwitched(i, j, k)))
            }
        }
        return shares
    }

    /// Empties the pool: no element switched, every point's history cleared.
    func resetCrackedPool() {
        guard let entries = crackedElementBuffer, let points = crackedPointBuffer else { return }
        let words = entries.contents().bindMemory(to: UInt32.self, capacity: 4 * (1 + max(elementCount, 1)))
        words[0] = 0
        words[1] = UInt32(crackedCapacity)
        words[2] = 0
        words[3] = 0
        for n in 0..<elementCount { words[4 * (1 + n)] = UInt32.max }
        memset(points.contents(), 0, points.length)
    }

    /// Byte offsets of the fields a switched element keeps per point, in `ElementState` and in
    /// `CrackedPoint` (Structure.metal), with their lengths.
    static let crackedPointFields: [(state: Int, point: Int, length: Int)] = [
        (80, 0, 12),  // crackStrain
        (124, 12, 12),  // crushStrain
        (112, 24, 12),  // confinementGain
        (148, 36, 12),  // crackResidual
        (180, 48, 12),  // jointSlip
        (136, 60, 8),  // crackFrame
        (160, 68, 8),  // secondCrack
        (144, 76, 4),  // compaction
        (168, 80, 4),  // secondOpening
        (172, 84, 4),  // secondHistory
        (192, 88, 4),  // compactionStart
        (108, 92, 4),  // crackingFactor
    ]

    /// Switches the elements `shouldSwitch` picks to their eight points now, as the kernel does the
    /// first time one of their points leaves the elastic range: each point takes the element's
    /// history as it stands, and its hourglass forces go. Returns how many it switched.
    @discardableResult
    public func switchToAssumedStrain(where shouldSwitch: (_ i: Int, _ j: Int, _ k: Int) -> Bool) -> Int {
        guard let entries = crackedElementBuffer, let points = crackedPointBuffer else { return 0 }
        let words = entries.contents().bindMemory(to: UInt32.self, capacity: 4 * (1 + max(elementCount, 1)))
        let instances = instanceBuffer.contents().bindMemory(to: UInt32.self, capacity: max(elementCount, 1))
        var switched = 0
        for n in 0..<elementCount where words[4 * (1 + n)] == UInt32.max && Int(words[0]) < crackedCapacity {
            let (i, j, k) = elementCoordinates(Int(instances[n]))
            guard shouldSwitch(i, j, k) else { continue }
            let slot = Int(words[0])
            words[0] += 1
            words[4 * (1 + n)] = UInt32(slot)
            let state = stateBuffer.contents().advanced(by: n * Self.stateStride)
            for point in 0..<8 {
                let record = points.contents().advanced(by: (8 * slot + point) * Self.crackedPointStride)
                for field in Self.crackedPointFields {
                    memcpy(record.advanced(by: field.point), state.advanced(by: field.state), field.length)
                }
            }
            memset(state.advanced(by: 32), 0, 48)  // the hourglass forces
            switched += 1
        }
        return switched
    }
}
