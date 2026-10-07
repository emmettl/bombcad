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

/// Edits a surface's octave-band absorption and scattering.
struct MaterialEditor: View {
    let surface: Surface
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
                NumberField(title: surface.rawValue.capitalized, value: mean(\.absorption))
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
                NumberField(title: "Length (x)", value: settings.room.size.component(0), unit: "m")
                NumberField(title: "Width (y)", value: settings.room.size.component(1), unit: "m")
                NumberField(title: "Height (z)", value: settings.room.size.component(2), unit: "m")
            }
            Section("Surface absorption") {
                ForEach(Surface.allCases, id: \.self) { surface in
                    MaterialEditor(surface: surface, material: settings.room[surface])
                }
                Button("Set All Surfaces Like the Floor") {
                    for surface in Surface.allCases {
                        project.settings.room[surface] = project.settings.room.floor
                    }
                }
            }
            Section("Source") {
                PointEditor(point: settings.source)
            }
            Section("Receivers") {
                ForEach(settings.receivers) { $receiver in
                    PointEditor(point: $receiver)
                    if project.settings.receivers.count > 1 {
                        Button("Remove \(receiver.name)", role: .destructive) {
                            project.settings.receivers.removeAll { $0.id == receiver.id }
                        }
                    }
                }
                Button("Add Receiver") { addReceiver() }
                    .disabled(project.settings.receivers.count >= 16)
            }
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

    private func addReceiver() {
        let size = project.settings.room.size
        let number = project.settings.receivers.count + 1
        project.settings.receivers.append(
            RoomPoint(
                name: "Receiver \(number)", position: [size.x * 0.7, size.y * 0.5, min(1.2, size.z / 2)]))
    }
}
