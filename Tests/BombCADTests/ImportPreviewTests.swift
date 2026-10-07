import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

@MainActor @Suite("Automatic import previews", .serialized)
struct ImportPreviewTests {
    private func source() throws -> ImportedMesh {
        try ImportedMesh(
            data: Data(
                """
                v 0 0 0
                v 1 0 0
                v 1 1 0
                v 0 1 0
                v 0 0 1
                v 1 0 1
                v 1 1 1
                v 0 1 1
                f 1 4 3 2
                f 5 6 7 8
                f 1 2 6 5
                f 2 3 7 6
                f 3 4 8 7
                f 4 1 5 8
                """.utf8), fileExtension: "obj")
    }
    private func request(x: Float = 1, h: Float = 0.25) -> ImportPreviewRequest {
        ImportPreviewRequest(
            scale: 1, yUp: false, corner: SIMD3(x, 1, 0), cellSize: h, domain: SIMD3(repeating: 4))
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < deadline, "Preview update timed out")
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @Test("Opening a preview schedules geometry without an explicit prepare action")
    func automatic() async throws {
        let model = ImportPreviewModel(source: try source())
        let input = request()
        model.update(input)
        #expect(model.isPreparing)
        #expect(!model.isCurrent)
        #expect(model.preview == nil)
        try await waitUntil { model.isCurrent }
        #expect(model.request == input)
        #expect(model.preview?.occupiedCells == 64)
        #expect(model.transformedMesh?.bounds.min == input.corner)
        #expect(model.error == nil)
    }
    @Test("Rapid edits publish only the latest preview and repeating a ready request is harmless")
    func latestRequest() async throws {
        let model = ImportPreviewModel(source: try source())
        model.update(request(), delay: .seconds(1))
        let latest = request(x: 2, h: 0.125)
        model.update(latest, delay: .zero)
        try await waitUntil { model.isCurrent }
        #expect(model.preview?.bounds.min == latest.corner)
        #expect(model.preview?.occupiedCells == 512)
        model.update(latest)
        #expect(model.isCurrent)
        #expect(!model.isPreparing)
        try await Task.sleep(for: .milliseconds(1100))
        #expect(model.preview?.bounds.min == latest.corner)
        #expect(model.request == latest)
    }
    @Test("Queued or failed changes retain the old view but never mark it current")
    func stalePreview() async throws {
        let model = ImportPreviewModel(source: try source())
        model.update(request(), delay: .zero)
        try await waitUntil { model.isCurrent }
        let old = model.preview
        model.update(request(x: 2), delay: .seconds(1))
        #expect(model.preview == old)
        #expect(!model.isCurrent && model.isPreparing)
        var invalid = request(x: 2)
        invalid.domain = SIMD3(repeating: 0.5)
        model.update(invalid, delay: .zero)
        try await waitUntil { !model.isPreparing }
        #expect(model.error != nil)
        #expect(!model.isCurrent)
        #expect(model.preview == old)
    }
    @Test("Scene and support changes refresh placement checks without replacing valid sampled geometry")
    func placementContext() async throws {
        let model = ImportPreviewModel(source: try source())
        var input = request()
        input.scene = Scenario(
            name: "Context", domainSize: SIMD3(repeating: 4), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(3, 3, 2)))
        model.update(input, delay: .zero)
        try await waitUntil { model.isCurrent }
        let geometry = model.preview
        #expect(model.placementReport?.issues.isEmpty == true)
        input.scene?.charge.position = SIMD3(1.5, 1.5, 0.5)
        model.update(input, delay: .zero)
        #expect(!model.isCurrent)
        try await waitUntil { model.isCurrent }
        #expect(model.preview == geometry)
        #expect(model.placementReport?.issues.contains { $0.kind == .blockedCharge } == true)
        input.corner.z = 2
        input.scene?.charge.position = SIMD3(3, 3, 2)
        input.fixedBase = true
        model.update(input, delay: .zero)
        try await waitUntil { model.isCurrent }
        #expect(
            model.placementReport?.issues.first { $0.kind == .floating }?.detail.contains("Fixed base holds")
                == true)
    }

    @Test("Closing cancels queued work and a subsequent preview can start again")
    func cancelAndRestart() async throws {
        let model = ImportPreviewModel(source: try source())
        model.update(request(), delay: .seconds(1))
        model.cancel()
        #expect(!model.isPreparing && !model.isCurrent)
        model.update(request(), delay: .zero)
        try await waitUntil { model.isCurrent }
        #expect(model.preview?.occupiedCells == 64)
    }
}
