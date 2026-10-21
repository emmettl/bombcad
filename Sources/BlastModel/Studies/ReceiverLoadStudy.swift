import Foundation
import simd

/// Hypothetical uniform component loads from declared peak/impulse pairs. This does not infer
/// building loads from receiver points or change dataset admission or product defaults.
package enum ReceiverLoadStudy {
    package struct Load: Codable, Sendable {
        package var id: String
        package var peakPa: Double
        package var impulsePaS: Double
    }

    package struct Fixture: Codable, Sendable {
        package var id: String
        package var kind: EnvelopeComponent.Kind
        package var material: EnvelopeConstruction.Kind
        package var widthM: Float
        package var heightM: Float
        package var thicknessM: Float
    }

    package struct Request: Codable, Sendable {
        package var format: String
        package var binS: Double
        package var riseShare: Double
        package var loads: [Load]
        package var fixtures: [Fixture]
    }

    package struct Row: Codable, Sendable {
        package var load: String
        package var fixture: String
        package var policy: String
        package var integratedImpulsePaS: Double
        package var damage: EnvelopeComponentDamage?
    }

    enum Invalid: Error, CustomStringConvertible {
        case input(String)
        var description: String {
            switch self {
            case .input(let message): message
            }
        }
    }

    package static func evaluate(_ input: Request) throws -> [Row] {
        guard input.format == "bombcad-receiver-fixtures-1",
            input.binS.isFinite, (1e-6...0.1).contains(input.binS),
            input.riseShare.isFinite, (0...1).contains(input.riseShare),
            !input.loads.isEmpty, !input.fixtures.isEmpty,
            input.loads.count <= 1000, input.fixtures.count <= 100,
            input.loads.count * input.fixtures.count <= 10000,
            Set(input.loads.map(\.id)).count == input.loads.count,
            Set(input.fixtures.map(\.id)).count == input.fixtures.count
        else { throw Invalid.input("format, step, rise, unique IDs or bounded nonempty inputs invalid") }
        for load in input.loads {
            guard !load.id.isEmpty, load.peakPa.isFinite, load.peakPa > 0,
                load.impulsePaS.isFinite, load.impulsePaS > 0,
                4 * load.impulsePaS / load.peakPa / input.binS <= 1_000_000
            else { throw Invalid.input("invalid or oversized pulse: \(load.id)") }
        }
        for fixture in input.fixtures {
            guard !fixture.id.isEmpty, [.wall, .roof, .pane].contains(fixture.kind),
                fixture.thicknessM < min(fixture.widthM, fixture.heightM),
                [fixture.widthM, fixture.heightM, fixture.thicknessM].allSatisfy({
                    $0.isFinite && $0 > 0 && $0 <= 100
                })
            else { throw Invalid.input("invalid component fixture: \(fixture.id)") }
        }
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        var rows: [Row] = []
        for fixture in input.fixtures {
            let roof = fixture.kind == .roof
            let region = Box(
                min: .zero,
                max: roof
                    ? SIMD3(fixture.widthM, fixture.heightM, fixture.thicknessM)
                    : SIMD3(fixture.widthM, fixture.thicknessM, fixture.heightM))
            let component = EnvelopeComponent(
                id: fixture.id, owner: owner, kind: fixture.kind, region: region,
                axis: roof ? 2 : 1, outward: 1, source: 0, panel: 0,
                supportEdges: [true, true, true, true])
            let construction = EnvelopeConstruction(
                objectID: owner, walls: fixture.material, wallThicknessM: fixture.thicknessM,
                roof: fixture.material, roofThicknessM: fixture.thicknessM,
                glassThicknessM: fixture.thicknessM, source: .user,
                detail: "Declared uniform-load sensitivity fixture; other construction assumptions default")
            for load in input.loads {
                let prediction = FacadeLoadSurrogate.Prediction(
                    peakPa: load.peakPa, impulsePaS: load.impulsePaS,
                    riseShare: input.riseShare, arrivalS: 0)
                for policy in ["raw", "product-3pct"] {
                    let pulse: EnvelopeComponentLoad
                    if policy == "product-3pct" {
                        pulse = FacadeLoadSurrogate.load(component, prediction, binS: input.binS)
                    } else {
                        let pressures = FacadeLoadSurrogate.pulse(
                            peak: load.peakPa, impulse: load.impulsePaS,
                            riseShare: input.riseShare, binS: input.binS)
                        pulse = EnvelopeComponentLoad(
                            id: component.id, owner: owner,
                            kind: EnvelopeComponentLoad.Kind(rawValue: component.kind.rawValue)!,
                            region: region, axis: component.axis, binS: input.binS,
                            outerPa: pressures, innerPa: [], supportEdges: component.supportEdges)
                    }
                    rows.append(
                        Row(
                            load: load.id, fixture: fixture.id, policy: policy,
                            integratedImpulsePaS: pulse.outerPa.reduce(0, +) * input.binS,
                            damage: EnvelopeDamageAssessment.assess(pulse, construction: construction)))
                }
            }
        }
        return rows
    }

    /// `blastmodel receiver-fixtures --input declared.json --out new-results.json`.
    package static func run(_ args: [String]) throws {
        guard let path = SurrogateBench.value(args, "input"),
            let output = SurrogateBench.value(args, "out"),
            !FileManager.default.fileExists(atPath: output)
        else { throw Invalid.input("--input JSON and --out NEW-JSON required") }
        let input = try JSONDecoder().decode(Request.self, from: Data(contentsOf: URL(filePath: path)))
        let rows = try evaluate(input)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: URL(filePath: output), options: .withoutOverwriting)
        print("\(rows.count) fixture/pulse assessments; receiver-to-uniform-load sensitivity only")
    }
}
