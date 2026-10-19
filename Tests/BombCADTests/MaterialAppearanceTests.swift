import BlastCore
import BlastRender
import Foundation
import Testing
import simd

/// Materials look like what they are, and the damage colouring reads over every one of them, to
/// people with each common colour deficiency as well.
@Suite("Material appearance")
struct MaterialAppearanceTests {
    @Test("Each material is drawn as its kind")
    func kinds() {
        #expect(MaterialAppearance(StructureMaterial.reinforcedConcrete) == .concrete)
        #expect(MaterialAppearance(.plainConcrete) == .concrete)
        #expect(MaterialAppearance(.structuralSteel) == .steel)
        #expect(MaterialAppearance(.annealedGlass) == .glass && MaterialAppearance(.toughenedGlass) == .glass)
        #expect(
            MaterialAppearance(.softwood) == .timber
                && MaterialAppearance(StructureMaterial.crossLaminatedTimber) == .timber)
        #expect(MaterialAppearance(.glulam) == .timber)
        #expect(MaterialAppearance(.masonry) == .brick)
        // A steel section standing as a rectangle, its density scaled down with it.
        let column = SteelSection.uc305x305x118.equivalent()
        #expect(column.density < 6000 && MaterialAppearance(column) == .steel)
        let sheet = ProfiledSheet(
            profile: .swedsteelSTW35, region: Box(min: .zero, max: SIMD3(6, 0.035, 3)), span: 2)
        #expect(MaterialAppearance(sheet.skinMaterial) == .sheeting)
        #expect(MaterialAppearance(sheet.ribMaterial(elementSize: 0.5)) == .sheeting)
        #expect(MaterialAppearance(.concreteBlock) == .blockwork)
        #expect(
            MaterialAppearance(.elastic(density: 1000, youngsModulus: 1e9, poissonRatio: 0.3)) == .neutral)
        // Every kind its own colour, and a palette always as long as the shaders read.
        let colours = MaterialAppearance.allCases.map(\.colour)
        #expect(Set(colours.map { [$0.x, $0.y, $0.z] }).count == colours.count)
        let palette = MaterialAppearance.palette([.structuralSteel, .reinforcedConcrete])
        #expect(palette.count == MaterialAppearance.paletteSize)
        #expect(
            palette[0] == MaterialAppearance.steel.colour && palette[1] == MaterialAppearance.concrete.colour)
    }

    // Machado, Oliveira and Fernandes (2009) at full severity, on linear RGB.
    static let deficiencies: [(String, simd_float3x3)] = [
        ("normal", matrix_identity_float3x3),
        (
            "protanopia",
            simd_float3x3(
                rows: [
                    SIMD3(0.152286, 1.052583, -0.204868), SIMD3(0.114503, 0.786281, 0.099216),
                    SIMD3(-0.003882, -0.048116, 1.051998),
                ])
        ),
        (
            "deuteranopia",
            simd_float3x3(
                rows: [
                    SIMD3(0.367322, 0.860646, -0.227968), SIMD3(0.280085, 0.672501, 0.047413),
                    SIMD3(-0.011820, 0.042940, 0.968881),
                ])
        ),
        (
            "tritanopia",
            simd_float3x3(
                rows: [
                    SIMD3(1.255528, -0.076749, -0.178779), SIMD3(-0.078411, 0.930809, 0.147602),
                    SIMD3(0.004733, 0.691367, 0.303900),
                ])
        ),
    ]

    /// CIE L*a*b* of linear sRGB (D65).
    static func lab(_ c: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_clamp(c, SIMD3(repeating: 0), SIMD3(repeating: 1))
        let x = (0.4124 * c.x + 0.3576 * c.y + 0.1805 * c.z) / 0.95047
        let y = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        let z = (0.0193 * c.x + 0.1192 * c.y + 0.9505 * c.z) / 1.08883
        func f(_ t: Float) -> Float { t > 0.008856 ? cbrt(t) : 7.787 * t + 16 / 116 }
        return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
    }

    /// CIE76 ΔE between two linear colours as someone with `deficiency` sees them.
    static func difference(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ deficiency: simd_float3x3) -> Float {
        simd_distance(lab(deficiency * a), lab(deficiency * b))
    }

    @Test("Damage and rubble stand out from every material, to every common colour deficiency")
    func damageReads() {
        // As `structureFragment` lights a face turned partly to the sun.
        let light: Float = 0.75
        let dataLight = 0.78 + 0.22 * light
        for kind in MaterialAppearance.allCases where kind != .glass {
            let c = kind.colour
            let sound = SIMD3(c.x, c.y, c.z) * light
            let rubble = kind.rubble * light
            for (name, deficiency) in Self.deficiencies {
                for damage: Float in [0.1, 0.5, 1] {
                    let tint = MaterialAppearance.damage(damage) * dataLight
                    // Sound against damaged: well apart (ΔE 15 or more).
                    #expect(
                        Self.difference(sound, tint, deficiency) >= 15, "\(kind) \(name), damage \(damage)")
                    if damage >= 0.5 {
                        // Failing against failed: apart (10 or more).
                        #expect(
                            Self.difference(tint, rubble, deficiency) >= 10,
                            "\(kind) \(name) rubble against damage \(damage)")
                    }
                }
                #expect(Self.difference(sound, rubble, deficiency) >= 15, "\(kind) \(name) rubble")
            }
        }
    }

    @Test("The shaders draw with the same palette, damage ramp, rubble and sheeting")
    func shaderMirrors() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let shader = try String(
            contentsOf: root.appending(path: "Sources/BlastRender/Shaders/Render.metal"), encoding: .utf8)
        #expect(shader.contains("constant uint paletteSize = \(MaterialAppearance.paletteSize);"))
        #expect(shader.contains("float3(0.98f, 0.82f, 0.25f), float3(0.93f, 0.42f, 0.12f)"))
        #expect(shader.contains("float3(0.93f, 0.42f, 0.12f), float3(0.55f, 0.06f, 0.08f)"))
        #expect(shader.contains("float3(0.20f * dot(base, float3(0.2126f, 0.7152f, 0.0722f)))"))
        #expect(MaterialAppearance.rubbleShade == 0.20)
        // The ray-traced blocks' looks, by `blockCode`.
        let looks = MaterialAppearance.allCases.map {
            String(format: "float3(%.2ff, %.2ff, %.2ff)", $0.colour.x, $0.colour.y, $0.colour.z)
        }
        let table = shader.components(separatedBy: "const float3 looks[8] = {").last ?? ""
        let entries = table.prefix { $0 != "}" }.components(separatedBy: "float3(").dropFirst()
            .map { "float3(" + $0.trimmingCharacters(in: CharacterSet(charactersIn: ", \n")) }
        #expect(entries == looks, "\(entries)")
        #expect(MaterialAppearance.concrete.blockCode == 1 && MaterialAppearance.neutral.blockCode == 8)
        #expect(MaterialAppearance(EnvelopeConstruction.Kind.unreinforcedMasonry) == .brick)
        #expect(MaterialAppearance(EnvelopeConstruction.Kind.profiledSteelSheeting) == .sheeting)
        #expect(MaterialAppearance(EnvelopeConstruction.Kind.crossLaminatedTimber) == .timber)
        let sheet = MaterialAppearance.sheeting.colour
        #expect(shader.contains("el.thickness < \(MaterialAppearance.sheetingThickness)f"))
        #expect(
            shader.contains(
                "float4(\(sheet.x)f, \(sheet.y)f, \(sheet.z)f, \(String(format: "%.2f", sheet.w))f)"))
    }
}
