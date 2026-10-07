import BlastCore
import Foundation
import Observation

struct ImportProfile: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var scale: Float
    var yUp: Bool
    var deformable: Bool
    var fixedBase: Bool
    var material: StructureMaterial
    var namedMaterials: [String: StructureMaterial]
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80
            && scale.isFinite && scale > 0 && scale <= 1_000_000
            && namedMaterials.count <= 2048 && namedMaterials.keys.allSatisfy { $0.count <= 500 }
    }
    func assignments(for parts: [ImportedMesh.Part]) -> [Int: StructureMaterial] {
        Dictionary(
            uniqueKeysWithValues: parts.compactMap { part in
                namedMaterials[part.name].map { (part.id, $0) }
            })
    }
}

@MainActor @Observable
final class ImportProfileStore {
    private(set) var profiles: [ImportProfile] = []
    @ObservationIgnored private let storage: UserDefaults
    private static let key = "BombCAD.importProfiles.v1"
    init(storage: UserDefaults = .standard) {
        self.storage = storage
        profiles = Self.read(storage) ?? []
    }
    private static func read(_ storage: UserDefaults) -> [ImportProfile]? {
        guard let data = storage.data(forKey: key), data.count <= 1_000_000,
            let saved = try? JSONDecoder().decode([ImportProfile].self, from: data), saved.count <= 20,
            saved.allSatisfy(\.isValid), Set(saved.map(\.id)).count == saved.count
        else { return nil }
        return saved
    }
    func save(_ profile: ImportProfile) throws {
        guard profile.isValid else {
            throw ImportedMesh.ImportError.invalid(
                "Use a profile name of 1–80 characters and a valid unit scale.")
        }
        var updated = Self.read(storage) ?? profiles
        var profile = profile
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = updated.firstIndex(where: {
            $0.name.caseInsensitiveCompare(profile.name) == .orderedSame
        }) {
            profile.id = updated[index].id
            updated[index] = profile
        } else {
            guard updated.count < 20 else {
                throw ImportedMesh.ImportError.invalid(
                    "Up to 20 import profiles can be saved. Delete an unused profile first.")
            }
            if updated.contains(where: { $0.id == profile.id }) { profile.id = UUID() }
            updated.append(profile)
        }
        let data = try JSONEncoder().encode(updated)
        guard data.count <= 1_000_000 else {
            throw ImportedMesh.ImportError.invalid(
                "Profile storage exceeds its limit. Save fewer named material assignments.")
        }
        storage.set(data, forKey: Self.key)
        profiles = updated
    }
    func remove(id: UUID) {
        profiles = Self.read(storage) ?? profiles
        profiles.removeAll { $0.id == id }
        if let data = try? JSONEncoder().encode(profiles) { storage.set(data, forKey: Self.key) }
    }
}
