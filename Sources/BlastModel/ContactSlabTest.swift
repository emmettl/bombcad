import Foundation
import simd

/// Reinforced concrete slabs under contact charges: M. A. Hupfauf, *Secondary debris resulting
/// from concrete slabs subjected to contact detonations*, PhD thesis, Universität der Bundeswehr
/// München, 2024, and M. Hupfauf and N. Gebbeken, *Advances in Structural Engineering* 25(7)
/// (2022) 1373–1385. Both CC BY 4.0; the data are in `Fixtures/Hupfauf/slabs.json`.
///
/// Slabs 2.0 × 2.0 m, 20, 25 or 30 cm thick, of concrete of 42.7 MPa cube strength and
/// 2,220 kg/m³ with 8 mm aggregate, reinforced in both faces both ways with 10 mm B500B bars at
/// 150 mm under 35 mm of cover, stood upright between steel beams 20 cm wide on both faces at
/// two opposite edges (1.6 m clear). Cylinders of 1000, 1500 and 2000 g of SEMTEX 10, 103 mm
/// across, were fired with one end flush with the centre of a face; high-speed cameras tracked
/// the debris off the other face, and the craters were scanned.
///
/// Assumed: the charge is the sphere of TNT the thesis gives as equivalent in its
/// energy-equivalent impulse (1,550, 1,841 and 2,058 g), touching the slab; the cylinder strength
/// is 0.8 of the cube's; the beams hold both faces still along those edges; the bars break at
/// 15% plastic strain, as for the close-in slabs.
public enum ContactSlabTest {
    public struct Test: Sendable {
        public var name: String
        public var thickness: Float
        /// SEMTEX 10 (kg) and the TNT sphere the thesis takes as equivalent (kg).
        public var semtex: Float
        public var tntSphere: Float
        public var breach: Bool
        /// Measured: the debris's fastest velocity off the protective face (m/s), the spall
        /// crater's diameter on that face (m) and the debris's mass (kg), one per shot.
        public var tipVelocity: [Float]
        public var spallDiameter: [Float]
        public var debrisMass: [Float]

        /// T / W^(1/3), cm g^(-1/3), as the thesis scales it.
        public var scaledThickness: Float { thickness * 100 / cbrt(tntSphere * 1000) }
        /// The thesis's fits over all its slabs: the debris's fastest velocity (m/s) and the
        /// width of its velocity profile (m).
        public var fittedTipVelocity: Float { 292 / scaledThickness - 98 }
        public var fittedWidth: Float { (57 + 45 * scaledThickness) / 1000 }

        /// The thesis's profile of the debris's velocity over the radius r (m): a pseudo-Voigt
        /// curve, a quarter Lorentzian of width σ/2 and three quarters Gaussian of width σ.
        public func fittedVelocity(at r: Float) -> Float {
            let sigma = fittedWidth
            let gamma = sigma / 2
            let lorentz = gamma * gamma / (gamma * gamma + r * r)
            let gauss = exp(-r * r / (2 * sigma * sigma))
            return fittedTipVelocity * (0.25 * lorentz + 0.75 * gauss)
        }
    }

    /// One slab of each kind (thickness and charge), from the fifteen without steel fibres.
    public static let tests: [Test] = [
        Test(
            name: "SN174", thickness: 0.20, semtex: 1.5, tntSphere: 1.841, breach: true,
            tipVelocity: [84, 75.9],
            spallDiameter: [0.703, 0.682], debrisMass: [50.0, 47.3]),
        Test(
            name: "SN142", thickness: 0.20, semtex: 1.0, tntSphere: 1.550, breach: true,
            tipVelocity: [72.5, 69],
            spallDiameter: [0.659, 0.625], debrisMass: [41.0, 37.3]),
        Test(
            name: "SN144", thickness: 0.25, semtex: 2.0, tntSphere: 2.058, breach: true,
            tipVelocity: [55.5, 46.4],
            spallDiameter: [0.810, 0.882], debrisMass: [70.3, 63.7]),
        Test(
            name: "SN128", thickness: 0.25, semtex: 1.5, tntSphere: 1.841, breach: true,
            tipVelocity: [46, 41.5],
            spallDiameter: [0.630, 0.741], debrisMass: [52.5, 45.6]),
        Test(
            name: "SN175", thickness: 0.25, semtex: 1.0, tntSphere: 1.550, breach: false, tipVelocity: [35],
            spallDiameter: [0.785], debrisMass: [48.3]),
        Test(
            name: "SN147", thickness: 0.30, semtex: 2.0, tntSphere: 2.058, breach: false,
            tipVelocity: [25, 23.4],
            spallDiameter: [0.961, 0.820], debrisMass: [64.8, 38.7]),
        Test(
            name: "SN145", thickness: 0.30, semtex: 1.5, tntSphere: 1.841, breach: false,
            tipVelocity: [22.5, 19],
            spallDiameter: [0.913, 0.807], debrisMass: [34.7, 57.8]),
        Test(
            name: "SN131", thickness: 0.30, semtex: 1.0, tntSphere: 1.550, breach: false,
            tipVelocity: [15, 14.7],
            spallDiameter: [0.829, 0.854], debrisMass: [41.4, 39.2]),
    ]

    /// Air below the slab (for the debris) and above it (for the charge), and around its edges.
    package static let below: Float = 0.6
    package static let above: Float = 0.5
    package static let margin: Float = 0.2
    package static let plan: Float = 2.0
    package static let supportStrip: Float = 0.2

