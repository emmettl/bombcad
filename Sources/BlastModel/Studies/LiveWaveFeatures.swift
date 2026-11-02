import Foundation
import simd

/// The live wave's learned refinement's training pairs (emmettl/bombcad-work#115;
/// docs/live-wave.md).
///
/// `blastmodel live-wave-features --runs dir[,dir…] --out dataset [--coarsen 1,2] [--only ids]`:
/// for each `scenebench field-export --arrival` run, the live wave (`LiveWave.field`, the fitted
/// terms) worked out on the run's own plan, and on it coarsened as the app coarsens a large
/// district while the charge is dragged, and written as `dataset/runs/<id>/c<k>/`:
///
/// - `features.npy`, channels × rows × columns: `LiveWave.features`, the refinement's inputs
///   (`LiveWave.Refinement.inputs`);
/// - `targets.npy`, 3 × rows × columns: the logs of the run's peak, arrival and impulse over the
///   wave's, NaN where the run has none there (out of its mask, its arrival not recorded); on a
///   coarsened plan, the mean of the logs of its cells' run values, less the log of the wave's;
/// - `sight.npy`, rows × columns: 1 in sight of the charge, 0 shielded, as the judge counts them;
/// - `meta.json`: the run, its layout and mass, the cells and the coarsening.
///
/// Scripts/ml/train_live_wave.py trains on them.
extension LiveWaveJudge {
    package static func features(_ args: [String]) throws {
        let value = { (name: String) in SurrogateBench.value(args, name) }
        guard let dirs = value("runs"), let out = value("out") else {
            throw BlastError.allocationFailed(
                "--runs folder[,folder…] of field-export runs and --out dataset")
        }
        let coarsenings = (value("coarsen") ?? "1,2").split(separator: ",").compactMap { Int($0) }
        let only = value("only").map { Set($0.split(separator: ",").map(String.init)) }
        var folders: [URL] = []
        for dir in dirs.split(separator: ",") {
            let url = URL(filePath: String(dir))
            for name in try FileManager.default.contentsOfDirectory(atPath: url.path).sorted() {
                let folder = url.appending(path: name)
                guard FileManager.default.fileExists(atPath: folder.appending(path: "arrival.npy").path)
                else {
                    continue
                }
                if let only, !only.contains(name) { continue }
                folders.append(folder)
            }
        }
        guard !folders.isEmpty else {
            throw BlastError.allocationFailed("field-export --arrival runs under \(dirs)")
        }
        var written = 0
        for folder in folders {
            let run = try read(folder)
            let root = URL(filePath: out).appending(path: "runs").appending(path: run.id)
            for k in coarsenings {
                let clock = ContinuousClock.now
                let target = root.appending(path: "c\(k)")
                if FileManager.default.fileExists(atPath: target.appending(path: "meta.json").path) {
                    continue
                }
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                let pair = Self.pair(run, coarsen: k)
                let (nx, ny) = (pair.plan.columns, pair.plan.rows)
                try writeNPY(
                    pair.features, shape: [LiveWave.Refinement.inputs.count, ny, nx],
                    to: target.appending(path: "features.npy"))
                try writeNPY(pair.targets, shape: [3, ny, nx], to: target.appending(path: "targets.npy"))
                try writeNPY(pair.sight, shape: [ny, nx], to: target.appending(path: "sight.npy"))
                let meta: [String: Any] = [
                    "format": "bombcad-live-wave-pair-1", "id": run.id, "layout": run.layout,
                    "massKg": run.mass,
                    "charge": [run.charge.x, run.charge.y, run.charge.z], "coarsen": k,
                    "cellSizeM": pair.plan.cell, "rows": ny, "columns": nx,
                    "inputs": LiveWave.Refinement.inputs, "targets": LiveWave.Refinement.outputs,
                    "coefficients": "fitted",
                    "cells": [
                        "peak": pair.targets[0..<(nx * ny)].filter(\.isFinite).count,
                        "arrival": pair.targets[(nx * ny)..<(2 * nx * ny)].filter(\.isFinite).count,
                        "impulse": pair.targets[(2 * nx * ny)...].filter(\.isFinite).count,
                    ],
                ]
                try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                    .write(to: target.appending(path: "meta.json"))
                written += 1
                print(
                    String(
                        format: "%@ c%d: %d × %d, %.1f s", run.id, k, nx, ny,
                        (ContinuousClock.now - clock) / .seconds(1)))
            }
        }
        print("\(written) pairs written under \(out)")
    }

