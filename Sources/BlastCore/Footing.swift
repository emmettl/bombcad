import Foundation
import simd

/// Soil as an elastic solid: its small-strain shear modulus, Poisson's ratio and density.
public struct SoilMaterial: Sendable, Hashable, Codable {
    /// Pa.
    public var shearModulus: Float
    public var poissonRatio: Float
    /// kg/m³.
    public var density: Float

    public init(shearModulus: Float, poissonRatio: Float, density: Float) {
        self.shearModulus = shearModulus
        self.poissonRatio = poissonRatio
        self.density = density
    }

    /// A medium dense sand: a shear wave speed of about 145 m/s, ν = 0.3 and 1,900 kg/m³, within
    /// the ranges foundation texts give for such a sand, written from memory and not measured
    /// for any site.
    public static let mediumDenseSand = Self(shearModulus: 40e6, poissonRatio: 0.3, density: 1900)

    /// A soft rock under a layer of soil: 2 GPa, ν = 0.25, 2,400 kg/m³ (about 900 m/s).
    public static let softRock = Self(shearModulus: 2e9, poissonRatio: 0.25, density: 2400)

    public var shearWaveSpeed: Float { (shearModulus / density).squareRoot() }

    /// The speed of the waves that carry a footing's vertical and rocking motion away in Wolf's
    /// cones: the dilatational speed up to ν = 1/3, and twice the shear speed beyond, where the
    /// dilatational speed grows without bound and the trapped mass stands in for the rest.
    public var coneWaveSpeed: Float {
        let nu = poissonRatio
        if nu <= 1 / 3 { return shearWaveSpeed * (2 * (1 - nu) / (1 - 2 * nu)).squareRoot() }
        return 2 * shearWaveSpeed
    }

    func validate() throws {
        guard shearModulus.isFinite, shearModulus > 0, density.isFinite, density > 0,
            poissonRatio.isFinite, poissonRatio >= 0, poissonRatio < 0.5
        else {
            throw ImportedMesh.ImportError.invalid(
                "Soil needs a positive shear modulus and density, and Poisson's ratio from 0 to below 0.5.")
        }
    }
}

/// The ground under a footing: an elastic half-space, or a layer of it over another (or over
/// rock), that bears in compression only, yields past its bearing capacity and lets the footing
/// slide on it with Coulomb friction.
public struct Soil: Sendable, Hashable, Codable {
    public var material: SoilMaterial
    /// Pressure in Pa the soil bears before it yields and the footing settles for good; nil
    /// bears any.
    public var bearingCapacity: Float?
    public var friction: Float
    /// The soil's own mass and the waves that carry energy away into it (Wolf's cones). Without
    /// them the soil is massless springs, damped only as contacts are.
    public var radiationDamping: Bool
    /// The soil above as a layer this deep, in metres, over `beneath`; nil for a half-space.
    public var layerDepth: Float?
    /// What lies under the layer; nil for rock that does not move.
    public var beneath: SoilMaterial?
    /// Sand that compresses for good when pressed past the most it has borne (`CyclicSand`), by
    /// default; nil for a bed elastic up to its bearing capacity (as documents saved before it
    /// came in keep).
    public var cyclic: CyclicSand?

    public init(
        material: SoilMaterial = .mediumDenseSand, bearingCapacity: Float? = 600e3, friction: Float = 0.5,
        radiationDamping: Bool = true, layerDepth: Float? = nil, beneath: SoilMaterial? = nil,
        cyclic: CyclicSand? = CyclicSand()
    ) {
        self.cyclic = cyclic
        self.material = material
        self.bearingCapacity = bearingCapacity
        self.friction = friction
        self.radiationDamping = radiationDamping
        self.layerDepth = layerDepth
        self.beneath = beneath
    }

    /// The displacement reflection coefficient of a wave going down through the layer at its
    /// base, from the two materials' impedances ρ c (−1 at rock): (Z₁ − Z₂) / (Z₁ + Z₂).
    func reflection(shear: Bool) -> Float {
        guard layerDepth != nil else { return 0 }
        guard let beneath else { return -1 }
        func impedance(_ m: SoilMaterial) -> Float {
            m.density * (shear ? m.shearWaveSpeed : m.coneWaveSpeed)
        }
        let top = impedance(material)
        let bottom = impedance(beneath)
        return (top - bottom) / (top + bottom)
    }

