import BlastCore
import SwiftUI

/// Common engineering inputs. Changing a value makes a copy of the selected preset.
struct MaterialEditor: View {
    @Binding var material: StructureMaterial
    var body: some View {
        TextField("Material name", text: $material.name)
        number("Density", "kg/m³", \.density, scale: 1, range: 1...30_000)
        if material.model == .timber {
            TimberEditor(material: $material)
        } else {
            number("Young’s modulus", "GPa", \.youngsModulus, scale: 1e9, range: 0.001...1000)
            number("Poisson ratio", "", \.poissonRatio, scale: 1, range: 0...0.49)
        }
        if material.model == .concrete {
            number("Compression strength", "MPa", \.compressiveStrength, scale: 1e6, range: 0.001...1000)
            number("Tension strength", "MPa", \.tensileStrength, scale: 1e6, range: 0.001...1000)
            number("Fracture energy", "J/m²", \.fractureEnergy, scale: 1, range: 0.001...100_000)
            number("Crushing energy", "J/m²", \.crushingEnergy, scale: 1, range: 0.001...1_000_000)
        } else if material.model == .vonMises {
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

/// Timber's grain, layers, moduli and strengths (`TimberProperties`), all at their means; the
/// strengths before the dynamic increase factor.
struct TimberEditor: View {
    @Binding var material: StructureMaterial

    private var timber: Binding<TimberProperties> {
        Binding(
            get: { material.timber ?? TimberProperties.strengthClass(.c24) },
            set: { properties in
                material.timber = properties
                // The kernels read the modulus along the grain as the material's.
                material.youngsModulus = properties.alongGrain
                material.poissonRatio = properties.poissonRatio
            })
    }

    var body: some View {
        Picker("Grain along", selection: timber.grainAxis) {
            ForEach(0..<3, id: \.self) { Text(["x", "y", "z"][$0]).tag($0) }
        }
        .pickerStyle(.segmented)
        .help(
            "The global axis the grain of the outer lamellae runs along, in walls, floors and roofs it lies in."
        )
        Picker(
            "Lamellae",
            selection: Binding(
                get: { max(timber.wrappedValue.lamellae.count, 1) },
                set: { count in
                    timber.wrappedValue.lamellae = count > 1 ? TimberProperties.crossLaminated(count) : []
                })
        ) {
            Text("Solid").tag(1)
            ForEach([3, 5, 7], id: \.self) { Text("\($0)").tag($0) }
        }
        .help(
            "Cross-laminated timber: lamellae of equal thickness, crossing in turn, the outer ones along the grain."
        )
        value("Modulus along the grain", "GPa", \.alongGrain, scale: 1e9, range: 0.1...50)
        value("Modulus across the grain", "MPa", \.acrossGrain, scale: 1e6, range: 1...5000)
        value("Shear modulus", "MPa", \.shearModulus, scale: 1e6, range: 1...5000)
        value("Rolling shear modulus", "MPa", \.rollingShearModulus, scale: 1e6, range: 1...1000)
        value("Bending strength", "MPa", \.tensionAlong, scale: 1e6, range: 0.1...200)
        value("Compression along the grain", "MPa", \.compressionAlong, scale: 1e6, range: 0.1...200)
        value("Tension across the grain", "MPa", \.tensionAcross, scale: 1e6, range: 0.01...20)
        value("Compression across the grain", "MPa", \.compressionAcross, scale: 1e6, range: 0.1...50)
        value("Shear strength", "MPa", \.shearStrength, scale: 1e6, range: 0.1...50)
        value("Rolling shear strength", "MPa", \.rollingStrength, scale: 1e6, range: 0.01...20)
        value("Dynamic increase factor", "", \.strengthFactor, scale: 1, range: 1...3)
    }

    private func value(
        _ title: String, _ unit: String, _ key: WritableKeyPath<TimberProperties, Float>, scale: Float,
        range: ClosedRange<Float>
    ) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(
                    title,
                    value: Binding(
                        get: { Double(timber.wrappedValue[keyPath: key] / scale) },
                        set: {
                            guard $0.isFinite else { return }
                            timber.wrappedValue[keyPath: key] =
                                min(max(Float($0), range.lowerBound), range.upperBound) * scale
                        }), format: .number.precision(.fractionLength(0...3))
                )
                .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 90)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
