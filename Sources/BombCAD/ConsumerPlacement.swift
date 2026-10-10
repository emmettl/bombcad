import BlastCore
import CryptoKit
import Foundation
import simd

/// What the models fed by a run cost a frame on each Mac, and what the run itself takes a frame,
/// as runs and probes have measured them for one set of inputs (see `ConsumerPlacement`).
struct ConsumerCosts: Codable, Sendable, Equatable {
    /// One model's cost.
    struct Model: Codable, Sendable, Equatable {
        /// What the model was given to start, as a digest, so that a cost is used only for the
        /// same work.
        var spec: String
        /// Its seconds a frame on each Mac it has been measured on: "local" for this one, or a
        /// host.
        var seconds: [String: Double] = [:]
        /// Whether it uses this Mac's GPU when here, which the blast's solver shares.
        var usesGPU = false
    }

    /// The blast's own seconds a frame: the run's, less any time spent waiting for models and
    /// any models' time on its GPU; nil until a run has measured it.
    var frameSeconds: Double?
    /// The largest fireball's equivalent radius, in metres, in the last run that reckoned its
    /// radiation, for the probe to march through one as large.
    var fireballRadius: Float?
    /// By the model's name, as `--consumer` names it: fragments, thermal or ground.
    var models: [String: Model] = [:]

    /// The digest of `kind` that a cost is kept under.
    static func spec(_ kind: ConsumerKind) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(kind)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `seconds` a frame for the model `name` doing `kind`'s work at `place`, measured now. A
    /// cost measured for other work is dropped. Here the dearer of the two measurements is kept,
    /// since a probe here does not share the GPU with the blast as the run does; elsewhere the
    /// newer stands, since another Mac's load comes and goes.
    mutating func measured(
        _ name: String, kind: ConsumerKind, place: String, seconds: Double, usesGPU: Bool? = nil
    ) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let spec = Self.spec(kind)
        var model = models[name].flatMap { $0.spec == spec ? $0 : nil } ?? Model(spec: spec)
        model.seconds[place] = place == "local" ? max(model.seconds[place] ?? 0, seconds) : seconds
        if let usesGPU { model.usesGPU = usesGPU }
        models[name] = model
    }

    /// The model's seconds a frame at `place`, if measured for `kind`'s work.
    func seconds(_ name: String, kind: ConsumerKind, place: String) -> Double? {
        guard let model = models[name], model.spec == Self.spec(kind) else { return nil }
        return model.seconds[place]
    }
}

/// Where each model fed by a run goes, by what it costs. A model on another Mac costs the run
/// nothing while that Mac keeps up, and holds the run back by however much it falls behind; one
/// here costs the run its time if it shares the GPU with the blast, and nothing if it runs on
/// the CPU's otherwise idle cores, unless it is slower than the run. Models on the same Mac add
/// up. The plan is the placement whose slowest part is quickest, keeping models here unless
/// moving them is estimated to save at least 3% of the run.
enum ConsumerPlacement {
    /// The run's estimated seconds a frame with each model `places` puts it, `kinds` saying what
    /// each does; a model never measured somewhere counts as free there.
    static func frameSeconds(
        _ places: [String: String], kinds: [String: ConsumerKind], costs: ConsumerCosts
    ) -> Double {
        var here = costs.frameSeconds ?? 0
        var slowest = 0.0
        var loads: [String: Double] = [:]
        for (name, place) in places {
            guard let kind = kinds[name] else { continue }
            let seconds = costs.seconds(name, kind: kind, place: place) ?? 0
            if place == "local" {
                if costs.models[name]?.usesGPU == true { here += seconds }
                slowest = max(slowest, seconds)
            } else {
                loads[place, default: 0] += seconds
            }
        }
        return max(here, slowest, loads.values.max() ?? 0)
    }

    /// Where to place each model: `choices` gives each its possible places ("local" or a host),
    /// one for a model already placed. Only places where a model's cost is known are considered
    /// for it, besides this Mac. The same costs always give the same plan.
    static func plan(
        _ choices: [String: [String]], kinds: [String: ConsumerKind], costs: ConsumerCosts
    ) -> (places: [String: String], frameSeconds: Double) {
        let names = choices.keys.sorted()
        let options = names.map { name in
            let places = choices[name] ?? ["local"]
            guard places.count > 1, let kind = kinds[name] else { return places }
            return places.filter { $0 == "local" || costs.seconds(name, kind: kind, place: $0) != nil }
                .sorted { ($0 == "local" ? 0 : 1, $0) < ($1 == "local" ? 0 : 1, $1) }
        }
        var plans: [(places: [String: String], seconds: Double, away: Int)] = []
        func search(_ index: Int, _ places: [String: String]) {
            guard index < names.count else {
                plans.append(
                    (
                        places, frameSeconds(places, kinds: kinds, costs: costs),
                        places.values.filter { $0 != "local" }.count
                    ))
                return
            }
            for place in options[index] {
                var next = places
                next[names[index]] = place
                search(index + 1, next)
            }
        }
        search(0, [:])
        let best = plans.map(\.seconds).min() ?? 0
        let margin = max(0.001, 0.03 * best)
        // Within the margin, fewest models away, then quickest; plans come in a fixed order.
        let chosen = plans.filter { $0.seconds <= best + margin }
            .min { ($0.away, $0.seconds) < ($1.away, $1.seconds) }!
        return (chosen.places, chosen.seconds)
    }
}

