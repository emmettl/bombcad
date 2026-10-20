import BlastModel
import Foundation
import Metal

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
