import BlastCore
import Foundation
import Observation
import simd

struct ImportPreviewRequest: Sendable, Equatable {
    var scale: Float
    var yUp: Bool
    var corner: SIMD3<Float>
    var cellSize: Float
    var domain: SIMD3<Float>
}

/// Debounced previews are independent of simulation settings; only Apply changes the layout.
@MainActor @Observable
final class ImportPreviewModel {
    private let source: ImportedMesh
    private(set) var request: ImportPreviewRequest?
    private(set) var preview: ImportedMesh.Preview?
    private(set) var transformedMesh: ImportedMesh?
    private(set) var error: String?
    private(set) var isPreparing = false
    private(set) var isCurrent = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    init(source: ImportedMesh) { self.source = source }
    func update(_ request: ImportPreviewRequest, delay: Duration = .milliseconds(350)) {
        if self.request == request && (isPreparing || isCurrent) { return }
        generation += 1
        let token = generation
        let source = source
        task?.cancel()
        self.request = request
        error = nil
        isPreparing = true
        isCurrent = false
        task = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            let sampling = Task.detached(priority: .userInitiated) {
                () -> Result<(ImportedMesh, ImportedMesh.Preview), Error> in
                Result {
                    let mesh = try source.transformed(
                        scale: request.scale, yUp: request.yUp, corner: request.corner)
                    return (
                        mesh,
                        try mesh.preview(cellSize: request.cellSize, domain: request.domain, allowEmpty: true)
                    )
                }
            }
            let result = await withTaskCancellationHandler(
                operation: { await sampling.value }, onCancel: { sampling.cancel() })
            guard !Task.isCancelled, generation == token else { return }
            isPreparing = false
            task = nil
            switch result {
            case .success(let result):
                transformedMesh = result.0
                preview = result.1
                isCurrent = true
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isPreparing = false
        isCurrent = false
    }
}
