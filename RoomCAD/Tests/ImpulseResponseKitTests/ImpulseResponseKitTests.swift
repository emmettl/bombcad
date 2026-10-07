import Foundation
import ImpulseResponseKit
import Testing

@Suite("Impulse-response files and conditioning")
struct ImpulseResponseKitTests {
    private func response(channels: [[Float]]) throws -> ImpulseResponse {
        let metadata = ResponseMetadata(
            sampleRate: 48_000, frameCount: channels[0].count,
            channels: channels.indices.map {
                .init(
                    name: "Receiver \($0)", sourceID: UUID(), receiverID: UUID(), receiverPosition: [1, 2, 3])
            },
            content: .complete, gainConvention: "Test", usableBand: .init(lowerHz: 20, upperHz: 20_000),
            model: "Test", assumptions: [], generator: "Tests")
        return try ImpulseResponse(channels: channels, metadata: metadata)
    }

    @Test("Stereo float WAV has the standard header and round trips exactly")
    func stereoRoundTrip() throws {
        let channels: [[Float]] = [[0, 0.5, -0.25, 1e-7], [1, -1, 0.125, -3e-9]]
        let data = try WAVFile.encode(channels: channels, sampleRate: 48_000)
        #expect(data.count == 12 + 26 + 12 + 8 + 4 * 2 * 4)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(data[20] == 3 && data[21] == 0)  // WAVE_FORMAT_IEEE_FLOAT
        #expect(data[22] == 2)  // channels
        let decoded = try WAVFile.decode(data)
        #expect(decoded.sampleRate == 48_000)
        #expect(decoded.channels == channels)
    }

    @Test("Four-path responses use the extensible float format and round trip")
    func extensibleRoundTrip() throws {
        let channels: [[Float]] = (0..<4).map { c in (0..<5).map { Float(c * 10 + $0) / 64 } }
        let data = try WAVFile.encode(channels: channels, sampleRate: 96_000)
        #expect(data[20] == 0xFE && data[21] == 0xFF)
        #expect(try WAVFile.decode(data).channels == channels)
    }

    @Test("Unknown chunks and odd padding are skipped when reading")
    func skipsUnknownChunks() throws {
        var data = try WAVFile.encode(channels: [[0.25, -0.5]], sampleRate: 44_100)
        let insert = Data("LIST".utf8) + Data([3, 0, 0, 0, 1, 2, 3, 0])
        data.insert(contentsOf: insert, at: 12)
        let size = UInt32(data.count - 8)
        data.replaceSubrange(4..<8, with: (0..<4).map { UInt8((size >> (8 * UInt32($0))) & 0xFF) })
        #expect(try WAVFile.decode(data).channels == [[0.25, -0.5]])
    }

    @Test("Non-finite samples, integer PCM and truncated files are rejected")
    func rejectsInvalid() throws {
        #expect(throws: ImpulseResponseError.self) {
            try WAVFile.encode(channels: [[.nan]], sampleRate: 48_000)
        }
        var pcm = try WAVFile.encode(channels: [[0]], sampleRate: 48_000)
        pcm[20] = 1
        #expect(throws: ImpulseResponseError.self) { try WAVFile.decode(pcm) }
        let full = try WAVFile.encode(channels: [[0, 1, 2]], sampleRate: 48_000)
        #expect(throws: ImpulseResponseError.self) { try WAVFile.decode(full.prefix(full.count - 2)) }
    }

    @Test("A common gain keeps channel ratios and is recorded")
    func commonGain() throws {
        var ir = try response(channels: [[0, 0.2, 0.1], [0.4, -0.1, 0]])
        try ir.normalizePeak(to: 0.8)
        #expect(ir.peak == 0.8)
        #expect(abs(ir.channels[0][1] / ir.channels[1][0] - 0.5) < 1e-6)
        #expect(abs(ir.metadata.commonGain - 2) < 1e-6)
        #expect(ir.metadata.processing.map(\.kind) == ["commonGain"])
    }

    @Test("Removing leading delay shifts the emission frame for every channel")
    func trimming() throws {
        var ir = try response(channels: [[0, 0, 1, 0], [0, 0, 0, 1]])
        try ir.removeLeadingFrames(2)
        #expect(ir.channels == [[1, 0], [0, 1]])
        #expect(ir.metadata.emissionFrame == -2)
        #expect(ir.frameCount == 2)
        #expect(throws: ImpulseResponseError.self) { try ir.removeLeadingFrames(2) }
    }

    @Test("A fade-out reaches silence and leaves earlier samples alone")
    func fade() throws {
        var ir = try response(channels: [Array(repeating: 1, count: 4_800)])
        try ir.fadeOut(seconds: 0.01)
        #expect(ir.channels[0][4_800 - 481] == 1)
        #expect(ir.channels[0].last == 0)
    }

    @Test("Responses and metadata round trip through files, with generator details alongside")
    func files() throws {
        struct Details: Codable { var note: String }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("room.wav")
        let ir = try response(channels: [[0, 0.5], [0.25, 0]])
        try ir.write(wav: url, generatorDetails: Details(note: "kept"))
        #expect(try ImpulseResponse.read(wav: url) == ir)
        let json = try String(contentsOf: ImpulseResponse.metadataURL(for: url), encoding: .utf8)
        #expect(json.contains("\"note\" : \"kept\""))
        #expect(json.contains("dev.roomcad.impulse-response"))
    }
}
