import Foundation
import Testing
import simd

@testable import BlastModel

/// `EnvelopeConstruction.masonryArching`: unreinforced masonry walls arching between their
/// returns (emmettl/bombcad-work#57).
@Suite("Masonry arching between returns")
struct MasonryArchingTests {
    static let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000057")!

    static func brick(_ thickness: Float, arching: Bool?) -> EnvelopeConstruction {
        var construction = EnvelopeConstruction(
            objectID: owner, walls: .unreinforcedMasonry, wallThicknessM: thickness, source: .user,
            detail: "brick")
        construction.masonryArching = arching
        return construction
    }

    /// A triangular pulse on a wall 5 m wide, from `bottom` to `top`, its edges `edges`.
    static func load(
        peak: Double, impulse: Double, bottom: Float, top: Float, edges: [Bool]?,
        kind: EnvelopeComponentLoad.Kind = .wall
    )
        -> EnvelopeComponentLoad
    {
        let bin = 2e-4
        let duration = 2 * impulse / peak
        let pressures = (0..<2500).map { k -> Double in
            let t = (Double(k) + 0.5) * bin
            return t < duration ? peak * (1 - t / duration) : 0
        }
        return EnvelopeComponentLoad(
            id: "front", owner: owner, kind: kind,
            region: Box(min: SIMD3(0, 0, bottom), max: SIMD3(0.2, 5, top)), axis: 0, binS: bin,
            outerPa: pressures, innerPa: pressures.map { _ in 0 }, supportEdges: edges)
    }

    @Test(
        "The arch takes hold from cracking to 1.7 f t² (1 − x/t)² / L² at the struts' crushing strain, then falls to nothing"
    )
    func backbone() {
        var masonry = StructureMaterial.masonry
        masonry.steel = nil
        let t = 0.215
        let system = EnvelopePanel.unreinforcedMasonryOneWay(
            thickness: t, material: masonry, span: 5, edges: .fixed)
        let arched = EnvelopePanel.arching(system, thickness: t, material: masonry, span: 5)
        let q0 = 1.7 * 8e6 * t * t / 25
        func curve(_ x: Double) -> Double { q0 * (1 - x / t) * (1 - x / t) }
        // The wall's own cracking point first, unchanged.
        #expect(arched.backbone[0] == system.backbone[0])
        // The peak where struts t/2 deep have shortened by 0.85 f / E: 66 mm for 5 m.
        let peakAt = 0.85 * 8e6 / 6e9 * 25 / (2 * t)
        let peak = arched.backbone.max { $0.y < $1.y }!
        #expect(abs(peak.x - peakAt) < 1e-9 && abs(peak.y - curve(peakAt)) / curve(peakAt) < 1e-9)
        #expect(arched.backbone.last == SIMD2(t, 0))
        // The energy to fall: the rise, and the curve beyond (the polygon over its points).
        var energy = 0.0
        var previous = SIMD2<Double>(0, 0)
        for point in arched.backbone {
            energy += (point.x - previous.x) * (point.y + previous.y) / 2
            previous = point
        }
        let first = system.backbone[0]
        let expected =
            first.x * first.y / 2 + (first.y + curve(peakAt)) / 2 * (peakAt - first.x)
            + q0 * t / 3 * pow(1 - peakAt / t, 3)
        #expect(abs(energy - expected) / expected < 0.02, "\(energy) against \(expected)")
        // Weaker than the wall's own resistance, nothing changes: a leaf 30 m between returns.
        let own = EnvelopePanel.unreinforcedMasonryOneWay(
            thickness: 0.1025, material: masonry, span: 3, edges: .fixed)
        #expect(EnvelopePanel.arching(own, thickness: 0.1025, material: masonry, span: 30) == own)
    }

