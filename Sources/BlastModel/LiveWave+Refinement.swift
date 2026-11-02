import Foundation
import simd

// MARK: - The learned refinement

extension LiveWave {
    /// The live wave's learned refinement (emmettl/bombcad-work#115; docs/live-wave.md): a U-Net
    /// trained on BombCAD's own 4 m district runs of made-up districts (Scripts/ml/train_live_wave.py)
    /// that corrects the wave's peak, arrival and impulse cell by cell, from the plan and the wave's
    /// own fields: its path round and over buildings, and the strength and time it gives there. Its
    /// outputs are logarithms of the run's over the wave's, so a correction of nothing is the wave
    /// as it was. The impulse is carried by the Friedlander decay, the positive phase kept, or the
    /// phase stretched where a pulse of no decay is still too small.
    ///
    /// The app's default since 2 November 2026, within about 1 km of the charge (`defaultBlend`);
    /// run by BlastCore's `LearnedFieldNetwork` on the GPU from a `.bcfw` file of
    /// its weights, with no group norms, so that a cell gets the same whatever the plan's size.
    public struct Refinement: Sendable {
        /// The inputs it was trained on, in order, as `features` lays them out.
        public static let inputs = [
            "height", "footprint", "ground", "logPathScaledDistance", "pathExcess",
            "logStraightScaledDistance",
            "logLivePeak", "logLiveScaledArrival", "cellM",
        ]
        /// Its outputs: the logs of the run's peak, arrival and impulse over the live wave's.
        public static let outputs = ["logPeakRatio", "logArrivalRatio", "logImpulseRatio"]
        /// The largest correction taken, as a log, each output's: a factor of e^1.5 (4.5) on the
        /// peak and impulse and e^0.5 (1.65) on the arrival. The network's own stay well inside.
        public static let limits: [Float] = [1.5, 0.5, 1.5]

        public let network: any LearnedField.Network
        /// Where it is taken, by straight-line distance from the charge, m: whole within the lower
        /// end, eased to nothing at the upper; everywhere with nil.
        public var blend: ClosedRange<Float>?

        /// The app's blend, adopted on 2 November 2026 (docs/live-wave.md, "Adopted as the
        /// default"): whole within 700 m, the plain wave from 1,200 m. Beyond about 1 km the network
        /// reads Beirut's shielded peaks low, as the made-up districts' runs do there.
        public static let defaultBlend: ClosedRange<Float> = 700...1200

        /// How much of the correction a cell `distance` m from the charge takes under `blend`.
        static func weight(at distance: Float, blend: ClosedRange<Float>?) -> Float {
            guard let blend else { return 1 }
            if distance <= blend.lowerBound { return 1 }
            if distance >= blend.upperBound { return 0 }
            let t = (distance - blend.lowerBound) / (blend.upperBound - blend.lowerBound)
            return 1 - t * t * (3 - 2 * t)
        }

        /// Its standing, worded from the standing table's figures (docs/live-wave.md, "The learned
        /// refinement").
        public static let standing: [String] = {
            let sight = ValidationTables.figure("liveWaveLearnedPeakSight")
            let shielded = ValidationTables.figure("liveWaveLearnedPeakShielded")
            let near = ValidationTables.figure("liveWaveLearnedNearShielded")
            let arrival = ValidationTables.figure("liveWaveLearnedArrivalShielded")
            return [
                "\(EvidenceLevel.illustrative.title). An estimate, not a run: the live wave corrected cell by cell by a "
                    + "network trained on BombCAD's own 4 m runs of made-up districts, whole within 700 m of the charge "
                    + "and eased to the plain wave by 1,200 m.",
                String(
                    format:
                        "Against Beirut's 4 m runs it was never trained on, 2 m over the ground: peaks within ×1.25 on %.0f%% of cells "
                        + "in sight and %.0f%% behind buildings, %.0f%% of those within 100 m (%.0f%% without it); "
                        + "arrivals beyond 200 m %.1f–%.1f%% out on average behind buildings.",
                    100 * sight.low, 100 * shielded.low, 100 * near.high, 100 * near.low, 100 * arrival.low,
                    100 * arrival.high),
                "Its pulse carries the runs' positive impulse where it is taken. Beyond 1 km, where it would read low "
                    + "as the made-up districts' runs do, it gives way to the plain wave. It is the 4 m runs' wave, as "
                    + "the live wave is.",
            ]
        }()

