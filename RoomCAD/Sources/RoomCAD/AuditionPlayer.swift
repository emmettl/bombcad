import AVFoundation
import AcousticCore
import Audition
import Foundation
import Observation

/// Plays a dry clip and the same clip through the room together, so the wet/dry balance can change
/// while it plays, from a playhead that can be moved.
@MainActor
@Observable
final class AuditionPlayer {
    /// Clips offered for the current sample rate, bundled recordings first.
    private(set) var clips: [DryClip] = []
    var clipID: String?
    /// 0 is all dry, 1 is all wet.
    var wetMix: Double = 1 { didSet { applyLevels() } }
    /// Changing this rebuilds the buffers, because node volumes cannot exceed 1 and the matching gain
    /// is therefore part of them; playback continues from the same point.
    var matchLoudness = true {
        didSet {
            guard oldValue != matchLoudness, let preview else { return }
            install(preview)
        }
    }
    /// Changing this while playing takes effect from the current point.
    var loops = true {
        didSet {
            if oldValue != loops, isPlaying { restart(at: currentTime()) }
        }
    }
    private(set) var isPlaying = false
    private(set) var isPreparing = false
    var message: String?
    /// Where playback starts or resumes, in seconds; updated when paused or moved, not while playing.
    private(set) var playhead: Double = 0
    /// What the waveform shows: the clip alone, or dry and wet once a response is prepared.
    private(set) var dryOverview: WaveformOverview?
    private(set) var wetOverview: WaveformOverview?

    private var sampleRate = 0
    private var preview: AuditionPreview?
    /// The clip and room the prepared preview was built from.
    private var prepared: (clipID: String, settings: RoomResponseSettings)?
    private var dryBuffer: AVAudioPCMBuffer?
    private var wetBuffer: AVAudioPCMBuffer?
    private var engine: AVAudioEngine?
    private var dryNode: AVAudioPlayerNode?
    private var wetNode: AVAudioPlayerNode?
    private var preparation: Task<Void, Never>?
    /// The clip and room being prepared, and whether to play when ready.
    private var pending: (clipID: String, settings: RoomResponseSettings)?
    private var playWhenPrepared = false
    /// Frame at which the current run began.
    private var runStart = 0
    /// Distinguishes runs, so a finished or stopped run's callback cannot end a newer one.
    private var run = 0

    static let overviewBuckets = 1200

    var clip: DryClip? { clips.first { $0.id == clipID } ?? clips.first }

    var duration: Double { preview?.duration ?? clip?.duration ?? 0 }

    // MARK: - Clips

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
        showClip()
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

    /// Shows the selected clip on its own until a response is prepared for it.
    func showClip() {
        guard let clip, prepared?.clipID != clip.id else { return }
        pause()
        preview = nil
        playhead = 0
        dryOverview = WaveformOverview(
            [clip.samples], sampleRate: clip.sampleRate, buckets: Self.overviewBuckets)
        wetOverview = nil
    }

    /// Shows a newly selected clip and, if there is a response, prepares it, playing on if it was.
    func clipSelected(_ result: RoomResponse?) {
        let wasPlaying = isPlaying || isPreparing
        showClip()
        if let result { prepare(result, thenPlay: wasPlaying) }
    }

    // MARK: - Preparing

    /// Convolves the selected clip with `result` off the main thread unless that is already done, then
    /// plays from the playhead if asked or if already playing.
    func prepare(_ result: RoomResponse, thenPlay: Bool = false) {
        prepareClips(sampleRate: result.response.sampleRate)
        guard let clip else { return }
        if let prepared, prepared.clipID == clip.id, prepared.settings == result.settings, preview != nil {
            if thenPlay && !isPlaying { restart(at: playhead) }
            return
        }
        // A request for what is already being prepared only adds the wish to play.
        if let pending, preparation != nil, pending.clipID == clip.id, pending.settings == result.settings {
            playWhenPrepared = playWhenPrepared || thenPlay
            return
        }
        let wasPlaying = isPlaying
        if prepared?.clipID != clip.id { showClip() }
        preparation?.cancel()
        isPreparing = true
        message = nil
        let response = result.response
        let settings = result.settings
        pending = (clip.id, settings)
        playWhenPrepared = thenPlay || wasPlaying
        preparation = Task {
            let built = await Task.detached(priority: .userInitiated) {
                Result { try AuditionPreview(clip: clip, response: response) }
            }.value
            guard !Task.isCancelled else { return }
            isPreparing = false
            preparation = nil
            pending = nil
            switch built {
            case .success(let preview):
                prepared = (clip.id, settings)
                install(preview, at: currentTime(), play: playWhenPrepared || isPlaying)
            case .failure(let error):
                message = error.localizedDescription
            }
        }
    }

