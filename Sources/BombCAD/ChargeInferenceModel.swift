import BlastCore
import Foundation
import Observation
import simd

/// The Infer Charge sheet's state: the observers and survey read, the search's settings, and the
/// posterior once `ChargeInference` has sampled it off the main thread
/// (docs/charge-inference.md).
@MainActor @Observable
final class ChargeInferenceModel {
    /// The observers read, and the file they came from.
    private(set) var observers: [ChargeInferenceInputs.ObserverRow] = []
    private(set) var observersFile = ""
    /// The survey of broken glass, read only when a file is chosen; used only when `usesGlass`.
    private(set) var glassFile = ""
    private var glassURL: URL?
    var usesGlass = false
    /// The survey weighed on the scene's own buildings instead (`ChargeInference.SurrogateDamage`):
    /// each surveyed façade taken to the side of a scene building it lies on, and the side's glass
    /// judged from the façade load surrogate's load and its glazing mix, as the app judges a run's.
    /// Offered only where the scene has such sides (`offerSceneGlass`).
    var usesSceneGlass = false
    /// The scene's sides whose glass the app judges, its envelopes and its cells, where it has any.
    private(set) var sceneGlass:
        (scene: Scenario, sides: [ChargeInference.SurrogateDamage.Side], cellSize: Float)?
    /// The scene's corner (0, 0), as a map import places buildings: (longitude, latitude).
    var cornerLongitude = ""
    var cornerLatitude = ""
    /// The reference point, (longitude, latitude): the observers' centre unless set.
    var referenceLongitude = ""
    var referenceLatitude = ""
    var temperatureC = 15.0
    /// The yield searched, kilotonnes of TNT (uniform in its logarithm).
    var lowestKilotonnes = 0.001
    var highestKilotonnes = 10.0
    /// The charge is searched within this many metres of the reference point.
    var searchRadius = 500.0
    var infersOffset = false
    /// The clock offset searched, ± seconds.
    var offsetReach = 0.1
    var infersHeight = false
    /// The heights searched, metres above the ground.
    var highestBurst = 150.0
    /// Steps of the sampler, each of its walkers; the first half are discarded.
    var steps = 3000

    private(set) var isRunning = false
    private(set) var progress = 0.0
    private(set) var error: String?
    /// The last posterior, the observers' arrivals it was found from, and the settings it used.
    private(set) var result: Result?
    private var task: Task<Void, Never>?

    /// A median with its 68% (p16–p84) and 90% (p05–p95) intervals.
    struct Interval: Equatable {
        var median, p05, p16, p84, p95: Double
    }

    struct Result {
        var posterior: ChargeInference.Posterior
        var arrivals: [ChargeInference.Arrival]
        var facades: Int
        /// With the survey on the scene's buildings: the sides it was matched to and of those broken.
        var sceneSides: (seen: Int, broken: Int)?
        var projection: ChargeInferenceInputs.LocalProjection
        var settings: ChargeInference.Settings
        var seconds: Double

        /// The yield in kilotonnes of TNT: its median and its 68% and 90% intervals.
        var kilotonnes: Interval? {
            posterior.summary("log10MassKg").map {
                func kt(_ value: Double) -> Double { pow(10, value) / 1e6 }
                return Interval(
                    median: kt($0.median), p05: kt($0.p05), p16: kt($0.p16), p84: kt($0.p84), p95: kt($0.p95))
            }
        }

        /// Parameter `name`'s median and intervals, as sampled.
        func interval(_ name: String) -> Interval? {
            posterior.summary(name).map {
                Interval(median: $0.median, p05: $0.p05, p16: $0.p16, p84: $0.p84, p95: $0.p95)
            }
        }

        /// The median place, metres east and north of the reference point.
        var place: SIMD2<Double>? {
            guard let east = posterior.summary("east"), let north = posterior.summary("north") else {
                return nil
            }
            return SIMD2(east.median, north.median)
        }

        /// The median place's longitude and latitude.
        var placeLonLat: SIMD2<Double>? { place.map(projection.lonLat) }
    }

    init() {}

