import BlastCore
import SwiftUI

/// The Run tab's Ground shock section: a line of points on the ground, and the soil under them,
/// whose shaking each run estimates from the overpressure on the ground, here or on a Mac set for
/// sweeps, drawn as dots there.
struct GroundShockSection: View {
    @Bindable var model: SimulationModel

    private static let counts = [8, 16, 32, 64]

    var body: some View {
        Section("Ground shock") {
            Toggle("Ground points", isOn: enabled)
                .help(
                    "Estimates how the ground shakes under a line of points from the overpressure the run "
                        + "records on the ground. Illustrative: the design manuals' one-dimensional "
                        + "air-induced ground shock, away from the charge; the ground stays rigid for the air."
                )
            if let spec = model.groundShockSpec {
                LabeledSlider(
                    title: "Soil density",
                    value: Binding(
                        get: { Double(spec.soil.density) },
                        set: { model.groundShockSpec?.soil.density = Float(($0 / 50).rounded() * 50) }),
                    range: 1000...2800, text: "\(Int(spec.soil.density)) kg/m³")
                LabeledSlider(
                    title: "Wave speed",
                    value: Binding(
                        get: { log10(Double(spec.soil.waveSpeed)) },
                        set: { model.groundShockSpec?.soil.waveSpeed = Self.roundedSpeed(pow(10, $0)) }),
                    range: 2...3.6, text: "\(Int(spec.soil.waveSpeed)) m/s")
                Picker("Points", selection: line(\.count)) {
                    ForEach(Self.counts, id: \.self) { Text("\($0)").tag($0) }
                }
                coordinate("From x", \.from.x, axis: 0)
                coordinate("From y", \.from.y, axis: 1)
                coordinate("To x", \.to.x, axis: 0)
                coordinate("To y", \.to.y, axis: 1)
                PlacementPicker(
                    title: "Run on", host: $model.groundShockHost,
                    help: "Estimates the shaking here or on a Mac set for sweeps in Settings, frame by frame."
                )
                Text(
                    model.groundShockStatus.isEmpty
                        ? "Changes take effect from the next run." : model.groundShockStatus
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.groundShockSpec != nil },
            set: { model.groundShockSpec = $0 ? Self.defaultSpec(for: model.settings.scenario) : nil })
    }

    private func line<Value>(_ path: WritableKeyPath<GroundShockSpec.Line, Value>) -> Binding<Value> {
        Binding(
            get: {
                (model.groundShockSpec?.line ?? Self.defaultSpec(for: model.settings.scenario).line!)[
                    keyPath: path]
            },
            set: { model.groundShockSpec?.line?[keyPath: path] = $0 })
    }

    /// One end's coordinate, to the half metre, within the domain.
    private func coordinate(
        _ title: String, _ path: WritableKeyPath<GroundShockSpec.Line, Float>, axis: Int
    ) -> some View {
        let size = Double(model.domainSize[axis])
        let value = line(path)
        return LabeledSlider(
            title: title,
            value: Binding(
                get: { Double(value.wrappedValue) },
                set: { value.wrappedValue = Float(($0 * 2).rounded() / 2) }),
            range: 0...size, text: String(format: "%.1f m", value.wrappedValue))
    }

    /// Two significant figures: 300, 1,500, 2,400 m/s.
    private static func roundedSpeed(_ speed: Double) -> Float {
        let step = pow(10, floor(log10(speed)) - 1)
        return Float((speed / step).rounded() * step)
    }

    /// Sixteen points from a metre beside the charge to a metre short of the domain's edge, the
    /// way the ground runs furthest, in dry soil of 1,600 kg/m³ at 300 m/s.
    static func defaultSpec(for scenario: Scenario) -> GroundShockSpec {
        let charge = SIMD2(scenario.charge.position.x, scenario.charge.position.y)
        let size = SIMD2(scenario.domainSize.x, scenario.domainSize.y)
        let directions: [(SIMD2<Float>, Float)] = [
            (SIMD2(1, 0), size.x - charge.x), (SIMD2(-1, 0), charge.x),
            (SIMD2(0, 1), size.y - charge.y), (SIMD2(0, -1), charge.y),
        ]
        let (direction, room) = directions.max { $0.1 < $1.1 }!
        let start = min(1, room / 4)
        var spec = GroundShockSpec()
        spec.line = .init(
            from: charge + direction * start, to: charge + direction * max(room - 1, start), count: 16)
        return spec
    }
}
