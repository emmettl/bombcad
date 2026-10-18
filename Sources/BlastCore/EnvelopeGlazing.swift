import Foundation

/// The windows a façade holds when nothing places them pane by pane (a map building's storeys):
/// a mix of annealed pane types, each a share of the glazed area, and the share of the façade that
/// is glazed. Each pane breaks with E1300's probability under the façade's load
/// (`GlassStrength.probability`), so a façade breaks by degrees: a fraction of its panes, and a
/// chance that any one does.
public struct GlazingMix: Codable, Hashable, Sendable {
    public struct Pane: Codable, Hashable, Sendable {
        public var widthM: Float
        public var heightM: Float
        public var thicknessM: Float
        /// Its share of the glazed area.
        public var share: Float

        public init(widthM: Float, heightM: Float, thicknessM: Float, share: Float) {
            self.widthM = widthM
            self.heightM = heightM
            self.thicknessM = thicknessM
            self.share = share
        }

        public var areaM2: Float { widthM * heightM }
    }

    /// What the mix stands for, in words.
    public var name: String
    public var panes: [Pane]
    /// The glazed share of the façade's area.
    public var glazedFraction: Float

    public init(name: String, panes: [Pane], glazedFraction: Float) {
        self.name = name
        self.panes = panes
        self.glazedFraction = glazedFraction
    }

    // No survey of a city's glazing by building was found (Beirut's own: the army's count of
    // 550,000 m² of glass broken, not by pane). These mixes are assumptions, stated as such: older
    // buildings with small panes of thin annealed glass (4 mm, the least that windows were made of,
    // and the worst case, as Monk and Clubley take it), newer ones with larger panes of 6 mm, and
    // tall or commercial buildings with large ones of 6–10 mm, all annealed (toughened and
    // laminated glass, which a modern tower would have, is not modelled).

    /// Low buildings of three storeys or so, taken as older: small sash panes and a glazed door.
    public static let olderLowRise = GlazingMix(
        name: "older low-rise (assumed)",
        panes: [
            Pane(widthM: 0.6, heightM: 1.2, thicknessM: 0.004, share: 0.6),
            Pane(widthM: 0.9, heightM: 1.5, thicknessM: 0.004, share: 0.3),
            Pane(widthM: 1.0, heightM: 2.2, thicknessM: 0.006, share: 0.1),
        ], glazedFraction: 0.15)

    /// Blocks of flats: windows of 4 and 6 mm and balcony doors.
    public static let apartments = GlazingMix(
        name: "apartments (assumed)",
        panes: [
            Pane(widthM: 0.9, heightM: 1.4, thicknessM: 0.004, share: 0.4),
            Pane(widthM: 1.2, heightM: 1.5, thicknessM: 0.006, share: 0.4),
            Pane(widthM: 1.0, heightM: 2.2, thicknessM: 0.006, share: 0.2),
        ], glazedFraction: 0.25)

    /// Tall, commercial and office buildings: large panes, thicker glass, more of the façade.
    public static let commercial = GlazingMix(
        name: "tall or commercial (assumed)",
        panes: [
            Pane(widthM: 1.5, heightM: 2.0, thicknessM: 0.006, share: 0.5),
            Pane(widthM: 1.5, heightM: 2.5, thicknessM: 0.008, share: 0.3),
            Pane(widthM: 2.0, heightM: 3.0, thicknessM: 0.010, share: 0.2),
        ], glazedFraction: 0.4)

    /// Sheds and warehouses: a few small panes.
    public static let industrial = GlazingMix(
        name: "industrial (assumed)",
        panes: [Pane(widthM: 0.6, heightM: 1.0, thicknessM: 0.004, share: 1)], glazedFraction: 0.05)

