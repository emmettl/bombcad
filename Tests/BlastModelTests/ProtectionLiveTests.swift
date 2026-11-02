import Foundation
import Testing
import simd

@testable import BlastModel

/// Protective design you can push around (emmettl/bombcad-work#117): the people hurt by the glass
/// thrown into their rooms, a barrier wall as a what-if with its raster laid out again, and the
/// barrier's own shielding term.
@Suite("Protections live: glass thrown, barriers and their shelter")
struct ProtectionLiveTests {
    // MARK: The glass thrown

    /// Bowen et al. (1956), Table 3.1: mass (g), speed (ft/s), the shots' per cent through the skin and
    /// through the abdominal wall.
    static let bowen: [(grams: Double, feet: Double, skin: Double, wall: Double)] = [
        (0.0543, 487, 52, 36.0), (0.0543, 858, 100, 88.0), (0.131, 205, 12, 4.0), (0.131, 262, 52, 0),
        (0.131, 456, 88, 60.0), (0.131, 649, 100, 92.3), (0.318, 192, 54, 11.5), (0.318, 305, 82, 62.5),
        (0.318, 419, 95, 63.4), (0.769, 200, 62, 25.0), (0.769, 297, 88, 60.0), (0.769, 418, 100, 88.0),
        (1.895, 170, 33, 14.3), (1.895, 240, 79, 68.4), (1.895, 360, 100, 100), (1.895, 387, 100, 100),
    ]

