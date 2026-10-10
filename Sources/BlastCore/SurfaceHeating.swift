import Foundation

/// A material's thermal properties near room temperature, taken as constant, and where it burns,
/// the thresholds at which tests have seen it ignite. See docs/surface-heating.md for the sources.
public struct ThermalMaterial: Codable, Sendable, Equatable {
    public var name: String
    /// In W/(m K), kg/m³ and J/(kg K).
    public var conductivity: Float
    public var density: Float
    public var specificHeat: Float
    /// The share of the fireball's radiation the surface absorbs.
    public var absorptivity: Float
    /// The surface's emissivity for its own long-wave radiation, by which it loses heat.
    public var emissivity: Float
    /// Nil for a material that does not burn, or for which no test thresholds are given.
    public var ignition: IgnitionThreshold?

    public init(
        name: String, conductivity: Float, density: Float, specificHeat: Float, absorptivity: Float,
        emissivity: Float, ignition: IgnitionThreshold? = nil
    ) {
        self.name = name
        self.conductivity = conductivity
        self.density = density
        self.specificHeat = specificHeat
        self.absorptivity = absorptivity
        self.emissivity = emissivity
        self.ignition = ignition
    }

    /// In m²/s.
    public var diffusivity: Double { Double(conductivity) / (Double(density) * Double(specificHeat)) }

    /// The share of a fireball's radiation a grey-banded surface absorbs: its solar absorptivity
    /// for the part of a 2,000 K black body's spectrum below 2 µm (48%), and its long-wave
    /// emissivity beyond. An assumption, as building materials absorb near-infrared much as they
    /// do sunlight and the far infrared as they emit it.
    public static func fireballAbsorptivity(solar: Float, emissivity: Float) -> Float {
        0.48 * solar + 0.52 * emissivity
    }

    var isValid: Bool {
        [conductivity, density, specificHeat].allSatisfy { $0.isFinite && $0 > 0 }
            && absorptivity.isFinite && (0...1).contains(absorptivity) && emissivity.isFinite
            && (0...1).contains(emissivity) && (ignition?.isValid ?? true)
    }
}

/// Where a material has been seen to ignite in tests: thresholds to compare against, not a model
/// of burning. Either may be absent.
public struct IgnitionThreshold: Codable, Sendable, Equatable {
    /// The surface temperature at which it ignites under steady radiant heating, in kelvin.
    public var temperature: Float?
    /// The incident radiant exposure seen to ignite it in a short thermal pulse, in J/m².
    public var fluence: Float?
    /// What the fluence's tests saw, and where they come from, in a few words.
    public var basis: String

    public init(temperature: Float? = nil, fluence: Float? = nil, basis: String) {
        self.temperature = temperature
        self.fluence = fluence
        self.basis = basis
    }

    var isValid: Bool {
        (temperature.map { $0.isFinite && $0 > 0 } ?? true) && (fluence.map { $0.isFinite && $0 > 0 } ?? true)
    }

    /// A calorie a square centimetre, the unit of Glasstone and Dolan's tables, in J/m².
    public static let calorieSquareCentimetre: Float = 41_840
}

/// What a surface is made of, outermost layer first. A layer without a thickness runs through the
/// solid behind the surface (as thick as the block or structure is along its normal, and without
/// end under the ground).
public struct SurfaceMaterial: Codable, Sendable, Equatable {
    public struct Layer: Codable, Sendable, Equatable {
        public var material: ThermalMaterial
        /// In metres; nil for the rest of the solid.
        public var thickness: Float?

        public init(_ material: ThermalMaterial, thickness: Float? = nil) {
            self.material = material
            self.thickness = thickness
        }
    }

    public var name: String
    public var layers: [Layer]

    public init(name: String, layers: [Layer]) {
        self.name = name
        self.layers = layers
    }

    var isValid: Bool {
        !layers.isEmpty
            && layers.allSatisfy {
                $0.material.isValid && ($0.thickness.map { $0.isFinite && $0 > 0 } ?? true)
            }
    }
}

