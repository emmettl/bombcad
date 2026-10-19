import Foundation
import Testing
import simd

@testable import BlastModel

@Suite("Scenario setup")
struct ScenarioTests {
    @Test("Each piece of a structure is reinforced as it asks")
    func reinforcementSettings() {
        let wall = Box(x: 0...0.25, y: 0...4, height: 3)
        let column = Box(x: 2...2.5, y: 0...0.5, height: 3)
        var model = StructureModel(solids: [wall, column], elementSize: 0.0625)
        model.autoReinforce()
        // Automatic: a mat in each face of the wall, and the column as a column.
        #expect(model.reinforcement.count == 3)
        let automatic = model.reinforcement

        model.setReinforcement(.none, of: 0)
        model.setReinforcement(.column(longitudinal: 0.03, ties: 0.01), of: 1)
        model.autoReinforce()
        #expect(model.reinforcement == [ReinforcementLayer(region: column, ratio: SIMD3(0.01, 0.01, 0.03))])

        model.setReinforcement(.mats(areaPerMetre: 1000e-6, depth: 0.05, bothFaces: false), of: 0)
        model.autoReinforce()
        let mat = model.reinforcement[0]
        // One mat, 50 mm in from the low face across the wall's thickness, smeared over one
        // element: 1000 mm²/m in a 62.5 mm band is a ratio of 1.6% each way along the wall.
        #expect(model.reinforcement.count == 2)
        #expect(abs((mat.region.min.x + mat.region.max.x) / 2 - 0.05) < 1e-6)
        #expect(abs(mat.ratio.y - 0.016) < 1e-6 && abs(mat.ratio.z - 0.016) < 1e-6 && mat.ratio.x == 0)

        // Removing a piece removes its setting with it, so the rest keep theirs.
        model.removeSolid(at: 0)
        #expect(model.solids == [column])
        #expect(model.reinforcement(of: 0) == .column(longitudinal: 0.03, ties: 0.01))
        model.setReinforcement(.automatic, of: 0)
        model.autoReinforce()
        #expect(model.reinforcement == [automatic[2]])
    }

    @Test("A layout saved before newer settings existed still opens, with their defaults")
    func olderLayouts() throws {
        var scenario = ScenarioPreset.blastWall.scenario
        scenario.structure?.setReinforcement(.none, of: 0)
        scenario.structure?.autoReinforce()
        let data = try JSONEncoder().encode(scenario)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var structure = try #require(json["structure"] as? [String: Any])
        var material = try #require(structure["material"] as? [String: Any])
        // Settings added to the material and the structure after the first saved layouts.
        for key in ["crackResidual", "aggregateSize"] {
            #expect(material.removeValue(forKey: key) != nil, "\(key) should be saved")
        }
        #expect(structure.removeValue(forKey: "solidReinforcement") != nil)
        structure["material"] = material
        json["structure"] = structure
        let old = try JSONSerialization.data(withJSONObject: json)

        let opened = try JSONDecoder().decode(Scenario.self, from: old)
        var expected = scenario
        expected.structure?.solidReinforcement = []
        #expect(opened == expected)
        #expect(opened.structure?.material.crackResidual == 0.1)
        #expect(opened.structure?.material.aggregateSize == 0.016)
        // The saved bars are kept as they were; the setting reads as automatic.
        #expect(opened.structure?.reinforcement == scenario.structure?.reinforcement)
        #expect(opened.structure?.reinforcement(of: 0) == .automatic)
    }

    @Test("The Kinney-Graham reference curve has the expected shape")
    func kinneyGraham() {
        // Roughly 10 atmospheres at a scaled distance of 1 m/kg^(1/3), falling monotonically.
        let atOne = KinneyGraham.peakOverpressureRatio(scaledDistance: 1)
        #expect(atOne > 9 && atOne < 11)
        let distances = stride(from: 0.2, through: 40, by: 0.2)
        let values = distances.map { KinneyGraham.peakOverpressureRatio(scaledDistance: $0) }
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 > $1 })
        #expect(
            abs(KinneyGraham.peakOverpressure(mass: 8, range: 2) - 101_325 * atOne) < 1)
    }
}

