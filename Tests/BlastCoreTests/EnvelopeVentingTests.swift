import Foundation
import Metal
import Testing
import simd

@testable import BlastCore
@testable import BlastModel

/// Envelope buildings whose glazing breaks in the air (`EnvelopeVenting`).
@Suite("Envelope venting", .serialized, .gpuThreads)
struct EnvelopeVentingTests {
    @Test("The fine grid's pane lookup is led by a header of 32 bytes, four entries, as the kernels read it")
    func paneLookupLayout() {
        // `PaneLookup` in Refine.metal is 32 bytes, and the kernels read its (cell, pane) entries
        // from the byte after it; at 48 bytes in Swift the last two pane cells were never found.
        #expect(MemoryLayout<PaneLookup>.size == 32)
        #expect(MemoryLayout<PaneLookup>.stride == 4 * MemoryLayout<SIMD2<UInt32>>.stride)
    }

    /// The damage references' building: four walls 0.2 m thick and a roof over a 6 m square, with a
    /// window 1.5 by 1.25 m in the south wall glazed by `glass` (a pane in a cut opening), or with
    /// the glass set in the wall without an opening.
    func building(origin: SIMD3<Float>, cutOpening: Bool) throws -> BuildingEnvelope {
        let (x, y) = (origin.x, origin.y)
        let solids = [
            Box(min: SIMD3(x, y, 0), max: SIMD3(x + 6, y + 0.2, 3)),
            Box(min: SIMD3(x, y + 5.8, 0), max: SIMD3(x + 6, y + 6, 3)),
            Box(min: SIMD3(x, y + 0.2, 0), max: SIMD3(x + 0.2, y + 5.8, 3)),
            Box(min: SIMD3(x + 5.8, y + 0.2, 0), max: SIMD3(x + 6, y + 5.8, 3)),
            Box(min: SIMD3(x, y, 3), max: SIMD3(x + 6, y + 6, 3.2)),
        ]
        let window = Box(min: SIMD3(x + 2.25, y, 1), max: SIMD3(x + 3.75, y + 0.2, 2.25))
        let pane = Box(min: SIMD3(x + 2.25, y + 0.097, 1), max: SIMD3(x + 3.75, y + 0.103, 2.25))
        return try BuildingEnvelope(solids: solids, openings: cutOpening ? [window] : [], panes: [pane])
    }

    @Test("A sealed building's inside is one room, its openings and panes taken as closed")
    func interiors() throws {
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(16, 16, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        try scene.addEnvelopeObject(building(origin: SIMD3(4, 4, 0), cutOpening: true), name: "Building")
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25)
        let grid = solver.grid
        let mask = solidMask(solver)
        let rooms = mask.withUnsafeBufferPointer {
            EnvelopeVenting.interiors(
                grid: grid, mask: $0, envelopes: scene.envelopeObjects.compactMap(\.envelope))
        }
        #expect(rooms.count == 1 && rooms[0].count == 1)
        // Inside the walls, 5.6 m square (centres from 4.375 to 9.625 m: 22 a side), under the roof
        // (12 cells of centres below 3 m).
        #expect(rooms[0][0].count == 22 * 22 * 12)
    }

    func solidMask(_ solver: BlastSolver) -> [UInt8] {
        let grid = solver.grid
        var mask = [UInt8](repeating: 0, count: grid.cellCount)
        for k in 0..<grid.nz {
            for j in 0..<grid.ny {
                for i in 0..<grid.nx where solver.isSolid(i, j, k) {
                    mask[i + grid.nx * (j + grid.ny * k)] = 1
                }
            }
        }
        return mask
    }

