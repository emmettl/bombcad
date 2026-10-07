import BlastCore
import Foundation
import Observation

@MainActor @Observable
final class ImportFileLoader {
    struct Loaded: Identifiable {
        var id = UUID()
        var filename: String
        var inspection: ImportedMesh.Inspection
    }
    private(set) var result: Loaded?
    private(set) var error: String?
    private(set) var failureID = UUID()
    private(set) var isLoading = false
    private(set) var filename = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingURL: URL?
    func load(_ url: URL) {
        cancel()
        result = nil
        error = nil
        filename = url.lastPathComponent
        guard url.isFileURL, ["obj", "stl", "ifc"].contains(url.pathExtension.lowercased()) else {
            error =
                "Choose one local OBJ, STL or IFC file. Export other formats as a watertight, triangulated OBJ or STL."
            failureID = UUID()
            return
        }
        isLoading = true
        let token = generation
        task = Task {
            guard !Task.isCancelled else { return }
            let reading = Task.detached(priority: .userInitiated) {
                () -> Result<ImportedMesh.Inspection, Error> in
                do {
                    try Task.checkCancellation()
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    guard values.isRegularFile == true else {
                        throw ImportedMesh.ImportError.invalid(
                            "Choose an OBJ, STL or IFC file rather than a folder or special file.")
                    }
                    let size = values.fileSize ?? 0
                    guard size <= 20_000_000 else {
                        throw ImportedMesh.ImportError.invalid(
                            "Model exceeds the 20 MB limit. Simplify the export before importing.")
                    }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    var data = Data()
                    while data.count <= 20_000_000 {
                        try Task.checkCancellation()
                        let amount = min(1_000_000, 20_000_001 - data.count)
                        guard let chunk = try handle.read(upToCount: amount), !chunk.isEmpty else { break }
                        data.append(chunk)
                    }
                    try Task.checkCancellation()
                    if url.pathExtension.lowercased() == "ifc" {
                        return .success(try await IFCImporter.convert(data).inspection)
                    }
                    return .success(try ImportedMesh.inspect(data: data, fileExtension: url.pathExtension))
                } catch { return .failure(error) }
            }
            let outcome = await withTaskCancellationHandler(
                operation: { await reading.value }, onCancel: { reading.cancel() })
            guard !Task.isCancelled, generation == token else { return }
            isLoading = false
            task = nil
            switch outcome {
            case .success(let inspection): result = Loaded(filename: filename, inspection: inspection)
            case .failure(let failure):
                error = failure.localizedDescription
                failureID = UUID()
            }
        }
    }
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        isLoading = false
        pendingURL = nil
    }
    func retryAfterDismissal(_ url: URL) {
        cancel()
        pendingURL = url
        result = nil
    }
    func presentationDismissed() {
        guard let url = pendingURL else { return }
        pendingURL = nil
        load(url)
    }
    func dismissResult() { result = nil }
}
