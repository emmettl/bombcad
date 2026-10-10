import Foundation
import Metal
import simd

/// A precast beam seated on corbels at the tops of two columns, one column struck away from the
/// span, to show a span that drops once its column has swayed off its seat.
///
/// Two reinforced concrete columns 0.4 m square and 3.6 m high, clamped at their bases, stand
/// with 6 m between their faces, each with a corbel 0.3 m deep reaching 0.3 m into the span at its
/// top. A precast beam 0.4 m wide and 0.5 m deep sits on both across a gap of one element (a
/// bearing pad), `seat` metres of each end on its corbel, tied to it by `Anchorage.betweenParts`:
/// resting with friction 0.5 unless given another law. Both column and beam move: the right
/// column is given a velocity away from the span rising linearly from nothing at its base to
/// `speed` at its top, as a blast's impulse on its far face might, and the beam is carried along
/// by friction until it slides on its seat, or off it. Every element is reinforced concrete with
/// the model's automatic mats. This shows the mechanism; it is not a validation.
public enum DroppedSpanStudy {
    public static let columnSide: Float = 0.4
    public static let height: Float = 3.6
    public static let span: Float = 6
    public static let corbel: Float = 0.3
    public static let depth: Float = 0.5

    public struct Result: Sendable {
        public var speed: Float
        public var seat: Float
        /// The struck column's largest sway at its top, and the beam's largest slide on that
        /// column's corbel, in metres.
        public var peakSway: Float = 0
        public var peakSlide: Float = 0
        /// The share of the struck end's bearing area slid off its seat, at the end.
        public var unseated: Float = 0
        /// How far the beam's struck end has fallen at the end, in metres.
        public var drop: Float = 0
        public var summary: StructureSummary
        public var wallSeconds: Double
    }

    /// The study's body, the beam seated `seat` metres on each corbel, by `law` (resting with
    /// friction 0.5 by default), on elements of `elementSize`.
    public static func model(seat: Float, law: Anchorage = .resting(friction: 0.5), elementSize: Float = 0.1)
        -> StructureModel
    {
        let h = elementSize
        let right = columnSide + span
        let top = height
        let solids = [
            Box(min: .zero, max: SIMD3(columnSide, columnSide, top)),
            Box(min: SIMD3(right, 0, 0), max: SIMD3(right + columnSide, columnSide, top)),
            Box(min: SIMD3(columnSide, 0, top - corbel), max: SIMD3(columnSide + corbel, columnSide, top)),
            Box(min: SIMD3(right - corbel, 0, top - corbel), max: SIMD3(right, columnSide, top)),
            Box(
                min: SIMD3(columnSide + corbel - seat, 0, top + h),
                max: SIMD3(right - corbel + seat, columnSide, top + h + depth)),
        ]
        var model = StructureModel(solids: solids, elementSize: h, fixedBase: true)
        model.autoReinforce()
        var law = law
        law.betweenParts = true
        for low in [columnSide, right - corbel] {
            model.supports.append(
                Box(
                    min: SIMD3(low - 0.01, -0.01, top - 0.01),
                    max: SIMD3(low + corbel + 0.01, columnSide + 0.01, top + h + 0.01)))
            model.supportAnchorages.append(law)
        }
        return model
    }

    /// Runs the study for `duration` seconds after the strike.
    public static func run(
        device: MTLDevice, seat: Float, speed: Float, law: Anchorage = .resting(friction: 0.5),
        duration: Float = 1.5, elementSize: Float = 0.1
    ) throws -> Result {
        let started = ContinuousClock.now
        let model = model(seat: seat, law: law, elementSize: elementSize)
        let solver = try StructureSolver(device: device, model: model)
        // Pieces that fall meet what is below them.
        solver.contactMode = .always
        let dt = Double(solver.criticalTimeStep)
        solver.damping = 100
        solver.advance(steps: Int((0.1 / dt).rounded()))
        solver.damping = 0

        let h = model.elementSize
        let right = columnSide + span
        // The struck column's nodes, its top's, and the beam's nodes over its corbel and their
        // corbel's below them.
        var struck: [(node: Int, height: Float)] = []
        var beamEnd: [Int] = []
        var corbelTop: [Int] = []
        var columnTop: Int?
        for k in 0...solver.ez {
            for j in 0...solver.ey {
                for i in 0...solver.ex {
                    guard let n = solver.storedNode(i, j, k) else { continue }
                    let p = solver.referencePosition(i, j, k)
                    if p.x >= right - corbel - 1e-3 && p.z <= height + 1e-3 {
                        struck.append((n, p.z))
                        if abs(p.z - height) < 1e-3, abs(p.x - (right + columnSide)) < 1e-3 { columnTop = n }
                    }
                    if p.x >= right - corbel - 1e-3, p.x <= right - corbel + seat + 1e-3 {
                        if abs(p.z - (height + h)) < 1e-3 { beamEnd.append(n) }
                        if abs(p.z - height) < 1e-3 { corbelTop.append(n) }
                    }
                }
            }
        }
        solver.mutateNodes { nodes in
            for (n, z) in struck { nodes[n].velocity.x += speed * z / height }
        }
        func mean(_ list: [Int], _ nodes: UnsafeMutableBufferPointer<StructureNode>) -> SIMD3<Float> {
            list.reduce(SIMD3<Float>.zero) { $0 + nodes[$1].displacement } / Float(max(list.count, 1))
        }
        var result = Result(speed: speed, seat: seat, summary: StructureSummary(), wallSeconds: 0)
        let sample = 5e-3
        let stepsPerSample = max(1, Int((sample / dt).rounded()))
        var start = SIMD3<Float>.zero
        solver.mutateNodes { start = mean(beamEnd, $0) }
        for _ in 0..<Int((Double(duration) / sample).rounded()) {
            solver.advance(steps: stepsPerSample)
            solver.mutateNodes { nodes in
                if let columnTop { result.peakSway = max(result.peakSway, nodes[columnTop].ux) }
                result.peakSlide = max(result.peakSlide, mean(corbelTop, nodes).x - mean(beamEnd, nodes).x)
                result.drop = start.z - mean(beamEnd, nodes).z
            }
        }
        // The struck end's seat is the second support region.
        if let pairs = solver.pairSummary(support: 1) {
            result.unseated = 1 - pairs.seatedArea / max(solver.supportBearingArea(at: 1), 1e-9)
        }
        result.summary = solver.summary()
        let elapsed = ContinuousClock.now - started
        result.wallSeconds =
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
        return result
    }
}