        public init(network: any LearnedField.Network, blend: ClosedRange<Float>? = nil) throws {
            guard network.header.isLiveWave, network.header.headCount == Self.outputs.count else {
                throw LearnedFieldError.badWeights(
                    "not the live wave's refinement: inputs \(network.header.inputs)")
            }
            self.network = network
            self.blend = blend
        }

        /// `field`, worked out on `plan` for a charge of `mass` kg at `charge`, refined: its peak,
        /// arrival, duration and decay corrected; its paths kept. `seconds` takes the time this
        /// took as well, and `refinementSeconds` says it.
        public func refined(_ field: Field, plan: Plan, charge: SIMD3<Float>, mass: Double) throws -> Field {
            let start = ContinuousClock.now
            let header = network.header
            let raw = LiveWave.features(field: field, plan: plan, charge: charge, mass: mass)
            let (inputs, rows, columns) = LiveWave.standardisedInputs(
                raw, rows: plan.rows, columns: plan.columns, header: header)
            let outs = try network.outputChannels(inputs: inputs, rows: rows, columns: columns)
            guard outs.count == Self.outputs.count, outs.allSatisfy({ $0.count == rows * columns }) else {
                throw LearnedFieldError.network("\(outs.map(\.count)) outputs for 3 of \(rows) × \(columns)")
            }
            var refined = LiveWave.corrected(field, by: outs, columns: columns, blend: blend)
            let took = (ContinuousClock.now - start) / .seconds(1)
            refined.refinementSeconds = took
            refined.seconds = field.seconds + took
            return refined
        }
    }