    func validate() throws {
        try material.validate()
        try beneath?.validate()
        try cyclic?.validate()
        guard friction.isFinite, friction >= 0, (bearingCapacity ?? 1).isFinite, (bearingCapacity ?? 1) > 0,
            (layerDepth ?? 1).isFinite, (layerDepth ?? 1) > 0
        else {
            throw ImportedMesh.ImportError.invalid(
                "Soil friction must be nonnegative, and its bearing capacity and layer depth positive.")
        }
    }
}

/// Sand under a footing's bed that settles under cycles of load well below its bearing capacity,
/// as S. Gajan's contact interface model has it ("Physical and numerical modeling of nonlinear
/// cyclic load-deformation behavior of shallow foundations supporting rocking shear walls", PhD
/// dissertation, UC Davis, 2006, §6.5; S. Gajan and B. L. Kutter, J. Geotech. Geoenviron. Eng.
/// 135(3), 2009).
///
/// Each point of the bed, pressed past the largest force it has borne, is as stiff as the
/// elastic bed, but gives back only `elasticShare` of that compression when unloaded: the rest
/// is settlement (Gajan's model gives back none). Below that force it unloads and reloads
/// elastically, `1 / elasticShare` times as stiff. Unloaded to nothing, it keeps `memory` of the
/// force (Gajan's bearing pressure falls to nothing where the footing lifts, and builds again
/// only as the footing presses deeper). Lifted clear of the soil, further than the soil springs
/// back, the soil heaves back by `heave` of how far it has been pressed down, times 1 − 1/FS for
/// the footing's static factor of safety (Gajan's rebounding ratio, Rv = Rv₀ (1 − 1/FS),
/// Rv₀ = 0.1 for all his tests), loosened: the point forgets the force.
///
/// The defaults: no memory, as Gajan's; for the share given back, his vertical push on the Nevada
/// sand at 80% relative density, which first loaded it at about 11 MN/m³ and unloaded and
/// reloaded it at 80–100 (§4.2, Figs. 4.1–4.3), about an eighth; and no heave. In his model the
/// heave raises only a second surface, which bears weakly; here it raises the one surface the
/// point bears on, and any Rv₀ from 0.01 to 0.1 stopped a footing rocked slowly settling after
/// its first packet of cycles (docs/validation.md#a-footing-shaken-on-dry-sand).
public struct CyclicSand: Sendable, Hashable, Codable {
    public var elasticShare: Float
    public var memory: Float
    public var heave: Float

    public init(elasticShare: Float = 0.12, memory: Float = 0, heave: Float = 0) {
        self.elasticShare = elasticShare
        self.memory = memory
        self.heave = heave
    }

    func validate() throws {
        guard elasticShare.isFinite, elasticShare > 0, elasticShare <= 1, (0...1).contains(memory),
            (0...1).contains(heave)
        else {
            throw ImportedMesh.ImportError.invalid(
                "Cyclic sand gives back more than none and no more than all of a first loading, and its "
                    + "memory and heave are from 0 to 1.")
        }
    }
}

/// A rigid footing under a body's base, of finite plan, with its own mass, standing on soil.
///
/// The connection it belongs to (`Anchorage.footing`) ties the body to the footing's top, which
/// moves and turns with it; the footing bears on the soil over its plan alone, so that its heel
/// lifts and its contact shifts towards the toe as it turns, and it can slide, settle and tip
/// over. Its plan is the box round the base points that share the connection, widened by
/// `overhang` on each side.
public struct Footing: Sendable, Hashable, Codable {
    /// How far the footing reaches beyond the base on each side, along x and along y, in metres.
    public var overhang: SIMD2<Float>
    /// Metres.
    public var thickness: Float
    /// kg/m³.
    public var density: Float
    public var soil: Soil
    /// How deep the footing is set into the soil, which then bears against its sides; nil for a
    /// footing on the surface.
    public var embedment: Embedment?

    public init(
        overhang: SIMD2<Float> = SIMD2(0.5, 0.5), thickness: Float = 0.4, density: Float = 2400,
        soil: Soil = Soil(), embedment: Embedment? = nil
    ) {
        self.embedment = embedment
        self.overhang = overhang
        self.thickness = thickness
        self.density = density
        self.soil = soil
    }

    func validate() throws {
        try soil.validate()
        try embedment?.validate()
        guard overhang.x.isFinite, overhang.y.isFinite, overhang.x >= 0, overhang.y >= 0,
            thickness.isFinite, thickness > 0, density.isFinite, density > 0
        else {
            throw ImportedMesh.ImportError.invalid(
                "A footing needs a nonnegative overhang and a positive thickness and density.")
        }
    }
}

