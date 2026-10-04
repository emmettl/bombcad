import Foundation
import Metal
import simd

public enum MaterialModel: UInt32, Sendable, Codable {
    /// Elastic-plastic with a single yield stress and a plastic-strain failure limit.
    case vonMises = 0
    /// Concrete that cracks in tension and crushes in compression, with optional reinforcement.
    case concrete = 1
}

/// Reinforcing steel: elastic, then hardening linearly from yield to ultimate, then a plateau
/// until it ruptures.
public struct SteelProperties: Sendable, Hashable, Codable {
    /// Pa
    public var youngsModulus: Float = 200e9
    public var yieldStress: Float
    public var ultimateStress: Float
    /// Plastic strain at which the ultimate stress is reached.
    public var ultimateStrain: Float
    /// Plastic strain at which the bar breaks.
    public var ruptureStrain: Float
    /// A measured hardening curve as (plastic strain, stress) points, used in place of the
    /// straight line from yield to ultimate. At most eight points; the bar breaks at the last.
    public var measuredCurve: [SIMD2<Float>]?

    public init(yieldStress: Float, ultimateStress: Float, ultimateStrain: Float, ruptureStrain: Float) {
        self.yieldStress = yieldStress
        self.ultimateStress = ultimateStress
        self.ultimateStrain = ultimateStrain
        self.ruptureStrain = ruptureStrain
    }

    /// The hardening curve as (plastic strain, stress) points.
    public var curve: [SIMD2<Float>] {
        if let measuredCurve { return Array(measuredCurve.prefix(8)) }
        return [
            SIMD2(0, yieldStress), SIMD2(ultimateStrain, max(ultimateStress, yieldStress)),
            SIMD2(max(ruptureStrain, ultimateStrain * 1.001), max(ultimateStress, yieldStress)),
        ]
    }

    /// Typical ribbed bar with a 500 MPa characteristic yield.
    public static let grade500 = SteelProperties(
        yieldStress: 500e6, ultimateStress: 575e6, ultimateStrain: 0.075, ruptureStrain: 0.12)
}

/// Material of a deformable structure.
///
/// The concrete model works on total strain, with cracks smeared over the three lattice planes.
/// Across each plane the normal stress follows a uniaxial curve (exponential softening in
/// tension, a parabola then linear softening in compression), with the softening scaled so that
/// the energy to open a crack or crush a band does not depend on the mesh. Shear across a
/// cracked plane is carried by aggregate interlock, which weakens as the crack widens.
/// Reinforcement is smeared into the elements it passes through.
public struct StructureMaterial: Sendable, Hashable, Codable {
    public var name: String
    public var model: MaterialModel
    /// kg/m³
    public var density: Float
    /// Pa
    public var youngsModulus: Float
    public var poissonRatio: Float

    // Von Mises model.
    /// Uniaxial yield stress in Pa.
    public var yieldStress: Float = 1e30
    /// Slope of the stress against plastic strain after yield, in Pa.
    public var hardeningModulus: Float = 0
    /// Equivalent plastic strain at which an element is removed.
    public var failureStrain: Float = 1e30

    // Concrete model.
    /// Uniaxial compressive strength in Pa.
    public var compressiveStrength: Float = 0
    /// Uniaxial tensile strength in Pa.
    public var tensileStrength: Float = 0
    /// Energy to open a unit area of crack, in J/m².
    public var fractureEnergy: Float = 0
    /// Energy to crush a unit area of band, in J/m².
    public var crushingEnergy: Float = 0
    /// Crack width, in metres, at which an element with no intact steel across the crack is
    /// removed. Well before this the crack carries no tension; removal only matters for letting
    /// pieces separate, so it is deliberately late: a cracked element still resists compression.
    public var erosionOpening: Float = 0.005
    /// Properties of the reinforcement, or nil to ignore any reinforcement in the model.
    public var steel: SteelProperties?
    /// Typical distance between cracks in a reinforced member, in metres. Plain concrete forms
    /// one crack, whose energy is spread over one element; bars force a crack every so often,
    /// so in reinforced concrete the energy is spread over this distance instead (when it is
    /// larger than an element), which keeps the response independent of the mesh.
    public var crackSpacing: Float = 0.1
    /// Shortest length, in metres, over which crushing is taken to spread. Zero spreads it over
    /// one element.
    public var crushBand: Float = 0
    /// Radius, in metres, over which crushing is averaged before it softens the concrete
    /// (nonlocal crushing). Zero, the default, or less than half an element keeps it local;
    /// three aggregate sizes (48 mm) is the usual choice when it is wanted.
    public var crushLength: Float = 0
    /// Judge a bar's rupture by its plastic strain averaged over a debonded length (the crack
    /// spacing) rather than in the one element a crack runs through.
    public var bondSpreading = true
    /// Gain in compressive strength per unit of lateral confining stress (Richart's 4.1).
    public var confinementCoefficient: Float = 4.1
    /// Largest aggregate size in metres, which governs how well a crack still carries shear.
    public var aggregateSize: Float = 0.016
    /// Fraction of a crack's inelastic opening that remains when the tension across it is
    /// released, because fragments and misfit stop the faces closing completely.
    public var crackResidual: Float = 0.1
    /// Fixed multipliers on strength, such as the design dynamic increase factors of
    /// UFC 3-340-02. They apply on top of `rateDependent`, so normally use one or the other.
    public var concreteRateFactor: Float = 1
    public var steelRateFactor: Float = 1
    /// Raise strength with the local strain rate: CEB-FIP 1990 for concrete in compression,
    /// Malvar and Ross (1998) in tension, Malvar and Crawford (1998) for reinforcement.
    public var rateDependent = false