    /// The refinement's raw inputs (`Refinement.inputs`) over `plan` for `field`, channels × rows
    /// × columns: the height, the footprint, the ground over the ground under the charge, ln Z of
    /// the path and of the straight line, the path's excess ln(L/R), the logs of the wave's peak
    /// (Pa) and of its arrival over W^(1/3) (s/kg^(1/3)), and the cell's size, m. A cell the wave
    /// never reaches takes the straight line's.
    public static func features(field: Field, plan: Plan, charge: SIMD3<Float>, mass: Double) -> [Float] {
        let count = plan.columns * plan.rows
        let channels = Refinement.inputs.count
        let root = cbrt(max(mass, 1e-6))
        let ci = min(max(Int(charge.x / plan.cell), 0), plan.columns - 1)
        let cj = min(max(Int(charge.y / plan.cell), 0), plan.rows - 1)
        let chargeGround = plan.ground[ci + plan.columns * cj]
        let near = 0.5 * Double(plan.cell)
        let table = Table.shared
        var out = [Float](repeating: 0, count: channels * count)
        out.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: plan.rows) { j in
                for i in 0..<plan.columns {
                    let n = i + plan.columns * j
                    let straight = Double(field.straight[n])
                    let reached = field.path[n].isFinite && field.arrival[n].isFinite
                    let path = reached ? Double(field.path[n]) : straight
                    let logZPath = log(max(path, near) / root)
                    let logZStraight = log(max(straight, near) / root)
                    let excess = min(max(log(max(path, 1e-3) / max(straight, 1e-3)), 0), 3)
                    let peak: Double
                    let arrival: Double
                    if reached {
                        peak = Double(field.peak[n])
                        arrival = Double(field.arrival[n])
                    } else {
                        let kb = table.at(logZ: logZStraight)
                        peak = kb.peak
                        arrival = kb.scaledArrival * root
                    }
                    let h = plan.height[n]
                    out[0 * count + n] = h
                    out[1 * count + n] = h > 0 ? 1 : 0
                    out[2 * count + n] = plan.ground[n] - chargeGround
                    out[3 * count + n] = Float(logZPath)
                    out[4 * count + n] = Float(excess)
                    out[5 * count + n] = Float(logZStraight)
                    out[6 * count + n] = Float(log(max(peak, 1)))
                    out[7 * count + n] = Float(log(max(arrival / root, 1e-6)))
                    out[8 * count + n] = plan.cell
                }
            }
        }
        return out
    }

    /// `raw`'s channels standardised by `header`'s statistics and padded at the north and east to
    /// a multiple of `header.multiple` by repeating the edge, as the training pads them.
    public static func standardisedInputs(
        _ raw: [Float], rows: Int, columns: Int, header: LearnedField.Weights.Header
    ) -> (inputs: [Float], rows: Int, columns: Int) {
        let channels = header.inputs.count
        let plan = rows * columns
        precondition(raw.count == channels * plan, "a value a channel and cell")
        let multiple = max(1, header.multiple)
        let paddedRows = (rows + multiple - 1) / multiple * multiple
        let paddedColumns = (columns + multiple - 1) / multiple * multiple
        let area = paddedRows * paddedColumns
        let mean = header.stats.mean.map(Float.init)
        let scale = header.stats.std.map { 1 / Float($0) }
        var inputs = [Float](repeating: 0, count: channels * area)
        inputs.withUnsafeMutableBufferPointer { out in
            raw.withUnsafeBufferPointer { raw in
                concurrently(iterations: paddedRows) { r in
                    let j = min(r, rows - 1)
                    for k in 0..<channels {
                        let (m, s) = (mean[k], scale[k])
                        let from = k * plan + columns * j
                        let to = k * area + paddedColumns * r
                        for c in 0..<paddedColumns {
                            out[to + c] = (raw[from + min(c, columns - 1)] - m) * s
                        }
                    }
                }
            }
        }
        return (inputs, paddedRows, paddedColumns)
    }

    /// `field` with the corrections `outs` (the logs of peak, arrival and impulse, each over a plan
    /// `columns` wide, padded) taken, each held within `Refinement.limits`: the peak and arrival
    /// scaled; the impulse by the Friedlander decay at the same positive phase, or, where even no
    /// decay gives too little, by a longer phase with none.
    ///
    /// With `blend`, each correction is taken whole within its lower end of straight-line distance
    /// from the charge, m, and eased to nothing at its upper end (a smoothstep), the plain wave
    /// beyond.
    static func corrected(
        _ field: Field, by outs: [[Float]], columns: Int, blend: ClosedRange<Float>? = nil
    ) -> Field {
        var refined = field
        let limits = Refinement.limits
        let straight = field.straight
        let decay = DecayTable.shared
        refined.arrival.withUnsafeMutableBufferPointer { arrival in
            refined.peak.withUnsafeMutableBufferPointer { peak in
                refined.duration.withUnsafeMutableBufferPointer { duration in
                    refined.decay.withUnsafeMutableBufferPointer { b in
                        concurrently(iterations: field.rows) { j in
                            for i in 0..<field.columns {
                                let n = i + field.columns * j
                                guard arrival[n].isFinite, duration[n] > 0 else { continue }
                                let m = i + columns * j
                                let w = Refinement.weight(at: straight[n], blend: blend)
                                guard w > 0 else { continue }
                                let dp = w * min(max(outs[0][m], -limits[0]), limits[0])
                                let da = w * min(max(outs[1][m], -limits[1]), limits[1])
                                let di = w * min(max(outs[2][m], -limits[2]), limits[2])
                                peak[n] *= exp(dp)
                                arrival[n] *= exp(da)
                                // The pulse kept where the impulse moves with the peak.
                                guard di != dp else { continue }
                                // The wave's own impulse share of peak × phase, then the run's.
                                let share = Float(DecayTable.share(Double(b[n]))) * exp(di - dp)
                                if share < 0.5 {
                                    b[n] = decay.decay(forShare: share)
                                } else {
                                    duration[n] *= share / 0.5
                                    b[n] = 0
                                }
                            }
                        }
                    }
                }
            }
        }
        refined.lastArrival = refined.arrival.lazy.filter(\.isFinite).max() ?? 0
        refined.refined = true
        return refined
    }

    /// The Friedlander decay b for a share of peak × phase (`Table.decay`), tabulated over the
    /// shares a pulse can have, for a field's million cells.
    struct DecayTable: Sendable {
        static let size = 4096
        /// The share at b = 50, the largest decay taken.
        static let smallest = share(50)
        let entries: [Float]

        static let shared = DecayTable()

        init() {
            entries = (0..<Self.size).map { k in
                let share = Self.smallest + (0.5 - Self.smallest) * Double(k) / Double(Self.size - 1)
                return Float(Table.decay(share))
            }
        }

        /// The impulse over peak × phase of the pulse of decay `b`: 1/b − (1 − e^(−b))/b².
        static func share(_ b: Double) -> Double { b < 1e-4 ? 0.5 - b / 6 : 1 / b - (1 - exp(-b)) / (b * b) }

        func decay(forShare share: Float) -> Float {
            let u = (Double(share) - Self.smallest) / (0.5 - Self.smallest) * Double(Self.size - 1)
            guard u > 0 else { return entries[0] }
            let k = min(Int(u), Self.size - 2)
            let f = Float(min(u - Double(k), 1))
            return entries[k] + f * (entries[k + 1] - entries[k])
        }
    }
}

