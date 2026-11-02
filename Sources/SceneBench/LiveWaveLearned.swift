import BlastCore
import BlastModel
import Foundation
import simd

/// The live blast wave's learned refinement (`LiveWave.Refinement`, emmettl/bombcad-work#115;
/// docs/live-wave.md) on the GPU, where `blastmodel`, with no Metal, cannot run it.
///
/// - `scenebench live-wave-judge --learned weights.bcfw <blastmodel live-wave-judge's arguments>`:
///   the judge, each run's wave refined by the network before it is set against the run.
/// - `scenebench live-wave-time --learned weights.bcfw <blastmodel live-wave-time's arguments>`:
///   a recompute on a laid-out district as the app does it, with the refinement, timed.
/// - `scenebench live-wave-predict --learned weights.bcfw --features pair/c1 --out corrections.npy`:
///   the network's corrections on one training pair's features, for checking against PyTorch.
enum LiveWaveLearned {
    static func refinement(_ args: [String]) throws -> LiveWave.Refinement {
        guard let path = SurrogateBench.value(args, "learned") else {
            throw BlastError.allocationFailed(
                "--learned weights.bcfw (Scripts/ml/export_live_wave_weights.py)")
        }
        // `--blend 700,1200`: whole within the first distance, m, eased to the plain wave at the
        // second; `--blend default` the app's; without it, everywhere.
        var blend: ClosedRange<Float>?
        if let text = SurrogateBench.value(args, "blend") {
            if text == "default" {
                blend = LiveWave.Refinement.defaultBlend
            } else {
                let ends = text.split(separator: ",").compactMap { Float($0) }
                guard ends.count == 2, ends[0] >= 0, ends[1] > ends[0] else {
                    throw BlastError.allocationFailed("--blend near,far in metres, or default")
                }
                blend = ends[0]...ends[1]
            }
        }
        return try LiveWave.Refinement(
            network: LearnedFieldNetwork(contentsOf: URL(filePath: path)), blend: blend)
    }

    static func judge(_ args: [String]) throws {
        let refinement = try refinement(args)
        try LiveWaveJudge.run(args) { field, plan, charge, mass in
            try refinement.refined(field, plan: plan, charge: charge, mass: mass)
        }
    }

    static func time(_ args: [String]) throws {
        let refinement = try refinement(args)
        try LiveWaveJudge.time(args) { field, plan, charge, mass in
            try refinement.refined(field, plan: plan, charge: charge, mass: mass)
        }
    }

    static func predict(_ args: [String]) throws {
        let value = { (name: String) in SurrogateBench.value(args, name) }
        guard let folder = value("features"), let out = value("out") else {
            throw BlastError.allocationFailed("--features pair-folder and --out corrections.npy")
        }
        let refinement = try refinement(args)
        let (features, shape) = try LearnedField.readNPY(
            URL(filePath: folder).appending(path: "features.npy"))
        let (rows, columns) = (shape[1], shape[2])
        let header = refinement.network.header
        let (inputs, paddedRows, paddedColumns) = LiveWave.standardisedInputs(
            features, rows: rows, columns: columns, header: header)
        let outs = try refinement.network.outputChannels(
            inputs: inputs, rows: paddedRows, columns: paddedColumns)
        var values = [Float](repeating: 0, count: outs.count * rows * columns)
        for (k, channel) in outs.enumerated() {
            for j in 0..<rows {
                for i in 0..<columns {
                    values[k * rows * columns + i + columns * j] = channel[i + paddedColumns * j]
                }
            }
        }
        try NPY.write(values, shape: [outs.count, rows, columns], to: URL(filePath: out))
        print("\(outs.count) corrections over \(rows) × \(columns) written to \(out)")
    }
}