    /// Reads observers from `url`; the reference point becomes their centre.
    func loadObservers(_ url: URL) {
        do {
            let rows = try ChargeInferenceInputs.readObservers(url)
            guard !rows.isEmpty else {
                throw ChargeInferenceInputs.ReadError(
                    "No observers with arrival times in \(url.lastPathComponent).")
            }
            setObservers(rows, file: url.lastPathComponent)
        } catch { self.error = error.localizedDescription }
    }

    func setObservers(_ rows: [ChargeInferenceInputs.ObserverRow], file: String) {
        observers = rows
        observersFile = file
        let centre = rows.reduce(SIMD2<Double>.zero) { $0 + $1.lonLat } / Double(max(rows.count, 1))
        referenceLongitude = String(format: "%.6f", centre.x)
        referenceLatitude = String(format: "%.6f", centre.y)
        result = nil
        error = nil
    }

    /// Takes a survey of broken glass from `url` (GEER's shapefile, its .dbf beside it, or a CSV),
    /// read when the inference runs.
    func chooseGlass(_ url: URL) {
        glassURL = url
        glassFile = url.lastPathComponent
    }

    /// Offers the survey on `scene`'s own buildings where it has sides whose glass the app judges on
    /// cells `cellSize` across; otherwise withdraws it.
    func offerSceneGlass(scene: Scenario, cellSize: Float) async {
        let sides = await Task.detached(priority: .userInitiated) {
            ChargeInference.SurrogateDamage.judgedSides(scene: scene, cellSize: cellSize)
        }.value
        sceneGlass = sides.isEmpty ? nil : (scene, sides, cellSize)
        if sceneGlass == nil { usesSceneGlass = false }
    }

    var corner: SIMD2<Double>? {
        guard let lon = Double(cornerLongitude), let lat = Double(cornerLatitude), abs(lat) < 90,
            abs(lon) <= 180
        else { return nil }
        return SIMD2(lon, lat)
    }

    /// Whether the survey is weighed on the scene's buildings.
    var weighsSceneGlass: Bool { usesGlass && usesSceneGlass && sceneGlass != nil }

    var reference: SIMD2<Double>? {
        guard let lon = Double(referenceLongitude), let lat = Double(referenceLatitude),
            abs(lat) < 90, abs(lon) <= 180
        else { return nil }
        return SIMD2(lon, lat)
    }

    /// Why the inference cannot start, if it cannot.
    var notReady: String? {
        if observers.count < 3 { return "Load at least three observers' arrivals." }
        if reference == nil { return "Give the reference point's longitude and latitude." }
        if !(lowestKilotonnes > 0 && lowestKilotonnes < highestKilotonnes) {
            return "The yield searched must run from above zero to a larger yield."
        }
        if !(searchRadius > 0) { return "The search radius must be above zero." }
        if usesGlass && glassURL == nil { return "Choose a survey of broken glass, or leave the glass out." }
        if weighsSceneGlass && corner == nil {
            return
                "Give the longitude and latitude of the scene's corner, to put the survey on its buildings."
        }
        return nil
    }

    var settings: ChargeInference.Settings {
        var settings = ChargeInference.Settings()
        settings.temperatureC = temperatureC
        settings.massRange = (lowestKilotonnes * 1e6)...(highestKilotonnes * 1e6)
        settings.placeRadius = searchRadius
        settings.offsetRange = infersOffset ? (-offsetReach)...offsetReach : nil
        settings.heightRange = infersHeight ? 0...highestBurst : nil
        settings.steps = steps
        return settings
    }

