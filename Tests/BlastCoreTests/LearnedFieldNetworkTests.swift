import Foundation
import Metal
import Testing

@testable import BlastCore
@testable import BlastModel

/// The learned field model's U-Net on the GPU against PyTorch's own prediction of the same held-out
/// runs (emmettl/bombcad-work#67): `Scripts/ml/export_field_weights.py --reference` writes the runs'
/// inputs and PyTorch's log peak beside the weights. The weights are not in the repository, so
/// without them (or their references) this is skipped: set `BOMBCAD_FIELD_MODEL` and
/// `BOMBCAD_FIELD_MODEL_REFERENCE`, or keep them where StudioData holds them.
@Suite("The learned field model's network against PyTorch", .gpuThreads)
struct LearnedFieldNetworkTests {
    static let weights = URL(
        filePath: ProcessInfo.processInfo.environment["BOMBCAD_FIELD_MODEL"]
            ?? "/Volumes/StudioData/bombcad/ml/field-unet-fp-strict/app/field-unet-fp-strict.bcfw")
    static let reference = URL(
        filePath: ProcessInfo.processInfo.environment["BOMBCAD_FIELD_MODEL_REFERENCE"]
            ?? "/Volumes/StudioData/bombcad/ml/field-unet-fp-strict/app/reference")
    static var available: Bool {
        MTLCreateSystemDefaultDevice() != nil && FileManager.default.fileExists(atPath: weights.path)
            && FileManager.default.fileExists(
                atPath: reference.appending(path: "beirut-p0-1.logpeak.npy").path)
    }

    @Test(
        "On Beirut's held-out run, the log peak is PyTorch's to float rounding",
        .enabled(if: LearnedFieldNetworkTests.available))
    func matchesPyTorch() throws {
        let network = try LearnedFieldNetwork(contentsOf: Self.weights)
        let (raw, shape) = try LearnedField.readNPY(Self.reference.appending(path: "beirut-p0-1.inputs.npy"))
        let (expected, _) = try LearnedField.readNPY(
            Self.reference.appending(path: "beirut-p0-1.logpeak.npy"))
        let (rows, columns) = (shape[1], shape[2])
        let (inputs, paddedRows, paddedColumns, kb) = LearnedField.networkInputs(
            exportChannels: raw, rows: rows, columns: columns, header: network.header)
        let out = try network.peakChannel(inputs: inputs, rows: paddedRows, columns: paddedColumns)
        var largest: Float = 0
        for j in 0..<rows {
            for i in 0..<columns {
                let n = i + columns * j
                largest = max(largest, abs(out[i + paddedColumns * j] + kb[n] - expected[n]))
            }
        }
        // 3e-6 when it was written (21 October 2026): float32 against float32 in another order.
        #expect(largest < 1e-4)
    }
}
