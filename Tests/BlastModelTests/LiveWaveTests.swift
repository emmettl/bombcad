import Foundation
import Testing
import simd

@testable import BlastModel

/// The live blast wave's paths, strengths and times (docs/live-wave.md).
struct LiveWaveTests {
    /// An open plan `n` cells square on `cell` m cells, with `blocks` (i0, j0, i1, j1, height) on it.
    static func plan(_ n: Int, cell: Float = 4, blocks: [(Int, Int, Int, Int, Float)] = []) -> LiveWave.Plan {
        var height = [Float](repeating: 0, count: n * n)
        for (i0, j0, i1, j1, h) in blocks {
            for j in j0...j1 { for i in i0...i1 { height[i + n * j] = h } }
        }
        return LiveWave.Plan(
            columns: n, rows: n, cell: cell, height: height, ground: [Float](repeating: 0, count: n * n))
    }

    @Test("In the open the path is the straight line to within 1.3%, and never shorter")
    func openPaths() {
        let plan = Self.plan(201)
        let charge = SIMD3<Float>(402, 402, 0)
        let (path, straight) = LiveWave.paths(plan: plan, charge: charge)
        // Beyond a few cells, within the steps' 1.3% and the lattice's cell or so.
        var worst: Float = 0
        var far: Float = 0
        for n in path.indices where straight[n] > 40 {
            let ratio = path[n] / straight[n]
            #expect(ratio >= 0.9999)
            worst = max(worst, ratio)
            if straight[n] > 300 { far = max(far, ratio) }
        }
        #expect(worst < 1.025)
        #expect(far < 1.014)
        #expect(far > 1.005)
    }

    @Test("In the open the wave is Kingery–Bulmash's along the straight line, uncorrected")
    func openStrength() throws {
        let plan = Self.plan(201)
        let charge = SIMD3<Float>(402, 402, 0)
        let mass = 100_000.0
        let field = LiveWave.field(plan: plan, charge: charge, mass: mass, coefficients: .none)
        // A cell 300 m east, on an axis, where the path is exact.
        let n = (100 + 75) + 201 * 100
        let r = Double(field.straight[n])
        let z = r / cbrt(mass)
        let kb = try #require(KingeryBulmash.point(at: z))
        #expect(abs(Double(field.path[n]) - r) < 1e-3)
        #expect(abs(Double(field.peak[n]) / kb.incidentPressure - 1) < 0.01)
        #expect(abs(Double(field.arrival[n]) / kb.arrival(mass: mass) - 1) < 0.01)
        let duration = try #require(KingeryBulmash.scaledDuration(at: z)) * cbrt(mass)
        #expect(abs(Double(field.duration[n]) / duration - 1) < 0.01)
        // The Friedlander pulse carries Kingery–Bulmash's impulse.
        let steps = 4000
        var impulse = 0.0
        for k in 0..<steps {
            let t = field.arrival[n] + Float((Double(k) + 0.5) / Double(steps)) * field.duration[n]
            impulse += Double(field.overpressure(n, at: t)) * Double(field.duration[n]) / Double(steps)
        }
        #expect(abs(impulse / kb.incidentImpulse(mass: mass) - 1) < 0.02)
        #expect(field.overpressure(n, at: field.arrival[n] - 1e-4) == 0)
        #expect(field.lastArrival > field.arrival[n])
    }

    @Test(
        "Behind a long wall the front comes later and weaker, and over a low one sooner than round a tall one"
    )
    func shadow() {
        let charge = SIMD3<Float>(100 * 4 + 2, 60 * 4 + 2, 0)
        // A wall 20 cells east of the charge, 3 cells thick, 121 long, 10 m and then 40 m high.
        let low = Self.plan(201, blocks: [(120, 0, 122, 120, 10)])
        let tall = Self.plan(201, blocks: [(120, 0, 122, 120, 40)])
        let open = Self.plan(201)
        let behind = 130 + 201 * 60
        let a = LiveWave.field(plan: open, charge: charge, mass: 1000, coefficients: .none)
        let b = LiveWave.field(plan: low, charge: charge, mass: 1000, coefficients: .none)
        let c = LiveWave.field(plan: tall, charge: charge, mass: 1000, coefficients: .none)
        #expect(b.arrival[behind] > a.arrival[behind])
        #expect(c.arrival[behind] > b.arrival[behind])
        #expect(b.peak[behind] < a.peak[behind])
        #expect(c.peak[behind] < b.peak[behind])
        // The path goes over the 10 m wall, hugging it: longer than a string stretched over it
        // through the air (2 m more), shorter than straight up and down it (20 m).
        let over = b.path[behind] - a.path[behind]
        #expect(over > 2 && over < 20)
        #expect(b.excess(behind) > 0.02)
        #expect(a.excess(behind) < 0.001)
        // A cell in front of the wall is as in the open.
        let front = 110 + 201 * 60
        #expect(abs(b.arrival[front] - a.arrival[front]) < 1e-6)
    }