    func glazedScene(charge: Float) throws -> Scenario {
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(16, 20, 6), boxes: [],
            charge: Charge(mass: charge, position: SIMD3(7, 2, 1)),
            gauges: [Gauge("Inside", at: SIMD3(7, 10, 1.5))])
        try scene.addEnvelopeObject(building(origin: SIMD3(4, 7, 0), cutOpening: true), name: "Building")
        return scene
    }

    @Test("A pane breaks as its one-way model does, opens, and the room fills; a restart closes it")
    func breaksAndFills() throws {
        let scene = try glazedScene(charge: 5)
        let construction = EnvelopeConstruction.assumed(objectID: scene.envelopeObjects[0].id)
        func vented() throws -> BlastSolver {
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var config = SolverConfiguration.recommended.balloonStart
            config.airSleepThreshold = 0
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
                configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.04))
            try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) { _ in construction }
            return solver
        }
        let solver = try vented()
        let cells = scene.envelopeObjects[0].envelope!.paneCells(0, grid: solver.grid)
        #expect(cells.allSatisfy { solidMask(solver)[$0] != 0 })
        _ = solver.advance(until: 0.03)
        let first = try #require(solver.envelopeVentingSnapshot())
        let broke = try #require(first.panes.first?.brokenAtS)
        // The one-way model on the pane's own load up to then breaks it at the same time.
        let history = try #require(solver.envelopeComponentHistories()?.first { $0.component.kind == .pane })
        let spans = history.component.spans
        let glass = EnvelopePanel.largeDeflectionGlass(
            thickness: Double(construction.glassThicknessM), material: .annealedGlass,
            a: Double(min(spans.x, spans.y)), b: Double(max(spans.x, spans.y)))
        let net = history.netImpulsePaS.map { Double($0) / history.binS }
        let oneWay = try #require(glass.response(pressures: net, step: history.binS).lostResistanceAt)
        #expect(abs(oneWay - broke) < 3e-4, "GPU \(broke) s, one-way \(oneWay) s")
        #expect(cells.allSatisfy { solidMask(solver)[$0] == 0 })
        let room = try #require(first.inside(of: scene.envelopeObjects[0].id))
        #expect(room.peakPa > 100 && room.impulsePaS > 0)
        // A restart closes the pane again.
        solver.restart()
        #expect(cells.allSatisfy { solidMask(solver)[$0] != 0 })
        #expect(solver.envelopeVentingSnapshot()?.panes.first?.brokenAtS == nil)
        // A run again from the start is the same to the bit.
        let again = try vented()
        _ = again.advance(until: 0.03)
        let second = try #require(again.envelopeVentingSnapshot())
        #expect(
            second.panes.first?.brokenAtS == broke && second.rooms.first?.peakPa == first.rooms.first?.peakPa)
    }

    @Test(
        "In refined air a broken pane opens its finer cells too: glass gone at once lets in what an open window does"
    )
    func refined() throws {
        // Glass 0.3 mm thick, gone as the shock arrives; against the same window open from the start.
        func run(_ envelope: BuildingEnvelope, levels: Int, vented: Bool) throws -> [Float] {
            var scene = Scenario(
                name: "Glazed", domainSize: SIMD3(16, 20, 6), boxes: [],
                charge: Charge(mass: 5, position: SIMD3(7, 2, 1)),
                gauges: [Gauge("Inside", at: SIMD3(7, 10, 1.5)), Gauge("Back", at: SIMD3(7, 12.5, 1.5))])
            try scene.addEnvelopeObject(envelope, name: "Building")
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var config = SolverConfiguration.recommended.balloonStart
            config.airSleepThreshold = 0
            config.refinement = levels == 0 ? 1 : 2
            config.refinementLevels = max(levels, 1)
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
                configuration: config)
            if vented {
                try solver.configureEnvelopeComponents(
                    objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.04))
                try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) {
                    var thin = EnvelopeConstruction.assumed(objectID: $0)
                    thin.glassThicknessM = 0.0003
                    return thin
                }
            }
            _ = solver.advance(until: 0.03)
            if vented {
                let broke = try #require(solver.envelopeVentingSnapshot()?.panes.first?.brokenAtS)
                #expect(broke < 0.007, "\(levels) levels: broke at \(broke) s")
            }
            return solver.gaugeHistories.map { ($0.map(\.pressure).max() ?? 0) - config.ambientPressure }
        }
        let cut = try building(origin: SIMD3(4, 7, 0), cutOpening: true)
        let open = try BuildingEnvelope(solids: cut.solids, openings: cut.openings, panes: [])
        for levels in [0, 1, 2] {
            let reference = try run(open, levels: levels, vented: false)
            for glazed in [cut, try building(origin: SIMD3(4, 7, 0), cutOpening: false)] {
                let peaks = try run(glazed, levels: levels, vented: true)
                for (peak, wanted) in zip(peaks, reference) {
                    #expect(abs(peak / wanted - 1) < 0.1, "\(levels) levels: \(peak) Pa against \(wanted)")
                }
            }
        }
    }

    @Test("A brick wall that falls fails in the air when its one-way model does, opens, and the room fills")
    func wallFails() throws {
        let scene = try glazedScene(charge: 50)
        let owner = scene.envelopeObjects[0].id
        let brick = EnvelopeConstruction(
            objectID: owner, walls: .unreinforcedMasonry, wallThicknessM: 0.1, source: .user, detail: "")
        func vented() throws -> BlastSolver {
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var config = SolverConfiguration.recommended.balloonStart
            config.airSleepThreshold = 0
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
                configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.06))
            try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) { _ in brick }
            return solver
        }
        let solver = try vented()
        _ = solver.advance(until: 0.05)
        let snapshot = try #require(solver.envelopeVentingSnapshot())
        // The south wall, facing the charge.
        let south = try #require(snapshot.walls.first { $0.component.hasSuffix("/wall/0.0") })
        let failed = try #require(south.failedAtS)
        let history = try #require(
            solver.envelopeComponentHistories()?.first { $0.component.id == south.component })
        let load = EnvelopeComponentLoad(history)
        let model = try #require(EnvelopeWallFailure.make(load, construction: brick))
        let net = load.netPa
        let fallen = try #require(
            model.systems[0].sdof.response(pressures: net, step: load.binS).lostResistanceAt)
        #expect(
            abs(fallen + load.startS - failed) < 5e-4, "GPU \(failed) s, one-way \(fallen + load.startS) s")
        // Its cells are air, the room has filled, and the damage says so.
        let grid = solver.grid
        let region = history.component.region
        let centre = (region.min + region.max) / 2
        #expect(
            !solver.isSolid(
                Int(centre.x / grid.cellSize), Int(centre.y / grid.cellSize), Int(centre.z / grid.cellSize)))
        #expect((snapshot.inside(of: owner)?.peakPa ?? 0) > 1000)
        let loads = (solver.envelopeComponentHistories() ?? []).filter { !$0.invalid || snapshot.keeps($0) }
            .map(EnvelopeComponentLoad.init)
        let damage = try #require(
            EnvelopeDamageAssessment.assess(loads: loads, constructions: { _ in brick }, vented: snapshot)
                .first)
        let wall = try #require(damage.components.first { $0.id == south.component })
        #expect(wall.levels.upperBound == .failed && wall.failedAtS == failed)
        // A restart stands it again; a run again repeats to the bit.
        solver.restart()
        #expect(
            solver.isSolid(
                Int(centre.x / grid.cellSize), Int(centre.y / grid.cellSize), Int(centre.z / grid.cellSize)))
        let again = try vented()
        _ = again.advance(until: 0.05)
        #expect(
            again.envelopeVentingSnapshot()?.walls.first { $0.component == south.component }?.failedAtS
                == failed)
    }

    @Test("Under gravity a pane opens on the background at its height, and the room fills as without")
    func gravity() throws {
        let scene = try glazedScene(charge: 5)
        var results: [(broke: Double, peak: Double)] = []
        for gravity in [false, true] {
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var config = SolverConfiguration.recommended.balloonStart
            config.airSleepThreshold = 0
            config.gravity = gravity ? AirGravity() : nil
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
                configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.04))
            try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) {
                EnvelopeConstruction.assumed(objectID: $0)
            }
            _ = solver.advance(until: 0.03)
            let snapshot = try #require(solver.envelopeVentingSnapshot())
            results.append(
                (
                    try #require(snapshot.panes.first?.brokenAtS),
                    snapshot.inside(of: scene.envelopeObjects[0].id)?.peakPa ?? 0
                ))
        }
        #expect(abs(results[1].broke - results[0].broke) < 3e-4, "\(results)")
        #expect(results[0].peak > 100 && abs(results[1].peak / results[0].peak - 1) < 0.1, "\(results)")
    }

    @Test("Holes through a wall open their columns on the run's clock, small ones once they fill half a face")
    func wallHoles() throws {
        // The walled square without its window: only the holes let the blast in.
        var scene = Scenario(
            name: "Walled", domainSize: SIMD3(16, 20, 6), boxes: [],
            charge: Charge(mass: 5, position: SIMD3(7, 2, 1)))
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: building(origin: SIMD3(4, 7, 0), cutOpening: false).solids),
            name: "Building")
        let owner = scene.envelopeObjects[0].id
        let thick = EnvelopeConstruction.assumed(objectID: owner)
        func run(_ holes: [(owner: UUID, time: Double, position: SIMD3<Float>, areaM2: Float)]) throws
            -> (BlastSolver, EnvelopeVentingSnapshot)
        {
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var config = SolverConfiguration.recommended.balloonStart
            config.airSleepThreshold = 0
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
                configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.04))
            try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) { _ in thick }
            try solver.setEnvelopeWallHoles(holes)
            _ = solver.advance(until: 0.03)
            return (solver, try #require(solver.envelopeVentingSnapshot()))
        }
        // On the south wall's face (y = 7): four small holes in one column, 0.01 m² each (a face
        // is 0.0625 m², so the column opens with the fourth), and one of 0.2 m² further along.
        let small = SIMD3<Float>(5.1, 7.0, 0.6)
        let large = SIMD3<Float>(8.4, 7.0, 0.6)
        let holes: [(owner: UUID, time: Double, position: SIMD3<Float>, areaM2: Float)] =
            (0..<4).map { (owner, 0.002 + 0.001 * Double($0), small, 0.01) } + [(owner, 0.004, large, 0.2)]
        let (solver, vented) = try run(holes)
        let opened = vented.holes.filter { $0.openedAtS != nil }
        // The small column at the fourth hole (5 ms); the large hole's radius (0.25 m) takes its
        // own column and those whose centres lie within it.
        #expect(vented.holes.contains { abs(($0.openedAtS ?? -1) - 0.005) < 1e-6 })
        #expect(opened.filter { abs(($0.openedAtS ?? -1) - 0.004) < 1e-6 }.count >= 2)
        let grid = solver.grid
        func solid(_ p: SIMD3<Float>) -> Bool {
            solver.isSolid(
                Int(p.x / grid.cellSize), Int((p.y + 0.1) / grid.cellSize), Int(p.z / grid.cellSize))
        }
        #expect(!solid(small) && !solid(large))
        let filled = vented.inside(of: owner)?.peakPa ?? 0
        let (_, sealed) = try run([])
        #expect(filled > 100 && (sealed.inside(of: owner)?.peakPa ?? 0) == 0, "\(filled) Pa")
        // A restart closes them; a run again repeats to the bit.
        solver.restart()
        #expect(solid(small) && solid(large))
        let (_, again) = try run(holes)
        #expect(again.inside(of: owner)?.peakPa == vented.inside(of: owner)?.peakPa)
    }

    @Test("A charge close to a concrete wall breaches it by UFC 3-340-02's curve, opening the patch")
    func breach() throws {
        // 20 kg 0.6 m off the south wall (0.2 m of concrete) of the walled square.
        var scene = try glazedScene(charge: 20)
        scene.charge.position = SIMD3(5, 6.4, 1)
        let owner = scene.envelopeObjects[0].id
        var thick = EnvelopeConstruction.assumed(objectID: owner)
        thick.glassThicknessM = 0.05
        // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
        var config = SolverConfiguration.recommended.balloonStart
        config.airSleepThreshold = 0
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25,
            configuration: config)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.03))
        try solver.configureEnvelopeVenting(objects: scene.envelopeObjects) { _ in thick }
        let outcomes = try solver.setEnvelopeCloseIn(charges: [(scene.charge, 0)]) { _ in thick }
        let south = try #require(outcomes.first { $0.key.hasSuffix("/wall/0.0") })
        #expect(south.value == .breached)
        _ = solver.advance(until: 0.02)
        let vented = try #require(solver.envelopeVentingSnapshot())
        let holes = vented.holes.filter { $0.cause == "breach" && $0.openedAtS != nil }
        #expect(!holes.isEmpty && holes.allSatisfy { $0.component == south.key })
        // The patch nearest the charge is air; the room has filled.
        let grid = solver.grid
        #expect(!solver.isSolid(Int(5 / grid.cellSize), Int(7.1 / grid.cellSize), Int(1 / grid.cellSize)))
        #expect((vented.inside(of: owner)?.peakPa ?? 0) > 1000)
        #expect(vented.closeIn[south.key] == "breached")
    }
}
