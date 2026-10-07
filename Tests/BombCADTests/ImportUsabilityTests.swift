import BlastCore
import Foundation
import Testing
import simd

@testable import BombCAD

@MainActor @Suite("Import usability", .serialized)
struct ImportUsabilityTests {
    private func cube(_ name: String = "Block", x: Float = 0, width: Float = 1, offset: Int = 0) -> String {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1),
            SIMD3(1, 1, 1), SIMD3(0, 1, 1),
        ]
        let faces = [
            [1, 4, 3, 2], [5, 6, 7, 8], [1, 2, 6, 5], [2, 3, 7, 6], [3, 4, 8, 7], [4, 1, 5, 8],
        ]
        return "o \(name)\n"
            + points.map { p in "v \(p.x * width + x) \(p.y) \(p.z)" }.joined(separator: "\n")
            + "\n"
            + faces.map { "f " + $0.map { String($0 + offset) }.joined(separator: " ") }.joined(
                separator: "\n")
    }
    private func mesh(_ text: String) throws -> ImportedMesh {
        try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
    }
    private func waitUntil(_ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(10)
        while !condition() {
            try #require(ContinuousClock.now < end)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    @Test("Bulk materials only edit known selected parts and reset remains linked to the default")
    func bulkSelection() throws {
        let mesh = try mesh(
            cube("A") + "\n" + cube("B", x: 2, offset: 8) + "\n" + cube("C", x: 4, offset: 16))
        let original: [Int: StructureMaterial] = [24: .masonry]
        let selected: Set<Int> = [0, 12, 999]
        let edited = PartMaterialEditing.applying(
            .structuralSteel, to: selected, parts: mesh.parts, assignments: original)
        #expect(edited == [0: .structuralSteel, 12: .structuralSteel, 24: .masonry])
        let reset = PartMaterialEditing.applying(nil, to: [0, 12], parts: mesh.parts, assignments: edited)
        #expect(reset == original)
    }
    @Test("Material colours are stable across grids and equal materials share one colour")
    func colours() throws {
        let mesh = try mesh(cube("A") + "\n" + cube("B", x: 2, offset: 8))
        let palette = ImportMaterialPalette(
            parts: mesh.parts, defaultMaterial: .plainConcrete,
            assignments: [0: .structuralSteel, 12: .structuralSteel])
        #expect(palette.materials == [.plainConcrete, .structuralSteel])
        #expect(palette.indices[0] == palette.indices[12])
        let moved = try mesh.transformed(scale: 2, yUp: true, corner: .zero)
        #expect(
            ImportMaterialPalette(
                parts: moved.parts, defaultMaterial: .plainConcrete,
                assignments: [0: .structuralSteel, 12: .structuralSteel]
            ).indices == palette.indices)
    }
    @Test("Profiles persist complete properties, update case-insensitively, match names and remove safely")
    func profiles() throws {
        let suite = "BombCAD-ImportTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var custom = StructureMaterial.structuralSteel
        custom.density = 7800
        custom.name = "Test steel"
        let store = ImportProfileStore(storage: defaults)
        var profile = ImportProfile(
            name: "CAD millimetres", scale: 0.001, yUp: true, deformable: true,
            fixedBase: false, material: .plainConcrete,
            namedMaterials: ["Steel": custom, "Missing": .masonry])
        try store.save(profile)
        let id = try #require(store.profiles.first?.id)
        let reopened = ImportProfileStore(storage: defaults)
        #expect(reopened.profiles.first == profile)
        let mesh = try mesh(cube("Concrete") + "\n" + cube("Steel", x: 2, offset: 8))
        #expect(profile.assignments(for: mesh.parts) == [12: custom])
        profile.name = " cad MILLIMETRES "
        profile.scale = 0.01
        try reopened.save(profile)
        #expect(reopened.profiles.count == 1 && reopened.profiles[0].id == id)
        #expect(ImportProfileStore(storage: defaults).profiles.first?.scale == 0.01)
        reopened.remove(id: id)
        #expect(ImportProfileStore(storage: defaults).profiles.isEmpty)
    }
    @Test("Profile editors in different windows preserve each other's saves")
    func concurrentProfileStores() throws {
        let suite = "BombCAD-ImportWindows-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ImportProfileStore(storage: defaults)
        let second = ImportProfileStore(storage: defaults)
        let a = ImportProfile(
            name: "A", scale: 1, yUp: false, deformable: false, fixedBase: true, material: .plainConcrete,
            namedMaterials: [:])
        let b = ImportProfile(
            name: "B", scale: 0.001, yUp: true, deformable: false, fixedBase: true, material: .plainConcrete,
            namedMaterials: [:])
        try first.save(a)
        try second.save(b)
        #expect(ImportProfileStore(storage: defaults).profiles.map(\.name) == ["A", "B"])
        first.remove(id: a.id)
        #expect(ImportProfileStore(storage: defaults).profiles.map(\.name) == ["B"])
    }
    @Test("Bad profiles and profile capacity fail without overwriting stored preferences")
    func profileLimits() throws {
        let suite = "BombCAD-ImportLimits-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImportProfileStore(storage: defaults)
        var profile = ImportProfile(
            name: "", scale: 1, yUp: false, deformable: false, fixedBase: true,
            material: .plainConcrete, namedMaterials: [:])
        #expect(throws: ImportedMesh.ImportError.self) { try store.save(profile) }
        for n in 0..<20 {
            profile.name = "Profile \(n)"
            try store.save(profile)
        }
        profile.name = "Overflow"
        #expect(throws: ImportedMesh.ImportError.self) { try store.save(profile) }
        #expect(ImportProfileStore(storage: defaults).profiles.count == 20)
        profile.name = "Profile 0"
        profile.scale = .infinity
        #expect(throws: ImportedMesh.ImportError.self) { try store.save(profile) }
        #expect(store.profiles[0].scale == 1)
    }
    @Test("Comparisons recover a vanished part and do not mutate the chosen baseline")
    func comparison() async throws {
        let source = try mesh(cube("Large") + "\n" + cube("Thin", x: 2, width: 0.1, offset: 8))
        let baseline = try source.preview(cellSize: 0.5, domain: SIMD3(repeating: 4))
        let study = ImportResolutionStudy()
        study.compare(mesh: source, baseline: baseline, domain: SIMD3(repeating: 4))
        try await waitUntil { !study.isRunning }
        #expect(study.rows.map(\.cellSize) == [0.5, 0.25, 0.125])
        #expect(study.rows[0].counts()[12, default: 0] == 0)
        #expect(study.rows[2].counts()[12, default: 0] == 64)
        #expect(study.rows[0].preview == baseline)
        #expect(baseline.occupiedCells == 8)
    }
    @Test("Cancelled comparisons cannot publish stale results")
    func cancelComparison() async throws {
        let source = try mesh(cube())
        let baseline = try source.preview(cellSize: 0.5, domain: SIMD3(repeating: 4))
        let study = ImportResolutionStudy()
        study.compare(mesh: source, baseline: baseline, domain: SIMD3(repeating: 4))
        study.cancel(clear: true)
        try await Task.sleep(for: .milliseconds(30))
        #expect(study.rows.isEmpty && !study.isRunning)
        study.compare(mesh: source, baseline: baseline, domain: SIMD3(repeating: 4))
        try await waitUntil { !study.isRunning }
        #expect(study.rows.count == 3)
    }
    @Test("Air memory matches detailed/refinement accounting and the scale grid stays bounded")
    func memoryAndScale() {
        let plain = ImportMemoryEstimate(
            domain: SIMD3(repeating: 4), cellSize: 0.5, detailed: false, refined: false, budget: 1e9)
        #expect(plain.cellCount == 512 && plain.bytes == 512 * 57 && plain.fits)
        let detailed = ImportMemoryEstimate(
            domain: SIMD3(repeating: 4), cellSize: 0.5, detailed: true, refined: true, budget: 1)
        #expect(detailed.bytes == 512 * 73 + Double(SolverConfiguration().refinementMemory))
        #expect(!detailed.fits)
        #expect(ImportReferenceGrid.step(for: Box(min: .zero, max: SIMD3(repeating: 3))) == 1)
        let big = Box(min: .zero, max: SIMD3(1000, 2000, 3))
        #expect(big.size.y / ImportReferenceGrid.step(for: big) <= 16)
    }
    @Test(
        "File checking distinguishes valid meshes from non-importable inspection results and supports repaired retry"
    )
    func loadingAndRetry() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ImportCheck-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let valid = folder.appendingPathComponent("valid.obj")
        let invalid = folder.appendingPathComponent("open.obj")
        try Data(cube().utf8).write(to: valid)
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3".utf8).write(to: invalid)
        let loader = ImportFileLoader()
        loader.load(invalid)
        try await waitUntil { !loader.isLoading }
        #expect(loader.result?.inspection.validatedMesh == nil)
        #expect(loader.result?.inspection.issues.isEmpty == false)
        loader.retryAfterDismissal(valid)
        #expect(loader.result == nil && !loader.isLoading)
        loader.presentationDismissed()
        try await waitUntil { !loader.isLoading }
        #expect(loader.result?.inspection.validatedMesh?.parts.count == 1)
        #expect(loader.error == nil)
    }
    @Test("Folders disguised as model files fail without entering a blocked read")
    func folderDrop() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "folder-\(UUID()).obj", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let loader = ImportFileLoader()
        loader.load(folder)
        try await waitUntil { !loader.isLoading }
        #expect(loader.result == nil && loader.error?.contains("rather than a folder") == true)
    }
    @Test("Cancelled reads and repeated invalid extensions never publish stale geometry")
    func cancelledLoading() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("cancel-\(UUID()).obj")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(cube().utf8).write(to: file)
        let loader = ImportFileLoader()
        loader.load(file)
        loader.cancel()
        try await Task.sleep(for: .milliseconds(30))
        #expect(loader.result == nil && !loader.isLoading)
        let unsupported = file.deletingPathExtension().appendingPathExtension("step")
        loader.load(unsupported)
        let first = loader.failureID
        loader.load(unsupported)
        #expect(loader.error != nil && loader.failureID != first)
    }
}
