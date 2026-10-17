import Foundation
import simd

/// The cross-section of a profiled metal sheet, trapezoidal or sinusoidal, by its centreline
/// over one pitch, and the section properties that follow from it as a thin-walled section.
/// The library's profiles are cited (docs/profiled-sheeting.md).
public struct SheetProfile: Sendable, Hashable, Codable {
    public enum Shape: String, Sendable, Hashable, Codable {
        case trapezoidal, sinusoidal
    }

    public var name: String
    public var shape: Shape
    /// Steel thickness (m): the design (bare) thickness, without coatings.
    public var thickness: Float
    /// Rib pitch, centre to centre (m).
    public var pitch: Float
    /// Overall depth (m), outside face to outside face.
    public var depth: Float
    /// Trapezoidal only: the flat widths of the crest and the trough (m), measured to where the
    /// webs' centrelines meet them.
    public var crestWidth: Float
    public var troughWidth: Float
    /// The effective section modulus (m³ per metre width) its maker gives for bending, local
    /// buckling allowed for (EN 1993-1-3), the lesser of the two directions; nil where none is
    /// given, when the plastic modulus is used.
    public var effectiveModulus: Float?
    /// Its steel's yield stress (Pa), as its maker gives it.
    public var yieldStress: Float
    /// Where the numbers come from.
    public var source: String

    public init(
        name: String, shape: Shape, thickness: Float, pitch: Float, depth: Float, crestWidth: Float = 0,
        troughWidth: Float = 0, effectiveModulus: Float? = nil, yieldStress: Float, source: String
    ) {
        self.name = name
        self.shape = shape
        self.thickness = thickness
        self.pitch = pitch
        self.depth = depth
        self.crestWidth = crestWidth
        self.troughWidth = troughWidth
        self.effectiveModulus = effectiveModulus
        self.yieldStress = yieldStress
        self.source = source
    }

    /// The quarter-scale stainless steel blast wall of Langdon's pulse-pressure tests: 2 mm of
    /// 316L, a 220 mm pitch, 40.5 mm deep between the flanges' centrelines, its flats 95 and 45 mm
    /// to the webs' intersections (her Table 7-1 and Fig. 5-7). Its 0.2% proof stress is 296 MPa
    /// statically (Table 3-2, 2 mm, the mean of the two directions) and 356 MPa at 0.42 /s
    /// (Table 3-4).
    public static let langdonBlastWall = Self(
        name: "Langdon's quarter-scale blast wall", shape: .trapezoidal, thickness: 0.002, pitch: 0.22,
        depth: 0.0425, crestWidth: 0.045, troughWidth: 0.095, yieldStress: 296e6,
        source: "G. S. Langdon, PhD thesis, University of Liverpool, 2003: Table 7-1, Fig. 5-7, Table 3-2")

    /// Swedsteel STR45, a roof profile, 0.7 mm nominal (0.63 mm design thickness) of S350GD: 43 mm
    /// deep, crest 47 mm, trough 77 mm, at 180 mm. Its effective modulus is the lesser of the two
    /// directions at the ultimate limit state, 6,931 mm³/m.
    public static let swedsteelSTR45 = Self(
        name: "Trapezoidal roof sheet, 45 mm (STR45, 0.7 mm)", shape: .trapezoidal, thickness: 0.00063,
        pitch: 0.18, depth: 0.043, crestWidth: 0.047, troughWidth: 0.077, effectiveModulus: 6931e-9,
        yieldStress: 350e6,
        source: "Swedsteel-Metecno, Static designing tables for trapezoidal sheets (EN 1993-1-3), REV.1, 2016"
    )

    /// Swedsteel STW35, a wall profile, 0.7 mm nominal (0.63 mm design thickness) of S350GD: 32 mm
    /// deep, crest 70 mm, trough 40 mm, at 159 mm; effective modulus 5,179 mm³/m.
    public static let swedsteelSTW35 = Self(
        name: "Trapezoidal wall sheet, 32 mm (STW35, 0.7 mm)", shape: .trapezoidal, thickness: 0.00063,
        pitch: 0.159, depth: 0.032, crestWidth: 0.07, troughWidth: 0.04, effectiveModulus: 5179e-9,
        yieldStress: 350e6,
        source: "Swedsteel-Metecno, Static designing tables for trapezoidal sheets (EN 1993-1-3), REV.1, 2016"
    )

    /// A sinusoidal ("corrugated") sheet of 76 mm pitch and 18 mm depth, as ArcelorMittal's
    /// Frequence 13.76.18, at its thinnest, 0.63 mm, of S280GD (the maker gives no section
    /// properties; they are computed here).
    public static let sinusoidal76x18 = Self(
        name: "Sinusoidal sheet, 76/18 (0.63 mm)", shape: .sinusoidal, thickness: 0.00063, pitch: 0.076,
        depth: 0.018, yieldStress: 280e6,
        source: "ArcelorMittal Frequence 13.76.18: 76 mm pitch, 18 mm deep, 0.63 to 1.25 mm")

    public static let library: [Self] = [
        .swedsteelSTR45, .swedsteelSTW35, .sinusoidal76x18, .langdonBlastWall,
    ]

