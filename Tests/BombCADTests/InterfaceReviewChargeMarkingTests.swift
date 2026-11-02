import AppKit
import BlastCore
import BlastRender
import SwiftUI
import Testing
import simd

@testable import BombCAD

/// The Charge from the Damage panel (emmettl/bombcad-work#116 stage 2; docs/charge-inference.md,
/// "Marking the damage in the app") on a district the network never saw, judged and timed through
/// the app's own path: for charges of several places and yields, the quick estimate's damage marked
/// (`markFromDamage`), all of it and 3, 10 and 30 buildings of it, and the likeliest place and the
/// yield's median set against the charge; then buildings marked one at a time, each mark's weighing,
/// layout and GPU frame timed, the view and the panel captured. Only with `BOMBCAD_INTERFACE_REVIEW`
/// (the folder to write) and `BOMBCAD_CHARGE_MARKING_DISTRICT` (a folder with `district.osm`, and
/// `ground.asc` if it has terrain: `Scripts/ml/make_district.py`'s). An optimised build
/// (`swift test -c release -Xswiftc -enable-testing`) times the app's.
@MainActor
@Suite(
    "The charge from the damage, offscreen", .serialized, .hangLimit,
    .enabled(
        if: ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"] != nil
            && ProcessInfo.processInfo.environment["BOMBCAD_CHARGE_MARKING_DISTRICT"] != nil))
struct InterfaceReviewChargeMarkingTests {
    private func folder() throws -> URL {
        let output = try #require(ProcessInfo.processInfo.environment["BOMBCAD_INTERFACE_REVIEW"])
        let folder = URL(filePath: output, directoryHint: .isDirectory).appending(path: "charge-marking")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func settle(_ model: SimulationModel) async throws {
        while model.estimatingEnvelopeDamage || model.isLoadingInputs || model.lookInFlight
            || model.lookWaiting != nil || model.envelopeEstimateIsPreview
        {
            try #require(model.errorMessage == nil, "\(model.errorMessage ?? "")")
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The view as the panel has it, as the app draws it; written as `name`; its GPU time.
    @discardableResult
    private func view(_ model: SimulationModel, camera: OrbitCamera, to name: String?) throws -> Double {
        let renderer = try #require(model.renderer)
        let queue = try #require(model.commandQueue)
        var settings = model.renderSettings
        settings.showCharge = true
        settings.chargeAt = model.settings.chargePosition
        settings.thermal = nil
        settings.showsPaint = model.chargeMarking.paint != nil
        renderer.settings = settings
        renderer.setSurfacePaint(model.chargeMarking.paint)
        renderer.setLines(model.chargeMarking.lines)
        renderer.pixelsPerPoint = 2
        let frame = try #require(
            renderer.snapshot(commandQueue: queue, width: 1800, height: 1200, camera: camera))
        if let name {
            let rep = NSBitmapImageRep(cgImage: frame.image)
            try #require(rep.representation(using: .png, properties: [:])).write(
                to: try folder().appending(path: "\(name).png"))
        }
        return frame.gpuSeconds
    }

    private func panel(_ model: SimulationModel, _ name: String) throws {
        for (style, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try InterfaceSnapshotTests().snapshot(
                ChargeMarkingView(model: model, marking: model.chargeMarking).frame(width: 300),
                size: CGSize(width: 300, height: 1100), appearance: appearance,
                to: try folder().appending(path: "panel-\(name)-\(style).png"))
        }
    }

    static func quantile(_ v: [Double], _ q: Double) -> Double {
        let s = v.sorted()
        return s.isEmpty ? .nan : s[min(Int(q * Double(s.count)), s.count - 1)]
    }

    @Test("Read back charges on a district it never saw, and time each mark")
    func district() async throws {
        let source = URL(
            filePath: try #require(ProcessInfo.processInfo.environment["BOMBCAD_CHARGE_MARKING_DISTRICT"]),
            directoryHint: .isDirectory)
        let district = NewDistrictModel()
        try district.readMap(source.appending(path: "district.osm"))
        if FileManager.default.fileExists(atPath: source.appending(path: "ground.asc").path()) {
            try district.readTerrain(source.appending(path: "ground.asc"))
            district.terrainIsSurface = false
        }
        district.yieldValue = 1
        district.yieldUnit = .tonnes
        district.radius = 600
        district.nearAndFar = false
        district.memory = 8 << 30
        await district.lay()
        let preview = try #require(district.preview, "\(district.message ?? "")")
        let model = SimulationModel(document: preview.document)
        model.refinesCloseCalls = false
        try await settle(model)
        let centre = model.settings.chargePosition
        let middle = SIMD2(Double(centre.x), Double(centre.y))
        let terrain = model.settings.scenario.terrain
        print(
            "\(model.settings.scenario.envelopeObjects.count) envelope buildings, the search about the middle"
        )
        model.showsChargeMarking = true
        let marking = model.chargeMarking
        await marking.open(model)
        let network = try #require(marking.marking?.network)

        // Charges drawn over the disc's inner 350 m and from 200 kg to 1 kt, the search about the
        // district's middle; marked from the quick estimate's damage there.
        var random = ChargeFromDamage.SplitMix(seed: 116)
        var rows: [String] = []
        var offs: [Int: [Double]] = [:]
        var factors: [Int: [Double]] = [:]
        var estimates: [Double] = []
        for k in 0..<12 {
            let angle = 2 * Double.pi * random.uniform()
            let r = 350 * random.uniform().squareRoot()
            let place = middle + r * SIMD2(cos(angle), sin(angle))
            let mass = exp(log(200.0) + random.uniform() * (log(1e6) - log(200.0)))
            var charge = SIMD3(Float(place.x), Float(place.y), 0)
            charge.z = (terrain?.height(at: charge) ?? 0) + 1
            model.settings.chargePosition = charge
            model.settings.chargeMass = Float(mass)
            let clock = ContinuousClock.now
            model.quickEstimate()
            try await settle(model)
            estimates.append(clock.duration(to: .now) / .seconds(1))
            await marking.search(about: middle, model)
            await marking.markFromDamage(model)
            let all = try #require(marking.marking)
            let truth = SIMD2(Double(charge.x), Double(charge.y))
            // All marks, then 3, 10 and 30 of them in an order of their own.
            let order = all.order.map { ($0, random.next()) }.sorted { $0.1 < $1.1 }.map(\.0)
            var line = String(
                format: "charge %2d: %4.0f m from the middle, %@", k, r,
                ChargeFromDamage.Posterior.mass(mass) as NSString)
            for count in [3, 10, 30, order.count] where count <= order.count {
                var some = ChargeFromDamage.Marking(network: network, reference: middle)
                some.replaceAll(order.prefix(count).compactMap { id in all.marks[id].map { (id, $0) } })
                guard let p = some.posterior else { continue }
                let off = simd_distance(p.mostProbablePlace, truth)
                let factor = exp(abs(log(p.yieldQuantile(0.5) / mass)))
                let key = count == order.count ? -1 : count
                offs[key, default: []].append(off)
                factors[key, default: []].append(factor)
                line += String(
                    format: "; %d marks: %.0f m off, ×%.2f (90%% %@–%@)", count, off, factor,
                    ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.05)) as NSString,
                    ChargeFromDamage.Posterior.mass(p.yieldQuantile(0.95)) as NSString)
            }
            print(line)
            rows.append(line)
            if k == 0 {
                try view(
                    model,
                    camera: OrbitCamera(
                        target: SIMD3(centre.x, centre.y, 0), distance: 1500, azimuth: -1.9, elevation: 1.1),
                    to: "all-marks")
                try panel(model, "all-marks")
            }
        }
        for key in [3, 10, 30, -1] {
            guard let o = offs[key], let f = factors[key] else { continue }
            let summary = String(
                format:
                    "%@ marks: likeliest place off the charge %.0f m (median), %.0f m (90th); yield off by ×%.2f (median), ×%.2f (90th); %d charges",
                (key < 0 ? "all" : String(key)) as NSString, Self.quantile(o, 0.5), Self.quantile(o, 0.9),
                Self.quantile(f, 0.5), Self.quantile(f, 0.9), o.count)
            print(summary)
            rows.append(summary)
        }
        rows.append(String(format: "Quick estimates: %.1f s median", Self.quantile(estimates, 0.5)))

