import Foundation
import simd

/// Where a brick wall's debris lands: R. A. Keys, *Experimental & computational structural
/// analysis of masonry panels subject to long duration blast loading*, PhD thesis, University
/// of Southampton, 2016 (eprint 413951), and R. Keys and S. K. Clubley, *Engineering Structures*
/// 130 (2017) 229–241. Single-leaf walls of solid brick in running bond, 1 m long, 2 m high and
/// one brick (102.5 mm) thick, "A panels", each brick numbered and the debris collected and
/// weighed over a 0.5 m grid round the wall. The masses here were read from the thesis's
/// longitudinal histograms (Figures 4.17c, 4.20c, 4.22c and 4.30c) by `Scripts/keys2016`; the
/// trial data themselves are the UK Ministry of Defence's. See `Fixtures/Keys2016`.
///
/// The Windrush Arena trials put the walls on radials from 41 kg of TNT on the ground at MoD
/// Shoeburyness, side-on to them. The thesis's long-duration trials in the Air Blast Tunnel,
/// whose walls were thrown 5 to 50 m by the drag behind the shock, are in the fixture but not
/// run: the model cannot load debris with a planar long-duration wave (see docs/validation.md).
public enum MasonryDebrisTests {
    /// One wall: where it stood, the blast measured beside it, and the debris mass in 0.5 m bins
    /// from `firstBin` metres downstream of its upstream face (negative is towards the charge).
    public struct Trial: Sendable {
        public var id: String
        public var standoff: Float
        /// The peak side-on overpressure (Pa) and positive impulse (Pa s) the thesis gives as
        /// recorded at this radius (Tables 5.1 and 5.2): the trials' gauges were on the ground.
        public var measuredPeak: Float
        public var measuredImpulse: Float
        public var firstBin: Float
        public var masses: [Float]
        public var note: String = ""
    }

    public static let binWidth: Float = 0.5

    /// WR1A, WR1B and WR2C; WR1C, rebuilt a week before firing in weaker mortar, is kept but
    /// not compared (WR2C repeated it). Readings under 1 kg (two pixels) are taken as zero.
    public static let trials: [Trial] = [
        Trial(
            id: "WR1A", standoff: 10.6, measuredPeak: 115.1e3, measuredImpulse: 263.1, firstBin: -2,
            masses: [0, 3.9, 39.9, 104.0, 100.1, 44.2, 26.0, 13.9, 6.1, 3.9, 0, 0]),
        Trial(
            id: "WR1B", standoff: 13, measuredPeak: 73.1e3, measuredImpulse: 240.8, firstBin: -2,
            masses: [0, 2.5, 42.4, 104.5, 52.4, 48.3, 46.2, 30.2, 10.5, 8.4, 8.4, 8.4, 4.2, 0, 0, 2.5]),
        Trial(
            id: "WR2C", standoff: 15, measuredPeak: 53.2e3, measuredImpulse: 234.4, firstBin: -2,
            masses: [0, 8.2, 42.2, 102.2, 76.3, 66.0, 48.3, 38.0, 8.2, 4.3, 2.1, 0]),
        Trial(
            id: "WR1C", standoff: 15, measuredPeak: 53.2e3, measuredImpulse: 234.4, firstBin: -4,
            masses: [0, 2.0, 2.0, 8.1, 20.2, 31.9, 70.3, 71.9, 64.2, 52.1, 20.2, 8.1, 6.1, 0, 0],
            note: "rebuilt a week before firing; weaker mortar"),
    ]

    /// Mass-weighted statistics of debris in 0.5 m bins: the mean distance, the median and 90th
    /// percentile bins' centres, and the far end of the furthest bin holding at least `floor`.
    public struct Spread: Sendable, CustomStringConvertible {
        public var total: Float
        public var mean: Float
        public var median: Float
        public var p90: Float
        public var furthest: Float

        public init(
            firstBin: Float, masses: [Float], width: Float = MasonryDebrisTests.binWidth, floor: Float = 1
        ) {
            let centres = masses.indices.map { firstBin + (Float($0) + 0.5) * width }
            let sum = masses.reduce(0, +)
            total = sum
            mean = sum > 0 ? zip(centres, masses).reduce(0) { $0 + $1.0 * $1.1 } / sum : 0
            func quantile(_ q: Float) -> Float {
                var running: Float = 0
                for (centre, mass) in zip(centres, masses) {
                    running += mass
                    if running >= q * sum { return centre }
                }
                return centres.last ?? 0
            }
            median = quantile(0.5)
            p90 = quantile(0.9)
            let last = masses.lastIndex { $0 >= floor } ?? 0
            furthest = firstBin + Float(last + 1) * width
        }

        public var description: String {
            String(
                format: "%5.0f kg, mean %5.2f m, median %5.2f m, 90%% within %5.2f m, furthest %4.1f m",
                total,
                mean, median, p90, furthest)
        }
    }