/// A footing set into the soil: its base `depth` below the surface, the soil against its sides
/// over the footing's thickness or the depth, whichever is less.
///
/// The soil against a side starts at rest, its pressure at depth z K₀ γ z (J. Jáky's K₀ = 1 − sin φ,
/// the same on opposite sides, so that it pushes the footing nowhere), and bears on the side as a
/// spring until it reaches the passive pressure Kₚ γ z, past which it gives way for good, or
/// falls to the active Kₐ γ z as the side moves away, past which it follows the side (W. J. M.
/// Rankine's Kₚ = tan²(45° + φ/2) and Kₐ = tan²(45° − φ/2)). Along the side the soil grips by
/// friction on that pressure. The springs are set so that the footing's static stiffness,
/// vertically and horizontally, is G. Gazetas's for an embedded rigid rectangle ("Formulas and
/// charts for impedances of surface and embedded foundations", *J. Geotech. Eng.* 117(9),
/// 1991; tabulated again by G. Mylonakis, S. Nikolaou and G. Gazetas, "Footings under seismic
/// loading", *Soil Dyn. Earthq. Eng.* 26, 2006), written from memory: the base made stiffer by
/// its depth (the trench factor) and the sides adding the rest (the sidewall factor). Its
/// rocking stiffness then follows, and is compared with Gazetas's. The base bears more, by the
/// weight of soil beside it: the bearing capacity of the surface footing plus γ D N_q s_q d_q,
/// N_q = e^(π tan φ) tan²(45° + φ/2), s_q = 1 + (B/L) tan φ (E. E. De Beer) and
/// d_q = 1 + 2 tan φ (1 − sin φ)² D/B (J. Brinch Hansen, 1970; arctan(D/B) for D past B).
public struct Embedment: Sendable, Hashable, Codable {
    /// Metres from the surface down to the footing's base.
    public var depth: Float
    /// The soil's angle of internal friction, radians: its pressures on the sides and the
    /// overburden's share of its bearing capacity. 35° by default, a medium dense sand's.
    public var frictionAngle: Float
    /// Friction between the sides and the soil; nil for tan(2φ/3), as for cast concrete.
    public var sideFriction: Float?

    public init(depth: Float = 1, frictionAngle: Float = 35 * .pi / 180, sideFriction: Float? = nil) {
        self.depth = depth
        self.frictionAngle = frictionAngle
        self.sideFriction = sideFriction
    }

    func validate() throws {
        guard depth.isFinite, depth > 0, frictionAngle.isFinite, frictionAngle > 0, frictionAngle < .pi / 2,
            (sideFriction ?? 0).isFinite, (sideFriction ?? 0) >= 0
        else {
            throw ImportedMesh.ImportError.invalid(
                "An embedded footing needs a positive depth, a friction angle between 0° and 90° and nonnegative side friction."
            )
        }
    }

    /// The friction between the sides and the soil.
    public var wallFriction: Float { sideFriction ?? tan(2 * frictionAngle / 3) }

    /// Jáky's, Rankine's active and passive coefficients of earth pressure.
    public var atRest: Float { 1 - sin(frictionAngle) }
    public var active: Float { pow(tan(.pi / 4 - frictionAngle / 2), 2) }
    public var passive: Float { pow(tan(.pi / 4 + frictionAngle / 2), 2) }

    /// The height of the sides in contact with the soil, for a footing `thickness` deep.
    public func contactHeight(thickness: Float) -> Float { min(depth, thickness) }

