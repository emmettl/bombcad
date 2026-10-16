import BlastCore
import Foundation
import Metal
import simd

/// Stage 3a of the envelope damage work: the matched street layouts with their detailed
/// buildings free to respond, recording each component's deflection, rotation, failure and
/// glass breakage under the component ids of the agreed specification
/// (/Volumes/StudioData/bombcad/envelope-damage/component-spec.md, v1.2, §4–§6), so that the
/// one-way SDOF model on envelope loads can be set against them. Invented buildings: numerical
/// references, not measured damage.
enum EnvelopeDamageBenchmark {
    enum Wall: String, Codable, CaseIterable {
        /// 0.2 m reinforced concrete, one central mesh at 0.3%.
        case rc
        /// 0.215 m brick, smeared masonry (shells have no units and joints).
        case brick
        /// The RC walls with one 6 mm annealed glass pane in each façade.
        case glass
    }

    struct Record: Codable {
        var schemaVersion = 1
        var spec = "component-spec.md v1.2"
        var sourceRevision: String
        var device: String
        var layout: String
        var wall: Wall
        var chargeKg: Float
        var chargePosition: SIMD3<Float>
        var domainSize: SIMD3<Float>
        /// Added to every position of `StreetInteractionStudy`, whose domain this enlarges.
        var offset: SIMD3<Float>
        var air: Air
        var mesh: Mesh
        var durationS: Double
        var binS: Double
        var wallClockS: Double
        var stable: Bool
        var settleTimeS: Double
        var settleDampingPerS: Float
        /// Each building's fastest node once settled (m/s): how far from rest the blast found it.
        var settledFastestNodeMPerS: [String: Float]
        var notes: [String]
        var components: [Component]
        var gauges: [GaugeRecord]
    }

    struct Air: Codable {
        var cellSizeM: Float
        var afterburning: Bool
        var airModel: String
        var openFaces: String
        var refinement: Int
        var airSleep: Bool
    }

    struct Mesh: Codable {
        var shellElementSizeM: Float
        var shellLayers: Int
        var wallThicknessM: Float
        var roofThicknessM: Float
        var paneThicknessM: Float
        var fixedBase: Bool
    }

    struct Component: Codable {
        /// "<owner>/<kind>/<source>.<panel>", one panel per member here.
        var id: String
        var owner: UUID
        var building: String
        var kind: String
        var region: [SIMD3<Float>]
        var axis: Int
        var outward: Int
        var material: String
        /// Shorter and longer in-plane spans of the region (m).
        var shortSpanM: Float
        var longSpanM: Float
        var centreNode: SIMD3<Float>
        var supportEdgeNodes: Int
        /// Deflection under the building's weight once settled (m), from which `deflectionM` is measured.
        var settledDeflectionM: Float = 0
        /// Deflection along `axis` at the centre node less the support edges' mean, positive
        /// inward (towards the building's inside, or down for the roof), sampled at each bin's end.
        var deflectionM: [Float]
        var peakInwardM: Float
        var peakOutwardM: Float
        var peakM: Float
        var residualM: Float
        var rotationDeg: Float
        var elements: Int
        var failedShare: Float
        var shearFailedShare: Float
        var punchedShare: Float
        var broken: Bool?
        var brokenAtS: Double?
    }

    struct GaugeRecord: Codable {
        var name: String
        var position: SIMD3<Float>
        var peakOverpressurePa: Float
        var positiveImpulsePaS: Float
        /// Overpressure at each bin's end (Pa).
        var overpressurePa: [Float]
    }

    static let offset = SIMD3<Float>(8, 8, 0)
    static let domain = SIMD3<Float>(56, 48, 16)
    static let wallHeight: Float = 4
    static let roofThickness: Float = 0.2
    static let paneThickness: Float = 0.006
    static let elementSize: Float = 0.125
    static let layers = 8
    static let settleTime = 0.25
    static let settleDamping: Float = 300

    static func thickness(_ wall: Wall) -> Float { wall == .brick ? 0.215 : 0.2 }

