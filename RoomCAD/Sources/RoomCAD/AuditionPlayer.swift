import AVFoundation
import AcousticCore
import Audition
import Foundation
import Observation

/// Plays a dry clip and the same clip through the room together, so the wet/dry balance can change
/// while it plays.
@MainActor
@Observable
final class AuditionPlayer {
    /// Clips offered for the current sample rate, bundled recordings first.
    private(set) var clips: [DryClip] = []
    var clipID: String?
    /// 0 is all dry, 1 is all wet.
    var wetMix: Double = 1 { didSet { applyLevels() } }
    /// Changing this while playing restarts playback, because the gains are part of the buffers.
    var matchLoudness = true {
        didSet {
            if isPlaying, let preview { start(preview) }
        }
    }
    var loops = true
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    var message: String?

    private var sampleRate = 0
    private var preview: AuditionPreview?
    private var engine: AVAudioEngine?
    private var dryNode: AVAudioPlayerNode?
    private var wetNode: AVAudioPlayerNode?
    private var preparation: Task<Void, Never>?

    var clip: DryClip? { clips.first { $0.id == clipID } ?? clips.first }

    /// Loads the clip library at `rate` if it is not already loaded.
    func prepareClips(sampleRate rate: Int) {
        guard rate != sampleRate else { return }
        let custom = clips.filter { $0.credit == "Your file" }
        sampleRate = rate
        clips = DryClip.library(sampleRate: rate)
        // Re-read files the user chose, at the new rate.
        for clip in custom {
            if let url = URL(string: clip.id),
                let loaded = try? DryClip.load(contentsOf: url, sampleRate: rate)
            {
                clips.append(loaded)
            }
        }
    }

    /// Adds an audio file chosen by the user and selects it.
    func addFile(_ url: URL, sampleRate rate: Int) {
        prepareClips(sampleRate: rate)
        do {
            let clip = try DryClip.load(contentsOf: url, sampleRate: rate)
            clips.removeAll { $0.id == clip.id }
            clips.append(clip)
            clipID = clip.id
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Convolves the selected clip with `result` off the main thread, then plays it.
    func play(_ result: RoomResponse) {
        stop()
        prepareClips(sampleRate: result.response.sampleRate)
        guard let clip else { return }
        isPreparing = true
        message = nil
        let response = result.response
        preparation = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Result { try AuditionPreview(clip: clip, response: response) }
            }.value
            isPreparing = false
            guard !Task.isCancelled else { return }
            switch built {
            case .success(let preview): start(preview)
            case .failure(let error): message = error.localizedDescription
            }
        }
    }

    func stop() {
        preparation?.cancel()
        preparation = nil
        isPreparing = false
        dryNode?.stop()
        wetNode?.stop()
        engine?.stop()
        isPlaying = false
    }

    private func start(_ preview: AuditionPreview) {
        self.preview = preview
        dryNode?.stop()
        wetNode?.stop()
        let engine = engine ?? AVAudioEngine()
        let dry = dryNode ?? AVAudioPlayerNode()
        let wet = wetNode ?? AVAudioPlayerNode()
        if self.engine == nil {
            engine.attach(dry)
            engine.attach(wet)
        }
        self.engine = engine
        dryNode = dry
        wetNode = wet
        // Node volumes cannot exceed 1, so the matching and output gains go into the buffers and the
        // volumes only set the balance.
        let output = preview.outputGain(matchLoudness: matchLoudness)
        let wetGain = preview.wetGain(matchLoudness: matchLoudness) * output
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(preview.sampleRate), channels: 2),
            let dryBuffer = Self.buffer(preview.dry, gain: output, format: format),
            let wetBuffer = Self.buffer(preview.wet, gain: wetGain, format: format)
        else {
            message = "Could not prepare audio for playback."
            return
        }
        engine.disconnectNodeOutput(dry)
        engine.disconnectNodeOutput(wet)
        engine.connect(dry, to: engine.mainMixerNode, format: format)
        engine.connect(wet, to: engine.mainMixerNode, format: format)
        applyLevels()
        do {
            try engine.start()
        } catch {
            message = "Audio output is unavailable: \(error.localizedDescription)"
            return
        }
        let options: AVAudioPlayerNodeBufferOptions = loops ? [.loops] : []
        dry.scheduleBuffer(dryBuffer, at: nil, options: options)
        wet.scheduleBuffer(wetBuffer, at: nil, options: options) { [weak self] in
            Task { @MainActor in
                guard let self, !self.loops else { return }
                self.isPlaying = false
            }
        }
        // Start both a little ahead so they begin on the same sample.
        let start = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        dry.play(at: start)
        wet.play(at: start)
        isPlaying = true
    }

    private func applyLevels() {
        dryNode?.volume = Float(1 - wetMix)
        wetNode?.volume = Float(wetMix)
    }

    private static func buffer(_ channels: [[Float]], gain: Float, format: AVAudioFormat) -> AVAudioPCMBuffer?
    {
        let frames = AVAudioFrameCount(channels[0].count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        for (c, samples) in channels.enumerated() {
            let target = buffer.floatChannelData![c]
            for (i, value) in samples.enumerated() { target[i] = value * gain }
        }
        return buffer
    }
}
