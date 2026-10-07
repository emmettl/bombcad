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
    /// Where the coefficients come from, or that they are illustrative.
    public var reference: String

    public init(name: String, absorption: [Double], reference: String) {
        self.name = name
        self.absorption = absorption
        self.reference = reference
    }

    /// The same coefficient in every band.
    public static func uniform(_ alpha: Double, name: String, reference: String = "Illustrative") -> Self {
        Self(name: name, absorption: Array(repeating: alpha, count: OctaveBands.count), reference: reference)
    }

    public static let rigid = uniform(0, name: "Rigid", reference: "Ideal: no absorption")
    public static let anechoic = uniform(1, name: "Anechoic", reference: "Ideal: total absorption")

    /// Pressure reflection coefficient per band, assumed real and positive: `sqrt(1 - alpha)`.
    public var reflection: [Double] { absorption.map { sqrt(max(0, 1 - $0)) } }

    func validate() throws {
        guard absorption.count == OctaveBands.count else {
            throw AcousticError.invalid(
                "\(name) needs \(OctaveBands.count) octave-band absorption coefficients.")
        }
        guard absorption.allSatisfy({ (0...1).contains($0) }) else {
            throw AcousticError.invalid("\(name) has an absorption coefficient outside 0 to 1.")
        }
    }
}

/// A rectangular room with one material per surface.
public struct ShoeboxRoom: Codable, Equatable, Sendable {
    /// Interior dimensions in metres.
    public var size: SIMD3<Double>
    public var west, east, south, north, floor, ceiling: SurfaceMaterial

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

    public var volume: Double { size.x * size.y * size.z }

    public func area(_ surface: Surface) -> Double {
        switch surface {
        case .west, .east: size.y * size.z
        case .south, .north: size.x * size.z
        case .floor, .ceiling: size.x * size.y
        }
    }

    public var surfaceArea: Double { Surface.allCases.reduce(0) { $0 + area($1) } }

    /// Whether a point lies strictly inside the room.
    public func contains(_ point: SIMD3<Double>) -> Bool {
        all(point .> 0) && all(point .< size)
    }

    func validate() throws {
        guard size.x.isFinite, size.y.isFinite, size.z.isFinite, all(size .>= 0.5), all(size .<= 500) else {
            throw AcousticError.invalid("Room dimensions must be between 0.5 m and 500 m.")
        }
        for surface in Surface.allCases { try self[surface].validate() }
    }

    /// Sabine reverberation time per band in seconds, or nil where nothing absorbs.
    public func sabineReverberationTime(atmosphere: Atmosphere, airAbsorption: Bool) -> [Double?] {
        statisticalDecay(atmosphere: atmosphere, airAbsorption: airAbsorption) { band in
            Surface.allCases.reduce(0) { $0 + area($1) * self[$1].absorption[band] }
        }
    }

    /// Eyring reverberation time per band in seconds, or nil where nothing absorbs.
    public func eyringReverberationTime(atmosphere: Atmosphere, airAbsorption: Bool) -> [Double?] {
        statisticalDecay(atmosphere: atmosphere, airAbsorption: airAbsorption) { band in
            let total = surfaceArea
            let mean = Surface.allCases.reduce(0) { $0 + area($1) * self[$1].absorption[band] } / total
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