    @Test("Off, nothing changes: no key in the JSON, and every route judges as before")
    func offIsUnchanged() throws {
        let json = String(decoding: try JSONEncoder().encode(Self.brick(0.215, arching: nil)), as: UTF8.self)
        #expect(!json.contains("masonryArching"))
        let loads = [
            Self.load(peak: 196e3, impulse: 793, bottom: 0, top: 2.65, edges: [true, true, true, false]),
            Self.load(peak: 196e3, impulse: 793, bottom: 2.65, top: 5.3, edges: [true, true, false, false]),
            Self.load(peak: 50e3, impulse: 300, bottom: 0, top: 3, edges: nil),
            Self.load(peak: 50e3, impulse: 300, bottom: 0, top: 3, edges: [false, false, true, true]),
        ]
        for load in loads {
            let none = EnvelopeDamageAssessment.assess(
                load, construction: Self.brick(0.215, arching: nil), buildingTop: 5.3)
            let off = EnvelopeDamageAssessment.assess(
                load, construction: Self.brick(0.215, arching: false), buildingTop: 5.3)
            #expect(none?.rotationDeg == off?.rotationDeg && none?.levels == off?.levels)
            #expect(
                EnvelopeWallFailure.make(load, construction: Self.brick(0.215, arching: false))?.systems.map(
                    \.sdof)
                    == EnvelopeWallFailure.make(load, construction: Self.brick(0.215, arching: nil))?.systems
                    .map(\.sdof))
        }
    }

    @Test(
        "On, a solid one-brick front between party walls stands at 16.9 m from 96 kg; a cavity leaf does not")
    func terracedFront() throws {
        // Kingery–Bulmash at 16.9 m from 96 kg: reflected 196 kPa, 793 Pa s over the front.
        let upper = Self.load(
            peak: 196e3, impulse: 793, bottom: 2.65, top: 5.3, edges: [true, true, false, false])
        let ground = Self.load(
            peak: 196e3, impulse: 793, bottom: 0, top: 2.65, edges: [true, true, true, false])
        for load in [upper, ground] {
            let off = try #require(
                EnvelopeDamageAssessment.assess(
                    load, construction: Self.brick(0.215, arching: nil), buildingTop: 5.3))
            let on = try #require(
                EnvelopeDamageAssessment.assess(
                    load, construction: Self.brick(0.215, arching: true), buildingTop: 5.3))
            let leaf = try #require(
                EnvelopeDamageAssessment.assess(
                    load, construction: Self.brick(0.1025, arching: true), buildingTop: 5.3))
            #expect(off.levels.upperBound == .failed)
            #expect(on.levels.upperBound == .heavy, "\(on.rotationDeg)")
            #expect(leaf.levels.upperBound == .failed)
            // The venting route agrees: the solid front does not lose its resistance.
            let failure = try #require(
                EnvelopeWallFailure.make(load, construction: Self.brick(0.215, arching: true)))
            #expect(!failure.cantilever && failure.systems.allSatisfy { $0.sdof.ultimateResistance > 10e3 })
        }
    }

    @Test("A freestanding wall, a wall with an upright edge free, a roof and other constructions do not arch")
    func whereItDoesNotApply() throws {
        let freestanding = Self.load(
            peak: 50e3, impulse: 300, bottom: 0, top: 2, edges: [false, false, true, false])
        let oneSide = Self.load(
            peak: 50e3, impulse: 300, bottom: 0, top: 3, edges: [true, false, true, true])
        let roof = Self.load(peak: 50e3, impulse: 300, bottom: 0, top: 3, edges: nil, kind: .roof)
        // A map building's façade strip: its sides' holding is the panel's assumption.
        let facade = Self.load(
            peak: 196e3, impulse: 793, bottom: 0, top: 3, edges: [false, false, true, false], kind: .facade)
        for load in [freestanding, oneSide, roof, facade] {
            let off = EnvelopeDamageAssessment.assess(
                load, construction: Self.brick(0.215, arching: nil), buildingTop: 3)
            let on = EnvelopeDamageAssessment.assess(
                load, construction: Self.brick(0.215, arching: true), buildingTop: 3)
            #expect(off?.rotationDeg == on?.rotationDeg && off?.levels == on?.levels)
        }
        var concrete = EnvelopeConstruction(objectID: Self.owner, source: .user, detail: "rc")
        let wall = Self.load(peak: 196e3, impulse: 793, bottom: 0, top: 3, edges: [true, true, true, true])
        let plain = EnvelopeDamageAssessment.assess(wall, construction: concrete)
        concrete.masonryArching = true
        #expect(
            EnvelopeDamageAssessment.assess(wall, construction: concrete)?.rotationDeg == plain?.rotationDeg)
    }

    @Test("The option shows in the standing")
    func standing() {
        #expect(StandingTable.entry(for: .masonryArching).affects == [.envelopeDamage])
    }
}