    /// A von Mises material.
    public init(
        name: String, density: Float, youngsModulus: Float, poissonRatio: Float, yieldStress: Float,
        hardeningModulus: Float = 0, failureStrain: Float
    ) {
        self.name = name
        self.model = .vonMises
        self.density = density
        self.youngsModulus = youngsModulus
        self.poissonRatio = poissonRatio
        self.yieldStress = yieldStress
        self.hardeningModulus = hardeningModulus
        self.failureStrain = failureStrain
    }

    /// A material that never yields or fails.
    public static func elastic(density: Float, youngsModulus: Float, poissonRatio: Float) -> Self {
        Self(
            name: "Elastic", density: density, youngsModulus: youngsModulus, poissonRatio: poissonRatio,
            yieldStress: 1e30, failureStrain: 1e30)
    }

    /// Concrete of the given compressive strength (Pa), with its other properties taken from
    /// standard correlations: E = 4700 sqrt(fc) MPa (ACI 318), ft = 0.3 fc^(2/3) MPa (Eurocode 2)
    /// and Gf = 73 fc^0.18 N/m (fib Model Code 2010), with a crushing energy of 250 Gf.
    public static func concrete(
        name: String, compressiveStrength: Float, density: Float = 2400, steel: SteelProperties? = nil
    ) -> Self {
        let megapascals = compressiveStrength / 1e6
        var material = Self(
            name: name, density: density, youngsModulus: 4700e6 * megapascals.squareRoot(), poissonRatio: 0.2,
            yieldStress: 1e30, failureStrain: 1e30)
        material.model = .concrete
        material.compressiveStrength = compressiveStrength
        material.tensileStrength = 0.3e6 * pow(megapascals, 2.0 / 3.0)
        material.fractureEnergy = 73 * pow(megapascals, 0.18)
        material.crushingEnergy = 250 * material.fractureEnergy
        material.steel = steel
        return material
    }

    /// 30 MPa concrete with 500 MPa reinforcement wherever the model specifies it, both
    /// strengthening with strain rate.
    public static let reinforcedConcrete: Self = {
        var material = concrete(name: "Reinforced concrete", compressiveStrength: 30e6, steel: .grade500)
        material.rateDependent = true
        return material
    }()

    /// The same concrete with its reinforcement left out.
    public static let plainConcrete: Self = {
        var material = concrete(name: "Plain concrete", compressiveStrength: 30e6)
        material.rateDependent = true
        return material
    }()

    /// Unreinforced blockwork, treated as a weak, brittle concrete.
    public static let masonry: Self = {
        var material = concrete(name: "Masonry", compressiveStrength: 8e6, density: 1900)
        material.youngsModulus = 6e9
        material.tensileStrength = 0.3e6
        material.fractureEnergy = 20
        material.crushingEnergy = 5000
        material.erosionOpening = 0.003
        return material
    }()

    /// Structural steel, S355: yields at 355 MPa and hardens slowly, failing at 20% strain.
    public static let structuralSteel = Self(
        name: "Structural steel", density: 7850, youngsModulus: 210e9, poissonRatio: 0.3, yieldStress: 355e6,
        hardeningModulus: 1e9, failureStrain: 0.2)

    /// Annealed float glass, as a brittle material: elastic until it cracks at 45 MPa, then
    /// gone after a fraction of a millimetre (its fracture energy, about 8 J/m², is that of
    /// toughness 0.75 MPa m^(1/2)). Meant for panes meshed as shells.
    public static let annealedGlass: Self = {
        var material = concrete(name: "Annealed glass", compressiveStrength: 1000e6, density: 2500)
        material.youngsModulus = 70e9
        material.poissonRatio = 0.22
        material.tensileStrength = 45e6
        material.fractureEnergy = 8
        material.crushingEnergy = 2000
        material.erosionOpening = 0.0005
        material.aggregateSize = 0
        return material
    }()

    public static let presets: [Self] = [
        .reinforcedConcrete, .plainConcrete, .masonry, .structuralSteel, .annealedGlass,
    ]

    public var shearModulus: Float { youngsModulus / (2 * (1 + poissonRatio)) }