extension ThermalMaterial {
    /// Concrete (stone mix): Incropera Table A.3; solar absorptivity 0.60 and emissivity 0.88,
    /// Table A.12.
    public static let concrete = ThermalMaterial(
        name: "Concrete", conductivity: 1.4, density: 2300, specificHeat: 880,
        absorptivity: fireballAbsorptivity(solar: 0.60, emissivity: 0.88), emissivity: 0.88)
    /// Common brick: Incropera Table A.3; red brick's 0.63 and 0.93, Table A.12.
    public static let brick = ThermalMaterial(
        name: "Brick", conductivity: 0.72, density: 1920, specificHeat: 835,
        absorptivity: fireballAbsorptivity(solar: 0.63, emissivity: 0.93), emissivity: 0.93)
    /// Plain carbon steel (AISI 1010): Incropera Table A.1; weathered, oxidised, its surface an
    /// estimate, 0.7 and 0.8.
    public static let steel = ThermalMaterial(
        name: "Steel", conductivity: 63.9, density: 7832, specificHeat: 434,
        absorptivity: fireballAbsorptivity(solar: 0.7, emissivity: 0.8), emissivity: 0.8)
    /// Soda-lime plate glass: Incropera Table A.3, emissivity 0.92. Clear glass passes most of a
    /// fireball's light below 2.7 µm and absorbs beyond, 32% of a 2,000 K black body's spectrum, so
    /// 0.3; taken as absorbed at the surface. What passes into the room is not followed.
    public static let glass = ThermalMaterial(
        name: "Glass", conductivity: 1.4, density: 2500, specificHeat: 750, absorptivity: 0.3,
        emissivity: 0.92)
    /// Softwood (fir, pine): Incropera Table A.3; unpainted, its surface an estimate, 0.6 and 0.9.
    /// Ignites: flaming in plywood of Douglas fir during a pulse of 9 cal/cm² (Glasstone and
    /// Dolan, Table 7.40, 35 kt), its surface at about 350 °C at flaming ignition under steady
    /// radiant heat (Babrauskas 2002).
    public static let softwood = ThermalMaterial(
        name: "Softwood", conductivity: 0.12, density: 510, specificHeat: 1380,
        absorptivity: fireballAbsorptivity(solar: 0.6, emissivity: 0.9), emissivity: 0.9,
        ignition: IgnitionThreshold(
            temperature: 623, fluence: 9 * IgnitionThreshold.calorieSquareCentimetre,
            basis: "plywood flaming during a 35 kt pulse; 350 °C at steady flaming ignition"))
    /// Dense asphalt concrete: density and specific heat from Incropera Table A.3; conductivity
    /// 1.0, within the 0.7 to 1.5 W/(m K) measured for pavements (the table's 0.062 is far below
    /// them); fresh asphalt's 0.9 and 0.93.
    public static let asphalt = ThermalMaterial(
        name: "Asphalt", conductivity: 1.0, density: 2115, specificHeat: 920,
        absorptivity: fireballAbsorptivity(solar: 0.9, emissivity: 0.93), emissivity: 0.93)
    /// Soil: Incropera Table A.3; dry, its surface an estimate, 0.75 and 0.92.
    public static let soil = ThermalMaterial(
        name: "Soil", conductivity: 0.52, density: 2050, specificHeat: 1840,
        absorptivity: fireballAbsorptivity(solar: 0.75, emissivity: 0.92), emissivity: 0.92)
    /// Dry grass over soil: heated as the soil, as blades are not a solid; ignites at 5 cal/cm²
    /// (fine grass, Glasstone and Dolan, Table 7.40, 35 kt).
    public static let dryGrass = ThermalMaterial(
        name: "Dry grass", conductivity: 0.52, density: 2050, specificHeat: 1840,
        absorptivity: fireballAbsorptivity(solar: 0.75, emissivity: 0.92), emissivity: 0.92,
        ignition: IgnitionThreshold(
            fluence: 5 * IgnitionThreshold.calorieSquareCentimetre,
            basis: "fine grass ignites in a 35 kt pulse"))
    /// Cotton canvas, white: Incropera Table A.3's cotton for conductivity and specific heat, the
    /// density of 12 oz/yd² over an assumed half a millimetre, its surface an estimate, 0.3 and
    /// 0.9; ignites at 13 cal/cm² (Glasstone and Dolan, Table 7.35, 35 kt).
    public static let canvas = ThermalMaterial(
        name: "Canvas", conductivity: 0.06, density: 800, specificHeat: 1300,
        absorptivity: fireballAbsorptivity(solar: 0.3, emissivity: 0.9), emissivity: 0.9,
        ignition: IgnitionThreshold(
            fluence: 13 * IgnitionThreshold.calorieSquareCentimetre,
            basis: "white canvas ignites in a 35 kt pulse"))
}

extension SurfaceMaterial {
    /// The materials a surface can be given by name.
    public static let library: [SurfaceMaterial] = [
        SurfaceMaterial(name: "concrete", layers: [.init(.concrete)]),
        SurfaceMaterial(name: "masonry", layers: [.init(.brick)]),
        SurfaceMaterial(name: "steel", layers: [.init(.steel)]),
        SurfaceMaterial(name: "steel sheet", layers: [.init(.steel, thickness: 0.0007)]),
        SurfaceMaterial(name: "glass", layers: [.init(.glass)]),
        SurfaceMaterial(name: "glass pane", layers: [.init(.glass, thickness: 0.006)]),
        SurfaceMaterial(name: "timber", layers: [.init(.softwood)]),
        SurfaceMaterial(name: "timber board", layers: [.init(.softwood, thickness: 0.02)]),
        SurfaceMaterial(name: "asphalt", layers: [.init(.asphalt)]),
        SurfaceMaterial(name: "soil", layers: [.init(.soil)]),
        SurfaceMaterial(name: "dry grass", layers: [.init(.dryGrass)]),
        SurfaceMaterial(name: "canvas", layers: [.init(.canvas, thickness: 0.0005)]),
    ]