    /// A map building's mix by its `building` tag and its height (m): the tag where it says, the
    /// height otherwise (to 10 m older low-rise, to 30 m apartments, taller commercial).
    public static func forMapBuilding(kind: String, height: Float) -> GlazingMix {
        switch kind {
        case "industrial", "warehouse", "shed", "hangar", "barn", "garage", "garages", "storage_tank", "silo":
            return .industrial
        case "commercial", "office", "retail", "hotel", "government", "government_office", "hospital":
            return .commercial
        case "apartments", "residential":
            return height > 30 ? .commercial : .apartments
        case "house", "detached", "terrace", "semidetached_house":
            return .olderLowRise
        default:
            return height <= 10 ? .olderLowRise : height <= 30 ? .apartments : .commercial
        }
    }

    /// The glass of a façade region `areaM2` large under the net pressures (Pa, in bins `binS`
    /// long): the panes expected in it and expected to break, and the log of the chance that none
    /// does. A pane type's panes break with E1300's probability for the 60 s stress its load
    /// gives it on Moore's large-deflection plate (simply supported, the whole pane at its largest
    /// stress); one deflected past ten thicknesses lets go of its frame, and breaks.
    public func breakage(netPa pressures: [Double], binS: Double, areaM2: Double) -> GlazingBreakage {
        var result = GlazingBreakage()
        let peak = pressures.map(abs).max() ?? 0
        for pane in panes where pane.areaM2 > 0 && pane.share > 0 {
            let count = Double(glazedFraction * pane.share) * areaM2 / Double(pane.areaM2)
            guard count > 0 else { continue }
            result.panes += count
            result.glazedM2 += count * Double(pane.areaM2)
            // Under 50 Pa no pane comes near breaking.
            guard peak > 50 else { continue }
            let a = Double(min(pane.widthM, pane.heightM))
            let b = Double(max(pane.widthM, pane.heightM))
            let system = EnvelopeDamageAssessment.unbreakablePane(
                thickness: Double(pane.thicknessM), a: a, b: b)
            let response = system.response(pressures: pressures, step: binS)
            let probability =
                response.lostResistanceAt != nil
                ? 1 : GlassStrength.probability(stress: response.equivalentStress ?? 0, area: a * b)
            result.broken += count * probability
            result.brokenM2 += count * probability * Double(pane.areaM2)
            result.logNoneBroken += count * log(max(1 - probability, 1e-300))
        }
        return result
    }
}

/// Panes of a façade, or of a building's façades together, and how many break.
public struct GlazingBreakage: Codable, Hashable, Sendable {
    /// Panes expected, and expected to break.
    public var panes = 0.0
    public var broken = 0.0
    /// The glass in them and the glass expected broken, m².
    public var glazedM2 = 0.0
    public var brokenM2 = 0.0
    /// The log of the chance that none breaks (sums over regions, as their panes break apart).
    public var logNoneBroken = 0.0

    public init() {}

    /// The fraction of panes broken.
    public var fraction: Double { panes > 0 ? broken / panes : 0 }
    /// The chance that at least one pane breaks.
    public var anyBroken: Double { 1 - exp(logNoneBroken) }

    public static func + (a: Self, b: Self) -> Self {
        var sum = a
        sum.panes += b.panes
        sum.broken += b.broken
        sum.glazedM2 += b.glazedM2
        sum.brokenM2 += b.brokenM2
        sum.logNoneBroken += b.logNoneBroken
        return sum
    }
}

/// One side of a building's façades (the strips facing `outward` along `axis`), its glass.
public struct FacadeGlass: Codable, Hashable, Sendable {
    public var axis: Int
    public var outward: Int
    public var glass: GlazingBreakage

    public init(axis: Int, outward: Int, glass: GlazingBreakage) {
        self.axis = axis
        self.outward = outward
        self.glass = glass
    }
}

extension GlassStrength {
    /// The chance that a pane of `area` (m²) breaks under a stress equivalent to `stress` (Pa)
    /// held for 60 s, by the flaw model with the whole pane at that stress: 1 − exp(−k A σᵐ).
    public static func probability(stress: Double, area: Double) -> Double {
        guard stress > 0 else { return 0 }
        return 1 - exp(-flawConstant * area * pow(stress, weibullModulus))
    }
}
