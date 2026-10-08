import Foundation
import simd

/// A measured room described for comparison with RoomCAD: a floor plan with vertical walls, materials as
/// published third-octave absorption and scattering, and a multi-way source whose drivers sit at
/// different heights. Walls covered by several materials take their area-weighted mean.
public struct ValidationScene: Codable, Sendable {
    public var description: String
    /// Third-octave centre frequencies of the material data.
    public var frequencies: [Double]
    public var height: Double?
    /// Plan corners in metres, anticlockwise, in the scene's own coordinates.
    public var corners: [[Double]]?
    /// For each wall, its materials' names and the fractions of its area they cover.
    public var walls: [[String: Double]]?
    public var floor: String?
    public var ceiling: String?
    /// For a room of any shape, in place of the plan: the air built from pieces.
    public var geometry: Geometry?
    public var temperatureCelsius: Double
    public var relativeHumidity: Double
    /// Material sets by name (such as initial estimates and estimates fitted to the measured decay).
    public var materials: [String: [String: Material]]
    public var sources: [String: Source]
    /// Crossover frequencies between the source's drivers, lowest first; one fewer than the drivers.
    public var driverCrossovers: [Double]
    /// Receiver positions in the scene's coordinates.
    public var receivers: [String: [Double]]
    /// Zones of objects the geometry leaves out, such as chairs; see `FittingZone`.
    public var fittings: [Fitting]?

    /// A box of objects in the scene's coordinates: `count` objects of surface area `area` each, which
    /// lose `absorption` (per octave band, none if absent) of the energy at each encounter.
    public struct Fitting: Codable, Sendable {
        public var name: String
        public var box: [[Double]]
        public var count: Double
        public var area: Double
        public var absorption: [Double]?
        public var reference: String?
    }

    public struct Material: Codable, Sendable {
        public var absorption: [Double]
        public var scattering: [Double]
    }

    /// The room's air as boxes and extrusions joined or cut away in order, the first joined to nothing.
    /// Material names are the scene's, or "open" for an opening to the air outside.
    public struct Geometry: Codable, Sendable {
        public var pieces: [Piece]

        public struct Piece: Codable, Sendable {
            /// "union" or "subtract".
            public var operation: String
            public var name: String?
            /// Two corners, and six materials in the order -x, +x, -y, +y, -z, +z.
            public var box: [[Double]]?
            public var materials: [String]?
            public var extrusion: Extrusion?
        }

        /// A polygon extruded along an axis; see `Solid.extrusion`.
        public struct Extrusion: Codable, Sendable {
            public var points: [[Double]]
            public var axis: Int
            public var from: Double
            public var to: Double
            public var sides: [String]
            public var ends: [String]
        }
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

    /// The corner of the room's bounding box that becomes RoomCAD's origin: the plan's south-west corner
    /// at floor level, or the low corner of a mesh's bounds.
    var origin: SIMD3<Double> {
        if geometry != nil, let mesh = try? sceneMesh(set: materials.keys.sorted()[0]) {
            return mesh.bounds.min
        }
        let corners = self.corners ?? []
        let low = corners.reduce(SIMD2(Double.infinity, .infinity)) { simd_min($0, SIMD2($1[0], $1[1])) }
        return SIMD3(low.x, low.y, 0)
    }

