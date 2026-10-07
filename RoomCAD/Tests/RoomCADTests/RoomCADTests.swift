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
