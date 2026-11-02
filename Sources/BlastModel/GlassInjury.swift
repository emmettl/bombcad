import Foundation

/// Injury from window glass thrown into a room (emmettl/bombcad-work#117; docs/people-in-the-scene.md,
/// "Hurt by the glass thrown"): what the people behind a façade meet when its panes break and their
/// glass flies, by how far it is thrown and the pieces it strikes with, not by how many panes crack.
///
/// - **How far, how fast.** Each pane type's glass leaves at the speed `GlazingHazard` gives it
///   (its speed on breaking and what the load still on it adds), level from its middle, and falls
///   without drag: it reaches into the room as far as it lands (`GlazingHazard.thrown`). A person
///   nearer the window than that is in its way, one further is not.
/// - **What it strikes with.** Monolithic glass flies as the pieces the envelope debris takes
///   (`DebrisLaunch.piece`: annealed in 50 mm squares, toughened in 8 mm dice). Laminated glass torn
///   or pulled out of its frame, and filmed glass its film lets go of, fly whole.
/// - **How many strike.** The glass flies straight in from its window: a person stands in some
///   window's path as often as the façade is glazed (its glazed share), and there meets that window's
///   broken glass over their presented area (`presentedAreaM2`), a whole pane over theirs and its own;
///   elsewhere in the room, none (`zone`).
/// - **What a strike does.** A sharp piece: Bowen, Richmond, Wetherbe and White's glass missiles
///   fired into the abdomen (AECU-3350, 1956): Equation 13 for the body wall pierced, a serious
///   wound, where it strikes the trunk (`trunkShare`), and their skin column fitted on the same
///   form for a cut, wherever it strikes. A whole pane, blunt: the
///   fragments' energies (`HazardCriteria`): 14.9 J injurious, 79 J hazardous.
///
/// Illustrative: one animal study's criteria, a piece size assumed, glass flown level and without
/// drag, people spread evenly over the room.
public enum GlassInjury {
    /// A standing person's presented area, m²: DDESB TP-12's 6.2 ft² (Zaker, 1975), the area the
    /// fragment hazard distance is judged on (`HazardCriteria.hazardousAreaM2`).
    public static let presentedAreaM2 = 0.58
    /// The share of it that is the trunk, the body wall Bowen et al.'s serious wound pierces: a third
    /// (assumed). A cut counts anywhere.
    public static let trunkShare = 1.0 / 3
    /// How deep into a room the glass is followed, m: beyond, a room's back wall or its partitions
    /// stop it (assumed; GSA's and ASTM's tests judge to 3 m, Bowen's missile traps stood 3 m in).
    public static let roomDepthM = 6.0
    /// The masses Bowen et al.'s criterion is taken over, g: their lightest test missile (0.0543 g)
    /// to the 10 g they extrapolated it to themselves (their §7.4); outside, held at the nearer end.
    public static let gramsRange = 0.0543...10.0
    /// The skin's criterion is the body wall's at the speed times this: Bowen et al.'s skin column
    /// (Table 3.1, column F, 389 shots) fitted on their Equation 13's form, root mean square 0.10
    /// (their own fit to the body wall, 0.075). Skin is cut at 0.72 of the body wall's speed.
    public static let skinSpeedFactor = 1.38

    /// The chance that a glass piece of `grams` striking at `speedMS` pierces the body wall into the
    /// abdomen: Bowen et al. (1956), Equation 13, `log V = 2.5172 − log(log m + 2.3054) + 0.4842 P`,
    /// V in ft/s and m in g, P from nought at the threshold speed to one at 3.05 times it.
    public static func bodyWall(grams: Double, speedMS: Double) -> Double {
        guard speedMS > 0 else { return 0 }
        let m = min(max(grams, gramsRange.lowerBound), gramsRange.upperBound)
        let feet = speedMS / 0.3048
        let p = (log10(feet) - 2.5172 + log10(log10(m) + 2.3054)) / 0.4842
        return min(max(p, 0), 1)
    }

    /// The chance that it cuts through the skin (`skinSpeedFactor`).
    public static func skin(grams: Double, speedMS: Double) -> Double {
        bodyWall(grams: grams, speedMS: speedMS * skinSpeedFactor)
    }