    @Test("A step never cuts the corner of a building between two cells")
    func corners() {
        // Two blocks meeting at a corner, diagonally, leave no gap to pass through.
        let plan = Self.plan(
            41, blocks: [(0, 0, 20, 20, 30), (21, 21, 40, 40, 30)])
        let charge = SIMD3<Float>(30 * 4 + 2, 10 * 4 + 2, 0)
        let (path, straight) = LiveWave.paths(plan: plan, charge: charge)
        // Across the corner, at the other open quarter: over the roofs, 30 m up and down, not
        // through the corner.
        let n = 10 + 41 * 30
        #expect(path[n] > straight[n] + 25)
    }

    @Test("A step knows the cells it crosses and the corners it passes between")
    func stepCells() {
        let diagonal = LiveWave.crossed(1, 1)
        #expect(diagonal.over.isEmpty)
        #expect(diagonal.between.count == 1)
        // (3, −1) passes through the corner at (1.5, −0.5), between (2, 0) and (1, −1).
        let long = LiveWave.crossed(3, -1)
        #expect(
            long.over.count == 2 && long.over.contains { $0 == (1, 0) }
                && long.over.contains { $0 == (2, -1) })
        #expect(long.between.count == 1)
        let pair = long.between[0]
        #expect([pair.0, pair.1].contains { $0 == (2, 0) } && [pair.0, pair.1].contains { $0 == (1, -1) })
        // (2, 1) runs along the edge at x = 1, through two cells' insides and no corner.
        let knight = LiveWave.crossed(2, 1)
        #expect(knight.over.count == 2 && knight.between.isEmpty)
        #expect(LiveWave.steps.count == 32)
    }

    @Test("A plan from a scene matches the learned field's, cell for cell")
    func planFromScene() {
        var scene = ScenarioPreset.streetCanyon.scenario
        scene.charge.position = SIMD3(scene.domainSize.x / 2, scene.domainSize.y / 2, 0.5)
        let plan = LiveWave.Plan(scene: scene, cell: LearnedField.cellSize)
        let learned = LearnedField.Plan(scene: scene)
        #expect(plan.columns == learned.columns && plan.rows == learned.rows)
        #expect(plan.height == learned.height)
        #expect(plan.ground == learned.ground)
    }

    @Test("The cell size coarsens until the plan has few enough cells")
    func cellSize() {
        var scene = ScenarioPreset.streetCanyon.scenario
        #expect(LiveWave.Plan.cellSize(for: scene) == 4)
        scene.domainSize = SIMD3(8000, 8000, 300)
        let cell = LiveWave.Plan.cellSize(for: scene)
        #expect(cell == 8)
        #expect(Double(8000 / cell) * Double(8000 / cell) <= 1_700_000)
    }

    @Test("Friedlander's exponent gives back the impulse share it was asked for")
    func decay() {
        for ratio in [0.45, 0.3, 0.2, 0.1] {
            let b = LiveWave.Table.decay(ratio)
            let share = 1 / b - (1 - exp(-b)) / (b * b)
            #expect(abs(share - ratio) < 1e-6)
        }
        #expect(LiveWave.Table.decay(0.6) == 0)
    }
}

