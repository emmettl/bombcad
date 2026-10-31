import Foundation

// The app's "Fire after the blast" layer (emmettl/bombcad-work#38, stage 3; docs/fire-spread.md): the
// fire spread over a scene's envelope buildings from the quick estimate's chances or a run's damage,
// with the seeds and wind the user sets, kept as each building's ignition times over the draws so
// that a slider over the hours colours the buildings without drawing the fire again.

extension FireSpread {
    /// What the layer is asked for: where fires start, the wind, the hours and the construction.
    public struct LayerSettings: Codable, Sendable, Equatable {
        /// Buildings picked to start a fire, by their envelope's id.
        public var picked: [UUID] = []
        /// Every building whose footprint comes within this many m of the charge, if set.
        public var nearChargeM: Double?
        /// This many buildings at random in each draw, of those whose centres lie `randomFromM` to
        /// `randomToM` m from the charge.
        public var randomCount = 0
        public var randomFromM = 0.0
        public var randomToM = 1500.0
        /// A run's surface-heating flags as seeds, by this threshold, if set and the run has them.
        public var thermal: ThermalSeeding?
        public var wind = Wind.calm
        public var hours = 12.0
        /// Every building clad so, for a contrast; nil for each as its construction says.
        public var cladding: Cladding?
        /// The use, and so the fire load, of buildings whose tags say none.
        public var untaggedUse = BuildingUse.residential

        public init() {}

        /// Whether any seed is asked for.
        public var hasSeeds: Bool {
            !picked.isEmpty || nearChargeM != nil || randomCount > 0 || thermal != nil
        }
    }

    /// Where the blast's glass and walls come from.
    public enum LayerSource: Sendable {
        /// The quick estimate's chances: each side's expected share broken, each building's chance of
        /// heavily damaged walls.
        case estimate(
            glass: [FacadeLoadSurrogate.SideGlass], structure: [FacadeLoadSurrogate.StructureChance])
        /// A run's judgement of each building.
        case run([EnvelopeBuildingDamage])
    }

    /// A run's thermal receivers and their surface heating, for its ignition flags.
    public struct ThermalFlags: Sendable {
        public var receivers: [ThermalReceiver]
        public var heating: SurfaceHeatingResult

        public init(receivers: [ThermalReceiver], heating: SurfaceHeatingResult) {
            self.receivers = receivers
            self.heating = heating
        }
    }

    /// The fire over a scene's buildings: the ensemble, and each building's ignition times.
    public struct Layer: Sendable {
        /// The buildings' envelope ids, in the ensemble's order.
        public var ids: [UUID]
        public var ensemble: Ensemble
        /// Each building's ignition times over the draws in which it caught, s, earliest first.
        public var ignitions: [[Double]]
        /// The buildings set alight at the blast in every draw, and those a draw picks among.
        public var fixedSeeds: Int
        public var randomCandidates: Int
        /// How many buildings the run's surface heating flagged, when asked for.
        public var thermalFlagged: Int?
        /// The buildings whose walls burn from outside.
        public var combustible: Int
        /// Whether these are a preview's few draws.
        public var preview: Bool
        /// How long the district and the draws took, s.
        public var seconds: Double

        public var members: Int { ensemble.members }
        public var horizonS: Double { ensemble.horizonS }

        /// Building `n`'s chance of having caught by `t` (s after the blast), or with `alight` of
        /// burning then, over the draws.
        public func chance(_ n: Int, at t: Double, alight: Bool = false) -> Double {
            let times = ignitions[n]
            guard !times.isEmpty else { return 0 }
            let caught = Self.count(times, atMost: t)
            guard alight else { return Double(caught) / Double(members) }
            let out = Self.count(times, atMost: t - ensemble.buildings[n].burnS)
            return Double(caught - out) / Double(members)
        }

        /// Every building's chance at `t`, by its id.
        public func chances(at t: Double, alight: Bool = false) -> [UUID: Double] {
            var out: [UUID: Double] = [:]
            out.reserveCapacity(ids.count)
            for n in ids.indices { out[ids[n]] = chance(n, at: t, alight: alight) }
            return out
        }