    /// One pane type's glass thrown, as the room meets it.
    public struct Thrown: Sendable, Equatable {
        /// Its glass broken and thrown, as a share of the façade's area.
        public var areaShare: Double
        /// Its speed into the room, m/s, and how far in it lands, m.
        public var speedMS: Double
        public var reachM: Double
        /// Each piece's mass, kg, and its area, m².
        public var pieceKg: Double
        public var pieceM2: Double
        /// Flying whole (laminated or filmed glass let go), judged blunt; else sharp pieces.
        public var whole: Bool

        public init(
            areaShare: Double, speedMS: Double, reachM: Double, pieceKg: Double, pieceM2: Double, whole: Bool
        ) {
            self.areaShare = areaShare
            self.speedMS = speedMS
            self.reachM = reachM
            self.pieceKg = pieceKg
            self.pieceM2 = pieceM2
            self.whole = whole
        }

        /// The pieces expected to strike a person in its way, and of them the shares that hurt and
        /// that hurt severely.
        var strikes: (count: Double, hurt: Double, severe: Double) {
            guard areaShare > 0, pieceM2 > 0, speedMS > 0 else { return (0, 0, 0) }
            let count = areaShare / pieceM2 * (presentedAreaM2 + (whole ? pieceM2 : 0))
            if whole {
                let energy = 0.5 * pieceKg * speedMS * speedMS
                return (
                    count, energy >= Double(HazardCriteria.injuryEnergyJ) ? 1 : 0,
                    energy >= Double(HazardCriteria.hazardousEnergyJ) ? 1 : 0
                )
            }
            let grams = 1000 * pieceKg
            return (
                count, skin(grams: grams, speedMS: speedMS),
                trunkShare * bodyWall(grams: grams, speedMS: speedMS)
            )
        }
    }

    /// Over the first `roomDepthM` of the room behind a façade glazed over `glazed` of its area, the
    /// share of it within which a person is hurt, and hurt severely, by the glass `thrown` (each pane
    /// type's, as a share of the façade): at each depth the chance of standing in a window's path,
    /// `glazed`, times `1 − exp(−Σ strikes × chance / glazed)` over the throws that reach it there
    /// (the window's own glass, not the façade's average), averaged over the depth.
    public static func zone(_ thrown: [Thrown], glazed: Double = 1) -> (hurt: Double, severe: Double) {
        let g = min(max(glazed, 0), 1)
        let parts = thrown.map { ($0.reachM, $0.strikes) }.filter { $0.1.count > 0 && $0.0 > 0 }
        guard !parts.isEmpty, g > 0 else { return (0, 0) }
        // Between one reach and the next, the throws reaching further all strike.
        let edges = Array(Set(parts.map { min($0.0, roomDepthM) } + [0])).sorted()
        var hurt = 0.0
        var severe = 0.0
        for k in 1..<edges.count {
            let (from, to) = (edges[k - 1], edges[k])
            var h = 0.0
            var s = 0.0
            for (reach, strike) in parts where reach >= to {
                h += strike.count * strike.hurt
                s += strike.count * strike.severe
            }
            hurt += (to - from) * g * (1 - exp(-h / g))
            severe += (to - from) * g * (1 - exp(-s / g))
        }
        return (hurt / roomDepthM, severe / roomDepthM)
    }

    /// The pieces a pane of `pane`'s type in `mix` flies as: whole, or as `DebrisLaunch.piece`'s
    /// shards; their mass (kg) and area (m²).
    static func pieces(_ mix: GlazingMix, _ pane: GlazingMix.Pane, whole: Bool) -> (kg: Double, m2: Double) {
        let thickness = Double(mix.glassAlone(pane))
        let glass = 2500.0
        if whole {
            let area = Double(pane.areaM2)
            return (
                glass * thickness * area + SecurityFilm.density * (mix.glass?.film?.thickness ?? 0) * area,
                area
            )
        }
        let material: EnvelopeComponentDamage.Material =
            mix.glass?.toughened == true ? .toughenedGlass : .annealedGlass
        let piece = DebrisLaunch.piece(material, thickness: thickness, span: 0, pane: nil)
        let area = Double(piece.x * piece.y)
        return (glass * thickness * area, area)
    }
}