        // One at a time, as a user clicks: the last charge's damage, nearest the middle first.
        let damaged = try #require(marking.marking)
        let ids = damaged.order.sorted {
            let a = damaged.marks[$0]!.building
            let b = damaged.marks[$1]!.building
            return simd_distance(SIMD2(a.east, a.north), middle)
                < simd_distance(SIMD2(b.east, b.north), middle)
        }
        marking.clearAll(model)
        let camera = OrbitCamera(
            target: SIMD3(centre.x, centre.y, 0), distance: 1500, azimuth: -1.9, elevation: 1.1)
        var weigh: [Double] = []
        var layout: [Double] = []
        var gpu: [Double] = []
        var whole: [Double] = []
        for (n, id) in ids.prefix(60).enumerated() {
            let clock = ContinuousClock.now
            marking.set(damaged.marks[id], for: id, model)
            let shown = try view(
                model, camera: camera, to: [1, 3, 10, 30].contains(n + 1) ? "marks-\(n + 1)" : nil)
            whole.append(clock.duration(to: .now) / .seconds(1))
            weigh.append(marking.weighSeconds)
            layout.append(marking.drawSeconds)
            gpu.append(shown)
            if [3, 30].contains(n + 1) { try panel(model, "marks-\(n + 1)") }
        }
        let timing = String(
            format:
                "%d marks one at a time: weighed %.2f ms median (%.2f at most), laid out %.2f ms (%.2f), GPU frame at 1800 × 1200 %.1f ms (%.1f), mark to frame drawn %.1f ms (%.1f)",
            weigh.count, 1000 * Self.quantile(weigh, 0.5), 1000 * (weigh.max() ?? 0),
            1000 * Self.quantile(layout, 0.5), 1000 * (layout.max() ?? 0), 1000 * Self.quantile(gpu, 0.5),
            1000 * (gpu.max() ?? 0), 1000 * Self.quantile(whole, 0.5), 1000 * (whole.max() ?? 0))
        print(timing)
        rows.append(timing)
        try (rows.joined(separator: "\n") + "\n").write(
            to: try folder().appending(path: "judged.txt"), atomically: true, encoding: .utf8)
        #expect(Self.quantile(whole, 0.5) < 1.0 / 30)
    }
}