    /// The centreline over one pitch, from one trough's middle to the next, as (across, up)
    /// points in metres, the troughs' centreline at zero.
    public var centreline: [SIMD2<Double>] {
        let p = Double(pitch)
        let h = Double(depth - thickness)
        switch shape {
        case .trapezoidal:
            let crest = Double(crestWidth)
            let trough = Double(troughWidth)
            let web = (p - crest - trough) / 2
            return [
                SIMD2(0, 0), SIMD2(trough / 2, 0), SIMD2(trough / 2 + web, h),
                SIMD2(trough / 2 + web + crest, h), SIMD2(p - trough / 2, 0), SIMD2(p, 0),
            ]
        case .sinusoidal:
            return (0...96).map { n in
                let x = p * Double(n) / 96
                return SIMD2(x, h / 2 * (1 - cos(2 * Double.pi * x / p)))
            }
        }
    }

    /// Section properties of one pitch: area (m²), the centroid's height above the troughs'
    /// centreline (m), second moment of area (m⁴) and plastic modulus (m³), about the axis across
    /// the ribs, each wall a line of the thickness.
    public var section: (area: Double, centroid: Double, secondMoment: Double, plasticModulus: Double) {
        let t = Double(thickness)
        let points = centreline
        // Each wall: its two ends' heights and its area.
        var walls: [(low: Double, high: Double, area: Double)] = []
        for n in 1..<points.count {
            let (a, b) = (points[n - 1], points[n])
            walls.append((a.y, b.y, t * simd_length(b - a)))
        }
        var area = 0.0
        var moment = 0.0
        for wall in walls {
            area += wall.area
            moment += wall.area * 0.5 * (wall.low + wall.high)
        }
        let centroid = moment / area
        var secondMoment = 0.0
        for wall in walls {
            let ya = wall.low - centroid
            let yb = wall.high - centroid
            secondMoment += wall.area * (ya * ya + ya * yb + yb * yb) / 3
        }
        // The plastic axis halves the area; the modulus is the first moment of each half about it.
        func areaBelow(_ level: Double) -> Double {
            var sum = 0.0
            for wall in walls {
                let low = min(wall.low, wall.high)
                let high = max(wall.low, wall.high)
                if high <= low {
                    sum += low <= level ? wall.area : 0
                } else {
                    sum += wall.area * min(max((level - low) / (high - low), 0), 1)
                }
            }
            return sum
        }
        var low = 0.0
        var high = Double(depth)
        for _ in 0..<60 {
            let mid = 0.5 * (low + high)
            if areaBelow(mid) < area / 2 { low = mid } else { high = mid }
        }
        let axis = 0.5 * (low + high)
        var plasticModulus = 0.0
        for wall in walls {
            // |y - axis| averaged along the wall, which may cross the axis.
            let ya = wall.low - axis
            let yb = wall.high - axis
            if ya * yb >= 0 {
                plasticModulus += wall.area * 0.5 * abs(ya + yb)
            } else {
                let share = abs(ya) / (abs(ya) + abs(yb))
                plasticModulus += wall.area * 0.5 * (share * abs(ya) + (1 - share) * abs(yb))
            }
        }
        return (area, centroid, secondMoment, plasticModulus)
    }

    /// Per metre width: area (m²/m), second moment (m⁴/m) and the modulus that bending strength
    /// takes, the maker's effective one where given, else the plastic one (m³/m).
    public var perWidth: (area: Float, secondMoment: Float, strengthModulus: Float) {
        let s = section
        let p = Double(pitch)
        return (
            Float(s.area / p), Float(s.secondMoment / p), effectiveModulus ?? Float(s.plasticModulus / p)
        )
    }
}

/// A profiled metal sheet as the shell model meshes it: a skin, a plate as thick as the profile
/// is deep, which closes the surface to the air and carries a small share of the sheet, and the
/// ribs as beams on the skin's midsurface along the span, one on every line of the mesh across
/// the sheet from edge to edge, each standing for an equal share of its ribs. Ribs and skin are of steel
/// scaled so that together they bend as stiffly and as strongly along the span as the profile and
/// weigh as much (as `SteelSection.equivalent` does for rolled sections). Across the span the
/// sheet is held together only by the skin, as a corrugated sheet is nearly free to open there.
/// Approximations: the ribs' axial stiffness is about twice the profile's (a rectangle as deep as
/// the profile with its bending stiffness), the profile bends alike both ways, and local buckling
/// of its walls is not modelled beyond the maker's effective modulus.
public struct ProfiledSheet: Sendable, Hashable {
    public var profile: SheetProfile
    /// The sheet's region: its midsurface is the box's middle along its thinnest axis, its extent
    /// the box's along the other two.
    public var region: Box
    /// The axis the ribs run along, which the sheet spans.
    public var span: Int
    /// Steel's stiffness, density, hardening and failure strain; the yield is the profile's.
    public var steel: StructureMaterial
    /// The skin's share of the sheet's stiffness, strength and mass.
    public var skinShare: Float