        /// The timeline's step at or before `t`.
        public func step(at t: Double) -> Ensemble.Step? {
            ensemble.timeline.last { $0.atS <= t + 1e-9 } ?? ensemble.timeline.first
        }

        /// The buildings more likely than not to have caught by `t`.
        public func likely(at t: Double) -> Int {
            ids.indices.filter { chance($0, at: t) > 0.5 }.count
        }

        /// The values in `sorted` no more than `t`.
        static func count(_ sorted: [Double], atMost t: Double) -> Int {
            var low = 0
            var high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid] <= t { low = mid + 1 } else { high = mid }
            }
            return low
        }
    }

    /// The buildings whose footprints' centres lie `from` to `to` m from `point`.
    public static func candidates(
        in buildings: [Building], from point: SIMD2<Double>, fromM: Double, toM: Double
    ) -> [Int] {
        buildings.indices.filter { k in
            let b = buildings[k]
            let c =
                b.footprint.reduce(SIMD2<Double>.zero) { $0 + $1.centre * $1.area }
                / max(b.footprintArea, 1e-9)
            let d = ((c - point) * (c - point)).sum().squareRoot()
            return d >= fromM && d < toM
        }
    }

    /// The layer for `scene`, its glass and walls from `source` and its seeds and wind from
    /// `settings`: `members` draws, `chunk` at a time, nil if `stop` says so between them, and
    /// `progress` told the draws done after each chunk.
    public static func layer(
        scene: Scenario, source: LayerSource, thermal: ThermalFlags? = nil, settings: LayerSettings,
        members: Int, preview: Bool = false, seed: UInt64 = 0, stepS: Double = 900, chunk: Int = 20,
        parameters: Parameters = Parameters(), stop: () -> Bool = { false },
        progress: (Int) -> Void = { _ in }
    ) -> Layer? {
        let clock = ContinuousClock.now
        let buildings: [Building] =
            switch source {
            case .estimate(let glass, let structure):
                Self.buildings(
                    scene: scene, glass: glass, structure: structure, untaggedUse: settings.untaggedUse,
                    cladding: settings.cladding)
            case .run(let damage):
                Self.buildings(
                    scene: scene, damage: damage, untaggedUse: settings.untaggedUse,
                    cladding: settings.cladding)
            }
        let index = Dictionary(buildings.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let charge = SIMD2(Double(scene.charge.position.x), Double(scene.charge.position.y))
        var seeds = Set(settings.picked.compactMap { index[$0] })
        if let radius = settings.nearChargeM {
            seeds.formUnion(Self.buildings(near: charge, radius: radius, in: buildings))
        }
        var flagged: Int?
        if let seeding = settings.thermal, let thermal {
            let hit = ignited(
                receivers: thermal.receivers, heating: thermal.heating, buildings: buildings, seeding: seeding
            )
            flagged = hit.count
            seeds.formUnion(hit)
        }
        var random: RandomIgnitions?
        if settings.randomCount > 0 {
            random = RandomIgnitions(
                count: settings.randomCount,
                candidates: candidates(
                    in: buildings, from: charge, fromM: settings.randomFromM, toM: settings.randomToM))
        }
        if stop() { return nil }
        let district = District(buildings: buildings, wind: settings.wind, parameters: parameters)
        let ignitions = seeds.sorted().map { Ignition(building: $0) }
        let horizonS = max(settings.hours, 0) * 3600
        guard
            let runs = draws(
                district, seeds: ignitions, random: random, horizonS: horizonS, members: members, seed: seed,
                chunk: chunk, stop: stop, progress: progress)
        else { return nil }
        let (ensemble, times) = summary(
            district, draws: runs, seeds: ignitions, random: random, horizonS: horizonS, seed: seed,
            stepS: stepS)
        let elapsed = clock.duration(to: .now)
        return Layer(
            ids: buildings.map(\.id), ensemble: ensemble, ignitions: times, fixedSeeds: seeds.count,
            randomCandidates: random?.candidates.count ?? 0, thermalFlagged: flagged,
            combustible: buildings.filter { $0.cladding == .combustible }.count, preview: preview,
            seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18)
    }
}
