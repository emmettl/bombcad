import AcousticCore
import Foundation
import ImpulseResponseKit

public enum AuditionError: LocalizedError, Equatable {
    case sampleRateMismatch(clip: Int, response: Int)

    public var errorDescription: String? {
        switch self {
        case .sampleRateMismatch(let clip, let response):
            "The clip is at \(clip) Hz but the response is at \(response) Hz."
        }
    }
}

/// A dry clip and the same clip through a room, ready to play together as left and right channels.
///
/// The first receiver is heard on the left and the second on the right; a single receiver is heard on
/// both. Without loudness matching the levels are physical: the dry signal is the source heard 1 m away
/// in open air, because responses are pressures relative to that.
public struct AuditionPreview: Sendable {
    public var sampleRate: Int
    /// Left and right, each padded with silence to the length of the wet signal.
    public var dry: [[Float]]
    public var wet: [[Float]]
    /// Gain on the wet signal that gives it the same energy as the dry signal.
    public var matchingGain: Float
    public var dryPeak: Float
    public var wetPeak: Float
    /// Peak level the mix is kept below.
    public static let ceiling: Float = 0.9

    public init(clip: DryClip, response: ImpulseResponse) throws {
        guard clip.sampleRate == response.sampleRate else {
            throw AuditionError.sampleRateMismatch(clip: clip.sampleRate, response: response.sampleRate)
        }
        sampleRate = clip.sampleRate
        let paths = response.channels.count == 1 ? [0, 0] : [0, 1]
        let convolved = Set(paths).sorted().map {
            (index: $0, wet: Convolution.convolve(clip.samples, response.channels[$0]))
        }
        wet = paths.map { path in convolved.first { $0.index == path }!.wet }
        let length = wet[0].count
        let padded = clip.samples + [Float](repeating: 0, count: length - clip.samples.count)
        dry = [padded, padded]
        func energy(_ channels: [[Float]]) -> Double {
            channels.reduce(0) { total, channel in channel.reduce(total) { $0 + Double($1) * Double($1) } }
        }
        let wetEnergy = energy(wet)
        matchingGain = wetEnergy > 0 ? Float((energy(dry) / wetEnergy).squareRoot()) : 1
        dryPeak = clip.samples.reduce(0) { max($0, abs($1)) }
        wetPeak = wet.reduce(0) { peak, channel in channel.reduce(peak) { max($0, abs($1)) } }
    }

    public var duration: Double { Double(dry[0].count) / Double(sampleRate) }

    /// Gain applied to the wet signal before mixing.
    public func wetGain(matchLoudness: Bool) -> Float {
        matchLoudness ? matchingGain : 1
    }

    /// One gain for both signals that keeps any mix below `ceiling` without changing their balance.
    public func outputGain(matchLoudness: Bool) -> Float {
        let loudest = max(dryPeak, wetPeak * wetGain(matchLoudness: matchLoudness))
        return loudest > 0 ? min(1, Self.ceiling / loudest) : 1
    }

    /// The mix as played: `wetMix` 0 is all dry, 1 is all wet. For tests and offline rendering.
    public func mixed(wetMix: Float, matchLoudness: Bool) -> [[Float]] {
        let output = outputGain(matchLoudness: matchLoudness)
        let dryGain = (1 - wetMix) * output
        let wetGain = wetMix * wetGain(matchLoudness: matchLoudness) * output
        return zip(dry, wet).map { d, w in zip(d, w).map { dryGain * $0 + wetGain * $1 } }
    }
}
