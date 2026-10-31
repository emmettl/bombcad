import Foundation

/// Fire spreading from building to building after the blast, over hours (emmettl/bombcad-work#38;
/// docs/fire-spread.md). It is a building-by-building form of the post-earthquake fire-spread model of
/// GNS Science and Victoria University of Wellington, built for the New Zealand Fire Service. Each
/// of its rules and parameters is published:
/// - Cousins, Heron, Mazzoni, Thomas & Lloydd 2002, NZFS Commission Research Report 27: the radiator,
///   the ignition fluxes, spark reach by wind, brands, and the stages of a fire;
/// - Heron et al. 2003, Report 44: fire through openings, broken or intact, from buildings with
///   non-combustible cladding; the radiator's height; spread from a roof;
/// - Thomas, Heron & Baker 2008, Report 80: the probabilities of the modes that may or may not ignite,
///   before and after an earthquake.
///
/// Their cellular automaton is on 3 m cells. Here each building is one fire:
/// - it grows from its ignition to full involvement, burns for as long as its fuel and openings
///   allow, then burns down;
/// - while fully involved it radiates from the face that looks at each neighbour. That face is the
///   whole of it for combustible cladding and its windows otherwise.
///
/// The neighbour catches fire by one of the modes, in this order: contact, spontaneous ignition,
/// sparks (piloted), openings, the roof, brands. The blast enters through its broken glass (the
/// openings a non-combustible building takes fire through) and its failed walls (which leave it
/// burning as a combustible building would, as Report 80 recoded buildings shaken hard).
///
/// **Standing: illustrative.** Every rule is the model's own, adapted from cells to buildings and
/// from earthquakes to blasts; the seeds are the surface heating's illustrative ignitions or
/// chosen by the user; and it has been judged only qualitatively (docs/fire-spread.md).
public enum FireSpread {
    /// What a building's walls are clad with, as fire from outside meets them.
    public enum Cladding: String, Codable, Sendable, CaseIterable {
        /// Timber and other cladding that ignites (Report 27's "flammable claddings").
        case combustible
        /// Concrete, masonry, steel: only the openings let fire in (Report 44).
        case nonCombustible
    }