    /// Gazetas's factors on a surface footing's static stiffness for one `width` along x by
    /// `length` along y and `thickness` deep, embedded so: the trench factor (the base deeper) and
    /// the sidewall factor, by `FootingImpedance.Mode`. (Rocking has one factor, given as the
    /// sidewall's.)
    public func gazetasFactors(width: Float, length: Float, thickness: Float) -> (
        trench: [Float], sidewall: [Float]
    ) {
        let alongY = length >= width
        let l = max(width, length) / 2
        let b = min(width, length) / 2
        let chi = b / l
        let d = contactHeight(thickness: thickness)
        let big = depth
        let wall = 4 * (b + l) * d  // sidewall in contact
        let base = 4 * b * l
        let centroid = big - d / 2  // the depth of the sidewall's centroid
        let vertical = (1 + big / (21 * b) * (1 + 1.3 * chi), 1 + 0.2 * pow(wall / base, 2 / 3))
        let trench = 1 + 0.15 * (big / b).squareRoot()
        let across = 1 + 0.52 * pow(centroid * wall / (b * l * l), 0.4)  // Gazetas's y, across the long side
        let along = 1 + 0.52 * pow(centroid * wall / (l * b * b), 0.4)  // his x, along it
        let rockLong = 1 + 1.26 * d / b * (1 + d / b * pow(d / big, -0.2) * (b / l).squareRoot())
        let rockShort = 1 + 0.92 * pow(d / l, 0.6) * (1.5 + pow(d / l, 1.9) * pow(d / big, -0.6))
        // Our x and y, as `FootingImpedance.gazetas`.
        let sidewall: [Float] =
            alongY
            ? [vertical.1, across, along, rockShort, rockLong]
            : [vertical.1, along, across, rockLong, rockShort]
        return ([vertical.0, trench, trench, 1, 1], sidewall)
    }

    /// The ultimate bearing pressure under the base: the surface footing's `surface` plus the
    /// overburden's γ D N_q s_q d_q, for a footing `width` by `length` on `material`.
    public func bearingCapacity(surface: Float, width: Float, length: Float, material: SoilMaterial) -> Float
    {
        let phi = frictionAngle
        let b = min(width, length)
        let l = max(width, length)
        let nq = exp(.pi * tan(phi)) * pow(tan(.pi / 4 + phi / 2), 2)
        let shape = 1 + b / l * tan(phi)
        let ratio = depth <= b ? depth / b : atan(depth / b)
        let deep = 1 + 2 * tan(phi) * pow(1 - sin(phi), 2) * ratio
        return surface + material.density * 9.81 * depth * nq * shape * deep
    }
}

/// A complex number, for the soil's dynamic stiffness.
public struct Complex: Sendable, Equatable {
    public var real: Double
    public var imaginary: Double

    public init(_ real: Double, _ imaginary: Double = 0) {
        self.real = real
        self.imaginary = imaginary
    }

    public var magnitude: Double { (real * real + imaginary * imaginary).squareRoot() }
    public var phase: Double { atan2(imaginary, real) }

    static func + (a: Self, b: Self) -> Self { Self(a.real + b.real, a.imaginary + b.imaginary) }
    static func - (a: Self, b: Self) -> Self { Self(a.real - b.real, a.imaginary - b.imaginary) }
    static func * (a: Self, b: Self) -> Self {
        Self(a.real * b.real - a.imaginary * b.imaginary, a.real * b.imaginary + a.imaginary * b.real)
    }
    static func / (a: Self, b: Self) -> Self {
        let d = b.real * b.real + b.imaginary * b.imaginary
        return Self(
            (a.real * b.real + a.imaginary * b.imaginary) / d,
            (a.imaginary * b.real - a.real * b.imaginary) / d)
    }
}

/// A rigid rectangular footing's impedance on its soil, for small motions about the centre of
/// its base, in full contact.
///
/// The static stiffnesses are G. Gazetas's for a rigid rectangle on a half-space ("Formulas and
/// charts for impedances of surface and embedded foundations", *J. Geotech. Eng.* 117(9),
/// 1991), written from memory: within 1% of the rigid disk's for a square in translation and
/// 9% in rocking. The dynamic terms are J. P. Wolf's cones (*Foundation Vibration Analysis Using
/// Simple Physical Models*, 1994), each fitted to its static stiffness: a cone of apex height
/// z₀ = ρ c² A / K (3 ρ c² I / K in rocking) carries waves away at c. In translation it is a
/// spring and a dashpot ρ c A; in rocking a spring, with a dashpot ρ c I to an internal rotary
/// mass ρ I z₀, so that rocking radiates little at low frequency. Past ν = 1/3 a mass is trapped
/// under the footing: 2.4 (ν − 1/3) ρ A r₀ in translation and 1.2 (ν − 1/3) ρ I r₀ in rocking.
///
/// Over a layer, a wave sent down reflects at its base, and each echo returns after a round
/// trip 2 d / c, weakened by the cone's spreading to z₀ / (z₀ + 2 j d) and by the reflection
/// coefficient each time (Wolf's cones with reflections): the footing's displacement is the
/// half-space's, u₀(t) = ũ(t) + 2 Σⱼ Rʲ z₀ / (z₀ + 2 j d) ũ(t − 2 j d / c). That holds in
/// translation. The sum is cut off after 64 echoes, the last third of them tapered away (a raised
/// cosine), and each echo loses 1% more per round trip, as to the soil's own damping: cut off
/// sharply, sooner, or without the loss, the footing gains energy from the soil at some
/// frequencies. Rocking cones echo in the same way only with far
/// too much energy and stiffness, so over a layer a footing rocks on the half-space's cone made
/// stiffer statically by E. Kausel's factor for a stratum on rock, 1 + r / (6 d), scaled by −R
/// for what lies beneath.
public struct FootingImpedance: Sendable {
    /// The modes, in the order of the arrays: vertical, horizontal along x and along y, rocking
    /// about x (turning in the y–z plane) and about y (turning in the x–z plane).
    public enum Mode: Int, CaseIterable, Sendable {
        case vertical, horizontalX, horizontalY, rockingX, rockingY
        var isRocking: Bool { self == .rockingX || self == .rockingY }
        var isShear: Bool { self == .horizontalX || self == .horizontalY }
    }

