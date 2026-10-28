import BlastCore
import Foundation
import Metal
import simd

/// The learned field model in the app's quick estimate (emmettl/bombcad-work#67;
/// docs/learned-models.md):
///
/// `scenebench field-predict --weights field.bcfw --reference folder [--runs id,id]`: the Swift
/// network (`LearnedFieldNetwork`, MPSGraph) against PyTorch's prediction on the same runs, as
/// `Scripts/ml/export_field_weights.py --reference` wrote them (`<id>.inputs.npy`,
/// `<id>.logpeak.npy`): the largest and mean difference of the log peak, and the time.
///
/// `scenebench field-app <field-export's inputs> --weights field.bcfw [--radius 1024] [--height m]
/// [--check-inputs run-folder] --out strips.csv`: the app's own quick estimate of a `field-export`
/// run's district, laid out as `field-surrogate` lays it out, with the option on: the district
/// prepared (`FacadeLoadSurrogate.Prepared`) and the network's plan laid out
/// (`LearnedField.Estimator`), then `Prepared.estimate(charge:mass:learned:)`, what the app's look
/// does. Each façade strip's box goes to the CSV with the surrogate's peak and impulse
/// (`peak:surrogate`, `impulse:surrogate`), the estimate's peak with the option on (`peak:app`), and
/// whether the model gave it (`learned`): for `Scripts/ml/app_peaks.py` to judge through
/// `field-glass` and `field-walls`. `--check-inputs` compares the network's inputs laid out from
/// the scene with the run's own `inputs.npy`, to the bit.
enum FieldApp {
    static func predict(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let weights = value("weights"), let folder = value("reference") else {
            throw BlastError.allocationFailed("--weights field.bcfw --reference folder")
        }
        let network = try LearnedFieldNetwork(contentsOf: URL(filePath: weights))
        let root = URL(filePath: folder)
        let listed = try FileManager.default.contentsOfDirectory(atPath: folder).filter {
            $0.hasSuffix(".logpeak.npy")
        }.map { String($0.dropLast(".logpeak.npy".count)) }.sorted()
        let ids = value("runs")?.split(separator: ",").map(String.init) ?? listed
        for id in ids {
            let (raw, shape) = try LearnedField.readNPY(root.appending(path: "\(id).inputs.npy"))
            let (reference, _) = try LearnedField.readNPY(root.appending(path: "\(id).logpeak.npy"))
            let (rows, columns) = (shape[1], shape[2])
            var clock = ContinuousClock.now
            let (inputs, paddedRows, paddedColumns, kb) = LearnedField.networkInputs(
                exportChannels: raw, rows: rows, columns: columns, header: network.header)
            let inputsS = DistrictBenchmark.seconds(clock)
            var times: [Double] = []
            var out: [Float] = []
            for _ in 0..<3 {
                clock = .now
                out = try network.peakChannel(inputs: inputs, rows: paddedRows, columns: paddedColumns)
                times.append(DistrictBenchmark.seconds(clock))
            }
            // With more levels, every level's log peak against PyTorch's (`<id>.logpeaks.npy`).
            let levelsFile = root.appending(path: "\(id).logpeaks.npy")
            if network.header.levels != nil, FileManager.default.fileExists(atPath: levelsFile.path) {
                let (all, _) = try LearnedField.readNPY(levelsFile)
                let outs = try network.peakChannels(inputs: inputs, rows: paddedRows, columns: paddedColumns)
                for (l, level) in network.header.predicted.enumerated() {
                    var most: Float = 0
                    for j in 0..<rows {
                        for i in 0..<columns {
                            let n = i + columns * j
                            let mine = outs[l][i + paddedColumns * j] + (network.header.residual ? kb[n] : 0)
                            most = max(most, abs(mine - all[l * rows * columns + n]))
                        }
                    }
                    print(String(format: "  %@ level %@: log peak within %.2e", id, level.name, most))
                }
            }
            var largest: Float = 0
            var sum = 0.0
            for j in 0..<rows {
                for i in 0..<columns {
                    let n = i + columns * j
                    let mine = out[i + paddedColumns * j] + (network.header.residual ? kb[n] : 0)
                    let d = abs(mine - reference[n])
                    largest = max(largest, d)
                    sum += Double(d)
                }
            }
            print(
                String(
                    format:
                        "%@: %d × %d (padded %d × %d), log peak against PyTorch's within %.2e (mean %.2e); inputs %.3f s, network %@ s",
                    id, rows, columns, paddedRows, paddedColumns, largest, sum / Double(rows * columns),
                    inputsS,
                    times.map { String(format: "%.3f", $0) }.joined(separator: ", ")))
        }
    }

