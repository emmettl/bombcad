import Foundation
import simd

/// A measured room described for comparison with RoomCAD: a floor plan with vertical walls, materials as
/// published third-octave absorption and scattering, and a multi-way source whose drivers sit at
/// different heights. Walls covered by several materials take their area-weighted mean.
public struct ValidationScene: Codable, Sendable {
    public var description: String
    /// Third-octave centre frequencies of the material data.
    public var frequencies: [Double]
    public var height: Double
    /// Plan corners in metres, anticlockwise, in the scene's own coordinates.
    public var corners: [[Double]]
    /// For each wall, its materials' names and the fractions of its area they cover.
    public var walls: [[String: Double]]
    public var floor: String
    public var ceiling: String
    public var temperatureCelsius: Double
    public var relativeHumidity: Double
    /// Material sets by name (such as initial estimates and estimates fitted to the measured decay).
    public var materials: [String: [String: Material]]
    public var sources: [String: Source]
    /// Crossover frequencies between the source's drivers, lowest first; one fewer than the drivers.
    public var driverCrossovers: [Double]
    /// Receiver positions in the scene's coordinates.
    public var receivers: [String: [Double]]

    public struct Material: Codable, Sendable {
        public var absorption: [Double]
        public var scattering: [Double]
    }

    public struct Source: Codable, Sendable {
        /// Position in plan.
        public var position: [Double]
        /// Each driver's height, lowest frequencies first.
        public var drivers: [Double]
    }

    public static func load(_ url: URL) throws -> ValidationScene {
        try JSONDecoder().decode(ValidationScene.self, from: Data(contentsOf: url))
    }

    /// The south-west corner of the plan's bounding box, moved to the origin in RoomCAD's coordinates.
    var origin: SIMD2<Double> {
        corners.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, SIMD2($1[0], $1[1])) }
    }

    /// A point in the scene's coordinates in RoomCAD's.
    public func position(_ point: [Double]) -> SIMD3<Double> {
        SIMD3(point[0] - origin.x, point[1] - origin.y, point[2])
    }

    /// Third-octave values averaged over each of RoomCAD's octave bands.
    func octaves(_ values: [Double]) -> [Double] {
        OctaveBands.centres.map { centre in
            let nearest = frequencies.indices.min {
                abs(log2(frequencies[$0] / centre)) < abs(log2(frequencies[$1] / centre))
            }!
            let range = max(nearest - 1, 0)...min(nearest + 1, values.count - 1)
            return range.map { values[$0] }.reduce(0, +) / Double(range.count)
        }
    }

    /// A surface covered by `mix`, from material set `set`.
    public func material(_ mix: [String: Double], set: String) -> SurfaceMaterial {
        let parts = mix.sorted { $0.key < $1.key }
        let total = parts.reduce(0) { $0 + $1.value }
        var absorption = [Double](repeating: 0, count: OctaveBands.count)
        var scattering = absorption
        for (name, share) in parts {
            let source = materials[set]![name]!
            let a = octaves(source.absorption)
            let s = octaves(source.scattering)
            for band in absorption.indices {
                absorption[band] += a[band] * share / total
                scattering[band] += s[band] * share / total
            }
        }
        let name = parts.map { "\($0.key) \(Int(($0.value / total * 100).rounded()))%" }.joined(
            separator: ", ")
        return SurfaceMaterial(
            name: name, absorption: absorption, scattering: scattering,
            reference: "\(set) estimates, third-octave values averaged over octaves.")
    }

    /// The room, with material set `set`.
    public func room(set: String) -> ShoeboxRoom {
        let planCorners = corners.map { SIMD2($0[0], $0[1]) - origin }
        let high = planCorners.reduce(planCorners[0]) { simd_max($0, $1) }
        var room = ShoeboxRoom(size: SIMD3(high.x, high.y, height), material: material([floor: 1], set: set))
        room.floor = material([floor: 1], set: set)
        room.ceiling = material([ceiling: 1], set: set)
        room.plan = FloorPlan(corners: planCorners, walls: walls.map { material($0, set: set) })
        return room
    }

    /// Settings for one driver of `source` and the named receivers, with the measurement's air.
    public func settings(
        set: String, source: String, driver: Int, receivers names: [String], duration: Double,
        lowFrequencyModel: Bool = true
    ) -> RoomResponseSettings {
        let room = room(set: set)
        let s = sources[source]!
        let atmosphere = Atmosphere(
            temperatureCelsius: temperatureCelsius, relativeHumidity: relativeHumidity,
            pressureKilopascals: 101.325)
        return RoomResponseSettings(
            room: room,
            source: RoomPoint(name: source, position: position(s.position + [s.drivers[driver]])),
            receivers: names.map { RoomPoint(name: $0, position: position(receivers[$0]!)) },
            atmosphere: atmosphere, duration: duration,
            maximumReflectionOrder: min(
                120, Int((duration * atmosphere.soundSpeed / room.size.min()).rounded(.up)) + 2),
            lowFrequencyModel: lowFrequencyModel)
    }

    /// The response of every driver of `source` at the named receivers, each kept in its own band by
    /// complementary zero-phase crossovers, summed: one channel per receiver. Also returns the lowest
    /// driver's diagnostics, which carry the wave solver's.
    public func generate(
        set: String, source: String, receivers names: [String], duration: Double,
        lowFrequencyModel: Bool = true,
        configure: (inout RoomResponseSettings) -> Void = { _ in }
    ) throws -> (channels: [[Float]], sampleRate: Int, diagnostics: RoomResponseDiagnostics) {
        let drivers = sources[source]!.drivers
        var channels: [[Float]]?
        var diagnostics: RoomResponseDiagnostics?
        var sampleRate = 48_000
        for driver in drivers.indices {
            var settings = settings(
                set: set, source: source, driver: driver, receivers: names, duration: duration,
                lowFrequencyModel: lowFrequencyModel)
            configure(&settings)
            sampleRate = settings.sampleRate
            let result = try RoomResponseGenerator.generate(settings)
            if driver == 0 { diagnostics = result.diagnostics }
            let low = driver == 0 ? nil : driverCrossovers[driver - 1]
            let high = driver == drivers.count - 1 ? nil : driverCrossovers[driver]
            let filtered = result.response.channels.map { channel in
                RealFFT.zeroPhaseFilter(channel, sampleRate: Double(sampleRate)) { f in
                    (low.map { OctaveBands.rise(f, crossover: $0) } ?? 1)
                        - (high.map { OctaveBands.rise(f, crossover: $0) } ?? 0)
                }
            }
            channels = channels.map { zip($0, filtered).map { zip($0, $1).map(+) } } ?? filtered
        }
        return (channels!, sampleRate, diagnostics!)
    }
}
