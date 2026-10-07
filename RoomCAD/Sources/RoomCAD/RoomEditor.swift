import AcousticCore
import Foundation
import Observation
import RoomDocument

/// Per-window state that is not saved: generation in progress and the analysis of the result.
@MainActor
@Observable
final class RoomEditor {
    private(set) var isGenerating = false
    /// The settings being generated, while a run is in progress.
    private(set) var generatingSettings: RoomResponseSettings?
    private(set) var summary: ResponseSummary?
    /// The most recent failure, shown until the next attempt.
    var message: String?
    private var work: Task<RoomResponse, Error>?
    private var analysis: Task<Void, Never>?
    private var delivery: Task<Void, Never>?

    /// Generates a response in the background and hands it to `deliver` unless cancelled.
    func generate(_ settings: RoomResponseSettings, deliver: @escaping @MainActor (RoomResponse) -> Void) {
        cancel()
        message = nil
        do {
            try settings.validate()
        } catch {
            message = error.localizedDescription
            return
        }
        isGenerating = true
        generatingSettings = settings
        let work = Task.detached(priority: .userInitiated) { try RoomResponseGenerator.generate(settings) }
        self.work = work
        delivery = Task {
            defer {
                if self.work == work {
                    self.work = nil
                    self.isGenerating = false
                    self.generatingSettings = nil
                }
            }
            do {
                let result = try await work.value
                guard !work.isCancelled else { return }
                deliver(result)
                self.summarize(result)
            } catch is CancellationError {
            } catch {
                self.message = error.localizedDescription
            }
        }
    }

    func cancel() {
        work?.cancel()
        work = nil
        isGenerating = false
        generatingSettings = nil
    }

    /// Generates `settings` after `delay` unless asked again sooner: each call replaces the last, and a
    /// run for other settings is cancelled at once. Calls while the same settings are generating, or with
    /// invalid settings, do nothing.
    /// `needed` is asked again after the delay, in case a response arrived meanwhile.
    func regenerate(
        _ settings: RoomResponseSettings, after delay: Duration = .milliseconds(400),
        needed: @MainActor () -> Bool = { true }, deliver: @escaping @MainActor (RoomResponse) -> Void
    ) async {
        if let generatingSettings, generatingSettings != settings { cancel() }
        guard generatingSettings != settings, (try? settings.validate()) != nil else { return }
        try? await Task.sleep(for: delay)
        guard !Task.isCancelled, generatingSettings != settings, needed() else { return }
        generate(settings, deliver: deliver)
    }

    /// Recomputes the summary shown for `result`, or clears it.
    func summarize(_ result: RoomResponse?) {
        analysis?.cancel()
        guard let result else {
            summary = nil
            return
        }
        analysis = Task {
            let summary = await Task.detached(priority: .utility) { ResponseSummary(result) }.value
            if !Task.isCancelled { self.summary = summary }
        }
    }

    /// Waits for any generation and analysis in progress; for tests.
    func finished() async {
        await delivery?.value
        await analysis?.value
    }
}