    static func run(_ args: [String]) throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ name: String) -> String? { SurrogateBench.value(args, name) }
        guard let out = value("out"), let weights = value("weights") else {
            throw BlastError.allocationFailed("--weights field.bcfw --out strips.csv")
        }
        let start = ContinuousClock.now
        let inputs = try DistrictInputs.read(args)
        let radius = Float(value("radius").flatMap(Double.init) ?? 1024)
        let dx = inputs.cellSize
        var layout = DistrictLayout(buildings: inputs.buildings, charge: inputs.centre, mass: inputs.mass)
        layout.ground = inputs.ground
        layout.heights = inputs.heights
        layout.seaBase = inputs.seaBase
        layout.attributions = inputs.attributions
        let (scene, report) = try layout.scene(
            halfSide: radius, cellSize: dx, height: value("height").flatMap(Float.init), name: value("id"))
        print(report.summary)
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position
        var clock = ContinuousClock.now
        let prepared = FacadeLoadSurrogate.Prepared(
            scene: scene, cellSize: dx, incidence: SurrogateBench.incidence(args))
        let preparedS = DistrictBenchmark.seconds(clock)
        clock = .now
        let estimator = LearnedField.Estimator(
            scene: scene, network: try LearnedFieldNetwork(contentsOf: URL(filePath: weights)))
        let networkLoadS = DistrictBenchmark.seconds(clock)
        if let run = value("check-inputs") {
            let (theirs, shape) = try LearnedField.readNPY(URL(filePath: run).appending(path: "inputs.npy"))
            let mine = estimator.plan.exportChannels(charge: charge, mass: mass)
            let differing = zip(mine, theirs).filter { $0.0.bitPattern != $0.1.bitPattern }.count
            print(
                "Inputs laid out from the scene against \(run)/inputs.npy (\(shape)): \(differing) of \(theirs.count) values differ"
                    + (mine.count == theirs.count ? "" : "; \(mine.count) values against \(theirs.count)"))
        }
        clock = .now
        let peaks = try estimator.peaks(charge: charge, mass: mass)
        let peaksS = DistrictBenchmark.seconds(clock)
        clock = .now
        let plain = prepared.estimate(charge: charge, mass: mass)
        let plainS = DistrictBenchmark.seconds(clock)
        clock = .now
        let learned = prepared.estimate(charge: charge, mass: mass, learned: peaks)
        let learnedS = DistrictBenchmark.seconds(clock)
        var rows: [String] = []
        var taken = 0
        var groundFloor = 0
        for (n, component) in learned.components.enumerated() where component.kind == .facade {
            let r = component.region
            let factor = learned.features[n].learnedPeakFactor
            taken += factor != 1 ? 1 : 0
            groundFloor += peaks.isGroundFloor(component) ? 1 : 0
            rows.append(
                [
                    "\(component.axis)", "\(component.outward)",
                    String(format: "%.2f", r.min.x), String(format: "%.2f", r.min.y),
                    String(format: "%.2f", r.min.z),
                    String(format: "%.2f", r.max.x), String(format: "%.2f", r.max.y),
                    String(format: "%.2f", r.max.z),
                    String(format: "%.6g", plain.predictions[n].peakPa),
                    String(format: "%.6g", plain.predictions[n].impulsePaS),
                    String(format: "%.6g", learned.predictions[n].peakPa),
                    String(format: "%.6g", learned.predictions[n].impulsePaS), factor != 1 ? "1" : "0",
                ].joined(separator: ","))
        }
        let header =
            "axis,outward,x0,y0,z0,x1,y1,z1,peak:surrogate,impulse:surrogate,peak:app,impulse:app,learned\n"
        try (header + rows.joined(separator: "\n") + "\n").write(
            to: URL(filePath: out), atomically: true, encoding: .utf8)
        // Everything but the ground-floor strips the model read is the surrogate's, to the bit.
        var unchanged = true
        for n in learned.components.indices where learned.features[n].learnedPeakFactor == 1 {
            if learned.predictions[n] != plain.predictions[n]
                || learned.loads[n].outerPa != plain.loads[n].outerPa
            {
                unchanged = false
            }
        }
        print(
            String(
                format:
                    "Wrote %@: %d façade strips, %d on the ground floor, %d of them with the model's peak; the rest the surrogate's to the bit: %@. "
                    + "Prepared %.2f s, the network loaded %.2f s and its plan laid out %.2f s, its inputs %.2f s and run %.2f s (%.2f s in all), "
                    + "the estimate %.2f s without it and %.2f s with it; %.1f s in all",
                out, rows.count, groundFloor, taken, unchanged ? "yes" : "NO", preparedS, networkLoadS,
                estimator.seconds, peaks.seconds.inputs, peaks.seconds.network, peaksS, plainS, learnedS,
                DistrictBenchmark.seconds(start)))
    }
}
