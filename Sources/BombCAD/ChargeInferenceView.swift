import BlastCore
import SwiftUI
import UniformTypeIdentifiers
import simd

/// Simulation ▸ Infer Charge: the charge's yield, place and, if asked, height and clock offset
/// from observers' arrival times (and, illustratively, broken glass), by `ChargeInference`.
struct ChargeInferenceView: View {
    let model: SimulationModel
    @State var inference: ChargeInferenceModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusesTemperature: Bool
    @State private var importing: Importing?
    @State private var cornerLongitude = ""
    @State private var cornerLatitude = ""
    @State private var placed: String?

    private enum Importing: Identifiable {
        case observers, glass
        var id: Self { self }
    }

    var body: some View {
        @Bindable var inference = inference
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Infer charge").font(.title2)
                    Spacer()
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                Text(
                    "The charge's yield and place, with their uncertainty, from when observers saw or heard the shock arrive, by Kingery–Bulmash's arrival times. An inference, not a run: about a second on this Mac's processor."
                )
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                inputs(inference)
                runControls
                if let error = inference.error {
                    Text(error).foregroundStyle(.red).font(.callout).fixedSize(
                        horizontal: false, vertical: true)
                }
                if let result = inference.result {
                    Divider()
                    ChargeInferenceResultView(result: result, usesGlass: result.facades > 0)
                    placement(result)
                }
            }
            .padding(20)
        }
        .frame(width: 600, alignment: .leading).frame(minHeight: 560, alignment: .top)
        .fileImporter(
            isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil } }),
            allowedContentTypes: importing == .glass
                ? [.commaSeparatedText, UTType(filenameExtension: "shp") ?? .data]
                : [.commaSeparatedText, .plainText]
        ) { picked in
            let which = importing
            importing = nil
            guard case .success(let url) = picked else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            if which == .glass { self.inference.chooseGlass(url) } else { self.inference.loadObservers(url) }
        }
        .defaultFocus($focusesTemperature, true)
        .task { focusesTemperature = true }
    }

    private func inputs(_ inference: ChargeInferenceModel) -> some View {
        @Bindable var inference = inference
        return Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("Observers")
                HStack {
                    Button("Choose Arrivals…") { importing = .observers }
                    Text(
                        inference.observers.isEmpty
                            ? "A CSV: name,lat,lon,earliest_s,latest_s, or Rigby et al.'s table"
                            : "\(inference.observers.count) from \(inference.observersFile)"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Reference point")
                HStack {
                    TextField("Longitude", text: $inference.referenceLongitude).frame(width: 110)
                        .accessibilityLabel("Reference longitude")
                    TextField("Latitude", text: $inference.referenceLatitude).frame(width: 110)
                        .accessibilityLabel("Reference latitude")
                    Text("the place is searched about it").font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Air")
                HStack {
                    TextField("Temperature (°C)", value: $inference.temperatureC, format: .number)
                        .frame(width: 70).focused($focusesTemperature)
                        .accessibilityLabel("Air temperature (°C)")
                    Text("°C; the curves are for 15 °C").font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Yield searched")
                HStack {
                    TextField("From (kt)", value: $inference.lowestKilotonnes, format: .number).frame(
                        width: 70
                    )
                    .accessibilityLabel("Yield searched from (kt TNT)")
                    Text("to")
                    TextField("To (kt)", value: $inference.highestKilotonnes, format: .number).frame(
                        width: 70
                    )
                    .accessibilityLabel("Yield searched to (kt TNT)")
                    Text("kt TNT, even in its logarithm").font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Place searched")
                HStack {
                    TextField("Radius (m)", value: $inference.searchRadius, format: .number).frame(width: 70)
                        .accessibilityLabel("Place searched within (m)")
                    Text("m of the reference point").font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("Also infer")
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("A clock offset common to all, within ±", isOn: $inference.infersOffset)
                        TextField("Offset (s)", value: $inference.offsetReach, format: .number).frame(
                            width: 60
                        )
                        .disabled(!inference.infersOffset).accessibilityLabel("Clock offset within ± (s)")
                        Text("s")
                    }
                    HStack {
                        Toggle("The burst's height, up to", isOn: $inference.infersHeight)
                        TextField("Height (m)", value: $inference.highestBurst, format: .number).frame(
                            width: 60
                        )
                        .disabled(!inference.infersHeight).accessibilityLabel("Burst height up to (m)")
                        Text("m")
                    }
                }
            }
            GridRow {
                Text("Broken glass")
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button("Choose Survey…") { importing = .glass }
                        Text(
                            inference.glassFile.isEmpty
                                ? "GEER's façade shapefile, or a CSV" : inference.glassFile
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle(
                        "Use it (illustrative: it fits no yield, and biases the result)",
                        isOn: $inference.usesGlass)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(inference.isRunning)
    }

    @ViewBuilder private var runControls: some View {
        if inference.isRunning {
            HStack {
                ProgressView(value: inference.progress).accessibilityLabel("Inference progress")
                Button("Cancel") { inference.cancel() }
            }
        } else {
            HStack {
                Button("Infer") { inference.run() }.keyboardShortcut(.defaultAction)
                    .disabled(inference.notReady != nil)
                if let reason = inference.notReady {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Putting the scene's charge at the median, through the scene corner's longitude and latitude.
    private func placement(_ result: ChargeInferenceModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("In this scene").font(.headline)
            Text(
                "Give the longitude and latitude of the scene's corner (0, 0), as a map import does, to put the scene's charge at the median place and yield."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Corner longitude", text: $cornerLongitude).frame(width: 120)
                TextField("Corner latitude", text: $cornerLatitude).frame(width: 120)
                Button("Place Charge at Median") { place() }
                    .disabled(corner == nil || model.stepCount != 0)
            }
            .textFieldStyle(.roundedBorder)
            if model.stepCount != 0 {
                Text("Reset the simulation to move its charge.").font(.caption).foregroundStyle(.secondary)
            }
            if let placed { Text(placed).font(.caption) }
        }
    }

    private var corner: SIMD2<Double>? {
        guard let lon = Double(cornerLongitude), let lat = Double(cornerLatitude), abs(lat) < 90 else {
            return nil
        }
        return SIMD2(lon, lat)
    }

    private func place() {
        guard let corner, let (position, mass) = inference.scenePlacement(corner: corner) else { return }
        let domain = model.settings.scenario.domainSize
        guard position.x >= 0, position.y >= 0, position.x <= domain.x, position.y <= domain.y,
            position.z <= domain.z
        else {
            placed = String(
                format: "The median place, (%.0f, %.0f) m, lies outside the scene's %.0f × %.0f m.",
                position.x,
                position.y, domain.x, domain.y)
            return
        }
        model.settings.chargePosition = position
        model.settings.chargeMass = mass
        placed = String(
            format: "The charge is now %@ at (%.1f, %.1f, %.1f) m.", SimulationSettings.massText(mass),
            position.x,
            position.y, position.z)
    }
}

/// The posterior: the yield and its intervals, the place on a plan of the observers, height and
/// offset where they were inferred, and the standing.
struct ChargeInferenceResultView: View {
    let result: ChargeInferenceModel.Result
    let usesGlass: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let kt = result.kilotonnes {
                Text(
                    String(
                        format: "Yield %@ kt TNT", Self.figure(kt.median))
                )
                .font(.title3)
                Text(
                    "68%: \(Self.figure(kt.p16))–\(Self.figure(kt.p84)) kt, 90%: \(Self.figure(kt.p05))–\(Self.figure(kt.p95)) kt"
                )
                .font(.callout)
            }
            if let place = result.place, let lonLat = result.placeLonLat {
                Text(
                    String(
                        format:
                            "Place %.6f N %.6f E, %.0f m east and %.0f m north of the reference point; half the samples within %.0f m of it, 90%% within %.0f m",
                        lonLat.y, lonLat.x, place.x, place.y, result.posterior.placeRadius(holding: 0.5),
                        result.posterior.placeRadius(holding: 0.9))
                )
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let height = result.interval("height") {
                Text(
                    String(
                        format: "Height %.0f m (68%%: %.0f–%.0f, 90%%: %.0f–%.0f)", height.median, height.p16,
                        height.p84, height.p05, height.p95)
                ).font(.callout)
            }
            if let offset = result.interval("offset") {
                Text(
                    String(
                        format: "Clock offset %.3f s (68%%: %.3f–%.3f, 90%%: %.3f–%.3f)", offset.median,
                        offset.p16,
                        offset.p84, offset.p05, offset.p95)
                ).font(.callout)
            }
            if let spread = result.interval("logSpread") {
                Text(
                    String(
                        format:
                            "The observers lie %.1f%% off the model (90%%: %.1f–%.1f%%); %d arrivals%@, %.1f s",
                        100 * exp(spread.median), 100 * exp(spread.p05), 100 * exp(spread.p95),
                        result.arrivals.count, result.facades > 0 ? ", \(result.facades) façades" : "",
                        result.seconds)
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            ChargeInferencePlan(result: result).frame(height: 260)
            Text(
                "Blue: the observers. Cross: the reference point. Orange: the place's samples, the red circles holding half and 90% of them, close up at the top right when small."
            )
            .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            standing
        }
    }

    private var standing: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Standing: \((usesGlass ? EvidenceLevel.illustrative : .approximation).title)").font(
                .headline)
            ForEach(Array(ChargeInference.standing.enumerated()), id: \.offset) { index, line in
                // The glass's line only when glass was used.
                if index < ChargeInference.standing.count - 1 || usesGlass {
                    Text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("See docs/validation.md, \"Estimates beside a run\".").font(.caption2).foregroundStyle(
                .secondary)
        }
    }

    /// A yield to three significant figures.
    static func figure(_ value: Double) -> String { String(format: "%.3g", value) }
}

/// A plan of the observers, the posterior's samples of the place, and the circles about its median
/// holding half and 90% of them; north up.
struct ChargeInferencePlan: View {
    let result: ChargeInferenceModel.Result

    var body: some View {
        let posterior = result.posterior
        let east = posterior.names.firstIndex(of: "east")
        let north = posterior.names.firstIndex(of: "north")
        let samples: [SIMD2<Double>] =
            if let east, let north {
                stride(from: 0, to: posterior.samples.count, by: max(posterior.samples.count / 1500, 1)).map {
                    SIMD2(posterior.samples[$0][east], posterior.samples[$0][north])
                }
            } else { [] }
        let observers = result.arrivals.map { SIMD2($0.east, $0.north) }
        let median = result.place ?? .zero
        let r50 = posterior.placeRadius(holding: 0.5)
        let r90 = posterior.placeRadius(holding: 0.9)
        Canvas { context, size in
            var low = observers.reduce(median - r90, simd_min)
            var high = observers.reduce(median + r90, simd_max)
            low = simd_min(low, .zero)
            high = simd_max(high, .zero)
            let span = max(high.x - low.x, high.y - low.y, 1) * 1.1
            let centre = (low + high) / 2
            let scale = Double(min(size.width, size.height)) / span
            func point(_ p: SIMD2<Double>) -> CGPoint {
                CGPoint(
                    x: Double(size.width) / 2 + (p.x - centre.x) * scale,
                    y: Double(size.height) / 2 - (p.y - centre.y) * scale)
            }
            for sample in samples {
                let p = point(sample)
                context.fill(
                    Path(CGRect(x: p.x - 0.75, y: p.y - 0.75, width: 1.5, height: 1.5)),
                    with: .color(.orange.opacity(0.35)))
            }
            for (radius, opacity) in [(r90, 0.6), (r50, 1.0)] {
                let c = point(median)
                let r = radius * scale
                context.stroke(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(.red.opacity(opacity)), lineWidth: 1.5)
            }
            for observer in observers {
                let p = point(observer)
                context.fill(
                    Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)),
                    with: .color(.accentColor))
            }
            let origin = point(.zero)
            var cross = Path()
            cross.move(to: CGPoint(x: origin.x - 5, y: origin.y))
            cross.addLine(to: CGPoint(x: origin.x + 5, y: origin.y))
            cross.move(to: CGPoint(x: origin.x, y: origin.y - 5))
            cross.addLine(to: CGPoint(x: origin.x, y: origin.y + 5))
            context.stroke(cross, with: .color(.primary), lineWidth: 1)
            context.draw(
                Text(String(format: "%.0f m across, north up", span)).font(.caption2),
                at: CGPoint(x: 6, y: size.height - 6), anchor: .bottomLeading)
            // The place close up, top right, where its region is too small to see at the plan's scale.
            if r90 * scale < 12 {
                let side = min(Double(size.height) * 0.45, 130)
                let inset = CGRect(x: Double(size.width) - side - 6, y: 6, width: side, height: side)
                context.fill(
                    Path(roundedRect: inset, cornerRadius: 4),
                    with: .color(Color(nsColor: .windowBackgroundColor)))
                context.stroke(
                    Path(roundedRect: inset, cornerRadius: 4), with: .color(.secondary), lineWidth: 0.5)
                let across = max(3 * r90, 1)
                let zoom = side / across
                func close(_ p: SIMD2<Double>) -> CGPoint {
                    CGPoint(x: inset.midX + (p.x - median.x) * zoom, y: inset.midY - (p.y - median.y) * zoom)
                }
                var clipped = context
                clipped.clip(to: Path(inset))
                for sample in samples {
                    let p = close(sample)
                    clipped.fill(
                        Path(CGRect(x: p.x - 0.75, y: p.y - 0.75, width: 1.5, height: 1.5)),
                        with: .color(.orange.opacity(0.35)))
                }
                for (radius, opacity) in [(r90, 0.6), (r50, 1.0)] {
                    let c = close(median)
                    let r = radius * zoom
                    clipped.stroke(
                        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                        with: .color(.red.opacity(opacity)), lineWidth: 1.5)
                }
                clipped.draw(
                    Text(String(format: "%.0f m across", across)).font(.caption2),
                    at: CGPoint(x: inset.minX + 4, y: inset.maxY - 3), anchor: .bottomLeading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement()
        .accessibilityLabel(
            String(
                format:
                    "Plan: %d observers, the reference point, and the place's samples, half within %.0f m and 90%% within %.0f m of the median",
                observers.count, r50, r90))
    }
}