    public var lameLambda: Float {
        youngsModulus * poissonRatio / ((1 + poissonRatio) * (1 - 2 * poissonRatio))
    }

    /// Speed of compression waves in the bulk material, which sets the explicit time step.
    public var dilatationalWaveSpeed: Float {
        ((lameLambda + 2 * shearModulus) / density).squareRoot()
    }

    /// Speed of in-plane compression waves in a thin plate, which is in plane stress.
    public var plateWaveSpeed: Float {
        (youngsModulus / (density * (1 - poissonRatio * poissonRatio))).squareRoot()
    }
}

/// The axes concrete cracks across.
public enum CrackAxes: String, Sendable, Hashable, Codable, CaseIterable {
    /// The lattice's planes: an inclined crack is shared between them, each given its full
    /// strain, while interlock on them still carries tension across it.
    case lattice
    /// The principal axes of the strain when the concrete first cracks, kept from then on, so
    /// that an inclined crack opens and slides as one plane; but stress locks across it if the
    /// principal directions turn afterwards.
    case fixedAtFirstCrack
    /// The principal axes, followed while a crack is still forming and fixed once it has
    /// softened through a tenth of its softening strain.
    case turningUntilOpen

    var uniform: UInt32 {
        switch self {
        case .lattice: 0
        case .fixedAtFirstCrack: 1
        case .turningUntilOpen: 2
        }
    }
}

/// How a structure is meshed.
public enum ElementKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// Cubic solid elements on a lattice, several through the thickness of a wall.
    case solid
    /// Four-node shell elements on the midsurfaces of walls and slabs, with layers through the
    /// thickness. Every solid must then be plate-like.
    case shell
}

/// Reinforcement smeared uniformly through a region. `ratio` is steel area per unit area of
/// concrete for bars running along x, y and z.
/// How one solid of a structure is reinforced.
public enum Reinforcement: Sendable, Hashable, Codable {
    /// Worked out from the solid's shape: a mat of bars in each face of a wall or slab (565 mm²
    /// per metre each way, centred 40 mm in), or 2% steel along a column with 0.4% ties.
    case automatic
    /// Plain concrete.
    case none
    /// A mat of bars, the same each way, centred `depth` in from one or both faces of a wall or
    /// slab. With one face, it is the face on the low side of the thin axis.
    case mats(areaPerMetre: Float, depth: Float, bothFaces: Bool)
    /// Steel along the solid's longest dimension and ties across it, as fractions of the area.
    case column(longitudinal: Float, ties: Float)
}

public struct ReinforcementLayer: Sendable, Hashable, Codable {
    public var region: Box
    public var ratio: SIMD3<Float>

    public init(region: Box, ratio: SIMD3<Float>) {
        self.region = region
        self.ratio = ratio
    }
}

/// A layer of straight bars at 45 degrees to two lattice axes, such as the diagonal bars across
/// a chamfered corner. In the plane of those two axes the bars run from `start` along
/// `direction` (which has equal and opposite or equal components along the two axes and none
/// along the third) for `length`; the layer repeats along the third axis over `span`, with
/// `areaPerMetre` of bar per metre along it. It is smeared over the diagonal rows of elements
/// the bars pass through, in proportion to how near each row lies, so that its steel is kept.
/// An element holds one set of inclined bars; where layers of different directions overlap,
/// the larger wins.
public struct InclinedBars: Sendable, Hashable, Codable {
    public var start: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var length: Float
    public var span: ClosedRange<Float>
    public var areaPerMetre: Float

    public init(
        start: SIMD3<Float>, direction: SIMD3<Float>, length: Float, span: ClosedRange<Float>,
        areaPerMetre: Float
    ) {
        self.start = start
        self.direction = direction
        self.length = length
        self.span = span
        self.areaPerMetre = areaPerMetre
    }

    /// The two lattice axes the bars lie between, the third, and the code the element kernel
    /// knows them by (see `ElementSteel` in Structure.metal).
    var axes: (third: Int, code: UInt16)? {
        let magnitude = simd_abs(direction)
        guard let third = (0..<3).first(where: { magnitude[$0] < 1e-6 }) else { return nil }
        let plane = (third + 1) % 3  // the planes are (x, y), (y, z), (z, x): their first axis
        let other = (plane + 1) % 3
        guard abs(magnitude[plane] - magnitude[other]) < 1e-4 * max(magnitude[plane], 1e-6) else {
            return nil
        }
        let backwards = (direction[plane] > 0) != (direction[other] > 0)
        return (third, UInt16(1 + 2 * plane + (backwards ? 1 : 0)))
    }
}

/// A pressure history applied to one outer face of a structure, for running it without the air.
public struct PressureLoad: Sendable, Hashable {
    /// Axis (0, 1, 2 for x, y, z) normal to the loaded faces.
    public var axis: Int
    /// Load the faces whose outward normal points along the positive axis.
    public var positiveSide: Bool
    /// Time (s) and pressure (Pa) pairs, interpolated linearly; pressure pushes into the face.
    public var history: [SIMD2<Float>]

