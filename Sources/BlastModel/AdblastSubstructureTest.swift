import Foundation

extension SheetProfile {
    /// Hacierba TR35/207 in ADBLAST Figure A5 (p. A-9): the drawing gives 34 mm outside
    /// depth, a 119 mm crest and a 40 mm trough at 207 mm pitch. The name's 35 is nominal.
    /// Straight walls omit corner radii and coatings, as for the other `SheetProfile` sections.
    public static func tr35(thickness: Float, yield: Float) -> Self {
        Self(
            name: "TR35/207 (\(thickness * 1000) mm)", shape: .trapezoidal, thickness: thickness,
            pitch: 0.207, depth: 0.034, crestWidth: 0.119, troughWidth: 0.040, yieldStress: yield,
            source: "ADBLAST (EUR 27487, 2015), Figure A5, p. A-9")
    }
}

extension AdblastCladdingTest {
    /// Table 17, p. 37. Missing measurements remain nil; inferred charges are not measurements.
    public struct SubstructureTest: Sendable, Decodable {
        public enum Profile: String, Sendable, Decodable {
            case tr35 = "TR35"
            case tr84 = "TR84"
        }
        public enum Support: String, Sendable, Decodable {
            case free, fixed
        }
        public var test: Int
        public var profile: Profile
        public var thicknessMM: Float
        public var midPurlinSupport: Support
        public var reflectedPeakKPa: Float
        public var reflectedImpulseKPaMS: Float
        public var firstDynamicDeflectionMM: Float?
        public var plasticDeformationMM: Float
        public var transferLoadF1kN: Float
        public var transferLoadF2kN: Float?
        public var purlinPlasticVerticalMM: Float
        public var purlinPlasticLateralMM: Float

        public func sheetProfile(yield: Float) -> SheetProfile {
            switch profile {
            case .tr35: .tr35(thickness: thicknessMM / 1000, yield: yield)
            case .tr84: .tr84(thickness: thicknessMM / 1000, yield: yield)
            }
        }
    }

    /// The twelve substructure shots in the canonical ADBLAST fixture, without dropping rows
    /// whose deflection or second force is missing. See Fixtures/ADBLAST2015/substructure/.
    public static func substructureTests(from url: URL) throws -> [SubstructureTest] {
        struct Fixture: Decodable { var substructureTests: [SubstructureTest] }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).substructureTests
    }

    /// The C4 charges reported in section 3.3.4.7, p. 32, in ascending order.
    public static let substructureChargeCandidates: [Float] = [0.25, 0.5, 1, 1.5]

    /// The stage-one protocol, fixed before a mechanical comparison: the charge whose predicted
    /// centre reflected impulse is nearest the measured one (absolute difference, kPa ms).
    /// Predictions must be in `substructureChargeCandidates` order, finite and positive for all
    /// four candidates. Ties take the smaller charge. Nil refuses an incomplete/invalid sweep.
    /// The answer is an inferred load input, never a reported per-shot charge.
    public static func substructureCharge(
        measuredImpulseKPaMS: Float, predictedImpulsesKPaMS: [Float]
    ) -> Float? {
        guard measuredImpulseKPaMS.isFinite, measuredImpulseKPaMS > 0,
            predictedImpulsesKPaMS.count == substructureChargeCandidates.count,
            predictedImpulsesKPaMS.allSatisfy({ $0.isFinite && $0 > 0 })
        else { return nil }
        var best = 0
        for index in predictedImpulsesKPaMS.indices.dropFirst()
        where abs(predictedImpulsesKPaMS[index] - measuredImpulseKPaMS)
            < abs(predictedImpulsesKPaMS[best] - measuredImpulseKPaMS)
        {
            best = index
        }
        return substructureChargeCandidates[best]
    }
}
