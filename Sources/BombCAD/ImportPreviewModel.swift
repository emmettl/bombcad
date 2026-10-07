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
    var scene: Scenario? = nil
    var editingID: UUID? = nil
    var fixedBase: Bool? = nil
    func sameGeometry(as other: Self) -> Bool {
        scale == other.scale && yUp == other.yUp && corner == other.corner && cellSize == other.cellSize
            && domain == other.domain
    }
}

/// Debounced previews are independent of simulation settings; only Apply changes the layout.
@MainActor @Observable
final class ImportPreviewModel {
    private let source: ImportedMesh
    private(set) var request: ImportPreviewRequest?
    private(set) var preview: ImportedMesh.Preview?
    private(set) var transformedMesh: ImportedMesh?
    private(set) var placementReport: ImportPlacementReport?
    @ObservationIgnored private var previewRequest: ImportPreviewRequest?
    private(set) var error: String?
    private(set) var placementError: String?
    private struct ContextKey: Equatable, Sendable {
        var scene: Scenario
        var h: Float
        var domain: SIMD3<Float>
        var editingID: UUID?
    }
    @ObservationIgnored private var contextKey: ContextKey?
    @ObservationIgnored private var cachedContext: Scenario?
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
        let reuse = previewRequest?.sameGeometry(as: request) == true
        let cachedMesh = reuse ? transformedMesh : nil
        let cachedPreview = reuse ? preview : nil
        let key = request.scene.map {
            ContextKey(scene: $0, h: request.cellSize, domain: request.domain, editingID: request.editingID)
        }
        let context = key == contextKey ? cachedContext : nil
        task?.cancel()
        self.request = request
        error = nil
        placementError = nil
        isPreparing = true
        isCurrent = false
        task = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            let sampling = Task.detached(priority: .userInitiated) {
                () -> Result<
                    (ImportedMesh, ImportedMesh.Preview, ImportPlacementReport?, String?, Scenario?), Error
                > in
                Result {
                    let mesh =
                        try cachedMesh
                        ?? source.transformed(scale: request.scale, yUp: request.yUp, corner: request.corner)
                    let preview =
                        try cachedPreview
                        ?? mesh.preview(cellSize: request.cellSize, domain: request.domain, allowEmpty: true)
                    var placement: ImportPlacementReport?
                    var placementError: String?
                    var checkedContext: Scenario?
                    if let scene = request.scene {
                        do {
                            var candidate: Scenario
                            if let context {
                                candidate = context
                            } else {
                                candidate = scene
                                candidate.domainSize = request.domain
                                // The candidate's own source is checked above and excluded from contact checks.
                                // Sample all other attached sources at the staged layout-wide grid.
                                if let own = candidate.importedModels?.first(where: {
                                    $0.id == request.editingID && $0.isAttached
                                }) {
                                    candidate.importedModels?.removeAll { $0.id == own.id }
                                    if own.behavior == .deformable { candidate.structure = nil }
                                }
                                candidate = try candidate.resamplingImports(cellSize: request.cellSize)
                            }
                            checkedContext = candidate
                            placement = try ImportPlacementReport.analyze(
                                boxes: preview.boxes, scenario: candidate,
                                editingID: request.editingID, cellSize: request.cellSize,
                                fixedBase: request.fixedBase)
                        } catch is CancellationError { throw CancellationError() } catch {
                            placementError = error.localizedDescription
                        }
                    }
                    return (mesh, preview, placement, placementError, checkedContext)
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
                placementReport = result.2
                placementError = result.3
                cachedContext = result.4
                contextKey = key
                previewRequest = request
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