/// The live wave's learned refinement (emmettl/bombcad-work#115), with stand-in networks on the
/// CPU: the GPU's own (BlastCore's `LearnedFieldNetwork`) is checked against PyTorch in
/// BlastCoreTests.
@Suite("Live wave refinement")
struct LiveWaveRefinementTests {
    /// A network giving the same corrections everywhere: the logs of the peak, arrival and impulse.
    final class Constant: LearnedField.Network, @unchecked Sendable {
        let header: LearnedField.Weights.Header
        let corrections: [Float]
        var calls = 0

        init(_ corrections: [Float]) {
            let count = LiveWave.Refinement.inputs.count
            header = LearnedField.Weights.Header(
                format: "bombcad-field-weights-1", model: "unet", width: 1, depth: 4,
                inputs: LiveWave.Refinement.inputs,
                stats: .init(
                    mean: [Double](repeating: 0, count: count), std: [Double](repeating: 2, count: count)),
                residual: true, multiple: 16, groupNormGroups: 0, groupNormEpsilon: 1e-5, dtype: "float32",
                outputs: LiveWave.Refinement.outputs, tensors: [])
            self.corrections = corrections
        }

        func peakChannel(inputs: [Float], rows: Int, columns: Int) throws -> [Float] {
            throw LearnedFieldError.network("not asked")
        }

        func outputChannels(inputs: [Float], rows: Int, columns: Int) throws -> [[Float]] {
            calls += 1
            #expect(rows % 16 == 0 && columns % 16 == 0)
            #expect(inputs.count == LiveWave.Refinement.inputs.count * rows * columns)
            return corrections.map { [Float](repeating: $0, count: rows * columns) }
        }
    }

    static let plan = LiveWaveTests.plan(75, blocks: [(40, 30, 44, 50, 12)])
    static let charge = SIMD3<Float>(100, 150, 0)

    @Test("A correction of nothing is the wave as it was, to the bit")
    func nothing() throws {
        let field = LiveWave.field(plan: Self.plan, charge: Self.charge, mass: 1000)
        let network = Constant([0, 0, 0])
        let refined = try LiveWave.Refinement(network: network).refined(
            field, plan: Self.plan, charge: Self.charge, mass: 1000)
        #expect(network.calls == 1)
        #expect(refined.refined && !field.refined)
        #expect(refined.peak == field.peak && refined.arrival == field.arrival)
        #expect(refined.duration == field.duration && refined.decay == field.decay)
        #expect(refined.path == field.path && refined.lastArrival == field.lastArrival)
        #expect(refined.seconds >= field.seconds + refined.refinementSeconds - 1e-9)
    }

    @Test("The peak, arrival and impulse take their corrections, the impulse through the decay")
    func corrections() throws {
        let field = LiveWave.field(plan: Self.plan, charge: Self.charge, mass: 1000)
        let (dp, da, di): (Float, Float, Float) = (log(1.5), log(0.9), log(1.2))
        let refined = try LiveWave.Refinement(network: Constant([dp, da, di])).refined(
            field, plan: Self.plan, charge: Self.charge, mass: 1000)
        func impulse(_ f: LiveWave.Field, _ n: Int) -> Double {
            Double(f.peak[n]) * Double(f.duration[n]) * LiveWave.DecayTable.share(Double(f.decay[n]))
        }
        var checked = 0
        for n in field.peak.indices where field.arrival[n].isFinite {
            #expect(abs(refined.peak[n] / field.peak[n] - 1.5) < 1e-5)
            #expect(abs(refined.arrival[n] / field.arrival[n] - 0.9) < 1e-5)
            #expect(abs(impulse(refined, n) / impulse(field, n) - 1.2) < 2e-3)
            checked += 1
        }
        #expect(checked > 5000)
        #expect(abs(refined.lastArrival / field.lastArrival - 0.9) < 1e-5)
    }

