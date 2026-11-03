import Foundation

extension LiveResponse {
    /// The ranges the networks were trained over (emmettl/bombcad-work#118; docs/learned-models.md,
    /// "What lies outside the training, on the CPU"): each network's inputs' 0.1% and 99.9% points
    /// over its training's rows, written by `Scripts/ml/corpus.py ranges` with the weights' SHA-256
    /// beside them (`LiveResponse+Ranges.swift`). The live drag leaves a building whose inputs lie
    /// outside them to the CPU's preview, as it leaves a construction it cannot read, rather than
    /// colour it from inputs its networks have never seen.
    public struct TrainingRanges: Sendable {
        /// One network's inputs: their names, and each one's low and high points.
        public struct Network: Sendable {
            public let names: [String]
            public let low: [Float]
            public let high: [Float]

            public init(names: [String], low: [Float], high: [Float]) {
                self.names = names
                self.low = low
                self.high = high
            }
        }

        /// The SHA-256 of the weights, and of the glass thrown's, the ranges were written for.
        public let weightsSHA256: String
        public let thrownSHA256: String?
        public let networks: [String: Network]

        public init(weightsSHA256: String, thrownSHA256: String?, networks: [String: Network]) {
            self.weightsSHA256 = weightsSHA256
            self.thrownSHA256 = thrownSHA256
            self.networks = networks
        }

        /// The built-in ranges, where they were written for the built-in weights (nil otherwise:
        /// then nothing is left to the CPU for its range).
        public static var forBuiltInWeights: TrainingRanges? {
            builtIn.weightsSHA256 == Weights.embeddedSHA256
                && builtIn.thrownSHA256 == Weights.embeddedThrownSHA256 ? builtIn : nil
        }

        /// How far beyond its training's range an input may lie, in the network's own deviations of
        /// it (`Weights.Network.std`), before it counts as outside: one, the check's own
        /// (`LiveResponseRangeTests`).
        public static let deviations: Float = 1

        /// For each of `rows`' rows of `name`'s inputs, the input furthest outside the range by more
        /// than `deviations` (−1 for a row within it, or for a network the ranges or `weights` have
        /// not got). An input not finite is outside.
        public func outside(_ name: String, rows: [Float], weights: Weights) -> [Int32] {
            guard let range = networks[name], let network = weights.header.networks[name],
                range.names.count == network.inputs, range.low.count == network.inputs,
                range.high.count == network.inputs
            else {
                return []
            }
            let width = network.inputs
            let count = width == 0 ? 0 : rows.count / width
            var out = [Int32](repeating: -1, count: count)
            let std = network.std.map(Float.init)
            let limit = Self.deviations
            rows.withUnsafeBufferPointer { x in
                out.withUnsafeMutableBufferPointer { result in
                    concurrently(iterations: (count + 255) / 256) { chunk in
                        for r in (chunk * 256)..<min(count, (chunk + 1) * 256) {
                            var furthest = limit
                            var which: Int32 = -1
                            for k in 0..<width {
                                let v = x[r * width + k]
                                guard v.isFinite else {
                                    which = Int32(k)
                                    break
                                }
                                let beyond = max(v - range.high[k], range.low[k] - v, 0) / std[k]
                                if beyond > furthest {
                                    furthest = beyond
                                    which = Int32(k)
                                }
                            }
                            result[r] = which
                        }
                    }
                }
            }
            return out
        }

        /// What the drag leaves to the CPU of a look's rows: the buildings (by their index in the
        /// look's) with any row outside, and the inputs that put them there, "network input", with
        /// the number of buildings each did. `components`, `sides` and `buildings` are the
        /// networks' rows (empty for a part not shown); `componentOwner` and `sideOwner` each row's
        /// building, and the buildings' rows are the buildings' own, in order. The glass network's
        /// rows are read against the glass thrown's ranges too, where the weights have its network.
        public func buildingsOutside(
            components: [Float], componentOwner: [Int], sides: [Float], sideOwner: [Int], buildings: [Float],
            buildingCount: Int, weights: Weights
        ) -> (outside: [Bool], inputs: [String: Int]) {
            var outside = [Bool](repeating: false, count: buildingCount)
            var inputs: [String: Set<Int>] = [:]
            func mark(_ name: String, _ rows: [Float], owner: (Int) -> Int) {
                guard !rows.isEmpty else { return }
                for (r, k) in self.outside(name, rows: rows, weights: weights).enumerated() where k >= 0 {
                    let b = owner(r)
                    guard outside.indices.contains(b) else { continue }
                    outside[b] = true
                    inputs["\(name) \(networks[name]!.names[Int(k)])", default: []].insert(b)
                }
            }
            mark("component", components) { componentOwner[$0] }
            mark("side", sides) { sideOwner[$0] }
            if weights.header.networks["thrown"] != nil { mark("thrown", sides) { sideOwner[$0] } }
            mark("building", buildings) { $0 }
            return (outside, inputs.mapValues(\.count))
        }

        /// The inputs that left buildings to the CPU (`buildingsOutside`'s), in a few plain words, most
        /// buildings first: their panels' sizes, the loads on them, or their shapes.
        public static func words(_ inputs: [String: Int]) -> [String] {
            var counts: [String: Int] = [:]
            for (key, count) in inputs {
                let input = key.split(separator: " ").last.map(String.init) ?? key
                let word =
                    ["panelHeight", "span", "oneWaySpan"].contains { input.contains($0) }
                    ? "their panels' sizes"
                    : ["load", "Peak", "Impulse", "lnZ", "lnDistance", "rise", "scatter"].contains {
                        input.contains($0)
                    } ? "the loads on them" : "their shapes"
                counts[word] = max(counts[word] ?? 0, count)
            }
            return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key)
        }
    }
}

extension FacadeLoadSurrogate.Prepared.Look {
    /// What a live look left to the CPU's preview because it lies outside the learned response's
    /// training, or judged all the same, in a line as the app says it of constructions the response
    /// cannot read; nil for none.
    public var untrainedNote: String? {
        guard leftToCPU > 0 || outsideKept > 0 else { return nil }
        let why = LiveResponse.TrainingRanges.words(outsideTraining).joined(separator: ", ")
        if outsideKept > 0 {
            return
                "\(outsideKept) of \(liveBuildings) buildings here lie outside what the learned response was trained "
                + "on (\(why)): it judges them all the same for now, to keep the drag live."
        }
        return leftToCPU == liveBuildings
            ? "Every building here lies outside what the learned response was trained on (\(why)): the preview is the SDOF's."
            : "\(leftToCPU) of \(liveBuildings) buildings here lie outside what the learned response was trained on "
                + "(\(why)): their preview is the SDOF's."
    }
}
