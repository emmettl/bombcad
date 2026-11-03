import Foundation
import Testing
import simd

@testable import BlastModel

/// Every built-in scene's inputs to the live response, against the ranges its built-in weights were
/// trained on (emmettl/bombcad-work#118; docs/learned-models.md, "Adding a scene or a district type").
/// The live drag's preview of 2 November read the explorer's square badly because its 2 m cells put
/// the roofs' panel height outside every training row; nothing said so until a user saw it. This
/// check says so first: a scene whose inputs leave the training's range fails, naming the inputs.
///
/// An input is out of range on a row when it lies more than one of the training's deviations
/// beyond the training's 0.1-99.9% points (`LiveResponse.TrainingRanges.builtIn`, written by
/// `Scripts/ml/corpus.py ranges` for the built-in weights into BlastModel); it is novel for a scene
/// when that is so on at least `share` of the scene's rows. Since the user's decision of 3 November
/// 2026 the live drag leaves a building with any row out of range to the CPU's preview
/// (`TrainingRanges.buildingsOutside`): such a building is no longer judged, and its rows are not
/// counted here. So `known` lists each scene's gaps among the rows still judged (none, but for a
/// scene the drag keeps on the learned response), and `leftToCPU` the share of its buildings each
/// scene leaves to the CPU; a new gap fails, and so does one that has closed (then take it off the
/// list). CPU only, a few seconds; Beirut's port is checked where its downloaded file is found
/// (`$BOMBCAD_DATA/explorer/beirut-asset`), and skipped elsewhere, as on Linux.
@Suite("Live response's training range")
struct LiveResponseRangeTests {
    /// What, changed, makes `make check-affected` run this suite besides the code it executes: the
    /// built-in weights, the scripts their data and ranges come from, and the scenes.
    static let watched = [
        "Sources/BlastModel/LiveResponse+Embedded.swift", "Sources/BlastModel/LiveResponse+Thrown.swift",
        "Sources/BlastModel/LiveResponse+Ranges.swift", "Sources/BlastModel/LiveResponse+Range.swift",
        "Sources/BlastModel/ExplorerScene.swift",
        "Sources/BlastModel/Presets.swift", "Scripts/ml/make_district.py", "Scripts/ml/train_response.py",
        "Scripts/ml/corpus.py", "Scripts/ml/embed_response.py",
    ]

    /// The charge, kg, a preset without one (a gas deflagration's) is read under.
    static let chargeless = 100.0

    /// The share of a scene's rows an input must leave the range on to count.
    static let share = 0.05

    /// What the live response is out of range on in each built-in scene now, among the rows it still
    /// judges, network by network: recorded gaps, not passes (docs/learned-models.md, "The built-in
    /// scenes checked", 3 November 2026). Since the drag leaves what lies outside to the CPU's
    /// preview, only a scene it keeps on the learned response has any: Beirut's port, on 6 m cells
    /// (the training's on 2 and 4 m), its roofs' panel height out (`ExplorerScene.keepsLearnedResponse`).
    static let known: [String: Set<String>] = [
        "explorer beirut": [
            "building roof.panelHeight", "component panelHeight",
        ]
    ]

    /// The share of each scene's buildings, over its looks, that the drag leaves to the CPU's preview
    /// for their inputs (`TrainingRanges.buildingsOutside`; none unless listed). The presets' 0.25 m
    /// cells put every building's panels far outside the training (12-16 inputs, up to 202
    /// deviations), so they are not judged at all; the process plant's buildings are read under a
    /// charge of `chargeless` kg, its gas cloud having none (which is left to the CPU's preview too).
    static let leftToCPU: [String: ClosedRange<Double>] = [
        "explorer square": 0...0.01,
        "explorer street": 0...0.01,
        "preset officeTower": 1...1,
        "preset processPlantExplosion": 1...1,
        "preset transportHub": 1...1,
    ]

    /// One network's novel inputs: name, share of rows out of range, and the furthest out (in the
    /// training's deviations beyond its range).
    struct Novel: CustomStringConvertible {
        var network: String
        var input: String
        var share: Double
        var beyond: Float
        var key: String { "\(network) \(input)" }
        var description: String {
            String(
                format: "%@ %@: %.0f%% of rows, up to %.1f deviations out", network, input, 100 * share,
                beyond)
        }
    }

    /// What a scene gives the live response: nothing to judge, buildings whose construction it cannot
    /// read (then all of it is left to the CPU), or rows: the novel inputs among the rows of the
    /// buildings it still judges, the rows among those with any input out of range (none, where the
    /// drag leaves what lies outside to the CPU), and of the buildings in all its looks, those left
    /// to the CPU for their inputs, with the inputs that put them there.
    enum Reading {
        case nothing
        case leftToCPU(Int)
        case rows([Novel], strays: Int, left: Int, of: Int, why: [String: Int])
    }

