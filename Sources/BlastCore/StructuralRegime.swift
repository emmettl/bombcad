import Foundation
import simd

/// Where a structure lies from a scene's charges, which decides which concrete options suit it
/// (see docs/concrete-strategy.md). The validation cases fall into regimes that the options split
/// along; an option is the default within a regime when every case there agrees.
public enum StructuralRegime: String, Codable, CaseIterable, Sendable {
    /// Charges beyond 0.75 m/kg^(1/3) of the structure, in the open.
    case farField
    /// Within 0.75 m/kg^(1/3) but not in contact.
    case closeIn
    /// Within 0.15 m/kg^(1/3).
    case inContact
    /// A charge inside the structure's outline, or a closed room.
    case confined

    public var title: String {
        switch self {
        case .farField: "far field"
        case .closeIn: "close in"
        case .inContact: "in contact"
        case .confined: "confined"
        }
    }

    /// The regime of `model` in `scenario`: by the nearest charge's distance from the nearest point
    /// of the model's solids, over that charge's own cube root; nil without charges or solids.
    public static func detect(_ model: StructureModel, in scenario: Scenario) -> Self? {
        let charges = [scenario.charge] + (scenario.additionalCharges ?? [])
        guard let first = model.solids.first, charges.contains(where: { $0.mass > 0 }) else { return nil }
        let low = model.solids.reduce(first.min) { simd_min($0, $1.min) }
        let high = model.solids.reduce(first.max) { simd_max($0, $1.max) }
        let enclosed = charges.contains { all($0.position .> low) && all($0.position .< high) }
        if enclosed || scenario.reflectiveFaces != .ground { return .confined }
        let scaled = charges.filter { $0.mass > 0 }.map { charge in
            let distances = model.solids.map { box in
                simd_length(simd_clamp(charge.position, box.min, box.max) - charge.position)
            }
            return (distances.min() ?? .infinity) / pow(charge.mass, 1 / 3)
        }
        let nearest = scaled.min() ?? .infinity
        return nearest < 0.15 ? .inContact : nearest < 0.75 ? .closeIn : .farField
    }
}

/// How a structure is loaded: slowly, as the static beam tests were, or by a blast or a blow.
public enum StructuralLoading: String, Codable, CaseIterable, Sendable {
    case quasiStatic
    case impulsive
}

extension StructureModel {
    /// The regime the defaults are chosen for: the user's (`regimeOverride`) or, failing that,
    /// the one the scene detected.
    public var regime: StructuralRegime? { regimeOverride ?? detectedRegime }

    /// The loading the defaults are chosen for: the user's, or the scene's (impulsive), or the static
    /// tests' (quasi-static); nil when nothing says, and then no loading's defaults apply.
    public var loading: StructuralLoading? { loadingOverride ?? detectedLoading }

    /// Interlock that grows with pressure, as the solver applies it: set by the user, or by the
    /// confined regime's defaults, the one regime whose case (the chamber) it moves the right way.
    public var appliesPressedInterlock: Bool { pressedInterlock || pressedInterlockFromRegime }

    /// Whether pressed interlock is on only because the regime's defaults put it on.
    public var pressedInterlockFromRegime: Bool {
        !pressedInterlock && regimeDefaults && regime == .confined
    }

    /// Whether beams check each section's shear. Right for a beam pushed slowly (OA1 within 3%),
    /// but under a blow it failed every beam struck, so under impulsive loading the regime's
    /// defaults turn it off.
    public var appliesBeamSectionShear: Bool { !(regimeDefaults && loading == .impulsive) }

    /// Whether a cracked element's hourglass control softens with its cracking, as the user set or
    /// as the quasi-static regime's defaults have it. Pushed slowly, every case is the closer for it
    /// (OA1 on 24 elements 104% against 111%, Janney's beam failing at 40 mm against 42), but under
    /// a blow or a blast every case is the further (Ando's beams 66% off on average against 16%,
    /// the chamber's roof thrown), so only quasi-static loading has it by default.
    public var appliesHourglassFollowsCracking: Bool { hourglassFollowsCracking || hourglassFromRegime }

    /// Whether the hourglass control softens with cracking only because the regime's defaults have it.
    public var hourglassFromRegime: Bool {
        !hourglassFollowsCracking && regimeDefaults && loading == .quasiStatic
    }

    /// This model as the static tests load it, slowly: quasi-static unless the user chose.
    public func loadedSlowly() -> Self {
        var model = self
        model.detectedLoading = .quasiStatic
        return model
    }

    /// This model with the regime and loading `scenario` gives it, for a run in that scene.
    public func detectingRegime(in scenario: Scenario) -> Self {
        var model = self
        model.detectedRegime = StructuralRegime.detect(self, in: scenario)
        model.detectedLoading = .impulsive
        return model
    }
}