    /// How fire reached a building.
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Ignited by the scenario: a seed.
        case seed
        /// A combustible building within `Parameters.contactM` of one fully involved (Report 27 §4.3.1).
        case contact
        /// Radiation at `Parameters.spontaneousKWm2` or more on combustible cladding (Report 27 §4.3.4).
        case spontaneous
        /// Sparks on cladding preheated to `Parameters.pilotedKWm2`, within the sparks' reach for the
        /// wind (Report 27 §4.3.5).
        case piloted
        /// Into a non-combustible building through its windows, broken or intact (Report 44 §2.3,
        /// Report 80 Table 1).
        case openings
        /// From a burning roof that is not fire-rated, up a taller neighbour's face (Report 44 §2.2.3).
        case roof
        /// Flying brands downwind in a near gale (Report 27 §4.3.6).
        case brand
    }

    /// A rectangle of a footprint, metres, x east and y north.
    public struct Rect: Codable, Sendable, Equatable {
        public var min: SIMD2<Double>
        public var max: SIMD2<Double>

        public init(min: SIMD2<Double>, max: SIMD2<Double>) {
            self.min = min
            self.max = max
        }

        public var area: Double { (max.x - min.x) * (max.y - min.y) }
        public var centre: SIMD2<Double> { 0.5 * (min + max) }
    }

    /// One building as the fire sees it.
    public struct Building: Codable, Sendable, Equatable {
        public var id: UUID
        /// Its footprint as disjoint rectangles (a map building's cells merged), m.
        public var footprint: [Rect]
        /// Its ground and roof, m.
        public var base: Double
        public var top: Double
        public var cladding: Cladding
        /// Whether its roof is fire-rated (concrete): a roof that is not spreads fire to a taller
        /// neighbour within 5 m (Report 44 §2.2.3).
        public var fireRatedRoof: Bool
        public var use: BuildingUse
        /// Fire load energy density over its floor, MJ/m².
        public var fuelLoadMJm2: Double
        /// The glazed share of its façades (`GlazingMix.glazedFraction`).
        public var glazedFraction: Double
        /// Its windows' height, m, for the openings' ventilation factor A√H.
        public var windowHeightM: Double
        /// The share of each side's glass the blast broke, sides −x, +x, −y, +y: the chance that
        /// the windows facing a burning neighbour are open.
        public var brokenGlass: [Double]
        /// The chance that the blast failed its walls (heavy damage): then it burns and takes fire
        /// as a combustible building does, its contents open (Report 44 §2.2.2; Report 80 §3.1).
        public var wallsFailed: Double

        public init(
            id: UUID = UUID(), footprint: [Rect], base: Double = 0, top: Double, cladding: Cladding,
            fireRatedRoof: Bool = true, use: BuildingUse = .residential, fuelLoadMJm2: Double = 780,
            glazedFraction: Double = 0.15, windowHeightM: Double = 1.2, brokenGlass: [Double] = [0, 0, 0, 0],
            wallsFailed: Double = 0
        ) {
            self.id = id
            self.footprint = footprint
            self.base = base
            self.top = top
            self.cladding = cladding
            self.fireRatedRoof = fireRatedRoof
            self.use = use
            self.fuelLoadMJm2 = fuelLoadMJm2
            self.glazedFraction = glazedFraction
            self.windowHeightM = windowHeightM
            self.brokenGlass = brokenGlass
            self.wallsFailed = wallsFailed
        }

        public var height: Double { max(top - base, 0) }
        public var footprintArea: Double { footprint.reduce(0) { $0 + $1.area } }
        /// Its footprint's bounds.
        public var bounds: Rect {
            Rect(
                min: footprint.map(\.min).reduce(SIMD2(repeating: .infinity)) { pointwiseMin($0, $1) },
                max: footprint.map(\.max).reduce(SIMD2(repeating: -.infinity)) { pointwiseMax($0, $1) })
        }
    }

    /// The wind over the district, constant through the fire.
    public struct Wind: Codable, Sendable, Equatable {
        /// m/s at roof height.
        public var speedMS: Double
        /// Where it blows from, degrees clockwise from north (meteorology's convention).
        public var fromDegrees: Double

        public init(speedMS: Double = 0, fromDegrees: Double = 0) {
            self.speedMS = speedMS
            self.fromDegrees = fromDegrees
        }

        public static let calm = Wind()
        public var speedKMH: Double { speedMS * 3.6 }
        /// The way it blows to, a unit vector (x east, y north).
        public var downwind: SIMD2<Double> {
            let a = fromDegrees * .pi / 180
            return SIMD2(-sin(a), -cos(a))
        }
    }

    /// The model's parameters: the reports' published values, which the docs cite one by one.
    public struct Parameters: Codable, Sendable, Equatable {
        /// The radiating face's temperature, K: 1000 °C, "a temperature that most compartment fires
        /// are expected to reach" (Report 27 §4.3.2).
        public var radiatorK = 1273.15
        /// Its emissivity (Report 27 §4.3.2).
        public var emissivity = 0.9
        /// Spontaneous ignition of timber, kW/m² (Report 27 §4.3.3, as the NZ Building Code's
        /// acceptable solutions).
        public var spontaneousKWm2 = 30.0
        /// Piloted ignition, kW/m², with sparks or a flame (Report 27 §4.3.3).
        public var pilotedKWm2 = 12.5
        /// The share of the flux that intact glass lets through (Report 44 §2.3.2, "around 50%").
        public var glassTransmission = 0.5
        /// The radiator's height at most, m: three storeys of 4 m alight at once (Report 44 §2.3.3.1).
        public var radiatorHeightM = 12.0
        /// Combustible buildings this close catch by contact, m: flame projection from a window is
        /// under 1.3 m (Report 44 §2.2.5).
        public var contactM = 1.0
        /// Sparks' reach in calm air and across or against the wind, m (Report 27 Table 3).
        public var sparkReachCalmM = 12.0
        /// Sparks' reach downwind, m, against the wind's speed, km/h: Report 27 Table 3's calm,
        /// moderate breeze (20), fresh breeze (30) and near gale (50), linear between and held beyond.
        public var sparkReachDownwind: [SIMD2<Double>] = [
            SIMD2(0, 12), SIMD2(20, 15), SIMD2(30, 21), SIMD2(50, 45),
        ]
        /// The chance that sparks ignite cladding that radiation has preheated enough (Report 80
        /// Table 1's default, 10%).
        public var pilotedChance = 0.1
        /// Brands fly from near gale, km/h, up to `brandReachM` in a 45° arc downwind (Report 27
        /// §4.3.6), and ignite with `brandChance`: Report 80's default is 0, since Wellington's roofs
        /// are steel.
        public var brandWindKMH = 50.0
        public var brandReachM = 45.0
        public var brandArcDegrees = 45.0
        public var brandChance = 0.0
        /// Fire into a non-combustible building through its windows (Report 80 Table 1): the chance
        /// by separation band, up to `upToM`, with the windows intact (Report 80's "pre-earthquake")
        /// or broken ("post-earthquake"). Through intact glass the flux after `glassTransmission` must
        /// reach `spontaneousKWm2`; through broken windows `pilotedKWm2` (Report 44 §2.3.4).
        public var openingBands: [OpeningBand] = [
            OpeningBand(upToM: 3, intact: 0.04, broken: 0.05),
            OpeningBand(upToM: 6, intact: 0.10, broken: 0.41),
            OpeningBand(upToM: 18, intact: 0.01, broken: 0.30),
        ]
        /// From a roof that is not fire-rated to a taller neighbour within `roofReachM` (Report 44
        /// §2.2.3, the NZ Building Code's 5 m), with Report 80's chance.
        public var roofReachM = 5.0
        public var roofChance = 0.3
        /// A fire's growth to full intensity, s: 7.5 minutes (Report 27 §4.2).
        public var growthS = 450.0
        /// How long fire takes to cross a 3 m cell of a building, s: 2.5 minutes (Report 27 §4.3.1);
        /// a building is fully involved once it has crossed its footprint's side, √(area).
        public var cellCrossingS = 150.0
        public var cellM = 3.0
        /// Its burning down after full intensity, s: 12.5 minutes (Report 27 §4.2).
        public var decayS = 750.0
        /// A fire reaches its neighbours one of the model's scans after it is fully involved, s.
        public var scanS = 150.0
        /// A storey's height, m, for a building's floors.
        public var storeyM = 3.0
        /// The fully developed fire burns at the lesser of its ventilation-controlled rate,
        /// `ventilationMWm52` A√H (Kawagoe's 5.5 A√H kg/min of wood, at about 16 MJ/kg) and its
        /// fuel-controlled rate, `fuelControlledKWm2` over its floor (EN 1991-1-2 Annex E's RHRf).
        public var ventilationMWm52 = 1.5
        public var fuelControlledKWm2 = 250.0
        /// The openings' share of a façade at least, for its ventilation: doors and openings that are
        /// not glazed (an assumption).
        public var leastOpeningShare = 0.05

        public init() {}

        public struct OpeningBand: Codable, Sendable, Equatable {
            public var upToM: Double
            public var intact: Double
            public var broken: Double

            public init(upToM: Double, intact: Double, broken: Double) {
                self.upToM = upToM
                self.intact = intact
                self.broken = broken
            }
        }

        /// The black body's emissive power at the radiator's temperature times its emissivity, kW/m².
        public var emissivePowerKWm2: Double { emissivity * 5.670_374e-11 * pow(radiatorK, 4) }

        /// Flux on a point facing a burning face `width` × `height` m at `distance` m, kW/m²: the
        /// configuration factor of a rectangle seen from a point on its centre's normal (as Report 27
        /// reckons its Table 2).
        public func fluxKWm2(width: Double, height: Double, distance: Double) -> Double {
            guard width > 0, height > 0 else { return 0 }
            return emissivePowerKWm2
                * Self.configurationFactor(width: width, height: height, distance: distance)
        }

        /// The configuration factor of a `width` × `height` rectangle from a point `distance` in
        /// front of its centre: the sum of its four quarters' corner factors (Drysdale; Report 27 §4.3).
        public static func configurationFactor(width: Double, height: Double, distance: Double) -> Double {
            let d = max(distance, 1e-3)
            let x = width / (2 * d)
            let y = height / (2 * d)
            let sx = (1 + x * x).squareRoot()
            let sy = (1 + y * y).squareRoot()
            return 2 / .pi * (x / sx * atan(y / sx) + y / sy * atan(x / sy))
        }

        /// Sparks' reach, m, from a fire to a building `cosine` of the way downwind (1 straight
        /// downwind, 0 across, −1 upwind): the calm reach plus the downwind gain in proportion to the
        /// cosine, none across or upwind (Report 27 Table 3; the proportion is this model's).
        public func sparkReach(wind: Wind, cosine: Double) -> Double {
            let kmh = wind.speedKMH
            let table = sparkReachDownwind
            var downwind = table.last?.y ?? sparkReachCalmM
            if let first = table.first, kmh <= first.x { downwind = first.y }
            for (a, b) in zip(table, table.dropFirst()) where kmh >= a.x && kmh <= b.x {
                downwind = a.y + (b.y - a.y) * (kmh - a.x) / max(b.x - a.x, 1e-9)
                break
            }
            return sparkReachCalmM + max(downwind - sparkReachCalmM, 0) * max(cosine, 0)
        }

        /// The chance of fire through a non-combustible building's windows `distance` m from a fire.
        public func openingChance(distance: Double, broken: Bool) -> Double {
            guard let band = openingBands.first(where: { distance <= $0.upToM }) else { return 0 }
            return broken ? band.broken : band.intact
        }

        /// The farthest any mode reaches, m, for the neighbours a building looks at.
        public func reach(wind: Wind) -> Double {
            // Spontaneous ignition from a face of unbounded width: y/√(1+y²) ≥ q/E, y = h/2d.
            let f = min(spontaneousKWm2 / emissivePowerKWm2, 0.999)
            let spontaneous = radiatorHeightM / 2 * (1 - f * f).squareRoot() / f
            let brands = wind.speedKMH >= brandWindKMH && brandChance > 0 ? brandReachM : 0
            return max(
                contactM, spontaneous, sparkReach(wind: wind, cosine: 1), brands, roofReachM,
                openingBands.map(\.upToM).max() ?? 0)
        }
    }

    /// A building's fire: how long it grows, burns fully involved and burns down, s.
    public struct Stages: Sendable, Equatable {
        public var growthS: Double
        public var fullS: Double
        public var decayS: Double
        public var totalS: Double { growthS + fullS + decayS }
    }

    /// Its fire's stages. Growth is Report 27's 7.5 minutes to full intensity and its 2.5 minutes a
    /// 3 m cell across the footprint's side. The fully developed fire burns the building's fuel
    /// (fire load over floors of `storeyM`) a band of `radiatorHeightM` at a time, at the lesser of
    /// its ventilation- and fuel-controlled rates. All the windows count, since glass that the blast
    /// left fails at flashover (Report 44 §2.3.5).
    public static func stages(of building: Building, parameters p: Parameters) -> Stages {
        let area = max(building.footprintArea, 1)
        let growth = p.growthS + p.cellCrossingS * area.squareRoot() / p.cellM
        let height = max(building.height, p.storeyM)
        let band = min(height, p.radiatorHeightM)
        let bands = (height / p.radiatorHeightM).rounded(.up)
        let floors = max(1, (band / p.storeyM).rounded())
        let bounds = building.bounds
        let perimeter = 2 * ((bounds.max.x - bounds.min.x) + (bounds.max.y - bounds.min.y))
        let openings = max(building.glazedFraction, p.leastOpeningShare) * perimeter * band
        let ventilated = p.ventilationMWm52 * 1e6 * openings * max(building.windowHeightM, 0.1).squareRoot()
        let fuelled = p.fuelControlledKWm2 * 1e3 * area * floors
        let fuel = building.fuelLoadMJm2 * 1e6 * area * floors
        let full = bands * fuel / max(min(ventilated, fuelled), 1)
        return Stages(growthS: growth, fullS: full, decayS: p.decayS)
    }
}

