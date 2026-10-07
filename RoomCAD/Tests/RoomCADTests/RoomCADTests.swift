import AcousticCore
import CoreGraphics
import Foundation
import RoomDocument
import Testing

@testable import RoomCAD

@MainActor
@Suite("RoomCAD editor")
struct RoomCADTests {
    static var settings: RoomResponseSettings {
        RoomResponseSettings(
            room: ShoeboxRoom(size: [5, 4, 3], material: .uniform(0.4, name: "Test")),
            source: RoomPoint(name: "Source", position: [1.3, 1.1, 1.2]),
            receivers: [RoomPoint(name: "Listener", position: [3.7, 2.9, 1.6])],
            duration: 0.15, maximumReflectionOrder: 30)
    }

    @Test("Generating delivers a response for the current settings and summarizes it")
    func generate() async throws {
        let editor = RoomEditor()
        var project = RoomProject(settings: Self.settings)
        editor.generate(project.settings) { project.result = $0 }
        #expect(editor.isGenerating)
        await editor.finished()
        #expect(!editor.isGenerating)
        #expect(editor.message == nil)
        #expect(project.isResultCurrent)
        #expect(editor.summary?.channels.count == 1)
    }

    @Test("Invalid settings are reported instead of generated")
    func invalid() async {
        let editor = RoomEditor()
        var settings = Self.settings
        settings.source.position.z = 4
        var delivered = false
        editor.generate(settings) { _ in delivered = true }
        await editor.finished()
        #expect(!delivered)
        #expect(editor.message?.contains("Source") == true)
    }

    @Test("Cancelling stops a long generation without delivering it")
    func cancel() async {
        let editor = RoomEditor()
        var settings = Self.settings
        settings.duration = 4
        settings.maximumReflectionOrder = 400
        var delivered = false
        let start = Date()
        editor.generate(settings) { _ in delivered = true }
        editor.cancel()
        #expect(!editor.isGenerating)
        await editor.finished()
        #expect(!delivered)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test("A newer generation replaces one in progress")
    func replaces() async {
        let editor = RoomEditor()
        var first = Self.settings
        first.duration = 4
        first.maximumReflectionOrder = 400
        var names: [String] = []
        editor.generate(first) { _ in names.append("first") }
        editor.generate(Self.settings) { _ in names.append("second") }
        await editor.finished()
        #expect(names == ["second"])
    }

    @Test("Automatic regeneration waits for changes to settle and generates only the latest settings")
    func debounced() async {
        let editor = RoomEditor()
        var delivered: [Double] = []
        var first = Self.settings
        first.duration = 0.1
        let superseded = Task {
            await editor.regenerate(first, after: .milliseconds(300)) {
                delivered.append($0.settings.duration)
            }
        }
        // A newer change cancels the wait, as SwiftUI does when a task's identity changes.
        superseded.cancel()
        await superseded.value
        await editor.regenerate(Self.settings, after: .milliseconds(50)) {
            delivered.append($0.settings.duration)
        }
        #expect(editor.isGenerating)
        await editor.finished()
        #expect(delivered == [Self.settings.duration])
    }

    @Test(
        "A change cancels a run for older settings at once, and repeats of the running settings are ignored")
    func supersedes() async {
        let editor = RoomEditor()
        // Points get new identities on each access, so keep one copy.
        let current = Self.settings
        var slow = current
        slow.duration = 4
        slow.maximumReflectionOrder = 400
        var delivered: [Double] = []
        editor.generate(slow) { delivered.append($0.settings.duration) }
        await editor.regenerate(current, after: .zero) { delivered.append($0.settings.duration) }
        #expect(editor.generatingSettings == current)
        // Asking again for what is running does not restart it.
        await editor.regenerate(current, after: .zero) { _ in delivered.append(-1) }
        await editor.finished()
        #expect(delivered == [current.duration])
    }

    @Test("Automatic regeneration skips invalid settings and results that arrived during the wait")
    func skips() async {
        let editor = RoomEditor()
        var invalid = Self.settings
        invalid.receivers[0].position.x = 99
        await editor.regenerate(invalid, after: .zero) { _ in }
        #expect(!editor.isGenerating)
        await editor.regenerate(Self.settings, after: .zero, needed: { false }, deliver: { _ in })
        #expect(!editor.isGenerating)
    }

    @Test("Drawing coordinates map to the room and dragged points stay inside it")
    func layout() {
        let size: SIMD3<Double> = [8, 6, 3]
        let plan = RoomLayout(projection: .plan, size: size, bounds: CGSize(width: 500, height: 400))
        let rect = plan.roomRect
        #expect(abs(rect.width / rect.height - 8.0 / 6.0) < 1e-9)
        #expect(rect.minX >= RoomLayout.padding - 1e-9 && rect.minY >= RoomLayout.padding - 1e-9)
        let point: SIMD3<Double> = [2.25, 4.5, 1.2]
        let moved = plan.moved([0, 0, 1.2], to: plan.point(point))
        #expect(abs(moved.x - 2.25) < 0.006 && abs(moved.y - 4.5) < 0.006 && moved.z == 1.2)
        // y increases up the page.
        #expect(plan.point([1, 5, 0]).y < plan.point([1, 1, 0]).y)
        let clamped = plan.moved(point, to: CGPoint(x: -100, y: 1000))
        #expect(clamped.x == 0.05 && clamped.y == 0.05)

        let section = RoomLayout(projection: .elevation, size: size, bounds: CGSize(width: 500, height: 400))
        let raised = section.moved(point, to: section.point([3, 0, 2.5]))
        #expect(abs(raised.z - 2.5) < 0.006 && raised.y == 4.5)
    }
}

@MainActor
@Suite("RoomCAD audition player")
struct AuditionPlayerTests {
    @Test("A chosen clip is shown alone until a response is prepared, then dry and wet span clip and tail")
    func preparing() async throws {
        let player = AuditionPlayer()
        player.prepareClips(sampleRate: 48_000)
        let clip = try #require(player.clip)
        #expect(player.dryOverview?.duration == clip.duration)
        #expect(player.wetOverview == nil)

        let result = try RoomResponseGenerator.generate(RoomCADTests.settings)
        player.prepare(result)
        // A second request for the same room joins the first.
        player.prepare(result, thenPlay: false)
        #expect(player.isPreparing)
        await player.preparationFinished()
        #expect(!player.isPreparing)
        #expect(!player.isPlaying)
        let expected = clip.duration + Double(result.response.frameCount - 1) / 48_000
        #expect(abs((player.wetOverview?.duration ?? 0) - expected) < 1e-9)
        #expect(player.dryOverview?.duration == player.wetOverview?.duration)
    }