@Suite("Blast validation")
struct BlastValidationTests {
    @Test("The Kingery-Bulmash polynomials reproduce Swisdak's tables and the IATG examples")
    func kingeryBulmashCurves() throws {
        // Rows of Swisdak's Table 3: Z, arrival (ms), incident and reflected pressure (kPa),
        // duration (ms), incident and reflected impulse (kPa ms), all per kg^(1/3).
        let rows: [[Double]] = [
            [1.0, 0.467, 1354, 8152, 1.720, 236.3, 884.7],
            [2.0, 1.693, 283.7, 1058, 2.053, 134.6, 363.8],
            [5.0, 8.242, 43.23, 100.9, 3.793, 59.31, 125.6],
            [10.0, 21.66, 14.89, 31.54, 4.779, 31.04, 59.33],
            [20.0, 49.93, 6.102, 12.44, 5.940, 15.89, 28.67],
        ]
        for row in rows {
            let point = try #require(KingeryBulmash.point(at: row[0]))
            let duration = try #require(KingeryBulmash.scaledDuration(at: row[0]))
            let pairs = [
                (point.scaledArrival * 1000, row[1]), (point.incidentPressure / 1000, row[2]),
                (point.reflectedPressure / 1000, row[3]), (duration * 1000, row[4]),
                (point.scaledIncidentImpulse, row[5]), (point.scaledReflectedImpulse, row[6]),
            ]
            for (value, table) in pairs {
                #expect(abs(value - table) / table < 0.01, "Z = \(row[0]): \(value) against \(table)")
            }
        }
        #expect(abs((KingeryBulmash.shockVelocity(at: 5) ?? 0) - 398) < 4)
        // The independent IATG worked examples agree with the curves within a few per cent.
        for example in KingeryBulmash.hemisphericalSurfaceBurst {
            let point = try #require(KingeryBulmash.point(at: example.scaledDistance))
            #expect(abs(point.incidentPressure / example.incidentPressure - 1) < 0.06)
            #expect(abs(point.scaledReflectedImpulse / example.scaledReflectedImpulse - 1) < 0.06)
            #expect(abs(point.scaledArrival / example.scaledArrival - 1) < 0.06)
        }
        #expect(KingeryBulmash.point(at: 0.1) == nil)
    }

    @Test("The Kingery-Bulmash reference points scale as tabulated")
    func kingeryBulmashPoints() {
        let points = KingeryBulmash.hemisphericalSurfaceBurst
        #expect(points.count == 3)
        // The middle row of the source table: 10,000 kg at 50 m.
        let middle = points[1]
        #expect(abs(middle.range(mass: 10_000) - 50) < 1e-9)
        #expect(abs(middle.incidentPressure - 202_000) < 1)
        #expect(abs(middle.reflectedImpulse(mass: 10_000) - 6550) < 1e-6)
        #expect(abs(middle.arrival(mass: 10_000) - 0.0481) < 1e-9)
        #expect(zip(points, points.dropFirst()).allSatisfy { $0.scaledDistance < $1.scaledDistance })
    }

    @Test("A line of gauges stands at the charge's scaled distances, on the terrain, inside the domain")
    func gaugeLine() throws {
        // 500 t, cube root 79.37 kg^(1/3): Z = 10 is 794 m out, Z = 14 would be 1,111 m.
        var scenario = Scenario(
            name: "Field", domainSize: SIMD3(1000, 600, 200), boxes: [],
            charge: Charge(mass: 500_000, position: SIMD3(100, 300, 0)))
        #expect(scenario.roomiestGaugeLineDirection == SIMD2(1, 0))
        let line = scenario.gaugeLine(direction: scenario.roomiestGaugeLineDirection)
        #expect(line.map(\.name).first == "Z 1 · 79 m")
        #expect(line.count == 8)
        #expect(line.last.map { abs($0.position.x - (100 + 10 * Float(cbrt(500_000.0)))) < 0.01 } == true)
        #expect(line.allSatisfy { $0.position.y == 300 && $0.position.z == 1.5 })
        scenario.terrain = .slope(domain: scenario.domainSize, spacing: 5, foot: 400, angle: 10)
        for gauge in scenario.gaugeLine(direction: SIMD2(1, 0)) {
            let ground = scenario.terrain!.height(at: gauge.position)
            #expect(abs(gauge.position.z - ground - 1.5) < 1e-4)
        }
        // Nothing beyond the domain, and nothing for a charge of no mass.
        #expect(scenario.gaugeLine(direction: SIMD2(0, -1)).count == 4)
        scenario.charge.mass = 0
        #expect(scenario.gaugeLine(direction: SIMD2(1, 0)).isEmpty)
    }
}
