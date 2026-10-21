import Foundation
import Testing

@testable import BlastModel

/// The learned field model's inputs against the training's own (emmettl/bombcad-work#67): the
/// app's `LearnedField.networkInputs` on a plan of 37 × 23, neither a multiple of 16, against
/// train_field.py's features of the same `inputs.npy`, standardised and padded as judge_field.py
/// pads them (Fixtures/LearnedField/parity, written by Scripts/ml/test-field-model.py).
@Suite("Learned field encoding")
struct LearnedFieldEncodingTests {
    static let fixture = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appending(path: "Fixtures/LearnedField/parity")

    struct Stats: Decodable {
        var multiple: Int
        var stats: LearnedField.Weights.Header.Stats
    }

    @Test("The standardised, padded inputs are train_field.py's, to float rounding in the logs alone")
    func parity() throws {
        let (raw, rawShape) = try LearnedField.readNPY(Self.fixture.appending(path: "raw.npy"))
        let (expected, shape) = try LearnedField.readNPY(Self.fixture.appending(path: "inputs.npy"))
        let (kbExpected, _) = try LearnedField.readNPY(Self.fixture.appending(path: "kb-log-peak.npy"))
        let file = try JSONDecoder().decode(
            Stats.self, from: Data(contentsOf: Self.fixture.appending(path: "stats.json")))
        #expect(rawShape == [6, 37, 23] && shape == [6, 48, 32])
        let header = LearnedField.Weights.Header(
            format: "bombcad-field-weights-1", model: "unet", width: 32, depth: 4,
            inputs: LearnedField.Weights.inputs, stats: file.stats, residual: true, multiple: file.multiple,
            groupNormGroups: 8, groupNormEpsilon: 1e-5, dtype: "float16", tensors: [])
        let (inputs, rows, columns, kb) = LearnedField.networkInputs(
            exportChannels: raw, rows: 37, columns: 23, header: header)
        #expect(rows == 48 && columns == 32 && inputs.count == expected.count)
        let area = rows * columns
        for k in 0..<6 {
            var differing = 0
            var largest: Float = 0
            for n in 0..<area {
                let (a, b) = (inputs[k * area + n], expected[k * area + n])
                if a.bitPattern != b.bitPattern { differing += 1 }
                largest = max(largest, abs(a - b) / max(1, abs(b)))
            }
            // The height, footprint, ground and ln Z are arithmetic alone: the same to the bit. The
            // logs of Kingery–Bulmash's values may differ from NumPy's float32 log in the last place.
            if k < 4 {
                #expect(differing == 0, "channel \(k): \(differing) values differ")
            } else {
                #expect(largest < 1e-6, "channel \(k): within \(largest)")
            }
        }
        #expect(kb.count == kbExpected.count)
        #expect(zip(kb, kbExpected).allSatisfy { abs($0 - $1) <= 1e-6 * max(1, abs($1)) })
    }

    #if !(os(macOS) && arch(x86_64))
        @Test("Every half reads as the platform's own Float16 does")
        func everyHalf() {
            for bits in 0...UInt16.max {
                let ours = LearnedField.float(half: bits)
                let theirs = Float(Float16(bitPattern: bits))
                if theirs.isNaN {
                    #expect(ours.isNaN, "\(bits)")
                } else {
                    #expect(ours.bitPattern == theirs.bitPattern, "\(bits)")
                }
            }
        }
    #endif
}
