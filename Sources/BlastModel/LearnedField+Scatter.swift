import Foundation

extension LearnedField {
    /// A network's own scatter about the runs, for the chances drawn where its peak is used
    /// (emmettl/bombcad-work#69): the glass's by side and the walls' and roofs'. Without it they
    /// draw the surrogate's scatter (`FacadeLoadSurrogate.Uncertainty.loadScatter`, a log-SD of
    /// 0.23–0.41) about the network's peak, which reads the runs with about 0.2. Only the peak's:
    /// the impulse is still the surrogate's, and so is its scatter. Opt-in until judged.
    ///
    /// Measured against Beirut's 4 m recorder runs and two made-up layouts', which the strict
    /// models never saw (`judge_field.py`'s strips, docs/learned-models.md, "The models' own
    /// scatter in the chances"): the root mean square of the log of the network's peak over the
    /// recorded strip's, bias and spread together as the surrogate's `leaveOneOut` is, by facing
    /// and scaled distance. Judged on Beirut's 2 m references it helps the glass and the combined
    /// models' walls a little, and loses round 2's walls their tenths test: not adopted.
    public struct Scatter: Sendable, Equatable {
        /// Up to scaled distance `upToZ`, m/kg^(1/3), the root mean square of the log peak's error.
        public struct Band: Sendable, Equatable {
            public var upToZ: Double
            public var peak: Double

            public init(upToZ: Double, peak: Double) {
                self.upToZ = upToZ
                self.peak = peak
            }
        }

        /// The ground floor's façade strips' bands and the storeys' above, each by facing: front
        /// (the face's normal against the direction to the charge over 1/3), side, and back (under
        /// −1/3). nil where the network gives no peak, and the strip keeps the surrogate's scatter.
        public var ground: [[Band]]?
        public var upper: [[Band]]?

        public init(ground: [[Band]]?, upper: [[Band]]?) {
            self.ground = ground
            self.upper = upper
        }

        /// The bands for a façade strip of the ground floor or above, facing as `cosIncidence`.
        public func bands(groundFloor: Bool, cosIncidence: Double) -> [Band]? {
            guard let byFacing = groundFloor ? ground : upper, byFacing.count == 3 else { return nil }
            return byFacing[cosIncidence > 1.0 / 3 ? 0 : cosIncidence < -1.0 / 3 ? 2 : 1]
        }

        /// The log-SD of `bands` at scaled distance `z`: the first band reaching it.
        public static func peak(_ bands: [Band], atZ z: Double) -> Double? {
            bands.first { z <= $0.upToZ }?.peak
        }

        static func bands(_ values: [Double]) -> [Band] {
            zip([7, 10, 14, 20, 28, Double.infinity], values).map { Band(upToZ: $0, peak: $1) }
        }

        /// Round 2's strict model (`field-unet-fp-strict`, the release `field-model-1`) at the
        /// ground floor, against 1.47 M strips of the recorder (`judge/fpw`). A band with too few
        /// strips (a side beyond Z 28) takes every facing's.
        public static let fieldModel1 = Scatter(
            ground: [
                bands([0.33, 0.21, 0.19, 0.19, 0.19, 0.29]),
                bands([0.33, 0.21, 0.20, 0.20, 0.22, 0.31]),
                bands([0.32, 0.21, 0.19, 0.19, 0.20, 0.33]),
            ], upper: nil)

        /// Round 4's strict model (`field-unet-l4-strict`) at every storey, against 7.6 M strips
        /// of the fixed recorder (`judge/l4`).
        public static let round4 = Scatter(
            ground: [
                bands([0.33, 0.23, 0.22, 0.24, 0.25, 0.38]),
                bands([0.34, 0.23, 0.22, 0.22, 0.22, 0.39]),
                bands([0.32, 0.22, 0.21, 0.23, 0.24, 0.40]),
            ],
            upper: [
                bands([0.32, 0.21, 0.20, 0.21, 0.23, 0.37]),
                bands([0.34, 0.21, 0.20, 0.21, 0.22, 0.38]),
                bands([0.34, 0.20, 0.19, 0.21, 0.23, 0.39]),
            ])

        /// The measured scatter of the weights in the file named `name`, if it is one measured.
        public static func measured(forWeights name: String) -> Scatter? {
            switch name {
            case "field-unet-fp-strict.bcfw": fieldModel1
            case "field-unet-l4-strict.bcfw": round4
            default: nil
            }
        }

        /// For an estimator with `groundNetwork`: the ground floor's from that network's, the
        /// storeys above from the levels network's.
        public static func combining(ground: Scatter?, upper: Scatter?) -> Scatter {
            Scatter(ground: ground?.ground, upper: upper?.upper)
        }
    }
}