    @Test("Bowen et al.'s Equation 13 gives their body-wall shots, and the skin factor their skin column")
    func bowenCriteria() {
        func rms(
            _ f: (Double, Double) -> Double,
            _ observed: KeyPath<(grams: Double, feet: Double, skin: Double, wall: Double), Double>
        ) -> Double {
            let errors = Self.bowen.map { f($0.grams, $0.feet * 0.3048) - $0[keyPath: observed] / 100 }
            return (errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count)).squareRoot()
        }
        // Their standard error of estimate, 0.0745; the skin column on the same form, 0.10.
        #expect(rms(GlassInjury.bodyWall, \.wall) < 0.08)
        #expect(rms(GlassInjury.skin, \.skin) < 0.11)
        // Nought at the threshold speed, 329 / (log m + 2.3054) ft/s; one at 3.05 times it.
        let threshold = 329 / (log10(1.0) + 2.3054) * 0.3048
        #expect(GlassInjury.bodyWall(grams: 1, speedMS: threshold * 0.99) == 0)
        #expect(GlassInjury.bodyWall(grams: 1, speedMS: threshold * 3.1) == 1)
        #expect(GlassInjury.skin(grams: 1, speedMS: threshold) > 0.2)
    }

    @Test("The room's zone: nothing thrown, nothing; faster and further, more; a held pane's energy")
    func zone() {
        #expect(GlassInjury.zone([]) == (0, 0))
        func shards(_ speed: Double, share: Double = 0.2) -> GlassInjury.Thrown {
            GlassInjury.Thrown(
                areaShare: share, speedMS: speed, reachM: speed * 0.57, pieceKg: 0.025, pieceM2: 0.0025,
                whole: false)
        }
        let slow = GlassInjury.zone([shards(10)])
        let fast = GlassInjury.zone([shards(40)])
        #expect(slow.hurt < fast.hurt && slow.severe <= fast.severe)
        #expect(fast.hurt > 0.9 && fast.hurt <= 1)
        // Lands 2.3 m in: a person further is not reached.
        #expect(abs(GlassInjury.zone([shards(4)]).hurt) < 1e-12)
        // A whole laminated pane, 15 kg at 2 m/s (30 J): it hurts, not seriously.
        let pane = GlassInjury.Thrown(
            areaShare: 0.2, speedMS: 2, reachM: 6, pieceKg: 15, pieceM2: 1.5, whole: true)
        let whole = GlassInjury.zone([pane])
        #expect(whole.hurt > 0 && whole.severe == 0)
    }

    /// A 20 × 10 m block of flats 12 m high, `distance` m east of a 100 kg charge.
    func block(distance: Float = 30, glass: LiveResponse.Glass? = nil) throws -> Scenario {
        var scene = Scenario(
            name: "Block", domainSize: SIMD3(300, 200, 60), boxes: [],
            charge: Charge(mass: 100, position: SIMD3(50, 100, 0)))
        let x = 50 + distance
        let id = try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(x, 95, 0), max: SIMD3(x + 20, 105, 12))]), name: "Block")
        var construction = EnvelopeConstruction.assumed(objectID: id)
        construction.glazing = .apartments
        construction.use = .residential
        scene.envelopeConstructions = [construction]
        return LiveResponse.WhatIf(glass: glass).applied(to: scene)
    }

    func look(_ scene: Scenario) -> FacadeLoadSurrogate.Prepared.Look {
        FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2).look(
            charge: scene.charge.position, mass: Double(scene.charge.mass),
            constructions: { scene.envelopeConstruction(for: $0) },
            uncertainty: FacadeLoadSurrogate.Uncertainty(samples: 20))
    }

    @Test("Film and laminated glass throw less into the rooms; the people thrown at fall, Kummer's do not")
    func filmHelpsPeople() throws {
        let plain = try block()
        let filmed = try block(glass: .filmed(.mils(8, anchorage: .wetGlazed)))
        let laminated = try block(glass: .laminated(.facade))
        let (a, b, c) = (look(plain), look(filmed), look(laminated))
        let facing = { (look: FacadeLoadSurrogate.Prepared.Look) in
            look.glass.first { $0.axis == 0 && $0.outward == -1 }!
        }
        #expect(facing(a).thrownHurt! > 0.1, "\(facing(a))")
        #expect(facing(b).thrownHurt! < facing(a).thrownHurt! / 2, "\(facing(b))")
        #expect(facing(c).thrownHurt! < facing(a).thrownHurt! / 2, "\(facing(c))")
        func people(
            _ scene: Scenario, _ look: FacadeLoadSurrogate.Prepared.Look, _ model: OccupantInjury.GlassModel
        )
            -> OccupantInjury.Estimate
        {
            var assumptions = OccupantInjury.Assumptions()
            assumptions.glass = model
            return OccupantInjury.estimate(
                scene: scene, glass: look.glass, structure: look.structure, charge: scene.charge.position,
                mass: Double(scene.charge.mass), assumptions: assumptions)
        }
        let thrown = OccupantInjury.compare(
            people(filmed, b, .thrownGlass), against: people(plain, a, .thrownGlass))!
        let panes = OccupantInjury.compare(
            people(filmed, b, .panesBroken), against: people(plain, a, .panesBroken))!
        #expect(thrown.hurt < -0.5, "\(thrown)")
        #expect(abs(panes.hurt) < 0.05, "\(panes)")
        #expect(people(plain, a, .thrownGlass).glassFellBack == 0)
    }

    @Test("Without the glass thrown on its sides, a building keeps Kummer's, and says so")
    func fallsBack() throws {
        let scene = try block()
        var sides = look(scene).glass
        for k in sides.indices { sides[k].thrownHurt = nil }
        var thrown = OccupantInjury.Assumptions()
        thrown.glass = .thrownGlass
        let a = OccupantInjury.estimate(
            scene: scene, glass: sides, structure: [], charge: scene.charge.position, mass: 100,
            assumptions: thrown)
        let b = OccupantInjury.estimate(
            scene: scene, glass: sides, structure: [], charge: scene.charge.position, mass: 100)
        #expect(a.glassFellBack == 1)
        #expect(abs(a.expected - b.expected) < 1e-9)
    }

    @Test("Assumptions saved before the glass model read as Kummer's")
    func decodesOld() throws {
        let old = #"{"time":"night","densityScale":1,"untaggedUse":"residential"}"#
        let read = try JSONDecoder().decode(OccupantInjury.Assumptions.self, from: Data(old.utf8))
        #expect(read.glass == .panesBroken && read.time == .night)
    }

    // MARK: The barrier

    @Test("A what-if's barrier is put in the scene; the layout with it laid out again is a fresh one's")
    func barrierWhatIf() throws {
        let scene = try block(distance: 40)
        let wall = LiveResponse.WhatIf.Barrier.across(
            from: SIMD2(50, 100), to: SIMD2(90, 100), at: 0.5, lengthM: 30, heightM: 3)
        #expect(!wall.alongX)
        let whatIf = LiveResponse.WhatIf(barrier: wall)
        #expect(!whatIf.isEmpty && !whatIf.changesConstructions)
        let walled = whatIf.applied(to: scene)
        #expect(walled.boxes.count == scene.boxes.count + 1)
        #expect(walled.envelopeConstructions == scene.envelopeConstructions)
        #expect(whatIf.label.contains("barrier 3 m tall"))
        let fresh = FacadeLoadSurrogate.Prepared(scene: walled, cellSize: 2)
        let moved = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 2).withBlocks(walled.boxes)
        let charge = scene.charge.position
        let a = fresh.estimate(charge: charge, mass: 100)
        let b = moved.estimate(charge: charge, mass: 100)
        #expect(a.features == b.features)
        #expect(a.features.contains { $0.edgeIsBarrier })
        #expect(fresh.rasterKey != moved.rasterKey)
    }

    @Test("The barrier's shelter: nothing without a barrier; behind one, the load falls, most close behind")
    func barrierShelter() throws {
        let scene = try block(distance: 30)
        var walled = scene
        try walled.addBarrier(from: SIMD2(65, 85), to: SIMD2(65, 115), height: 3)
        let adopted = FacadeLoadSurrogate.Coefficients.deepCityOutline
        let sheltered = FacadeLoadSurrogate.Coefficients.deepCityOutlineBarriers
        // No barrier in the scene: the same to the bit.
        let open = FacadeLoadSurrogate.Prepared(scene: scene, cellSize: 1).estimate(
            charge: scene.charge.position, mass: 100)
        for f in open.features {
            #expect(!f.edgeIsBarrier)
            #expect(
                FacadeLoadSurrogate.predict(f, mass: 100, cellSize: 1, coefficients: adopted)
                    == FacadeLoadSurrogate.predict(f, mass: 100, cellSize: 1, coefficients: sheltered))
        }
        let behind = FacadeLoadSurrogate.Prepared(scene: walled, cellSize: 1).estimate(
            charge: walled.charge.position, mass: 100)
        var lower = 0
        var low: (height: Double, ratio: Double)?
        var high: (height: Double, ratio: Double)?
        for f in behind.features where f.edgeIsBarrier && f.cosIncidence > 0.5 {
            let a = FacadeLoadSurrogate.predict(f, mass: 100, cellSize: 1, coefficients: adopted)
            let b = FacadeLoadSurrogate.predict(f, mass: 100, cellSize: 1, coefficients: sheltered)
            #expect(b.peakPa <= a.peakPa && b.impulsePaS <= a.impulsePaS)
            if b.peakPa < 0.95 * a.peakPa { lower += 1 }
            let ratio = b.peakPa / a.peakPa
            if low == nil || f.heightM < low!.height { low = (f.heightM, ratio) }
            if high == nil || f.heightM > high!.height { high = (f.heightM, ratio) }
        }
        #expect(lower > 0)
        // The lowest storey behind a 3 m wall is sheltered more than the top.
        if let low, let high { #expect(low.ratio < high.ratio, "\(low) \(high)") }
        #expect(FacadeLoadSurrogate.TermSet.deepCityOutlineBarriers.coefficients.barrier == .fitted)
        #expect(FacadeLoadSurrogate.TermSet.adopted.coefficients.barrier == nil)
    }

    @Test("ITU-R P.526's knife-edge loss: 6 dB at the line, nothing well below it")
    func knifeEdge() {
        let ln10 = log(10.0)
        #expect(abs(FacadeLoadSurrogate.Coefficients.BarrierShielding.loss(0) - 6.0 / 20 * ln10) < 0.05)
        #expect(FacadeLoadSurrogate.Coefficients.BarrierShielding.loss(-1) == 0)
        #expect(
            FacadeLoadSurrogate.Coefficients.BarrierShielding.loss(2)
                > FacadeLoadSurrogate.Coefficients.BarrierShielding.loss(1))
    }

    // MARK: The explorer's words

    @Test("The explorer's protections: a stand-off for the square and the street, and the wall's figures")
    func explorerWords() {
        #expect(ExplorerScene.square.standOff?.building == "The glass office")
        #expect(ExplorerScene.street.standOff != nil)
        #expect(ExplorerScene.beirut.standOff == nil)
        #expect(ExplorerWords.barrierHowSure(shelter: true).contains("19 places in 20"))
        #expect(ExplorerWords.barrierHowSure(shelter: false).contains("places in 10"))
        #expect(
            ExplorerWords.standOffText(42, phrase: "from the glass office")
                == "The charge is kept 40 m from the glass office.")
    }
}