// MARK: - Neighbours

extension FireSpread {
    /// One building as another's fire sees it.
    public struct Exposure: Sendable, Equatable {
        public var target: Int
        /// The least distance between their footprints, m.
        public var separation: Double
        /// From the burning building to it, a unit vector.
        public var direction: SIMD2<Double>
        /// The burning building's width across that direction, m: its face's width.
        public var width: Double
        /// The side of the target that faces the fire (−x, +x, −y, +y as 0–3).
        public var side: Int
    }

    /// Each building's neighbours within `reach` m, nearest first.
    public static func exposures(_ buildings: [Building], reach: Double) -> [[Exposure]] {
        let bounds = buildings.map(\.bounds)
        let cell = max(reach, 1)
        var grid: [SIMD2<Int>: [Int]] = [:]
        func key(_ p: SIMD2<Double>) -> SIMD2<Int> {
            SIMD2(Int((p.x / cell).rounded(.down)), Int((p.y / cell).rounded(.down)))
        }
        for (n, b) in bounds.enumerated() where b.min.x.isFinite {
            let low = key(b.min)
            let high = key(b.max)
            for j in low.y...high.y {
                for i in low.x...high.x { grid[SIMD2(i, j), default: []].append(n) }
            }
        }
        var result = [[Exposure]](repeating: [], count: buildings.count)
        result.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: buildings.count) { n in
                let b = bounds[n]
                guard b.min.x.isFinite else { return }
                let low = key(b.min - reach)
                let high = key(b.max + reach)
                var seen = Set<Int>()
                for j in low.y...high.y {
                    for i in low.x...high.x {
                        for m in grid[SIMD2(i, j)] ?? [] where m != n { seen.insert(m) }
                    }
                }
                var list: [Exposure] = []
                for m in seen {
                    guard let e = exposure(from: buildings[n], to: buildings[m], index: m),
                        e.separation <= reach
                    else { continue }
                    list.append(e)
                }
                out[n] = list.sorted { ($0.separation, $0.target) < ($1.separation, $1.target) }
            }
        }
        return result
    }

    /// How `target` (at `index`) lies from `source`: the nearest pair of their rectangles, the way
    /// from one to the other, and the source's width across it.
    static func exposure(from source: Building, to target: Building, index: Int) -> Exposure? {
        var best: (d: Double, gap: SIMD2<Double>, centres: SIMD2<Double>)?
        for a in source.footprint {
            for b in target.footprint {
                func gap(_ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
                    b0 > a1 ? b0 - a1 : a0 > b1 ? -(a0 - b1) : 0
                }
                let g = SIMD2(
                    gap(a.min.x, a.max.x, b.min.x, b.max.x), gap(a.min.y, a.max.y, b.min.y, b.max.y))
                let d = (g * g).sum().squareRoot()
                if best == nil || d < best!.d { best = (d, g, b.centre - a.centre) }
            }
        }
        guard let best else { return nil }
        var way = best.d > 0 ? best.gap : best.centres
        let length = (way * way).sum().squareRoot()
        if length <= 0 { way = SIMD2(1, 0) } else { way /= length }
        let across = SIMD2(-way.y, way.x)
        var low = Double.infinity
        var high = -Double.infinity
        for r in source.footprint {
            for corner in [r.min, r.max, SIMD2(r.min.x, r.max.y), SIMD2(r.max.x, r.min.y)] {
                let s = (corner * across).sum()
                low = min(low, s)
                high = max(high, s)
            }
        }
        let axis = abs(way.x) >= abs(way.y) ? 0 : 1
        // The target faces back along the way: its −x side if the fire lies to its west.
        let side = 2 * axis + (way[axis] > 0 ? 0 : 1)
        return Exposure(
            target: index, separation: best.d, direction: way, width: max(high - low, 0), side: side)
    }
}