    @Test("An impulse more than a pulse of no decay holds stretches the positive phase")
    func stretched() throws {
        let field = LiveWave.field(plan: Self.plan, charge: Self.charge, mass: 1000)
        let refined = try LiveWave.Refinement(network: Constant([0, 0, 1.2])).refined(
            field, plan: Self.plan, charge: Self.charge, mass: 1000)
        var stretched = 0
        var decayed = 0
        for n in field.peak.indices where field.arrival[n].isFinite {
            let share = LiveWave.DecayTable.share(Double(field.decay[n]))
            let before = Double(field.peak[n]) * Double(field.duration[n]) * share
            let after =
                Double(refined.peak[n]) * Double(refined.duration[n])
                * LiveWave.DecayTable.share(Double(refined.decay[n]))
            #expect(abs(after / before - exp(1.2)) < 2e-3)
            if share * exp(1.2) >= 0.5 {
                #expect(refined.decay[n] == 0 && refined.duration[n] > field.duration[n])
                stretched += 1
            } else {
                #expect(refined.decay[n] < field.decay[n] && refined.duration[n] == field.duration[n])
                decayed += 1
            }
        }
        #expect(stretched > 0 && decayed > 0 && stretched + decayed > 5000)
    }

    @Test("Corrections are held within their limits")
    func limits() throws {
        let field = LiveWave.field(plan: Self.plan, charge: Self.charge, mass: 1000)
        let refined = try LiveWave.Refinement(network: Constant([5, -5, 0])).refined(
            field, plan: Self.plan, charge: Self.charge, mass: 1000)
        let n = 10 + 75 * 37
        #expect(abs(refined.peak[n] / field.peak[n] - exp(1.5)) < 1e-4)
        #expect(abs(refined.arrival[n] / field.arrival[n] - exp(-0.5)) < 1e-5)
    }