    public var stiffness: [Float]
    /// Dashpot ρ c A (or ρ c I); zero without radiation.
    public var dashpot: [Float]
    /// The trapped mass (or rotary mass) past ν = 1/3.
    public var trappedMass: [Float]
    /// Wave speed and the cone's apex height per mode.
    public var waveSpeed: [Float]
    public var apex: [Float]
    /// Layer: depth and reflection coefficient per mode (zero for a half-space).
    public var layerDepth: Float?
    public var reflection: [Float]

    /// The impedance of a footing `width` along x and `length` along y on `soil`, with the
    /// static stiffness `stiffness` per mode in place of Gazetas's when given (as a bed of springs
    /// can give it).
    public init(width: Float, length: Float, soil: Soil, stiffness given: [Float]? = nil) {
        let m = soil.material
        let nu = m.poissonRatio
        let rho = m.density
        let rockingFactor: Float = {
            guard let d = soil.layerDepth else { return 1 }
            return 1 - soil.reflection(shear: false) * Self.rockingRadius(width, length) / (6 * d)
        }()
        stiffness =
            given
            ?? Self.gazetas(width: width, length: length, material: m).enumerated().map {
                Mode(rawValue: $0.offset)!.isRocking ? $0.element * rockingFactor : $0.element
            }
        let area = width * length
        let inertia = [0, 0, 0, width * length * length * length / 12, length * width * width * width / 12]
        let cs = m.shearWaveSpeed
        let cv = m.coneWaveSpeed
        waveSpeed = Mode.allCases.map { $0.isShear ? cs : cv }
        let trapped = max(nu - 1 / 3, 0)
        let radius = (area / .pi).squareRoot()
        dashpot = []
        apex = []
        trappedMass = []
        for mode in Mode.allCases {
            let c = waveSpeed[mode.rawValue]
            let k = stiffness[mode.rawValue]
            if mode.isRocking {
                let i = inertia[mode.rawValue]
                let rockingRadius = (4 * i / .pi).squareRoot().squareRoot()
                dashpot.append(soil.radiationDamping ? rho * c * i : 0)
                apex.append(3 * rho * c * c * i / k)
                trappedMass.append(soil.radiationDamping ? 1.2 * trapped * rho * i * rockingRadius : 0)
            } else {
                dashpot.append(soil.radiationDamping ? rho * c * area : 0)
                apex.append(rho * c * c * area / k)
                trappedMass.append(
                    soil.radiationDamping && mode == .vertical ? 2.4 * trapped * rho * area * radius : 0)
            }
        }
        layerDepth = soil.layerDepth
        reflection = Mode.allCases.map { soil.reflection(shear: $0.isShear) }
    }

    /// The disk turning as stiffly as the footing on average about x and y: (4 I / π)^(1/4).
    static func rockingRadius(_ width: Float, _ length: Float) -> Float {
        let inertia = (width * length * length * length + length * width * width * width) / 24
        return (4 * inertia / .pi).squareRoot().squareRoot()
    }