    /// Coats of paint, thin enough to change only how the surface absorbs and emits: white and
    /// black, solar absorptivities 0.26 and 0.98 with emissivities 0.90 and 0.98 (Incropera
    /// Table A.12).
    public static let finishes: [String: (absorptivity: Float, emissivity: Float)] = [
        "white paint": (ThermalMaterial.fireballAbsorptivity(solar: 0.26, emissivity: 0.90), 0.90),
        "black paint": (ThermalMaterial.fireballAbsorptivity(solar: 0.98, emissivity: 0.98), 0.98),
    ]

    /// The library's name for a structural material's surface, by its name.
    public static func named(forStructure name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("glass") { return "glass" }
        if lower.contains("steel") && !lower.contains("concrete") { return "steel" }
        if lower.contains("masonry") || lower.contains("brick") { return "masonry" }
        if lower.contains("timber") || lower.contains("wood") { return "timber" }
        return "concrete"
    }
}

/// A different material for some of the scene's surfaces than the defaults give them.
public struct SurfaceOverride: Codable, Sendable, Equatable {
    /// `ground`, `block <n>`, `structure` (all of it) or `structure <n>` (its nth solid).
    public var surface: String
    /// A name from the library or the spec's own materials; nil keeps the surface's own.
    public var material: String?
    /// `white paint` or `black paint`, over the outer layer.
    public var finish: String?
    /// The outer layer's thickness, in metres, in place of the material's.
    public var thickness: Float?

    public init(surface: String, material: String? = nil, finish: String? = nil, thickness: Float? = nil) {
        self.surface = surface
        self.material = material
        self.finish = finish
        self.thickness = thickness
    }
}

/// How the surfaces' heating is reckoned: what each is made of, and the conduction model's grid.
/// Any field left out of its JSON takes its default.
public struct SurfaceHeatingSpec: Codable, Sendable, Equatable {
    public var enabled = true
    /// The air's and every surface's starting temperature, in kelvin.
    public var ambient: Float = 293.15
    /// The convective coefficient to the air at ambient on the exposed face, and on the back of a
    /// layer thinner than the solid, in W/(m² K).
    public var convection: Float = 20
    /// The ground's and the rigid blocks' materials, by name.
    public var ground = "asphalt"
    public var blocks = "concrete"
    /// The structure's material, by name; nil takes it from each solid's own (concrete, masonry,
    /// steel or glass).
    public var structure: String?
    public var overrides: [SurfaceOverride] = []
    /// Materials of the spec's own, beside the library's, or in place of one of the same name.
    public var materials: [SurfaceMaterial] = []
    /// Cells through the depth of each surface's column.
    public var cells = 32
    /// The first cell's thickness is the outer layer's diffusion length over this time, in seconds.
    public var resolvedTime: Float = 2.5e-5
    /// A column whose solid runs deeper than four diffusion lengths over this time, in seconds, is
    /// cut there with no heat flowing through, as a semi-infinite solid.
    public var horizon: Float = 2
    /// The longest time step, in seconds; a frame's interval is cut into equal steps no longer.
    public var maximumStep: Float = 1e-3

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = SurfaceHeatingSpec()
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        ambient = try values.decodeIfPresent(Float.self, forKey: .ambient) ?? defaults.ambient
        convection = try values.decodeIfPresent(Float.self, forKey: .convection) ?? defaults.convection
        ground = try values.decodeIfPresent(String.self, forKey: .ground) ?? defaults.ground
        blocks = try values.decodeIfPresent(String.self, forKey: .blocks) ?? defaults.blocks
        structure = try values.decodeIfPresent(String.self, forKey: .structure)
        overrides = try values.decodeIfPresent([SurfaceOverride].self, forKey: .overrides) ?? []
        materials = try values.decodeIfPresent([SurfaceMaterial].self, forKey: .materials) ?? []
        cells = try values.decodeIfPresent(Int.self, forKey: .cells) ?? defaults.cells
        resolvedTime = try values.decodeIfPresent(Float.self, forKey: .resolvedTime) ?? defaults.resolvedTime
        horizon = try values.decodeIfPresent(Float.self, forKey: .horizon) ?? defaults.horizon
        maximumStep = try values.decodeIfPresent(Float.self, forKey: .maximumStep) ?? defaults.maximumStep
    }

    /// The material of that name, the spec's own first.
    public func material(named name: String) -> SurfaceMaterial? {
        materials.first { $0.name == name } ?? SurfaceMaterial.library.first { $0.name == name }
    }

    public func validate() throws {
        let names = [ground, blocks] + (structure.map { [$0] } ?? []) + overrides.compactMap(\.material)
        guard ambient.isFinite, (100...1000).contains(ambient), convection.isFinite,
            (0...1e4).contains(convection),
            (4...512).contains(cells), resolvedTime.isFinite, resolvedTime > 0, horizon.isFinite,
            horizon > resolvedTime, maximumStep.isFinite, (1e-6...1).contains(maximumStep),
            materials.allSatisfy(\.isValid), names.allSatisfy({ material(named: $0) != nil }),
            overrides.allSatisfy({ override in
                (override.finish.map { SurfaceMaterial.finishes[$0] != nil } ?? true)
                    && (override.thickness.map { $0.isFinite && $0 > 0 } ?? true)
            })
        else {
            throw CocoaError(
                .coderInvalidValue,
                userInfo: [NSLocalizedDescriptionKey: "The surface heating description is out of range."])
        }
    }
}

