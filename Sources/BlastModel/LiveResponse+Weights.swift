import Foundation

extension LiveResponse {
    /// The networks' weights (`Scripts/ml/train_response.py`'s `export`): "BCLR", version 1, the
    /// header's length (both little-endian UInt32), a JSON header, then float32 tensors, each
    /// layer's weights (out × in, row by row) then its biases.
    public struct Weights: Sendable {
        public struct Layer: Codable, Sendable, Equatable {
            public var inputs: Int
            public var outputs: Int
            public var offset: Int
        }

        public struct Network: Codable, Sendable {
            public var inputs: Int
            public var mean: [Double]
            public var std: [Double]
            public var layers: [Layer]
            public var outputs: [String]
        }

        public struct Header: Codable, Sendable {
            public var format: String
            public var version: Int
            /// How the tensors are stored: "float16" or "float32" (nil, float32).
            public var dtype: String?
            /// The widths of a construction's and a glazing mix's inputs (`LiveResponse.constructionWidth`,
            /// `glazingWidth`): what the networks read of what a building is built of.
            public var constructionWidth: Int
            public var glazingWidth: Int
            public var slopeStep: Double
            public var sideStrips: Int
            public var buildingWalls: Int
            public var networks: [String: Network]
            /// The component network's glass-broken logit above which a pane is taken as broken (0,
            /// even odds, unless set): chosen on Beirut away from the places it is judged at.
            public var brokenThreshold: Double?
            public var trainedOn: String?
            public var epochs: Int?
            public var heldOut: String?
        }

        public var header: Header
        /// Every tensor, one after another, as the layers' offsets index them.
        public var values: [Float]

        public init(data: Data) throws {
            func fail(_ why: String) -> Error { LearnedFieldError.badWeights(why) }
            guard data.count >= 12, data.prefix(4) == Data("BCLR".utf8) else {
                throw fail("not a .bclr file")
            }
            func u32(_ at: Int) -> Int {
                data.withUnsafeBytes {
                    Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)))
                }
            }
            guard u32(4) == 2 else { throw fail("version \(u32(4)), not 2") }
            let length = u32(8)
            guard data.count >= 12 + length else { throw fail("a header longer than the file") }
            header = try JSONDecoder().decode(Header.self, from: data.subdata(in: 12..<(12 + length)))
            let body = data.subdata(in: (12 + length)..<data.count)
            switch header.dtype ?? "float32" {
            case "float32":
                values = body.withUnsafeBytes { raw in
                    (0..<(raw.count / 4)).map {
                        Float(
                            bitPattern: UInt32(
                                littleEndian: raw.loadUnaligned(fromByteOffset: 4 * $0, as: UInt32.self)))
                    }
                }
            case "float16":
                values = body.withUnsafeBytes { raw in
                    (0..<(raw.count / 2)).map {
                        LearnedField.float(
                            half: UInt16(
                                littleEndian: raw.loadUnaligned(fromByteOffset: 2 * $0, as: UInt16.self)))
                    }
                }
            default:
                throw fail("tensors of \(header.dtype ?? "")")
            }
            guard header.format == "bclr", header.slopeStep == LiveResponse.slopeStep,
                header.sideStrips == LiveResponse.sideStrips,
                header.buildingWalls == LiveResponse.buildingWalls,
                header.constructionWidth == LiveResponse.constructionWidth,
                header.glazingWidth == LiveResponse.glazingWidth
            else { throw fail("weights for other inputs") }
            for name in ["component", "side", "building"] {
                guard let network = header.networks[name], let last = network.layers.last,
                    network.mean.count == network.inputs, network.std.count == network.inputs,
                    last.offset + last.inputs * last.outputs + last.outputs <= values.count
                else { throw fail("no \(name) network, or one cut short") }
            }
        }

        public init(contentsOf url: URL) throws { try self.init(data: Data(contentsOf: url)) }

        /// The weights built into the app (`LiveResponse.embedded`), nil if there are none.
        public static let builtIn: Weights? = embeddedWeights.flatMap {
            Data(base64Encoded: $0, options: .ignoreUnknownCharacters)
        }.flatMap { try? Weights(data: $0) }

        /// Each network's rows run on the CPU: standardised, then each layer, SiLU between.
        public func run(_ name: String, rows: [Float], count: Int) -> [Float] {
            guard let network = header.networks[name], count > 0 else { return [] }
            let width = network.inputs
            let outputs = network.layers.last!.outputs
            var result = [Float](repeating: 0, count: count * outputs)
            let mean = network.mean.map(Float.init)
            let std = network.std.map(Float.init)
            values.withUnsafeBufferPointer { w in
                rows.withUnsafeBufferPointer { x in
                    result.withUnsafeMutableBufferPointer { out in
                        concurrently(iterations: (count + 255) / 256) { chunk in
                            var a = [Float](repeating: 0, count: 512)
                            var b = [Float](repeating: 0, count: 512)
                            for row in (chunk * 256)..<min(count, (chunk + 1) * 256) {
                                for k in 0..<width { a[k] = (x[row * width + k] - mean[k]) / std[k] }
                                for (l, layer) in network.layers.enumerated() {
                                    let last = l == network.layers.count - 1
                                    for o in 0..<layer.outputs {
                                        var sum = w[layer.offset + layer.inputs * layer.outputs + o]
                                        let base = layer.offset + o * layer.inputs
                                        for k in 0..<layer.inputs { sum += w[base + k] * a[k] }
                                        b[o] = last ? sum : sum / (1 + exp(-sum))
                                    }
                                    swap(&a, &b)
                                }
                                for o in 0..<outputs { out[row * outputs + o] = a[o] }
                            }
                        }
                    }
                }
            }
            return result
        }
    }
}

extension LiveResponse {
    /// The learned response's standing, worded from the standing table's figures
    /// (docs/learned-models.md, "The live drag's learned response").
    public static let standing: [String] = {
        let glass = ValidationTables.figure("livePreviewGlass")
        let walls = ValidationTables.figure("livePreviewWalls")
        let damage = ValidationTables.figure("livePreviewDamage")
        func percent(_ f: ValidationTables.Figure, _ digits: Int) -> String {
            let low = String(format: "%.\(digits)f", f.low * 100)
            let high = String(format: "%.\(digits)f", f.high * 100)
            return low == high ? "\(low)%" : "\(low)–\(high)%"
        }
        return [
            "Small networks trained on Beirut's district and four made-up ones, over the envelope model's walls, "
                + "roofs and glass, stand in for the preview's SDOF and draws: against the full "
                + "estimate on Beirut at 0.5 kt, the glass blown out came within 0.1 on \(percent(glass, 0)) of sides, "
                + "the walls' and roofs' chances on \(percent(walls, 1)) of buildings, and the damage's colour was the "
                + "same for \(percent(damage, 1)) of buildings. On a made-up district they never saw, every chance as "
                + "close, the damage colour a point or so less (docs/learned-models.md, \"Instant what-ifs\")."
        ]
    }()
}
