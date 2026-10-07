import AcousticCore
import Foundation
import ImpulseResponseKit
import Testing

@testable import Audition

@Suite("Auditioning")
struct AuditionTests {
    private func response(_ channels: [[Float]], sampleRate: Int = 48_000) throws -> ImpulseResponse {
        try ImpulseResponse(
            channels: channels,
            metadata: ResponseMetadata(
                sampleRate: sampleRate, frameCount: channels[0].count,
                channels: channels.indices.map { _ in .init(name: "R", sourceID: UUID(), receiverID: UUID())
                },
                content: .complete, gainConvention: "Test", usableBand: .init(lowerHz: 20, upperHz: 20_000),
                model: "Test", assumptions: [], generator: "Tests"))
    }

    private func energy(_ samples: [Float]) -> Double {
        samples.reduce(0) { $0 + Double($1) * Double($1) }
    }

    @Test("FFT convolution matches direct convolution")
    func convolution() {
        var random = SplitMix(seed: 7)
        let a = (0..<300).map { _ in Float(random.nextSigned()) }
        let b = (0..<77).map { _ in Float(random.nextSigned()) }
        let fast = Convolution.convolve(a, b)
        #expect(fast.count == 376)
        for n in fast.indices {
            var sum = 0.0
            for k in max(0, n - 76)...min(n, 299) { sum += Double(a[k]) * Double(b[n - k]) }
            #expect(abs(Double(fast[n]) - sum) < 1e-4)
        }
        #expect(Convolution.convolve([], b).isEmpty)
    }

    @Test("Generated test signals are repeatable, finite and at the common peak")
    func testSignals() {
        for make in [DryClip.noiseBurst, DryClip.clicks] {
            let clip = make(48_000)
            #expect(clip == make(48_000))
            #expect(clip.samples.allSatisfy { $0.isFinite })
            #expect(abs(clip.samples.map(abs).max()! - DryClip.peak) < 1e-6)
            #expect(clip.duration >= 2)
        }
        // The burst is followed by silence in which to hear the decay.
        let burst = DryClip.noiseBurst(sampleRate: 48_000)
        #expect(burst.samples[30_000...].allSatisfy { $0 == 0 })
        #expect(DryClip.library(sampleRate: 44_100).allSatisfy { $0.sampleRate == 44_100 })
    }

    @Test("Audio files are mixed to mono and converted to the response's rate")
    func loading() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("tone.wav")
        let tone = (0..<44_100).map { Float(sin(2 * Double.pi * 440 * Double($0) / 44_100)) * 0.25 }
        try WAVFile.encode(channels: [tone, tone.map { -$0 * 0.5 }], sampleRate: 44_100).write(to: url)
        let clip = try DryClip.load(contentsOf: url, sampleRate: 48_000)
        #expect(clip.name == "tone")
        #expect(abs(clip.samples.count - 48_000) < 100)
        #expect(abs(clip.samples.map(abs).max()! - DryClip.peak) < 1e-6)
        // Still a 440 Hz tone: count rising zero crossings in the middle second.
        let crossings = zip(clip.samples, clip.samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        #expect(abs(crossings - 440) <= 2)

        let text = folder.appendingPathComponent("notes.wav")
        try Data("not audio".utf8).write(to: text)
        #expect(throws: DryClipError.self) { try DryClip.load(contentsOf: text, sampleRate: 48_000) }
    }

    @Test("The preview convolves each receiver with the clip and pads the dry signal to match")
    func preview() throws {
        let clip = DryClip.clicks(sampleRate: 48_000)
        let ir = try response([[1, 0, 0.5], [0, 0.25, 0]])
        let preview = try AuditionPreview(clip: clip, response: ir)
        #expect(preview.dry[0].count == clip.samples.count + 2)
        #expect(preview.wet.map(\.count) == [clip.samples.count + 2, clip.samples.count + 2])
        #expect(preview.wet[0] == Convolution.convolve(clip.samples, [1, 0, 0.5]))
        #expect(preview.dry[0] == preview.dry[1])

        let mono = try AuditionPreview(clip: clip, response: response([[0.5, 0.1]]))
        #expect(mono.wet[0] == mono.wet[1])

        #expect(throws: AuditionError.self) {
            try AuditionPreview(clip: clip, response: response([[1]], sampleRate: 44_100))
        }
    }

    @Test("Matched loudness gives the wet sound the dry sound's energy and mixes stay below the ceiling")
    func levels() throws {
        let clip = DryClip.noiseBurst(sampleRate: 48_000)
        // A quiet, long response: physical levels leave the wet sound far below the dry.
        var random = SplitMix(seed: 3)
        let tail = (0..<24_000).map { i in Float(random.nextSigned() * 0.01 * exp(-Double(i) / 4_000)) }
        let preview = try AuditionPreview(clip: clip, response: response([tail, tail.reversed()]))
        let wet = preview.mixed(wetMix: 1, matchLoudness: true)
        let dry = preview.mixed(wetMix: 0, matchLoudness: true)
        let ratio = (energy(wet[0]) + energy(wet[1])) / (energy(dry[0]) + energy(dry[1]))
        #expect(abs(ratio - 1) < 1e-3)
        for match in [true, false] {
            for mix in [Float(0), 0.3, 0.7, 1] {
                let peak = preview.mixed(wetMix: mix, matchLoudness: match).flatMap { $0 }.map(abs).max()!
                #expect(peak <= AuditionPreview.ceiling + 1e-6)
            }
        }
        // Physical levels keep the wet sound quieter than the dry.
        let physicalWet = preview.mixed(wetMix: 1, matchLoudness: false)
        let physicalDry = preview.mixed(wetMix: 0, matchLoudness: false)
        #expect(energy(physicalWet[0]) < energy(physicalDry[0]))
    }

    @Test("The library offers the bundled recordings, then the test signals")
    func library() {
        #expect(DryClip.resources != nil)
        let ids = DryClip.library(sampleRate: 48_000).map(\.id)
        #expect(ids.suffix(2) == ["noise-burst", "clicks"])
        #expect(Set(ids).count == ids.count)
    }
}
