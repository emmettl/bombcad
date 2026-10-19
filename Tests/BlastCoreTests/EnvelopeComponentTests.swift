import Foundation
import Metal
import Testing
import simd

@testable import BlastCore

/// Envelope components from the geometry alone (the component spec, v1.2).
@Suite("Envelope components")
struct EnvelopeComponentTests {
    let owner = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!

    @Test("The street study's building has one panel a wall and one roof panel, every edge supported")
    func streetBuilding() throws {
        var scene = try StreetInteractionStudy.make(.isolated, clamped: true)
        let id = try #require(scene.structuralObjects.first?.id)
        try scene.useEnvelope(id: id)
        let envelope = try #require(scene.envelopeObjects.first?.envelope)
        let components = envelope.components(owner: id, cellSize: 0.5)
        #expect(components.map(\.kind) == [.wall, .wall, .wall, .wall, .roof])
        #expect(
            components.allSatisfy { $0.id.hasSuffix(".0") && $0.supportEdges == [true, true, true, true] })
        #expect(components[0].id == "\(id.uuidString)/wall/0.0")
        // The front wall faces -y, the back +y, the left -x, the right +x; the roof up.
        #expect(components.map(\.outward) == [-1, 1, -1, 1, 1])
        #expect(components.map(\.axis) == [1, 1, 0, 0, 2])
        #expect(components[0].spans == SIMD2(6, 4))
        #expect(components[0].inPlaneAxes == (0, 2))
    }

    @Test(
        "A wall alone is cut into equal panels at most 6 m wide and 3 m tall; width and height cuts hold nothing"
    )
    func wallAlone() throws {
        let envelope = try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(12, 0.3, 6))])
        let components = envelope.components(owner: owner, cellSize: 0.5)
        #expect(components.count == 4)
        #expect(components.map(\.panel) == [0, 1, 2, 3])
        #expect(components[1].region.min.x == 6 && components[1].region.max.z == 3)
        #expect(components[2].region.min.z == 3 && components[2].region.min.x == 0)
        // On the ground only.
        #expect(components[0].supportEdges == [false, false, true, false])
        #expect(components[3].supportEdges == [false, false, false, false])
    }

    @Test("A slab crossing a wall cuts it there, a support, and no storey cuts follow")
    func slabSupport() throws {
        let envelope = try BuildingEnvelope(solids: [
            Box(min: .zero, max: SIMD3(6, 0.3, 7)),
            Box(min: SIMD3(0, 0, 2.85), max: SIMD3(6, 6, 3.15)),
        ])
        let walls = envelope.components(owner: owner, cellSize: 0.5).filter { $0.kind == .wall }
        #expect(walls.count == 2)
        #expect(walls[0].region.max.z == 3 && walls[1].region.min.z == 3 && walls[1].region.max.z == 7)
        #expect(walls[0].supportEdges[3] && walls[1].supportEdges[2])
    }

    @Test("A block gives façade strips a storey tall on each side, the last taking the remainder, and a roof")
    func block() throws {
        let envelope = try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(10, 8, 7))])
        let components = envelope.components(owner: owner, cellSize: 0.5)
        #expect(components.count == 13)
        let strips = components.filter { $0.kind == .facade }
        #expect(strips.map(\.source) == Array(0..<12))
        #expect(strips.prefix(3).map(\.region.max.z) == [3, 6, 7])
        #expect(strips.map(\.outward) == [-1, -1, -1, 1, 1, 1, -1, -1, -1, 1, 1, 1])
        #expect(strips.map(\.axis) == [0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1])
        #expect(components.last?.kind == .roof && components.last?.id == "\(owner.uuidString)/roof/0.0")
        // 6.5 m: the half metre left over joins the strip below.
        let low = try BuildingEnvelope(solids: [Box(min: .zero, max: SIMD3(10, 8, 6.5))])
        #expect(
            low.components(owner: owner).filter { $0.kind == .facade }.prefix(2).map(\.region.max.z) == [
                3, 6.5,
            ])
    }

    @Test("Glass in a detailed structure becomes panes, solid in the air, each held on four edges")
    func panes() throws {
        var model = StructureModel(
            solids: [
                Box(min: .zero, max: SIMD3(6, 0.3, 3)), Box(min: SIMD3(2, 0.1, 1), max: SIMD3(4, 0.11, 2)),
            ],
            elementSize: 0.1, fixedBase: true)
        model.openings = [Box(min: SIMD3(2, 0, 1), max: SIMD3(4, 0.3, 2))]
        model.solidMaterial = [nil, .annealedGlass]
        let envelope = try BuildingEnvelope(structure: model)
        #expect(envelope.solids.count == 1 && envelope.panes.count == 1)
        #expect(envelope.occupies(SIMD3(3, 0.105, 1.5)) && !envelope.occupies(SIMD3(3, 0.25, 1.5)))
        #expect(envelope.blockSources.last == .pane(0))
        let pane = try #require(envelope.components(owner: owner).last)
        #expect(pane.kind == .pane && pane.axis == 1 && pane.supportEdges == [true, true, true, true])
        #expect(pane.id == "\(owner.uuidString)/pane/0.0")
        // Encoded only when there are panes; a scene with them saves at its own version.
        let plain = try BuildingEnvelope(solids: model.solids.prefix(1).map { $0 })
        #expect(try !String(decoding: JSONEncoder().encode(plain), as: UTF8.self).contains("panes"))
        #expect(
            try JSONDecoder().decode(BuildingEnvelope.self, from: JSONEncoder().encode(envelope)) == envelope)
        var scene = Scenario(
            name: "Glazed", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        try scene.addEnvelopeObject(plain)
        #expect(!scene.hasEnvelopePanes)
        try scene.addEnvelopeObject(envelope)
        #expect(scene.hasEnvelopePanes)
    }
}

