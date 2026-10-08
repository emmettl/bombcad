import AcousticCore
import ImpulseResponseKit
import RoomDocument
import SwiftUI

/// A labelled number field with a unit.
struct NumberField: View {
    let title: String
    @Binding var value: Double
    var unit = ""
    var digits = 2

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...digits)))
                    .endsEditingOnSubmit()
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 72)
                if !unit.isEmpty {
                    Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
                }
            }
        }
    }
}

extension Binding where Value == SIMD3<Double> {
    func component(_ index: Int) -> Binding<Double> {
        Binding<Double>(get: { wrappedValue[index] }, set: { wrappedValue[index] = $0 })
    }
}

extension Binding where Value == SIMD2<Double> {
    func component(_ index: Int) -> Binding<Double> {
        Binding<Double>(get: { wrappedValue[index] }, set: { wrappedValue[index] = $0 })
    }
}

/// Edits an opening's surface, position and size, in the surface's own axes; in a room with a floor
/// plan, along its wall and up.
struct OpeningEditor: View {
    @Binding var opening: Opening
    /// The number of plan walls, if the room has a plan.
    let walls: Int?
    static let axisNames = ["x", "y", "z"]

    /// "floor", "ceiling", a box surface's name, or "wall-n".
    private var place: Binding<String> {
        Binding(
            get: { opening.wall.map { "wall-\($0)" } ?? opening.surface.rawValue },
            set: { value in
                if value.hasPrefix("wall-"), let wall = Int(value.dropFirst(5)) {
                    opening.wall = wall
                } else if let surface = Surface(rawValue: value) {
                    opening.wall = nil
                    opening.surface = surface
                }
            })
    }

    var body: some View {
        TextField("Name", text: $opening.name).endsEditingOnSubmit()
        Picker("In", selection: place) {
            if let walls {
                Text("Floor").tag(Surface.floor.rawValue)
                Text("Ceiling").tag(Surface.ceiling.rawValue)
                ForEach(0..<walls, id: \.self) { Text("Wall \($0 + 1)").tag("wall-\($0)") }
            } else {
                ForEach(Surface.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0.rawValue) }
            }
        }
        let names: (String, String) =
            opening.wall != nil
            ? ("along the wall", "height")
            : (Self.axisNames[opening.surface.planeAxes.0], Self.axisNames[opening.surface.planeAxes.1])
        NumberField(title: "Centre, \(names.0)", value: $opening.centre.component(0), unit: "m")
        NumberField(title: "Centre, \(names.1)", value: $opening.centre.component(1), unit: "m")
        NumberField(title: "Size, \(names.0)", value: $opening.size.component(0), unit: "m")
        NumberField(title: "Size, \(names.1)", value: $opening.size.component(1), unit: "m")
    }
}

/// Edits a fitted zone: its name, corners, how densely its objects lie and what they absorb.
struct ZoneEditor: View {
    @Binding var zone: FittingZone

    /// The objects' absorption, one value for every band; a zone whose bands differ shows their mean.
    private var absorption: Binding<Double> {
        Binding(
            get: { zone.absorption.reduce(0, +) / Double(zone.absorption.count) },
            set: { zone.absorption = Array(repeating: $0, count: OctaveBands.count) })
    }

