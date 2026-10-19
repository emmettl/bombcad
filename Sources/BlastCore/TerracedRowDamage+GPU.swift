import BlastModel
import simd

extension TerracedRowDamage {
    /// Judges `shells`, the row's body, against `rest`, each node's displacement once the row had
    /// settled.
    public init(shells: ShellSolver, rest: [SIMD3<Float>]) {
        self.init(reading: shells, rest: rest)
    }
}

extension ShellSolver: TerracedRowShells {
    package var rowMesh: ShellMesh { mesh }

    package func nodeDisplacements() -> [SIMD3<Float>] {
        var displacements: [SIMD3<Float>] = []
        mutateNodes { nodes in displacements = nodes.map(\.displacement) }
        return displacements
    }

    package func elementDamage() -> [Float] {
        let count = mesh.elements.count
        let damage = displayBuffer.contents().bindMemory(to: Float.self, capacity: max(count, 1))
        return Array(UnsafeBufferPointer(start: damage, count: count))
    }

    package func seats(support: Int) -> (pairs: Int, unseated: Int)? {
        pairSummary(support: support).map { ($0.pairs, $0.unseated) }
    }
}