    @Test("The inputs are the plan's and the wave's own, and a field model is not a refinement")
    func features() throws {
        let field = LiveWave.field(plan: Self.plan, charge: Self.charge, mass: 1000)
        let features = LiveWave.features(field: field, plan: Self.plan, charge: Self.charge, mass: 1000)
        let count = 75 * 75
        #expect(features.count == LiveWave.Refinement.inputs.count * count)
        let behind = 60 + 75 * 40
        let open = 10 + 75 * 37
        let root = cbrt(1000.0)
        #expect(features[behind] == 0 && features[count + 42 + 75 * 40] == 1)
        #expect(features[4 * count + behind] > 0.01)
        #expect(features[4 * count + open] == 0)
        #expect(abs(Double(features[5 * count + open]) - log(Double(field.straight[open]) / root)) < 1e-5)
        #expect(abs(Double(features[6 * count + open]) - log(Double(field.peak[open]))) < 1e-5)
        #expect(features[8 * count + open] == 4)
        let header = LearnedFieldTests.StandIn().header
        #expect(!header.isLiveWave)
        #expect(throws: LearnedFieldError.self) {
            try LiveWave.Refinement(network: LearnedFieldTests.StandIn())
        }
    }

    @Test("A training pair's targets are the logs of the run's over the wave's, on its plan and coarsened")
    func pairs() {
        let plan = Self.plan
        let field = LiveWave.field(plan: plan, charge: Self.charge, mass: 1000)
        let count = plan.columns * plan.rows
        let impulse = (0..<count).map { n in
            field.peak[n] * field.duration[n] * Float(LiveWave.DecayTable.share(Double(field.decay[n])))
        }
        // A run of twice the wave's peak, its arrival a tenth late and its impulse as the wave's,
        // with half its cells masked out.
        let run = LiveWaveJudge.Run(
            id: "made", layout: "made", mass: 1000, charge: Self.charge, plan: plan,
            peak: field.peak.map { 2 * $0 }, impulse: impulse, mask: (0..<count).map { $0 % 2 == 1 ? 1 : 0 },
            arrival: field.arrival.map { 1.1 * $0 })
        let fine = LiveWaveJudge.pair(run, coarsen: 1)
        #expect(fine.features.count == LiveWave.Refinement.inputs.count * count)
        for n in [10 + 75 * 37, 61 + 75 * 40] {
            #expect(abs(fine.targets[n] - log(2)) < 1e-5)
            #expect(abs(fine.targets[count + n] - log(1.1)) < 1e-5)
            #expect(abs(fine.targets[2 * count + n]) < 1e-4)
        }
        #expect(fine.targets[11 + 75 * 37].isNaN)
        #expect(fine.sight[10 + 75 * 37] == 1 && fine.sight[61 + 75 * 40] == 0)
        let coarse = LiveWaveJudge.pair(run, coarsen: 2)
        #expect(coarse.plan.columns == 37 && coarse.plan.cell == 8)
        let n = 5 + 37 * 18
        // The mean of its cells' logs over the coarse cell's own wave: near the fine plan's ×2.
        #expect(abs(coarse.targets[n] - log(2)) < 0.1)
        #expect(coarse.features[8 * 37 * 37 + n] == 8)
    }

    @Test("The blend takes the correction whole near the charge and eases it to nothing far out")
    func blend() throws {
        let blend: ClosedRange<Float> = 700...1200
        #expect(LiveWave.Refinement.weight(at: 100, blend: blend) == 1)
        #expect(LiveWave.Refinement.weight(at: 700, blend: blend) == 1)
        #expect(abs(LiveWave.Refinement.weight(at: 950, blend: blend) - 0.5) < 1e-6)
        #expect(LiveWave.Refinement.weight(at: 1200, blend: blend) == 0)
        #expect(LiveWave.Refinement.weight(at: 5000, blend: nil) == 1)
        // On a plan 300 m across, a blend from 100 m to 200 m: whole near, none beyond.
        let field = LiveWave.field(plan: Self.plan, charge: Self.charge, mass: 1000)
        let refined = try LiveWave.Refinement(network: Constant([log(2), 0, 0]), blend: 100...200).refined(
            field, plan: Self.plan, charge: Self.charge, mass: 1000)
        var near = 0
        var far = 0
        for n in field.peak.indices where field.arrival[n].isFinite {
            let ratio = refined.peak[n] / field.peak[n]
            if field.straight[n] <= 100 {
                #expect(abs(ratio - 2) < 1e-4)
                near += 1
            } else if field.straight[n] >= 200 {
                #expect(ratio == 1 && refined.decay[n] == field.decay[n])
                far += 1
            } else {
                #expect(ratio > 1 && ratio < 2)
            }
        }
        #expect(near > 100 && far > 100)
    }

    @Test("A refinement's weights file reads back, without group norms")
    func weightsFile() throws {
        let shapes = LearnedField.Weights.tensorShapes(
            width: 2, depth: 1, outputs: 3, inputs: LiveWave.Refinement.inputs.count, normalised: false)
        let names = LearnedField.Weights.tensorNames(depth: 1, normalised: false)
        #expect(names.count == 3 * 4 + 2)
        #expect(shapes["down.0.body.0.weight"] == [2, 9, 3, 3] && shapes["head.weight"] == [3, 2, 1, 1])
        var entries: [[String: Any]] = []
        var values: [Float] = []
        for name in names {
            let shape = shapes[name]!
            let count = shape.reduce(1, *)
            entries.append(["name": name, "shape": shape, "offset": values.count, "count": count])
            values += [Float](repeating: 0.5, count: count)
        }
        func file(groups: Int = 0, outputs: [String] = LiveWave.Refinement.outputs) throws -> Data {
            let header: [String: Any] = [
                "format": "bombcad-field-weights-1", "model": "unet", "width": 2, "depth": 1,
                "inputs": LiveWave.Refinement.inputs,
                "stats": ["mean": [Double](repeating: 0, count: 9), "std": [Double](repeating: 1, count: 9)],
                "residual": true, "outputs": outputs, "multiple": 2, "groupNormGroups": groups,
                "groupNormEpsilon": 1e-5, "dtype": "float32", "tensors": entries,
            ]
            var text = try JSONSerialization.data(withJSONObject: header)
            text.append(contentsOf: [UInt8](repeating: 0x20, count: (16 - text.count % 16) % 16))
            var data = Data("BCFW".utf8)
            for word in [UInt32(1), UInt32(text.count)] {
                withUnsafeBytes(of: word.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(text)
            for value in values {
                withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            return data
        }
        let weights = try LearnedField.Weights(data: file())
        #expect(weights.header.isLiveWave && !weights.header.normalised && weights.header.headCount == 3)
        #expect(weights.tensors["head.bias"]?.values == [0.5, 0.5, 0.5])
        // With group norms it would want their tensors; with other outputs it is refused.
        #expect(throws: LearnedFieldError.self) { try LearnedField.Weights(data: file(groups: 8)) }
        #expect(throws: LearnedFieldError.self) {
            try LearnedField.Weights(data: file(outputs: ["a", "b", "c"]))
        }
    }
}