/// Which receivers passed a test threshold for igniting their material. Illustrative: thresholds
/// from tests, not a fire model.
public struct IgnitionFlags: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The surface reached the temperature at which the material ignites under steady heating.
    public static let temperature = IgnitionFlags(rawValue: 1)
    /// The fluence reached what ignited the material in a short pulse.
    public static let fluence = IgnitionFlags(rawValue: 2)
}

/// One of the materials a result's receivers were given, as resolved: its layers' thicknesses,
/// with the solid behind as nil, and its outer surface's finish.
public struct HeatedMaterial: Codable, Sendable, Equatable {
    /// The library's or the spec's name, and the finish if any, as `concrete, white paint`.
    public var name: String
    public var layers: [SurfaceMaterial.Layer]

    /// The outer layer, which absorbs, emits and ignites.
    public var surface: ThermalMaterial { layers[0].material }
}

/// What the surface heating found: the material each receiver's surface was given, the highest
/// temperature its surface reached, and the test thresholds for ignition it passed.
public struct SurfaceHeatingResult: Codable, Sendable, Equatable {
    public var ambient: Float
    public var materials: [HeatedMaterial]
    /// One a receiver, an index into `materials`.
    public var material: [Int]
    /// In kelvin, one a receiver.
    public var peakTemperature: [Float]
    /// One a receiver, `IgnitionFlags`' raw values; zero where its material does not burn.
    public var ignition: [UInt8]

    /// Each surface's highest peak temperature, and the receivers that passed ignition thresholds.
    public func summary(receivers: [ThermalReceiver]) -> [String] {
        var lines = [
            "Surface heating (1D conduction into each surface; ignition illustrative, from test thresholds):"
        ]
        var surfaces: [String] = []
        for receiver in receivers where !surfaces.contains(receiver.surface) {
            surfaces.append(receiver.surface)
        }
        for surface in surfaces {
            let indices = receivers.indices.filter { receivers[$0].surface == surface }
            guard let hottest = indices.max(by: { peakTemperature[$0] < peakTemperature[$1] }) else {
                continue
            }
            let names = Set(indices.map { materials[material[$0]].name }).sorted().joined(separator: ", ")
            lines.append(
                String(
                    format: "  %@ (%@): surface up to %.0f K, %.0f K above ambient", surface, names,
                    peakTemperature[hottest], peakTemperature[hottest] - ambient))
        }
        let burning = materials.indices.filter { materials[$0].surface.ignition != nil }
        for m in burning {
            let indices = material.indices.filter { material[$0] == m }
            guard !indices.isEmpty else { continue }
            let hot = indices.filter { IgnitionFlags(rawValue: ignition[$0]).contains(.temperature) }.count
            let dosed = indices.filter { IgnitionFlags(rawValue: ignition[$0]).contains(.fluence) }.count
            lines.append(
                "  \(materials[m].name): \(dosed) of \(indices.count) points past the short-pulse ignition fluence, "
                    + "\(hot) past the ignition temperature (illustrative)")
        }
        return lines
    }
}

/// The fireball's radiation heating each receiver's surface: the absorbed irradiance conducted
/// into its material as one dimension, through a column of cells growing geometrically from the
/// surface, which loses heat by convection and its own radiation; the same on the back of a layer
/// thinner than the solid. Inert: nothing melts, chars, burns or spalls, and the properties do not
/// change with temperature.
public struct SurfaceHeating: Sendable {
    /// Which material each receiver was given, and the columns they are reckoned through.
    public struct Layout: Sendable, Equatable {
        public let materials: [HeatedMaterial]
        public let material: [Int]
        /// The columns the receivers are reckoned through, and each receiver's: one a material and
        /// thickness of solid, those cut off at the same depth shared.
        let columns: [Column]
        let column: [Int]