    /// The live response's rows for `scene` on cells of `cellSize`, the charge at each of `places`
    /// (metres east and north of the scene's) and of each of `masses` kg, against the ranges; with
    /// `fallback`, as the drag judges it, its buildings outside the training left to the CPU.
    static func reading(
        _ scene: Scenario, cellSize: Float, places: [SIMD2<Float>], masses: [Double], fallback: Bool = true
    ) throws -> Reading {
        let weights = try #require(LiveResponse.Weights.builtIn)
        let ranges = try #require(LiveResponse.TrainingRanges.forBuiltInWeights)
        guard !scene.envelopeObjects.isEmpty else { return .nothing }
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: cellSize)
        guard prepared.componentCount > 0 else { return .nothing }
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645, samples: 10)
        var rows: [String: (values: [Float], width: Int)] = [:]
        var left = 0
        var buildings = 0
        var why: [String: Int] = [:]
        for offset in places {
            for mass in masses {
                var charge = scene.charge.position
                charge.x += offset.x
                charge.y += offset.y
                let (estimate, sides) = prepared.preview(charge: charge, mass: mass)
                let batch = LiveResponse.batch(
                    estimate: estimate, sides: sides, mass: mass, cellSize: cellSize,
                    coefficients: .adopted, roofCoefficients: .roofs, uncertainty: uncertainty,
                    construction: { LiveResponse.constructionFeatures(scene.envelopeConstruction(for: $0)) },
                    glazing: { LiveResponse.glazingFeatures($0.mix) })
                if batch.unknown > 0 || batch.noCharge { return .leftToCPU(batch.unknown) }
                // Each row's building, and those the drag leaves to the CPU: their rows are not judged.
                let index = Dictionary(
                    uniqueKeysWithValues: batch.buildingOwners.enumerated().map { ($1, $0) })
                let componentOwner = estimate.components.map { index[$0.owner] ?? -1 }
                let sideOwner = sides.map { index[$0.owner] ?? -1 }
                let (outside, inputs) = ranges.buildingsOutside(
                    components: batch.components, componentOwner: componentOwner, sides: batch.sides,
                    sideOwner: sideOwner, buildings: batch.buildings, buildingCount: batch.buildingCount,
                    weights: weights)
                buildings += batch.buildingCount
                if fallback {
                    left += outside.filter { $0 }.count
                    for (input, count) in inputs { why[input, default: 0] += count }
                }
                func judged(_ values: [Float], _ width: Int, _ owner: (Int) -> Int) -> [Float] {
                    guard fallback, width > 0 else { return values }
                    return (0..<(values.count / width)).flatMap { r -> ArraySlice<Float> in
                        let b = owner(r)
                        return outside.indices.contains(b) && outside[b]
                            ? [] : values[(r * width)..<((r + 1) * width)]
                    }
                }
                // The glass thrown's network (emmettl/bombcad-work#117) reads the glass network's rows.
                let sideRows = judged(batch.sides, batch.sideWidth) { sideOwner[$0] }
                for (name, values, width) in [
                    (
                        "component", judged(batch.components, batch.componentWidth) { componentOwner[$0] },
                        batch.componentWidth
                    ),
                    ("side", sideRows, batch.sideWidth),
                    ("building", judged(batch.buildings, batch.buildingWidth) { $0 }, batch.buildingWidth),
                    ("thrown", sideRows, batch.sideWidth),
                ] where width > 0 && weights.header.networks[name] != nil {
                    rows[name, default: ([], width)].values += values
                }
            }
        }
        var novel: [Novel] = []
        var strays = 0
        for (name, (values, width)) in rows.sorted(by: { $0.key < $1.key }) {
            let range = try #require(ranges.networks[name])
            let network = try #require(weights.header.networks[name])
            #expect(width == network.inputs && range.names.count == width, "\(name)'s widths")
            let count = values.count / width
            guard count > 0 else { continue }
            var stray = [Bool](repeating: false, count: count)
            for k in 0..<width {
                let std = Float(network.std[k])
                var out = 0
                var furthest: Float = 0
                for r in 0..<count {
                    let v = values[r * width + k]
                    let beyond = v.isFinite ? max(v - range.high[k], range.low[k] - v, 0) / std : .infinity
                    if beyond > 1 {
                        out += 1
                        stray[r] = true
                    }
                    furthest = max(furthest, beyond)
                }
                let fraction = Double(out) / Double(count)
                if fraction >= share {
                    novel.append(
                        Novel(network: name, input: range.names[k], share: fraction, beyond: furthest))
                }
            }
            strays += stray.filter { $0 }.count
        }
        return .rows(novel, strays: fallback ? strays : 0, left: left, of: buildings, why: why)
    }

    /// The check: the scene's novel inputs among the rows still judged are its known gaps, no more and
    /// no fewer; none of those rows lies outside (the drag's check and this one agree); and the share
    /// it leaves to the CPU is its own.
    static func check(_ name: String, _ reading: Reading) {
        switch reading {
        case .nothing, .leftToCPU:
            #expect(known[name] == nil, "\(name): the live response no longer judges it; take it off `known`")
            #expect(
                leftToCPU[name] == nil,
                "\(name): the live response no longer judges it; take it off `leftToCPU`")
        case .rows(let novel, let strays, let left, let of, let why):
            let found = Set(novel.map(\.key))
            let expected = known[name] ?? []
            #expect(
                found == expected,
                """
                \(name): the live response's inputs leave the range its built-in weights were trained on \
                (new: \(found.subtracting(expected).sorted()); closed: \(expected.subtracting(found).sorted())). \
                \(novel.map(\.description).joined(separator: "; ")). Train on such scenes (Scripts/ml/corpus.py, \
                docs/learned-models.md, "Adding a scene or a district type"), or record the gap in `known`.
                """)
            #expect(strays == 0, "\(name): \(strays) rows the drag judges lie outside the training")
            let share = Double(left) / Double(max(of, 1))
            let range = leftToCPU[name] ?? 0...0
            #expect(
                range.contains(share),
                """
                \(name): the drag leaves \(left) of \(of) buildings (over its looks) to the CPU's preview, \
                not \(range): \(why.sorted { $0.value > $1.value }.prefix(8).map { "\($0.key) \($0.value)" }). \
                Train on such scenes, or record the share in `leftToCPU`.
                """)
        }
    }

    @Test("The ranges are the built-in weights' own, and every explorer scene is checked")
    func rangesMatchTheWeights() {
        // A new explorer scene is checked here too: add it to `explorer` or `beirut`'s like.
        #expect(ExplorerScene.allCases == [.square, .street, .beirut])
        #expect(
            LiveResponse.TrainingRanges.builtIn.weightsSHA256 == LiveResponse.Weights.embeddedSHA256
                && LiveResponse.TrainingRanges.builtIn.thrownSHA256
                    == LiveResponse.Weights.embeddedThrownSHA256
                && LiveResponse.TrainingRanges.forBuiltInWeights != nil,
            "the built-in weights changed: run Scripts/ml/corpus.py ranges on their training data")
    }

    @Test(
        "The explorer's built-in scenes are within the live response's training, as the drag judges them",
        arguments: [
            ExplorerScene.square, .street,
        ])
    func explorer(scene: ExplorerScene) throws {
        var layout = DistrictLayout(
            buildings: scene.buildings(), charge: scene.charge, mass: scene.defaultMassKg)
        layout.keepsOutlines = true
        let cell = try #require(scene.cellSizeM)
        let half = layout.halfSide(radius: scene.radiusM, cellSize: cell)
        let (made, _) = try layout.scene(halfSide: half, cellSize: cell, radius: scene.radiusM)
        let mass = Double(scene.defaultMassKg)
        Self.check(
            "explorer \(scene.rawValue)",
            try Self.reading(
                made, cellSize: cell, places: [.zero, try #require(scene.behindABuilding).offset],
                masses: [mass, mass * 10], fallback: !scene.keepsLearnedResponse))
    }

    @Test("Beirut's port, where its file is downloaded, kept on the learned response, is within its training")
    func beirut() throws {
        let scene = ExplorerScene.beirut
        let data = ProcessInfo.processInfo.environment["BOMBCAD_DATA"] ?? "/Volumes/StudioData/bombcad"
        let asset = URL(filePath: data).appending(
            path: "explorer/beirut-asset/\(ExplorerScene.Beirut.fileName)")
        guard FileManager.default.fileExists(atPath: asset.path) else { return }  // not downloaded here
        let district = try scene.district(asset: asset)
        var layout = DistrictLayout(
            buildings: district.buildings, charge: scene.charge, mass: scene.defaultMassKg)
        layout.keepsOutlines = true
        layout.ground = district.ground
        let cell = try #require(scene.cellSizeM)
        let half = layout.halfSide(radius: scene.radiusM, cellSize: cell)
        let (made, _) = try layout.scene(halfSide: half, cellSize: cell, radius: scene.radiusM)
        Self.check(
            "explorer beirut",
            try Self.reading(
                made, cellSize: cell, places: [.zero], masses: [Double(scene.defaultMassKg)],
                fallback: !scene.keepsLearnedResponse))
    }

    @Test(
        "The presets with buildings are left to the CPU's preview where outside the training, on the app's medium cells"
    )
    func presets() throws {
        let cell = Float(0.25)
        for preset in ScenarioPreset.allCases {
            let scene = preset.scenario
            var mass = Double(scene.charge.mass)
            if !LiveResponse.judges(mass: mass) {
                // No charge (the process plant's gas cloud): left to the CPU's preview. Its buildings
                // are read under a charge of `chargeless` kg put in its place, as a user may set one.
                let none = try Self.reading(scene, cellSize: cell, places: [.zero], masses: [mass])
                if case .rows = none {
                    Issue.record("preset \(preset.rawValue): judged without a charge")
                }
                mass = Self.chargeless
            }
            Self.check(
                "preset \(preset.rawValue)",
                try Self.reading(scene, cellSize: cell, places: [.zero], masses: [mass / 4, mass, mass * 4]))
        }
    }
}