    /// One building at the study's origin `(x, y)`: walls south, north, west, east (the study's
    /// order), the roof, then for glass one pane per façade, panes last so that the envelope's
    /// solids keep the members' indices.
    static func building(x: Float, y: Float, wall: Wall) -> StructureModel {
        let t = thickness(wall)
        let h = wallHeight
        var solids = [
            Box(min: SIMD3(x, y, 0), max: SIMD3(x + 6, y + t, h)),
            Box(min: SIMD3(x, y + 6 - t, 0), max: SIMD3(x + 6, y + 6, h)),
            Box(min: SIMD3(x, y + t, 0), max: SIMD3(x + t, y + 6 - t, h)),
            Box(min: SIMD3(x + 6 - t, y + t, 0), max: SIMD3(x + 6, y + 6 - t, h)),
            Box(min: SIMD3(x, y, h), max: SIMD3(x + 6, y + 6, h + roofThickness)),
        ]
        var model = StructureModel(
            solids: solids, material: .reinforcedConcrete, elementSize: elementSize, fixedBase: true)
        model.elementKind = .shell
        model.shellElementSize = elementSize
        model.shellLayers = layers
        if wall == .brick {
            var masonry = StructureMaterial.masonry
            masonry.units = nil
            for index in 0..<4 { model.setMaterial(masonry, of: index) }
        }
        // One central mesh of 0.3% in each wall (none in brick) and in the roof.
        for (index, box) in solids.enumerated() where wall != .brick || index == 4 {
            let axis = index == 4 ? 2 : index < 2 ? 1 : 0
            let depth = (box.max[axis] - box.min[axis]) / 2
            model.addMat(
                to: box, thicknessAxis: axis, areaPerMetre: 0.003 * (box.max[axis] - box.min[axis]),
                depth: depth, faces: (true, false))
        }
        if wall == .glass {
            // A window 1.5 m wide and 1.25 m tall, its sill 1 m up, in the middle of each wall:
            // a 6 mm pane in the wall's plane, listed after the walls. Coplanar plates that
            // overlap give one element of the later plate's material and thickness, so the pane
            // is the glazing and shares its edge nodes with the wall. (An opening would cut the
            // pane away with the wall: openings apply to every solid.)
            var panes: [Box] = []
            for index in 0..<4 {
                let box = solids[index]
                let axis = index < 2 ? 1 : 0
                let along = 1 - axis
                let middle = (box.min[along] + box.max[along]) / 2
                let plane = (box.min[axis] + box.max[axis]) / 2
                var low = SIMD3<Float>(0, 0, 1)
                var high = SIMD3<Float>(0, 0, 2.25)
                low[along] = middle - 0.75
                high[along] = middle + 0.75
                low[axis] = plane - paneThickness / 2
                high[axis] = plane + paneThickness / 2
                panes.append(Box(min: low, max: high))
            }
            solids += panes
            model.solids = solids
            for index in 5..<solids.count {
                model.setMaterial(.annealedGlass, of: index)
                model.setElementKind(.shell, of: index)
            }
        }
        return model
    }

    static func scene(layout: StreetInteractionStudy.Layout, wall: Wall, charge: Float) throws -> Scenario {
        let study = try StreetInteractionStudy.make(layout)
        var scene = Scenario(
            name: "Envelope damage: \(layout.rawValue), \(wall.rawValue), \(charge) kg", domainSize: domain,
            boxes: [], charge: Charge(mass: charge, position: study.charge.position + offset),
            gauges: study.gauges.map { Gauge($0.name, at: $0.position + offset) })
        for object in study.structuralObjects {
            let origin = object.structure!.bounds.min + offset
            try scene.addStructureObject(
                building(x: origin.x, y: origin.y, wall: wall), name: object.name, id: object.id)
            // Inside, at the middle of the floor plan and 1.5 m up.
            scene.gauges.append(Gauge("\(object.name) inside", at: SIMD3(origin.x + 3, origin.y + 3, 1.5)))
        }
        return scene
    }

