import Foundation
import Testing
import simd

@testable import BlastModel

/// The live drag's learned response (emmettl/bombcad-work#112): its weights read and run as
/// PyTorch's dense layers run them, its inputs laid out as the training data's, and its look made of
/// the preview's own components.
@Suite("Live response")
struct LiveResponseTests {
    /// Weights of the right widths for `scene`, made up (the trained ones are built in once trained).
    static func madeUp(for scene: Scenario, hidden: Int = 8) throws -> LiveResponse.Weights {
        let widths = [
            "component": 3 + LiveResponse.constructionWidth + LiveResponse.shapeWidth,
            "side": 9 * LiveResponse.sideStrips + 5 + LiveResponse.glazingWidth,
            "building": LiveResponse.slotWidth * (LiveResponse.buildingWalls + 1) + 1
                + LiveResponse.constructionWidth,
        ]
        let outputs = ["component": 6, "side": 5, "building": 3]
        var values: [Float] = []
        var networks: [String: LiveResponse.Weights.Network] = [:]
        var state: UInt64 = 7
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 2000) / 4000
        }
        for name in ["component", "side", "building"] {
            let sizes = [widths[name]!, hidden, hidden, outputs[name]!]
            var layers: [LiveResponse.Weights.Layer] = []
            for (a, b) in zip(sizes.dropLast(), sizes.dropFirst()) {
                layers.append(.init(inputs: a, outputs: b, offset: values.count))
                values += (0..<(a * b + b)).map { _ in next() }
            }
            networks[name] = .init(
                inputs: sizes[0], mean: [Double](repeating: 0.1, count: sizes[0]),
                std: [Double](repeating: 2, count: sizes[0]), layers: layers, outputs: [])
        }
        let header = LiveResponse.Weights.Header(
            format: "bclr", version: 2, constructionWidth: LiveResponse.constructionWidth,
            glazingWidth: LiveResponse.glazingWidth,
            slopeStep: LiveResponse.slopeStep,
            sideStrips: LiveResponse.sideStrips, buildingWalls: LiveResponse.buildingWalls, networks: networks
        )
        var data = Data("BCLR".utf8)
        let text = try JSONEncoder().encode(header)
        for word in [UInt32(2), UInt32(text.count)] {
            withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(text)
        values.withUnsafeBytes { data.append(contentsOf: $0) }
        return try LiveResponse.Weights(data: data)
    }

    @Test("Weights read from their file run as dense layers with SiLU between, inputs standardised")
    func dense() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let weights = try Self.madeUp(for: scene)
        let network = try #require(weights.header.networks["side"])
        let row = (0..<network.inputs).map { Float($0 % 7) * 0.3 - 0.5 }
        let out = weights.run("side", rows: row + row, count: 2)
        // By hand.
        var a = zip(row, zip(network.mean, network.std)).map { ($0 - Float($1.0)) / Float($1.1) }
        for (l, layer) in network.layers.enumerated() {
            a = (0..<layer.outputs).map { o in
                var sum = weights.values[layer.offset + layer.inputs * layer.outputs + o]
                for k in 0..<layer.inputs {
                    sum += weights.values[layer.offset + o * layer.inputs + k] * a[k]
                }
                return l == network.layers.count - 1 ? sum : sum / (1 + exp(-sum))
            }
        }
        #expect(out.count == 10)
        for k in 0..<5 {
            #expect(abs(out[k] - a[k]) < 1e-5)
            #expect(out[5 + k] == out[k])
        }
    }

    @Test("Weights of another layout, or not weights at all, are refused")
    func refused() throws {
        #expect(throws: (any Error).self) { try LiveResponse.Weights(data: Data("BCFW1234".utf8)) }
        #expect(throws: (any Error).self) { try LiveResponse.Weights(data: Data()) }
    }

    @Test("A live look takes the preview's own components, their features as the CPU's to float rounding")
    func liveLook() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let constructions = { (id: UUID) in scene.envelopeConstruction(for: id) }
        let weights = try Self.madeUp(for: scene)
        let model = LiveResponse.Model(weights: weights, engine: LiveResponse.CPUEngine(weights: weights))
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let mass = Double(scene.charge.mass)
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645, samples: 10)
        for place in [scene.charge.position, scene.charge.position + SIMD3(6, -4, 0)] {
            let (preview, sides) = prepared.preview(charge: place, mass: mass)
            let (look, _) = try #require(
                try prepared.livePreview(
                    charge: place, mass: mass, uncertainty: uncertainty, model: model, keepEstimate: true))
            #expect(look.preview)
            #expect(look.estimate.components.map(\.id) == preview.components.map(\.id))
            for (a, b) in zip(look.estimate.features, preview.features) {
                #expect(abs(a.distanceM - b.distanceM) <= 1e-5 * b.distanceM)
                #expect(abs(a.cosIncidence - b.cosIncidence) <= 1e-6)
                #expect(a.buildingsCrossed == b.buildingsCrossed)
                #expect(abs(a.blockedM - b.blockedM) <= 1e-4)
            }
            #expect(look.glass.map(\.owner) == sides.map(\.owner))
            #expect(Set(look.damage.map(\.id)) == Set(preview.components.map(\.owner)))
            #expect(Set(look.structure.map(\.owner)) == Set(preview.components.map(\.owner)))
            for side in look.glass {
                #expect((0...1).contains(side.someBroken))
                #expect(side.blownOut <= side.someBroken)
            }
            for chance in look.structure { #expect(chance.wallsHeavy <= chance.wallsModerate) }

            // Its rows are the training data's: its answers are the networks' on `batch`'s rows, the CPU's
            // own predictions, to float rounding.

            let reference = LiveResponse.batch(
                estimate: preview, sides: sides, mass: mass, cellSize: 2, coefficients: .adopted,
                roofCoefficients: .roofs, uncertainty: uncertainty,
                construction: { LiveResponse.constructionFeatures(constructions($0)) },
                glazing: { LiveResponse.glazingFeatures($0.mix) })
            #expect(reference.unknown == 0)
            func sigmoid(_ x: Float) -> Double { 1 / (1 + exp(-Double(x))) }
            let sideOut = weights.run("side", rows: reference.sides, count: reference.sideCount)
            #expect(look.glass.count == reference.sideCount)
            for (s, side) in look.glass.enumerated() {
                #expect(abs(side.someBroken - sigmoid(sideOut[5 * s])) < 1e-4)
                #expect(abs(side.openingsBlownOut - sigmoid(sideOut[5 * s + 4])) < 1e-4)
            }
            let buildingOut = weights.run(
                "building", rows: reference.buildings, count: reference.buildingCount)
            let chances = Dictionary(uniqueKeysWithValues: look.structure.map { ($0.owner, $0) })
            for (b, owner) in reference.buildingOwners.enumerated() where reference.buildingHasRoof[b] {
                let chance = try #require(chances[owner])
                #expect(abs(chance.roofModerate - sigmoid(buildingOut[3 * b + 2])) < 1e-4)
            }
            let componentOut = weights.run(
                "component", rows: reference.components, count: reference.componentCount)
            var codes: [UUID: Int] = [:]
            for (k, component) in preview.components.enumerated() {
                var best = 0
                for c in 1..<5 where componentOut[6 * k + c] > componentOut[6 * k + best] { best = c }
                codes[component.owner] = max(codes[component.owner] ?? 0, best)
            }
            for building in look.damage {
                #expect(building.structuralLevels.upperBound.rawValue == codes[building.id])
            }
        }
    }

    @Test("A component's shape written in place is the one laid out from its load")
    func shapes() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        var checked = 0
        for list in prepared.components {
            for component in list {
                var row = [Float](repeating: -1, count: LiveResponse.shapeWidth)
                row.withUnsafeMutableBufferPointer {
                    LiveResponse.writeShape(component, buildingTop: 9, buildingBase: 0.5, into: $0, at: 0)
                }
                #expect(row == LiveResponse.shape(component, buildingTop: 9, buildingBase: 0.5))
                checked += 1
            }
        }
        // Walls held as panels, one way and standing free, as an envelope's own walls are.
        for edges in [
            [true, true, true, true], [false, false, true, true], [true, true, false, false],
            [false, false, true, false],
        ] {
            for kind in [EnvelopeComponent.Kind.wall, .slab, .roof, .pane, .facade] {
                let component = EnvelopeComponent(
                    id: "x", owner: UUID(), kind: kind,
                    region: Box(min: SIMD3(0, 0, 1), max: SIMD3(0.2, 7, 4.5)),
                    axis: 0, outward: 1, source: 0, panel: 0, supportEdges: edges)
                var row = [Float](repeating: -1, count: LiveResponse.shapeWidth)
                row.withUnsafeMutableBufferPointer {
                    LiveResponse.writeShape(component, buildingTop: 12, buildingBase: 0, into: $0, at: 0)
                }
                #expect(row == LiveResponse.shape(component, buildingTop: 12, buildingBase: 0))
            }
        }
        #expect(checked > 20)
    }

    @Test("A district built otherwise than the networks were trained on is left to the CPU's preview")
    func unknownConstruction() throws {
        var scene = try FacadeGlassProbabilityTests.row()
        let weights = try Self.madeUp(for: scene)
        let id = try #require(scene.envelopeObjects.first?.id)
        var construction = scene.envelopeConstruction(for: id)
        construction.masonryArching = true
        scene.setEnvelopeConstruction(construction)
        let model = LiveResponse.Model(weights: weights, engine: LiveResponse.CPUEngine(weights: weights))
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let result = try prepared.livePreview(
            charge: scene.charge.position, mass: Double(scene.charge.mass),
            uncertainty: FacadeLoadSurrogate.Uncertainty(yieldLogSD: 0.2), model: model)
        #expect(result == nil)
    }

    @Test("The preview's choice by its groups laid out once is the choice by dictionaries, to the component")
    func choices() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        for incidence in FacadeLoadSurrogate.Incidence.allCases {
            let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2, incidence: incidence)
            for place in [scene.charge.position, SIMD3(100, 10, 1), SIMD3(390, 59, 2), SIMD3(65, 30, 0.5)] {
                let fast = prepared.choices(charge: place)
                let reference = prepared.referenceChoices(charge: place)
                #expect(fast.map { $0.map(\.index) } == reference.map { $0.map(\.index) })
                #expect(fast.map { $0.map(\.area) } == reference.map { $0.map(\.area) })
                #expect(fast.map { $0.map(\.judged) } == reference.map { $0.map(\.judged) })
            }
        }
    }

    @Test("A construction is read by what it is built of, not by its building or where it came from")
    func constructionFeatures() throws {
        let a = EnvelopeConstruction(objectID: UUID(), source: .map, detail: "one")
        let b = EnvelopeConstruction(objectID: UUID(), source: .user, detail: "two")
        let read = try #require(LiveResponse.constructionFeatures(a))
        #expect(read.count == LiveResponse.constructionWidth)
        #expect(LiveResponse.constructionFeatures(b) == read)
        // Every what-if is read, and reads apart.
        var seen: Set<[Float]> = [read]
        for (_, glass) in LiveResponse.Glass.offered.dropFirst() {
            let built = try #require(LiveResponse.constructionFeatures(glass.applied(to: b)))
            #expect(seen.insert(built).inserted)
        }
        for kind in LiveResponse.WhatIf.wallKinds.dropFirst() {
            let built = try #require(
                LiveResponse.constructionFeatures(LiveResponse.WhatIf(walls: kind).applied(to: b)))
            #expect(seen.insert(built).inserted)
        }
        // The glazing too, with its glass.
        var glazed = b
        glazed.glazing = .commercial
        let laminated = LiveResponse.Glass.laminated(.facade).applied(to: glazed)
        #expect(
            LiveResponse.glazingFeatures(try #require(laminated.glazing))
                != LiveResponse.glazingFeatures(.commercial))
        #expect(LiveResponse.glazingFeatures(.commercial)?.count == LiveResponse.glazingWidth)
        // What the networks were not trained on is not read.
        var arched = b
        arched.masonryArching = true
        #expect(LiveResponse.constructionFeatures(arched) == nil)
        var odd = GlazingMix.apartments
        odd.glazedFraction = 0.3
        #expect(LiveResponse.glazingFeatures(odd) == nil)
    }

    @Test("A what-if builds every building of the scene so, and leaves an empty one as it is")
    func whatIf() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        #expect(LiveResponse.WhatIf().applied(to: scene) == scene)
        let whatIf = LiveResponse.WhatIf(
            glass: .toughened, walls: .unreinforcedMasonry, roof: .crossLaminatedTimber)
        let built = whatIf.applied(to: scene)
        for object in scene.envelopeObjects {
            let c = built.envelopeConstruction(for: object.id)
            #expect(
                c.walls == .unreinforcedMasonry && c.roof == .crossLaminatedTimber && c.glassToughened == true
            )
            #expect(c.glazing?.glass?.toughened == true)
        }
        #expect(whatIf.label.contains("toughened"))
        // A prepared district takes the new constructions without being laid out again.
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let again = prepared.withConstructions(of: built)
        #expect(again.identity == prepared.identity && again.constructionsKey != prepared.constructionsKey)
        #expect(again.constructions.allSatisfy { $0.walls == .unreinforcedMasonry })
    }
}
