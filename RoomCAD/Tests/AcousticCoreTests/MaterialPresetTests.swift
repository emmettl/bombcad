import Testing

@testable import AcousticCore

@Suite("Material presets")
struct MaterialPresetTests {
    private func preset(_ id: String, in presets: [MaterialPreset] = MaterialPresets.absorption) throws
        -> MaterialPreset
    {
        try #require(presets.first { $0.id == id })
    }

    @Test("Every published preset gives a valid material")
    func allValid() throws {
        #expect(MaterialPresets.absorption.count == 90)
        #expect(MaterialPresets.scattering.count == 7)
        #expect(MaterialPresets.categories(of: MaterialPresets.absorption).count == 11)
        #expect(Set(MaterialPresets.absorption.map(\.id)).count == 90)
        let base = SurfaceMaterial.uniform(0.2, scattering: 0.3, name: "Base")
        for preset in MaterialPresets.absorption {
            #expect((5...7).contains(preset.published.count), "\(preset.id)")
            try base.applying(absorption: preset).validate()
        }
        for preset in MaterialPresets.scattering {
            try base.applying(scattering: preset).validate()
        }
    }

    @Test("Values match the source, with 63 Hz and missing high bands taken from the nearest published band")
    func values() throws {
        let carpet = try preset("carpet_cotton")
        #expect(carpet.name == "Cotton carpet")
        #expect(carpet.coefficients == [0.07, 0.07, 0.31, 0.49, 0.81, 0.66, 0.54, 0.48])
        #expect(carpet.extendedBands == [63])

        let lead = try preset("lead_glazing")
        #expect(lead.published == [0.3, 0.2, 0.14, 0.1, 0.05, 0.05])
        #expect(lead.coefficients == [0.3, 0.3, 0.2, 0.14, 0.1, 0.05, 0.05, 0.05])
        #expect(lead.extendedBands == [63, 8000])
        #expect(lead.reference.contains("63 Hz and 8 kHz extended"))

        #expect(try preset("rough_concrete").coefficients[6] == 0.07)
        let skyline = try preset("rpg_skyline", in: MaterialPresets.scattering)
        #expect(skyline.coefficients == [0.01, 0.01, 0.08, 0.45, 0.82, 1.0, 1.0, 1.0])
    }

    @Test("Absorption presets keep a surface's scattering, and scattering presets its absorption")
    func independent() throws {
        let base = SurfaceMaterial.uniform(0.2, scattering: 0.3, name: "Base")
        let carpeted = base.applying(absorption: try preset("carpet_cotton"))
        #expect(carpeted.name == "Cotton carpet")
        #expect(carpeted.scattering == base.scattering)
        #expect(carpeted.reference.hasPrefix("Absorption: Vorländer"))

        let audience = try preset("theatre_audience", in: MaterialPresets.scattering)
        let scattered = carpeted.applying(scattering: audience)
        #expect(scattered.absorption == carpeted.absorption)
        #expect(scattered.name == "Cotton carpet")
        #expect(scattered.scattering == audience.coefficients)
        // Choosing again replaces the scattering note rather than adding another.
        let again = scattered.applying(
            scattering: try preset("classroom_tables", in: MaterialPresets.scattering))
        #expect(again.reference.components(separatedBy: "Scattering:").count == 2)
        #expect(again.reference.contains("classroom tables"))
    }
}
