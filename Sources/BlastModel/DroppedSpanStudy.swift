import Foundation
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

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            speed: Float,
            seat: Float,
            peakSway: Float = 0,
            peakSlide: Float = 0,
            unseated: Float = 0,
            drop: Float = 0,
            summary: StructureSummary,
            wallSeconds: Double
        ) {
            self.speed = speed
            self.seat = seat
            self.peakSway = peakSway
            self.peakSlide = peakSlide
            self.unseated = unseated
            self.drop = drop
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
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
}
