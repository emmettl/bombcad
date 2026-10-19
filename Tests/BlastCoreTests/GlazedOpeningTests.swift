import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// A window as users and IFC imports model it: an opening cut through a wall, and a pane of glass
/// in it. The opening cuts the wall; the pane is kept, on the wall's midsurface, joined to the
/// opening's reveal.
@Suite("Glazed openings", .gpuThreads)
struct GlazedOpeningTests {
    /// A 0.2 m reinforced concrete wall across x = 4 to 4.2, 3 m long and 2.5 m high, with a 1 m
    /// square opening from 1 to 2 m along it and 0.5 to 1.5 m up; and, unless `glazed` is false,
    /// a 6 mm pane of annealed glass in the opening, set 50 mm off the wall's middle and 20 mm in
    /// from the reveal, as a window's glass sits in its frame.
    static func wall(glazed: Bool = true) -> StructureModel {
        var model = StructureModel(
            solids: [Box(min: SIMD3(4, 0, 0), max: SIMD3(4.2, 3, 2.5))],
            openings: [Box(min: SIMD3(3.99, 1, 0.5), max: SIMD3(4.21, 2, 1.5))], elementSize: 0.125)
        model.elementKind = .shell
        model.shellLayers = 4
        if glazed {
            model.solids.append(Box(min: SIMD3(4.047, 1.02, 0.52), max: SIMD3(4.053, 1.98, 1.48)))
            model.setMaterial(.annealedGlass, of: 1)
        }
        return model
    }

