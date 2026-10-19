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
