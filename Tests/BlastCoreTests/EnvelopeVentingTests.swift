import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Envelope buildings whose glazing breaks in the air (`EnvelopeVenting`).
@Suite("Envelope venting", .serialized, .gpuThreads)
struct EnvelopeVentingTests {
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
            var config = SolverConfiguration.recommended
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
            var config = SolverConfiguration.recommended
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
            var config = SolverConfiguration.recommended
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
            var config = SolverConfiguration.recommended
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
}