// MARK: - A run

extension FireSpread {
    /// One ignition: a building and when, s after the blast.
    public struct Ignition: Codable, Sendable, Equatable {
        public var building: Int
        public var atS: Double

        public init(building: Int, atS: Double = 0) {
            self.building = building
            self.atS = atS
        }
    }

    /// Ignitions placed at random: `count` of `candidates` (building indices), different in each draw.
    public struct RandomIgnitions: Codable, Sendable, Equatable {
        public var count: Int
        public var candidates: [Int]

        public init(count: Int, candidates: [Int]) {
            self.count = count
            self.candidates = candidates
        }

        /// This draw's: a partial Fisher–Yates shuffle on the draw's own numbers.
        public func draw(member: UInt64, seed: UInt64) -> [Int] {
            var pool = candidates
            let key = Draws(seed: seed, member: member)
            let wanted = min(max(count, 0), pool.count)
            for k in 0..<wanted {
                let pick = k + min(Int(key.uniform(k, -1, 9) * Double(pool.count - k)), pool.count - k - 1)
                pool.swapAt(k, pick)
            }
            return Array(pool.prefix(wanted)).sorted()
        }
    }

    /// One draw of the fire: each building's ignition, if it caught by `horizonS`, how and from which.
    public struct Member: Sendable, Equatable {
        public var ignitedS: [Double?]
        public var mode: [Mode?]
        public var source: [Int?]
        /// Each building's stages (whether or not it caught).
        public var stages: [Stages]

