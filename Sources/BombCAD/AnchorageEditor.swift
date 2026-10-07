import BlastCore
import SwiftUI

/// Exact preset matching keeps a custom law visible without replacing it with a nearby preset.
struct AnchorageEditor: View {
    let title: String
    @Binding var law: Anchorage?

    private var choice: String {
        if law == nil { return BaseConnection.clamped.rawValue }
        return BaseConnection.allCases.first { $0.anchorage == law }?.rawValue ?? "custom"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Picker(
                title,
                selection: Binding(
                    get: { choice },
                    set: { value in
                        if let preset = BaseConnection(rawValue: value) { law = preset.anchorage }
                    })
            ) {
                ForEach(BaseConnection.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                if choice == "custom" { Text("Custom connection").tag("custom") }
            }
            .labelsHidden().accessibilityLabel(title)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if law != nil {
            DisclosureGroup("Connection properties") {
                number("Tensile strength", "MPa", \.tensileStrength, scale: 1e6)
                number("Strength plateau opening", "mm", \.tensionPlateau, scale: 0.001)
                number("Final opening", "mm", \.tensionOpening, scale: 0.001)
                number("Shear cohesion", "MPa", \.cohesion, scale: 1e6)
                number("Cohesion loss slip", "mm", \.cohesionSlip, scale: 0.001)
                number("Friction coefficient", "", \.friction, scale: 1)
                stiffness("Normal stiffness", \.normalStiffness)
                stiffness("Shear stiffness", \.shearStiffness)
                Text(
                    "Automatic stiffness uses the structure’s default material and element size. Strength and friction apply per unit bearing area; these presets are modelling assumptions."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func number(
        _ title: String, _ unit: String, _ key: WritableKeyPath<Anchorage, Float>, scale: Float
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(
                    title,
                    value: Binding(
                        get: { Double((law?[keyPath: key] ?? 0) / scale) },
                        set: { value in
                            guard value.isFinite, value >= 0, Float(value * Double(scale)).isFinite,
                                var candidate = law
                            else { return }
                            candidate[keyPath: key] = Float(value * Double(scale))
                            // Keep the envelope ordered as either opening is edited.
                            if key == \.tensionPlateau {
                                candidate.tensionOpening = max(
                                    candidate.tensionOpening, candidate.tensionPlateau)
                            }
                            if key == \.tensionOpening {
                                candidate.tensionPlateau = min(
                                    candidate.tensionPlateau, candidate.tensionOpening)
                            }
                            law = candidate
                        }), format: .number.precision(.fractionLength(0...5))
                )
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func stiffness(_ title: String, _ key: WritableKeyPath<Anchorage, Float?>) -> some View {
        VStack(alignment: .leading) {
            Toggle(
                "Automatic \(title.lowercased())",
                isOn: Binding(
                    get: { law?[keyPath: key] == nil },
                    set: { automatic in
                        guard var candidate = law else { return }
                        candidate[keyPath: key] = automatic ? nil : 1e9
                        law = candidate
                    }))
            if law?[keyPath: key] != nil {
                LabeledContent(title + " (GPa/m)") {
                    TextField(
                        title,
                        value: Binding(
                            get: { Double(law?[keyPath: key] ?? 1e9) / 1e9 },
                            set: { value in
                                guard value.isFinite, value > 0, Float(value * 1e9).isFinite,
                                    var candidate = law
                                else { return }
                                candidate[keyPath: key] = Float(value * 1e9)
                                law = candidate
                            }), format: .number.precision(.fractionLength(0...5))
                    )
                    .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 85)
                }
            }
        }
    }
}