    /// Prepares on the calling thread without playing; for snapshots and tests.
    func prepareImmediately(_ result: RoomResponse) throws {
        prepareClips(sampleRate: result.response.sampleRate)
        guard let clip else { return }
        let preview = try AuditionPreview(clip: clip, response: result.response)
        prepared = (clip.id, result.settings)
        install(preview, at: 0, play: false)
    }

    /// Waits for background preparation in progress; for tests.
    func preparationFinished() async {
        await preparation?.value
    }

    /// Builds the played buffers for `preview` and carries on from `time`, playing if asked or already
    /// playing.
    private func install(_ preview: AuditionPreview, at time: Double? = nil, play: Bool? = nil) {
        let time = time ?? currentTime()
        let play = play ?? isPlaying
        stopNodes()
        self.preview = preview
        let overviews = preview.overviews(buckets: Self.overviewBuckets, matchLoudness: matchLoudness)
        dryOverview = overviews.dry
        wetOverview = overviews.wet
        // Node volumes cannot exceed 1, so the matching and output gains go into the buffers and the
        // volumes only set the balance.
        let output = preview.outputGain(matchLoudness: matchLoudness)
        let wetGain = preview.wetGain(matchLoudness: matchLoudness) * output
        guard
            let format = AVAudioFormat(standardFormatWithSampleRate: Double(preview.sampleRate), channels: 2)
        else { return }
        dryBuffer = Self.buffer(preview.dry, gain: output, format: format)
        wetBuffer = Self.buffer(preview.wet, gain: wetGain, format: format)
        playhead = min(max(0, time), preview.duration)
        if play { restart(at: playhead) }
    }

    // MARK: - Transport

    func pause() {
        playhead = currentTime()
        preparation?.cancel()
        preparation = nil
        pending = nil
        isPreparing = false
        stopNodes()
    }

    /// Moves the playhead, carrying on playing from there if playing.
    func seek(to time: Double) {
        let time = min(max(0, time), duration)
        if isPlaying { restart(at: time) } else { playhead = time }
    }

    /// The position being heard, in seconds.
    func currentTime() -> Double {
        guard isPlaying, let preview, let node = wetNode, let renderTime = node.lastRenderTime,
            let playerTime = node.playerTime(forNodeTime: renderTime)
        else { return playhead }
        let frame = PlaybackPosition.frame(
            start: runStart, elapsed: Int(playerTime.sampleTime), length: preview.dry[0].count, loops: loops)
        return Double(frame) / Double(preview.sampleRate)
    }

    private func restart(at time: Double) {
        guard let preview, let dryBuffer, let wetBuffer else { return }
        stopNodes()
        let length = preview.dry[0].count
        // Starting at the very end means starting again.
        var start = Int(time * Double(preview.sampleRate))
        if start >= length - 1 { start = 0 }
        playhead = Double(start) / Double(preview.sampleRate)

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
        let format = dryBuffer.format
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
        guard let dryRest = Self.slice(dryBuffer, from: start),
            let wetRest = Self.slice(wetBuffer, from: start)
        else { return }
        run += 1
        let thisRun = run
        runStart = start
        // The rest of this pass, then whole passes if looping.
        dry.scheduleBuffer(dryRest, at: nil, options: [])
        wet.scheduleBuffer(wetRest, at: nil, options: [], completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.run == thisRun, !self.loops else { return }
                self.stopNodes()
                self.playhead = 0
            }
        }
        if loops {
            dry.scheduleBuffer(dryBuffer, at: nil, options: [.loops])
            wet.scheduleBuffer(wetBuffer, at: nil, options: [.loops])
        }
        // Start both a little ahead so they begin on the same sample.
        let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
        dry.play(at: when)
        wet.play(at: when)
        isPlaying = true
    }

    private func stopNodes() {
        run += 1
        dryNode?.stop()
        wetNode?.stop()
        isPlaying = false
    }

    /// Stops playback and releases the audio device, keeping the playhead.
    func stop() {
        pause()
        engine?.stop()
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

    /// A copy of `buffer` from `start` to its end.
    private static func slice(_ buffer: AVAudioPCMBuffer, from start: Int) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength) - start
        guard frames > 0,
            let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(frames))
        else { return nil }
        slice.frameLength = AVAudioFrameCount(frames)
        for c in 0..<Int(buffer.format.channelCount) {
            slice.floatChannelData![c].update(from: buffer.floatChannelData![c] + start, count: frames)
        }
        return slice
    }
}
