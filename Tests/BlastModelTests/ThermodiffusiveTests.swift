import Foundation
import Testing

@testable import BlastModel

@Suite("A lean hydrogen flame's thermodiffusive response")
struct ThermodiffusiveTests {
    @Test("Lean hydrogen's Lewis number, and none rich or for the other gases")
    func lewisNumbers() throws {
        let lean = try #require(FlammableGas.hydrogen.lewisNumber(fraction: 0.18))
        #expect(abs(lean - 0.389) < 1e-3)
        #expect(abs((FlammableGas.hydrogen.lewisNumber(fraction: 0.295) ?? 0) - 0.428) < 2e-3)
        #expect(FlammableGas.hydrogen.lewisNumber(fraction: 0.35) == nil)
        #expect(FlammableGas.methane.lewisNumber(fraction: 0.095) == nil)
        #expect(FlammableGas.propane.lewisNumber(fraction: 0.04) == nil)
    }

    @Test("The default flame burns lean hydrogen 1/Le faster; laminar flames and other gases unchanged")
    func factor() {
        let flame = FlameAcceleration()
        #expect(abs(flame.thermodiffusiveFactor(gas: .hydrogen, fraction: 0.18) - 1 / 0.389) < 0.01)
        #expect(flame.thermodiffusiveFactor(gas: .hydrogen, fraction: 0.42) == 1)
        #expect(flame.thermodiffusiveFactor(gas: .methane, fraction: 0.095) == 1)
        #expect(FlameAcceleration.laminar.thermodiffusiveFactor(gas: .hydrogen, fraction: 0.18) == 1)
    }

    @Test("Files saved without it keep their flame; new ones round-trip it")
    func coding() throws {
        var old = FlameAcceleration()
        old.thermodiffusive = nil
        var json =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(FlameAcceleration()))
            as! [String: Any]
        json.removeValue(forKey: "thermodiffusive")
        let decoded = try JSONDecoder().decode(
            FlameAcceleration.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == old)
        let fresh = try JSONDecoder().decode(
            FlameAcceleration.self, from: JSONEncoder().encode(FlameAcceleration()))
        #expect(fresh.thermodiffusive == .inverseLewis)
    }
}