    public init(axis: Int, positiveSide: Bool, history: [SIMD2<Float>]) {
        self.axis = axis
        self.positiveSide = positiveSide
        self.history = history
    }

    /// Impulse per unit area of the whole history, in Pa s.
    public var impulse: Float {
        zip(history, history.dropFirst()).reduce(0) { $0 + 0.5 * ($1.0.y + $1.1.y) * ($1.1.x - $1.0.x) }
    }
}

/// A deformable body: the union of `solids` minus `openings`, meshed with cubic elements.
public struct StructureModel: Sendable, Hashable, Codable {
    public var solids: [Box]
    public var openings: [Box]
    public var material: StructureMaterial
    /// Edge length of an element in metres.
    public var elementSize: Float
    /// Clamp the nodes that sit on the ground plane.
    public var fixedBase: Bool
    public var reinforcement: [ReinforcementLayer] = []
    /// Bars at 45 degrees to the lattice (see `InclinedBars`).
    public var inclinedBars: [InclinedBars] = []
    /// How each solid is reinforced, by index into `solids`; solids beyond the end of this list
    /// are reinforced automatically. Applied by `autoReinforce()`.
    public var solidReinforcement: [Reinforcement] = []
    /// The material of each solid, by index into `solids`, where it is not `material`. Where
    /// solids overlap, the later one's material wins.
    public var solidMaterial: [StructureMaterial?] = []
    /// Solid elements on a lattice, or shells on the midsurfaces of walls and slabs. With
    /// shells, `elementSize` is their size in the plane of the wall or slab.
    public var elementKind: ElementKind = .solid
    /// How each solid is meshed, by index into `solids`, where it differs from `elementKind`.
    /// A body with both kinds is meshed as two, tied together where shells meet solid elements;
    /// `elementSize` is then the solid elements' size and `shellElementSize` the shells'.
    public var solidElementKind: [ElementKind?] = []
    /// In a body of both kinds, the shells' size; `elementSize` if nil.
    public var shellElementSize: Float?
    /// Layers of concrete (or other material) through the thickness of each shell.
    public var shellLayers: Int = 8
    /// Regions in which the structure is held still: nodes inside any of them do not move
    /// (beyond the ground plane, which `fixedBase` holds). For walls built into rigid scenery.
    public var supports: [Box] = []
    /// Where two materials meet, the elements on the weaker one's side carry only this bond
    /// across the boundary: tensile strength (Pa) and fracture energy (J/m²), as of mortar on
    /// concrete, so that infill can come away from its frame. Nil bonds them as one body.
    public var interfaceBond: SIMD2<Float>?
    /// A typical bond of masonry to concrete: 0.2 MPa and 10 J/m².
    public static let masonryBond = SIMD2<Float>(0.2e6, 10)

    /// The axes concrete cracks across (see `CrackAxes`).
    public var crackAxes: CrackAxes = .turningUntilOpen
    /// Whether concrete whose crack axes are fixed opens a second crack where the tension turns
    /// more than 30 degrees away from them, instead of carrying it across the first by shear.
    public var secondCracks = true

    /// Most materials one structure can hold.
    public static let maxMaterials = 8

    public init(
        solids: [Box], openings: [Box] = [], material: StructureMaterial = .reinforcedConcrete,
        elementSize: Float, fixedBase: Bool = true
    ) {
        self.solids = solids
        self.openings = openings
        self.material = material
        self.elementSize = elementSize
        self.fixedBase = fixedBase
    }

    public func occupies(_ point: SIMD3<Float>) -> Bool {
        solids.contains { $0.contains(point) } && !openings.contains { $0.contains(point) }
    }

    public var bounds: Box {
        var low = SIMD3<Float>(repeating: .infinity)
        var high = SIMD3<Float>(repeating: -.infinity)
        for box in solids {
            low = simd_min(low, box.min)
            high = simd_max(high, box.max)
        }
        return Box(min: low, max: high)
    }

