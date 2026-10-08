import AcousticCore
import Observation
import RoomDocument
import SwiftUI

/// Fits a room's absorption to target reverberation times in the background (`AbsorptionCalibration`),
/// simulating at preview quality, and reports each step.
@MainActor
@Observable
final class AbsorptionFitter {
    private(set) var isRunning = false
    /// The latest step, such as "Step 2: 1 kHz 1.45 s", or the outcome once done.
    private(set) var status: String?
    private var work: Task<Void, Never>?

    /// Fits `settings`' room to `target` and hands the fitted room to `apply` unless cancelled.
    func fit(
        _ settings: RoomResponseSettings, to target: [Double?],
        apply: @escaping @MainActor (ShoeboxRoom) -> Void
    ) {
        cancel()
        guard target.contains(where: { $0 != nil }) else {
            status = "Enter a target time in at least one band."
            return
        }
        isRunning = true
        status = "Simulating the room as it is…"
        let flag = CancellationFlag()
        cancellation = flag
        let reports = StepReports()
        work = Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result {
                    try AbsorptionCalibration.fit(settings, to: target) { trial in
                        if flag.isCancelled { throw CancellationError() }
                        let channels = try RoomResponseGenerator.generate(
                            trial, cancellation: flag, quality: .preview
                        ).response.channels
                        reports.count += 1
                        return channels
                    }
                }
            }.value
            guard !flag.isCancelled else { return }
            isRunning = false
            switch outcome {
            case .success(let (room, steps)):
                status = Self.summary(steps, target: target)
                apply(room)
            case .failure(let error):
                status = "Fitting failed: \(error.localizedDescription)"
            }
        }
        // Report progress while the fit runs.
        Task {
            while isRunning, !flag.isCancelled {
                if reports.count > 0 { status = "Simulating, step \(reports.count + 1)…" }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        work = nil
        if isRunning { status = "Cancelled." }
        isRunning = false
    }

    private var cancellation: CancellationFlag?

    /// "Absorption scaled ×0.82–1.31 in 3 steps; T30 within 2% of the targets."
    static func summary(_ steps: [AbsorptionCalibration.Step], target: [Double?]) -> String {
        guard let last = steps.last else { return "Nothing was simulated." }
        let used = target.indices.filter { target[$0] != nil }
        let factors = used.map { last.factors[$0] }
        let errors = used.compactMap { band in
            last.reverberationTime[band].map { abs($0 / target[band]! - 1) }
        }
        let scale =
            factors.isEmpty
            ? "unchanged"
            : "scaled ×\(factors.min()!.formatted(.number.precision(.fractionLength(2))))"
                + (factors.max()! - factors.min()! > 0.005
                    ? "–\(factors.max()!.formatted(.number.precision(.fractionLength(2))))" : "")
        let worst = errors.max().map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        let steps = steps.count - 1
        return
            "Absorption \(scale) in \(steps) step\(steps == 1 ? "" : "s"); preview T30 within \(worst) of the "
            + "targets."
    }
}

/// Simulations finished so far, counted from the background.
final class StepReports: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Target reverberation times per band and a button that scales every surface's absorption to meet
/// them by simulating the room.
struct CalibrationSection: View {
    @Binding var project: RoomProject
    @State private var targets = [Double?](repeating: nil, count: OctaveBands.count)
    @State private var fitter = AbsorptionFitter()

    var body: some View {
        Section("Match Reverberation Time") {
            ForEach(OctaveBands.centres.indices, id: \.self) { band in
                LabeledContent(MaterialEditor.bandName(band)) {
                    HStack(spacing: 4) {
                        TextField(
                            "T30", value: $targets[band], format: .number.precision(.fractionLength(0...2))
                        )
                        .endsEditingOnSubmit()
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 72)
                        Text("s").foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                    }
                }
            }
            HStack {
                Button("Fit Absorption") {
                    fitter.fit(project.settings, to: targets) { room in project.settings.room = room }
                }
                .disabled(fitter.isRunning)
                .help(
                    "Scale every surface's absorption, keeping their proportions, until the simulated T30 meets "
                        + "the targets. Bands left empty keep their absorption.")
                if fitter.isRunning {
                    Button("Stop") { fitter.cancel() }
                }
            }
            if let status = fitter.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