    /// Elements lie on a lattice from the domain's corner, so the slab is placed on it.
    static func onLattice(_ length: Float, _ h: Float) -> Float { (length / h).rounded() * h }

    public static func slab(_ test: Test, elementSize h: Float) -> Box {
        let side = onLattice(margin, h)
        let base = onLattice(below, h)
        return Box(
            min: SIMD3(side, side, base), max: SIMD3(side + plan, side + plan, base + test.thickness))
    }

    /// The protective face's centre, under the charge.
    public static func centre(_ test: Test, elementSize h: Float) -> SIMD3<Float> {
        let slab = slab(test, elementSize: h)
        return SIMD3((slab.min.x + slab.max.x) / 2, (slab.min.y + slab.max.y) / 2, slab.min.z)
    }

    /// C30/37 as measured: 42.7 MPa on cubes (34 MPa on cylinders), 2,220 kg/m³, 8 mm aggregate,
    /// strengthening with strain rate; B500B bars.
    public static func material() -> StructureMaterial {
        let steel = SteelProperties(
            yieldStress: 500e6, ultimateStress: 540e6, ultimateStrain: 0.05, ruptureStrain: 0.15)
        var material = StructureMaterial.concrete(
            name: "C30/37", compressiveStrength: 0.8 * 42.7e6, density: 2220, steel: steel)
        material.aggregateSize = 0.008
        material.rateDependent = true
        return material
    }

    public static func scenario(_ test: Test, elementSize: Float? = nil) -> Scenario {
        let h = elementSize ?? test.thickness / 12
        let slab = slab(test, elementSize: h)
        var model = StructureModel(solids: [slab], material: material(), elementSize: h, fixedBase: false)
        // Two layers of 10 mm bars at 150 mm in each face, their centres 40 and 50 mm in.
        model.addMat(
            to: slab, thicknessAxis: 2, areaPerMetre: 78.5e-6 / 0.15, depth: 0.045,
            faces: (low: true, high: true))
        let radius = Float(cbrt(3 * Double(test.tntSphere) / (4 * Double.pi * 1600)))
        let top = slab.max.z
        let c = centre(test, elementSize: h)
        let gauges = [
            Gauge("Loaded face, 0.5 m out", at: SIMD3(c.x + 0.5, c.y, top + 0.005)),
            Gauge("Protective face, 0.3 m out", at: SIMD3(c.x + 0.3, c.y, slab.min.z - 0.005)),
        ]
        return Scenario(
            name: "Contact charge \(test.name)",
            domainSize: SIMD3(
                slab.max.x + slab.min.x, slab.max.y + slab.min.y, slab.max.z + above),
            boxes: [], charge: Charge(mass: test.tntSphere, position: SIMD3(c.x, c.y, top + radius)),
            gauges: gauges, structure: model)
    }

    public struct Result: Sendable {
        /// The slab's downward momentum (N s) against time (s), every sample.
        public var momentum: [SIMD2<Double>]
        /// The protective face's downward velocity (m/s) over the radius, in rings `ring` wide,
        /// the median of each ring's nodes, at 0.5, 1 and 2 ms and at the end.
        public var faceProfiles: [(time: Double, velocity: [Float])]
        public var ring: Float
        /// The protective face's downward velocity within two rings of the axis (m/s), the
        /// median of its nodes: the largest it reached, and at the end.
        public var tipVelocity: Float
        public var tipVelocityAtEnd: Float
        /// The radius out to which the protective face has come away at the end (m): it moves
        /// down more than 1 m/s faster than the slab at mid-depth behind it, or its column's
        /// concrete is gone through the thickness.
        public var separatedRadius: Float
        /// The radius out to which the protective face's cover is gone or cracked loose: an
        /// element between the face and the bars removed, left bare, or cracked open across a
        /// plane within 45 degrees of the face's by more than 0.5 mm (m).
        public var spallRadiusByDamage: Float
        /// The loaded face: radius and depth (m) of the region removed or crushed past 1%.
        public var craterRadius: Float
        public var craterDepth: Float
        /// Whether a column of elements under the charge has lost its concrete through the
        /// thickness (removed or left as bare bars).
        public var breached: Bool
        /// Mass of the concrete removed or left as bare bars (kg), in the half of the slab on the
        /// protective side and in the loaded half.
        public var removedProtective: Double
        public var removedLoaded: Double
        public var kineticEnergy: Double
        public var summary: StructureSummary
        public var wallSeconds: Double

        /// The memberwise initialiser, written out so that BlastCore can use it.
        package init(
            momentum: [SIMD2<Double>],
            faceProfiles: [(time: Double, velocity: [Float])],
            ring: Float,
            tipVelocity: Float,
            tipVelocityAtEnd: Float,
            separatedRadius: Float,
            spallRadiusByDamage: Float,
            craterRadius: Float,
            craterDepth: Float,
            breached: Bool,
            removedProtective: Double,
            removedLoaded: Double,
            kineticEnergy: Double,
            summary: StructureSummary,
            wallSeconds: Double
        ) {
            self.momentum = momentum
            self.faceProfiles = faceProfiles
            self.ring = ring
            self.tipVelocity = tipVelocity
            self.tipVelocityAtEnd = tipVelocityAtEnd
            self.separatedRadius = separatedRadius
            self.spallRadiusByDamage = spallRadiusByDamage
            self.craterRadius = craterRadius
            self.craterDepth = craterDepth
            self.breached = breached
            self.removedProtective = removedProtective
            self.removedLoaded = removedLoaded
            self.kineticEnergy = kineticEnergy
            self.summary = summary
            self.wallSeconds = wallSeconds
        }
    }
}