    /// One run's training pair on its plan coarsened `k` times: the refinement's inputs, its
    /// targets and the cells in sight.
    static func pair(_ run: Run, coarsen k: Int) -> (
        plan: LiveWave.Plan, features: [Float], targets: [Float], sight: [Float]
    ) {
        let plan = k > 1 ? coarsened(run.plan, by: k) : run.plan
        let field = LiveWave.field(plan: plan, charge: run.charge, mass: run.mass)
        let features = LiveWave.features(field: field, plan: plan, charge: run.charge, mass: run.mass)
        let (nx, ny) = (plan.columns, plan.rows)
        let count = nx * ny
        let fine = run.plan.columns
        var targets = [Float](repeating: .nan, count: 3 * count)
        var sight = [Float](repeating: 0, count: count)
        targets.withUnsafeMutableBufferPointer { out in
            sight.withUnsafeMutableBufferPointer { sight in
                concurrently(iterations: ny) { j in
                    for i in 0..<nx {
                        let n = i + nx * j
                        sight[n] = inSight(plan, charge: run.charge, cell: n) ? 1 : 0
                        guard field.arrival[n].isFinite, field.peak[n] > 0, field.duration[n] > 0 else {
                            continue
                        }
                        let impulse =
                            Double(field.peak[n]) * Double(field.duration[n])
                            * LiveWave.DecayTable.share(Double(field.decay[n]))
                        var sums = [0.0, 0.0, 0.0]
                        var counts = [0, 0, 0]
                        for b in 0..<k {
                            for a in 0..<k {
                                let m = (i * k + a) + fine * (j * k + b)
                                guard run.mask[m] > 0 else { continue }
                                if run.peak[m] > 0 {
                                    sums[0] += log(Double(run.peak[m]))
                                    counts[0] += 1
                                }
                                if run.impulse[m] > 0 {
                                    sums[2] += log(Double(run.impulse[m]))
                                    counts[2] += 1
                                }
                                if let arrival = run.arrival?[m], arrival.isFinite, arrival > 0 {
                                    sums[1] += log(Double(arrival))
                                    counts[1] += 1
                                }
                            }
                        }
                        let live = [log(Double(field.peak[n])), log(Double(field.arrival[n])), log(impulse)]
                        for t in 0..<3 where counts[t] > 0 {
                            out[t * count + n] = Float(sums[t] / Double(counts[t]) - live[t])
                        }
                    }
                }
            }
        }
        return (plan, features, targets, sight)
    }

    /// A `.npy` file (format 1.0) of little-endian float32 in C order, as `scenebench
    /// field-export` writes them.
    static func writeNPY(_ values: [Float], shape: [Int], to url: URL) throws {
        precondition(values.count == shape.reduce(1, *), "the values fill the shape")
        let dims = shape.map(String.init).joined(separator: ", ") + (shape.count == 1 ? "," : "")
        var text = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(dims)), }"
        let unpadded = 10 + text.utf8.count + 1
        text += String(repeating: " ", count: (64 - unpadded % 64) % 64) + "\n"
        var data = Data([0x93] + Array("NUMPY".utf8) + [1, 0])
        let length = UInt16(text.utf8.count)
        data.append(contentsOf: [UInt8(length & 0xff), UInt8(length >> 8)])
        data.append(contentsOf: Array(text.utf8))
        data.reserveCapacity(data.count + 4 * values.count)
        for value in values {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: url)
    }
}