    /// A component's nodes, edges and elements on the shell mesh.
    struct Tracked {
        var component: Component
        var axis: Int
        var centre: Int
        var edges: [Int]
        var elements: [Int]
        var samples: [(time: Double, value: Float)] = []
        var brokenAt: Double?
        var baseline: Float = 0
    }

    static func track(
        owner: SceneObject, model: StructureModel, shells: ShellSolver, wall: Wall
    ) -> [Tracked] {
        let h = model.shellElementSize ?? model.elementSize
        let glassFrom = wall == .glass ? 5 : model.solids.count
        let panes = Array(model.solids[glassFrom...])
        let bounds = model.bounds
        let centreOfBuilding = (bounds.min + bounds.max) / 2
        let references = shells.referencePositions
        let centres = (0..<shells.elementCount).map { shells.elementCentre($0) }
        var result: [Tracked] = []
        for (index, box) in model.solids.enumerated() {
            let size = box.max - box.min
            let axis = size.x <= size.y && size.x <= size.z ? 0 : size.y <= size.z ? 1 : 2
            let isPane = index >= glassFrom
            let kind = isPane ? "pane" : axis == 2 ? "roof" : "wall"
            let source = isPane ? index - glassFrom : index
            let middle = (box.min + box.max) / 2
            let outward = axis == 2 ? 1 : (middle[axis] - centreOfBuilding[axis] >= 0 ? 1 : -1)
            // Through the thickness to the mid-surface, and half an element in the plane so the
            // edge rows shared with neighbouring members count as this member's edges.
            var grown = Box(min: box.min - SIMD3(repeating: h / 2), max: box.max + SIMD3(repeating: h / 2))
            grown.min[axis] = box.min[axis] - h / 2
            grown.max[axis] = box.max[axis] + h / 2
            func inPane(_ p: SIMD3<Float>) -> Bool {
                panes.contains { pane in
                    var inner = pane
                    inner.min[axis] -= h
                    inner.max[axis] += h
                    // Strictly inside the pane's plane outline: its edge row is the wall's too.
                    let a = (axis + 1) % 3
                    let b = (axis + 2) % 3
                    let inA = p[a] > pane.min[a] + h / 4 && p[a] < pane.max[a] - h / 4
                    let inB = p[b] > pane.min[b] + h / 4 && p[b] < pane.max[b] - h / 4
                    let inAxis = p[axis] >= inner.min[axis] && p[axis] <= inner.max[axis]
                    return inA && inB && inAxis
                }
            }
            let nodes = references.indices.filter { n in
                grown.contains(references[n]) && (isPane || !inPane(references[n]))
            }
            let plane = [0, 1, 2].filter { $0 != axis }
            let spans = plane.map { box.max[$0] - box.min[$0] }
            // Support edges: the region's outermost rows of nodes in the plane. Every edge here
            // lies on another member, the ground or the wall around a pane.
            let low = plane.map { a in nodes.map { references[$0][a] }.min() ?? 0 }
            let high = plane.map { a in nodes.map { references[$0][a] }.max() ?? 0 }
            let edges = nodes.filter { n in
                plane.indices.contains { k in
                    references[n][plane[k]] <= low[k] + h / 2 || references[n][plane[k]] >= high[k] - h / 2
                }
            }
            let centre = nodes.min {
                simd_distance(references[$0], middle) < simd_distance(references[$1], middle)
            }
            // A pane's elements are those inside its outline; a member's, those in its grown box
            // and not in a pane.
            var outline = box
            outline.min[axis] -= h / 2
            outline.max[axis] += h / 2
            let elements = centres.indices.filter { e in
                isPane ? outline.contains(centres[e]) : grown.contains(centres[e]) && !inPane(centres[e])
            }
            if ProcessInfo.processInfo.environment["ENVELOPE_DAMAGE_DEBUG"] != nil {
                print(
                    "  solid \(index) \(kind) axis \(axis): \(nodes.count) nodes, \(edges.count) edges, \(elements.count) elements, box \(box.min) \(box.max)"
                )
            }
            guard let centre else { continue }
            let component = Component(
                id: "\(owner.id.uuidString)/\(kind)/\(source).0", owner: owner.id, building: owner.name,
                kind: kind,
                region: [box.min, box.max], axis: axis, outward: outward,
                material: isPane
                    ? "annealedGlass" : wall == .brick && index < 4 ? "masonry" : "reinforcedConcrete",
                shortSpanM: spans.min()!, longSpanM: spans.max()!, centreNode: references[centre],
                supportEdgeNodes: edges.count, deflectionM: [], peakInwardM: 0, peakOutwardM: 0, peakM: 0,
                residualM: 0, rotationDeg: 0, elements: elements.count, failedShare: 0, shearFailedShare: 0,
                punchedShare: 0, broken: isPane ? false : nil, brokenAtS: nil)
            result.append(
                Tracked(component: component, axis: axis, centre: centre, edges: edges, elements: elements))
        }
        return result
    }

