import Foundation
import Testing
import simd

@testable import BlastModel

/// The live drag leaves to the CPU's preview what lies outside its training (emmettl/bombcad-work#118,
/// the user's decision of 3 November 2026; docs/learned-models.md, "What lies outside the training,
/// on the CPU"): a building with any row of the networks' inputs more than one deviation beyond the
/// training's 0.1-99.9% points is judged by the SDOF and draws, the rest by the networks.
@Suite("Live response's fallback outside its training")
struct LiveResponseFallbackTests {
    /// Ranges for `weights` that hold everything, but the component network's `input` held below `high`.
    static func ranges(for weights: LiveResponse.Weights, holding input: Int = -1, below high: Float = 0)
        -> LiveResponse.TrainingRanges
    {
        var networks: [String: LiveResponse.TrainingRanges.Network] = [:]
        for (name, network) in weights.header.networks {
            var top = [Float](repeating: 1e30, count: network.inputs)
            if name == "component", input >= 0 { top[input] = high }
            networks[name] = .init(
                names: (0..<network.inputs).map { "input\($0)" },
                low: [Float](repeating: -1e30, count: network.inputs), high: top)
        }
        return LiveResponse.TrainingRanges(weightsSHA256: "", thrownSHA256: nil, networks: networks)
    }

    @Test("A row is outside where an input lies more than one deviation beyond the range, or is not finite")
    func rows() throws {
        let weights = try LiveResponseTests.madeUp(for: try FacadeGlassProbabilityTests.row())
        let width = try #require(weights.header.networks["component"]).inputs
        // The made-up weights' deviations are 2: 1.9 above the range is within, 2.1 beyond.
        let ranges = Self.ranges(for: weights, holding: 3, below: 1)
        var rows = [Float](repeating: 0, count: 4 * width)
        rows[0 * width + 3] = 2.9
        rows[1 * width + 3] = 3.1
        rows[2 * width + 3] = .nan
        rows[3 * width + 7] = .infinity
        #expect(ranges.outside("component", rows: rows, weights: weights) == [-1, 3, 3, 7])
        // A network the ranges have not got holds everything.
        #expect(ranges.outside("thrown", rows: rows, weights: weights).isEmpty)
        let (outside, inputs) = ranges.buildingsOutside(
            components: rows, componentOwner: [0, 1, 1, 2], sides: [], sideOwner: [], buildings: [],
            buildingCount: 3, weights: weights)
        #expect(outside == [false, true, true])
        #expect(inputs == ["component input3": 1, "component input7": 1])
        #expect(
            LiveResponse.TrainingRanges.words(["building roof.panelHeight": 9, "side strip0.load1": 2])
                == ["their panels' sizes", "the loads on them"])
    }

    @Test("The buildings outside are the CPU preview's, the rest the networks', and the look says how many")
    func partly() throws {
        let scene = try FacadeGlassProbabilityTests.row()
        let weights = try LiveResponseTests.madeUp(for: scene)
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2)
        let mass = Double(scene.charge.mass)
        let charge = scene.charge.position
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645, samples: 10)
        let engine = LiveResponse.CPUEngine(weights: weights)
        let learned = try #require(
            try prepared.livePreview(
                charge: charge, mass: mass, uncertainty: uncertainty,
                model: LiveResponse.Model(weights: weights, engine: engine))
        ).look
        #expect(learned.leftToCPU == 0 && learned.untrainedNote == nil)
        // The component network's peak held below the middle of the buildings' nearest: the nearer
        // half outside.
        let (preview, _) = prepared.preview(charge: charge, mass: mass)
        var nearest: [UUID: Double] = [:]
        for (k, component) in preview.components.enumerated() {
            let peak = LiveResponse.quantized(
                LiveResponse.Load(
                    log10Peak: log10(max(preview.predictions[k].peakPa, 1e-6)), log10Impulse: 0, rise: 0,
                    peakSlope: 0, impulseSlope: 0)
            ).0
            nearest[component.owner] = max(nearest[component.owner] ?? -.infinity, Double(peak))
        }
        let peaks = nearest.values.sorted()
        #expect(peaks.count == 4 && peaks[1] < peaks[2])
        let middle = Float((peaks[1] + peaks[2]) / 2)
        let model = LiveResponse.Model(
            weights: weights, engine: engine, ranges: Self.ranges(for: weights, holding: 0, below: middle - 2)
        )
        let look = try #require(
            try prepared.livePreview(charge: charge, mass: mass, uncertainty: uncertainty, model: model)
        ).look
        let outside = Set(nearest.filter { $0.value > Double(middle) }.map(\.key))
        #expect(outside.count == 2)
        #expect(look.leftToCPU == 2 && look.liveBuildings == 4 && look.outsideKept == 0)
        #expect(look.outsideTraining == ["component input0": 2])
        #expect(look.learnedResponse == "CPU")
        #expect(look.untrainedNote?.hasPrefix("2 of 4 buildings here lie outside") == true)

        // Those outside as the CPU's own preview of them, the rest as the networks'.
        let cpu = prepared.look(
            charge: charge, mass: mass, constructions: { scene.envelopeConstruction(for: $0) },
            uncertainty: uncertainty, preview: true)
        func codes(_ damage: [EnvelopeBuildingDamage]) -> [UUID: Int] {
            Dictionary(uniqueKeysWithValues: damage.map { ($0.id, EnvelopeDamageColour.code($0)) })
        }
        let mine = codes(look.damage)
        #expect(mine.count == 4)
        for (id, code) in mine {
            #expect(code == (outside.contains(id) ? codes(cpu.damage) : codes(learned.damage))[id])
        }
        func sides(_ glass: [FacadeLoadSurrogate.SideGlass]) -> [String: FacadeLoadSurrogate.SideGlass] {
            Dictionary(uniqueKeysWithValues: glass.map { ("\($0.owner) \($0.axis) \($0.outward)", $0) })
        }
        #expect(look.glass.count == learned.glass.count)
        for (key, side) in sides(look.glass) {
            #expect(side == (outside.contains(side.owner) ? sides(cpu.glass) : sides(learned.glass))[key])
        }
        let chances = { (list: [FacadeLoadSurrogate.StructureChance]) in
            Dictionary(uniqueKeysWithValues: list.map { ($0.owner, $0) })
        }
        #expect(look.structure.count == 4)
        for chance in look.structure {
            #expect(
                chance
                    == (outside.contains(chance.owner) ? chances(cpu.structure) : chances(learned.structure))[
                        chance.owner])
        }

        // Asked to keep them on the networks, it does, and counts them.
        let kept = try #require(
            try prepared.livePreview(
                charge: charge, mass: mass, uncertainty: uncertainty, model: model,
                leavesUntrainedToCPU: false)
        ).look
        #expect(kept.leftToCPU == 0 && kept.outsideKept == 2)
        #expect(codes(kept.damage) == codes(learned.damage))
        #expect(kept.untrainedNote?.contains("judges them all the same") == true)
    }

    @Test("A preset on the app's medium cells, outside the training throughout, is the CPU preview's")
    func wholly() throws {
        let weights = try #require(LiveResponse.Weights.builtIn)
        let ranges = try #require(LiveResponse.TrainingRanges.forBuiltInWeights)
        let scene = ScenarioPreset.officeTower.scenario
        let prepared = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 0.25)
        let mass = Double(scene.charge.mass)
        let uncertainty = FacadeLoadSurrogate.Uncertainty(yieldLogSD: log(1.5) / 1.645, samples: 10)
        let model = LiveResponse.Model(
            weights: weights, engine: LiveResponse.CPUEngine(weights: weights), ranges: ranges)
        let look = try #require(
            try prepared.livePreview(
                charge: scene.charge.position, mass: mass, uncertainty: uncertainty, model: model)
        ).look
        #expect(look.liveBuildings > 0 && look.leftToCPU == look.liveBuildings)
        #expect(look.learnedResponse == nil)
        #expect(look.untrainedNote?.hasPrefix("Every building here lies outside") == true)
        let cpu = prepared.look(
            charge: scene.charge.position, mass: mass, constructions: { scene.envelopeConstruction(for: $0) },
            uncertainty: uncertainty, preview: true)
        #expect(
            look.damage.map { EnvelopeDamageColour.code($0) }
                == cpu.damage.map { EnvelopeDamageColour.code($0) })
        #expect(look.glass == cpu.glass)
        #expect(look.structure == cpu.structure)
    }
}
