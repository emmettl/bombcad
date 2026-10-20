import Foundation
import Testing

@testable import BlastModel

#if canImport(Compression)
    import Compression
#endif

/// Raw Deflate decoded in Swift (`Inflate`), which reads a GeoTIFF's Deflate strips where Apple's
/// Compression framework is not: streams written by zlib, stored, fixed and dynamic.
@Suite("Inflate")
struct InflateTests {
    static let text =
        String(
            repeating:
                "The blast wave reached the facade at 34 ms; panes of 4 mm annealed glass broke at 3.45 ms "
                + "under a reflected pressure of 33 kPa, while the 6 mm panes held. ", count: 3)
        + "Kingery-Bulmash 1984."

    @Test("zlib's stored, fixed-Huffman and dynamic-Huffman blocks decode to what was written")
    func zlibStreams() throws {
        let fixed: [UInt8] = [
            203, 72, 205, 201, 201, 87, 200, 64, 144, 58, 10, 73, 57, 137, 197, 37, 200, 36, 0,
        ]
        #expect(try Inflate.decode(fixed) == Array("hello hello hello, blast blast blast".utf8))
        let stored: [UInt8] =
            [1, 24, 0, 231, 255] + Array(String(repeating: "abcdefgh", count: 3).utf8)
        #expect(try Inflate.decode(stored) == Array(String(repeating: "abcdefgh", count: 3).utf8))
        // Python's zlib at level 9, wbits −15: one dynamic-Huffman block.
        let dynamic = try #require(
            Data(
                base64Encoded:
                    "7Y5BDoIwFESvMgdQEgMYjTu3blxwgQ8dKKEU0l8k3t4iN3Dt8v+8eTOVJWonGrHKiwiUxtIgpncrjRhCIvICo94wi6diapHOEeI9xSW2S3FFHaZhh7OiTDgWbxggSdk6NjGBc6DqErgp8hzDUw5Ybe/4rTtv0r3C0pkM1X/aD9Meve8Y3sf74kZRi9P1UmQf"
            ))
        #expect((dynamic[0] >> 1) & 3 == 2)
        #expect(try Inflate.decode(Array(dynamic)) == Array(Self.text.utf8))
        #expect(throws: Inflate.Failure.self) { try Inflate.decode([203, 72, 205]) }
    }

    #if canImport(Compression)
        @Test("It decodes what Apple's Compression writes, as Apple's own decoder does")
        func againstCompression() throws {
            var generator = SystemRandomNumberGenerator()
            for size in [1, 300, 70_000] {
                // Floats like a DEM strip's: smooth, with noise.
                let floats = (0..<size).map { i in
                    Float(sin(Double(i) / 50) * 300 + Double.random(in: 0..<2, using: &generator))
                }
                let input = floats.withUnsafeBytes { Array($0) }
                var encoded = [UInt8](repeating: 0, count: input.count + 1024)
                let written = compression_encode_buffer(
                    &encoded, encoded.count, input, input.count, nil, COMPRESSION_ZLIB)
                #expect(written > 0)
                #expect(try Inflate.decode(Array(encoded.prefix(written))) == input, "\(size)")
            }
        }
    #endif
}
