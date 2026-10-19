import Foundation
import simd

/// One charge's fireball in spherical shells, as an early frame takes it from the mapped start's
/// one-dimensional solution: each shell's luminous temperature (zero where it is not luminous),
/// the unburnt products in it that make soot, and its absorption as hot air. The thermal volume
/// marches rays through these exactly, crossing shell by shell, in place of the frame's voxels: a
/// shock's hot front one shell thick against the soot-black products behind it is a voxel thick
/// at best, and the voxels' interpolation gives most of it the products' cooler radiance.
public struct FireballSphere: Sendable, Equatable {
    public var centre: SIMD3<Float>
    /// Each shell's thickness, in metres; shell `n` lies between `n` and `n + 1` of them out.
    public var shellSize: Float
    public var temperatures: [Float]
    public var products: [Float]
    public var airAbsorption: [Float]

    public init(
        centre: SIMD3<Float>, shellSize: Float, temperatures: [Float], products: [Float],
        airAbsorption: [Float]
    ) {
        precondition(temperatures.count == products.count && temperatures.count == airAbsorption.count)
        self.centre = centre
        self.shellSize = shellSize
        self.temperatures = temperatures
        self.products = products
        self.airAbsorption = airAbsorption
    }

    /// The sphere's outer radius, in metres.
    public var radius: Float { Float(temperatures.count) * shellSize }
}

extension FireballSphere: Codable {
    private enum CodingKeys: String, CodingKey {
        case centre, shellSize, shells
    }

    /// As JSON: the centre and shell size, then the shells' temperatures, products and
    /// absorptions as little-endian floats, in base64.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let centre = try values.decode(SIMD3<Float>.self, forKey: .centre)
        let shellSize = try values.decode(Float.self, forKey: .shellSize)
        let data = try values.decode(Data.self, forKey: .shells)
        guard data.count % 12 == 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .shells, in: values, debugDescription: "The fireball's shells arrived cut short.")
        }
        let count = data.count / 12
        let floats = data.withUnsafeBytes { raw in
            (0..<(3 * count)).map {
                Float(
                    bitPattern: UInt32(
                        littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)))
            }
        }
        self.init(
            centre: centre, shellSize: shellSize, temperatures: Array(floats[0..<count]),
            products: Array(floats[count..<(2 * count)]), airAbsorption: Array(floats[(2 * count)...]))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(centre, forKey: .centre)
        try values.encode(shellSize, forKey: .shellSize)
        var data = Data(capacity: 12 * temperatures.count)
        for value in temperatures + products + airAbsorption {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        try values.encode(data, forKey: .shells)
    }
}

/// The spheres as the march takes them, under a spec: each shell's absorption coefficient and
/// black-body radiance.
struct SphericalMedium: Sendable {
    struct Sphere: Sendable {
        var centre: SIMD3<Float>
        var shellSize: Float
        var radius: Float
        /// κ (1/m) and B = σT⁴/π each shell; zero where it is not luminous.
        var shells: [SIMD2<Float>]
    }

    var spheres: [Sphere]

    init(_ spheres: [FireballSphere], spec: ThermalSpec) {
        let sigma = Float(ThermalExposure.stefanBoltzmann / Double.pi)
        let soot = ThermalMedium.sootAbsorption * spec.sootYield / ThermalMedium.sootDensity
        self.spheres = spheres.map { sphere in
            let shells = sphere.temperatures.indices.map { n -> SIMD2<Float> in
                let t = sphere.temperatures[n]
                guard t > 0 else { return .zero }
                let air = spec.hotAirAbsorption ? sphere.airAbsorption[n] : 0
                let kappa = spec.absorption + soot * sphere.products[n] * t + air
                return SIMD2(kappa, sigma * t * t * t * t)
            }
            return Sphere(
                centre: sphere.centre, shellSize: sphere.shellSize, radius: sphere.radius, shells: shells)
        }
    }

    /// The radiance reaching `origin` along `direction` from the spheres, out to `limit`: each
    /// sphere's chord, nearest first, crossed shell by shell, the gas in each piece taken at the
    /// shell it lies in, until less than 10⁻⁴ of what lies beyond could get through.
    func radiance(from origin: SIMD3<Float>, along direction: SIMD3<Float>, limit: Float) -> Float {
        var chords: [(enter: Float, leave: Float, closest: Float, impact: Float, sphere: Int)] = []
        for (n, sphere) in spheres.enumerated() {
            let offset = origin - sphere.centre
            let closest = -simd_dot(offset, direction)
            let impact = max(simd_length_squared(offset) - closest * closest, 0)
            let reach = sphere.radius * sphere.radius - impact
            guard reach > 0 else { continue }
            let half = reach.squareRoot()
            let enter = max(closest - half, 0)
            let leave = min(closest + half, limit)
            if enter < leave { chords.append((enter, leave, closest, impact.squareRoot(), n)) }
        }
        chords.sort { $0.enter < $1.enter }
        var radiance: Float = 0
        var through: Float = 1
        for chord in chords {
            let sphere = spheres[chord.sphere]
            let size = sphere.shellSize
            let count = sphere.shells.count
            // Where the ray crosses each shell's outer boundary, coming in and going out.
            let innermost = min(Int(chord.impact / size), count - 1)
            var crossings: [Float] = []
            crossings.reserveCapacity(2 * (count - innermost) + 2)
            for k in stride(from: count, to: innermost, by: -1) {
                let r = Float(k) * size
                crossings.append(chord.closest - max(r * r - chord.impact * chord.impact, 0).squareRoot())
            }
            for k in (innermost + 1)...count {
                let r = Float(k) * size
                crossings.append(chord.closest + max(r * r - chord.impact * chord.impact, 0).squareRoot())
            }
            var from = chord.enter
            for crossing in crossings where crossing > from {
                let to = min(crossing, chord.leave)
                let middle = 0.5 * (from + to) - chord.closest
                let r = (chord.impact * chord.impact + middle * middle).squareRoot()
                let shell = sphere.shells[min(Int(r / size), count - 1)]
                if shell.x > 0 {
                    let passed = exp(-shell.x * (to - from))
                    radiance += through * shell.y * (1 - passed)
                    through *= passed
                    if through < 1e-4 { return radiance }
                }
                from = to
                if from >= chord.leave { break }
            }
        }
        return radiance
    }
}
