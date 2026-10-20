import Testing
import simd

@testable import BlastModel

@Suite("Experimental rigid-box coupling", .serialized)
struct ExperimentalRigidBoxTests {
    @Test("Connected remapping preserves a uniform field and transports gradients around solid cells")
    func connectedRemap() throws {
        let old = (0..<9).map { $0 == 4 || $0 == 8 }
        let new = (0..<9).map { $0 == 0 || $0 == 4 }
        func neighbours(_ n: Int) -> [Int] {
            let x = n % 3
            let y = n / 3
            return [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                .filter { $0.0 >= 0 && $0.0 < 3 && $0.1 >= 0 && $0.1 < 3 }
                .map { $0.0 + 3 * $0.1 }
        }
        for gradient in [false, true] {
            let cells = (0..<9).map { n in
                CellState(
                    Primitive(
                        density: gradient ? 1 + Float(n) : 1.225,
                        velocity: SIMD3(1, 2, 3), pressure: gradient ? 101325 + 100 * Float(n) : 101325),
                    gamma: 1.4)
            }
            let remapped = try ConservativeCellRemap.apply(
                cells, oldSolid: old, newSolid: new, mode: .connectedTransport, neighbours: neighbours)
            func sum(_ field: [CellState], mask: [Bool]) -> SIMD8<Double> {
                field.indices.filter { !mask[$0] }.reduce(.zero) { total, n in
                    let c = field[n]
                    return total
                        + SIMD8(
                            Double(c.density), Double(c.momentumX), Double(c.momentumY),
                            Double(c.momentumZ), Double(c.energy), 0, 0, 0)
                }
            }
            #expect(sum(cells, mask: old) == sum(remapped, mask: new))
            #expect(remapped[4].energy == cells[4].energy)
            if !gradient {
                for n in cells.indices where !new[n] {
                    #expect(remapped[n].density == cells[0].density)
                    #expect(remapped[n].energy == cells[0].energy)
                }
            }
        }
        let cells = Array(
            repeating: CellState(Primitive(density: 1.225, pressure: 101325), gamma: 1.4), count: 3)
        #expect(throws: ConservativeCellRemap.Failure.self) {
            try ConservativeCellRemap.apply(
                cells, oldSolid: [false, true, true],
                newSolid: [true, true, false], mode: .connectedTransport
            ) { n in
                [n - 1, n + 1].filter { (0..<3).contains($0) }
            }
        }
    }
}
