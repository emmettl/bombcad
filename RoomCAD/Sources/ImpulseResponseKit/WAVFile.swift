import Foundation

/// Reads and writes interleaved 32-bit IEEE float WAV files.
///
/// Mono and stereo files use `WAVE_FORMAT_IEEE_FLOAT` with a `fact` chunk. Files with more than two
/// channels use `WAVE_FORMAT_EXTENSIBLE` with no speaker mask, because response channels are paths
/// between a source and receivers rather than loudspeaker feeds.
public enum WAVFile {
    static let formatIEEEFloat: UInt16 = 3
    static let formatExtensible: UInt16 = 0xFFFE
    /// KSDATAFORMAT_SUBTYPE_IEEE_FLOAT, as stored in the file.
    static let floatSubformat: [UInt8] = [
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71,
    ]
    /// Larger files need RF64, which is not implemented.
    static let maximumDataBytes = Int(UInt32.max) - 1024

    public static func encode(channels: [[Float]], sampleRate: Int) throws -> Data {
        guard let frames = channels.first?.count, channels.allSatisfy({ $0.count == frames }) else {
            throw ImpulseResponseError.invalid("A WAV file needs at least one channel, all the same length.")
        }
        guard channels.count <= Int(UInt16.max), sampleRate > 0, sampleRate <= Int(UInt32.max) else {
            throw ImpulseResponseError.invalid("Unsupported channel count or sample rate.")
        }
        guard channels.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw ImpulseResponseError.invalid("Cannot write non-finite samples.")
        }
        let count = channels.count
        let dataBytes = frames * count * 4
        guard dataBytes <= maximumDataBytes else {
            throw ImpulseResponseError.invalid("The response is too long for a WAV file.")
        }
        let extensible = count > 2
        var out = Data()
        out.reserveCapacity(dataBytes + 80)
        out.append(contentsOf: Array("RIFF".utf8))
        let fmtSize = extensible ? 40 : 18
        // WAVE + fmt chunk + fact chunk + data chunk header + payload.
        out.append(le32(4 + (8 + fmtSize) + 12 + 8 + dataBytes))
        out.append(contentsOf: Array("WAVEfmt ".utf8))
        out.append(le32(fmtSize))
        out.append(le16(extensible ? formatExtensible : formatIEEEFloat))
        out.append(le16(count))
        out.append(le32(sampleRate))
        out.append(le32(sampleRate * count * 4))
        out.append(le16(count * 4))
        out.append(le16(32))
        if extensible {
            out.append(le16(22))
            out.append(le16(32))  // valid bits per sample
            out.append(le32(0))  // no speaker positions
            out.append(contentsOf: floatSubformat)
        } else {
            out.append(le16(0))
        }
        out.append(contentsOf: Array("fact".utf8))
        out.append(le32(4))
        out.append(le32(frames))
        out.append(contentsOf: Array("data".utf8))
        out.append(le32(dataBytes))
        var interleaved = [Float](repeating: 0, count: frames * count)
        for (c, samples) in channels.enumerated() {
            for i in 0..<frames { interleaved[i * count + c] = samples[i] }
        }
        // Apple platforms are little-endian, matching the file's byte order.
        interleaved.withUnsafeBytes { out.append(contentsOf: $0) }
        return out
    }

    public static func decode(_ data: Data) throws -> (sampleRate: Int, channels: [[Float]]) {
        let bytes = [UInt8](data)
        func fail(_ message: String) -> ImpulseResponseError {
            .invalid("Not a readable float WAV: \(message).")
        }
        guard bytes.count >= 12, tag(bytes, 0) == "RIFF", tag(bytes, 8) == "WAVE" else {
            throw fail("missing RIFF/WAVE header")
        }
        var offset = 12
        var format: (channels: Int, sampleRate: Int)?
        var payload: Range<Int>?
        while offset + 8 <= bytes.count {
            let id = tag(bytes, offset)
            let size = Int(read32(bytes, offset + 4))
            let body = offset + 8
            guard size <= bytes.count - body else { throw fail("truncated \(id) chunk") }
            if id == "fmt " {
                guard size >= 16 else { throw fail("short format chunk") }
                var code = read16(bytes, body)
                let channels = Int(read16(bytes, body + 2))
                let sampleRate = Int(read32(bytes, body + 4))
                let bits = read16(bytes, body + 14)
                if code == formatExtensible {
                    guard size >= 40, Array(bytes[(body + 24)..<(body + 40)]) == floatSubformat else {
                        throw fail("extensible format is not IEEE float")
                    }
                    code = formatIEEEFloat
                }
                guard code == formatIEEEFloat, bits == 32 else { throw fail("samples are not 32-bit float") }
                guard channels > 0, sampleRate > 0 else { throw fail("invalid channel count or rate") }
                format = (channels, sampleRate)
            } else if id == "data" {
                payload = body..<(body + size)
            }
            offset = body + size + (size & 1)
        }
        guard let format else { throw fail("no format chunk") }
        guard let payload else { throw fail("no data chunk") }
        let frameBytes = format.channels * 4
        guard payload.count % frameBytes == 0 else { throw fail("partial frame in data chunk") }
        let frames = payload.count / frameBytes
        var channels = [[Float]](repeating: [Float](repeating: 0, count: frames), count: format.channels)
        for i in 0..<frames {
            for c in 0..<format.channels {
                let position = payload.lowerBound + (i * format.channels + c) * 4
                channels[c][i] = Float(bitPattern: read32(bytes, position))
            }
        }
        return (format.sampleRate, channels)
    }

    private static func tag(_ bytes: [UInt8], _ offset: Int) -> String {
        String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * UInt32($1)) }
    }

    private static func le16(_ value: some BinaryInteger) -> Data {
        let v = UInt16(truncatingIfNeeded: value)
        return Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    private static func le32(_ value: some BinaryInteger) -> Data {
        let v = UInt32(truncatingIfNeeded: value)
        return Data((0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xFF) })
    }
}
