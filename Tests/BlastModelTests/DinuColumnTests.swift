import Foundation
import Testing
import simd

@testable import BlastModel

/// The CODEC bunker column (`DinuColumnTest`, emmettl/bombcad-work#77): a HEB260 meshed as three
/// shell plates that share their nodes where the web meets the flanges.
@Suite("Dinu's column web close in")
struct DinuColumnTests {
    @Test("The web ends on the flanges' midsurfaces and shares their nodes along both junctions")
    func webMeetsFlanges() throws {
        var settings = DinuColumnTest.Settings()
        settings.elementSize = 0.02
        settings.length = 0.5
        let model = DinuColumnTest.model(settings)
        let mesh = try ShellMesh(model: model)
        let s = settings.section
        let half = (s.depth - s.flange) / 2
        let web = mesh.elements.filter { $0.solid == 2 }
        let flanges = mesh.elements.filter { $0.solid != 2 }
        #expect(web.allSatisfy { $0.axis == 1 && abs($0.thickness - s.web) < 1e-6 })
        #expect(flanges.allSatisfy { $0.axis == 0 && abs($0.thickness - s.flange) < 1e-6 })
        let webNodes = Set(web.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let flangeNodes = Set(flanges.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let shared = webNodes.intersection(flangeNodes)
        // Both junction lines, one node per element edge along the column and one more.
        let along = Int((settings.length / settings.elementSize).rounded()) + 1
        #expect(shared.count == 2 * along)
        for n in shared {
            let p = mesh.positions[Int(n)]
            #expect(abs(abs(p.x - DinuColumnTest.axis.x) - half) < 1e-4)
            #expect(abs(p.y - DinuColumnTest.axis.y) < 1e-4)
        }
        // The web spans the flanges' midsurfaces, the flanges their width.
        let webX = webNodes.map { mesh.positions[Int($0)].x - DinuColumnTest.axis.x }
        #expect(abs((webX.max() ?? 0) - half) < 1e-4 && abs((webX.min() ?? 0) + half) < 1e-4)
        let flangeY = flangeNodes.map { mesh.positions[Int($0)].y - DinuColumnTest.axis.y }
        #expect(abs((flangeY.max() ?? 0) - s.flangeWidth / 2) < 1e-4)
    }

    @Test("The steel as measured: hardening to f_u at 27%, tearing there, S275's rate law")
    func steel() {
        let model = DinuColumnTest.model(DinuColumnTest.Settings())
        let web = model.solidMaterial[2]!
        #expect(web.yieldStress == 407e6 && model.material.yieldStress == 420e6)
        let atElongation =
            web.yieldStress + web.hardeningModulus * (0.27 - web.yieldStress / web.youngsModulus)
        #expect(abs(atElongation - 539e6) < 1e3)
        #expect(web.failureStrain == 0.27)
        #expect(web.rateLaw == .cowperSymonds(d: 40.4, q: 5))
    }

    @Test("Each charge stands its distance off the web's face, 1.25 m up, inside the air")
    func charges() {
        for shot in DinuColumnTest.shots {
            let settings = DinuColumnTest.settings(DinuColumnTest.Settings(), for: shot)
            let c = DinuColumnTest.chargePosition(shot, settings: settings)
            #expect(abs(c.z - 1.25) < 1e-6 && c.z + 0.3 < settings.length)
            let face = DinuColumnTest.axis.y + settings.section.web / 2
            #expect(abs(c.y - face - shot.standoff) < 1e-6)
            let radius = cbrt(3 * shot.charge / (4 * .pi * 1600))
            #expect(c.y + radius + 0.2 < DinuColumnTest.domain(settings).y)
        }
        #expect(abs(DinuColumnTest.shots[1].scaledDistance - 0.164) < 0.001)
        #expect(abs(DinuColumnTest.extent([0.9, 1.1, 1.0], elementSize: 0.01) - 0.21) < 1e-5)
        #expect(DinuColumnTest.extent([], elementSize: 0.01) == 0)
        let reach = DinuColumnTest.reach([0.9, 1.1, 1.0], from: 1.0, elementSize: 0.01)
        #expect(abs(reach.above - 0.105) < 1e-5 && abs(reach.below - 0.105) < 1e-5)
    }

    @Test("The bunker's column: pinned ends, the joint 0.3 m above the charge; the building's clamped")
    func supports() {
        let settings = DinuColumnTest.Settings()
        let a = DinuColumnTest.axis
        let s = settings.section
        let flangeX = a.x + (s.depth - s.flange) / 2
        func held(_ p: SIMD3<Float>) -> [Bool] {
            let r = DinuColumnTest.restraint(at: p, settings: settings)
            return [r.x, r.y, r.z]
        }
        #expect(held(SIMD3(a.x, a.y, 0)) == [true, true, true])
        #expect(held(SIMD3(flangeX, a.y + 0.05, 1.99)) == [true, true, true])
        // The end plates hold the flanges from 1.475 to 1.845 m; the cleat the web from 1.55 to 1.77.
        #expect(held(SIMD3(flangeX, a.y + 0.07, 1.50)) == [true, true, false])
        #expect(held(SIMD3(flangeX, a.y, 1.46)) == [false, false, false])
        #expect(held(SIMD3(a.x + 0.04, a.y, 1.60)) == [false, true, false])
        #expect(held(SIMD3(a.x + 0.07, a.y, 1.60)) == [false, false, false])
        #expect(held(SIMD3(a.x, a.y, 1.25)) == [false, false, false])
        // Gauge S6: 0.2 m below the charge, 80 mm off the centreline.
        #expect(
            DinuColumnTest.gaugeS6(settings).allSatisfy {
                abs($0.z - 1.05) < 1e-5 && abs(abs($0.x - a.x) - 0.08) < 1e-5
            })
        let building = DinuColumnTest.settings(settings, for: DinuColumnTest.shots[2])
        #expect(!building.pinnedEnds && !building.joint && building.length == 2.5)
        #expect(DinuColumnTest.reportedBreachLength(DinuColumnTest.shots[1]) == 0.5...0.6)
        #expect(DinuColumnTest.reportedBreachLength(DinuColumnTest.shots[2]) == nil)
    }

    @Test(
        "The frame: each IPE220 a line of beams from a flange's midsurface, hinged there, the flange tied over 140 x 275 mm"
    )
    func frame() throws {
        var settings = DinuColumnTest.Settings()
        settings.beams = true
        let model = DinuColumnTest.model(settings)
        let mesh = try ShellMesh(model: model)
        let a = DinuColumnTest.axis(settings)
        let s = settings.section
        let half = (s.depth - s.flange) / 2
        for solid in [3, 4] {
            let line = mesh.beams.filter { $0.solid == solid }
            #expect(!line.isEmpty && line.allSatisfy { $0.axis == 0 })
            let xs = line.flatMap { [mesh.positions[Int($0.nodes.x)].x, mesh.positions[Int($0.nodes.y)].x] }
            let near = xs.map { abs($0 - a.x) }.min() ?? 0
            let far = xs.map { abs($0 - a.x) }.max() ?? 0
            #expect(abs(near - half) < 1e-4 && abs(far - DinuColumnTest.beamReach) < 1e-4)
            // Mass per metre and axial stiffness: the IPE220's (26.2 kg/m), E A 1.32 times its 701 MN.
            let steel = model.material(of: solid)
            let area = DinuColumnTest.beamWidth * DinuColumnTest.beamSection.depth
            #expect(abs(steel.density * area / 26.2 - 1) < 0.01)
            #expect(abs(steel.youngsModulus * area / (210e9 * 33.4e-4) - 1.317) < 0.005)
        }
        // A hinge at each beam's column end only, its joint node the master of the flange's patch.
        #expect(mesh.hinges.count == 2)
        for hinge in mesh.hinges {
            let tied = mesh.ties.filter { $0.master == hinge.jointNode }.map { mesh.positions[Int($0.slave)] }
            #expect(tied.count > 300)
            #expect(tied.allSatisfy { abs(abs($0.x - a.x) - half) < 1e-4 && abs($0.y - a.y) <= 0.0701 })
            let zs = tied.map(\.z)
            #expect(abs((zs.max() ?? 0) - (zs.min() ?? 0) - 0.27) < 0.011)
            // The flange keeps its whole width there.
            let joint = mesh.positions[Int(hinge.jointNode)]
            let across = mesh.positions.filter { abs($0.x - joint.x) < 1e-4 && abs($0.z - joint.z) < 1e-4 }
                .map(\.y)
            #expect(abs((across.min() ?? 0) - (a.y - s.flangeWidth / 2)) < 1e-4)
            #expect(abs((across.max() ?? 0) - (a.y + s.flangeWidth / 2)) < 1e-4)
        }
        // Held: the beams' far ends sideways; the flanges no longer held at the joint; the cleat still.
        func held(_ p: SIMD3<Float>) -> [Bool] {
            let r = DinuColumnTest.restraint(at: p, settings: settings)
            return [r.x, r.y, r.z]
        }
        #expect(held(SIMD3(a.x + 1.4, a.y, 1.66)) == [false, true, false])
        #expect(held(SIMD3(a.x - 1.4, a.y, 1.66)) == [false, true, false])
        #expect(held(SIMD3(a.x + half, a.y + 0.07, 1.60)) == [false, false, false])
        #expect(held(SIMD3(a.x + 0.04, a.y, 1.60)) == [false, true, false])
        #expect(held(SIMD3(a.x, a.y, 1.99)) == [true, true, true])
        settings.axialLoad = 0.3 * DinuColumnTest.squashLoad()
        #expect(held(SIMD3(a.x, a.y, 1.99)) == [true, true, false])
        #expect(held(SIMD3(a.x, a.y, 0)) == [true, true, true])
        // The charge stays 0.2 m off the web, in the wider air.
        let c = DinuColumnTest.chargePosition(DinuColumnTest.shots[1], settings: settings)
        #expect(abs(c.x - a.x) < 1e-6 && a.x + DinuColumnTest.beamReach < DinuColumnTest.domain(settings).x)
    }

    @Test("A face's strain: stretch alone, and bending, its faces either side of the midsurface")
    func faceStrain() {
        let a = SIMD3<Float>(0, 0, 0)
        let b = SIMD3<Float>(0, 0, 0.02)
        let none = simd_quatf(angle: 0, axis: SIMD3(1, 0, 0))
        let offset = SIMD3<Float>(0, -0.005, 0)
        // 1% stretch along z.
        let stretch = DinuColumnTest.faceStrain(
            reference: a, b, displacement: .zero, SIMD3(0, 0, 0.0002), rotation: none, none, offset: offset)
        #expect(abs(stretch - 0.01) < 1e-5)
        // Curvature κ about x: the normal turns by ±κ L/2 at the two nodes; the face 5 mm off strains κ t/2.
        let kappa: Float = 2  // 1/m
        let turn = kappa * 0.01
        let qa = simd_quatf(angle: -turn, axis: SIMD3(1, 0, 0))
        let qb = simd_quatf(angle: turn, axis: SIMD3(1, 0, 0))
        let back = DinuColumnTest.faceStrain(
            reference: a, b, displacement: .zero, .zero, rotation: qa, qb, offset: offset)
        let front = DinuColumnTest.faceStrain(
            reference: a, b, displacement: .zero, .zero, rotation: qa, qb, offset: -offset)
        #expect(abs(abs(back) - kappa * 0.005) < 1e-4 && abs(back + front) < 1e-5)
    }

    @Test("Readings: peak, kept, rate and a ringing's period")
    func readings() {
        let times = (0..<1000).map { Float($0) * 1e-5 }
        let strains = times.map { 0.001 * sin(2 * Float.pi * $0 / 0.0006) + 0.0005 }
        let r = DinuColumnTest.reading(times: times, strains: strains, tail: 0.0006)
        #expect(abs(r.maximum - 0.0015) < 1e-5 && abs(r.minimum + 0.0005) < 1e-5)
        #expect(abs(r.kept - 0.0005) < 5e-5)
        #expect(abs(r.fastestRate - 0.001 * 2 * Float.pi / 0.0006) < 0.5)
        let period = DinuColumnTest.period(times: times, values: strains)
        #expect(abs((period ?? 0) - 0.0006) < 2e-5)
        #expect(DinuColumnTest.collapsed([SIMD2(0.1, 0.002)]) == false)
        #expect(DinuColumnTest.collapsed([SIMD2(0.1, 0.02)]) == nil)
        #expect(DinuColumnTest.collapsed([SIMD2(0.1, 0.06)]) == true)
    }

    @Test("The frame's reference: Fig. 4's peaks, the period, and the parametric thresholds the shots carry")
    func frameReference() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures/Dinu2017/frame.json")
        let reference = try DinuColumnTest.frameReference(from: url)
        #expect(reference.shots.map(\.name) == ["m1", "m2", "m3", "m4"])
        let m4 = try #require(reference.shots.last)
        #expect(m4.peaks == [.init(gauge: 6, microstrain: 17800)] && m4.keptMicrostrain == 6100)
        #expect(reference.shots[1].periodMS == 0.62 && reference.shots[1].peaks[0].station == 2)
        for shot in reference.shots {
            #expect(DinuColumnTest.shots.contains { $0.name == shot.name && $0.standoff == 0.5 })
        }
        for axial in reference.axial {
            let threshold = try #require(DinuColumnTest.axialThresholds[axial.shot])
            #expect(axial.holds.max() == threshold.holds && axial.collapses.min() == threshold.collapses)
            #expect(DinuColumnTest.shots.contains { $0.name == axial.shot && $0.standoff == 0.2 })
        }
        // The proposed tearing strain, an option only: 23% at 10 mm, 8.7 points per doubling.
        #expect(abs(DinuColumnTest.sizeScaledTearingStrain(elementSize: 0.01) - 0.23) < 1e-6)
        #expect(abs(DinuColumnTest.sizeScaledTearingStrain(elementSize: 0.005) - 0.3166) < 1e-3)
        #expect(DinuColumnTest.Settings().failureStrain == nil)
        // The squash load at the measured yields.
        #expect(abs(DinuColumnTest.squashLoad() / 3.27e6 - 1) < 0.005)
    }
}
