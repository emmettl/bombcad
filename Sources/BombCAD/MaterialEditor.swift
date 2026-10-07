import BlastCore
import SwiftUI

/// Common engineering inputs. Changing a value makes a copy of the selected preset.
struct MaterialEditor: View {
    @Binding var material: StructureMaterial
    var body: some View {
        TextField("Material name", text: $material.name)
        number("Density", "kg/m³", \.density, scale: 1, range: 1...30_000)
        number("Young’s modulus", "GPa", \.youngsModulus, scale: 1e9, range: 0.001...1000)
        number("Poisson ratio", "", \.poissonRatio, scale: 1, range: 0...0.49)
        if material.model == .concrete {
            number("Compression strength", "MPa", \.compressiveStrength, scale: 1e6, range: 0.001...1000)
            number("Tension strength", "MPa", \.tensileStrength, scale: 1e6, range: 0.001...1000)
            number("Fracture energy", "J/m²", \.fractureEnergy, scale: 1, range: 0.001...100_000)
            number("Crushing energy", "J/m²", \.crushingEnergy, scale: 1, range: 0.001...1_000_000)
        } else {
            number("Yield stress", "MPa", \.yieldStress, scale: 1e6, range: 0.001...100_000)
            number("Hardening modulus", "GPa", \.hardeningModulus, scale: 1e9, range: 0...1000)
            number("Failure strain", "", \.failureStrain, scale: 1, range: 0.00001...100)
        }
        Text("Other properties retain the chosen preset’s values. Reinforcement is configured separately.")
            .font(.caption).foregroundStyle(.secondary)
    }
    private func number(
        _ title: String, _ unit: String, _ key: WritableKeyPath<StructureMaterial, Float>, scale: Float,
        range: ClosedRange<Float>
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(
                    title,
                    value: Binding(
                        get: { Double(material[keyPath: key] / scale) },
                        set: {
                            guard $0.isFinite else { return }
                            material[keyPath: key] =
                                min(max(Float($0), range.lowerBound), range.upperBound) * scale
                        }), format: .number.precision(.fractionLength(0...5))
                )
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