    static func deflection(_ tracked: Tracked, _ shells: ShellSolver) -> Float {
        let axis = tracked.axis
        var edge: Float = 0
        for n in tracked.edges { edge += shells.node(n).displacement[axis] }
        edge /= Float(max(tracked.edges.count, 1))
        let relative = shells.node(tracked.centre).displacement[axis] - edge
        return -Float(tracked.component.outward) * relative
    }

    /// Values at each bin's end, linearly between samples (the last sample past the end held).
    static func binned(_ samples: [(time: Double, value: Float)], bin: Double, duration: Double) -> [Float] {
        let count = Int((duration / bin).rounded())
        var out: [Float] = []
        out.reserveCapacity(count)
        var j = 0
        for b in 1...max(count, 1) {
            let t = Double(b) * bin
            while j + 1 < samples.count && samples[j + 1].time < t { j += 1 }
            guard j + 1 < samples.count else {
                out.append(samples.last?.value ?? 0)
                continue
            }
            let (t0, v0) = samples[j]
            let (t1, v1) = samples[j + 1]
            let w = t1 > t0 ? Float((t - t0) / (t1 - t0)) : 1
            out.append(v0 + (v1 - v0) * min(max(w, 0), 1))
        }
        return out
    }

    static func runOne(
        device: MTLDevice, layout: StreetInteractionStudy.Layout, wall: Wall, charge: Float, dx: Float,
        duration: Double, bin: Double, revision: String, directory: URL
    ) throws {
        let scene = try scene(layout: layout, wall: wall, charge: charge)
        var config = SolverConfiguration.recommended
        config.airSleepThreshold = 0
        config.airSleepCrossings = 0
        let start = ProcessInfo.processInfo.systemUptime
        let solver = try BlastSolver(device: device, scenario: scene, cellSize: dx, configuration: config)
        var tracked: [(SceneObject, [Tracked])] = []
        var settledSpeed: [String: Float] = [:]
        for object in scene.structuralObjects {
            guard let body = solver.body(id: object.id), let shells = body.shells else {
                throw BlastError.allocationFailed("shell body for \(object.name)")
            }
            // Settled under their weight first, damped, so that the blast finds them at rest:
            // after cracking a brick wall holds by its weight (arching), and the records are
            // alike for every wall.
            shells.damping = settleDamping
            shells.advance(steps: Int((settleTime / Double(shells.criticalTimeStep)).rounded(.up)))
            shells.damping = 0
            var fastest: Float = 0
            for n in 0..<shells.nodeCount { fastest = max(fastest, simd_length(shells.node(n).velocity)) }
            settledSpeed[object.name] = fastest
            tracked.append(
                (object, track(owner: object, model: object.structure!, shells: shells, wall: wall)))
        }
        func sample() {
            for (b, entry) in tracked.enumerated() {
                guard let shells = solver.body(id: entry.0.id)?.shells else { continue }
                for c in entry.1.indices {
                    let value = deflection(tracked[b].1[c], shells) - tracked[b].1[c].baseline
                    tracked[b].1[c].samples.append((solver.time, value))
                    if tracked[b].1[c].component.kind == "pane", tracked[b].1[c].brokenAt == nil,
                        tracked[b].1[c].elements.contains(where: { shells.flag($0) != .active })
                    {
                        tracked[b].1[c].brokenAt = solver.time
                    }
                }
            }
        }
        // Each component's settled deflection, from which the blast's is measured.
        for (b, entry) in tracked.enumerated() {
            guard let shells = solver.body(id: entry.0.id)?.shells else { continue }
            for c in entry.1.indices { tracked[b].1[c].baseline = deflection(tracked[b].1[c], shells) }
        }
        sample()
        var stable = true
        var lastReport = 0.0
        while solver.time < duration - 1e-9 {
            let result = solver.advance(steps: 2, timeLimit: duration)
            if !result.isStable {
                stable = false
                break
            }
            if result.steps == 0 { break }
            sample()
            if solver.time - lastReport >= 0.01 {
                lastReport = solver.time
                print(String(format: "  %.0f ms", solver.time * 1000))
            }
        }
        var components: [Component] = []
        for (b, entry) in tracked.enumerated() {
            let shells = solver.body(id: entry.0.id)!.shells!
            for t in entry.1 {
                var c = t.component
                c.deflectionM = binned(t.samples, bin: bin, duration: duration)
                // A broken pane's peak is the one before it broke.
                let whole = t.samples.filter { t.brokenAt == nil || $0.time < t.brokenAt! }.map(\.value)
                c.peakInwardM = max(whole.max() ?? 0, 0)
                c.peakOutwardM = min(whole.min() ?? 0, 0)
                c.settledDeflectionM = t.baseline
                c.peakM = max(c.peakInwardM, -c.peakOutwardM)
                let tail = t.samples.filter { $0.time >= duration - 0.01 }.map(\.value)
                c.residualM = tail.isEmpty ? 0 : tail.reduce(0, +) / Float(tail.count)
                c.rotationDeg = atan(c.peakM / (c.shortSpanM / 2)) * 180 / .pi
                let count = Float(max(t.elements.count, 1))
                c.failedShare = Float(t.elements.filter { shells.flag($0) != .active }.count) / count
                c.shearFailedShare = Float(t.elements.filter { shells.hasShearFailed($0) }.count) / count
                c.punchedShare = Float(t.elements.filter { shells.isPunched($0) }.count) / count
                if c.kind == "pane" {
                    c.broken = t.brokenAt != nil
                    c.brokenAtS = t.brokenAt
                }
                components.append(c)
            }
            _ = b
        }
        let ambient = scene.atmosphere.pressure
        let gauges = scene.gauges.enumerated().map { index, gauge -> GaugeRecord in
            let history = solver.gaugeHistories[index]
            var impulse: Float = 0
            for (a, b) in zip(history, history.dropFirst()) {
                impulse += Float(b.time - a.time) * max(0.5 * (a.pressure + b.pressure) - ambient, 0)
            }
            return GaugeRecord(
                name: gauge.name, position: gauge.position,
                peakOverpressurePa: (history.map(\.pressure).max() ?? ambient) - ambient,
                positiveImpulsePaS: impulse,
                overpressurePa: binned(
                    history.map { ($0.time, $0.pressure - ambient) }, bin: bin, duration: duration))
        }
        let record = Record(
            sourceRevision: revision, device: device.name, layout: layout.rawValue, wall: wall,
            chargeKg: charge,
            chargePosition: scene.charge.position, domainSize: scene.domainSize, offset: offset,
            air: Air(
                cellSizeM: dx, afterburning: config.afterburning, airModel: "\(config.airModel)",
                openFaces: "\(config.openFaces)", refinement: config.refinement, airSleep: false),
            mesh: Mesh(
                shellElementSizeM: elementSize, shellLayers: layers, wallThicknessM: thickness(wall),
                roofThicknessM: roofThickness, paneThicknessM: wall == .glass ? paneThickness : 0,
                fixedBase: true),
            durationS: duration, binS: bin, wallClockS: ProcessInfo.processInfo.systemUptime - start,
            stable: stable,
            settleTimeS: settleTime, settleDampingPerS: settleDamping, settledFastestNodeMPerS: settledSpeed,
            notes: notes(wall), components: components, gauges: gauges)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let name = "\(layout.rawValue)-\(wall.rawValue)-\(Int(charge))"
        try encoder.encode(record).write(to: directory.appending(path: "\(name).json"))
        print("\(name): \(String(format: "%.0f", record.wallClockS)) s, stable \(stable)")
        for c in components {
            print(
                String(
                    format:
                        "  %@ %@ %@: peak %.1f mm (in %.1f, out %.1f), residual %.1f mm, %.2f°, failed %.0f%%%@",
                    c.building, c.kind, String(c.id.split(separator: "/").last ?? ""), c.peakM * 1000,
                    c.peakInwardM * 1000, -c.peakOutwardM * 1000, c.residualM * 1000, c.rotationDeg,
                    c.failedShare * 100,
                    c.broken.map {
                        $0 ? String(format: ", broken at %.1f ms", (c.brokenAtS ?? 0) * 1000) : ", whole"
                    }
                        ?? ""))
        }
        for g in gauges {
            print(
                String(
                    format: "  gauge %@: %.1f kPa, %.0f Pa s", g.name, g.peakOverpressurePa / 1000,
                    g.positiveImpulsePaS))
        }
    }

