import BlastCore
import SwiftUI

/// An envelope's construction beyond its walls' kind, for its one-way damage: the walls'
/// thickness and bars, their strengths, reinforced blockwork's grout, and a cap carried on a
/// freestanding wall's top. The air never sees any of it.
struct EnvelopeConstructionEditor: View {
    let model: SimulationModel
    let id: UUID

    var body: some View {
        let construction = model.settings.scenario.envelopeConstruction(for: id)
        let reinforced = construction.walls != .unreinforcedMasonry
        DisclosureGroup("Construction") {
            number("Wall thickness", "m", Double(construction.wallThicknessM)) { value in
                edit { $0.wallThicknessM = Float(max(value, 0.01)) }
            }
            if reinforced {
                number("Bars, each way", "%", Double(construction.reinforcementRatio) * 100) { value in
                    edit { $0.reinforcementRatio = Float(max(value, 0)) / 100 }
                }
                Toggle(
                    "Bars in both faces",
                    isOn: Binding(
                        get: { construction.barsInBothFaces == true },
                        set: { on in edit { $0.barsInBothFaces = on ? true : nil } })
                )
                .help("A mat in each face, the bars shared between them; off, one mat at mid-thickness.")
                if construction.barsInBothFaces == true {
                    number("Cover to the bars' centres", "m", Double(construction.barCoverM ?? 0.03)) {
                        value in
                        edit { $0.barCoverM = Float(max(value, 0)) }
                    }
                }
                number("Bars' yield", "MPa", Double(construction.barYieldMPa ?? 500)) { value in
                    edit { $0.barYieldMPa = Float(max(value, 1)) }
                }
            }
            if construction.walls == .reinforcedConcrete {
                number("Concrete strength", "MPa", Double(construction.concreteStrengthMPa ?? 30)) { value in
                    edit { $0.concreteStrengthMPa = Float(max(value, 1)) }
                }
            }
            if construction.walls == .reinforcedBlockwork {
                let grouted = construction.blockworkGrouted ?? true
                Toggle(
                    "Fully grouted",
                    isOn: Binding(
                        get: { grouted }, set: { on in edit { $0.blockworkGrouted = on ? nil : false } })
                )
                .help("Grout in every cell; off, the cells hold only the bars (hollow blockwork).")
                number(
                    "Masonry strength", "MPa", Double(construction.masonryStrengthMPa ?? (grouted ? 10 : 3))
                ) { value in
                    edit { $0.masonryStrengthMPa = Float(max(value, 0.5)) }
                }
            }
            if reinforced {
                number("Cap on a freestanding wall", "kg/m", Double(construction.capMassKgPerM ?? 0)) {
                    value in
                    edit { $0.capMassKgPerM = value > 0 ? Float(value) : nil }
                }
                .help(
                    "A cap or canopy carried on the top of a wall that stands free: mass moving with the top, "
                        + "not a support.")
            }
        }
        .font(.callout)
    }

    private func edit(_ change: (inout EnvelopeConstruction) -> Void) {
        model.editEnvelopeConstruction(id: id, change)
    }

    private func number(
        _ title: String, _ unit: String, _ value: Double, set: @escaping @MainActor (Double) -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(
                    "", value: Binding(get: { value }, set: set),
                    format: .number.precision(.fractionLength(0...3))
                )
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
