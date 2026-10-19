import Foundation
import simd

/// A freestanding reinforced concrete wall under a blast, standing on each kind of base
/// connection in turn, to show how much the support assumption changes the response.
///
/// The wall is the deformable-wall preset's, 3 m high and 250 mm thick with a mat of 565 mm²/m
/// near each face, as a strip 1 m long. The blast is applied without the air: a triangular pulse
/// of the Kingery–Bulmash reflected pressure and impulse for a hemispherical surface burst at
/// the wall's distance, uniform over its face and with no clearing. This is a comparison of
/// support assumptions, not a validation: no measured wall is reproduced. Its starter bars
/// (`BaseConnection.dowelled`) are the vertical bars of both mats.
public enum AnchorageStudy {
    public static let height: Float = 3
    public static let thickness: Float = 0.25
    public static let length: Float = 1
    public static let barArea: Float = 565e-6

    public struct Result: Sendable {
        public var base: BaseConnection
        /// Reflected pressure (Pa) and duration (s) of the pulse.
        public var pressure: Float
        public var duration: Float
        /// The top's sway away from the charge: its largest, and where it is at the end.
        public var peakSway: Float
        public var finalSway: Float
        /// The base's largest opening and slip, the fraction of its nodes whose tie failed and its
        /// mean damage (zero when clamped).
        public var peakUplift: Float = 0
        public var maxSlip: Float = 0
        public var separated: Float = 0
        public var meanDamage: Float = 0
        /// The largest moment the base carried, per metre of wall, in N m/m.
        public var peakBaseMoment: Float = 0
        /// Loaded by the air: the impulse on the back face at mid-height, in Pa s, positive
        /// pushing towards the charge (the face's own positive phase is `pressure` × `duration` /
        /// 2), and the net impulse through the wall there, front less back, both over the 50 ms
        /// from the wave's arrival.
        public var backImpulse: Float = 0
        public var netImpulse: Float = 0
        /// The top's largest sway back towards the charge.
        public var peakBackSway: Float = 0
        /// On a footing: its largest rotation (radians, towards the back), the largest lift of
        /// its heel off the soil, and where it ends up: slid away from the charge and settled.
        public var footingRotation: Float = 0
        public var footingUplift: Float = 0
        public var footingSlide: Float = 0
        public var footingSettlement: Float = 0
        public var summary: StructureSummary
        public var wallSeconds: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            base: BaseConnection,
            pressure: Float,
            duration: Float,
            peakSway: Float,
            finalSway: Float,
            peakUplift: Float = 0,
            maxSlip: Float = 0,
            separated: Float = 0,
            meanDamage: Float = 0,
            peakBaseMoment: Float = 0,
            backImpulse: Float = 0,
            netImpulse: Float = 0,
            peakBackSway: Float = 0,
            footingRotation: Float = 0,
            footingUplift: Float = 0,
            footingSlide: Float = 0,
            footingSettlement: Float = 0,
            summary: StructureSummary,
            wallSeconds: Double
        ) {
            self.base = base
            self.pressure = pressure
            self.duration = duration
            self.peakSway = peakSway
            self.finalSway = finalSway
            self.peakUplift = peakUplift
            self.maxSlip = maxSlip
            self.separated = separated
            self.meanDamage = meanDamage
            self.peakBaseMoment = peakBaseMoment
            self.backImpulse = backImpulse
            self.netImpulse = netImpulse
            self.peakBackSway = peakBackSway
            self.footingRotation = footingRotation
            self.footingUplift = footingUplift
            self.footingSlide = footingSlide
            self.footingSettlement = footingSettlement
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
    }

    /// The connection `base` stands for. On a footing, the strip's footing reaches beyond the wall
    /// across its thickness only, as a slice of a long footing does, and stands on `soil` when
    /// given.
    public static func anchorage(_ base: BaseConnection, soil: Soil? = nil, embedment: Embedment? = nil)
        -> Anchorage?
    {
        guard var law = base.anchorage else { return nil }
        law.footing?.overhang.y = 0
        if let soil { law.footing?.soil = soil }
        law.footing?.embedment = embedment
        return law
    }
}
