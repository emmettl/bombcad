import BlastCore
import Foundation

// The live blast wave's learned refinement and its weights' download (emmettl/bombcad-work#115;
// docs/live-wave.md). Off by default. Turning it on without the weights offers the download;
// nothing is fetched until the user clicks Download, and the option is turned on only once the
// file is in place and checked, as the learned field model's option does.
extension SimulationModel {
    /// Whether the refinement is taken while the charge is dragged on a large district's coarser
    /// cells, as well as once it is let go: it keeps the recompute within a tenth of a second there
    /// (docs/live-wave.md, "The learned refinement").
    nonisolated static let liveWaveRefinesWhileDragging = true

    /// Where the weights are read from: `BOMBCAD_LIVE_WAVE_MODEL`, the setting, or Application
    /// Support.
    var liveWaveLearnedWeightsURL: URL {
        LiveWave.Refinement.weightsURL(
            setting: learnedDefaults.string(forKey: Self.liveWaveLearnedWeightsKey),
            fallback: liveWaveLearnedHome)
    }

    /// The refinement from its weights' file, on the system's GPU.
    nonisolated static func loadLiveWaveRefinement(_ url: URL) throws -> LiveWave.Refinement {
        try LiveWave.Refinement(network: LearnedFieldNetwork(contentsOf: url))
    }

    /// The option's switch. Off is off. On, with the weights there, is on; without them, the user
    /// is asked whether to download them (only to the default place: a path set by hand that holds
    /// nothing is reported, not filled), and the option stays off until they are in.
    func setLiveWaveLearned(_ on: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard !liveWaveLearnedDownloadInFlight else { return }
        liveWaveLearnedStatus = ""
        guard on else {
            offersLiveWaveLearnedDownload = false
            liveWaveLearned = false
            return
        }
        let url = LiveWave.Refinement.weightsURL(
            setting: learnedDefaults.string(forKey: Self.liveWaveLearnedWeightsKey), environment: environment,
            fallback: liveWaveLearnedHome)
        if FileManager.default.fileExists(atPath: url.path) {
            liveWaveLearned = true
        } else if url == liveWaveLearnedHome {
            offersLiveWaveLearnedDownload = true
        } else {
            liveWaveLearnedStatus =
                "No learned refinement's weights at \(url.path), the path set for them: the option stays off."
        }
    }

    /// The user declined the download: the option stays off.
    func declineLiveWaveLearnedDownload() {
        offersLiveWaveLearnedDownload = false
        liveWaveLearnedStatus = "Not downloaded: the live wave's learned refinement stays off."
    }

    /// The release's file for Application Support.
    var liveWaveLearnedReleaseItem: LearnedFieldDownload.Item {
        LearnedFieldDownload.Item(LiveWave.Refinement.Release.asset, to: liveWaveLearnedHome)
    }

    /// The user clicked Download: fetches the file, checks it and turns the option on; on any
    /// failure or a cancel, keeps nothing, says why, and leaves the option off.
    func downloadLiveWaveLearnedWeights(_ item: LearnedFieldDownload.Item? = nil) {
        let item = item ?? liveWaveLearnedReleaseItem
        offersLiveWaveLearnedDownload = false
        guard !liveWaveLearnedDownloadInFlight else { return }
        liveWaveLearnedDownloadInFlight = true
        liveWaveLearnedStatus =
            "Downloading the live wave's learned refinement, " + LearnedField.Release.megabytes(item.bytes)
            + ", from " + item.source.absoluteString + "…"
        liveWaveLearnedDownloadTask = Task { [weak self] in
            let result: Result<[URL], Error>
            do {
                result = .success(try await LearnedFieldDownload.install([item]))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            self.liveWaveLearnedDownloadInFlight = false
            self.liveWaveLearnedDownloadTask = nil
            switch result {
            case .success:
                self.liveWaveLearnedStatus =
                    "Downloaded the live wave's learned refinement to " + item.destination.path + "; checked."
                self.liveWaveLearned = true
            case .failure(let error):
                self.liveWaveLearnedStatus = "\(error) The live wave's learned refinement stays off."
            }
        }
    }

    /// Stops a download under way; the option stays off.
    func cancelLiveWaveLearnedDownload() { liveWaveLearnedDownloadTask?.cancel() }
}