    public init(
        profile: SheetProfile, region: Box, span: Int, steel: StructureMaterial = .structuralSteel,
        skinShare: Float = 0.05
    ) {
        self.profile = profile
        self.region = region
        self.span = span
        self.steel = steel
        self.skinShare = skinShare
    }

    /// The axis normal to the sheet.
    public var normal: Int {
        let size = region.size
        return (0..<3).min { size[$0] < size[$1] } ?? 0
    }

    /// The axis across the ribs.
    public var across: Int { 3 - normal - span }

    /// The rib lines across the sheet for a mesh of `elementSize`: their positions, on lines of
    /// the mesh from edge to edge, and the width each stands for, the sheet's shared alike.
    public func ribLines(elementSize: Float) -> [(position: Float, width: Float)] {
        let (low, high) = (region.min[across], region.max[across])
        let count = max(1, Int(((high - low) / elementSize).rounded()))
        let spacing = (high - low) / Float(count)
        return (0...count).map { n in (low + Float(n) * spacing, (high - low) / Float(count + 1)) }
    }

    /// Scales `steel` to stand for `share` of a strip of the profile `strip` wide in a rectangle
    /// `width` by the profile's depth: as stiff and strong in bending along the span, as heavy.
    func scaled(_ name: String, share: Float, strip: Float, width: Float) -> StructureMaterial {
        let (area, secondMoment, modulus) = profile.perWidth
        let depth = profile.depth
        let stiffness = share * secondMoment * strip / (width * depth * depth * depth / 12)
        var material = steel
        material.name = name
        material.youngsModulus = steel.youngsModulus * stiffness
        material.hardeningModulus = steel.hardeningModulus * stiffness
        material.density = steel.density * share * area * strip / (width * depth)
        material.yieldStress = profile.yieldStress * share * modulus * strip / (width * depth * depth / 4)
        return material
    }

    /// The skin's material: a plate as thick as the profile is deep, a metre of which stands for
    /// `skinShare` of a metre of the sheet.
    public var skinMaterial: StructureMaterial {
        scaled("\(profile.name), skin", share: skinShare, strip: 1, width: 1)
    }

    /// The ribs' material for a mesh of `elementSize`, in beams of square section as wide as the
    /// profile is deep (so that the mesher takes them for beams, not plates).
    public func ribMaterial(elementSize: Float) -> StructureMaterial {
        let strip = ribLines(elementSize: elementSize).first?.width ?? 1
        return scaled("\(profile.name), ribs", share: 1 - skinShare, strip: strip, width: profile.depth)
    }

    /// Adds the skin and the rib beams to `model`, meshed as shells, and returns their indices
    /// in `model.solids`, the skin first.
    @discardableResult
    public func add(to model: inout StructureModel) -> [Int] {
        model.solids.append(region)
        return build(in: &model, at: model.solids.count - 1)
    }

    /// Builds the sheet in `model` from solid `index`, its region: that solid becomes the skin
    /// and the ribs are appended. Returns their indices, the skin first.
    @discardableResult
    func build(in model: inout StructureModel, at index: Int) -> [Int] {
        let size = model.shellElementSize ?? model.elementSize
        let mid = 0.5 * (region.min[normal] + region.max[normal])
        let half = profile.depth / 2
        var skin = region
        skin.min[normal] = mid - half
        skin.max[normal] = mid + half
        model.solids[index] = skin
        model.setMaterial(skinMaterial, of: index)
        model.setElementKind(.shell, of: index)
        var added = [index]
        func append(_ box: Box, _ material: StructureMaterial) {
            model.solids.append(box)
            let index = model.solids.count - 1
            model.setMaterial(material, of: index)
            model.setElementKind(.shell, of: index)
            added.append(index)
        }
        let ribs = ribMaterial(elementSize: size)
        let lines = ribLines(elementSize: size)
        let width = profile.depth
        for (n, line) in lines.enumerated() {
            // Inside the sheet at its edges; on the mesh's line all the same.
            let a =
                n == 0
                ? line.position : n == lines.count - 1 ? line.position - width : line.position - width / 2
            var box = skin
            box.min[across] = a
            box.max[across] = a + width
            append(box, ribs)
        }
        return added
    }
}

/// A solid made a profiled sheet (`StructureModel.solidSheets`): its profile, and the axis its
/// ribs run along, which it spans.
public struct SheetAssignment: Codable, Hashable, Sendable {
    public var profile: SheetProfile
    public var ribAxis: Int

    public init(profile: SheetProfile, ribAxis: Int) {
        self.profile = profile
        self.ribAxis = ribAxis
    }

    /// `profile` on `box` with its ribs as cladding and roofs usually run: up a wall (spanning
    /// between horizontal rails), and along a roof's longer side.
    public init(profile: SheetProfile, on box: Box) {
        let size = box.size
        let normal = (0..<3).min { size[$0] < size[$1] } ?? 2
        let inPlane = (0..<3).filter { $0 != normal }
        self.init(
            profile: profile,
            ribAxis: normal == 2 ? (size[inPlane[0]] >= size[inPlane[1]] ? inPlane[0] : inPlane[1]) : 2)
    }
}
