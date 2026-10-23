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
        let shapes = LearnedField.Weights.tensorShapes(width: 1, depth: 1)
        for name in LearnedField.Weights.tensorNames(depth: 1) {
            let shape = shapes[name]!
            let count = shape.reduce(1, *)
            entries.append(["name": name, "shape": shape, "offset": values.count, "count": count])
            values += [UInt16](repeating: 0x3C00, count: count)
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

    @Test("The release is the repository's field-model-2 assets, their hashes and sizes pinned")
    func release() {
        #expect(
            LearnedField.Release.ground.url.absoluteString
                == "https://github.com/emmettl/bombcad/releases/download/field-model-2/field-unet-fp-strict.bcfw"
        )
        #expect(LearnedField.Release.assets.allSatisfy { $0.sha256.count == 64 })
        #expect(
            LearnedField.Release.offer.contains("31.4 MB")
                && LearnedField.Release.offer.contains("https://github.com"))
    }

    /// The release's assets as prepared on StudioData, where they are.
    static let releaseFolder = URL(filePath: "/Volumes/StudioData/bombcad/release-field-model-2")

    @Test(
        "The prepared release's files pass the app's pin, fetched from file:// copies",
        .enabled(if: FileManager.default.fileExists(atPath: releaseFolder.path)))
    func preparedRelease() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = LearnedField.Release.assets.map { asset in
            var item = LearnedFieldDownload.Item(asset, to: folder.appending(path: asset.file))
            item.source = Self.releaseFolder.appending(path: asset.file)
            return item
        }
        try await LearnedFieldDownload.install(items)
        for asset in LearnedField.Release.assets {
            let kept = folder.appending(path: asset.file)
            let size = try FileManager.default.attributesOfItem(atPath: kept.path)[.size] as? Int
            #expect(size == asset.bytes)
            #expect(try LearnedFieldDownload.digest(of: kept) == asset.sha256)
        }
        #expect(
            try LearnedField.Weights(contentsOf: folder.appending(path: LearnedField.levelsFileName)).header
                .levels?.count == 9)
    }

    @Test("Two files: each fetched and checked, kept only if both pass; one already in place is not fetched")
    func both() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "first.bcfw")
        let second = folder.appending(path: "second.bcfw")
        try Self.tinyWeights().write(to: first)
        // The same weights with a byte of padding more in the header: another file, another hash.
        var other = try Self.tinyWeights()
        other.append(contentsOf: [0, 0])
        try other.write(to: second)
        let (a, b) = (try LearnedFieldDownload.digest(of: first), try LearnedFieldDownload.digest(of: second))
        #expect(a != b)
        let home = folder.appending(path: "LearnedModels")
        let items = [
            LearnedFieldDownload.Item(source: first, destination: home.appending(path: "g.bcfw"), sha256: a),
            LearnedFieldDownload.Item(source: second, destination: home.appending(path: "l.bcfw"), sha256: b),
        ]
        // The second's hash wrong: neither is kept.
        var wrong = items
        wrong[1].sha256 = String(repeating: "0", count: 64)
        await #expect(throws: LearnedFieldError.self) { try await LearnedFieldDownload.install(wrong) }
        #expect(!FileManager.default.fileExists(atPath: items[0].destination.path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? [] == [])
        // Both right: both kept.
        #expect(try await LearnedFieldDownload.install(items) == items.map(\.destination))
        #expect(items.allSatisfy { $0.isInPlace })
        // The first in place and the second gone (field model 1's install): only the second is
        // fetched, so a source for the first that no longer exists does not matter.
        try FileManager.default.removeItem(at: items[1].destination)
        var update = items
        update[0].source = folder.appending(path: "absent.bcfw")
        #expect(LearnedFieldDownload.missing(update) == [update[1]])
        #expect(try await LearnedFieldDownload.install(update) == [items[1].destination])
        #expect(items.allSatisfy { $0.isInPlace })
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: home.path).sorted() == ["g.bcfw", "l.bcfw"])
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
                sha256: LearnedField.Release.ground.sha256)
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
