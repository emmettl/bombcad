import BlastCore
import SwiftUI
import UniformTypeIdentifiers

struct EnvelopeExposureSection: View {
    @Bindable var model: SimulationModel
    @State private var selectedID: UUID?
    @State private var export: EnvelopeResultsDocument?
    @State private var exportError: String?

    private var selected: EnvelopeExposureSummary? {
        model.envelopeExposure.first { $0.id == selectedID } ?? model.envelopeExposure.first
    }

    var body: some View {
        if !model.settings.scenario.envelopeObjects.isEmpty {
            Section("Building surface exposure") {
                if let result = selected {
                    Picker("Building", selection: Binding(get: { selected?.id }, set: { selectedID = $0 })) {
                        ForEach(Array(model.envelopeExposure.enumerated()), id: \.element.id) {
                            index, building in
                            Text("\(index + 1). \(building.name)").tag(Optional(building.id))
                        }
                    }
                    LabeledContent("Window", value: String(format: "%.1f ms", result.elapsedS * 1000))
                    LabeledContent("Resolved surface", value: String(format: "%.1f m²", result.validAreaM2))
                    LabeledContent(
                        "Peak overpressure", value: String(format: "%.2f kPa", result.peakPositivePa / 1000))
                    LabeledContent(
                        "Mean positive impulse",
                        value: String(format: "%.2f Pa s", result.meanPositiveImpulsePaS ?? 0))
                    LabeledContent(
                        "Summed positive loading",
                        value: String(format: "%.2f N s", result.surfacePositiveImpulseNS)
                    )
                    .help(
                        "Positive pressure impulse integrated over all resolved interior and exterior surfaces. This scalar sum is not a resultant vector impulse."
                    )
                    VStack(alignment: .leading) {
                        Text("Force now (x, y, z)").font(.caption).foregroundStyle(.secondary)
                        Text(vector(result.forceN, unit: "N"))
                    }
                    VStack(alignment: .leading) {
                        Text("Signed impulse (x, y, z)").font(.caption).foregroundStyle(.secondary)
                        Text(vector(result.signedImpulseNS, unit: "N s"))
                    }
                    if result.invalidFaceCount > 0 {
                        Text("\(result.invalidFaceCount) changed faces are excluded from these results.")
                            .foregroundStyle(.orange).font(.caption)
                    }
                    Button("Export surface records…") {
                        do { export = EnvelopeResultsDocument(data: try model.envelopeResultsData()) } catch {
                            exportError = error.localizedDescription
                        }
                    }
                    .disabled(!model.canExportEnvelopeExposure)
                    .help(
                        "Pause to export each building's resolved faces and cumulative pressure exposure as JSON."
                    )
                } else {
                    Text(
                        model.envelopeExposureStatus.isEmpty
                            ? "Surface results will appear when the scene is ready."
                            : model.envelopeExposureStatus
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Text(
                    "Stationary voxel surfaces, including interiors. Loads use adjacent-cell pressure; no deformation or failure is predicted. Kept runs retain building summaries; JSON exports retain individual faces."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .monospacedDigit()
            .fileExporter(
                isPresented: Binding(get: { export != nil }, set: { if !$0 { export = nil } }),
                document: export, contentType: .json, defaultFilename: "BombCAD building surfaces"
            ) { result in
                if case .failure(let error) = result { exportError = error.localizedDescription }
            }
            .alert(
                "Surface export failed",
                isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })
            ) {
                Button("OK") { exportError = nil }
            } message: {
                Text(exportError ?? "")
            }
        }
    }

    private func vector(_ value: SIMD3<Double>, unit: String) -> String {
        String(format: "(%.2f, %.2f, %.2f) %@", value.x, value.y, value.z, unit)
    }
}

struct EnvelopeResultsDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