    /// Adds a mat of bars, running both ways, near one or both faces of a slab or wall.
    ///
    /// - Parameters:
    ///   - slab: The slab or wall to reinforce.
    ///   - thicknessAxis: The axis (0, 1, 2) through the slab's thickness.
    ///   - areaPerMetre: Bar area per metre width in each direction, in m²/m. Pass different
    ///     values for the two in-plane axes with `transverseAreaPerMetre`.
    ///   - depth: Distance from the face to the centre of the bars.
    ///   - faces: Which faces get a mat: the low side, the high side, or both.
    public mutating func addMat(
        to slab: Box, thicknessAxis: Int, areaPerMetre: Float, transverseAreaPerMetre: Float? = nil,
        longitudinalAxis: Int? = nil, depth: Float, faces: (low: Bool, high: Bool) = (true, true)
    ) {
        // Each mat is smeared through a band one element thick, centred on the bars.
        let h = elementSize
        var ratio = SIMD3<Float>(repeating: areaPerMetre / h)
        if let transverseAreaPerMetre, let longitudinalAxis {
            ratio = SIMD3(repeating: transverseAreaPerMetre / h)
            ratio[longitudinalAxis] = areaPerMetre / h
        }
        ratio[thicknessAxis] = 0
        func band(centre: Float) -> ReinforcementLayer {
            var region = slab
            region.min[thicknessAxis] = centre - h / 2
            region.max[thicknessAxis] = centre + h / 2
            return ReinforcementLayer(region: region, ratio: ratio)
        }
        if faces.low { reinforcement.append(band(centre: slab.min[thicknessAxis] + depth)) }
        if faces.high { reinforcement.append(band(centre: slab.max[thicknessAxis] - depth)) }
    }

    /// How solid `index` is reinforced.
    public func reinforcement(of index: Int) -> Reinforcement {
        solidReinforcement.indices.contains(index) ? solidReinforcement[index] : .automatic
    }

    /// Sets how solid `index` is reinforced. Call `autoReinforce()` afterwards to apply it.
    public mutating func setReinforcement(_ spec: Reinforcement, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidReinforcement.count <= index { solidReinforcement.append(.automatic) }
        solidReinforcement[index] = spec
    }

    /// Removes solid `index` together with its reinforcement and material settings.
    public mutating func removeSolid(at index: Int) {
        guard solids.indices.contains(index) else { return }
        solids.remove(at: index)
        if solidReinforcement.indices.contains(index) { solidReinforcement.remove(at: index) }
        if solidMaterial.indices.contains(index) { solidMaterial.remove(at: index) }
        if solidElementKind.indices.contains(index) { solidElementKind.remove(at: index) }
    }

    /// How solid `index` is meshed.
    public func elementKind(of index: Int) -> ElementKind {
        (solidElementKind.indices.contains(index) ? solidElementKind[index] : nil) ?? elementKind
    }

    /// Meshes solid `index` with `kind`.
    public mutating func setElementKind(_ kind: ElementKind, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidElementKind.count <= index { solidElementKind.append(nil) }
        solidElementKind[index] = kind == elementKind ? nil : kind
    }

    /// The same body with the pieces that come within `distance` of `point` meshed as solid
    /// elements of `elementSize` and the rest as shells of `shellSize`: solid elements where the
    /// stress through a wall's thickness matters, near a charge.
    public func solidNear(_ point: SIMD3<Float>, within distance: Float, shellSize: Float) -> StructureModel {
        var model = self
        model.elementKind = .solid
        model.solidElementKind = []
        for (index, box) in solids.enumerated() {
            let nearest = simd_clamp(point, box.min, box.max)
            model.setElementKind(simd_distance(nearest, point) <= distance ? .solid : .shell, of: index)
        }
        if model.isMixed {
            model.shellElementSize = shellSize
        } else if let kind = solids.indices.first.map({ model.elementKind(of: $0) }), kind == .shell {
            // Nothing is near: all shells.
            model.elementKind = .shell
            model.solidElementKind = []
            model.elementSize = shellSize
        }
        return model
    }

    /// Whether some solids are meshed with solid elements and others with shells.
    public var isMixed: Bool {
        Set(solids.indices.map { elementKind(of: $0) }).count > 1
    }

    /// The part of the body meshed with `kind`: its solids, with their materials and
    /// reinforcement, and everything else; nil if there are none.
    public func part(_ kind: ElementKind) -> StructureModel? {
        let chosen = solids.indices.filter { elementKind(of: $0) == kind }
        guard !chosen.isEmpty else { return nil }
        var part = self
        part.elementKind = kind
        part.solids = chosen.map { solids[$0] }
        part.solidMaterial = chosen.map { solidMaterial.indices.contains($0) ? solidMaterial[$0] : nil }
        part.solidReinforcement = chosen.map { reinforcement(of: $0) }
        part.solidElementKind = []
        if kind == .shell, let shellElementSize { part.elementSize = shellElementSize }
        return part
    }

    /// The material of solid `index`.
    public func material(of index: Int) -> StructureMaterial {
        (solidMaterial.indices.contains(index) ? solidMaterial[index] : nil) ?? material
    }

    /// Sets the material of solid `index`; nil returns it to the structure's own material.
    public mutating func setMaterial(_ newMaterial: StructureMaterial?, of index: Int) {
        guard solids.indices.contains(index) else { return }
        while solidMaterial.count <= index { solidMaterial.append(nil) }
        solidMaterial[index] = newMaterial == material ? nil : newMaterial
    }

    /// The distinct materials in the structure, `material` first.
    public var materials: [StructureMaterial] {
        var list = [material]
        for case let other? in solidMaterial where !list.contains(other) {
            list.append(other)
        }
        return list
    }

