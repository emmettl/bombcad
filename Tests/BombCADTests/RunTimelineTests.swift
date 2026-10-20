import BlastCore
import BlastRender
import Foundation
import Metal
import Testing
import simd

@testable import BombCAD

/// A run's timeline: recorded as the run goes, kept with the run, and replayed in the view with
/// no physics, play, pause, step and drag.
@MainActor @Suite("Run timelines", .serialized, .hangLimit)
struct RunTimelineTests {
    private func device() throws -> MTLDevice {
        try #require(MTLCreateSystemDefaultDevice(), "These tests need a Metal device")
    }

    /// A wall struck by a small charge, its solids on 0.25 m elements.
    private func solver() throws -> (BlastSolver, Scenario) {
        let scenario = try SavedRunTests().fixture().scenario
        return (try BlastSolver(device: try device(), scenario: scenario, cellSize: 0.5), scenario)
    }

    /// Whether `a` is `b` as a recorded frame keeps it: the field, the flags and the time exactly,
    /// displacements and rotations to half precision, damage to 1/255.
    private func kept(_ a: ViewFrame, _ b: ViewFrame) -> Bool {
        func near(_ x: [Float], _ y: [Float], _ tolerance: (Float) -> Float) -> Bool {
            x.count == y.count && zip(x, y).allSatisfy { abs($0 - $1) <= tolerance($1) }
        }
        func half(_ v: Float) -> Float { max(abs(v) / 1024, 1e-4) }
        func byte(_: Float) -> Float { 0.5 / 255 + 1e-6 }
        func clamped(_ v: [Float]) -> [Float] { v.map { min(max($0, 0), 1) } }
        func flat3(_ v: [SIMD3<Float>]) -> [Float] { v.flatMap { [$0.x, $0.y, $0.z] } }
        func flat4(_ v: [SIMD4<Float>]) -> [Float] { v.flatMap { [$0.x, $0.y, $0.z, $0.w] } }
        guard a.time == b.time, a.field == b.field, a.bodies.count == b.bodies.count else { return false }
        return zip(a.bodies, b.bodies).allSatisfy { x, y in
            let solids =
                switch (x.solids, y.solids) {
                case (nil, nil): true
                case (let p?, let q?):
                    p.flags == q.flags && near(flat3(p.displacements), flat3(q.displacements), half)
                        && near(p.damage, clamped(q.damage), byte)
                default: false
                }
            let shells =
                switch (x.shells, y.shells) {
                case (nil, nil): true
                case (let p?, let q?):
                    p.flags == q.flags && p.beamFlags == q.beamFlags
                        && near(flat3(p.displacements), flat3(q.displacements), half)
                        && near(flat4(p.rotations), flat4(q.rotations), half)
                        && near(p.damage, clamped(q.damage), byte)
                        && near(p.beamDamage, clamped(q.beamDamage), byte)
                default: false
                }
            return solids && shells
        }
    }