    public struct Result: Sendable {
        public var trial: Trial
        public var firstBin: Float
        public var masses: [Float]
        /// The model's side-on peak and positive impulse on the ground at the wall's radius, 3 m
        /// to one side of it: the impulse of the positive phase, from the arrival to the first
        /// return to ambient, as the test's gauges give it (summed over seconds of record, a
        /// residual of tens of pascals in the settled air would add hundreds of Pa s).
        public var gaugePeak: Float = 0
        public var gaugeImpulse: Float = 0
        /// When everything had come to rest (the fastest node under `restSpeed`), or the time
        /// limit.
        public var settled: Double = 0
        public var summary = StructureSummary()
        public var elementSize: Float = 0
        public var wallSeconds: Double = 0
        /// When the wave reached the face (s), and the bed joints open by 0.1 mm across at least
        /// half the wall at 5, 10, 20, 50, 100 and 200 ms after that.
        public var arrival: Float = 0
        public var crackHistory: [(time: Double, heights: [Float])] = []
        /// The pieces it ended in (`pieces`), heaviest first, kg.
        public var pieces: [Float] = []

        public var spread: Spread { Spread(firstBin: firstBin, masses: masses) }
        public var measuredSpread: Spread { Spread(firstBin: trial.firstBin, masses: trial.masses) }

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            trial: Trial,
            firstBin: Float,
            masses: [Float],
            gaugePeak: Float = 0,
            gaugeImpulse: Float = 0,
            settled: Double = 0,
            summary: StructureSummary = StructureSummary(),
            elementSize: Float = 0,
            wallSeconds: Double = 0,
            arrival: Float = 0,
            crackHistory: [(time: Double, heights: [Float])] = [],
            pieces: [Float] = []
        ) {
            self.trial = trial
            self.firstBin = firstBin
            self.masses = masses
            self.gaugePeak = gaugePeak
            self.gaugeImpulse = gaugeImpulse
            self.settled = settled
            self.summary = summary
            self.elementSize = elementSize
            self.wallSeconds = wallSeconds
            self.arrival = arrival
            self.crackHistory = crackHistory
            self.pieces = pieces
        }
    }

    /// The wall as built: a brick and its joint are 225 by 75 mm on face, so 37.5 mm elements
    /// give two to a course and six to a brick, and the wall is three elements (112.5 mm) thick
    /// rather than 102.5 mm, its density reduced to keep its mass (1 × 2 × 0.1025 m at
    /// 1900 kg/m³, 390 kg; the trials collected 340 to 400 kg). On a mortar bed: the joints' own
    /// bond, cohesion and friction (the thesis does not say what the walls stood on).
    public static func wall(
        at front: SIMD3<Float>, elementSize h: Float = 0.0375, base: Anchorage? = mortarBed
    ) -> StructureModel {
        let length = (1 / h).rounded() * h
        let height = (2 / h).rounded() * h
        let thickness = (0.1025 / h).rounded() * h
        let box = Box(min: front, max: front + SIMD3(thickness, length, height))
        var material = StructureMaterial.masonry
        material.name = "Brickwork (Keys)"
        material.density = 1900 * (1 * 2 * 0.1025) / (length * height * thickness)
        var model = StructureModel(solids: [box], material: material, elementSize: h, fixedBase: true)
        model.baseAnchorage = base
        return model
    }

    /// A mortar bed with the brickwork's own joints' bond, cohesion and friction.
    public static let mortarBed: Anchorage = {
        let units = MasonryUnits.brick
        return Anchorage(
            tensileStrength: units.bondStrength,
            tensionOpening: 2 * units.bondFractureEnergy / units.bondStrength,
            cohesion: units.cohesion, cohesionSlip: 2 * units.shearFractureEnergy / units.cohesion,
            friction: units.friction)
    }()
}

// MARK: - The Air Blast Tunnel

extension MasonryDebrisTests {
    /// A wall in the Air Blast Tunnel at MoD Shoeburyness, a shock tube giving about 110 kPa for
    /// 210 ms in its 4.9 m section and 55–60 kPa for 150–180 ms in its 10.2 m section. Keys and
    /// Clubley's table 1 gives the measured incident overpressure, positive phase and impulse
    /// (`Fixtures/Keys2016/panels.json`); the debris, in `bin` m bins from the wall's upstream
    /// face, is read off the thesis's figures 4.39, 4.58c and 4.73c (`debris.json`).
    public struct TunnelTrial: Sendable {
        public var id: String
        /// Across the tunnel (m): one A panel, or two side by side.
        public var width: Float
        public var overpressure: Float
        public var duration: Float
        public var impulse: Float
        /// Bed joints the paper saw open at 50 ms (m above the base).
        public var crackHeights: [Float]
        public var bin: Float
        public var masses: [Float]
    }

