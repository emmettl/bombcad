import Testing
import simd

@testable import BlastCore

@Suite("Connected gas control volumes")
struct ConnectedGasGroupsTests {
    @Test("Clipped axis-aligned and rotated boxes preserve uniform gas on two grids")
    func clippedGeometry() throws {
        let results = try ExperimentalConnectedGasStudy.run()
        #expect(results.count == 4)
        for r in results {
            #expect(r.groups < r.wetCells && r.maximumGroupMembers <= 64)
            #expect(r.areaResidual < 1e-8 && r.momentResidual < 1e-8)
            #expect(r.maximumRelativePressureError < 1e-12)
            #expect(abs(r.relativeMassChange) < 1e-12 && abs(r.relativeEnergyChange) < 1e-12)
            #expect(simd_length(r.momentumChange) < 1e-12)
            if r.rotation > 0 { #expect(r.groupedStep > 100 * r.initialStep) }
        }
    }

    @Test("Tiny split members preserve uniform pressure; face ordering does not change membership")
    func tinyMembers() throws {
        let f = boxes([1, 1e-12, 1])
        let p = try plan(f)
        let split = try p.scatter(p.groups.map(\.cell))
        #expect(abs(split[1].pressure() / 101325 - 1) < 1e-12)
        var reversed = f
        reversed.faces.reverse()
        #expect(try plan(reversed).cellToGroup == p.cellToGroup)
    }
    private struct Fixture {
        var cells: [FractionalGasTransport.Cell]
        var centres: [SIMD3<Double>]
        var faces: [ConnectedGasGroups.Face]
        var boundaries: [ConnectedGasGroups.Boundary]
    }
    private func boxes(_ widths: [Double], rotated: Bool = false) -> Fixture {
        let turn = simd_quatd(angle: rotated ? 0.37 : 0, axis: simd_normalize(SIMD3(1, 2, 3)))
        let shift = rotated ? SIMD3<Double>(10000, -20000, 30000) : .zero
        func point(_ p: SIMD3<Double>) -> SIMD3<Double> { turn.act(p) + shift }
        var cells: [FractionalGasTransport.Cell] = []
        var centres: [SIMD3<Double>] = []
        var faces: [ConnectedGasGroups.Face] = []
        var boundaries: [ConnectedGasGroups.Boundary] = []
        var low = 0.0
        for (n, width) in widths.enumerated() {
            let high = low + width
            let middle = (low + high) / 2
            cells.append(.init(volume: width, density: 1.225, pressure: 101325))
            centres.append(point(SIMD3(middle, 0.5, 0.5)))
            if n > 0 {
                faces.append(
                    .init(
                        a: n - 1, b: n, area: 1, normal: turn.act(SIMD3(1, 0, 0)),
                        centroid: point(SIMD3(low, 0.5, 0.5))))
            }
            if n == 0 {
                boundaries.append(
                    .init(
                        cell: n, area: 1, normal: turn.act(SIMD3(-1, 0, 0)),
                        centroid: point(SIMD3(low, 0.5, 0.5))))
            }
            if n == widths.count - 1 {
                boundaries.append(
                    .init(
                        cell: n, area: 1, normal: turn.act(SIMD3(1, 0, 0)),
                        centroid: point(SIMD3(high, 0.5, 0.5))))
            }
            for axis in 1...2 {
                for sign in [-1.0, 1.0] {
                    var normal = SIMD3<Double>.zero
                    normal[axis] = sign
                    var p = SIMD3(middle, 0.5, 0.5)
                    p[axis] = sign < 0 ? 0 : 1
                    boundaries.append(
                        .init(cell: n, area: width, normal: turn.act(normal), centroid: point(p)))
                }
            }
            low = high
        }
        return Fixture(cells: cells, centres: centres, faces: faces, boundaries: boundaries)
    }
    private func plan(_ f: Fixture, maximumMembers: Int = 64) throws -> ConnectedGasGroups.Plan {
        try ConnectedGasGroups.build(
            cells: f.cells, centres: f.centres, nominalVolume: 1,
            faces: f.faces, boundaries: f.boundaries, maximumMembers: maximumMembers)
    }

    @Test(
        "A thin cell merges across an open face, preserving exterior geometry and resting gas",
        arguments: [false, true])
    func closedGeometry(rotated: Bool) throws {
        let f = boxes([1, 0.01, 1], rotated: rotated)
        let p = try plan(f)
        #expect(p.groups.map(\.members) == [[0, 1], [2]])
        #expect(p.cellToGroup == [0, 0, 1] && p.faces.count == 1)
        #expect(p.maximumAreaResidual < 1e-8 && p.maximumMomentResidual < 1e-8)
        let faces = p.faces.map {
            FractionalEulerFlux.Face(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area)
        }
        let walls = p.boundaries.map {
            FractionalEulerFlux.Wall(cell: $0.cell, normal: $0.normal, area: $0.area)
        }
        let cells = p.groups.map(\.cell)
        let dt = try FractionalEulerFlux.maximumStep(cells, faces: faces, walls: walls)
        let result = try FractionalEulerFlux.advanceWithWalls(cells, faces: faces, walls: walls, duration: dt)
        let scattered = try p.scatter(result.cells)
        for cell in scattered { #expect(abs(cell.pressure() / 101325 - 1) < 1e-12) }
        let oldFaces = f.faces.map {
            FractionalEulerFlux.Face(a: $0.a, b: $0.b, normal: $0.normal, area: $0.area)
        }
        let oldWalls = f.boundaries.map {
            FractionalEulerFlux.Wall(cell: $0.cell, normal: $0.normal, area: $0.area)
        }
        let oldDt = try FractionalEulerFlux.maximumStep(f.cells, faces: oldFaces, walls: oldWalls)
        #expect(dt > 10 * oldDt)
    }

    @Test("Nonuniform gas inventories survive aggregation and constant-state splitting")
    func extensiveBudgets() throws {
        var f = boxes([1, 0.01, 1])
        f.cells[1] = .init(volume: 0.01, density: 2, velocity: SIMD3(-2, 1, 0), pressure: 150000)
        let p = try plan(f)
        let split = try p.scatter(p.groups.map(\.cell))
        let before = f.cells.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        let after = split.reduce(SIMD8<Double>.zero) { $0 + $1.amount }
        for axis in 0..<5 { #expect(abs(before[axis] - after[axis]) < 1e-9) }
        #expect(simd_length(split[0].velocity - split[1].velocity) < 1e-12)
        #expect(abs(split[0].pressure() / split[1].pressure() - 1) < 1e-12)
    }

    @Test("Bad centroids and volumes fail even when area vectors close")
    func badGeometry() throws {
        var f = boxes([1, 0.01, 1])
        let face = f.faces[0]
        f.faces[0] = .init(
            a: face.a, b: face.b, area: face.area, normal: face.normal,
            centroid: face.centroid + SIMD3(0.1, 0, 0))
        #expect(throws: ConnectedGasGroups.Failure.self) { try plan(f) }
        f = boxes([1, 0.01, 1])
        f.cells[1] = .init(volume: 0.02, density: 1.225, pressure: 101325)
        #expect(throws: ConnectedGasGroups.Failure.self) { try plan(f) }
    }

    @Test("Isolated small cells and member limits fail explicitly; dry cells remain empty")
    func limitsAndDryCells() throws {
        let chained = try plan(boxes([0.01, 0.01, 0.01, 1]))
        #expect(chained.groups.map(\.members) == [[0, 1, 2, 3]])
        #expect(throws: ConnectedGasGroups.Failure.self) { try plan(boxes([0.01, 0.01, 0.01])) }
        #expect(throws: ConnectedGasGroups.Failure.self) { try plan(boxes([0.01])) }
        #expect(throws: ConnectedGasGroups.Failure.self) { try plan(boxes([1, 0.01, 1]), maximumMembers: 1) }
        var f = boxes([1, 0.01, 1])
        f.cells.append(.init(volume: 0, density: 1.225, pressure: 101325))
        f.centres.append(.zero)
        let p = try plan(f)
        #expect(p.cellToGroup.last == -1)
        #expect(try p.scatter(p.groups.map(\.cell)).last!.amount == .zero)
    }
}