/// The costs measured for each set of inputs, kept between runs in a file: the last 64 sets.
struct ConsumerCostStore: Sendable {
    let url: URL

    /// In the user's caches, shared by the app and `BombCAD run`.
    static var standard: ConsumerCostStore {
        ConsumerCostStore(
            url: URL.cachesDirectory.appending(path: "BombCAD/consumer-costs.json"))
    }

    private struct Entry: Codable {
        var costs: ConsumerCosts
        var date: Date
    }

    private func entries() -> [String: Entry] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    /// The key for a run's inputs, fed every `frameInterval` seconds.
    static func key(_ inputs: SimulationInputs, frameInterval: Double) -> String? {
        (try? SavedSimulationRun.fingerprint(inputs.scenario, settings: inputs.settings))
            .map { $0 + String(format: "/%.4f", frameInterval) }
    }

    func costs(for key: String) -> ConsumerCosts? { entries()[key]?.costs }

    func record(_ costs: ConsumerCosts, for key: String) {
        var entries = entries()
        entries[key] = Entry(costs: costs, date: .now)
        if entries.count > 64 {
            for old in entries.sorted(by: { $0.value.date < $1.value.date }).prefix(entries.count - 64) {
                entries[old.key] = nil
            }
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// A short measurement of a model's cost on a Mac before a run: a few frames like the run's
/// largest, through a session of the model's own kind there. Only the thermal radiation is
/// probed: its march costs about the same each frame, set by its receivers and the fireball's
/// size, while the fragments' and the ground's cost is small and follows the run.
enum ConsumerProbe {
    /// Frames the probe sends: the first, which sets things up, is not timed.
    static let frames = 4

    /// A fireball of `radius` metres, half a sphere on the ground under the charge, at 2,000 K,
    /// in cells of the grid's size merged as `LuminousCells` merges them; `frames` of them.
    static func fireballs(scenario: Scenario, cellSize: Float, radius: Float) -> [FireballFrame] {
        let radius = max(radius, cellSize)
        var size = cellSize
        func counts(_ size: Float) -> SIMD3<Int32> {
            SIMD3(
                Int32((2 * radius / size).rounded(.up)) + 1, Int32((2 * radius / size).rounded(.up)) + 1,
                Int32((radius / size).rounded(.up)) + 1)
        }
        while Int(counts(size).x) * Int(counts(size).y) * Int(counts(size).z) > LuminousCells.maximumVoxels {
            size *= 2
        }
        let n = counts(size)
        let centre = SIMD3(scenario.charge.position.x, scenario.charge.position.y, 0)
        let first = SIMD3<Int32>(((SIMD3(centre.x - radius, centre.y - radius, 0)) / size).rounded(.down))
        var fills: [UInt8] = []
        var temperatures: [UInt16] = []
        fills.reserveCapacity(Int(n.x * n.y * n.z))
        temperatures.reserveCapacity(fills.capacity)
        var inside = 0
        for k in 0..<n.z {
            for j in 0..<n.y {
                for i in 0..<n.x {
                    let point = (SIMD3<Float>(first &+ SIMD3(i, j, k)) + 0.5) * size
                    let hot = simd_distance(point, centre) <= radius
                    inside += hot ? 1 : 0
                    fills.append(hot ? 255 : 0)
                    temperatures.append(hot ? 2000 : 0)
                }
            }
        }
        let cells = LuminousCells(
            voxelSize: size, first: first, counts: n, fills: fills, temperatures: temperatures, products: nil)
        return (0..<frames).map { index in
            FireballFrame(
                time: 0.001 * Double(index + 1), volume: Double(inside) * pow(Double(size), 3),
                centre: centre + SIMD3(0, 0, radius / 2), temperature: 2000, hottest: 2000, cells: cells)
        }
    }

    /// The largest fireball's radius to probe with: the last run's, or else one scaled from the
    /// street canyon's 7.3 m for 100 kg with afterburning by the cube root of the charge.
    static func radius(scenario: Scenario, costs: ConsumerCosts) -> Float {
        costs.fireballRadius ?? 7.3 * cbrt(max(scenario.charge.mass, 0.001) / 100)
    }

    /// `consumer`'s seconds a frame over `frames` after the first, and whether it used this Mac's
    /// GPU; nil if it has not answered within `timeout`.
    @MainActor
    static func measure(
        _ consumer: any FrameConsumer, frames: [FireballFrame], timeout: Duration = .seconds(30)
    ) async -> (seconds: Double, usesGPU: Bool)? {
        let deadline = ContinuousClock.now + timeout
        func reached(_ frame: Int) async -> Bool {
            while consumer.report.frame < frame {
                guard ContinuousClock.now < deadline else { return false }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return true
        }
        guard let first = frames.first else { return nil }
        consumer.send(.fireball(first))
        guard await reached(0) else { return nil }
        let start = consumer.seconds
        for frame in frames.dropFirst() { consumer.send(.fireball(frame)) }
        guard frames.count > 1, await reached(frames.count - 1) else { return nil }
        let gpu = (consumer as? LocalFrameConsumer)?.gpuSeconds ?? 0
        return ((consumer.seconds - start) / Double(frames.count - 1), gpu > 0)
    }
}