    /// Index into `materials` of the material at `point`: that of the last solid containing it.
    public func materialIndex(at point: SIMD3<Float>) -> Int {
        guard let index = solids.lastIndex(where: { $0.contains(point) }) else { return 0 }
        return materials.firstIndex(of: material(of: index)) ?? 0
    }

    /// Replaces the reinforcement with the arrangement each solid asks for. Solids left as
    /// `.automatic` get a standard arrangement worked out from their shape: a slab or wall (one
    /// dimension much smaller than the others) gets a mat of bars in both faces; anything
    /// stockier is treated as a column, with 2% steel along its length and ties across it.
    ///
    /// - Parameters:
    ///   - areaPerMetre: Bar area per metre width of each automatic mat, each way, in m²/m.
    ///   - depth: Distance from a face to the centre of its automatic mat.
    public mutating func autoReinforce(areaPerMetre: Float = 565e-6, depth: Float = 0.04) {
        reinforcement = []
        for (index, solid) in solids.enumerated() {
            let size = solid.size
            let thin = (0..<3).min { size[$0] < size[$1] } ?? 0
            let long = (0..<3).max { size[$0] < size[$1] } ?? 2
            let others = (0..<3).filter { $0 != thin }
            let isSlab = size[thin] <= 0.6 && others.allSatisfy { size[$0] >= 3 * size[thin] }
            func column(_ longitudinal: Float, _ ties: Float) {
                var ratio = SIMD3<Float>(repeating: ties)
                ratio[long] = longitudinal
                reinforcement.append(ReinforcementLayer(region: solid, ratio: ratio))
            }
            switch reinforcement(of: index) {
            case .automatic:
                if isSlab {
                    addMat(
                        to: solid, thicknessAxis: thin, areaPerMetre: areaPerMetre,
                        depth: Swift.min(depth, size[thin] / 2))
                } else {
                    column(0.02, 0.004)
                }
            case .none:
                break
            case .mats(let area, let matDepth, let bothFaces):
                addMat(
                    to: solid, thicknessAxis: thin, areaPerMetre: area,
                    depth: Swift.min(matDepth, size[thin] / 2), faces: (true, bothFaces))
            case .column(let longitudinal, let ties):
                column(longitudinal, ties)
            }
        }
    }
}

/// Node of the structural mesh as stored on the GPU. Layout matches `StructureNode` in
/// `Structure.metal`.
public struct StructureNode: Sendable {
    /// Displacement from the node's lattice position, in metres.
    public var ux: Float = 0
    public var uy: Float = 0
    public var uz: Float = 0
    public var mass: Float = 0
    public var vx: Float = 0
    public var vy: Float = 0
    public var vz: Float = 0
    /// Bits 0-2 hold the node still along x, y, z; bit 3 keeps its velocity as set; bit 4
    /// lets it rise but not fall below where it started. Bit 5 is set by the solver when all
    /// eight elements around the node are intact, which leaves it out of contact.
    public var flags: UInt32 = 0

    public init() {}

    public var displacement: SIMD3<Float> {
        get { SIMD3(ux, uy, uz) }
        set { (ux, uy, uz) = (newValue.x, newValue.y, newValue.z) }
    }

    public var velocity: SIMD3<Float> {
        get { SIMD3(vx, vy, vz) }
        set { (vx, vy, vz) = (newValue.x, newValue.y, newValue.z) }
    }

    /// Held still in every direction.
    public var isFixed: Bool {
        get { flags & 7 == 7 }
        set { flags = newValue ? flags | 7 : flags & ~7 }
    }

    /// Holds the node still along the chosen axes only.
    public mutating func restrain(x: Bool = false, y: Bool = false, z: Bool = false) {
        flags |= (x ? 1 : 0) | (y ? 2 : 0) | (z ? 4 : 0)
    }

    /// Rests on a support that pushes up but does not hold down: the node cannot move below
    /// its starting height, and lifts off freely.
    public var restsOnSupport: Bool {
        get { flags & 16 != 0 }
        set { flags = newValue ? flags | 16 : flags & ~16 }
    }

    /// Moves at its current velocity regardless of the forces on it.
    public var isPrescribed: Bool {
        get { flags & 8 != 0 }
        set { flags = newValue ? flags | 8 : flags & ~8 }
    }
}

public enum ElementFlag: UInt8, Sendable {
    case empty = 0
    case active = 1
    case eroded = 2
}

public struct StructureSummary: Sendable, Hashable {
    /// Elements still carrying load.
    public var activeElements = 0
    /// Elements removed after reaching the failure strain.
    public var erodedElements = 0
    /// Largest displacement, in metres, of a node still attached to an active element.
    public var maxDisplacement: Float = 0
    /// Largest equivalent plastic strain (von Mises) or compressive strain (concrete) in an
    /// active element.
    public var maxPlasticStrain: Float = 0
    /// Largest damage index in an active element: 0 is sound, 1 is at the point of failure.
    public var maxDamage: Float = 0
    /// True when the solution has become numerically unstable (some displacement is not a number).
    public var hasBlownUp = false

