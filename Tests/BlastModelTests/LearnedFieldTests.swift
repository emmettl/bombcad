import Foundation
import Testing
import simd

@testable import BlastModel

/// The learned field model's peak in the quick estimate (emmettl/bombcad-work#67), with a stand-in
/// network on the CPU: the GPU's own (BlastCore's `LearnedFieldNetwork`) is checked against
/// PyTorch in BlastCoreTests.
@Suite("Learned field peaks")
struct LearnedFieldTests {
    /// A network whose correction is nothing (so its peak is Kingery–Bulmash's incident one), or
    /// one that fails.
    final class StandIn: LearnedField.Network, @unchecked Sendable {
        let header: LearnedField.Weights.Header
        let fails: Bool
        var calls = 0

        init(fails: Bool = false) {
            header = LearnedField.Weights.Header(
                format: "bombcad-field-weights-1", model: "unet", width: 1, depth: 1,
                inputs: LearnedField.Weights.inputs,
                stats: .init(mean: [0, 0, 0, 0, 0, 0], std: [1, 1, 1, 1, 1, 1]), residual: true, multiple: 16,
                groupNormGroups: 8, groupNormEpsilon: 1e-5, dtype: "float32", tensors: [])
            self.fails = fails
        }

        func peakChannel(inputs: [Float], rows: Int, columns: Int) throws -> [Float] {
            calls += 1
            if fails { throw LearnedFieldError.network("a stand-in that fails") }
            #expect(rows % 16 == 0 && columns % 16 == 0 && inputs.count == 6 * rows * columns)
            return [Float](repeating: 0, count: rows * columns)
        }
    }

    @Test("Halves read as IEEE halves")
    func halves() {
        #expect(LearnedField.float(half: 0x3C00) == 1)
        #expect(LearnedField.float(half: 0xC000) == -2)
        #expect(LearnedField.float(half: 0x3800) == 0.5)
        #expect(LearnedField.float(half: 0x7BFF) == 65504)
        #expect(LearnedField.float(half: 0x0001) == 0x1p-24)
        #expect(LearnedField.float(half: 0x8000) == 0 && LearnedField.float(half: 0x8000).sign == .minus)
        #expect(LearnedField.float(half: 0x7C00) == .infinity)
        #expect(LearnedField.float(half: 0x7E00).isNaN)
    }

    @Test("A weights file reads back its header and tensors, and one short of a tensor is refused")
    func weightsFile() throws {
        func file(dropping: String? = nil) throws -> Data {
            var entries: [[String: Any]] = []
            var values: [UInt16] = []
            let shapes = LearnedField.Weights.tensorShapes(width: 2, depth: 1)
            for name in LearnedField.Weights.tensorNames(depth: 1) where name != dropping {
                let shape = shapes[name]!
                let count = shape.reduce(1, *)
                entries.append(["name": name, "shape": shape, "offset": values.count, "count": count])
                values += (0..<count).map { $0 % 2 == 0 ? 0x3C00 : 0xC000 }
            }
            let header: [String: Any] = [
                "format": "bombcad-field-weights-1", "model": "unet", "width": 2, "depth": 1,
                "inputs": LearnedField.Weights.inputs,
                "stats": ["mean": [0, 1, 2, 3, 4, 5], "std": [1, 1, 1, 1, 1, 2]], "residual": true,
                "multiple": 2, "groupNormGroups": 8, "groupNormEpsilon": 1e-5, "dtype": "float16",
                "tensors": entries,
            ]
            var text = try JSONSerialization.data(withJSONObject: header)
            text.append(contentsOf: [UInt8](repeating: 0x20, count: (16 - text.count % 16) % 16))
            var data = Data("BCFW".utf8)
            for word in [UInt32(1), UInt32(text.count)] {
                withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(text)
            for value in values { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
            return data
        }
        let weights = try LearnedField.Weights(data: file())
        #expect(weights.header.depth == 1 && weights.header.stats.std[5] == 2)
        #expect(weights.tensors["head.bias"]?.values == [1, -2])
        #expect(weights.tensors.count == LearnedField.Weights.tensorNames(depth: 1).count)
        #expect(throws: LearnedFieldError.self) {
            try LearnedField.Weights(data: file(dropping: "up.0.body.3.weight"))
        }
        #expect(throws: LearnedFieldError.self) {
            try LearnedField.Weights(data: Data("nothing at all".utf8))
        }
    }