        /// Gives each receiver on `grids` its material, by `spec` and the scene's own materials.
        public init(spec: SurfaceHeatingSpec, grids: [ThermalSurfaceGrid], scene: FragmentScene) {
            var materials: [HeatedMaterial] = []
            var columns: [Column] = []
            var material: [Int] = []
            var column: [Int] = []
            for grid in grids where !grid.receivers.isEmpty {
                let resolved = Self.resolve(spec: spec, grid: grid, scene: scene)
                let m = materials.firstIndex(of: resolved.material) ?? materials.count
                if m == materials.count { materials.append(resolved.material) }
                let built = Column(resolved.material, solid: resolved.thickness, spec: spec)
                let c = columns.firstIndex(of: built) ?? columns.count
                if c == columns.count { columns.append(built) }
                material += [Int](repeating: m, count: grid.receivers.count)
                column += [Int](repeating: c, count: grid.receivers.count)
            }
            self.materials = materials
            self.columns = columns
            self.material = material
            self.column = column
        }

        /// A grid's material, resolved, and how thick the solid behind it is, nil under the ground.
        static func resolve(spec: SurfaceHeatingSpec, grid: ThermalSurfaceGrid, scene: FragmentScene)
            -> (material: HeatedMaterial, thickness: Float?)
        {
            var labels = [grid.surface]
            var name: String
            var thickness: Float?
            if let solid = grid.solid {
                let boxes = scene.blocks + scene.structure
                let axis = grid.normal.x != 0 ? 0 : (grid.normal.y != 0 ? 1 : 2)
                thickness = boxes[solid].size[axis]
                if solid < scene.blocks.count {
                    name = spec.blocks
                } else {
                    let n = solid - scene.blocks.count
                    labels.append("structure \(n)")
                    name =
                        spec.structure
                        ?? SurfaceMaterial.named(forStructure: scene.structureMaterials?[safe: n] ?? "")
                }
            } else {
                name = spec.ground
            }
            var finish: String?
            var outer: Float?
            for override in spec.overrides where labels.contains(override.surface) {
                if let material = override.material { name = material }
                if let value = override.finish { finish = value }
                if let value = override.thickness { outer = value }
            }
            var layers = (spec.material(named: name) ?? SurfaceMaterial.library[0]).layers
            if let outer { layers[0].thickness = outer }
            if let finish, let coat = SurfaceMaterial.finishes[finish] {
                layers[0].material.absorptivity = coat.absorptivity
                layers[0].material.emissivity = coat.emissivity
            }
            return (HeatedMaterial(name: finish.map { "\(name), \($0)" } ?? name, layers: layers), thickness)
        }

        /// The result from each receiver's peak surface temperature and fluence.
        public func result(peakTemperature: [Float], fluence: [Float], ambient: Float) -> SurfaceHeatingResult
        {
            let flags = material.indices.map { n -> UInt8 in
                guard let threshold = materials[material[n]].surface.ignition else { return 0 }
                var flags: IgnitionFlags = []
                if let temperature = threshold.temperature, peakTemperature[n] >= temperature {
                    flags.insert(.temperature)
                }
                if let dose = threshold.fluence, fluence[n] >= dose { flags.insert(.fluence) }
                return flags.rawValue
            }
            return SurfaceHeatingResult(
                ambient: ambient, materials: materials, material: material, peakTemperature: peakTemperature,
                ignition: flags)
        }
    }

    public let spec: SurfaceHeatingSpec
    public let layout: Layout
    /// Every column's temperatures, `nodes` a receiver, surface first, in kelvin.
    private var temperature: [Double]
    /// Whether each column has been heated at all; those that have not are skipped.
    private var heated: [Bool]
    /// In kelvin, one a receiver.
    public private(set) var peakTemperature: [Float]
    private var lastTime: Double?
    private var lastIrradiance: [Float] = []
    let nodes: Int
    /// Each column's capacities then conductances, `2 nodes − 1` a column, and its face.
    private let coefficients: [Double]
    private let faces: [Column.Face]

    public init(spec: SurfaceHeatingSpec, grids: [ThermalSurfaceGrid], scene: FragmentScene) {
        self.init(spec: spec, layout: Layout(spec: spec, grids: grids, scene: scene))
    }

    init(spec: SurfaceHeatingSpec, layout: Layout) {
        self.spec = spec
        self.layout = layout
        nodes = spec.cells + 1
        coefficients = layout.columns.flatMap { $0.capacity + $0.conductance }
        faces = layout.columns.map(\.face)
        temperature = [Double](repeating: Double(spec.ambient), count: layout.material.count * nodes)
        heated = [Bool](repeating: false, count: layout.material.count)
        peakTemperature = [Float](repeating: spec.ambient, count: layout.material.count)
    }