    /// A point in the scene's coordinates in RoomCAD's.
    public func position(_ point: [Double]) -> SIMD3<Double> {
        SIMD3(point[0], point[1], point[2]) - origin
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

    /// This scene with a material set `name`: set `base` with its absorption scaled, in each octave band,
    /// so that Eyring's formula for this scene's room, with its air, gives `reverberationTime`. That is how
    /// BRAS fitted its "fitted" set to its own, more detailed models; applied to a simplified room it
    /// removes the difference that the simplification makes to the room's surface area and volume, so
    /// what remains is the model's own decay. Bands without a time keep the base absorption.
    public func refitting(_ base: String, to reverberationTime: [Double?], as name: String) -> ValidationScene
    {
        let room = room(set: base)
        let atmosphere = Atmosphere(
            temperatureCelsius: temperatureCelsius, relativeHumidity: relativeHumidity,
            pressureKilopascals: 101.325)
        let c = atmosphere.soundSpeed
        let volume = room.volume
        let surface = room.surfaceArea
        let factors = OctaveBands.centres.indices.map { band -> Double in
            guard let t = reverberationTime[band], t > 0 else { return 1 }
            let air = 2 * atmosphere.amplitudeAttenuationPerMetre(frequency: OctaveBands.centres[band])
            let fitted = room.zones.reduce(0) { $0 + $1.absorptionArea[band] }
            let needed = 1 - exp(-(24 * log(10) * volume / (c * t) - 4 * air * volume - fitted) / surface)
            let present = room.boundaries.reduce(0) { $0 + $1.area * $1.material.absorption[band] } / surface
            return present > 0 ? max(needed, 0) / present : 1
        }
        var scene = self
        scene.materials[name] = materials[base]!.mapValues { material in
            var scaled = material
            scaled.absorption = frequencies.enumerated().map { index, f in
                let band = OctaveBands.centres.indices.min {
                    abs(log2(OctaveBands.centres[$0] / f)) < abs(log2(OctaveBands.centres[$1] / f))
                }!
                return min(material.absorption[index] * factors[band], 0.99)
            }
            return scaled
        }
        return scene
    }

    /// The names of a set's materials, in the order a mesh refers to them.
    func materialNames(set: String) -> [String] { materials[set]!.keys.sorted() }

    /// The room's mesh built from `geometry`, in the scene's coordinates.
    func sceneMesh(set: String) throws -> RoomMesh {
        guard let geometry else { throw AcousticError.invalid("The scene has no geometry.") }
        let names = materialNames(set: set)
        let open = names.count
        func index(_ name: String) throws -> Int {
            if name == "open" { return open }
            guard let found = names.firstIndex(of: name) else {
                throw AcousticError.invalid("The scene has no material called \(name).")
            }
            return found
        }
        var solid: Solid?
        for piece in geometry.pieces {
            let part: Solid
            if let box = piece.box, let materials = piece.materials {
                part = .box(
                    SIMD3(box[0][0], box[0][1], box[0][2]), SIMD3(box[1][0], box[1][1], box[1][2]),
                    materials: try materials.map(index))
            } else if let e = piece.extrusion {
                part = .extrusion(
                    e.points.map { SIMD2($0[0], $0[1]) }, along: e.axis, from: e.from, to: e.to,
                    sides: try e.sides.map(index), ends: (try index(e.ends[0]), try index(e.ends[1])))
            } else {
                throw AcousticError.invalid(
                    "A piece of the scene's geometry is neither a box nor an extrusion.")
            }
            if let current = solid {
                solid = piece.operation == "subtract" ? current.subtracting(part) : current.union(part)
            } else {
                solid = part
            }
        }
        guard let solid else { throw AcousticError.invalid("The scene's geometry has no pieces.") }
        var mesh = solid.room(materials: names.map { material([$0: 1], set: set) })
        for face in mesh.faces.indices where mesh.faces[face].material == open {
            mesh.faces[face].open = true
            mesh.faces[face].material = 0
        }
        return mesh
    }

    /// The room, with material set `set`.
    public func room(set: String) -> ShoeboxRoom {
        if geometry != nil, let mesh = try? sceneMesh(set: set) {
            var room = ShoeboxRoom(size: [1, 1, 1], material: .rigid)
            room.mesh = mesh
            room = room.fittingMesh()
            room.fittings = zones(origin: mesh.bounds.min)
            return room
        }
        let origin2 = SIMD2(origin.x, origin.y)
        let planCorners = (corners ?? []).map { SIMD2($0[0], $0[1]) - origin2 }
        let high = planCorners.reduce(planCorners[0]) { simd_max($0, $1) }
        var room = ShoeboxRoom(
            size: SIMD3(high.x, high.y, height ?? 3), material: material([(floor ?? ""): 1], set: set))
        room.floor = material([(floor ?? ""): 1], set: set)
        room.ceiling = material([(ceiling ?? ""): 1], set: set)
        room.plan = FloorPlan(corners: planCorners, walls: (walls ?? []).map { material($0, set: set) })
        room.fittings = zones(origin: origin)
        return room
    }

    /// The fitted zones in RoomCAD's coordinates, or nil for none.
    func zones(origin: SIMD3<Double>) -> [FittingZone]? {
        fittings.map { fittings in
            fittings.map { fitting in
                FittingZone.objects(
                    fitting.name,
                    low: SIMD3(fitting.box[0][0], fitting.box[0][1], fitting.box[0][2]) - origin,
                    high: SIMD3(fitting.box[1][0], fitting.box[1][1], fitting.box[1][2]) - origin,
                    count: fitting.count, area: fitting.area,
                    absorption: fitting.absorption ?? Array(repeating: 0, count: OctaveBands.count),
                    reference: fitting.reference ?? "")
            }
        }
    }

    /// A fixed identity for a named source or receiver, so that the seeds drawn from it, and so the
    /// response, are the same on every run.
    static func identifier(_ name: String) -> UUID {
        // FNV-1a.
        let hash = name.utf8.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
        return UUID(
            uuidString: "00000000-0000-4000-8000-" + String(format: "%012llx", hash & 0xffff_ffff_ffff))!
    }

    /// Settings for one driver of `source` and the named receivers, with the measurement's air.
    public func settings(
        set: String, source: String, driver: Int, receivers names: [String], duration: Double,
        lowFrequencyModel: Bool = true
    ) -> RoomResponseSettings {
        let room = room(set: set)
        let origin = self.origin
        func position(_ point: [Double]) -> SIMD3<Double> { SIMD3(point[0], point[1], point[2]) - origin }
        let s = sources[source]!
        let atmosphere = Atmosphere(
            temperatureCelsius: temperatureCelsius, relativeHumidity: relativeHumidity,
            pressureKilopascals: 101.325)
        return RoomResponseSettings(
            room: room,
            source: RoomPoint(
                id: Self.identifier(source), name: source,
                position: position(s.position + [s.drivers[driver]])),
            receivers: names.map {
                RoomPoint(id: Self.identifier($0), name: $0, position: position(receivers[$0]!))
            },
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