    @Test("Seeking while paused moves the playhead within the clip")
    func seeking() throws {
        let player = AuditionPlayer()
        try player.prepareImmediately(try RoomResponseGenerator.generate(RoomCADTests.settings))
        player.seek(to: 1.25)
        #expect(player.playhead == 1.25)
        #expect(player.currentTime() == 1.25)
        player.seek(to: 1_000)
        #expect(player.playhead == player.duration)
        player.seek(to: -3)
        #expect(player.playhead == 0)
    }

    @Test("Choosing another clip resets the playhead and shows that clip")
    func choosingClips() async throws {
        let player = AuditionPlayer()
        let result = try RoomResponseGenerator.generate(RoomCADTests.settings)
        try player.prepareImmediately(result)
        player.seek(to: 2)
        let other = try #require(player.clips.first { $0.id == "noise-burst" })
        player.clipID = other.id
        player.clipSelected(result)
        #expect(player.playhead == 0)
        #expect(player.dryOverview?.duration == other.duration)
        await player.preparationFinished()
        #expect(player.wetOverview != nil)
        #expect(!player.isPlaying)
    }

    @Test("Switching loudness matching changes the wet lane's level, not its length")
    func matching() throws {
        let player = AuditionPlayer()
        try player.prepareImmediately(try RoomResponseGenerator.generate(RoomCADTests.settings))
        let matched = try #require(player.wetOverview)
        player.matchLoudness = false
        let physical = try #require(player.wetOverview)
        #expect(matched.duration == physical.duration)
        #expect(matched.maximum != physical.maximum)
    }
}
