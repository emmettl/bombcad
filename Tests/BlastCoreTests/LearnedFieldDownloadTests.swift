import Foundation
import Testing

@testable import BlastCore
@testable import BlastModel

/// The learned field model's weights fetched and kept (emmettl/bombcad-work#67), from a `file://`
/// stand-in: nothing here reaches the network.
@Suite("The learned field model's download")
struct LearnedFieldDownloadTests {
    /// A tiny but well-formed weights file: every tensor a U-Net of depth 1 has.
    static func tinyWeights() throws -> Data {
        var entries: [[String: Any]] = []
        var values: [UInt16] = []
        for name in LearnedField.Weights.tensorNames(depth: 1) {
            entries.append(["name": name, "shape": [1], "offset": values.count, "count": 1])
            values.append(0x3C00)
        }
        let header: [String: Any] = [
            "format": "bombcad-field-weights-1", "model": "unet", "width": 1, "depth": 1,
            "inputs": LearnedField.Weights.inputs,
            "stats": ["mean": [0, 0, 0, 0, 0, 0], "std": [1, 1, 1, 1, 1, 1]], "residual": true, "multiple": 2,
            "groupNormGroups": 8, "groupNormEpsilon": 1e-5, "dtype": "float16", "tensors": entries,
        ]
        var text = try JSONSerialization.data(withJSONObject: header)
        text.append(contentsOf: [UInt8](repeating: 0x20, count: (16 - text.count % 16) % 16))
        var data = Data("BCFW".utf8)
        for word in [UInt32(1), UInt32(text.count)] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(text)
        for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "learned-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("The release is the repository's field-model-1 asset, its hash and size pinned")
    func release() {
        #expect(
            LearnedField.Release.url.absoluteString
                == "https://github.com/emmettl/bombcad/releases/download/field-model-1/field-unet-fp-strict.bcfw"
        )
        #expect(LearnedField.Release.sha256.count == 64)
        #expect(
            LearnedField.Release.offer.contains("15.7 MB")
                && LearnedField.Release.offer.contains("https://github.com"))
    }

    @Test("A file with the pinned hash is kept, in place of one there before")
    func kept() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.bcfw")
        try Self.tinyWeights().write(to: source)
        let hash = try LearnedFieldDownload.digest(of: source)
        let destination = folder.appending(path: "LearnedModels/field.bcfw")
        try await LearnedFieldDownload.install(from: source, to: destination, sha256: hash)
        #expect(try Data(contentsOf: destination) == Data(contentsOf: source))
        // Again, over the file already there.
        try await LearnedFieldDownload.install(from: source, to: destination, sha256: hash.uppercased())
        #expect(try LearnedField.Weights(contentsOf: destination).header.depth == 1)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
                == ["field.bcfw"])
    }

    @Test("A wrong hash, a missing source or a file that is not weights leaves nothing")
    func refused() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appending(path: "source.bcfw")
        try Self.tinyWeights().write(to: source)
        let destination = folder.appending(path: "LearnedModels/field.bcfw")
        await #expect {
            try await LearnedFieldDownload.install(
                from: source, to: destination, sha256: String(repeating: "0", count: 64))
        } throws: { error in
            if case LearnedFieldError.checksum = error { return true }
            return false
        }
        await #expect {
            try await LearnedFieldDownload.install(
                from: folder.appending(path: "absent.bcfw"), to: destination,
                sha256: LearnedField.Release.sha256)
        } throws: { error in
            if case LearnedFieldError.download = error { return true }
            return false
        }
        let junk = folder.appending(path: "junk.bcfw")
        try Data("not weights".utf8).write(to: junk)
        await #expect(throws: LearnedFieldError.self) {
            try await LearnedFieldDownload.install(
                from: junk, to: destination, sha256: LearnedFieldDownload.digest(of: junk))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
