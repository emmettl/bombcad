import Foundation

/// Published octave-band coefficients for common surfaces, to fill in a `SurfaceMaterial`.
public struct MaterialPreset: Identifiable, Equatable, Sendable {
    public var id: String
    public var category: String
    public var name: String
    /// As published, from 125 Hz upwards: six bands to 4 kHz or seven to 8 kHz (fewer for some
    /// scattering data).
    public var published: [Double]

    /// One value per band of `OctaveBands`. The 63 Hz band, which the data does not cover, takes the
    /// 125 Hz value, and bands above the last published one take its value.
    public var coefficients: [Double] {
        (0..<OctaveBands.count).map { band in
            band == 0 ? published[0] : published[min(band - 1, published.count - 1)]
        }
    }

    /// Bands whose values are extended rather than published, as nominal frequencies.
    public var extendedBands: [Int] {
        [OctaveBands.nominalCentres[0]] + OctaveBands.nominalCentres.dropFirst(published.count + 1)
    }

    /// How the coefficients were obtained, for a material's reference.
    public var reference: String {
        let extended = extendedBands.map { $0 >= 1000 ? "\($0 / 1000) kHz" : "\($0) Hz" }
        return "Vorländer, Auralization (Springer, 2008), annex, via pyroomacoustics: \(name). "
            + "\(extended.joined(separator: " and ")) extended from the nearest published band."
    }
}

public enum MaterialPresets {
    /// Absorption coefficients for 90 surfaces, in 11 categories.
    public static let absorption: [MaterialPreset] = absorptionTable.map {
        MaterialPreset(id: $0.id, category: $0.category, name: $0.name, published: $0.coefficients)
    }

    /// Scattering coefficients for diffusers, seating and audience, and studio wall and ceiling boxes.
    public static let scattering: [MaterialPreset] = scatteringTable.map {
        MaterialPreset(id: $0.id, category: $0.category, name: $0.name, published: $0.coefficients)
    }

    /// Category names in their published order.
    public static func categories(of presets: [MaterialPreset]) -> [String] {
        var seen: [String] = []
        for preset in presets where !seen.contains(preset.category) { seen.append(preset.category) }
        return seen
    }
}

extension SurfaceMaterial {
    /// This material with a preset's absorption and name; its scattering is kept, because the absorption
    /// data does not include scattering.
    public func applying(absorption preset: MaterialPreset) -> SurfaceMaterial {
        var material = self
        material.name = preset.name
        material.absorption = preset.coefficients
        material.reference = "Absorption: \(preset.reference)"
        return material
    }

    /// This material with a preset's scattering; its absorption and name are kept.
    public func applying(scattering preset: MaterialPreset) -> SurfaceMaterial {
        var material = self
        material.scattering = preset.coefficients
        let absorption =
            material.reference.components(separatedBy: " Scattering: ").first ?? material.reference
        material.reference = "\(absorption) Scattering: \(preset.reference)"
        return material
    }
}