// MARK: - Where the weights are

extension LiveWave.Refinement {
    /// The environment variable naming the weights' file, and the file's own name.
    public static let environmentKey = "BOMBCAD_LIVE_WAVE_MODEL"
    public static let fileName = "live-wave-unet-1.bcfw"

    /// Where the weights are read from: `BOMBCAD_LIVE_WAVE_MODEL` if set, else `setting` (the app's),
    /// else `fallback`.
    public static func weightsURL(
        setting: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment,
        fallback: URL = defaultWeightsURL
    ) -> URL {
        if let path = environment[environmentKey], !path.isEmpty {
            return URL(filePath: (path as NSString).expandingTildeInPath)
        }
        if let setting, !setting.isEmpty { return URL(filePath: (setting as NSString).expandingTildeInPath) }
        return fallback
    }

    /// Beside the learned field model's weights in Application Support.
    public static var defaultWeightsURL: URL {
        LearnedField.defaultWeightsURL.deletingLastPathComponent().appending(path: fileName)
    }

    /// The weights' release: the one file the app offers to download the first time the option is
    /// turned on (never without the user's click), checked against its SHA-256 before it is kept,
    /// as the learned field model's are (docs/live-wave.md).
    public enum Release {
        public static let tag = "live-wave-model-1"
        /// The width-32 network of 2 November 2026 (`live-wave-w32`, epoch 73).
        public static let asset = LearnedField.Release.Asset(
            file: fileName, bytes: 15_702_546,
            sha256: "4041d39729910a40190ccd50408a1699cde4d08fa9c4739038f95785167e4f26", tag: tag)

        /// What the download is for, in the words the app asks with.
        public static var offer: String {
            "The learned refinement corrects the live blast wave's peak, arrival and pulse towards "
                + "BombCAD's own district runs (illustrative). Its weights, "
                + LearnedField.Release.megabytes(asset.bytes) + ", are downloaded once from the repository's "
                + "\(tag) release (" + asset.url.absoluteString + ") and kept in Application Support."
        }
    }
}