        /// How many were alight (ignited, not yet burnt out) and how many burnt out at `t`.
        public func counts(at t: Double) -> (burning: Int, burnt: Int) {
            var burning = 0
            var burnt = 0
            for (n, start) in ignitedS.enumerated() {
                guard let start, start <= t else { continue }
                if t < start + stages[n].totalS { burning += 1 } else { burnt += 1 }
            }
            return (burning, burnt)
        }
    }

    /// A district ready for the fire: its buildings, their neighbours and their fires' stages.
    public struct District: Sendable {
        public let buildings: [Building]
        public let wind: Wind
        public let parameters: Parameters
        public let exposures: [[Exposure]]
        public let stages: [Stages]

        public init(buildings: [Building], wind: Wind = .calm, parameters: Parameters = Parameters()) {
            self.buildings = buildings
            self.wind = wind
            self.parameters = parameters
            exposures = FireSpread.exposures(buildings, reach: parameters.reach(wind: wind))
            stages = buildings.map { FireSpread.stages(of: $0, parameters: parameters) }
        }

        /// One draw, `member` of the ensemble whose draws `seed` sets: the same arguments give the
        /// same fire on any machine. Each chance is drawn once for its pair (or building, or side)
        /// and mode, so the fire is the earliest arrival over the pairs whose draws came up, the
        /// building's ignition plus its growth plus one scan (Dijkstra's order).
        public func run(seeds: [Ignition], horizonS: Double, member: UInt64 = 0, seed: UInt64 = 0) -> Member {
            let p = parameters
            let count = buildings.count
            var ignited = [Double?](repeating: nil, count: count)
            var mode = [Mode?](repeating: nil, count: count)
            var source = [Int?](repeating: nil, count: count)
            var best = [Double](repeating: .infinity, count: count)
            var done = [Bool](repeating: false, count: count)
            var queue = MinQueue()
            for s in seeds where buildings.indices.contains(s.building) && s.atS < best[s.building] {
                best[s.building] = s.atS
                mode[s.building] = .seed
                source[s.building] = nil
                queue.push(s.atS, s.building)
            }
            let key = Draws(seed: seed, member: member)
            // Whether the blast failed a building's walls, in this draw: then it burns as combustible.
            func opened(_ n: Int) -> Bool {
                buildings[n].wallsFailed > 0 && key.uniform(n, 0, 1) < buildings[n].wallsFailed
            }
            func combustible(_ n: Int) -> Bool { buildings[n].cladding == .combustible || opened(n) }
            let downwind = wind.downwind
            let brands = wind.speedKMH >= p.brandWindKMH && p.brandChance > 0
            let arc = cos(p.brandArcDegrees / 2 * .pi / 180)
            while let (t, n) = queue.pop() {
                guard !done[n], t <= best[n] else { continue }
                done[n] = true
                guard t <= horizonS else { continue }
                ignited[n] = t
                let full = t + stages[n].growthS
                let spreads = full + min(p.scanS, stages[n].fullS)
                guard spreads <= horizonS else { continue }
                let fromCombustible = combustible(n)
                let s = buildings[n]
                let height = min(s.height, p.radiatorHeightM)
                for e in exposures[n] where !done[e.target] && spreads < best[e.target] {
                    let m = e.target
                    let target = buildings[m]
                    let width = fromCombustible ? e.width : e.width * s.glazedFraction
                    let q = p.fluxKWm2(width: width, height: height, distance: e.separation)
                    var how: Mode?
                    if combustible(m) {
                        if e.separation <= p.contactM {
                            how = .contact
                        } else if q >= p.spontaneousKWm2 {
                            how = .spontaneous
                        } else if q >= p.pilotedKWm2,
                            e.separation <= p.sparkReach(wind: wind, cosine: (e.direction * downwind).sum()),
                            key.uniform(n, m, 2) < p.pilotedChance
                        {
                            how = .piloted
                        } else if brands, e.separation <= p.brandReachM,
                            (e.direction * downwind).sum() >= arc,
                            key.uniform(n, m, 3) < p.brandChance
                        {
                            how = .brand
                        }
                    } else {
                        if target.glazedFraction > 0 {
                            let broken = key.uniform(m, 4 + e.side, 1) < target.brokenGlass[e.side]
                            let enough =
                                broken ? q >= p.pilotedKWm2 : q * p.glassTransmission >= p.spontaneousKWm2
                            if enough,
                                key.uniform(n, m, 4) < p.openingChance(distance: e.separation, broken: broken)
                            {
                                how = .openings
                            }
                        }
                        if how == nil, !s.fireRatedRoof, e.separation <= p.roofReachM, target.top > s.top,
                            key.uniform(n, m, 5) < p.roofChance
                        {
                            how = .roof
                        }
                    }
                    guard let how else { continue }
                    best[m] = spreads
                    mode[m] = how
                    source[m] = n
                    queue.push(spreads, m)
                }
            }
            for n in 0..<count where ignited[n] == nil {
                mode[n] = nil
                source[n] = nil
            }
            return Member(ignitedS: ignited, mode: mode, source: source, stages: stages)
        }
    }

