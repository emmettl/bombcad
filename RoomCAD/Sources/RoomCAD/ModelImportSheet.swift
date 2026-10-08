import AcousticCore
import GeometryImport
import SwiftUI
import UniformTypeIdentifiers

/// A model file read and waiting to be placed as the room.
struct PendingModel: Identifiable {
    let id = UUID()
    let name: String
    let polygons: [RoomImport.Polygon]

    /// Reads an OBJ or STL file's polygons, naming each by its OBJ material, group or object.
    init(url: URL) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let file = try MeshFile(data: Data(contentsOf: url), fileExtension: url.pathExtension)
        name = url.lastPathComponent
        polygons = file.faces.map { face in
            RoomImport.Polygon(
                corners: face.corners.map { SIMD3<Double>(file.vertices[$0]) },
                name: face.material ?? face.group ?? face.object)
        }
    }

    static let types: [UTType] = [UTType(filenameExtension: "obj"), UTType(filenameExtension: "stl")]
        .compactMap { $0 }
}

/// The units a model may be drawn in, and their size in metres.
enum ModelUnit: String, CaseIterable, Identifiable {
    case metres, centimetres, millimetres, inches, feet

    var id: Self { self }
    var metres: Double {
        switch self {
        case .metres: 1
        case .centimetres: 0.01
        case .millimetres: 0.001
        case .inches: 0.0254
        case .feet: 0.3048
        }
    }
}

/// Chooses the model's units and up axis, shows the room they make or why it cannot be one, and
/// replaces the room with it.
struct ModelImportSheet: View {
    let model: PendingModel
    let material: SurfaceMaterial
    let apply: (ShoeboxRoom) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var unit = ModelUnit.metres
    @State private var yUp = false

    private var outcome: Result<(room: ShoeboxRoom, notes: [String]), Error> {
        Result { try RoomImport.room(from: model.polygons, scale: unit.metres, yUp: yUp, material: material) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(model.name)").font(.headline)
            Text(
                "The model must be the closed surface of the room's air. Its faces take one material per "
                    + "material, group or object name in the file, each starting as \(material.name); set them "
                    + "in the inspector afterwards."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Drawn in", selection: $unit) {
                    ForEach(ModelUnit.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Drawn with y up", isOn: $yUp)
                    .help("Most modelling apps other than CAD draw with y up; RoomCAD's height is z")
            }
            .formStyle(.grouped)
            switch outcome {
            case .success(let (room, notes)):
                let size = room.size
                Text(
                    String(
                        format: "%.2f × %.2f × %.2f m, %.0f m³, %d faces, %d materials", size.x, size.y,
                        size.z,
                        room.volume, room.mesh?.faces.count ?? 0, room.mesh?.materials.count ?? 0))
                ForEach(notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                    Button("Replace Room") {
                        apply(room)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            case .failure(let error):
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }
                }
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