    /// The surface temperature of each receiver now, in kelvin.
    public var surfaceTemperature: [Float] {
        (0..<layout.material.count).map { Float(temperature[$0 * nodes]) }
    }

    /// Heats every surface from the last frame to `time`, its irradiance (W/m², one a receiver)
    /// going linearly from the last frame's to `irradiance`, as the fluence's trapezium rule takes
    /// it. The first frame only sets where it starts.
    public mutating func advance(to time: Double, irradiance: [Float]) {
        defer {
            lastTime = time
            lastIrradiance = irradiance
        }
        guard let lastTime, time > lastTime else { return }
        let interval = time - lastTime
        let steps = max(1, Int((interval / Double(spec.maximumStep)).rounded(.up)))
        let dt = interval / Double(steps)
        let count = layout.material.count
        let chunk = 256
        let before = lastIrradiance
        let nodes = self.nodes
        let ambient = Double(spec.ambient)
        let convection = Double(spec.convection)
        let stride = 2 * nodes - 1
        let columnOf = UnsafeMutableBufferPointer<Int32>.allocate(capacity: count)
        defer { columnOf.deallocate() }
        for n in 0..<count { columnOf[n] = Int32(layout.column[n]) }
        let unchanged = before.count == count ? nil : [Float](repeating: 0, count: count)
        (unchanged ?? before).withUnsafeBufferPointer { before in
            irradiance.withUnsafeBufferPointer { irradiance in
                coefficients.withUnsafeBufferPointer { coefficients in
                    faces.withUnsafeBufferPointer { faces in
                        temperature.withUnsafeMutableBufferPointer { temperature in
                            heated.withUnsafeMutableBufferPointer { heated in
                                peakTemperature.withUnsafeMutableBufferPointer { peak in
                                    DispatchQueue.concurrentPerform(iterations: (count + chunk - 1) / chunk) {
                                        c in
                                        let work = Column.Work(nodes: nodes)
                                        for n in c * chunk..<min((c + 1) * chunk, count) {
                                            let q0 = Double(before[n])
                                            let q1 = Double(irradiance[n])
                                            guard heated[n] || q0 > 0 || q1 > 0 else { continue }
                                            heated[n] = true
                                            let k = Int(columnOf[n])
                                            let cap = coefficients.baseAddress! + k * stride
                                            let t = temperature.baseAddress! + n * nodes
                                            var hottest = Double(peak[n])
                                            for s in 0..<steps {
                                                let a = Double(s) / Double(steps)
                                                let b = Double(s + 1) / Double(steps)
                                                Column.step(
                                                    t, dt: dt, from: q0 + (q1 - q0) * a,
                                                    to: q0 + (q1 - q0) * b,
                                                    ambient: ambient, convection: convection, work: work,
                                                    face: faces[k], c: cap, g: cap + nodes)
                                                hottest = max(hottest, t[0])
                                            }
                                            peak[n] = Float(hottest)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    public func result(fluence: [Float]) -> SurfaceHeatingResult {
        layout.result(peakTemperature: peakTemperature, fluence: fluence, ambient: spec.ambient)
    }
}

/// One material's column of cells into its surface, as finite volumes: a node at the surface, at
/// each cell's far face and at every interface between layers, each holding the heat capacity of
/// the half cells either side of it, joined to the next by its cell's conductance.
struct Column: Sendable, Equatable {
    /// In J/(m² K), one a node.
    var capacity: [Double]
    /// In W/(m² K), between each node and the next.
    var conductance: [Double]
    /// Depth of each node, in metres.
    var depth: [Double]
    var absorptivity: Double
    var emissivity: Double
    /// The back face's, where the material is thinner than the column would be; nil for a column
    /// cut off in a deeper solid, through which no heat flows.
    var back: Double?

    /// What a step needs of a column besides its capacities and conductances, with no arrays to
    /// count references to as the cores share it.
    struct Face: Sendable {
        var nodes: Int
        var absorptivity: Double
        var emissivity: Double
        /// The back face's emissivity; negative where no heat flows through the back.
        var back: Double
    }

    var face: Face {
        Face(nodes: capacity.count, absorptivity: absorptivity, emissivity: emissivity, back: back ?? -1)
    }

    static let stefanBoltzmann = 5.670_374e-8
    /// TR-BDF2's split, 2 − √2.
    static let gamma = 2 - 2.0.squareRoot()

    /// `material`'s column in front of a solid `solid` metres thick, nil without end.
    init(_ material: HeatedMaterial, solid: Float?, spec: SurfaceHeatingSpec) {
        // Each layer's extent; the last runs to the back of the solid where it has none.
        var bounds: [Double] = []
        var reach = 0.0
        var layers = material.layers
        if let solid {
            // Within the solid's own thickness.
            var used = 0.0
            var kept: [SurfaceMaterial.Layer] = []
            for layer in layers where used < Double(solid) {
                var layer = layer
                let thickness = min(Double(layer.thickness ?? .infinity), Double(solid) - used)
                layer.thickness = Float(thickness)
                used += thickness
                kept.append(layer)
            }
            layers =
                kept.isEmpty ? [SurfaceMaterial.Layer(material.layers[0].material, thickness: solid)] : kept
        }
        for layer in layers {
            reach += layer.thickness.map(Double.init) ?? .infinity
            bounds.append(reach)
        }
        let diffusivity = layers.map(\.material.diffusivity).max()!
        let deep = 4 * (diffusivity * Double(spec.horizon)).squareRoot()
        let length = min(reach, deep)
        let cells = spec.cells
        let first = min(
            (layers[0].material.diffusivity * Double(spec.resolvedTime)).squareRoot(), length / Double(cells))
        let ratio = Self.ratio(first: first, length: length, cells: cells)
        var depth = [0.0]
        var size = first
        for _ in 0..<cells {
            depth.append(depth.last! + size)
            size *= ratio
        }
        depth[cells] = length
        // Moves the nearest node onto each interface within the column.
        for bound in bounds.dropLast() where bound < length {
            let nearest = (1..<cells).min { abs(depth[$0] - bound) < abs(depth[$1] - bound) }!
            depth[nearest] = bound
        }
        depth.sort()
        func layer(at x: Double) -> ThermalMaterial {
            layers[bounds.firstIndex { x < $0 } ?? layers.count - 1].material
        }
        capacity = [Double](repeating: 0, count: cells + 1)
        conductance = []
        for i in 0..<cells {
            let width = max(depth[i + 1] - depth[i], 1e-12)
            let m = layer(at: 0.5 * (depth[i] + depth[i + 1]))
            let heat = Double(m.density) * Double(m.specificHeat) * width / 2
            capacity[i] += heat
            capacity[i + 1] += heat
            conductance.append(Double(m.conductivity) / width)
        }
        self.depth = depth
        absorptivity = Double(layers[0].material.absorptivity)
        emissivity = Double(layers[0].material.emissivity)
        back = reach <= deep ? Double(layers.last!.material.emissivity) : nil
    }

    /// The ratio by which `cells` cells, the first `first` thick, grow to fill `length`.
    static func ratio(first: Double, length: Double, cells: Int) -> Double {
        guard first * Double(cells) < length else { return 1 }
        var (low, high) = (1.0, 2.0)
        func fill(_ r: Double) -> Double { first * (pow(r, Double(cells)) - 1) / (r - 1) }
        while fill(high) < length { high *= 2 }
        for _ in 0..<100 {
            let mid = 0.5 * (low + high)
            if fill(mid) < length { low = mid } else { high = mid }
        }
        return 0.5 * (low + high)
    }

    /// Scratch space for one column's step: five rows of `nodes`.
    final class Work {
        let nodes: Int
        let buffer: UnsafeMutablePointer<Double>

        init(nodes: Int) {
            self.nodes = nodes
            buffer = .allocate(capacity: 5 * nodes)
            buffer.initialize(repeating: 0, count: 5 * nodes)
        }

        deinit { buffer.deallocate() }

        var diagonal: UnsafeMutablePointer<Double> { buffer }
        var rhs: UnsafeMutablePointer<Double> { buffer + nodes }
        var flux: UnsafeMutablePointer<Double> { buffer + 2 * nodes }
        var start: UnsafeMutablePointer<Double> { buffer + 3 * nodes }
        var stage: UnsafeMutablePointer<Double> { buffer + 4 * nodes }
    }

    /// The net heat into each node, in W/m², at temperatures `t` and absorbed-to-be irradiance `q`.
    static func heat(
        _ t: UnsafePointer<Double>, q: Double, ambient: Double, convection: Double, face: Face,
        g: UnsafePointer<Double>, into out: UnsafeMutablePointer<Double>
    ) {
        let n = face.nodes
        let sigma = Self.stefanBoltzmann
        let a4 = ambient * ambient * ambient * ambient
        out.update(repeating: 0, count: n)
        for i in 0..<n - 1 {
            let flow = g[i] * (t[i + 1] - t[i])
            out[i] += flow
            out[i + 1] -= flow
        }
        let s = t[0]
        out[0] +=
            face.absorptivity * q - convection * (s - ambient) - face.emissivity * sigma
            * (s * s * s * s - a4)
        if face.back >= 0 {
            let b = t[n - 1]
            out[n - 1] += -convection * (b - ambient) - face.back * sigma * (b * b * b * b - a4)
        }
    }

    /// Solves (scale·C + A) x = rhs, A the conduction between the nodes and the losses at the
    /// faces linearised about `about`, and adds the linearised losses' constant parts and the
    /// absorbed irradiance `q` to `rhs` first. The answer goes into `x`, which may be `about`.
    static func solve(
        scale: Double, rhs: UnsafeMutablePointer<Double>, about: UnsafePointer<Double>, q: Double,
        ambient: Double, convection: Double, face: Face, c: UnsafePointer<Double>, g: UnsafePointer<Double>,
        diagonal: UnsafeMutablePointer<Double>, x: UnsafeMutablePointer<Double>
    ) {
        let n = face.nodes
        let sigma = Self.stefanBoltzmann
        let a4 = ambient * ambient * ambient * ambient
        diagonal[0] = scale * c[0] + g[0]
        for i in 1..<n - 1 { diagonal[i] = scale * c[i] + g[i - 1] + g[i] }
        diagonal[n - 1] = scale * c[n - 1] + g[n - 2]
        // σT⁴ ≈ 4T₀³T − 3T₀⁴ about T₀.
        let s = about[0]
        diagonal[0] += convection + 4 * face.emissivity * sigma * s * s * s
        rhs[0] +=
            face.absorptivity * q + convection * ambient + face.emissivity * sigma * (3 * s * s * s * s + a4)
        if face.back >= 0 {
            let b = about[n - 1]
            diagonal[n - 1] += convection + 4 * face.back * sigma * b * b * b
            rhs[n - 1] += convection * ambient + face.back * sigma * (3 * b * b * b * b + a4)
        }
        // Thomas's algorithm; the off-diagonals are −conductance.
        for i in 1..<n {
            let m = g[i - 1] / diagonal[i - 1]
            diagonal[i] -= m * g[i - 1]
            rhs[i] += m * rhs[i - 1]
        }
        x[n - 1] = rhs[n - 1] / diagonal[n - 1]
        for i in stride(from: n - 2, through: 0, by: -1) {
            x[i] = (rhs[i] + g[i] * x[i + 1]) / diagonal[i]
        }
    }

    /// One step of `dt` by TR-BDF2, the irradiance going from `from` to `to`: the trapezium rule to
    /// γ of the way, then the second-order backward difference to the end, each implicit with the
    /// losses linearised about the temperatures it starts from. Second order and L-stable, so the
    /// fine cells at the surface neither limit the step nor ring.
    func step(
        _ t: UnsafeMutablePointer<Double>, dt: Double, from: Double, to: Double, ambient: Double,
        convection: Double, work: Work
    ) {
        capacity.withUnsafeBufferPointer { c in
            conductance.withUnsafeBufferPointer { g in
                Self.step(
                    t, dt: dt, from: from, to: to, ambient: ambient, convection: convection, work: work,
                    face: face, c: c.baseAddress!, g: g.baseAddress!)
            }
        }
    }

    /// As `step`, given the column's face, capacities `c` and conductances `g`.
    static func step(
        _ t: UnsafeMutablePointer<Double>, dt: Double, from: Double, to: Double, ambient: Double,
        convection: Double, work: Work, face: Face, c: UnsafePointer<Double>, g: UnsafePointer<Double>
    ) {
        let n = face.nodes
        let gamma = Self.gamma
        let (rhs, start, stage) = (work.rhs, work.start, work.stage)
        heat(t, q: from, ambient: ambient, convection: convection, face: face, g: g, into: work.flux)
        start.update(from: t, count: n)
        // The trapezium rule: 2C/(γΔt) (T* − Tₙ) = f(Tₙ) + f(T*).
        let first = 2 / (gamma * dt)
        for i in 0..<n { rhs[i] = first * c[i] * t[i] + work.flux[i] }
        solve(
            scale: first, rhs: rhs, about: start, q: from + (to - from) * gamma, ambient: ambient,
            convection: convection, face: face, c: c, g: g, diagonal: work.diagonal, x: stage)
        // The backward difference: C/(wΔt) Tₙ₊₁ − f(Tₙ₊₁) = C/(wΔt) (a T* − b Tₙ).
        let w = (1 - gamma) / (2 - gamma)
        let a = 1 / (gamma * (2 - gamma))
        let b = (1 - gamma) * (1 - gamma) / (gamma * (2 - gamma))
        let second = 1 / (w * dt)
        for i in 0..<n { rhs[i] = second * c[i] * (a * stage[i] - b * start[i]) }
        solve(
            scale: second, rhs: rhs, about: stage, q: to, ambient: ambient, convection: convection,
            face: face,
            c: c, g: g, diagonal: work.diagonal, x: t)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
