import BlastCore
import SwiftUI

/// The scene's further charges, after the main one: each one's TNT mass, place and the delay, in
/// milliseconds after the main charge, at which it detonates.
struct AdditionalChargesView: View {
    @Bindable var model: SimulationModel

    private var charges: [Charge] { model.settings.scenario.additionalCharges ?? [] }

    var body: some View {
        DisclosureGroup("More charges (\(charges.count))") {
            ForEach(charges.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Charge \(index + 2)").font(.callout.weight(.medium))
                        Spacer()
                        Button(role: .destructive) {
                            var list = charges
                            list.remove(at: index)
                            model.settings.scenario.additionalCharges = list.isEmpty ? nil : list
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove charge \(index + 2)")
                    }
                    field("TNT, kg", index, \.mass, minimum: 0)
                    HStack {
                        field("X, m", index, \.position.x)
                        field("Y, m", index, \.position.y)
                        field("Height, m", index, \.position.z, minimum: 0)
                    }
                    TextField(
                        "Delay, ms",
                        value: Binding(
                            get: {
                                charges.indices.contains(index) ? Double(charges[index].delay ?? 0) * 1000 : 0
                            },
                            set: { value in
                                edit(index) { $0.delay = value > 0 ? Float(value / 1000) : nil }
                            }),
                        format: .number.precision(.fractionLength(0...3))
                    )
                    .help(
                        "How long after the main charge this one detonates, in milliseconds. The main charge "
                            + "fires at the start of the run.")
                }
                .padding(.vertical, 2)
            }
            Button("Add a charge") {
                var next = model.settings.scenario.charge
                next.delay = nil
                let size = model.domainSize
                next.position.x = min(next.position.x + 5, size.x - 1)
                model.settings.scenario.additionalCharges = charges + [next]
            }
            .help(
                "A further charge, as heavy as the main one and 5 m along from it, fired with it until given a delay."
            )
            ForEach(model.firingNotes, id: \.self) { note in
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if charges.contains(where: { ($0.delay ?? 0) > 0 }) {
                Text(
                    "Delayed charges are laid down as they fire. With the fine start, each is mapped if the air "
                        + "about it is still until its solution is due, else started as a ball of hot gas."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func edit(_ index: Int, _ change: (inout Charge) -> Void) {
        var list = charges
        guard list.indices.contains(index) else { return }
        change(&list[index])
        model.settings.scenario.additionalCharges = list
    }

    private func field(
        _ title: String, _ index: Int, _ path: WritableKeyPath<Charge, Float>, minimum: Float = -.infinity
    ) -> some View {
        TextField(
            title,
            value: Binding(
                get: { charges.indices.contains(index) ? Double(charges[index][keyPath: path]) : 0 },
                set: { value in edit(index) { $0[keyPath: path] = max(Float(value), minimum) } }),
            format: .number.precision(.fractionLength(0...2))
        )
        .help(title)
    }
}
