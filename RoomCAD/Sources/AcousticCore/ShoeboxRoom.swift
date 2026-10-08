import Foundation

public enum AcousticError: LocalizedError, Equatable {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

/// The six boundaries of a rectangular room whose interior spans `[0, size]`, z up.
public enum Surface: String, CaseIterable, Codable, Sendable {
    /// x = 0
    case west
    /// x = size.x
    case east
    /// y = 0
    case south
    /// y = size.y
    case north
    /// z = 0
    case floor
    /// z = size.z
    case ceiling
}

/// Acoustic properties of a surface finish. Unrelated to structural material properties.
public struct SurfaceMaterial: Codable, Equatable, Sendable {
    public var name: String
    /// Energy absorption coefficient in each octave band of `OctaveBands`, from 0 (rigid) to 1.
    public var absorption: [Double]
    /// Scattering coefficient in each octave band, from 0 (mirror-like) to 1: the fraction of the
    /// reflected energy that leaves diffusely rather than specularly (ISO 17497-1).
    public var scattering: [Double]
    /// Where the coefficients come from, or that they are illustrative.
    public var reference: String

    public init(name: String, absorption: [Double], scattering: [Double]? = nil, reference: String) {
        self.name = name
        self.absorption = absorption
        self.scattering = scattering ?? Array(repeating: 0, count: absorption.count)
        self.reference = reference
    }

    /// The same coefficients in every band.
    public static func uniform(
        _ alpha: Double, scattering: Double = 0, name: String, reference: String = "Illustrative"
    ) -> Self {
        Self(
            name: name, absorption: Array(repeating: alpha, count: OctaveBands.count),
            scattering: Array(repeating: scattering, count: OctaveBands.count), reference: reference)
    }

    public static let rigid = uniform(0, name: "Rigid", reference: "Ideal: no absorption")
    public static let anechoic = uniform(1, name: "Anechoic", reference: "Ideal: total absorption")

    /// Pressure reflection coefficient of the specular part per band, assumed real and positive:
    /// `sqrt((1 - alpha)(1 - s))`. The scattered energy is modelled separately.
    public var reflection: [Double] {
        zip(absorption, scattering).map { sqrt(max(0, 1 - $0) * max(0, 1 - $1)) }
    }

    var scatters: Bool { scattering.contains { $0 > 0 } }

    enum CodingKeys: String, CodingKey {
        case name, absorption, scattering, reference
    }

    /// Materials saved before scattering existed decode as purely specular.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        absorption = try container.decode([Double].self, forKey: .absorption)
        scattering =
            try container.decodeIfPresent([Double].self, forKey: .scattering)
            ?? Array(repeating: 0, count: absorption.count)
        reference = try container.decode(String.self, forKey: .reference)
    }

    func validate() throws {
        guard absorption.count == OctaveBands.count, scattering.count == OctaveBands.count else {
            throw AcousticError.invalid(
                "\(name) needs \(OctaveBands.count) octave-band absorption and scattering coefficients.")
        }
        guard absorption.allSatisfy({ (0...1).contains($0) }) else {
            throw AcousticError.invalid("\(name) has an absorption coefficient outside 0 to 1.")
        }
        guard scattering.allSatisfy({ (0...1).contains($0) }) else {
            throw AcousticError.invalid("\(name) has a scattering coefficient outside 0 to 1.")
        }
    }
}

/// A room: a rectangular box with one material per surface, or, with a `plan`, any floor plan with
/// vertical walls between a flat floor and ceiling.
public struct ShoeboxRoom: Codable, Equatable, Sendable {
    /// Interior dimensions in metres; with a plan, its bounding box and the height.
    public var size: SIMD3<Double>
    /// Box walls, unused when there is a plan.
    public var west, east, south, north: SurfaceMaterial
    public var floor, ceiling: SurfaceMaterial
    /// A floor plan with its own walls, or nil for a box. Its corners lie within `[0, size.x] × [0, size.y]`.
    public var plan: FloorPlan?
    /// A room of any shape, which takes the place of the box's surfaces and any plan. Its corners lie
    /// within `[0, size]`.
    public var mesh: RoomMesh?

    public init(size: SIMD3<Double>, material: SurfaceMaterial) {
        self.size = size
        (west, east, south, north, floor, ceiling) = (
            material, material, material, material, material, material
        )
    }

