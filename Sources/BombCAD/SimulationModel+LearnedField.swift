import BlastCore
import Foundation

// The quick estimate's learned field option and its weights' download (emmettl/bombcad-work#67,
// #69). Turning the option on without the weights offers the download; nothing is fetched until the
// user clicks Download, and the option is turned on only once the files are in place and checked.
// An install with field model 1's file alone keeps working as it did, and is offered field model
// 2's second file as an update, again fetched only on a click.
extension SimulationModel {
    /// Where the weights are read from: `BOMBCAD_FIELD_MODEL`, the setting, or Application Support.
    var learnedWeightsURL: URL {
        LearnedField.weightsURL(
            setting: learnedDefaults.string(forKey: Self.learnedWeightsKey), fallback: learnedHome)
    }

    /// Where the levels network's file (field model 2's second) is kept: beside the ground floor's
    /// in Application Support.
    var learnedLevelsHome: URL { LearnedField.levelsWeightsURL(ground: learnedHome, environment: [:]) }

    /// The levels network's file if it is there: `BOMBCAD_FIELD_MODEL_LEVELS`, or beside the ground
    /// floor's file. Without it the option is field model 1, the ground floor's network alone.
    var learnedLevelsURL: URL? {
        let url = LearnedField.levelsWeightsURL(ground: learnedWeightsURL)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether field model 2's second file is offered as an update: field model 1's file is in
    /// Application Support, the levels network's is not, and neither was set by hand.
    func learnedUpdateAvailable(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let ground = LearnedField.weightsURL(
            setting: learnedDefaults.string(forKey: Self.learnedWeightsKey), environment: environment,
            fallback: learnedHome)
        return ground == learnedHome && FileManager.default.fileExists(atPath: ground.path)
            && LearnedField.levelsWeightsURL(ground: ground, environment: environment) == learnedLevelsHome
            && !FileManager.default.fileExists(atPath: learnedLevelsHome.path)
    }

    /// The option's standing, for the model the files there make: field model 2's with both,
    /// field model 1's with the ground floor's alone.
    var learnedStanding: [String] {
        learnedLevelsURL != nil ? LearnedField.standing : LearnedField.standingModel1
    }

    /// The option's switch. Off is off. On, with the weights there, is on; without them, the user
    /// is asked whether to download them (only to the default place: a path set by hand that
    /// holds nothing is reported, not filled), and the option stays off until they are in.
    func setLearnedPeaks(_ on: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !learnedDownloadInFlight else { return }
        learnedDownloadStatus = ""
        guard on else {
            offersLearnedDownload = false
            quickEstimateLearnedPeaks = false
            return
        }
        let url = LearnedField.weightsURL(
            setting: learnedDefaults.string(forKey: Self.learnedWeightsKey), environment: environment,
            fallback: learnedHome)
        if FileManager.default.fileExists(atPath: url.path) {
            quickEstimateLearnedPeaks = true
        } else if url == learnedHome {
            offersLearnedDownload = true
        } else {
            learnedDownloadStatus =
                "No learned field model's weights at \(url.path), the path set for them: the option stays off."
        }
    }

    /// The user declined the download: the option stays off.
    func declineLearnedDownload() {
        offersLearnedDownload = false
        learnedDownloadStatus = "Not downloaded: the learned field option stays off."
    }

    /// The release's files for Application Support: field model 2's two.
    var learnedReleaseItems: [LearnedFieldDownload.Item] {
        [
            LearnedFieldDownload.Item(LearnedField.Release.ground, to: learnedHome),
            LearnedFieldDownload.Item(LearnedField.Release.levels, to: learnedLevelsHome),
        ]
    }

    /// The user clicked Download (or Download Update): fetches whichever of `items` are not already
    /// in place, checks every one and turns the option on; on any failure or a cancel, keeps
    /// nothing new, says why, and leaves the option as it was (off for a first download; for an
    /// update, field model 1 as before).
    func downloadLearnedWeights(_ items: [LearnedFieldDownload.Item]? = nil) {
        let items = items ?? learnedReleaseItems
        offersLearnedDownload = false
        guard !learnedDownloadInFlight else { return }
        let wasOn = quickEstimateLearnedPeaks
        learnedDownloadInFlight = true
        let missing = LearnedFieldDownload.missing(items)
        learnedDownloadStatus =
            "Downloading the learned field model, "
            + LearnedField.Release.megabytes(missing.reduce(0) { $0 + $1.bytes }) + ", from "
            + missing.map(\.source.absoluteString).joined(separator: " and ") + "…"
        learnedDownloadTask = Task { [weak self] in
            let result: Result<[URL], Error>
            do {
                result = .success(try await LearnedFieldDownload.install(items))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.learnedDownloadInFlight = false
            self.learnedDownloadTask = nil
            switch result {
            case .success(let urls):
                self.learnedDownloadStatus =
                    "Downloaded the learned field model to "
                    + (urls.first ?? self.learnedHome).deletingLastPathComponent().path + "; checked."
                self.quickEstimateLearnedPeaks = true
            case .failure(let error):
                self.learnedDownloadStatus =
                    wasOn
                    ? "\(error) The learned field option carries on with the model it had."
                    : "\(error) The learned field option stays off."
            }
        }
    }

    /// Stops a download under way; the option stays as it was.
    func cancelLearnedDownload() { learnedDownloadTask?.cancel() }

    /// **Check on this Mac**: runs `BombCAD field-model check` (`HeadlessFieldModel`) from this
    /// app's own executable, in a process of its own so that its peak memory is its own and a GPU
    /// that cannot hold it costs the app nothing, and shows what it printed.
    func checkLearnedFieldOnThisMac() {
        guard !learnedCheckInFlight, let executable = Bundle.main.executableURL else { return }
        learnedCheckInFlight = true
        learnedCheckReport = ["Checking the learned field model on this Mac…"]
        let ground = learnedWeightsURL
        let levels = learnedLevelsURL
        Task { [weak self] in
            let lines = await Task.detached(priority: .userInitiated) { () -> [String] in
                let process = Process()
                process.executableURL = executable
                process.arguments =
                    ["field-model", "check", "--ground", ground.path]
                    + (levels.map { ["--levels", $0.path] } ?? [])
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    return ["The check could not be started: \(error.localizedDescription)"]
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                var lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                if process.terminationReason == .uncaughtSignal {
                    lines.append(
                        "The check's process stopped on signal \(process.terminationStatus): the model does not run here."
                    )
                }
                return lines
            }.value
            guard let self else { return }
            self.learnedCheckInFlight = false
            self.learnedCheckReport = lines
        }
    }
}