    public static let tunnelTrials: [TunnelTrial] = [
        TunnelTrial(
            id: "BWL1A", width: 1, overpressure: 100e3, duration: 0.214, impulse: 7260,
            crackHeights: [0.3, 0.5, 1.6],
            bin: 1,
            masses: [
                1, 1, 1, 1, 1, 3, 1, 7, 1, 5, 2, 1, 5, 13, 8, 11, 3, 5, 6, 20, 2, 2, 14, 4, 10, 8, 13, 26, 27,
                13, 43, 48, 31, 9, 3, 7, 4, 7, 3, 3, 2, 3, 4, 6, 1, 3, 3, 1, 3, 1,
            ]),
        TunnelTrial(
            id: "BWL2C", width: 1, overpressure: 60e3, duration: 0.179, impulse: 3952,
            crackHeights: [0.5, 1.5], bin: 0.5,
            masses: [
                0, 0, 0, 0, 9.9, 3.9, 19.5, 13.8, 16.7, 49.3, 14.6, 5.7, 9.9, 67, 64.1, 54.2, 11.7, 5.7, 5, 0,
                5, 5, 0, 0, 1.8, 2.9, 0, 0,
            ]),
        TunnelTrial(
            id: "BWL3B", width: 2, overpressure: 57e3, duration: 0.152, impulse: 3362, crackHeights: [],
            bin: 0.5,
            masses: [
                3, 2, 95, 30.9, 7.2, 29.9, 26, 27.9, 59.8, 20.1, 37.2, 16.1, 38.1, 56.9, 93, 48, 44.1, 20.1,
                23, 15.1, 7.2, 10.2, 2, 6.2, 10.2, 6.2, 1, 7.2, 3, 19.1,
            ]),
    ]

    /// The Friedlander decay constant b for which a wave of `peak` and `duration` carries
    /// `impulse`: I = p t+ (1/b − (1 − e^−b)/b²).
    public static func decay(peak: Float, duration: Float, impulse: Float) -> Float {
        let target = impulse / (peak * duration)
        var low: Float = 0.01
        var high: Float = 20
        for _ in 0..<60 {
            let b = 0.5 * (low + high)
            let share = 1 / b - (1 - exp(-b)) / (b * b)
            if share > target { low = b } else { high = b }
        }
        return 0.5 * (low + high)
    }

    /// The air entering the tunnel `t` seconds after the shock: the measured incident
    /// overpressure's Friedlander curve, the shock's jump by the Rankine–Hugoniot relations, and
    /// behind it a simple wave (isentropic, the Riemann invariant along the backward
    /// characteristics kept). Past the negative phase's depth, or 30% of the peak, the curve is
    /// held at its least.
    public static func inflow(
        _ trial: TunnelTrial, at t: Float, ambient: Float = 101_325, density: Float = 1.225
    )
        -> Primitive
    {
        let gamma: Float = 1.4
        let c0 = (gamma * ambient / density).squareRoot()
        let ps = ambient + trial.overpressure
        let mach = (1 + (gamma + 1) / (2 * gamma) * (ps / ambient - 1)).squareRoot()
        let rhos = density * (gamma + 1) * mach * mach / ((gamma - 1) * mach * mach + 2)
        let us = 2 * c0 / (gamma + 1) * (mach - 1 / mach)
        let cs = (gamma * ps / rhos).squareRoot()
        let b = decay(peak: trial.overpressure, duration: trial.duration, impulse: trial.impulse)
        let s = max(t, 0) / trial.duration
        let f = max((1 - s) * exp(-b * s), -0.3)
        let p = max(ambient + trial.overpressure * f, 0.2 * ambient)
        let rho = rhos * pow(p / ps, 1 / gamma)
        let c = (gamma * p / rho).squareRoot()
        let u = us + 2 / (gamma - 1) * (c - cs)
        return Primitive(density: rho, velocity: SIMD3(u, 0, 0), pressure: p)
    }

    public struct TunnelResult: Sendable {
        public var trial: TunnelTrial
        /// Mass (kg) by where it lay at the end, in `trial.bin` bins from the upstream face, the
        /// first holding anything upstream of it and the last anything beyond.
        public var masses: [Float]
        public var incidentPeak: Float = 0
        public var incidentImpulse: Float = 0
        public var facePeak: Float = 0
        /// Bed joints open across half the wall's width at 50 ms (m above the base).
        public var crackHeights: [Float] = []
        /// The pieces it ended in (`pieces`), heaviest first, kg.
        public var pieces: [Float] = []
        public var settled: Double = 0
        public var summary = StructureSummary()
        public var wallSeconds: Double = 0

        public var spread: Spread { Spread(firstBin: 0, masses: masses, width: trial.bin) }
        public var measuredSpread: Spread { Spread(firstBin: 0, masses: trial.masses, width: trial.bin) }

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            trial: TunnelTrial,
            masses: [Float],
            incidentPeak: Float = 0,
            incidentImpulse: Float = 0,
            facePeak: Float = 0,
            crackHeights: [Float] = [],
            pieces: [Float] = [],
            settled: Double = 0,
            summary: StructureSummary = StructureSummary(),
            wallSeconds: Double = 0
        ) {
            self.trial = trial
            self.masses = masses
            self.incidentPeak = incidentPeak
            self.incidentImpulse = incidentImpulse
            self.facePeak = facePeak
            self.crackHeights = crackHeights
            self.pieces = pieces
            self.settled = settled
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
    }
}
