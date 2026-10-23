import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Craters and ground that takes energy")
struct CraterTests {
    @Test("Cooper's scaling gives his worked examples")
    func cooperExamples() {
        // Example 29.1: 215 lb of picric acid, 123 lb of TNT equivalent, half buried in glacial soil
        // (E_CR 0.75), P_CJ 7.94 GPa: a crater of 3.8 ft radius.
        let k = 0.46 + 0.027 * Float(7.94)
        let buried = CraterEstimate.cooperRadius(
            pounds: 123, efficiency: 0.75, radiusConstant: k, heightOfBurst: 0)
        #expect(abs(buried - 3.84) < 0.01)
        // Example 29.2: the same drum on a 30 in table, its centre 3.67 charge radii up: 0.65 ft.
        let raised = CraterEstimate.cooperRadius(
            pounds: 123, efficiency: 0.75, radiusConstant: k, heightOfBurst: 3.67)
        #expect(abs(raised - 0.65) < 0.005)
        // Equation 29.3's constant for TNT in the Nevada alluvium, and ANFO's from figure 29.6.
        #expect(CraterExplosive.tnt.radiusConstant == 0.97)
        #expect(abs(CraterExplosive.anfo.radiusConstant - 0.6085) < 1e-4)
    }

    @Test("A tonne of TNT centred on alluvium: Cooper's radius, half as deep, a third either way")
    func estimate() throws {
        let charge = Charge(mass: 1000, position: SIMD3(10, 20, 0))
        let crater = try #require(CraterEstimate(charge: charge, groundHeight: 0, ground: .alluvium))
        // 0.97 (2 × 0.5 × 2,204.62)^(1/3) ft = 12.63 ft = 3.849 m.
        #expect(abs(crater.apparentRadius - 3.849) < 0.002)
        #expect(abs(crater.apparentDepth - crater.apparentRadius / 2) < 1e-6)
        #expect(abs(crater.radiusRange.lowerBound - crater.apparentRadius * 2 / 3) < 1e-5)
        #expect(abs(crater.radiusRange.upperBound - crater.apparentRadius * 4 / 3) < 1e-5)
        #expect(crater.centre == SIMD3(10, 20, 0) && crater.heightOfBurst == 0)
        #expect(abs(crater.groundShare - 0.333) < 1e-6)
        // Cube-root scaling: eight times the mass, twice the radius.
        let bigger = try #require(
            CraterEstimate(charge: Charge(mass: 8000, position: .zero), groundHeight: 0, ground: .alluvium))
        #expect(abs(bigger.apparentRadius / crater.apparentRadius - 2) < 1e-4)
        // Saturated soil digs (2 / 0.5)^(1/3) times as wide; ANFO 0.61 / 0.97 as wide as TNT.
        let wet = try #require(CraterEstimate(charge: charge, groundHeight: 0, ground: .saturated))
        #expect(abs(wet.apparentRadius / crater.apparentRadius - cbrt(4)) < 1e-4)
        let soft = try #require(
            CraterEstimate(charge: charge, groundHeight: 0, ground: .alluvium, explosive: .anfo))
        #expect(abs(soft.apparentRadius / crater.apparentRadius - 0.6085 / 0.97) < 1e-4)
        // Rigid ground digs none, nor does a charge of no mass.
        #expect(CraterEstimate(charge: charge, groundHeight: 0, ground: .rigid) == nil)
        #expect(
            CraterEstimate(charge: Charge(mass: 0, position: .zero), groundHeight: 0, ground: .clay) == nil)
    }

    @Test("Height of burst is to the charge's centre, in charge radii; high bursts dig nothing")
    func heightOfBurst() throws {
        let radius = CraterEstimate.chargeRadius(mass: 1000)
        // A sphere of 1,600 kg/m³: 0.5304 m for a tonne.
        #expect(abs(radius - 0.5304) < 1e-4)
        // Centred on the ground, or below it: a surface burst. Resting on it: a radius up.
        let centred = Charge(mass: 1000, position: SIMD3(0, 0, 5))
        #expect(CraterEstimate.heightOfBurst(centred, groundHeight: 5) == 0)
        #expect(
            CraterEstimate.heightOfBurst(Charge(mass: 1000, position: SIMD3(0, 0, 4)), groundHeight: 5) == 0)
        let resting = Charge(mass: 1000, position: SIMD3(0, 0, 5 + radius))
        #expect(abs(CraterEstimate.heightOfBurst(resting, groundHeight: 5) - 1) < 1e-5)
        // A radius up, the crater's energy is e^(−1.457) of a surface burst's.
        let up = try #require(CraterEstimate(charge: resting, groundHeight: 5, ground: .alluvium))
        let down = try #require(CraterEstimate(charge: centred, groundHeight: 5, ground: .alluvium))
        #expect(abs(up.apparentRadius / down.apparentRadius - exp(-1.457 / 3)) < 1e-4)
        #expect(up.centre.z == 5)
        // The air's share still tapers from the underside: resting, its ground share is a surface
        // burst's.
        #expect(CraterEstimate.couplingHeight(resting, groundHeight: 5) == 0)
        #expect(abs(up.groundShare - 0.333) < 1e-6)
        // Above 3.2 radii to the centre, an air burst.
        let high = Charge(mass: 1000, position: SIMD3(0, 0, 5 + 3.3 * radius))
        #expect(CraterEstimate(charge: high, groundHeight: 5, ground: .alluvium) == nil)
    }

    @Test("Glacial soil digs H. F. Cooper's wet-soil crater: Suffield's resting 500-ton spheres in the band")
    func glacialSoil() throws {
        let mass: Float = 500 * 907.185
        // Centred: 1.2 (4,000 × 500)^(1/3) ft = 151.2 ft, 46.09 m.
        let centred = try #require(
            CraterEstimate(charge: Charge(mass: mass, position: .zero), groundHeight: 0, ground: .glacialSoil)
        )
        #expect(abs(centred.apparentRadius - 46.09) < 0.02)
        // Resting, its centre a radius up: H solves at 0.134, 73.1 m across. Prairie Flat's 85.5 m
        // and Dial Pack's 70.1 m are 1.17 and 0.96 of it, inside the band.
        let lifted = Charge(mass: mass, position: SIMD3(0, 0, CraterEstimate.chargeRadius(mass: mass)))
        let resting = try #require(CraterEstimate(charge: lifted, groundHeight: 0, ground: .glacialSoil))
        #expect(abs(resting.apparentDiameter - 73.1) < 0.1)
        for measured: Float in [85.5, 70.1] {
            #expect(
                2 * resting.radiusRange.lowerBound < measured && measured < 2 * resting.radiusRange.upperBound
            )
        }
        // ANFO scales it as P. W. Cooper's K does.
        let anfo = try #require(
            CraterEstimate(
                charge: Charge(mass: mass, position: .zero), groundHeight: 0, ground: .glacialSoil,
                explosive: .anfo))
        #expect(abs(anfo.apparentRadius / centred.apparentRadius - 0.6085 / 0.97) < 1e-4)
    }

    @Test("On earth a charge keeps 0.9 of its mass for the air, less so with height; rigid ground none")
    func coupling() {
        let charge = Charge(mass: 100, position: SIMD3(1, 2, 0))
        #expect(charge.coupled(to: .rigid, groundHeight: 0) == charge)
        #expect(abs(charge.coupled(to: .clay, groundHeight: 0).mass - 90) < 1e-4)
        let radius = CraterEstimate.chargeRadius(mass: 100)
        // A sphere resting on the ground is a surface burst; its underside a radius up, it keeps
        // 1 − 0.1 e^(−1.457), 97.7%.
        let resting = Charge(mass: 100, position: SIMD3(1, 2, radius))
        #expect(abs(resting.coupled(to: .rock, groundHeight: 0).mass - 90) < 1e-4)
        let raised = Charge(mass: 100, position: SIMD3(1, 2, 2 * radius))
        #expect(abs(raised.coupled(to: .rock, groundHeight: 0).mass - 100 * (1 - 0.1 * exp(-1.457))) < 1e-3)
        #expect(GroundType.alluvium.surfaceYieldRatio == (1.8, 1.5, 2))
        #expect(GroundType.rigid.surfaceYieldRatio == (2, 2, 2))
        // The scene: every charge, and nothing else; rigid ground leaves it exactly as it was.
        var scenario = Scenario(
            name: "Two", domainSize: SIMD3(repeating: 20), boxes: [], charge: charge)
        scenario.additionalCharges = [Charge(mass: 10, position: SIMD3(5, 5, 0))]
        #expect(scenario.coupled(to: .rigid) == scenario)
        let coupled = scenario.coupled(to: .saturated)
        #expect(abs(coupled.charge.mass - 90) < 1e-4 && abs(coupled.additionalCharges![0].mass - 9) < 1e-5)
        #expect(coupled.charge.position == charge.position && coupled.domainSize == scenario.domainSize)
    }

    @Test("The crater's profile: a bowl up to the original ground, the lip's crest, and thinning ejecta")
    func profile() throws {
        let crater = try #require(
            CraterEstimate(charge: Charge(mass: 1000, position: .zero), groundHeight: 0, ground: .alluvium))
        let radius = crater.apparentRadius
        // Glasstone and Dolan's proportions: the crest a quarter of the depth high at 1.25 radii.
        #expect(abs(crater.lipHeight - crater.apparentDepth / 4) < 1e-6)
        #expect(
            abs(crater.lipCrestRadius - 1.25 * radius) < 1e-5 && abs(crater.lipRadius - 2.5 * radius) < 1e-5)
        #expect(abs(crater.change(atDistance: 0) + crater.apparentDepth) < 1e-6)
        #expect(abs(crater.change(atDistance: radius)) < 1e-6)
        #expect(abs(crater.change(atDistance: 1.25 * radius) - crater.lipHeight) < 1e-5)
        // Thinning beyond the crest, and nothing past the ejecta's reach.
        #expect(crater.change(atDistance: 1.8 * radius) < crater.lipHeight / 3)
        #expect(crater.change(atDistance: 1.8 * radius) > 0)
        #expect(
            abs(crater.change(atDistance: 2.5 * radius)) < 1e-6 && crater.change(atDistance: 3 * radius) == 0)
        #expect(crater.change(at: SIMD2(0, radius / 2)) == crater.change(atDistance: radius / 2))
        // The lip holds about two thirds of the bowl's volume: Glasstone and Dolan's ejecta are
        // 55% of the apparent crater's mass, before the upturned rim (§6.75).
        var bowl = 0.0
        var lip = 0.0
        let dr = Double(radius) / 2000
        for k in 0..<6000 {
            let r = (Double(k) + 0.5) * dr
            let z = Double(crater.change(atDistance: Float(r)))
            if z < 0 { bowl -= 2 * .pi * r * z * dr } else { lip += 2 * .pi * r * z * dr }
        }
        #expect(lip / bowl > 0.55 && lip / bowl < 0.8, "lip/bowl \(lip / bowl)")
    }

    @Test(
        "Below a shallow water table the walls slump to 10–15°: a fifth as deep; deep water changes nothing")
    func waterTable() throws {
        // 500 short tons of TNT resting on Suffield's glacial soil.
        let mass: Float = 500 * 907.185
        let charge = Charge(mass: mass, position: SIMD3(0, 0, CraterEstimate.chargeRadius(mass: mass)))
        let dry = try #require(CraterEstimate(charge: charge, groundHeight: 0, ground: .glacialSoil))
        #expect(
            abs(dry.apparentRadius - 36.55) < 0.05 && abs(dry.apparentDepth - dry.apparentRadius / 2) < 1e-4)
        #expect(dry.waterTable == nil && dry.depthRange == nil)
        // The water 1.5 m down: R tan 12.5° / 2, 4.05 m (3.22 to 4.90 for 10 to 15°).
        let wet = try #require(
            CraterEstimate(charge: charge, groundHeight: 0, ground: .glacialSoil, waterTable: 1.5))
        func slumped(_ degrees: Float) -> Float { dry.apparentRadius * tan(degrees * .pi / 180) / 2 }
        #expect(abs(wet.apparentDepth - slumped(12.5)) < 1e-3 && abs(wet.apparentDepth - 4.05) < 0.01)
        #expect(
            abs(wet.depthRange!.lowerBound - slumped(10)) < 1e-3
                && abs(wet.depthRange!.upperBound - slumped(15)) < 1e-3)
        #expect(wet.apparentRadius == dry.apparentRadius && wet.waterTable == 1.5)
        #expect(abs(wet.lipHeight - wet.apparentDepth / 4) < 1e-6)
        #expect(wet.summary.contains("slumped below the water table 1.5 m down"))
        // Between the slumped depth and the dry one, the crater reaches down to the water table.
        let middle = try #require(
            CraterEstimate(charge: charge, groundHeight: 0, ground: .glacialSoil, waterTable: 8))
        #expect(middle.apparentDepth == 8 && middle.depthRange == 8...8)
        // Deeper than the dry crater: no change, to the bit.
        let deep = try #require(
            CraterEstimate(charge: charge, groundHeight: 0, ground: .glacialSoil, waterTable: 20))
        #expect(deep == dry)
        // Saturated soil lies below a water table at the surface.
        #expect(GroundType.saturated.typicalWaterTable == 0 && GroundType.clay.typicalWaterTable == nil)
    }

    @Test("A crater cuts into a terrain lifted above the floor, and refuses to go below it")
    func cratered() throws {
        let terrain = Terrain(
            origin: .zero, spacing: 0.5, columns: 41, rows: 41,
            heights: [Float](repeating: 10, count: 41 * 41))
        let crater = try #require(
            CraterEstimate(
                charge: Charge(mass: 1000, position: SIMD3(10, 10, 10)), groundHeight: 10, ground: .clay))
        let cut = try terrain.cratered([crater])
        #expect(abs(cut.height(at: SIMD3(10, 10, 0)) - (10 - crater.apparentDepth)) < 1e-5)
        #expect(cut.height(at: SIMD3(0, 0, 0)) == 10)
        let shallow = Terrain(
            origin: .zero, spacing: 0.5, columns: 41, rows: 41, heights: [Float](repeating: 1, count: 41 * 41)
        )
        #expect(throws: Terrain.Failure.self) { try shallow.cratered([crater]) }
    }

    @Test("The USD scene shows the crater growing from the first frame, the ground open under it")
    func usd() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "crater-usd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var scenario = Scenario(
            name: "Open", domainSize: SIMD3(40, 40, 10), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(20, 20, 0)))
        let craters = CraterEstimate.craters(of: scenario, ground: .clay)
        let crater = try #require(craters.first)
        let flatURL = folder.appending(path: "flat.usda")
        let flat = try USDSceneWriter(url: flatURL, scenario: scenario, frameInterval: 0.001)
        for _ in 0..<3 { try flat.append(nil) }
        flat.addCraters(craters)
        try flat.finish()
        let text = try String(contentsOf: flatURL, encoding: .utf8)
        let mesh = try #require(text.components(separatedBy: "def Mesh \"Crater\"").last)
        // Flat at frame 0, growing at 1 and 2, 2 ms after the blast, then on in a tail after the
        // run until it has formed (see CraterGrowthTests).
        #expect(mesh.contains("point3f[] points.timeSamples = {") && mesh.contains("            2: ["))
        let samples = flat.craterSamples(crater)
        #expect(samples.prefix(3).map(\.code) == [0, 1, 2] && samples.last?.bowl == 1)
        #expect(text.contains("double craterTailStartTimeCode = 3"))
        #expect(mesh.contains("bombcad:label = \"\(crater.summary)\""))
        // The ground plane in eight rectangles round the crater's square.
        let ground = try #require(text.components(separatedBy: "def Mesh \"Ground\"").last)
        let counts = try #require(
            ground.components(separatedBy: "faceVertexCounts = [").dropFirst().first?.prefix { $0 != "]" })
        #expect(counts.split(separator: ",").count == 8)
        // Over a terrain, its quads under the patch are left out.
        scenario.terrain = Terrain(
            spacing: 1, columns: 41, rows: 41, heights: [Float](repeating: 5, count: 41 * 41))
        scenario.terrain!.heights[0] = 6
        scenario.charge.position.z = 5
        let hilly = folder.appending(path: "terrain.usda")
        let writer = try USDSceneWriter(url: hilly, scenario: scenario, frameInterval: 0.001)
        try writer.append(nil)
        writer.addCraters(CraterEstimate.craters(of: scenario, ground: .clay))
        try writer.finish()
        let terrain = try #require(
            String(contentsOf: hilly, encoding: .utf8).components(separatedBy: "def Mesh \"Terrain\"").last)
        let quads = try #require(
            terrain.components(separatedBy: "faceVertexCounts = [").dropFirst().first?.prefix { $0 != "]" })
        #expect(quads.split(separator: ",").count < 40 * 40)
    }

    @Test("Soft ground names its standing and adds the crater's")
    func standing() {
        let scenario = Scenario(
            name: "Open", domainSize: SIMD3(repeating: 40), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(20, 20, 0)))
        var configuration = SolverConfiguration()
        let rigid = SceneStanding(
            StandingInputs(scenario: scenario, cellSize: 0.5, configuration: configuration))
        #expect(!rigid.results.contains { $0.kind == .crater })
        configuration.ground = .glacialSoil
        let soft = SceneStanding(
            StandingInputs(scenario: scenario, cellSize: 0.5, configuration: configuration))
        let crater = soft.results.first { $0.kind == .crater }
        #expect(crater?.level == .approximation)
        #expect(
            StandingInputs(scenario: scenario, cellSize: 0.5, configuration: configuration).options.contains(
                .groundCoupling))
        let peak = soft.results.first { $0.kind == .peakOverpressure }
        #expect(peak?.options.contains(StandingTable.entry(for: .groundCoupling).title) == true)
        #expect(soft.unsupported.first { $0.contains("crater is estimated") } != nil)
    }
}
