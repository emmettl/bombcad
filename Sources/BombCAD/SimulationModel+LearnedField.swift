import BlastCore
import Foundation

// The quick estimate's learned field option and its weights' download (emmettl/bombcad-work#67).
// Turning the option on without the weights offers the download; nothing is fetched until the
// user clicks Download, and the option is turned on only once the file is in place and checked.
extension SimulationModel {
    /// Where the weights are read from: `BOMBCAD_FIELD_MODEL`, the setting, or Application Support.
    var learnedWeightsURL: URL {
        LearnedField.weightsURL(
            setting: learnedDefaults.string(forKey: Self.learnedWeightsKey), fallback: learnedHome)
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

    /// The user clicked Download: fetches the weights, checks them and turns the option on; on any
    /// failure or a cancel, keeps nothing and leaves the option off, saying why.
    func downloadLearnedWeights(
        from source: URL = LearnedField.Release.url, sha256: String = LearnedField.Release.sha256
    ) {
        let destination = learnedHome
        offersLearnedDownload = false
        guard !learnedDownloadInFlight else { return }
        learnedDownloadInFlight = true
        learnedDownloadStatus = String(
            format: "Downloading the learned field model, %.1f MB, from %@…",
            Double(LearnedField.Release.bytes) / 1e6,
            source.absoluteString)
        learnedDownloadTask = Task { [weak self] in
            let result: Result<URL, Error>
            do {
                result = .success(
                    try await LearnedFieldDownload.install(from: source, to: destination, sha256: sha256))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.learnedDownloadInFlight = false
            self.learnedDownloadTask = nil
            switch result {
            case .success(let url):
                self.learnedDownloadStatus = "Downloaded the learned field model to \(url.path); checked."
                self.quickEstimateLearnedPeaks = true
            case .failure(let error):
                self.learnedDownloadStatus = "\(error) The learned field option stays off."
            }
        }
    }

    /// Stops a download under way; the option stays off.
    func cancelLearnedDownload() { learnedDownloadTask?.cancel() }
}