    /// The elements of `solid`, and whether each of its nodes round its edge (at the extremes of
    /// its plane) is a node of `wall`'s elements too.
    static func pane(in mesh: ShellMesh, solid: Int, wall: Int) -> (elements: Int, joined: Bool) {
        let elements = mesh.elements.filter { $0.solid == solid }
        guard let axis = elements.first?.axis else { return (0, false) }
        let wallNodes = Set(
            mesh.elements.filter { $0.solid == wall }.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let nodes = Set(elements.flatMap { e in (0..<4).map { e.nodes[$0] } })
        let points = nodes.map { mesh.positions[Int($0)] }
        let low = points.reduce(SIMD3<Float>(repeating: .infinity), simd_min)
        let high = points.reduce(SIMD3<Float>(repeating: -.infinity), simd_max)
        let edge = nodes.filter { n in
            let p = mesh.positions[Int(n)]
            return (0..<3).contains { k in
                k != axis && (abs(p[k] - low[k]) < 1e-5 || abs(p[k] - high[k]) < 1e-5)
            }
        }
        return (elements.count, !edge.isEmpty && edge.isSubset(of: wallNodes))
    }

    /// A closed OBJ mesh of `boxes`, each drawn in by half a millimetre where there are several,
    /// so that they do not touch (as IFCStructureTests draws them).
    static func mesh(_ boxes: [Box]) throws -> ImportedMesh {
        var text = ""
        for (n, var box) in boxes.enumerated() {
            if boxes.count > 1 {
                box.min += SIMD3(repeating: 0.0005)
                box.max -= SIMD3(repeating: 0.0005)
            }
            for k in 0..<8 {
                let p = SIMD3(
                    k & 1 == 0 ? box.min.x : box.max.x, k & 2 == 0 ? box.min.y : box.max.y,
                    k & 4 == 0 ? box.min.z : box.max.z)
                text += "v \(p.x) \(p.y) \(p.z)\n"
            }
            for face in [
                [0, 2, 3, 1], [4, 5, 7, 6], [0, 1, 5, 4], [2, 6, 7, 3], [0, 4, 6, 2], [1, 3, 7, 5],
            ] {
                let v = face.map { 8 * n + $0 + 1 }
                text += "f \(v[0]) \(v[1]) \(v[2])\nf \(v[0]) \(v[2]) \(v[3])\n"
            }
        }
        return try ImportedMesh(data: Data(text.utf8), fileExtension: "obj")
    }

    /// How the window is modelled in `glassFailed`: as a pane in the wall's opening; as the
    /// envelope-damage references did before panes in openings were kept (no opening, the pane a
    /// plate in the wall's plane over the wall); or as the same pane alone, without the wall, held
    /// along its edges where the wall would hold it.
    enum Window { case opening, plate, alone }

    /// The wall facing a charge 3 m away, for 30 ms: how many of the glass's elements fail.
    static func glassFailed(charge: Float, window: Window = .opening, device: MTLDevice) throws -> (
        failed: Int, of: Int
    ) {
        var model = wall()
        let pane = Box(min: SIMD3(4.097, 1, 0.5), max: SIMD3(4.103, 2, 1.5))
        switch window {
        case .opening: break
        case .plate:
            model.openings = []
            model.solids[1] = pane
        case .alone:
            // The pane where the opening's meshing puts it, its edge nodes held still.
            model.openings = []
            model.solids = [pane]
            model.solidMaterial = [.annealedGlass]
            let (low, high) = (pane.min - 0.01, pane.max + 0.01)
            model.supports = [
                Box(min: low, max: SIMD3(high.x, low.y + 0.02, high.z)),
                Box(min: SIMD3(low.x, high.y - 0.02, low.z), max: high),
                Box(min: low, max: SIMD3(high.x, high.y, low.z + 0.02)),
                Box(min: SIMD3(low.x, low.y, high.z - 0.02), max: high),
            ]
        }
        let glassSolid = window == .alone ? 0 : 1
        let scenario = Scenario(
            name: "Glazed wall", domainSize: SIMD3(8, 3, 3), boxes: [],
            charge: Charge(mass: charge, position: SIMD3(1, 1.5, 1)), gauges: [], structure: model)
        let solver = try BlastSolver(device: device, scenario: scenario, cellSize: 0.1)
        solver.advance(until: 0.03)
        let shells = try #require(solver.shells)
        let glass = shells.mesh.elements.indices.filter { shells.mesh.elements[$0].solid == glassSolid }
        return (glass.filter { shells.flag($0) == .eroded }.count, glass.count)
    }

    @Test(
        "The glass in a wall's opening breaks in a modest blast, as the plate workaround's did, and survives a faint one"
    )
    func breaks() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let pane = try Self.glassFailed(charge: 1, device: device)
        let plate = try Self.glassFailed(charge: 1, window: .plate, device: device)
        let faint = try Self.glassFailed(charge: 0.0005, device: device)
        print(
            "Glass failed at 1 kg, 3 m: \(pane.failed) of \(pane.of) in the opening, \(plate.failed) of \(plate.of) as a plate"
        )
        #expect(pane.of == 64 && plate.of == 64)
        #expect(
            pane.failed > 0 && plate.failed > 0, "pane \(pane.failed), plate \(plate.failed) of 64 failed")
        // The same window both ways: as many of its elements fail, within a quarter.
        #expect(
            abs(pane.failed - plate.failed) <= max(4, plate.failed / 4),
            "pane \(pane.failed), plate \(plate.failed)")
        #expect(faint.failed == 0, "\(faint.failed) failed in a faint blast")
    }

    @Test("The glass in a wall's opening breaks under a charge that breaks the same pane alone")
    func breaksAsAlone() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let alone = try Self.glassFailed(charge: 1, window: .alone, device: device)
        let pane = try Self.glassFailed(charge: 1, device: device)
        print(
            "Glass failed at 1 kg, 3 m: \(pane.failed) of \(pane.of) in the opening, \(alone.failed) of \(alone.of) alone"
        )
        #expect(pane.of == 64 && alone.of == 64)
        // The air loads the pane in the opening: it breaks where the pane alone does.
        #expect(alone.failed > 0, "\(alone.failed) of 64 failed alone")
        #expect(pane.failed > 0, "\(pane.failed) of 64 failed in the opening")
        // With no clearing round its edges, the wall's pane is loaded longer and breaks no less.
        #expect(pane.failed >= alone.failed, "pane \(pane.failed), alone \(alone.failed)")
    }
}