    @Test(
        "The plan holds the blocks' heights over the cells their blocks cover, and the inputs follow field-export's"
    )
    func plan() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let plan = LearnedField.Plan(scene: scene)
        #expect(plan.columns == 100 && plan.rows == 15)
        // The blocks, x from 30, 60, 100 and 170 for 10 m, y 25–35, 9 m: the cells whose centres
        // they cover, from their low side up to (not on) their high side, as the air's grid holds them.
        for j in 0..<plan.rows {
            for i in 0..<plan.columns {
                let x = (Float(i) + 0.5) * 4
                let y = (Float(j) + 0.5) * 4
                let inside =
                    [30, 60, 100, 170].contains { x >= Float($0) && x < Float($0) + 10 } && y >= 25 && y < 35
                #expect(plan.height[i + plan.columns * j] == (inside ? 9 : 0))
            }
        }
        let mass = Double(scene.charge.mass)
        let raw = plan.exportChannels(charge: scene.charge.position, mass: mass)
        let n = 20 + plan.columns * 7
        let distance = simd_distance(SIMD2(82, 30), SIMD2(scene.charge.position.x, scene.charge.position.y))
        #expect(raw[2 * 1_500 + n] == distance)
        let kb = LearnedField.kingeryBulmash(z: Double(distance) / cbrt(mass), mass: mass)
        #expect(raw[4 * 1_500 + n] == Float(kb.peak) && raw[5 * 1_500 + n] == Float(kb.impulse))
        // Standardised and padded: the footprint 0 or 1, the edge repeated north and east.
        let header = StandIn().header
        let (inputs, rows, columns, kbLog) = LearnedField.networkInputs(
            exportChannels: raw, rows: plan.rows, columns: plan.columns, header: header)
        #expect(rows == 16 && columns == 112 && inputs.count == 6 * 16 * 112)
        #expect(kbLog[n] == log(Float(kb.peak)))
        let area = rows * columns
        #expect(inputs[area + 9 + columns * 7] == 1 && inputs[area + 5 + columns * 7] == 0)
        #expect(inputs[3 * area + 111 + columns * 15] == inputs[3 * area + 99 + columns * 14])
    }

    @Test("A strip's front cells are the air beside its face along its width, as judge_field.py's")
    func frontCells() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let plan = LearnedField.Plan(scene: scene)
        let map = LearnedField.PeakMap(
            plan: plan, logPeak: [Float](repeating: 8, count: plan.columns * plan.rows))
        func strip(_ axis: Int, _ outward: Int, _ low: SIMD3<Float>, _ high: SIMD3<Float>)
            -> EnvelopeComponent
        {
            EnvelopeComponent(
                id: "s", owner: UUID(), kind: .facade, region: Box(min: low, max: high), axis: axis,
                outward: outward, source: 0, panel: 0, supportEdges: [true, true, true, true])
        }
        // The first block's west face, x 30, y 25–35: column 6 (centre 26; the block holds column 7's
        // centre, 30), rows 6–8 (centres 26–34).
        let west = strip(0, -1, SIMD3(30, 25, 0), SIMD3(30.3, 35, 3))
        #expect(map.frontCells(west) == [6 + 100 * 6, 6 + 100 * 7, 6 + 100 * 8])
        // Its east face, x 40: column 10 (centre 42).
        #expect(map.frontCells(strip(0, 1, SIMD3(39.7, 25, 0), SIMD3(40, 35, 3))).first == 10 + 100 * 6)
        // Narrower than a cell: its middle one.
        #expect(map.frontCells(strip(1, -1, SIMD3(31, 25, 0), SIMD3(32, 25.3, 3))) == [7 + 100 * 5])
        // The ground floor spans 2 m over the ground; the storey above does not, nor does a roof.
        #expect(map.isGroundFloor(west))
        #expect(!map.isGroundFloor(strip(0, -1, SIMD3(30, 25, 3), SIMD3(30.3, 35, 6))))
        var roof = west
        roof.kind = .roof
        #expect(map.peak(at: roof) == nil)
        #expect(abs(map.peak(at: west)! - Double(exp(Float(8)))) < 1e-6 * exp(8))
    }

    @Test(
        "Off, the estimate is the surrogate's to the bit; on, only ground-floor façade strips take the model's peak"
    )
    func onlyGroundFloorFacades() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let charge = scene.charge.position
        let mass = Double(scene.charge.mass)
        let plain = prepared.estimate(charge: charge, mass: mass)
        let estimator = LearnedField.Estimator(scene: scene, network: StandIn())
        let peaks = try estimator.peaks(charge: charge, mass: mass)
        let learned = prepared.estimate(charge: charge, mass: mass, learned: peaks)
        var taken = 0
        for n in plain.components.indices {
            let component = plain.components[n]
            if let peak = peaks.peak(at: component) {
                taken += 1
                #expect(component.kind == .facade && peaks.isGroundFloor(component))
                #expect(abs(learned.predictions[n].peakPa / peak - 1) < 1e-9)
                // The impulse and rise stay the surrogate's.
                #expect(learned.predictions[n].impulsePaS == plain.predictions[n].impulsePaS)
                #expect(learned.predictions[n].riseShare == plain.predictions[n].riseShare)
                #expect(learned.features[n].learnedPeakFactor != 1)
            } else {
                #expect(learned.predictions[n] == plain.predictions[n])
                #expect(learned.loads[n].outerPa == plain.loads[n].outerPa)
                #expect(learned.features[n] == plain.features[n])
            }
        }
        #expect(taken > 0)
        #expect(learned.components.contains { $0.kind == .roof })
        // The stand-in's peak is Kingery–Bulmash's incident one, under the surrogate's facing raise.
        let n = try #require(plain.components.indices.first { peaks.peak(at: plain.components[$0]) != nil })
        let f = learned.features[n]
        #expect(f.learnedPeakFactor > 0)
        // A drawn yield keeps the same ratio.
        var unlearned = f
        unlearned.learnedPeakFactor = 1
        let ratio =
            FacadeLoadSurrogate.predict(f, mass: 2 * mass, cellSize: 2).peakPa
            / FacadeLoadSurrogate.predict(unlearned, mass: 2 * mass, cellSize: 2).peakPa
        #expect(abs(ratio - f.learnedPeakFactor) < 1e-12)
    }

    @Test(
        "A look with the model: its peaks in the damage, glass and walls; without it, or failing, the surrogate's to the bit"
    )
    func look() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let constructions = { (id: UUID) in scene.envelopeConstruction(for: id) }
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: 0.2, samples: 6)
        let charge = scene.charge.position
        let mass = Double(scene.charge.mass)
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = prepared.look(
            charge: charge, mass: mass, constructions: constructions, uncertainty: uncertainty)
        #expect(plain.learnedStrips == 0 && plain.learnedError == nil)
        let failing = StandIn(fails: true)
        let failed = prepared.look(
            charge: charge, mass: mass, constructions: constructions, uncertainty: uncertainty,
            learned: LearnedField.Estimator(scene: scene, network: failing))
        #expect(failing.calls == 1 && failed.learnedError != nil && failed.learnedStrips == 0)
        #expect(try encoder.encode(failed.damage) == encoder.encode(plain.damage))
        #expect(failed.glass == plain.glass && failed.structure == plain.structure)
        #expect(failed.estimate.loads.map(\.outerPa) == plain.estimate.loads.map(\.outerPa))

        let network = StandIn()
        let estimator = LearnedField.Estimator(scene: scene, network: network)
        for preview in [false, true] {
            let look = prepared.look(
                charge: charge, mass: mass, constructions: constructions, uncertainty: uncertainty,
                preview: preview, learned: estimator)
            #expect(look.learnedError == nil && look.learnedStrips > 0)
            // The estimate's glass sides carry the model's peaks into the draws.
            let sides =
                preview
                ? prepared.preview(
                    charge: charge, mass: mass, learned: try estimator.peaks(charge: charge, mass: mass)
                ).sides
                : prepared.glassSides(look.estimate)
            #expect(sides.contains { $0.strips.contains { $0.features.learnedPeakFactor != 1 } })
            if !preview {
                let (glass, _) = FacadeLoadSurrogate.glassProbabilities(
                    sides: sides, mass: mass, cellSize: 2, uncertainty: uncertainty)
                #expect(look.glass == glass)
                let (structure, _) = FacadeLoadSurrogate.structureProbabilities(
                    look.estimate, mass: mass, cellSize: 2, constructions: constructions,
                    uncertainty: uncertainty)
                #expect(look.structure == structure)
            }
        }
        #expect(network.calls == 3)
    }

    @Test("The weights come from BOMBCAD_FIELD_MODEL, else the setting, else Application Support")
    func weightsURL() {
        #expect(
            LearnedField.weightsURL(setting: "/b.bcfw", environment: [LearnedField.environmentKey: "/a.bcfw"])
                .path
                == "/a.bcfw")
        #expect(LearnedField.weightsURL(setting: "/b.bcfw", environment: [:]).path == "/b.bcfw")
        #expect(LearnedField.weightsURL(setting: nil, environment: [:]) == LearnedField.defaultWeightsURL)
        #expect(
            LearnedField.defaultWeightsURL.path.hasSuffix("BombCAD/LearnedModels/" + LearnedField.fileName))
    }
}
