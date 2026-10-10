import BlastCore
import Charts
import SwiftUI

/// The Run tab's Ground shock section: a line of points on the ground, and the soil under them,
/// whose shaking each run reckons from the overpressure on the ground, here or on a Mac set for
/// sweeps, drawn as dots there, with the column's response at depth under one of them charted.
struct GroundShockSection: View {
    @Bindable var model: SimulationModel

    private static let counts = [8, 16, 32, 64]
    private static let deepest: [Float] = [3, 5, 10, 20]

    /// What lies under the top layer, as the app offers it.
    enum Beneath: String, CaseIterable, Identifiable {
        case same = "More of the same"
        case stiffSoil = "Stiff soil"
        case rock = "Rock"
        case rigid = "Rigid rock"
        var id: Self { self }

        var base: SoilBase? {
            switch self {
            case .same: nil
            case .stiffSoil: .halfSpace(density: 1900, waveSpeed: 900)
            case .rock: .halfSpace(density: 2500, waveSpeed: 2500)
            case .rigid: .rigid
            }
        }

        init(_ base: SoilBase?) {
            self = Self.allCases.first { $0.base == base } ?? .same
        }
    }

    var body: some View {
        Section("Ground shock") {
            Toggle("Ground points", isOn: enabled)
                .help(
                    "Estimates how the ground shakes under a line of points from the overpressure the run "
                        + "records on the ground. Illustrative: the design manuals' one-dimensional "
                        + "air-induced ground shock, away from the charge; the ground stays rigid for the air."
                )
            if let spec = model.groundShockSpec {
                Picker("Model", selection: modelChoice) {
                    Text("Soil column").tag(GroundShockModel.column)
                    Text("Manual estimate").tag(GroundShockModel.estimate)
                }
                .help(
                    "The soil column follows the wave down through layers that load and unload at "
                        + "different stiffnesses; the manual estimate scales the peak and impulse on the ground."
                )
                LabeledSlider(
                    title: "Soil density",
                    value: Binding(
                        get: { Double(spec.soil.density) },
                        set: { value in top { $0.density = Float((value / 50).rounded() * 50) } }),
                    range: 1000...2800, text: "\(Int(spec.soil.density)) kg/m³")
                LabeledSlider(
                    title: "Wave speed",
                    value: Binding(
                        get: { log10(Double(spec.soil.waveSpeed)) },
                        set: { value in top { $0.waveSpeed = Self.roundedSpeed(pow(10, value)) } }),
                    range: 2...3.6, text: "\(Int(spec.soil.waveSpeed)) m/s")
                if spec.model == .column, let layer = spec.profile?.layers.first {
                    LabeledSlider(
                        title: "Unloading",
                        value: Binding(
                            get: { Double(layer.unloadingSpeed / layer.waveSpeed) },
                            set: { value in
                                let ratio = Float((value * 4).rounded() / 4)
                                model.groundShockSpec?.profile?.layers[0].unloadingWaveSpeed =
                                    ratio > 1 ? Self.roundedSpeed(Double(ratio * layer.waveSpeed)) : nil
                            }),
                        range: 1...4,
                        text: String(format: "%.2g× as stiff a wave", layer.unloadingSpeed / layer.waveSpeed)
                    )
                    .help(
                        "How much faster the soil carries a wave unloading than loading: 1 for elastic soil.")
                    Picker("Beneath", selection: beneath) {
                        ForEach(Beneath.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if Beneath(spec.profile?.base) != .same {
                        LabeledSlider(
                            title: "Layer depth",
                            value: Binding(
                                get: { Double(layer.thickness) },
                                set: {
                                    model.groundShockSpec?.profile?.layers[0].thickness = Float(
                                        ($0 * 2).rounded() / 2)
                                }
                            ),
                            range: 0.5...20, text: String(format: "%.1f m", layer.thickness))
                    }
                    Picker("Down to", selection: deepest) {
                        ForEach(Self.deepest, id: \.self) { Text("\(Int($0)) m").tag($0) }
                    }
                }
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
                if let result = model.groundShockLive, result.points.contains(where: { $0.profile != nil }) {
                    GroundDepthChart(result: result)
                }
            }
        }
    }

    private var modelChoice: Binding<GroundShockModel> {
        Binding(
            get: { model.groundShockSpec?.model ?? .column },
            set: { choice in
                guard var spec = model.groundShockSpec else { return }
                spec.model = choice
                if choice == .column, spec.profile == nil { spec.profile = Self.defaultProfile(spec.soil) }
                model.groundShockSpec = spec
            })
    }

    /// Sets the soil at the surface: the estimate's and the column's top layer alike.
    private func top(_ change: (inout SoilLayer) -> Void) {
        guard var spec = model.groundShockSpec else { return }
        var layer = spec.profile?.layers.first ?? Self.defaultProfile(spec.soil).layers[0]
        let ratio = layer.unloadingSpeed / layer.waveSpeed
        change(&layer)
        layer.unloadingWaveSpeed = ratio > 1 ? Self.roundedSpeed(Double(ratio * layer.waveSpeed)) : nil
        spec.soil = GroundSoil(density: layer.density, waveSpeed: layer.waveSpeed)
        if spec.profile != nil { spec.profile?.layers[0] = layer }
        model.groundShockSpec = spec
    }

    private var beneath: Binding<Beneath> {
        Binding(
            get: { Beneath(model.groundShockSpec?.profile?.base) },
            set: { model.groundShockSpec?.profile?.base = $0.base })
    }

    private var deepest: Binding<Float> {
        Binding(
            get: { model.groundShockSpec?.depths.max() ?? 3 },
            set: { model.groundShockSpec?.depths = [0, 1, 3] + ($0 > 3 ? [$0] : []) })
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

    /// A column of `soil` that unloads at twice its loading wave speed, going on for ever.
    static func defaultProfile(_ soil: GroundSoil) -> SoilProfile {
        SoilProfile(
            layers: [
                SoilLayer(
                    thickness: 3, density: soil.density, waveSpeed: soil.waveSpeed,
                    unloadingWaveSpeed: 2 * soil.waveSpeed)
            ])
    }

    /// Sixteen points from a metre beside the charge to a metre short of the domain's edge, the
    /// way the ground runs furthest, in dry soil of 1,600 kg/m³ at 300 m/s, loading at that
    /// speed and unloading at twice it, as a soil column.
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
        spec.model = .column
        spec.profile = defaultProfile(spec.soil)
        spec.line = .init(
            from: charge + direction * start, to: charge + direction * max(room - 1, start), count: 16)
        return spec
    }
}

/// One ground point's column: its peaks from the surface down, or its downward velocity at each
/// depth asked for through the run. The point is the one where the ground moves fastest unless
/// another is chosen.
struct GroundDepthChart: View {
    let result: GroundShockResult
    @State private var chosen: Int?
    @State private var motion = false

    private var columns: [Int] { result.points.indices.filter { result.points[$0].profile != nil } }

    private var index: Int {
        if let chosen, columns.contains(chosen) { return chosen }
        return columns.max {
            result.points[$0].surfaceVelocity(in: result.soil)
                < result.points[$1].surfaceVelocity(in: result.soil)
        } ?? 0
    }

    private struct Level {
        var depth: Double
        var value: Double
        var series: String
    }

    var body: some View {
        let point = result.points[index]
        VStack(alignment: .leading, spacing: 6) {
            Picker("Show", selection: $motion) {
                Text("Peaks with depth").tag(false)
                Text("Motion at depth").tag(true)
            }
            .pickerStyle(.segmented)
            Stepper(
                String(
                    format: "Point %d of %d, (%.1f, %.1f)", index + 1, result.points.count, point.position.x,
                    point.position.y),
                value: Binding(get: { index }, set: { chosen = min(max($0, 0), result.points.count - 1) }),
                in: 0...max(result.points.count - 1, 0)
            )
            .font(.caption)
            if motion { motionChart(point) } else if let profile = point.profile { peakChart(profile) }
        }
    }

    private func peakChart(_ profile: GroundDepthProfile) -> some View {
        let levels =
            profile.depths.indices.map {
                Level(
                    depth: Double(profile.depths[$0]), value: Double(profile.velocity[$0]) * 1000,
                    series: "Peak")
            }
            + profile.depths.indices.map {
                Level(
                    depth: Double(profile.depths[$0]), value: Double(profile.residualDisplacement[$0]) * 1000,
                    series: "Left (mm)")
            }
        return VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(levels.indices, id: \.self) { n in
                    LineMark(
                        x: .value("Value", levels[n].value), y: .value("Depth", levels[n].depth),
                        series: .value("Series", levels[n].series)
                    )
                    .foregroundStyle(by: .value("Series", levels[n].series))
                }
            }
            .chartForegroundStyleScale([
                "Peak": Color.primary, "Left (mm)": Color(red: 0.2, green: 0.62, blue: 0.68),
            ])
            .chartYScale(domain: .automatic(includesZero: true, reversed: true))
            .chartXAxisLabel("Downward velocity (mm/s), settlement left (mm)")
            .chartYAxisLabel("Depth (m)")
            .frame(height: 150)
            Text(
                "The fastest the soil moved down at each depth, and how far down it was left at the last frame."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func motionChart(_ point: GroundPointResult) -> some View {
        let times = result.frameTimes ?? []
        let samples = point.responses.flatMap { response in
            (response.history ?? []).enumerated().map { frame, velocity in
                Level(
                    depth: (frame < times.count ? times[frame] : Double(frame) * result.frameInterval) * 1000,
                    value: Double(velocity) * 1000,
                    series: String(format: "%g m", response.depth))
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Chart {
                ForEach(samples.indices, id: \.self) { n in
                    LineMark(
                        x: .value("Time", samples[n].depth), y: .value("Velocity", samples[n].value),
                        series: .value("Depth", samples[n].series)
                    )
                    .foregroundStyle(by: .value("Depth", samples[n].series))
                }
            }
            .chartXAxisLabel("Time (ms)")
            .chartYAxisLabel("Down (mm/s)")
            .frame(height: 150)
            Text("The soil's downward velocity at each depth, a value a frame.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
