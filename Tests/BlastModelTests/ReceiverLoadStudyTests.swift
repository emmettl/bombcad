import Foundation
import Testing

@testable import BlastModel

@Suite("Receiver load fixtures")
struct ReceiverLoadStudyTests {
    func request() -> ReceiverLoadStudy.Request {
        .init(
            format: "bombcad-receiver-fixtures-1", binS: 1e-4, riseShare: 0.2,
            loads: [.init(id: "declared", peakPa: 1050, impulsePaS: 42)],
            fixtures: [
                .init(
                    id: "pane", kind: .pane, material: .reinforcedConcrete,
                    widthM: 1.2, heightM: 1.5, thicknessM: 0.006)
            ])
    }

    @Test("Raw binned triangles conserve the declared impulse, including limiting rises")
    func conservation() throws {
        for rise in [0.0, 0.2, 1.0] {
            var input = request()
            input.riseShare = rise
            let rows = try ReceiverLoadStudy.evaluate(input)
            #expect(rows.count == 2)
            #expect(abs(rows[0].integratedImpulsePaS - 42) < 1e-9)
            #expect(abs(rows[1].integratedImpulsePaS - 42) > 0.01)
            #expect(rows.allSatisfy { $0.damage != nil })
        }
    }

    @Test("Invalid and oversized declarations refuse the whole study")
    func refusals() {
        var inputs: [ReceiverLoadStudy.Request] = []
        var input = request()
        input.loads.append(input.loads[0])
        inputs.append(input)
        input = request()
        input.binS = 0
        inputs.append(input)
        input = request()
        input.loads[0].peakPa = .nan
        inputs.append(input)
        input = request()
        input.loads[0].impulsePaS = 1e12
        inputs.append(input)
        input = request()
        input.fixtures[0].kind = .facade
        inputs.append(input)
        for input in inputs {
            #expect(throws: ReceiverLoadStudy.Invalid.self) { try ReceiverLoadStudy.evaluate(input) }
        }
    }

    @Test("CLI refuses an existing output without changing its bytes")
    func existingOutput() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appending(path: "input.json")
        let output = folder.appending(path: "output.json")
        try JSONEncoder().encode(request()).write(to: input)
        let marker = Data("preserve".utf8)
        try marker.write(to: output)
        #expect(throws: ReceiverLoadStudy.Invalid.self) {
            try ReceiverLoadStudy.run(["--input", input.path, "--out", output.path])
        }
        #expect(try Data(contentsOf: output) == marker)
    }
}
