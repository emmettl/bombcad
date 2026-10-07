import BlastCore
import Foundation
import Observation
import simd

/// Explicit comparisons are cancellable and cannot change the live simulation or chosen grid.
@MainActor @Observable
final class ImportResolutionStudy {
    struct Row: Identifiable, Sendable {
        var cellSize: Float
        var preview: ImportedMesh.Preview?
        var error: String?
        var id: Float { cellSize }
        var volume: Float? { preview.map { Float($0.occupiedCells) * pow(cellSize, 3) } }
        func counts() -> [Int: Int] {
            guard let preview, let ids = preview.boxPartIDs else { return [:] }
            var cells: [Int: Int] = [:]
            for (n, box) in preview.boxes.enumerated() where ids.indices.contains(n) {
                let size = box.size / cellSize
                cells[ids[n], default: 0] += Int((size.x * size.y * size.z).rounded())
            }
            return cells
        }
    }
    private(set) var rows: [Row] = []
    private(set) var isRunning = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    func compare(mesh: ImportedMesh, baseline: ImportedMesh.Preview, domain: SIMD3<Float>) {
        cancel()
        rows = []
        isRunning = true
        let token = generation
        task = Task {
            let sampling = Task.detached(priority: .userInitiated) {
                () -> [Row] in
                var rows: [Row] = []
                for h: Float in [0.5, 0.25, 0.125] {
                    if Task.isCancelled { return [] }
                    do {
                        let preview =
                            h == baseline.cellSize
                            ? baseline : try mesh.preview(cellSize: h, domain: domain, allowEmpty: true)
                        rows.append(Row(cellSize: h, preview: preview))
                    } catch is CancellationError { return [] } catch {
                        rows.append(Row(cellSize: h, error: error.localizedDescription))
                    }
                }
                return rows
            }
            let rows = await withTaskCancellationHandler(
                operation: { await sampling.value }, onCancel: { sampling.cancel() })
            guard !Task.isCancelled, token == generation else { return }
            self.rows = rows
            isRunning = false
            task = nil
        }
    }
    func cancel(clear: Bool = false) {
        generation += 1
        task?.cancel()
        task = nil
        isRunning = false
        if clear { rows = [] }
    }
}

struct ImportMemoryEstimate {
    var cellCount: Double
    var bytes: Double
    var budget: Double
    var fits: Bool { bytes.isFinite && bytes < budget }
    init(domain: SIMD3<Float>, cellSize: Float, detailed: Bool, refined: Bool, budget: Double) {
        self.budget = budget
        cellCount = (0..<3).reduce(1) { $0 * ceil(Double(domain[$1]) / Double(cellSize)) }
        bytes =
            cellCount * (detailed ? 73 : 57) + (refined ? Double(SolverConfiguration().refinementMemory) : 0)
    }
    var description: String {
        String(format: "%.2g M air cells · %.2g GB estimated air memory", cellCount / 1e6, bytes / 1e9)
    }
}