    /// Samples the posterior off the main thread, telling `progress` as it goes.
    func run() {
        guard notReady == nil, let reference, !isRunning else { return }
        let projection = ChargeInferenceInputs.LocalProjection(centre: reference)
        let arrivals = observers.map { row in
            let place = projection.metres(row.lonLat)
            return ChargeInference.Arrival(
                name: row.name, east: place.x, north: place.y, earliest: row.earliest, latest: row.latest)
        }
        let glass = usesGlass ? glassURL : nil
        let onScene = weighsSceneGlass ? sceneGlass.flatMap { found in corner.map { (found, $0) } } : nil
        let radius = searchRadius
        let settings = settings
        isRunning = true
        progress = 0
        error = nil
        let (stream, continuation) = AsyncStream.makeStream(
            of: Double.self, bufferingPolicy: .bufferingNewest(1))
        let work = Task.detached(priority: .userInitiated) {
            () throws -> (ChargeInference.Posterior, Int, (seen: Int, broken: Int)?, Double) in
            defer { continuation.finish() }
            var facades =
                try glass.map { try ChargeInferenceInputs.readFacades($0, projection: projection) } ?? []
            let started = ContinuousClock.now
            var damage: ChargeInference.SurrogateDamage?
            var sceneSides: (seen: Int, broken: Int)?
            if let ((scene, sides, cellSize), corner) = onScene {
                (damage, sceneSides) = try Self.sceneDamage(
                    facades: facades, projection: projection, scene: scene, sides: sides, cellSize: cellSize,
                    corner: corner, radius: radius)
                facades = []
            }
            let posterior = ChargeInference.infer(
                arrivals: arrivals, facades: facades, damage: damage, settings: settings
            ) {
                continuation.yield($0)
                return !Task.isCancelled
            }
            let took = ContinuousClock.now - started
            return (
                posterior, sceneSides.map(\.seen) ?? facades.count, sceneSides,
                Double(took.components.seconds) + Double(took.components.attoseconds) * 1e-18
            )
        }
        task = Task {
            await withTaskCancellationHandler {
                for await share in stream { progress = share }
                do {
                    let (posterior, facades, sceneSides, seconds) = try await work.value
                    if !posterior.samples.isEmpty {
                        result = Result(
                            posterior: posterior, arrivals: arrivals, facades: facades,
                            sceneSides: sceneSides,
                            projection: projection,
                            settings: settings, seconds: seconds)
                    }
                } catch { self.error = error.localizedDescription }
                isRunning = false
            } onCancel: {
                work.cancel()
            }
        }
    }

    /// The survey's façades put on the scene's judged sides, and the evidence they give: the scene
    /// placed by its corner, the inference's reference point in it, its places searched within
    /// `radius` metres on a grid no finer than 20 m.
    nonisolated static func sceneDamage(
        facades: [ChargeInference.Facade], projection: ChargeInferenceInputs.LocalProjection, scene: Scenario,
        sides: [ChargeInference.SurrogateDamage.Side], cellSize: Float, corner: SIMD2<Double>, radius: Double
    ) throws -> (ChargeInference.SurrogateDamage, (seen: Int, broken: Int)) {
        let placement = MapBuildingPlacement(origin: corner, resolution: 1)
        let onScene = facades.map { facade in
            var moved = facade
            let place = placement.position(projection.lonLat(SIMD2(facade.east, facade.north)))
            moved.east = place.x
            moved.north = place.y
            return moved
        }
        let observed = ChargeInference.SurrogateDamage.observed(facades: onScene, sides: sides, scene: scene)
        guard !observed.isEmpty else {
            throw ChargeInferenceInputs.ReadError(
                "No surveyed façade lies on a side of the scene's buildings: check the scene's corner.")
        }
        let reference = placement.position(projection.centre)
        let damage = ChargeInference.SurrogateDamage(
            scene: scene, observed: observed, reference: SIMD2(Float(reference.x), Float(reference.y)),
            placeRadius: radius, spacing: max(20, radius / 15), cellSize: cellSize)
        return (damage, (observed.count, observed.filter(\.damaged).count))
    }

    func cancel() {
        task?.cancel()
    }

    /// Where the median charge lies in a scene whose corner (0, 0) is at `corner` (longitude,
    /// latitude), and its mass: as a map import places buildings (`MapBuildingPlacement`).
    func scenePlacement(corner: SIMD2<Double>) -> (position: SIMD3<Float>, massKg: Float)? {
        guard let result, let lonLat = result.placeLonLat,
            let mass = result.posterior.summary("log10MassKg").map({ pow(10, $0.median) })
        else { return nil }
        let place = MapBuildingPlacement(origin: corner, resolution: 1).position(lonLat)
        let height = result.posterior.summary("height")?.median ?? 0
        return (SIMD3(Float(place.x), Float(place.y), Float(height)), Float(mass))
    }
}