    static func notes(_ wall: Wall) -> [String] {
        var notes = [
            "Invented buildings under invented charges: numerical references for the one-way model, not measured damage.",
            "Walls and roof as shells at their mid-surfaces; deflection relative to the support edges' mean, positive inward.",
            "Every edge of every member is a support edge here (ground, neighbouring members, the wall around a pane).",
            "Under gravity, settled first for 0.25 s with mass-proportional damping of 300/s, then undamped; deflections are from the settled state.",
            "Component loads (pOuter/pInner) come from the stage 1 recorder; this record keeps the inside gauges.",
        ]
        if wall == .brick {
            notes.append(
                "Brick as smeared masonry on shells, without units and joints; masonry after cracking is the least trustworthy reference (validation.md#brick-walls-debris)."
            )
        }
        if wall == .glass {
            notes.append(
                "A wall's centre node lies at its window's edge: the window is in the middle of the wall.")
        }
        return notes
    }

    static func run(_ args: [String]) throws {
        guard let destination = args.first, !destination.hasPrefix("--"),
            let device = MTLCreateSystemDefaultDevice()
        else {
            throw BlastError.allocationFailed(
                "usage: scenebench envelope-damage <directory> [--layouts=isolated,pair,street] [--walls=rc,brick,glass] [--charges=2,10,50] [--dx=0.25] [--duration=0.15]"
            )
        }
        func value(_ name: String) -> String? {
            args.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        let directory = URL(filePath: destination)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let layouts = (value("layouts") ?? "isolated").split(separator: ",").compactMap {
            StreetInteractionStudy.Layout(rawValue: String($0))
        }
        let walls = (value("walls") ?? "rc").split(separator: ",").compactMap { Wall(rawValue: String($0)) }
        let charges = (value("charges") ?? "10").split(separator: ",").compactMap { Float($0) }
        let dx = value("dx").flatMap { Float($0) } ?? 0.25
        let duration = value("duration").flatMap { Double($0) } ?? 0.15
        let revision = value("source-revision") ?? "working-tree"
        for layout in layouts {
            for wall in walls {
                for charge in charges {
                    try runOne(
                        device: device, layout: layout, wall: wall, charge: charge, dx: dx,
                        duration: duration,
                        bin: 1e-4, revision: revision, directory: directory)
                }
            }
        }
    }
}
