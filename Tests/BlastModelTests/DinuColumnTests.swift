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

    @Test("Each charge stands its distance off the web's face, at mid-height, inside the air")
    func charges() {
        let settings = DinuColumnTest.Settings()
        for shot in DinuColumnTest.shots {
            let c = DinuColumnTest.chargePosition(shot, settings: settings)
            let face = DinuColumnTest.axis.y + settings.section.web / 2
            #expect(abs(c.y - face - shot.standoff) < 1e-6)
            let radius = cbrt(3 * shot.charge / (4 * .pi * 1600))
            #expect(c.y + radius + 0.2 < DinuColumnTest.domain(settings).y)
        }
        #expect(abs(DinuColumnTest.shots[1].scaledDistance - 0.164) < 0.001)
        #expect(abs(DinuColumnTest.extent([0.9, 1.1, 1.0], elementSize: 0.01) - 0.21) < 1e-5)
        #expect(DinuColumnTest.extent([], elementSize: 0.01) == 0)
    }
}