/// The recorder of each component's load (`EnvelopeComponentRecorder`).
@Suite("Envelope component histories", .serialized, .gpuThreads)
struct EnvelopeComponentHistoryTests {
    /// A 2 m wall, 0.5 m thick, in a closed 8 m box of air.
    func scene(openings: [Box] = []) throws -> Scenario {
        var scene = Scenario(
            name: "Wall", domainSize: SIMD3(8, 8, 6), boxes: [],
            charge: Charge(mass: 0, position: SIMD3(1, 1, 1)))
        scene.reflectiveFaces = .all
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(3, 3, 0), max: SIMD3(5, 3.5, 3))], openings: openings),
            name: "Wall")
        return scene
    }

    @Test("Uniform pressure fills each bin by its overlap with the steps, the last partial")
    func uniform() throws {
        let scene = try scene()
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 103_325))
        solver.restart()
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.001))
        let command = try #require(solver.encodeBatch(steps: 50, timeLimit: 0.00025))
        command.commit()
        command.waitUntilCompleted()
        _ = solver.completeBatch()
        let history = try #require(solver.envelopeComponentHistories()?.first)
        #expect(history.component.kind == .wall && history.binS == 1e-4)
        #expect(history.outerAreaM2 == 6 && history.innerAreaM2 == 6 && history.faceCount == 48)
        // 2,000 Pa over each whole bin of 0.1 ms, and over the part of the last the run reached.
        let bins = Int((solver.time / 1e-4).rounded(.up))
        let expected = (0..<bins).map {
            Float(2000 * (min(solver.time, Double($0 + 1) * 1e-4) - Double($0) * 1e-4))
        }
        for side in [history.outerImpulsePaS, history.innerImpulsePaS] {
            #expect(side.count == bins)
            for (bin, expected) in zip(side, expected) { #expect(abs(bin - expected) < 1e-5) }
        }
        #expect(abs(history.peakOuterPa - 2000) < 0.1 && abs(history.peakNetPa) < 0.1)
        #expect(!history.truncated && !history.invalid && history.outerMaxPa == nil)
    }

    @Test("Refined air gives the surface recorder the load of a grid of its finest cells, as the components")
    func refinedFacade() throws {
        // 1 kg at 4 m from a closed box's front wall, on 0.25 m cells refined by 2 and on uniform
        // 0.125 m cells (`blastbench facade` at this scale: within 0.6% on 10 and 40 kg).
        func front(cellSize: Float, refinement: Int) throws -> (
            peak: Double, impulse: Double, surfacePeak: Double, surfaceImpulse: Double
        ) {
            var scene = Scenario(
                name: "Facade", domainSize: SIMD3(11, 7, 4), boxes: [],
                charge: Charge(mass: 1, position: SIMD3(2, 3.5, 0.25)))
            let solids = [
                Box(min: SIMD3(6, 2, 0), max: SIMD3(6.25, 5, 2)),
                Box(min: SIMD3(8.75, 2, 0), max: SIMD3(9, 5, 2)),
                Box(min: SIMD3(6.25, 2, 0), max: SIMD3(8.75, 2.25, 2)),
                Box(min: SIMD3(6.25, 4.75, 0), max: SIMD3(8.75, 5, 2)),
                Box(min: SIMD3(6, 2, 1.75), max: SIMD3(9, 5, 2)),
            ]
            try scene.addEnvelopeObject(BuildingEnvelope(solids: solids), name: "Building")
            // Pinned to the balloon until rerun on the mapped start (validation.md, "Still on the balloon start").
            var configuration = SolverConfiguration.recommended.balloonStart
            configuration.refinement = refinement
            configuration.refinementMemory = 64 << 20
            let solver = try BlastSolver(
                device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: cellSize,
                configuration: configuration)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.012))
            try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
            _ = solver.advance(until: 0.012)
            let surface = try #require(solver.envelopeExposureSummaries()?.first)
            let wall = try #require(
                solver.envelopeComponentHistories()?.first {
                    $0.component.kind == .wall && $0.component.source == 0
                })
            return (
                Double(wall.peakOuterPa), wall.outerImpulsePaS.map(Double.init).reduce(0, +),
                Double(surface.peakPositivePa), surface.surfacePositiveImpulseNS
            )
        }
        let refined = try front(cellSize: 0.25, refinement: 2)
        let uniform = try front(cellSize: 0.125, refinement: 1)
        let coarse = try front(cellSize: 0.25, refinement: 1)
        #expect(abs(refined.peak / uniform.peak - 1) < 0.03, "\(refined.peak) Pa against \(uniform.peak)")
        #expect(
            abs(refined.impulse / uniform.impulse - 1) < 0.03, "\(refined.impulse) against \(uniform.impulse)"
        )
        #expect(uniform.peak > 1.1 * coarse.peak)
        #expect(
            abs(refined.surfacePeak / uniform.surfacePeak - 1) < 0.03,
            "\(refined.surfacePeak) Pa against \(uniform.surfacePeak)")
        #expect(
            abs(refined.surfaceImpulse / uniform.surfaceImpulse - 1) < 0.03,
            "\(refined.surfaceImpulse) against \(uniform.surfaceImpulse)")
        #expect(uniform.surfacePeak > 1.1 * coarse.surfacePeak)
    }

    @Test("Each side's binned impulse is the mean of its faces' own integrals")
    func againstFaces() throws {
        // The street study's building, four walls and a roof: components in more than one
        // threadgroup.
        var scene = Scenario(
            name: "Building", domainSize: SIMD3(12, 12, 6), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(6, 1.5, 1)))
        scene.reflectiveFaces = .all
        let solids = [
            Box(min: SIMD3(3, 3, 0), max: SIMD3(9, 3.5, 4)), Box(min: SIMD3(3, 8.5, 0), max: SIMD3(9, 9, 4)),
            Box(min: SIMD3(3, 3.5, 0), max: SIMD3(3.5, 8.5, 4)),
            Box(min: SIMD3(8.5, 3.5, 0), max: SIMD3(9, 8.5, 4)),
            Box(min: SIMD3(3, 3, 4), max: SIMD3(9, 9, 4.5)),
        ]
        try scene.addEnvelopeObject(BuildingEnvelope(solids: solids), name: "Building")
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.25)
        try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
        _ = solver.advance(steps: 60)
        let faces = try #require(solver.envelopeExposureSnapshot()?.first?.surfaces)
        let histories = try #require(solver.envelopeComponentHistories())
        #expect(histories.count == 5 && histories.contains { $0.peakOuterPa > 1000 })
        for history in histories {
            let component = history.component
            for (outward, binned) in [
                (component.outward, history.outerImpulsePaS), (-component.outward, history.innerImpulsePaS),
            ] {
                let own = faces.filter { face in
                    let solid = face.positionM - face.normal * 0.125
                    return face.normal[component.axis] == Float(outward)
                        && (0..<3).allSatisfy {
                            solid[$0] >= component.region.min[$0] && solid[$0] <= component.region.max[$0]
                        }
                }
                #expect(!own.isEmpty)
                let mean = own.map { Double($0.signedImpulsePaS) }.reduce(0, +) / Double(own.count)
                let sum = binned.map(Double.init).reduce(0, +)
                #expect(
                    abs(sum - mean) <= 1e-4 * abs(mean) + 1e-6, "\(component.id) \(outward): \(sum) \(mean)")
            }
            #expect(!history.truncated)
            #expect(history.outerMaxPa?.count == history.outerImpulsePaS.count)
            #expect(history.outerMaxPa?.max() == history.peakOuterPa)
            // Its equivalent uniform loads likewise, of the faces' integrals weighted by its shape
            // (Biggs's ∫pφ / ∫φ): the plate's over every face, the strip's over the middle third
            // across its span.
            let axes = (0..<3).filter { $0 != component.axis }
            let edges =
                component.supportEdges.contains(true) ? component.supportEdges : [true, true, true, true]
            let held = [(edges[0], edges[1]), (edges[2], edges[3])]
            let free = (0..<2).filter { !held[$0].0 && !held[$0].1 }
            let across =
                free.count == 1
                ? free[0] : component.region.size[axes[1]] > component.region.size[axes[0]] ? 1 : 0
            for (strip, equivalent) in [(false, history.plate), (true, history.strip)] {
                let equivalent = try #require(equivalent, "\(component.id)")
                for (outward, binned) in [
                    (component.outward, equivalent.outerImpulsePaS),
                    (-component.outward, equivalent.innerImpulsePaS),
                ] {
                    var weighted = 0.0
                    var total = 0.0
                    for face in faces where face.normal[component.axis] == Float(outward) {
                        let solid = face.positionM - face.normal * 0.125
                        guard
                            (0..<3).allSatisfy({
                                solid[$0] >= component.region.min[$0] && solid[$0] <= component.region.max[$0]
                            })
                        else { continue }
                        let at = (0..<2).map { a in
                            min(
                                max(
                                    (solid[axes[a]] - component.region.min[axes[a]])
                                        / component.region.size[axes[a]], 0), 1)
                        }
                        if strip && abs(at[across] - 0.5) > 1.0 / 6 + 1e-6 { continue }
                        var phi: Float = 1
                        for a in 0..<2 where !(strip && a == across) {
                            phi *= EnvelopeComponentRecorder.shape(at[a], low: held[a].0, high: held[a].1)
                        }
                        weighted += Double(phi) * Double(face.signedImpulsePaS)
                        total += Double(phi)
                    }
                    #expect(total > 0)
                    let expected = weighted / total
                    let sum = binned.map(Double.init).reduce(0, +)
                    #expect(
                        abs(sum - expected) <= 1e-3 * abs(expected) + 1e-5,
                        "\(component.id) \(strip ? "strip" : "plate") \(outward): \(sum) \(expected)")
                }
            }
        }
    }

    @Test(
        "Recording the equivalent loads leaves every component's own history bit-identical, and one without room keeps none"
    )
    func equivalentsPassive() throws {
        var scene = try scene()
        scene.charge = Charge(mass: 0.05, position: SIMD3(4, 1.5, 1))
        let device = try #require(MTLCreateSystemDefaultDevice())
        func histories(_ options: EnvelopeHistoryOptions) throws -> [EnvelopeComponentHistory] {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            try solver.configureEnvelopeComponents(objects: scene.envelopeObjects, options: options)
            _ = solver.advance(steps: 60)
            return try #require(solver.envelopeComponentHistories())
        }
        let with = try histories(EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
        let without = try histories(
            EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true, governingBands: false))
        #expect(with.contains { $0.plate != nil && $0.strip != nil })
        #expect(without.allSatisfy { $0.plate == nil && $0.strip == nil })
        for (a, b) in zip(with, without) {
            #expect(a.outerImpulsePaS.map(\.bitPattern) == b.outerImpulsePaS.map(\.bitPattern))
            #expect(a.innerImpulsePaS.map(\.bitPattern) == b.innerImpulsePaS.map(\.bitPattern))
            #expect(a.outerMaxPa!.map(\.bitPattern) == b.outerMaxPa!.map(\.bitPattern))
            #expect(a.peakNetPa.bitPattern == b.peakNetPa.bitPattern)
        }
        // A budget the components alone fill keeps their bins' width, and no equivalent loads.
        // (0.05 s of 0.1 ms bins and one over, 8 bytes each.)
        let tight = try histories(EnvelopeHistoryOptions(windowS: 0.05, memoryBudget: with.count * 501 * 8))
        #expect(tight.allSatisfy { $0.plate == nil && $0.strip == nil && $0.binS == with[0].binS })
    }

    @Test("A face in still air reads the still air: the same bits as reading its cell")
    func stillTiles() throws {
        var scene = Scenario(
            name: "Two walls", domainSize: SIMD3(24, 8, 6), boxes: [],
            charge: Charge(mass: 0.05, position: SIMD3(2, 4, 1)))
        for x: Float in [5, 19] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(solids: [Box(min: SIMD3(x, 2, 0), max: SIMD3(x + 0.5, 6, 3))]),
                name: "Wall \(x)")
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        func histories(skipping: Bool) throws -> [EnvelopeComponentHistory] {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects,
                options: EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
            solver.envelopeComponentRecorder?.skipStillTiles = skipping
            _ = solver.advance(steps: 40)
            return try #require(solver.envelopeComponentHistories())
        }
        let skipped = try histories(skipping: true)
        let read = try histories(skipping: false)
        // The far wall stays in still air through the run, the near one does not.
        #expect(skipped.first!.peakOuterPa != skipped.last!.peakOuterPa)
        for (a, b) in zip(skipped, read) {
            #expect(a.outerImpulsePaS.map(\.bitPattern) == b.outerImpulsePaS.map(\.bitPattern))
            #expect(a.innerImpulsePaS.map(\.bitPattern) == b.innerImpulsePaS.map(\.bitPattern))
            #expect(a.outerMaxPa!.map(\.bitPattern) == b.outerMaxPa!.map(\.bitPattern))
            #expect(a.peakNetPa.bitPattern == b.peakNetPa.bitPattern)
        }
    }

    @Test(
        "A window from arrival holds the same bins as one from t = 0, from the bin the blast reached it in",
        arguments: [Float(0), 500])
    func fromArrival(arrivalPa: Float) throws {
        var scene = Scenario(
            name: "Two walls", domainSize: SIMD3(16, 8, 6), boxes: [],
            charge: Charge(mass: 0.2, position: SIMD3(2, 4, 1)))
        for x: Float in [4, 12] {
            try scene.addEnvelopeObject(
                BuildingEnvelope(
                    solids: [Box(min: SIMD3(x, 2, 0), max: SIMD3(x + 0.5, 6, 3))],
                    panes: [Box(min: SIMD3(x, 3, 1), max: SIMD3(x + 0.25, 5, 2))]),
                name: "Wall \(x)")
        }
        let device = try #require(MTLCreateSystemDefaultDevice())
        func histories(fromArrival: Bool, threshold: Float = arrivalPa) throws -> [EnvelopeComponentHistory] {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects,
                options: EnvelopeHistoryOptions(
                    windowS: 0.05, binMaxima: true, windowFromArrival: fromArrival, arrivalPa: threshold))
            _ = solver.advance(steps: 160)
            return try #require(solver.envelopeComponentHistories())
        }
        let zero = try histories(fromArrival: false)
        let arrival = try histories(fromArrival: true)
        #expect(zero.allSatisfy { $0.windowStartS == nil })
        let near = try #require(arrival.first?.windowStartS)
        let far = try #require(arrival.last?.windowStartS)
        #expect(far > near, "\(arrival.map(\.windowStartS))")
        for (a, b) in zip(zero, arrival) {
            let start = Int((b.windowStartS! / b.binS).rounded())
            #expect(b.outerImpulsePaS.count == a.outerImpulsePaS.count - start)
            // Past an overpressure, the first bin holds only the steps from the one that passed it;
            // the earlier part of that bin, under the threshold, is left out.
            let same = arrivalPa > 0 ? 1 : 0
            #expect(
                a.outerImpulsePaS.dropFirst(start + same).map(\.bitPattern)
                    == b.outerImpulsePaS.dropFirst(same).map(\.bitPattern))
            #expect(
                a.innerImpulsePaS.dropFirst(start + same).map(\.bitPattern)
                    == b.innerImpulsePaS.dropFirst(same).map(\.bitPattern))
            #expect(
                a.outerMaxPa!.dropFirst(start + same).map(\.bitPattern)
                    == b.outerMaxPa!.dropFirst(same).map(\.bitPattern))
            let left = Float(Double(arrivalPa) * b.binS * 1.001) + 1e-9
            let outerGap: Float = abs(a.outerImpulsePaS[start] - b.outerImpulsePaS[0])
            let innerGap: Float = abs(a.innerImpulsePaS[start] - b.innerImpulsePaS[0])
            #expect(outerGap <= left && innerGap <= left)
            #expect(a.peakNetPa.bitPattern == b.peakNetPa.bitPattern)
            if arrivalPa == 0 {
                // Before it, the air at the wall was still.
                #expect(a.outerImpulsePaS.prefix(start).allSatisfy { abs($0) < 1e-6 })
            } else {
                // Before it, no step on either side passed the threshold; in its first bin one did.
                #expect(a.outerMaxPa!.prefix(start).allSatisfy { $0 <= arrivalPa })
                #expect(a.innerMaxPa!.prefix(start).allSatisfy { $0 <= arrivalPa })
                #expect(max(b.outerMaxPa!.first!, b.innerMaxPa!.first!) > arrivalPa)
            }
        }
        if arrivalPa > 0 {
            // No earlier than the air's first moving.
            let waking = try histories(fromArrival: true, threshold: 0)
            for (a, b) in zip(waking, arrival) { #expect(b.windowStartS! >= a.windowStartS!) }
        }
        // Judged, the two agree, times from t = 0.
        func judged(_ histories: [EnvelopeComponentHistory]) -> [EnvelopeBuildingDamage] {
            EnvelopeDamageAssessment.assess(
                loads: histories.map(EnvelopeComponentLoad.init),
                constructions: { scene.envelopeConstruction(for: $0) },
                rooms: Dictionary(uniqueKeysWithValues: scene.envelopeObjects.map { ($0.id, 2.0) }))
        }
        let (fromZero, fromArrival) = (judged(zero), judged(arrival))
        #expect(fromZero.map(\.panesBroken) == fromArrival.map(\.panesBroken))
        #expect(fromZero.contains { $0.panesBroken > 0 })
        for (a, b) in zip(fromZero, fromArrival) {
            #expect(abs((a.firstPaneBrokenAtS ?? 0) - (b.firstPaneBrokenAtS ?? 0)) <= 1e-4)
            #expect(abs(a.insidePeakPa - b.insidePeakPa) <= 1e-3 * a.insidePeakPa + 1)
        }
    }

    @Test("Saved options without the arrival's overpressure start their windows as the air moves")
    func arrivalDecoding() throws {
        let options = EnvelopeHistoryOptions(windowS: 0.5, windowFromArrival: true)
        #expect(options.arrivalPa == 500)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        #expect(json["arrivalPa"] as? Double == 500)
        json["arrivalPa"] = nil
        let old = try JSONDecoder().decode(
            EnvelopeHistoryOptions.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.arrivalPa == 0)
    }

    @Test("Histories repeat bit for bit however the steps are cut into batches")
    func batching() throws {
        var scene = try scene()
        scene.charge = Charge(mass: 0.05, position: SIMD3(4, 1.5, 1))
        let device = try #require(MTLCreateSystemDefaultDevice())
        func histories(_ batch: Int) throws -> [EnvelopeComponentHistory] {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects,
                options: EnvelopeHistoryOptions(windowS: 0.05, binMaxima: true))
            for _ in 0..<(48 / batch) { _ = solver.advance(steps: batch) }
            return try #require(solver.envelopeComponentHistories())
        }
        let whole = try histories(48)
        for batch in [1, 5] {
            let cut = try histories(batch == 5 ? 6 : batch)
            for (a, b) in zip(whole, cut) {
                #expect(
                    a.outerImpulsePaS.map(\.bitPattern) == b.outerImpulsePaS.map(\.bitPattern), "\(batch)")
                #expect(
                    a.innerImpulsePaS.map(\.bitPattern) == b.innerImpulsePaS.map(\.bitPattern), "\(batch)")
                #expect(a.peakNetPa.bitPattern == b.peakNetPa.bitPattern)
            }
        }
    }

    @Test("Recording leaves coarse and refined air bit-identical", arguments: [1, 2])
    func passive(refinement: Int) throws {
        var scene = try scene()
        scene.charge = Charge(mass: 0.02, position: SIMD3(4, 1.5, 1))
        var config = SolverConfiguration()
        config.refinement = refinement
        config.refinementMemory = 16 << 20
        let device = try #require(MTLCreateSystemDefaultDevice())
        let plain = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        let observed = try BlastSolver(device: device, scenario: scene, cellSize: 0.5, configuration: config)
        try observed.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(windowS: 0.01, openingsAsPanes: true))
        _ = plain.advance(steps: 16)
        _ = observed.advance(steps: 16)
        let states = plain.withState { Array($0) }
        observed.withState { cells in
            #expect(
                zip(states, cells).allSatisfy { a, b in
                    a.density == b.density && a.energy == b.energy && a.momentumX == b.momentumX
                        && a.momentumY == b.momentumY && a.momentumZ == b.momentumZ
                })
        }
    }

    @Test(
        "In refined air a wall reads the finest cells against it: nearer the finer grid's peak than its coarse cells"
    )
    func refinedFaces() throws {
        var scene = Scenario(
            name: "Wall", domainSize: SIMD3(10, 10, 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(3, 5, 0.5)))
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(6, 2, 0), max: SIMD3(6.5, 8, 3))]), name: "Wall")
        let device = try #require(MTLCreateSystemDefaultDevice())
        func peak(cell: Float, refinement: Int, fine: Bool) throws -> Float {
            var config = SolverConfiguration()
            config.refinement = refinement
            config.refinementMemory = 64 << 20
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: cell, configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.01))
            solver.envelopeComponentRecorder?.readsRefinedAir = fine
            _ = solver.advance(until: 0.008)
            // The side facing the charge, which for a wall alone may be its inner.
            return try #require(
                solver.envelopeComponentHistories()?.map { max($0.peakOuterPa, $0.peakInnerPa) }.max())
        }
        let uniform = try peak(cell: 0.25, refinement: 1, fine: true)
        let refinedFine = try peak(cell: 0.5, refinement: 2, fine: true)
        let refinedCoarse = try peak(cell: 0.5, refinement: 2, fine: false)
        // 24.4 kPa on 0.25 m cells; refined, 24.3 kPa read fine and 21.9 kPa read coarse.
        #expect(refinedFine > refinedCoarse, "\(refinedFine) \(refinedCoarse)")
        #expect(
            abs(refinedFine - uniform) < abs(refinedCoarse - uniform),
            "\(refinedFine) \(refinedCoarse) \(uniform)")
    }

    @Test("A refinement ceiling keeps the refined air below it, at both levels, and changes nothing unset")
    func refinementCeiling() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(12, 12, 8), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(6, 6, 0.5)))
        let device = try #require(MTLCreateSystemDefaultDevice())
        func run(_ ceiling: Float?) throws -> (rows: [[Int]], digest: [Float]) {
            var config = SolverConfiguration()
            config.refinement = 2
            config.refinementLevels = 2
            config.refinementMemory = 64 << 20
            config.refinementCeiling = ceiling
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: 0.25, configuration: config)
            var rows: [[Int]] = []
            while solver.time < 0.01 {
                let batch = solver.advance(steps: 8, timeLimit: 0.01)
                if batch.steps == 0 { break }
                let now = solver.refinedBlocksByHeight()
                rows = rows.isEmpty ? now : zip(rows, now).map { zip($0, $1).map { max($0, $1) } }
            }
            let digest = solver.withState { cells in
                stride(from: 0, to: cells.count, by: 997).map { cells[$0].density + cells[$0].energy }
            }
            return (rows, digest)
        }
        let free = try run(nil)
        let capped = try run(2)
        // Blocks are 4 coarse cells (1 m) high at the first level and 4 of its cells (0.5 m) at the
        // second. Capped at 2 m, none from 4 m up: the sphere left free about the charge reaches
        // 2.9 m, and a jump just below it refines the block round it, which may reach the block over
        // it. Some there without.
        #expect(
            free.rows[0].dropFirst(4).reduce(0, +) > 0 && free.rows[1].dropFirst(8).reduce(0, +) > 0,
            "\(free.rows) \(capped.rows)")
        #expect(capped.rows[0].dropFirst(4).allSatisfy { $0 == 0 }, "\(capped.rows[0])")
        #expect(capped.rows[1].dropFirst(8).allSatisfy { $0 == 0 }, "\(capped.rows[1])")
        #expect(capped.rows[0].prefix(2).reduce(0, +) > 0 && capped.rows[1].prefix(4).reduce(0, +) > 0)
        // A ceiling above the domain is no ceiling: the same air, bit for bit.
        let high = try run(100)
        #expect(high.digest.map(\.bitPattern) == free.digest.map(\.bitPattern))
    }

    @Test(
        "A solver loaded again without its ceiling runs as one that never had it; a raised charge stays refined"
    )
    func refinementCeilingReused() throws {
        let scene = Scenario(
            name: "Open", domainSize: SIMD3(12, 12, 8), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(6, 6, 0.5)))
        let device = try #require(MTLCreateSystemDefaultDevice())
        var config = SolverConfiguration()
        config.refinement = 2
        config.refinementLevels = 2
        config.refinementMemory = 64 << 20
        func digest(_ solver: BlastSolver) -> [UInt32] {
            solver.withState { cells in
                stride(from: 0, to: cells.count, by: 997).map {
                    (cells[$0].density + cells[$0].energy).bitPattern
                }
            }
        }
        // Run with a ceiling, then load the same solver again without it, as the app reuses one.
        var capped = config
        capped.refinementCeiling = 2
        let reused = try BlastSolver(device: device, scenario: scene, cellSize: 0.25, configuration: capped)
        _ = reused.advance(steps: 24)
        reused.configuration.refinementCeiling = nil
        try reused.load(scene)
        _ = reused.advance(steps: 24)
        let fresh = try BlastSolver(device: device, scenario: scene, cellSize: 0.25, configuration: config)
        _ = fresh.advance(steps: 24)
        #expect(digest(reused) == digest(fresh))
        // A charge 5 m up, over a 2 m ceiling: its near field (3 m/kg^(1/3), 2.4 m) is refined still.
        var raised = scene
        raised.charge.position.z = 5
        let high = try BlastSolver(device: device, scenario: raised, cellSize: 0.25, configuration: capped)
        _ = high.advance(steps: 16)
        #expect(high.refinedBlocksByHeight()[0].dropFirst(3).reduce(0, +) > 0)
    }

    @Test("Refinement held beside a wall while its air is loaded keeps it fine after the shock has gone")
    func heldBand() throws {
        var scene = Scenario(
            name: "Wall", domainSize: SIMD3(10, 10, 4), boxes: [],
            charge: Charge(mass: 0.5, position: SIMD3(3, 5, 0.5)))
        try scene.addEnvelopeObject(
            BuildingEnvelope(solids: [Box(min: SIMD3(6, 2, 0), max: SIMD3(6.5, 8, 3))]), name: "Wall")
        let device = try #require(MTLCreateSystemDefaultDevice())
        func run(cell: Float, refinement: Int, hold: Float?) throws -> (impulse: Double, patches: Int) {
            var config = SolverConfiguration()
            config.refinement = refinement
            config.refinementMemory = 64 << 20
            config.refinementHoldsEnvelopes = hold
            let solver = try BlastSolver(
                device: device, scenario: scene, cellSize: cell, configuration: config)
            try solver.configureEnvelopeComponents(
                objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.02))
            var patches = 0
            while solver.time < 0.02 {
                let batch = solver.advance(steps: 8, timeLimit: 0.02)
                patches = batch.refinedTiles
                if batch.steps == 0 { break }
            }
            // The side facing the charge: the larger impulse.
            let histories = try #require(solver.envelopeComponentHistories())
            let impulse =
                histories.map { h in
                    max(
                        h.outerImpulsePaS.reduce(0) { $0 + Double($1) },
                        h.innerImpulsePaS.reduce(0) { $0 + Double($1) })
                }.max() ?? 0
            return (impulse, patches)
        }
        let uniform = try run(cell: 0.25, refinement: 1, hold: nil)
        let free = try run(cell: 0.5, refinement: 2, hold: nil)
        let held = try run(cell: 0.5, refinement: 2, hold: 100)
        // At 20 ms the shock has left: no patch is left without the band, 20 with it; the wall's
        // net impulse 11.35 Pa s without, 10.43 with, against 10.47 on uniform 0.25 m cells.
        #expect(held.patches > free.patches, "\(held.patches) \(free.patches)")
        #expect(
            abs(held.impulse - uniform.impulse) <= abs(free.impulse - uniform.impulse) * 1.001,
            "\(held.impulse) \(free.impulse) \(uniform.impulse)")
    }

    @Test("Past the window steps are not binned and say so; a budget too small widens the bins")
    func windowAndBudget() throws {
        let scene = try scene()
        let device = try #require(MTLCreateSystemDefaultDevice())
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        solver.fill(uniform: Primitive(density: 1.225, pressure: 103_325))
        solver.restart()
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.0001))
        let command = try #require(solver.encodeBatch(steps: 50, timeLimit: 0.0004))
        command.commit()
        command.waitUntilCompleted()
        _ = solver.completeBatch()
        let history = try #require(solver.envelopeComponentHistories()?.first)
        #expect(history.truncated && history.outerImpulsePaS.count == 2)
        // One component: 8 bytes a bin; five bins fit 40 bytes, so 1 ms of 0.1 ms bins widens to 0.3 ms.
        let budgeted = try BlastSolver(device: device, scenario: scene, cellSize: 0.5)
        try budgeted.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.001, memoryBudget: 40))
        _ = budgeted.advance(steps: 1)
        #expect(budgeted.envelopeComponentHistories()?.first.map { abs($0.binS - 3e-4) < 1e-12 } == true)
    }

    @Test("An opening recorded as a pane reads the air just outside the wall on both sides")
    func openingAsPane() throws {
        let scene = try scene(openings: [Box(min: SIMD3(3.5, 3, 1), max: SIMD3(4.5, 3.5, 2))])
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(windowS: 0.001, openingsAsPanes: true))
        let components = try #require(solver.envelopeComponents())
        let opening = try #require(components.last)
        #expect(opening.id.hasSuffix("/opening/0") && opening.kind == .pane && opening.axis == 1)
        _ = solver.advance(steps: 2)
        let history = try #require(solver.envelopeComponentHistories()?.last)
        // Two cells by two on each side.
        #expect(history.outerAreaM2 == 1 && history.innerAreaM2 == 1)
    }

    @Test(
        "Cost: a neighbourhood's histories take a few MB, under three times that with their equivalent loads, and read no more cells than the surface recorder"
    )
    func cost() throws {
        var scene = Scenario(
            name: "Neighbourhood", domainSize: SIMD3(96, 96, 8), boxes: [],
            charge: Charge(mass: 2, position: SIMD3(4, 4, 1)))
        let template = try #require(
            try StreetInteractionStudy.make(.isolated, clamped: true).structuralObjects.first?.structure)
        for index in 0..<64 {
            let offset = SIMD3<Float>(10 + Float(index % 8) * 10 - 16, 10 + Float(index / 8) * 10 - 6, 0)
            try scene.addEnvelopeObject(
                BuildingEnvelope(
                    solids: template.solids.map { Box(min: $0.min + offset, max: $0.max + offset) }),
                name: "Building \(index + 1)")
        }
        let solver = try BlastSolver(
            device: #require(MTLCreateSystemDefaultDevice()), scenario: scene, cellSize: 0.5)
        let before = solver.memoryFootprint
        try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
        let surfaces = solver.memoryFootprint - before
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects,
            options: EnvelopeHistoryOptions(windowS: 0.06, governingBands: false))
        let histories = solver.memoryFootprint - before - surfaces
        let components = try #require(solver.envelopeComponents())
        #expect(components.count == 64 * 5)
        // 320 components, 601 bins of two sides, and their faces once (with their weights).
        #expect(histories < 2_600_000, "\(histories) bytes")
        // With their equivalent loads, three times the bins and the faces about twice again.
        try solver.configureEnvelopeComponents(
            objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.06))
        let equivalents = solver.memoryFootprint - before - surfaces
        print("Neighbourhood histories: \(histories) bytes, \(equivalents) with their equivalent loads")
        #expect(equivalents < 3 * histories, "\(equivalents) bytes")
        let faces = solver.envelopeExposureSnapshot()!.reduce(0) { $0 + $1.surfaces.count }
        let read = solver.envelopeComponentHistories()!.reduce(0) { $0 + $1.faceCount }
        #expect(read <= faces, "\(read) cells read a step against \(faces) faces")
        #expect(surfaces > 0)
    }

    @Test("Beside a moving structure an envelope is recorded and judged, its faces' air never taken")
    func besideMovingStructure() throws {
        // A concrete wall a cell from an envelope's face, thrown 0.3 m towards it by 80 kg.
        var scene = Scenario(
            name: "Wall beside an envelope", domainSize: SIMD3(10, 6, 4), boxes: [],
            charge: Charge(mass: 80, position: SIMD3(4, 3, 1.2)))
        let wall = Box(min: SIMD3(6, 1.5, 0), max: SIMD3(6.25, 4.5, 2.5))
        scene.objects.append(
            SceneObject(
                name: "Wall",
                representation: .deformable(
                    StructureModel(
                        solids: [wall], material: .reinforcedConcrete, elementSize: 0.125, fixedBase: true))))
        try scene.addEnvelopeObject(
            BuildingEnvelope(
                solids: [Box(min: SIMD3(6.5, 1, 0), max: SIMD3(7, 5, 3))],
                panes: [Box(min: SIMD3(6.5, 2, 1), max: SIMD3(6.75, 3, 2))]),
            name: "Envelope")
        let device = try #require(MTLCreateSystemDefaultDevice())
        // The envelope's west face's air: the cells at x 6.25–6.5 m across it.
        let face = (0..<12).flatMap { k in (4..<20).map { j in (25, j, k) } }
        let inside = (0..<12).flatMap { k in (4..<20).map { j in (26, j, k) } }
        func run(observed: Bool) throws -> (solver: BlastSolver, taken: Int) {
            let solver = try BlastSolver(device: device, scenario: scene, cellSize: 0.25)
            if observed {
                try solver.configureEnvelopeExposure(objects: scene.envelopeObjects)
                try solver.configureEnvelopeComponents(
                    objects: scene.envelopeObjects, options: EnvelopeHistoryOptions(windowS: 0.05))
            }
            var taken = 0
            for _ in 0..<10 {
                _ = solver.advance(until: solver.time + 0.005)
                taken = max(taken, face.filter { solver.isSolid($0.0, $0.1, $0.2) }.count)
                #expect(inside.allSatisfy { solver.isSolid($0.0, $0.1, $0.2) })
            }
            return (solver, taken)
        }
        // Unobserved, the wall takes half the face's air as it comes; observed, none of it.
        let unobserved = try run(observed: false)
        #expect(unobserved.taken > 50, "\(unobserved.taken)")
        let observed = try run(observed: true)
        #expect(observed.taken == 0)
        #expect(observed.solver.keptAirCells?.contains(observed.solver.grid.index(25, 12, 4)) == true)
        let summary = try #require(observed.solver.bodySummary())
        #expect(summary.maxDisplacement > 0.25, "\(summary.maxDisplacement)")
        // Its components are recorded, and the building judged.
        let histories = try #require(observed.solver.envelopeComponentHistories())
        let loads = histories.filter { !$0.invalid }.map(EnvelopeComponentLoad.init)
        #expect(!loads.isEmpty)
        let damage = EnvelopeDamageAssessment.assess(
            loads: loads, constructions: { scene.envelopeConstruction(for: $0) },
            rooms: [scene.envelopeObjects[0].id: 1])
        #expect(damage.count == 1 && damage[0].panes == 1)
        // The standing says the envelopes are one way beside the structure, and not without one.
        func says(_ scenario: Scenario) -> Bool {
            let standing = SceneStanding(
                StandingInputs(scenario: scenario, cellSize: 0.25, configuration: .init()))
            return standing.results.filter { $0.kind == .envelopeDamage || $0.kind == .envelopeExposure }
                .allSatisfy { $0.assumptions.contains(StandingScene.envelopesBesideStructures) }
        }
        #expect(says(scene))
        // Nothing is kept without a body: an envelope-only scene runs as before.
        var alone = scene
        try alone.removeObject(id: scene.structuralObjects[0].id)
        let only = try BlastSolver(device: device, scenario: alone, cellSize: 0.25)
        try only.configureEnvelopeExposure(objects: alone.envelopeObjects)
        #expect(only.keptAirCells == nil)
        #expect(!says(alone))
    }
}
