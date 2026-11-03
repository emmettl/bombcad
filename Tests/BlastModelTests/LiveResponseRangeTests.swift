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
/// beyond the training's 0.1-99.9% points (`LiveResponseRanges.swift`, written by
/// `Scripts/ml/corpus.py ranges` for the built-in weights); it is novel for a scene when that is so
/// on at least `share` of the scene's rows. Each scene's known gaps are listed in `known`, so that
/// a new gap fails, and so does one that has closed (then take it off the list). CPU only, a few
/// seconds; Beirut's port is checked where its downloaded file is found (`$BOMBCAD_DATA/explorer/
/// beirut-asset`), and skipped elsewhere, as on Linux.
@Suite("Live response's training range")
struct LiveResponseRangeTests {
    /// What, changed, makes `make check-affected` run this suite besides the code it executes: the
    /// built-in weights, the scripts their data and ranges come from, and the scenes.
    static let watched = [
        "Sources/BlastModel/LiveResponse+Embedded.swift", "Sources/BlastModel/LiveResponse+Thrown.swift",
        "Sources/BlastModel/ExplorerScene.swift",
        "Sources/BlastModel/Presets.swift", "Scripts/ml/make_district.py", "Scripts/ml/train_response.py",
        "Scripts/ml/corpus.py", "Scripts/ml/embed_response.py",
    ]

    /// The charge, kg, a preset without one (a gas deflagration's) is read under.
    static let chargeless = 100.0

    /// The share of a scene's rows an input must leave the range on to count.
    static let share = 0.05

    /// What the live response is out of range on in each built-in scene now, network by network:
    /// recorded gaps, not passes (docs/learned-models.md, "The built-in scenes checked", 3 November
    /// 2026). Beirut's port is on 6 m cells, the training's on 2 and 4 m: its roofs' panel height is
    /// out. The three presets the live response judges are on the app's 0.25 m cells, their panels
    /// and spans far out. The process plant's gas cloud has no charge, and is left to the CPU's
    /// preview; its buildings are read under a charge of `chargeless` kg put in its place.
    static let known: [String: Set<String>] = [
        "explorer beirut": [
            "building roof.panelHeight", "component panelHeight",
        ],
        "preset officeTower": [
            "building roof.load2", "building roof.panelHeight", "building wall0.kind.facade",
            "building wall0.panelHeight", "building wall0.span.short", "building wall1.panelHeight",
            "building wall1.span.short", "building wall2.panelHeight", "building wall2.span.short",
            "building wall3.panelHeight", "component panelHeight", "component span.long",
        ],
        "preset processPlantExplosion": [
            "building roof.edge2", "building roof.panelHeight", "building wall0.kind.facade",
            "building wall0.oneWaySpan", "building wall0.panelHeight", "building wall0.span.short",
            "building wall1.panelHeight", "building wall1.span.short", "building wall2.panelHeight",
            "building wall2.span.short", "building wall3.oneWaySpan", "building wall3.panelHeight",
            "building wall3.span.short", "component oneWaySpan", "component panelHeight",
            "component span.long",
        ],
        "preset transportHub": [
            "building roof.edge2", "building roof.panelHeight", "building wall0.kind.facade",
            "building wall0.panelHeight", "building wall0.span.short", "building wall1.panelHeight",
            "building wall1.span.short", "building wall2.panelHeight", "building wall2.span.short",
            "building wall3.panelHeight", "building wall3.span.short", "component panelHeight",
        ],
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

    /// What a scene gives the live response: nothing to judge, buildings it leaves to the CPU, or rows.
    enum Reading {
        case nothing
        case leftToCPU(Int)
        case rows([Novel])
    }

    /// The live response's rows for `scene` on cells of `cellSize`, the charge at each of `places`
    /// (metres east and north of the scene's) and of each of `masses` kg, against the ranges.
    static func reading(
        _ scene: Scenario, cellSize: Float, places: [SIMD2<Float>], masses: [Double]
    ) throws -> Reading {
        let weights = try #require(LiveResponse.Weights.builtIn)
        guard !scene.envelopeObjects.isEmpty else { return .nothing }
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: cellSize)
        guard prepared.componentCount > 0 else { return .nothing }
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645, samples: 10)
        var rows: [String: (values: [Float], width: Int)] = [:]
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
                // The glass thrown's network (emmettl/bombcad-work#117) reads the glass network's rows.
                for (name, values, width) in [
                    ("component", batch.components, batch.componentWidth),
                    ("side", batch.sides, batch.sideWidth),
                    ("building", batch.buildings, batch.buildingWidth),
                    ("thrown", batch.sides, batch.sideWidth),
                ] where width > 0 && weights.header.networks[name] != nil {
                    rows[name, default: ([], width)].values += values
                }
            }
        }
        var novel: [Novel] = []
        for (name, (values, width)) in rows.sorted(by: { $0.key < $1.key }) {
            let range = try #require(ranges[name])
            let network = try #require(weights.header.networks[name])
            #expect(width == network.inputs && range.names.count == width, "\(name)'s widths")
            let count = values.count / width
            guard count > 0 else { continue }
            for k in 0..<width {
                let std = Float(network.std[k])
                var out = 0
                var furthest: Float = 0
                for r in 0..<count {
                    let v = values[r * width + k]
                    let beyond = max(v - range.high[k], range.low[k] - v, 0) / std
                    if beyond > 1 { out += 1 }
                    furthest = max(furthest, beyond)
                }
                let fraction = Double(out) / Double(count)
                if fraction >= share {
                    novel.append(
                        Novel(network: name, input: range.names[k], share: fraction, beyond: furthest))
                }
            }
        }
        return .rows(novel)
    }

    /// The check: the scene's novel inputs are its known gaps, no more and no fewer.
    static func check(_ name: String, _ reading: Reading) {
        switch reading {
        case .nothing, .leftToCPU:
            #expect(known[name] == nil, "\(name): the live response no longer judges it; take it off `known`")
        case .rows(let novel):
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
        }
    }

    @Test("The ranges are the built-in weights' own, and every explorer scene is checked")
    func rangesMatchTheWeights() {
        // A new explorer scene is checked here too: add it to `explorer` or `beirut`'s like.
        #expect(ExplorerScene.allCases == [.square, .street, .beirut])
        #expect(
            Self.trainedSHA256 == LiveResponse.Weights.embeddedSHA256
                && Self.trainedThrownSHA256 == LiveResponse.Weights.embeddedThrownSHA256,
            "the built-in weights changed: run Scripts/ml/corpus.py ranges on their training data")
    }

    @Test(
        "The explorer's built-in scenes are within the live response's training",
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
                masses: [mass, mass * 10]))
    }

    @Test("Beirut's port, where its file is downloaded, is within the live response's training")
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
            try Self.reading(made, cellSize: cell, places: [.zero], masses: [Double(scene.defaultMassKg)]))
    }

    @Test("The presets with buildings are within the live response's training, on the app's medium cells")
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