    /// Gazetas's static stiffnesses for a rigid rectangle `width` along x by `length` along y.
    static func gazetas(width: Float, length: Float, material m: SoilMaterial) -> [Float] {
        let shear = m.shearModulus
        let nu = m.poissonRatio
        // Gazetas's plan is 2L by 2B, L ≥ B, his x along L: here l and b.
        let alongY = length >= width
        let l = max(width, length) / 2
        let b = min(width, length) / 2
        let chi = 4 * b * l / (4 * l * l)
        let vertical = 2 * shear * l / (1 - nu) * (0.73 + 1.54 * pow(chi, 0.75))
        let across = 2 * shear * l / (2 - nu) * (2 + 2.5 * pow(chi, 0.85))  // across the long side
        let along = across - 0.2 / (0.75 - nu) * shear * l * (1 - b / l)
        let aboutLong = 2 * l * pow(2 * b, 3) / 12  // second moment about the long axis
        let aboutShort = 2 * b * pow(2 * l, 3) / 12
        let rockLong = shear / (1 - nu) * pow(aboutLong, 0.75) * pow(l / b, 0.25) * (2.4 + 0.5 * b / l)
        let rockShort = 3 * shear / (1 - nu) * pow(aboutShort, 0.75) * pow(l / b, 0.15)
        // Our x and y: rocking about x turns in the y–z plane.
        return alongY
            ? [vertical, across, along, rockShort, rockLong]
            : [vertical, along, across, rockLong, rockShort]
    }

    /// The reflections kept over a layer, 64; none in rocking. A layer on rock is stiffer than the
    /// half-space by a sum of echoes of alternating sign, and the soil takes energy from the
    /// footing at low frequency only by a margin that the whole sum, smoothly ended, keeps: with
    /// fewer echoes it gives the footing energy instead.
    func reflections(_ mode: Mode) -> Int {
        guard layerDepth != nil, reflection[mode.rawValue] != 0, !mode.isRocking else { return 0 }
        return 64
    }

    /// The echoes' weights 2 Rʲ z₀ / (z₀ + 2 j d) 0.99ʲ, j = 1...n, the last third tapered away.
    func echoes(_ mode: Mode) -> [Float] {
        let n = reflections(mode)
        guard n > 0, let d = layerDepth else { return [] }
        let r = reflection[mode.rawValue]
        let z0 = apex[mode.rawValue]
        let tapered = n / 3
        return (1...n).map { j in
            let taper =
                j > n - tapered
                ? 0.5 * (1 + cos(Float.pi * Float(j - (n - tapered)) / Float(tapered + 1))) : 1
            return 2 * pow(r * 0.99, Float(j)) * z0 / (z0 + 2 * Float(j) * d) * taper
        }
    }

    /// The half-space cone's dynamic stiffness at ω rad/s (trapped mass included), Wolf's closed
    /// form: K + i ω C in translation, K [1 − b²/(3 (1 + b²))] + i ω C b²/(1 + b²) in rocking,
    /// b = ω z₀ / c.
    public func halfSpace(_ mode: Mode, omega omega: Double) -> Complex {
        let k = Double(stiffness[mode.rawValue])
        let c = Double(dashpot[mode.rawValue])
        let mass = Double(trappedMass[mode.rawValue])
        guard mode.isRocking else { return Complex(k - omega * omega * mass, omega * c) }
        guard c > 0 else { return Complex(k) }
        let b = omega * Double(apex[mode.rawValue]) / Double(waveSpeed[mode.rawValue])
        let f = b * b / (1 + b * b)
        return Complex(k * (1 - f / 3) - omega * omega * mass, omega * c * f)
    }

    /// The dynamic stiffness at ω, over the layer when there is one: the half-space's divided by
    /// 1 + 2 Σⱼ Rʲ z₀ / (z₀ + 2 j d) e^(−i ω j T), T = 2 d / c (the trapped mass outside it).
    public func dynamicStiffness(_ mode: Mode, omega omega: Double) -> Complex {
        let mass = Double(trappedMass[mode.rawValue])
        let cone = halfSpace(mode, omega: omega) + Complex(omega * omega * mass)
        let weights = echoes(mode)
        guard !weights.isEmpty, let d = layerDepth else { return cone - Complex(omega * omega * mass) }
        let period = 2 * Double(d) / Double(waveSpeed[mode.rawValue])
        var flexibility = Complex(1)
        for (j, w) in weights.enumerated() {
            let angle = -omega * Double(j + 1) * period
            flexibility = flexibility + Complex(Double(w) * cos(angle), Double(w) * sin(angle))
        }
        return cone / flexibility - Complex(omega * omega * mass)
    }

    /// The static stiffness, over the layer when there is one.
    public func staticStiffness(_ mode: Mode) -> Float {
        stiffness[mode.rawValue] / (1 + echoes(mode).reduce(0, +))
    }
}