    public init() {}

    public var erodedFraction: Double {
        let total = activeElements + erodedElements
        return total == 0 ? 0 : Double(erodedElements) / Double(total)
    }

    /// The summary of two parts of one body together.
    public func combined(with other: StructureSummary) -> StructureSummary {
        var both = self
        both.activeElements += other.activeElements
        both.erodedElements += other.erodedElements
        both.maxDisplacement = max(maxDisplacement, other.maxDisplacement)
        both.maxPlasticStrain = max(maxPlasticStrain, other.maxPlasticStrain)
        both.maxDamage = max(maxDamage, other.maxDamage)
        both.hasBlownUp = hasBlownUp || other.hasBlownUp
        return both
    }
}

/// Layout matches `StructureUniforms` in `Structure.metal`.
struct StructureUniforms {
    var ex: UInt32
    var ey: UInt32
    var ez: UInt32
    var substep: UInt32 = 0
    var h: Float
    var originX: Float
    var originY: Float
    var originZ: Float
    var bulkLinear: Float
    var bulkQuadratic: Float
    var criticalStep: Float
    var fixedStep: Float = 0
    var gravity: Float
    var damping: Float
    var ambientPressure: Float = 101_325
    var fluidGamma: Float = 1.4
    var fluidCell: Float = 1
    var fluidNx: UInt32 = 1
    var fluidNy: UInt32 = 1
    var fluidNz: UInt32 = 1
    var coupled: UInt32 = 0
    var minVolumeRatio: Float
    var groundFriction: Float
    var contactMode: UInt32 = 0
    var stamp: UInt32 = 0
    var contactNx: UInt32 = 1
    var contactNy: UInt32 = 1
    var contactNz: UInt32 = 1
    var gridOriginX: Float = 0
    var gridOriginY: Float = 0
    var gridOriginZ: Float = 0
    var contactStiffness: Float = 0
    var contactDamping: Float = 0
    var contactFriction: Float = 0
    var rateFilter: Float = 0
    var loadTime: Float = 0
    var loadCount: UInt32 = 0
    var loadFace: UInt32 = 0
    var debrisLoading: UInt32 = 0
    var exchangeX: Int32 = 0
    var exchangeY: Int32 = 0
    var exchangeZ: Int32 = 0
    var exchangeNx: Int32 = 0
    var exchangeNy: Int32 = 0
    var exchangeNz: Int32 = 0
    var fluidAirModel: UInt32 = 0
    var orientedCracks: UInt32 = 0
    var interfaceLinks: UInt32 = 0
    var fluidRefine: UInt32 = 0
    var fluidBlocksX: UInt32 = 0
    var fluidBlocksY: UInt32 = 0
    var secondCracks: UInt32 = 0
}

/// One material as the element kernel sees it. Layout matches `MaterialParameters` in
/// `Structure.metal`.
struct MaterialParameters {
    var density: Float = 0
    var lambda: Float = 0
    var mu: Float = 0
    var yieldStress: Float = 1e30
    var hardening: Float = 0
    var failureStrain: Float = 1e30
    var hourglassStiffness: Float = 0
    var soundSpeed: Float = 0
    var materialModel: UInt32 = 0
    var youngsModulus: Float = 0
    var compressiveStrength: Float = 0
    var tensileStrength: Float = 0
    var crackOnset: Float = 1
    var crackSoftening: Float = 1
    var crushPeak: Float = 1
    var crushEnd: Float = 2
    var erosionStrain: Float = 1
    var crushErosion: Float = 1
    var confinement: Float = 0
    var steelModulus: Float = 0
    var steelPoints: UInt32 = 1
    var steelStrain: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var steelStress: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
    var concreteRateCompression: Float = 0
    var concreteRateTension: Float = 0
    var steelRateYield: Float = 0
    var steelRateUltimate: Float = 0
    var crackBand: Float = 1
    var interlockStrength: Float = 0
    var interlockWidthScale: Float = 0
    var shearRetention: Float = 0.25
    var crackResidual: Float = 0
    var crushRadius: UInt32 = 0
    var steelHardeningRatio: Float = 0.01
    var barReach: Float = 0
}

