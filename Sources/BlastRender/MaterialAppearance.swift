import BlastCore
import simd

/// How a structural material looks in the viewport and snapshots, read from what the material is:
/// its model, density, masonry units and transparency. The colours are restrained, so the damage
/// colouring and the blast's field drawn over them stay readable on every one (`damage(_:)`).
public enum MaterialAppearance: Sendable, Equatable, CaseIterable {
    case concrete
    case steel
    /// Thin steel shells (profiled cladding): the steel lighter, as galvanised sheet reads.
    case sheeting
    case glass
    case timber
    case brick
    case blockwork
    /// Anything else, as rigid blocks and scenery are drawn.
    case neutral

    /// The kind of `material`.
    public init(_ material: StructureMaterial) {
        if material.isTransparent {
            self = .glass
        } else if material.model == .timber {
            self = .timber
        } else if let units = material.units {
            // Bricks are 65 mm a course and 225 mm long; blocks are 215 mm a course.
            self = units.courseHeight < 0.15 ? .brick : .blockwork
        } else if material.model == .vonMises
            && (material.name.hasSuffix(", skin") || material.name.hasSuffix(", ribs"))
        {
            // A profiled sheet's skin and ribs, as `ProfiledSheet` names them: steel scaled to the
            // profile's depth, so neither its density nor its thickness says what it is.
            self = .sheeting
        } else if material.model == .vonMises && (material.rateLaw != nil || material.density > 6000) {
            // Steel: its rate law survives a section's scaling (`SteelSection.equivalent`), which
            // scales its density with the section's area.
            self = .steel
        } else if material.model == .concrete {
            self = .concrete
        } else {
            self = .neutral
        }
    }

    /// An exposure-only building's walls, by their construction: unreinforced masonry as brick.
    public init(_ construction: EnvelopeConstruction.Kind) {
        switch construction {
        case .reinforcedConcrete: self = .concrete
        case .unreinforcedMasonry: self = .brick
        case .reinforcedBlockwork: self = .blockwork
        case .profiledSteelSheeting: self = .sheeting
        case .crossLaminatedTimber: self = .timber
        }
    }

    /// The code a ray-traced block carries for its look (`SceneRenderer`, `sceneFragment`): its
    /// place among `allCases`, from 1; 0 is a plain block, drawn neutral.
    public var blockCode: Float { Float(Self.allCases.firstIndex(of: self)! + 1) }

    /// Linear RGB under full light, and in `w` how strongly it shows the sun's highlight.
    public var colour: SIMD4<Float> {
        switch self {
        case .concrete: SIMD4(0.80, 0.79, 0.76, 0)
        case .steel: SIMD4(0.30, 0.36, 0.46, 0.35)
        case .sheeting: SIMD4(0.76, 0.79, 0.82, 0.30)
        case .glass: SIMD4(0.55, 0.74, 0.74, 0)
        case .timber: SIMD4(0.66, 0.50, 0.34, 0.04)
        case .brick: SIMD4(0.64, 0.40, 0.31, 0)
        case .blockwork: SIMD4(0.73, 0.71, 0.66, 0)
        case .neutral: SIMD4(0.72, 0.72, 0.72, 0)
        }
    }

    /// Steel shells thinner than this are drawn as sheeting.
    public static let sheetingThickness: Float = 0.004

    /// The colours of `materials` in order, for the shaders, padded to `StructureModel`'s most
    /// materials with the solids' joint materials (`StructureSolver.materials` may hold up to
    /// twice as many) so any index reads a colour.
    public static func palette(_ materials: [StructureMaterial]) -> [SIMD4<Float>] {
        var colours = materials.map { MaterialAppearance($0).colour }
        while colours.count < paletteSize { colours.append(MaterialAppearance.concrete.colour) }
        return Array(colours.prefix(paletteSize))
    }

    /// Entries in a palette: the low four bits of a solid's material index.
    public static let paletteSize = 16

    /// The damage colouring laid over any material, as `structureFragment` draws it: amber at the
    /// first damage, through orange to dark red as an element nears failure.
    public static func damage(_ damage: Float) -> SIMD3<Float> {
        let d = min(max(damage, 0), 1)
        let amber = SIMD3<Float>(0.98, 0.82, 0.25)
        let orange = SIMD3<Float>(0.93, 0.42, 0.12)
        let red = SIMD3<Float>(0.55, 0.06, 0.08)
        return d < 0.5 ? amber + (orange - amber) * (d * 2) : orange + (red - orange) * (d * 2 - 1)
    }

    /// Failed elements, drawn as rubble: a dark neutral grey at a fifth of the material's
    /// luminance. Tinted by the material, brick's and timber's rubble read as the heaviest damage's
    /// dark red to a protanope; grey, every pair stays apart (`MaterialAppearanceTests`).
    public var rubble: SIMD3<Float> {
        let c = colour
        let luminance = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        return SIMD3(repeating: Self.rubbleShade * luminance)
    }

    /// The rubble's share of the material's luminance.
    public static let rubbleShade: Float = 0.20
}