    @Test func aFrameComesBackAsItWent() throws {
        let (solver, _) = try solver()
        solver.advance(steps: 20)
        var fragments = FragmentLive()
        fragments.positions = [SIMD3(1, 2, 3), SIMD3(4, 5, 6)]
        fragments.speeds = [10, 0]
        fragments.landed = [false, true]
        fragments.fragmentCount = 1
        fragments.time = solver.time
        let box = SceneRenderer.OrientedBox(
            centre: SIMD3(1, 1, 0.5), orientation: simd_quatf(angle: 0.3, axis: SIMD3(0, 0, 1)),
            size: SIMD3(1, 2, 1), isCar: true)
        let frame = TimelineFrame(
            view: ViewFrame(solver: solver, field: try solver.viewField(stride: 2)), fragments: fragments,
            freestanding: [box])
        let bytes = try TimelineCodec.compress(TimelineCodec.encode(frame))
        let decoded = try TimelineCodec.decode(TimelineCodec.decompress(bytes))
        #expect(kept(decoded.view, frame.view))
        #expect(decoded.fragments == frame.fragments && decoded.freestanding == frame.freestanding)
        #expect(TimelineCodec.compact(frame.view).count < SceneViewCodec.encode(frame.view).count)
        let bare = TimelineFrame(view: frame.view, fragments: nil, freestanding: [])
        let decodedBare = try TimelineCodec.decode(TimelineCodec.encode(bare))
        #expect(kept(decodedBare.view, bare.view) && decodedBare.fragments == nil)
        #expect(throws: (any Error).self) {
            try TimelineCodec.decode(TimelineCodec.encode(frame).dropLast(2))
        }
    }

    @Test func aTimelineSpansTheRunWithinItsBudget() async throws {
        let (solver, _) = try solver()
        let duration = 0.1
        // Too little room for a frame each 1/240th of the run: it records less often.
        let recorder = try RunTimelineRecorder(
            solver: solver, fingerprint: "test", duration: duration, budgetBytes: 8 << 10)
        defer { recorder.discard() }
        recorder.endTime = duration
        // The budget alone: the cap on capture time, which depends on how busy the Mac is, off.
        recorder.maximumShare = .infinity
        recorder.recordIfDue(solver, fragments: nil, freestanding: [])
        while solver.time < duration - 1e-9 {
            solver.advance(steps: 1, timeLimit: duration)
            recorder.recordIfDue(solver, fragments: nil, freestanding: [])
        }
        recorder.recordIfDue(solver, fragments: nil, freestanding: [], force: true)
        let folder = try #require(await recorder.finish())
        let manifest = try RunTimelineManifest.decode(Data(contentsOf: folder.appending(path: "run.json")))
        let frames = manifest.entries(.frames)
        #expect(
            frames.count >= 8 && frames.count < RunTimelineRecorder.defaultFrames,
            "\(frames.count) frames, \(manifest.usedBytes) bytes, \(solver.stepCount) steps")
        #expect(frames.first?.time == 0 && abs((frames.last?.time ?? 0) - solver.time) < 1e-12)
        #expect(recorder.interval > duration / Double(RunTimelineRecorder.defaultFrames))
        // Within its budget, give or take the frames recorded before it knew their size.
        #expect(manifest.usedBytes < 4 * manifest.budgetBytes, "\(manifest.usedBytes) bytes")

        // Played back: each frame uploaded over the setup, the last as the run left it.
        let player = try RunTimelinePlayer(folder: folder, device: try device())
        try player.show(player.entries.count - 1)
        let last = ViewFrame(solver: solver, field: try solver.viewField(stride: recorder.stride))
        #expect(player.frame.map { kept($0.view, last) } == true)
        #expect(player.index(at: 0) == 0 && player.index(at: 1) == player.entries.count - 1)
        #expect(player.index(at: frames[3].time + 1e-9) == 3)
    }

    @Test func capturingNeverTakesMoreThanItsShareOfTheRun() async throws {
        let (solver, _) = try solver()
        let duration = 0.02
        let recorder = try RunTimelineRecorder(solver: solver, fingerprint: "test", duration: duration)
        defer { recorder.discard() }
        recorder.endTime = duration
        // No share at all: the first frame, which is left out of the cap, and the last, forced.
        recorder.maximumShare = 0
        recorder.recordIfDue(solver, fragments: nil, freestanding: [])
        while solver.time < duration - 1e-9 {
            solver.advance(steps: 1, timeLimit: duration)
            recorder.recordIfDue(solver, fragments: nil, freestanding: [])
        }
        recorder.recordIfDue(solver, fragments: nil, freestanding: [], force: true)
        #expect(recorder.frames == 2)
    }

    @Test func aRunIsRecordedKeptAndReplayed() async throws {
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.recordsTimelines = true
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.replayableRuns.isEmpty && model.recentTimeline == nil)
        model.run()
        while model.isRunning || model.hasPendingGPUWork || model.recentTimeline == nil {
            try #require(model.errorMessage == nil)
            try await Task.sleep(for: .milliseconds(5))
        }
        let recent = try #require(model.recentTimeline)
        try model.keepRun(named: "Recorded")
        let run = try #require(model.savedRuns.last)
        #expect(model.runFolders[run.id] == recent && model.timelineFolder(for: run) == recent)
        #expect(model.replayableRuns.map(\.id) == [run.id])

        // Replayed: the last frame first, then scrubbed, stepped and played, the run untouched.
        let endTime = model.time
        model.replay(run)
        let playback = try #require(model.playback)
        #expect(playback.index == playback.count - 1 && abs(playback.time - endTime) < 1e-9)
        playback.seek(to: 0)
        #expect(playback.index == 0 && playback.frame?.time == 0)
        playback.step(1)
        #expect(playback.index == 1)
        playback.play()
        while playback.isPlaying { try await Task.sleep(for: .milliseconds(10)) }
        #expect(playback.index == playback.count - 1)
        model.stopReplay()
        #expect(model.playback == nil && model.time == endTime)

        // Saved with the project, beside its archive.
        let package = try ProjectDocument(model: model).packageWrapper(existing: nil)
        let folder = try #require(
            package.fileWrappers?["runs"]?.fileWrappers?[run.id.uuidString.lowercased()]?.fileWrappers)
        #expect(folder["run.json"] != nil && folder["frames"] != nil)

        // A new run forgets the old recording only if it was not kept.
        model.reset()
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.recentTimeline == nil)
        #expect(FileManager.default.fileExists(atPath: recent.path))
        try? FileManager.default.removeItem(at: recent)
    }

    @Test("A run continued from a state it saved ends as it did, to the bit; a state saved by hand is kept")
    func aRunContinuesFromItsSavedState() async throws {
        let kept = try SavedRunTests().fixture()
        var document = ProjectDocument(scenario: kept.scenario)
        document.runSettings = kept.settings
        // About 440 steps: several 64-step boundaries to save at.
        document.runSettings?.duration = 0.2
        let model = SimulationModel(document: document, playbackSpeed: .unlimited)
        model.recordsTimelines = true
        func settle() async throws {
            while model.isRunning || model.hasPendingGPUWork {
                try #require(model.errorMessage == nil)
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        while !model.experimentIsReady { try await Task.sleep(for: .milliseconds(5)) }
        model.run()
        while model.time < 0.3 * model.duration { try await Task.sleep(for: .milliseconds(2)) }
        model.toggleRun()
        try await settle()
        // Saved by hand: the paused run runs on to the next 64-step boundary and pauses there.
        #expect(model.canSaveState)
        model.saveStateHere()
        try await settle()
        let pinned = try #require(model.savedStates.first { $0.pinned == true })
        #expect(pinned.step % BlastSolver.checkpointInterval == 0)
        model.run()
        try await settle()
        while model.recentTimeline == nil { try await Task.sleep(for: .milliseconds(5)) }
        let straight = try #require(model.solverStateDigest)
        let endTime = model.time

        model.replay(nil)
        let playback = try #require(model.playback)
        let checkpoints = playback.player.manifest.entries(.checkpoint)
        #expect(checkpoints.count >= 3 && checkpoints.contains(pinned))
        playback.seek(to: 0.7 * endTime)
        let entry = try #require(model.checkpointToContinue(playback))
        #expect(entry.time <= playback.time && entry.time > pinned.time)
        model.continueFromReplay()
        #expect(model.playback == nil && model.continuedFrom == entry.time && model.time == entry.time)
        model.run()
        try await settle()
        #expect(model.time == endTime)
        #expect(model.solverStateDigest == straight)
        if let recent = model.recentTimeline { try? FileManager.default.removeItem(at: recent) }
    }
}