/// Layout matches `CouplingUniforms` in `Structure.metal`.
struct CouplingUniforms {
    var regionX: UInt32
    var regionY: UInt32
    var regionZ: UInt32
    var regionNx: UInt32
    var regionNy: UInt32
    var regionNz: UInt32
    var fluidNx: UInt32
    var fluidNy: UInt32
    var fluidNz: UInt32
    var threshold: UInt32
    var ex: UInt32
    var ey: UInt32
    var fluidCell: Float
    var h: Float
    var originX: Float
    var originY: Float
    var originZ: Float
    var gamma: Float
    var ambientDensity: Float
    var ambientPressure: Float
    var airModel: UInt32 = 0
    /// What each splatted point counts for in a cell's occupancy (see `threshold`).
    var splatWeight: UInt32 = 1
    /// The air's refinement: its ratio (0 when not refined), the size of its grid of blocks, the
    /// count that makes a fine cell solid, and the points along each edge an element is sampled
    /// at for the fine cells.
    var refineRatio: UInt32 = 0
    var blocksX: UInt32 = 0
    var blocksY: UInt32 = 0
    var fineThreshold: UInt32 = 1
    var fineSamples: UInt32 = 1
    var coarseSamples: UInt32 = 1
}

/// When nodes of the structure repel each other.
public enum ContactMode: UInt32, Sendable {
    /// Parts of the structure pass through each other.
    case off = 0
    /// Contact switches on once any element has failed; an intact structure does not need it.
    case afterFailure = 1
    case always = 2
}

/// Loads and compiles the compute kernels shared by the fluid and structural solvers.
enum ShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        let source = try ["Solver", "Refine", "Structure", "Shell"].map { name in
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: "metal", subdirectory: "Shaders")
            else {
                throw BlastError.missingShader("\(name).metal")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
        return try device.makeLibrary(source: source, options: nil)
    }
}

// MARK: - Decoding layouts saved by earlier versions

extension StructureMaterial {
    /// Decodes a material saved by any version: properties added since it was saved take
    /// their standard values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        model = try container.decode(MaterialModel.self, forKey: .model)
        density = try container.decode(Float.self, forKey: .density)
        youngsModulus = try container.decode(Float.self, forKey: .youngsModulus)
        poissonRatio = try container.decode(Float.self, forKey: .poissonRatio)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        yieldStress = try value(.yieldStress, yieldStress)
        hardeningModulus = try value(.hardeningModulus, hardeningModulus)
        failureStrain = try value(.failureStrain, failureStrain)
        compressiveStrength = try value(.compressiveStrength, compressiveStrength)
        tensileStrength = try value(.tensileStrength, tensileStrength)
        fractureEnergy = try value(.fractureEnergy, fractureEnergy)
        crushingEnergy = try value(.crushingEnergy, crushingEnergy)
        erosionOpening = try value(.erosionOpening, erosionOpening)
        steel = try container.decodeIfPresent(SteelProperties.self, forKey: .steel)
        crackSpacing = try value(.crackSpacing, crackSpacing)
        crushBand = try value(.crushBand, crushBand)
        aggregateSize = try value(.aggregateSize, aggregateSize)
        crushLength = try value(.crushLength, crushLength)
        bondSpreading = try value(.bondSpreading, bondSpreading)
        confinementCoefficient = try value(.confinementCoefficient, confinementCoefficient)
        crackResidual = try value(.crackResidual, crackResidual)
        concreteRateFactor = try value(.concreteRateFactor, concreteRateFactor)
        steelRateFactor = try value(.steelRateFactor, steelRateFactor)
        rateDependent = try value(.rateDependent, rateDependent)
    }
}

extension StructureModel {
    /// Decodes a structure saved by any version: properties added since it was saved take
    /// their standard values.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        solids = try container.decode([Box].self, forKey: .solids)
        openings = try container.decode([Box].self, forKey: .openings)
        material = try container.decode(StructureMaterial.self, forKey: .material)
        elementSize = try container.decode(Float.self, forKey: .elementSize)
        fixedBase = try container.decode(Bool.self, forKey: .fixedBase)
        reinforcement = try container.decodeIfPresent([ReinforcementLayer].self, forKey: .reinforcement) ?? []
        inclinedBars = try container.decodeIfPresent([InclinedBars].self, forKey: .inclinedBars) ?? []
        solidReinforcement =
            try container.decodeIfPresent([Reinforcement].self, forKey: .solidReinforcement) ?? []
        solidMaterial = try container.decodeIfPresent([StructureMaterial?].self, forKey: .solidMaterial) ?? []
        elementKind = try container.decodeIfPresent(ElementKind.self, forKey: .elementKind) ?? .solid
        shellLayers = try container.decodeIfPresent(Int.self, forKey: .shellLayers) ?? 8
        supports = try container.decodeIfPresent([Box].self, forKey: .supports) ?? []
        crackAxes = try container.decodeIfPresent(CrackAxes.self, forKey: .crackAxes) ?? .turningUntilOpen
        secondCracks = try container.decodeIfPresent(Bool.self, forKey: .secondCracks) ?? true
        solidElementKind = try container.decodeIfPresent([ElementKind?].self, forKey: .solidElementKind) ?? []
        shellElementSize = try container.decodeIfPresent(Float.self, forKey: .shellElementSize)
        interfaceBond = try container.decodeIfPresent(SIMD2<Float>.self, forKey: .interfaceBond)
    }
}