    var body: some View {
        TextField("Name", text: $zone.name).endsEditingOnSubmit()
        ForEach(0..<3, id: \.self) { axis in
            let name = OpeningEditor.axisNames[axis]
            NumberField(title: "From \(name)", value: $zone.low.component(axis), unit: "m")
            NumberField(title: "To \(name)", value: $zone.high.component(axis), unit: "m")
        }
        NumberField(title: "Objects met", value: $zone.density, unit: "/m", digits: 3)
            .help(
                "How often sound meets an object, per metre: the objects' total surface area over four times the zone's volume"
            )
        NumberField(title: "Absorption", value: absorption, digits: 3)
            .help(
                "The fraction of the energy lost at each object. Leave at 0 when a surface's material already accounts for the objects, as an audience floor does."
            )
        if !zone.reference.isEmpty {
            Text(zone.reference).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Edits a point's name and position.
struct PointEditor: View {
    @Binding var point: RoomPoint

    var body: some View {
        TextField("Name", text: $point.name).endsEditingOnSubmit()
        NumberField(title: "x", value: $point.position.component(0), unit: "m")
        NumberField(title: "y", value: $point.position.component(1), unit: "m")
        NumberField(title: "z", value: $point.position.component(2), unit: "m")
    }
}

/// Edits a receiver's pattern and aim; omni needs no aim.
struct MicrophoneEditor: View {
    @Binding var microphone: Microphone?

    private var pattern: Binding<Microphone.Pattern> {
        Binding(
            get: { microphone?.pattern ?? .omni },
            set: { pattern in
                if pattern == .omni {
                    microphone = nil
                } else {
                    var updated = microphone ?? Microphone(pattern: pattern)
                    updated.pattern = pattern
                    microphone = updated
                }
            })
    }

    private func angle(_ keyPath: WritableKeyPath<Microphone, Double>) -> Binding<Double> {
        Binding(
            get: { microphone?[keyPath: keyPath] ?? 0 },
            set: { microphone?[keyPath: keyPath] = $0 })
    }

    var body: some View {
        Picker("Microphone", selection: pattern) {
            ForEach(Microphone.Pattern.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        if microphone != nil {
            NumberField(title: "Azimuth", value: angle(\.azimuth), unit: "°", digits: 0)
                .help("Direction of aim in plan: 0° points along x, 90° along y")
            NumberField(title: "Elevation", value: angle(\.elevation), unit: "°", digits: 0)
        }
    }
}

/// Edits a surface's octave-band absorption and scattering.
struct MaterialEditor: View {
    let title: String
    @Binding var material: SurfaceMaterial

    /// The mean of `values`; setting it sets every band.
    private func mean(_ values: WritableKeyPath<SurfaceMaterial, [Double]>) -> Binding<Double> {
        Binding(
            get: { material[keyPath: values].reduce(0, +) / Double(material[keyPath: values].count) },
            set: { value in material[keyPath: values] = material[keyPath: values].map { _ in value } })
    }

    var body: some View {
        DisclosureGroup {
            TextField("Material", text: $material.name).endsEditingOnSubmit()
            TextField("Reference", text: $material.reference).endsEditingOnSubmit()
            LabeledContent("Scattering preset") {
                presetMenu(MaterialPresets.scattering, title: "Choose…") {
                    material = material.applying(scattering: $0)
                }
            }
            NumberField(title: "Scattering, all bands", value: mean(\.scattering))
                .help("Fraction of the reflected energy sent off diffusely rather than like a mirror")
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Band")
                    Text("Absorption α")
                    Text("Scattering s")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(OctaveBands.nominalCentres.indices, id: \.self) { band in
                    GridRow {
                        Text(Self.bandName(band)).font(.caption)
                        coefficient("α at \(Self.bandName(band))", $material.absorption[band])
                        coefficient("s at \(Self.bandName(band))", $material.scattering[band])
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                NumberField(title: title, value: mean(\.absorption))
                    .help(
                        "Mean absorption coefficient; editing it sets every band. Expand for scattering and each band."
                    )
                presetMenu(MaterialPresets.absorption, title: nil) {
                    material = material.applying(absorption: $0)
                }
                .help("Choose a material with published absorption. Now: \(material.name)")
            }
        }
    }

    /// A menu of presets grouped by category.
    private func presetMenu(
        _ presets: [MaterialPreset], title: String?, choose: @escaping (MaterialPreset) -> Void
    ) -> some View {
        Menu {
            ForEach(MaterialPresets.categories(of: presets), id: \.self) { category in
                Menu(category) {
                    ForEach(presets.filter { $0.category == category }) { preset in
                        Button(preset.name) { choose(preset) }
                    }
                }
            }
        } label: {
            if let title {
                Text(title)
            } else {
                Image(systemName: "books.vertical")
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func coefficient(_ title: String, _ value: Binding<Double>) -> some View {
        TextField(title, value: value, format: .number.precision(.fractionLength(0...2)))
            .endsEditingOnSubmit()
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .frame(width: 60)
    }

    static func bandName(_ band: Int) -> String {
        let centre = OctaveBands.nominalCentres[band]
        return centre >= 1000 ? "\(centre / 1000) kHz" : "\(centre) Hz"
    }
}

/// All inputs to a response, grouped as in the document.
struct RoomInspector: View {
    @Binding var project: RoomProject
    @State private var pendingPreset: RoomPreset?
    @State private var choosingModel = false
    @State private var pendingModel: PendingModel?
    @State private var modelError: String?

    private var settings: Binding<RoomResponseSettings> { $project.settings }

    var body: some View {
        Form {
            Section("Room") {
                Menu("Load Room Preset…") {
                    ForEach(RoomPresets.all) { preset in
                        Button {
                            pendingPreset = preset
                        } label: {
                            Text(preset.name)
                            Text(preset.summary)
                        }
                    }
                }
                .help("Replace the room, its surfaces and the positions with a furnished example")
                Menu("Shape: \(shapeName)") {
                    Button("Rectangle") { setShape(nil) }
                    Button("L-Shape") {
                        let size = project.settings.room.size
                        setShape(
                            .lShape(
                                [size.x, size.y], notch: [size.x / 2, size.y / 2], material: wallMaterial))
                    }
                    Button("T-Shape") {
                        let size = project.settings.room.size
                        setShape(
                            .tShape(
                                [size.x, size.y], stem: size.x * 0.4, bar: size.y * 0.4,
                                material: wallMaterial))
                    }
                    Button("Trapezoid") {
                        let size = project.settings.room.size
                        setShape(
                            .trapezoid(
                                width: size.x, depth: size.y, narrowTo: size.x * 0.6, material: wallMaterial))
                    }
                    Divider()
                    Button("Import Model…") {
                        modelError = nil
                        choosingModel = true
                    }
                }
                .fileImporter(isPresented: $choosingModel, allowedContentTypes: PendingModel.types) {
                    result in
                    do {
                        pendingModel = try PendingModel(url: result.get())
                    } catch {
                        modelError = error.localizedDescription
                    }
                }
                .sheet(item: $pendingModel) { model in
                    ModelImportSheet(model: model, material: wallMaterial) { room in
                        project.settings = project.settings.replacingRoom(with: room)
                    }
                }
                .help(
                    "A floor plan with vertical walls, whose corners drag in the plan view; or a model of any "
                        + "shape from an OBJ or STL file")
                if let modelError {
                    Label(modelError, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(
                        .callout)
                }
                if project.settings.room.mesh != nil {
                    LabeledContent("Length × width × height") {
                        Text(
                            String(
                                format: "%.2f × %.2f × %.2f m, from the shape", project.settings.room.size.x,
                                project.settings.room.size.y, project.settings.room.size.z)
                        )
                        .foregroundStyle(.secondary)
                    }
                } else if project.settings.room.plan == nil {
                    NumberField(title: "Length (x)", value: settings.room.size.component(0), unit: "m")
                    NumberField(title: "Width (y)", value: settings.room.size.component(1), unit: "m")
                } else {
                    LabeledContent("Length × width") {
                        Text(
                            String(
                                format: "%.2f × %.2f m, from the corners", project.settings.room.size.x,
                                project.settings.room.size.y)
                        )
                        .foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Corners") {
                        ForEach(project.settings.room.plan!.corners.indices, id: \.self) { index in
                            HStack {
                                NumberField(
                                    title: "Corner \(index + 1) x", value: corner(index, 0), unit: "m")
                                NumberField(title: "y", value: corner(index, 1), unit: "m")
                            }
                        }
                        HStack {
                            Button("Add Corner") { addCorner() }
                            Button("Remove Last Corner") { removeCorner() }
                                .disabled(project.settings.room.plan!.corners.count <= 3)
                        }
                    }
                }
                if project.settings.room.mesh == nil {
                    NumberField(title: "Height (z)", value: settings.room.size.component(2), unit: "m")
                }
            }
            Section("Surface absorption") {
                if let mesh = project.settings.room.mesh {
                    let areas = mesh.materialAreas
                    ForEach(mesh.materials.indices, id: \.self) { index in
                        MaterialEditor(
                            title: String(
                                format: "%@, %.0f m²", mesh.labels?[index] ?? "Surface \(index + 1)",
                                areas[index]),
                            material: Binding(
                                get: { project.settings.room.mesh?.materials[index] ?? .rigid },
                                set: { project.settings.room.mesh?.materials[index] = $0 }))
                    }
                } else if project.settings.room.plan == nil {
                    ForEach(Surface.allCases, id: \.self) { surface in
                        MaterialEditor(title: surface.rawValue.capitalized, material: settings.room[surface])
                    }
                } else {
                    MaterialEditor(title: "Floor", material: settings.room.floor)
                    MaterialEditor(title: "Ceiling", material: settings.room.ceiling)
                    ForEach(project.settings.room.plan!.walls.indices, id: \.self) { index in
                        MaterialEditor(
                            title: "Wall \(index + 1)",
                            material: Binding(
                                get: { project.settings.room.plan?.walls[index] ?? .rigid },
                                set: { project.settings.room.plan?.walls[index] = $0 }))
                    }
                }
                if project.settings.room.mesh == nil {
                    Button("Set All Surfaces Like the Floor") {
                        for surface in Surface.allCases {
                            project.settings.room[surface] = project.settings.room.floor
                        }
                        if let count = project.settings.room.plan?.walls.count {
                            project.settings.room.plan?.walls = Array(
                                repeating: project.settings.room.floor, count: count)
                        }
                    }
                }
            }
            Section("Source") {
                PointEditor(point: settings.source)
            }
            Section("Receivers") {
                Menu("Arrange First Two as a Stereo Pair") {
                    ForEach(StereoPair.allCases) { pair in
                        Button(pair.title) { project.settings = pair.arranged(in: project.settings) }
                    }
                }
                .disabled(project.settings.receivers.count < 2)
                .help(
                    "Place and aim the first two receivers as a standard pair around their centre, facing the source"
                )
                ForEach(settings.receivers) { $receiver in
                    PointEditor(point: $receiver)
                    MicrophoneEditor(microphone: $receiver.microphone)
                    if project.settings.receivers.count > 1 {
                        Button("Remove \(receiver.name)", role: .destructive) {
                            project.settings.receivers.removeAll { $0.id == receiver.id }
                        }
                    }
                }
                Button("Add Receiver") { addReceiver() }
                    .disabled(project.settings.receivers.count >= 16)
            }
            Section("Openings") {
                if project.settings.room.mesh != nil {
                    Text("A built shape's openings are part of the shape.").foregroundStyle(.secondary)
                } else {
                    ForEach(settings.openings) { $opening in
                        OpeningEditor(opening: $opening, walls: project.settings.room.plan?.corners.count)
                        Button("Remove \(opening.name)", role: .destructive) {
                            project.settings.openings.removeAll { $0.id == opening.id }
                        }
                    }
                    Button("Add Opening") { addOpening() }
                        .help("An open door or window: sound reaching it leaves the room")
                }
            }
            Section("Objects") {
                ForEach((project.settings.room.fittings ?? []).indices, id: \.self) { index in
                    ZoneEditor(zone: zoneBinding(index))
                    Button("Remove \(project.settings.room.fittings?[index].name ?? "")", role: .destructive)
                    {
                        project.settings.room.fittings?.remove(at: index)
                        if project.settings.room.fittings?.isEmpty == true {
                            project.settings.room.fittings = nil
                        }
                    }
                }
                Button("Add Seating Zone") { addZone() }
                    .help("A box of objects that scatter sound, such as chairs, desks, pews or ornament")
            }
            CalibrationSection(project: $project)
            Section("Simulation") {
                Picker("Sample rate", selection: settings.sampleRate) {
                    ForEach([44_100, 48_000, 96_000], id: \.self) {
                        Text("\((Double($0) / 1000).formatted()) kHz")
                    }
                }
                NumberField(title: "Duration", value: settings.duration, unit: "s")
                LabeledContent("Maximum order") {
                    TextField("Maximum order", value: settings.maximumReflectionOrder, format: .number)
                        .endsEditingOnSubmit()
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
                }
                Picker("Content", selection: settings.content) {
                    Text("Complete").tag(ResponseMetadata.Content.complete)
                    Text("Reflections only").tag(ResponseMetadata.Content.reflectionsOnly)
                }
                NumberField(
                    title: "Low cut (0 = off)", value: settings.lowFrequencyCutoff, unit: "Hz", digits: 0)
                LabeledContent("Diffuse rays") {
                    TextField("Diffuse rays", value: settings.diffuseRays, format: .number)
                        .endsEditingOnSubmit()
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
                }
                .help("Rays traced for the scattered energy. More rays give a smoother tail and take longer.")
                LabeledContent("Random seed") {
                    TextField("Random seed", value: settings.randomSeed, format: .number)
                        .endsEditingOnSubmit()
                        .labelsHidden().multilineTextAlignment(.trailing).frame(width: 72)
                }
                .help("Fixes the scattered tail's random detail, so a response can be reproduced exactly")
                Toggle("Wave solver for low frequencies", isOn: settings.lowFrequencyModel)
                    .help(
                        "Below the crossover, simulate the sound field on a grid, for the room's modes. "
                            + "Slower; skipped when the room is too large.")
                if project.settings.lowFrequencyModel {
                    Toggle(
                        "Automatic crossover",
                        isOn: Binding(
                            get: { project.settings.crossoverFrequency == nil },
                            set: { project.settings.crossoverFrequency = $0 ? nil : 150 }))
                    if project.settings.crossoverFrequency != nil {
                        NumberField(
                            title: "Crossover",
                            value: Binding(
                                get: { project.settings.crossoverFrequency ?? 150 },
                                set: { project.settings.crossoverFrequency = $0 }), unit: "Hz", digits: 0)
                    }
                }
                Toggle("Air absorption", isOn: settings.airAbsorption)
                NumberField(
                    title: "Temperature", value: settings.atmosphere.temperatureCelsius, unit: "°C", digits: 1
                )
                NumberField(
                    title: "Humidity", value: settings.atmosphere.relativeHumidity, unit: "%", digits: 0)
                LabeledContent("Image sources") {
                    Text("about \(Int(project.settings.estimatedImageCount).formatted()) per receiver")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Export") {
                Toggle(
                    "Normalize peak",
                    isOn: Binding(
                        get: { project.export.peak != nil },
                        set: { project.export.peak = $0 ? 0.5 : nil }))
                if project.export.peak != nil {
                    NumberField(
                        title: "Peak",
                        value: Binding(
                            get: { Double(project.export.peak ?? 0.5) },
                            set: { project.export.peak = Float($0) }))
                }
                NumberField(title: "Fade-out", value: $project.export.fadeOut, unit: "s", digits: 3)
                Toggle("Remove leading delay", isOn: $project.export.removeLeadingDelay)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Replace this room with “\(pendingPreset?.name ?? "")”?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } }),
            presenting: pendingPreset
        ) { preset in
            Button("Replace Room") { project.settings = preset.applied(to: project.settings) }
            Button("Cancel", role: .cancel) {}
        } message: { preset in
            Text(
                "\(preset.summary). The size, every surface, the source and listener positions, the duration "
                    + "and the reflection order change. This can't be undone.")
        }
    }

    private var shapeName: String {
        if let mesh = project.settings.room.mesh { return "Built shape, \(mesh.faces.count) faces" }
        guard let plan = project.settings.room.plan else { return "Rectangle" }
        return "\(plan.corners.count) walls"
    }

    /// The material new walls take: the north wall's, or the first plan wall's.
    private var wallMaterial: SurfaceMaterial {
        project.settings.room.plan?.walls.first ?? project.settings.room.north
    }

    private func setShape(_ plan: FloorPlan?) {
        project.settings.room.mesh = nil
        project.settings.room.plan = plan
        // Openings in walls belong to one kind of room or the other.
        project.settings.openings.removeAll {
            [.west, .east, .south, .north].contains($0.surface) || $0.wall != nil
        }
    }

    /// A corner coordinate; corners stay at or above zero, and the room grows to hold them.
    private func corner(_ index: Int, _ axis: Int) -> Binding<Double> {
        Binding(
            get: { project.settings.room.plan?.corners[index][axis] ?? 0 },
            set: { value in
                project.settings.room.plan?.corners[index][axis] = max(0, value)
                fitRoomToPlan()
            })
    }

    private func fitRoomToPlan() {
        guard let (_, high) = project.settings.room.plan?.bounds else { return }
        project.settings.room.size.x = max(high.x, 0.5)
        project.settings.room.size.y = max(high.y, 0.5)
    }

    /// A new corner halfway along the last wall.
    private func addCorner() {
        guard let plan = project.settings.room.plan else { return }
        let last = plan.count - 1
        project.settings.room.plan?.corners.append((plan.start(last) + plan.end(last)) / 2)
        project.settings.room.plan?.walls.append(plan.walls[last])
    }

    private func removeCorner() {
        project.settings.room.plan?.corners.removeLast()
        project.settings.room.plan?.walls.removeLast()
        let count = project.settings.room.plan?.corners.count ?? 0
        project.settings.openings.removeAll { ($0.wall ?? -1) >= count }
        fitRoomToPlan()
    }

    /// A door-sized opening in the middle of the north wall, or smaller if the wall is.
    private func addOpening() {
        let size = project.settings.room.size
        let width = min(0.9, size.x * 0.8)
        let height = min(2.0, size.z * 0.8)
        if let plan = project.settings.room.plan {
            // In the plan's first wall.
            let width = min(0.9, plan.length(0) * 0.8)
            project.settings.openings.append(
                Opening(
                    name: "Opening \(project.settings.openings.count + 1)", surface: .north, wall: 0,
                    centre: [plan.length(0) / 2, height / 2], size: [width, height]))
            return
        }
        project.settings.openings.append(
            Opening(
                name: "Opening \(project.settings.openings.count + 1)", surface: .north,
                centre: [size.x / 2, height / 2], size: [width, height]))
    }

    private func zoneBinding(_ index: Int) -> Binding<FittingZone> {
        Binding(
            get: { project.settings.room.fittings?[index] ?? Self.seating(in: project.settings.room.size) },
            set: { project.settings.room.fittings?[index] = $0 })
    }

    /// Seating over the middle of the floor, 0.9 m high.
    static func seating(in size: SIMD3<Double>) -> FittingZone {
        let low = SIMD3(size.x * 0.2, size.y * 0.1, 0)
        let high = SIMD3(size.x * 0.9, size.y * 0.9, min(0.9, size.z / 2))
        // About one seat to 0.55 m² of floor, each with 1.5 m² of surface.
        let floor = (high.x - low.x) * (high.y - low.y)
        return .objects(
            "Seating", low: low, high: high, count: floor / 0.55, area: 1.5,
            absorption: Array(repeating: 0, count: OctaveBands.count),
            reference:
                "Estimate: upholstered seats, one to 0.55 m² of floor, 1.5 m² of surface each. They scatter; "
                + "their absorption is left to the floor's audience material.")
    }

    private func addZone() {
        let zone = Self.seating(in: project.settings.room.size)
        project.settings.room.fittings = (project.settings.room.fittings ?? []) + [zone]
    }

    private func addReceiver() {
        let size = project.settings.room.size
        let number = project.settings.receivers.count + 1
        project.settings.receivers.append(
            RoomPoint(
                name: "Receiver \(number)", position: [size.x * 0.7, size.y * 0.5, min(1.2, size.z / 2)]))
    }
}
