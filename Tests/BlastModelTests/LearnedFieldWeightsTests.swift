import Foundation
import Testing

@testable import BlastModel

/// A `.bcfw` file that is corrupt, truncated or of another network is refused with an error, never
/// read out of bounds or trapped on (emmettl/bombcad-work#67): the app reads any file a path names
/// (`BOMBCAD_FIELD_MODEL`, the setting), and only the release's download is checked by its SHA-256.
@Suite("Learned field weights' file")
struct LearnedFieldWeightsTests {
    /// A U-Net of width 2 and depth 1 as export_field_weights.py writes it, with `change` made to
    /// its header and each tensor's entry first.
    static func file(
        header change: (inout [String: Any]) -> Void = { _ in },
        entry: (String, inout [String: Any]) -> Void = { _, _ in }
    ) throws -> Data {
        let shapes = LearnedField.Weights.tensorShapes(width: 2, depth: 1)
        var entries: [[String: Any]] = []
        var values: [UInt16] = []
        for name in LearnedField.Weights.tensorNames(depth: 1) {
            let shape = shapes[name]!
            let count = shape.reduce(1, *)
            var e: [String: Any] = ["name": name, "shape": shape, "offset": values.count, "count": count]
            entry(name, &e)
            entries.append(e)
            values += (0..<count).map { UInt16(0x3C00 + $0 % 7) }
        }
        var header: [String: Any] = [
            "format": "bombcad-field-weights-1", "model": "unet", "width": 2, "depth": 1,
            "inputs": LearnedField.Weights.inputs,
            "stats": ["mean": [0, 0, 1, 2, 3, 4], "std": [1, 1, 1, 1, 1, 2]], "residual": true,
            "multiple": 2, "groupNormGroups": 8, "groupNormEpsilon": 1e-5, "dtype": "float16",
            "tensors": entries,
        ]
        change(&header)
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

    @Test("The file as exported reads, and its tensors have the network's shapes")
    func reads() throws {
        let weights = try LearnedField.Weights(data: Self.file())
        #expect(weights.tensors["down.0.body.0.weight"]?.shape == [2, 6, 3, 3])
        #expect(weights.tensors["up.0.body.0.weight"]?.shape == [2, 6, 3, 3])
        #expect(weights.tensors["down.1.body.3.weight"]?.shape == [4, 4, 3, 3])
        #expect(weights.tensors["head.weight"].map { Array($0.values.prefix(2)) } == [1, 1 + 0x1p-10])
        // Read from a slice of a larger buffer, as a mapped file may be.
        let padded = try Data([0, 1, 2]) + Self.file()
        #expect(try LearnedField.Weights(data: padded.dropFirst(3)).tensors.count == 26)
        // The shipped model's shapes: width 32, depth 4, 7.9 M values, which with its header of
        // 9,248 bytes make the release's 15,716,144 (`LearnedField.Release.ground.bytes`) in
        // float16; the levels network's nine levels, two outputs each, with its header of 10,176,
        // its 15,718,128 (`Release.levels.bytes`).
        let shipped = LearnedField.Weights.tensorShapes(width: 32, depth: 4)
        let values = shipped.values.map { $0.reduce(1, *) }.reduce(0, +)
        #expect(values == 7_853_442 && 12 + 9_248 + 2 * values == LearnedField.Release.ground.bytes)
        let levels = LearnedField.Weights.tensorShapes(width: 32, depth: 4, outputs: 18).values.map {
            $0.reduce(1, *)
        }.reduce(0, +)
        #expect(12 + 10_176 + 2 * levels == LearnedField.Release.levels.bytes)
    }

    @Test("A file cut short anywhere is refused")
    func truncated() throws {
        let data = try Self.file()
        for length in 0..<data.count {
            #expect(throws: (any Error).self) { try LearnedField.Weights(data: data.prefix(length)) }
        }
    }

    @Test("A header whose tensors lie outside the payload, or overflow, is refused")
    func outside() throws {
        let cases: [(String, Any, Any?)] = [
            ("offset", -1, nil), ("offset", -1_000_000, nil), ("offset", Int.max, nil),
            ("count", -2, [-2]), ("count", Int.max, [Int.max]), ("count", 0, [Int.max, 2]),
            ("count", 4, [-2, -2]),
        ]
        for (key, value, shape) in cases {
            let data = try Self.file(entry: { name, e in
                guard name == "head.bias" else { return }
                e[key] = value
                if let shape { e["shape"] = shape }
            })
            #expect(throws: LearnedFieldError.self, "\(key) \(value) \(shape ?? "")") {
                try LearnedField.Weights(data: data)
            }
        }
        // The header's length past the file's end.
        var data = try Self.file()
        withUnsafeBytes(of: UInt32(data.count).littleEndian) { data.replaceSubrange(8..<12, with: $0) }
        #expect(throws: LearnedFieldError.self) { try LearnedField.Weights(data: data) }
    }

    @Test("Weights of another shape, width or depth than the header's are refused")
    func otherNetwork() throws {
        let wrongShape = try Self.file(entry: { name, e in
            if name == "down.0.body.0.weight" {
                e["shape"] = [2, 5, 3, 3]
                e["count"] = 90
            }
        })
        #expect(throws: LearnedFieldError.self) { try LearnedField.Weights(data: wrongShape) }
        for change: (inout [String: Any]) -> Void in [
            { $0["width"] = 4 }, { $0["depth"] = 2 }, { $0["multiple"] = 16 }, { $0["depth"] = 0 },
            { $0["width"] = 0 },
        ] {
            #expect(throws: LearnedFieldError.self) {
                try LearnedField.Weights(data: Self.file(header: change))
            }
        }
    }

    @Test("A standardisation with a zero or non-finite deviation is refused")
    func standardisation() throws {
        for std in [[1, 1, 1, 0, 1, 1], [1, 1, 1, -1, 1, 1]] {
            let data = try Self.file(header: { $0["stats"] = ["mean": [0, 0, 0, 0, 0, 0], "std": std] })
            #expect(throws: LearnedFieldError.self) { try LearnedField.Weights(data: data) }
        }
    }

    @Test("A .npy file cut short is refused")
    func shortNPY() throws {
        let fixture = LearnedFieldEncodingTests.fixture.appending(path: "kb-log-peak.npy")
        let data = try Data(contentsOf: fixture)
        let scratch = FileManager.default.temporaryDirectory.appending(
            path: "learned-field-\(UUID().uuidString).npy")
        defer { try? FileManager.default.removeItem(at: scratch) }
        for length in [0, 5, 9, 10, 11, 64, 127, 128, data.count - 1] {
            try data.prefix(length).write(to: scratch)
            #expect(throws: LearnedFieldError.self, "\(length) bytes") { try LearnedField.readNPY(scratch) }
        }
        try data.write(to: scratch)
        #expect(try LearnedField.readNPY(scratch).shape == [37, 23])
    }
}