    /// The draws of one ensemble member: a uniform number in [0, 1) for each (a, b, mode), the same
    /// whatever order they are asked in (SplitMix64 over the key).
    struct Draws {
        let seed: UInt64
        let member: UInt64

        func uniform(_ a: Int, _ b: Int, _ kind: Int) -> Double {
            var z = seed &+ 0x9E37_79B9_7F4A_7C15 &* (member &+ 1)
            z ^= UInt64(truncatingIfNeeded: a) &* 0xBF58_476D_1CE4_E5B9
            z ^= UInt64(truncatingIfNeeded: b) &* 0x94D0_49BB_1331_11EB
            z ^= UInt64(truncatingIfNeeded: kind) &* 0xD6E8_FEB8_6659_FD93
            for _ in 0..<2 {
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                z ^= z >> 31
            }
            return Double(z >> 11) / Double(UInt64(1) << 53)
        }
    }

    /// A binary heap of (time, building), earliest first, ties by building.
    struct MinQueue {
        private var heap: [(Double, Int)] = []

        mutating func push(_ t: Double, _ n: Int) {
            heap.append((t, n))
            var i = heap.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard heap[i] < heap[parent] else { break }
                heap.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> (Double, Int)? {
            guard !heap.isEmpty else { return nil }
            let top = heap[0]
            let last = heap.removeLast()
            if !heap.isEmpty {
                heap[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1
                    let r = l + 1
                    var m = i
                    if l < heap.count, heap[l] < heap[m] { m = l }
                    if r < heap.count, heap[r] < heap[m] { m = r }
                    if m == i { break }
                    heap.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }
}

// MARK: - The ensemble

extension FireSpread {
    /// What many draws of the fire give.
    public struct Ensemble: Codable, Sendable {
        public struct Building: Codable, Sendable {
            public var index: Int
            public var id: UUID
            /// The share of draws in which it caught by the horizon.
            public var chance: Double
            /// The median of its ignition time over the draws in which it caught, s.
            public var medianIgnitionS: Double?
            /// How it caught, most often.
            public var mode: Mode?
            public var burnS: Double
        }

        public struct Step: Codable, Sendable {
            public var atS: Double
            /// Buildings alight, over the draws: 5th, 50th and 95th percentiles.
            public var burning: SIMD3<Double>
            /// Buildings burnt out, the same.
            public var burnt: SIMD3<Double>
            /// Floor area alight or burnt out, m², the same.
            public var affectedFloorM2: SIMD3<Double>
        }

        public var members: Int
        public var seed: UInt64
        public var horizonS: Double
        public var wind: Wind
        public var parameters: Parameters
        public var seeds: [Ignition]
        public var random: RandomIgnitions?
        public var buildings: [Building]
        public var timeline: [Step]
        /// Over the draws, the mean number of buildings each mode ignited.
        public var modes: [String: Double]
        /// The buildings that caught by the horizon, over the draws: 5th, 50th and 95th percentiles.
        public var caught: SIMD3<Double>
    }

    /// `members` draws of `district`'s fire from `seeds` to `horizonS`, the timeline every `stepS`.
    ///
    /// With `random`, each draw also ignites that many of its candidates at the blast, chosen
    /// afresh each draw, as Report 27 ran Wellington from 27 randomly placed ignitions (§5.2).
    public static func ensemble(
        _ district: District, seeds: [Ignition], random: RandomIgnitions? = nil, horizonS: Double,
        members: Int = 100, seed: UInt64 = 0, stepS: Double = 600
    ) -> Ensemble {
        let count = max(members, 1)
        var runs = [Member?](repeating: nil, count: count)
        runs.withUnsafeMutableBufferPointer { out in
            concurrently(iterations: count) { k in
                let drawn = random?.draw(member: UInt64(k), seed: seed) ?? []
                out[k] = district.run(
                    seeds: seeds + drawn.map { Ignition(building: $0) }, horizonS: horizonS,
                    member: UInt64(k),
                    seed: seed)
            }
        }
        let draws = runs.map { $0! }
        let floor = district.buildings.map {
            $0.footprintArea * max(1, ($0.height / district.parameters.storeyM).rounded())
        }
        func percentiles(_ values: [Double]) -> SIMD3<Double> {
            let sorted = values.sorted()
            func at(_ q: Double) -> Double {
                guard !sorted.isEmpty else { return 0 }
                return sorted[min(sorted.count - 1, max(0, Int((q * Double(sorted.count - 1)).rounded())))]
            }
            return SIMD3(at(0.05), at(0.5), at(0.95))
        }
        var buildings: [Ensemble.Building] = []
        for n in district.buildings.indices {
            let times = draws.compactMap { $0.ignitedS[n] }.sorted()
            var tally: [Mode: Int] = [:]
            for d in draws { if let m = d.mode[n] { tally[m, default: 0] += 1 } }
            let mode = tally.max { ($0.value, $1.key.rawValue) < ($1.value, $0.key.rawValue) }?.key
            buildings.append(
                Ensemble.Building(
                    index: n, id: district.buildings[n].id, chance: Double(times.count) / Double(count),
                    medianIgnitionS: times.isEmpty ? nil : times[times.count / 2], mode: mode,
                    burnS: district.stages[n].totalS))
        }
        var timeline: [Ensemble.Step] = []
        var t = 0.0
        while t <= horizonS + 1e-9 {
            var burning: [Double] = []
            var burnt: [Double] = []
            var area: [Double] = []
            for d in draws {
                let c = d.counts(at: t)
                burning.append(Double(c.burning))
                burnt.append(Double(c.burnt))
                var a = 0.0
                for (n, start) in d.ignitedS.enumerated() where start.map({ $0 <= t }) ?? false {
                    a += floor[n]
                }
                area.append(a)
            }
            timeline.append(
                Ensemble.Step(
                    atS: t, burning: percentiles(burning), burnt: percentiles(burnt),
                    affectedFloorM2: percentiles(area)))
            t += max(stepS, 1)
        }
        var modes: [String: Double] = [:]
        for d in draws {
            for m in d.mode.compactMap({ $0 }) { modes[m.rawValue, default: 0] += 1 / Double(count) }
        }
        return Ensemble(
            members: count, seed: seed, horizonS: horizonS, wind: district.wind,
            parameters: district.parameters,
            seeds: seeds, random: random, buildings: buildings, timeline: timeline, modes: modes,
            caught: percentiles(draws.map { Double($0.ignitedS.compactMap { $0 }.count) }))
    }

    /// Its standing, worded from docs/fire-spread.md.
    public static let standing: [String] = [
        "\(EvidenceLevel.illustrative.title). A building-by-building form of the post-earthquake fire-spread "
            + "model GNS Science and Victoria University of Wellington built for the NZ Fire Service (Cousins "
            + "et al. 2002; Heron et al. 2003; Thomas et al. 2008): its radiator, ignition fluxes, spark reach "
            + "by wind and chances through openings, from cells to buildings and from earthquakes to blasts.",
        "Checked against the model's own published tables (fluxes and critical separations), not against a "
            + "fire: judged only qualitatively, on Beirut 2020, where the city's concrete and stone did not "
            + "carry a fire though nearly all its glass broke.",
        "The seeds are the surface heating's illustrative ignitions or the user's choice; the fire load, "
            + "glazing and construction are assumed by use and the map; no firefighting, no change of wind, "
            + "no fire inside a building from floor to floor, no gas or fuel stores.",
    ]
}

private func pointwiseMin(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
    SIMD2(min(a.x, b.x), min(a.y, b.y))
}

private func pointwiseMax(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
    SIMD2(max(a.x, b.x), max(a.y, b.y))
}