    public subscript(surface: Surface) -> SurfaceMaterial {
        get {
            switch surface {
            case .west: west
            case .east: east
            case .south: south
            case .north: north
            case .floor: floor
            case .ceiling: ceiling
            }
        }
        set {
            switch surface {
            case .west: west = newValue
            case .east: east = newValue
            case .south: south = newValue
            case .north: north = newValue
            case .floor: floor = newValue
            case .ceiling: ceiling = newValue
            }
        }
    }

    public var volume: Double { mesh?.volume ?? (plan?.area ?? size.x * size.y) * size.z }

    public func area(_ surface: Surface) -> Double {
        switch surface {
        case .west, .east: size.y * size.z
        case .south, .north: size.x * size.z
        case .floor, .ceiling: size.x * size.y
        }
    }

    public var surfaceArea: Double { boundaries.reduce(0) { $0 + $1.area } }

    /// Whether any surface scatters in any band.
    public var scatters: Bool { boundaries.contains { $0.material.scatters } }

    /// Whether a point lies strictly inside the room.
    public func contains(_ point: SIMD3<Double>) -> Bool {
        guard all(point .> 0) && all(point .< size) else { return false }
        if let mesh { return MeshGeometry.of(mesh).contains(point) }
        return plan?.contains([point.x, point.y]) ?? true
    }

    /// Shortest distance from a point inside the room to its boundary.
    public func clearance(_ point: SIMD3<Double>) -> Double {
        if let mesh { return MeshGeometry.of(mesh).clearance(point) }
        let vertical = min(point.z, size.z - point.z)
        guard let plan else { return min(vertical, point.x, point.y, size.x - point.x, size.y - point.y) }
        return min(vertical, plan.distanceToWalls([point.x, point.y]))
    }

    func validate() throws {
        guard size.x.isFinite, size.y.isFinite, size.z.isFinite, all(size .>= 0.5), all(size .<= 500) else {
            throw AcousticError.invalid("Room dimensions must be between 0.5 m and 500 m.")
        }
        for surface in Surface.allCases { try self[surface].validate() }
        if let mesh {
            guard plan == nil else {
                throw AcousticError.invalid("A room has either a floor plan or a mesh, not both.")
            }
            try mesh.validate()
            let (low, high) = mesh.bounds
            guard all(low .>= -1e-9), all(high .<= size + 1e-9) else {
                throw AcousticError.invalid("The room's mesh must lie within its size.")
            }
        }
        if let plan {
            try plan.validate()
            let (low, high) = plan.bounds
            guard all(low .>= -1e-9), high.x <= size.x + 1e-9, high.y <= size.y + 1e-9 else {
                throw AcousticError.invalid("The floor plan must lie within the room's length and width.")
            }
        }
    }

    /// Sabine reverberation time per band in seconds, or nil where nothing absorbs.
    public func sabineReverberationTime(atmosphere: Atmosphere, airAbsorption: Bool) -> [Double?] {
        statisticalDecay(atmosphere: atmosphere, airAbsorption: airAbsorption) { band in
            boundaries.reduce(0) { $0 + $1.area * $1.material.absorption[band] }
        }
    }

    /// Eyring reverberation time per band in seconds, or nil where nothing absorbs.
    public func eyringReverberationTime(atmosphere: Atmosphere, airAbsorption: Bool) -> [Double?] {
        statisticalDecay(atmosphere: atmosphere, airAbsorption: airAbsorption) { band in
            let total = surfaceArea
            let mean = boundaries.reduce(0) { $0 + $1.area * $1.material.absorption[band] } / total
            return mean >= 1 ? .infinity : -total * log(1 - mean)
        }
    }

    /// `T = 24 ln(10) V / (c (A + 4 m V))`, with `m` the energy attenuation of air per metre.
    private func statisticalDecay(
        atmosphere: Atmosphere, airAbsorption: Bool, absorptionArea: (Int) -> Double
    ) -> [Double?] {
        let c = atmosphere.soundSpeed
        return OctaveBands.centres.indices.map { band in
            let air =
                airAbsorption
                ? 2 * atmosphere.amplitudeAttenuationPerMetre(frequency: OctaveBands.centres[band]) : 0
            let area = absorptionArea(band) + 4 * air * volume
            return area > 0 ? 24 * log(10) * volume / (c * area) : nil
        }
    }
}
