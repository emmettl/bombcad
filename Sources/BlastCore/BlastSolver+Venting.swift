import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

// The air solver's venting: the envelopes' panes and walls breaking in the air, the holes fragments
// and close-in charges make, and the rooms behind them.
extension BlastSolver {
    /// Lets the envelopes' glazing break in the air (building-envelopes.md, "Venting"): each pane of
    /// the components recorded (`configureEnvelopeComponents`, which must come first) takes the glass
    /// of its building's construction, steps it with the air, and opens in the air when it breaks;
    /// each wall, roof and slab likewise takes its one-way systems (`EnvelopeWallFailure`) and
    /// opens when its damage is failed; each building's rooms are followed. In refined air the
    /// finer cells under an opened component open too, in the patches placed and those placed
    /// later; under gravity an opened cell holds the background at rest at its height.
    public func configureEnvelopeVenting(
        objects: [SceneObject], constructions: (UUID) -> EnvelopeConstruction
    )
        throws
    {
        guard let recorder = envelopeComponentRecorder else {
            throw BlastError.allocationFailed("envelope venting without the component recorder")
        }
        let mask = try stationaryMask(observing: objects)
        envelopeVenting = try EnvelopeVenting(
            device: device, library: library, grid: grid, mask: mask, objects: objects,
            components: recorder.components, rigidBoxes: rigidBoxes ?? [], constructions: constructions,
            equivalents: zip(recorder.plateEntry, recorder.stripEntry).map { ($0, $1) })
        if time > 0 { envelopeVenting?.startClocks(at: time) }
        for level in refinementLevels { level.setPanes(ventedPanes) }
    }

    /// Venting's panes as the refined levels take them.
    var ventedPanes: (cells: MTLBuffer, status: MTLBuffer, lookup: PaneLookup)? {
        envelopeVenting.map { ($0.sortedPaneCellBuffer, $0.statusBuffer, $0.paneLookup) }
    }

    /// When fragments hole envelope panes, by component id, s from the start (`FragmentCloud.paneHoles`):
    /// with venting on, each opens in the air on the step the run's clock reaches it, before its
    /// glass would break. Kept across restarts.
    public var ventsGlazing: Bool { envelopeVenting != nil }

    public func setEnvelopePaneHoles(_ holes: [String: Double]) {
        precondition(!batchInFlight, "Cannot set pane holes during a batch")
        envelopeVenting?.setHoles(holes)
    }

    /// Holes through envelope walls, roofs and slabs, with venting on: each `(owner, time s,
    /// position m, area m²)`, as fragments perforate them (`FragmentCloud.envelopeHoles`). Each goes
    /// through the wall, roof or slab of `owner` whose region holds its position (within a cell),
    /// as the column of its cells there; a column opens on the run's clock when the holes in it
    /// reach half its face (a cell's face, dx²), and a hole larger than that opens every column
    /// whose centre lies within its radius, the one it strikes among them. Replaces any set before;
    /// call before the run.
    public func setEnvelopeWallHoles(
        _ holes: [(owner: UUID, time: Double, position: SIMD3<Float>, areaM2: Float)]
    )
        throws
    {
        precondition(!batchInFlight, "Cannot set wall holes during a batch")
        guard let venting = envelopeVenting else { return }
        let dx = grid.cellSize
        let face = dx * dx
        let counts = [grid.nx, grid.ny, grid.nz]
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        func range(_ low: Float, _ high: Float, _ axis: Int) -> Range<Int> {
            let lower = min(max(Int((low / dx - 0.5).rounded(.up)), 0), counts[axis])
            let upper = min(max(Int((high / dx - 0.5).rounded(.up)), lower), counts[axis])
            return lower..<upper
        }
        let components = venting.components
        let candidates = components.indices.filter {
            [.wall, .roof, .slab].contains(components[$0].kind)
        }
        struct Column: Hashable {
            var component: Int
            var u: Int
            var v: Int
        }
        var area: [Column: Float] = [:]
        var opens: [Column: Double] = [:]
        for hole in holes.sorted(by: { $0.time < $1.time }) {
            // The component struck: of its owner, its region (grown by a cell) holding the point,
            // the nearest through its thickness.
            let struck = candidates.filter { components[$0].owner == hole.owner }.compactMap {
                n -> (Int, Float)? in
                let region = components[n].region
                let grown = Box(
                    min: region.min - SIMD3(repeating: dx), max: region.max + SIMD3(repeating: dx))
                guard grown.contains(hole.position) else { return nil }
                let axis = components[n].axis
                let middle = (region.min[axis] + region.max[axis]) / 2
                return (n, abs(hole.position[axis] - middle))
            }.min { $0.1 < $1.1 }
            guard let n = struck?.0 else { continue }
            let (u, v) = components[n].inPlaneAxes
            let at = Column(
                component: n, u: Int(floor(hole.position[u] / dx)), v: Int(floor(hole.position[v] / dx)))
            if hole.areaM2 > face / 2 {
                // A hole larger than half a face: every column within its radius, and its own.
                let radius = (hole.areaM2 / .pi).squareRoot()
                let reach = Int((radius / dx).rounded(.up))
                for i in (at.u - reach)...(at.u + reach) {
                    for j in (at.v - reach)...(at.v + reach) {
                        let du = (Float(i) + 0.5) * dx - hole.position[u]
                        let dv = (Float(j) + 0.5) * dx - hole.position[v]
                        let column = Column(component: n, u: i, v: j)
                        if column == at || du * du + dv * dv <= radius * radius, opens[column] == nil {
                            opens[column] = hole.time
                        }
                    }
                }
                continue
            }
            area[at, default: 0] += hole.areaM2
            if area[at]! >= face / 2, opens[at] == nil { opens[at] = hole.time }
        }
        var list: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] = []
        for (column, time) in opens.sorted(by: {
            ($0.value, $0.key.component, $0.key.u, $0.key.v) < (
                $1.value, $1.key.component, $1.key.u, $1.key.v
            )
        }) {
            let component = components[column.component]
            let region = component.region.holdingCells(of: dx)
            let (u, v) = component.inPlaneAxes
            guard (0..<counts[u]).contains(column.u), (0..<counts[v]).contains(column.v) else { continue }
            var cells: [Int] = []
            for k in range(region.min[component.axis], region.max[component.axis], component.axis) {
                var c = [0, 0, 0]
                c[component.axis] = k
                c[u] = column.u
                c[v] = column.v
                let index = grid.index(c[0], c[1], c[2])
                if mask[index] != 0 { cells.append(index) }
            }
            guard !cells.isEmpty, let owner = venting.owners.firstIndex(of: component.owner) else { continue }
            list.append((column.component, owner, cells, time, "fragments"))
        }
        fragmentOpenings = list
        try applyEnvelopeOpenings()
    }

    private func applyEnvelopeOpenings() throws {
        guard let venting = envelopeVenting else { return }
        try venting.setBreaches(fragmentOpenings + breachOpenings)
        for level in refinementLevels { level.setPanes(ventedPanes) }
    }

    /// Close-in charges against envelope concrete, with venting on: each wall, roof and slab of
    /// reinforced concrete or blockwork judged by UFC 3-340-02's threshold spall and breach curves
    /// (`UFCSpallBreach`) column by column across its face, at the range from the charge's centre
    /// to the column's middle on the face nearer it; the columns past the breach threshold open
    /// when the blast reaches them (Kingery–Bulmash's arrival at that range, at once within 0.2
    /// m/kg^(1/3)). `casing` kg of steel round the charge (a cased charge's, from its fragments).
    /// The burst counts as on the surface when the charge touches the slab or sits within two of
    /// its radii of the ground, and in free air otherwise. Each component's worst outcome is kept
    /// for its damage (`EnvelopeVentingSnapshot.closeIn`); spalling opens nothing, as it does not
    /// go through. A charge's breaches open its `delay` later (give the main charge none). Replaces
    /// any set before; call before the run.
    @discardableResult
    public func setEnvelopeCloseIn(
        charges: [(charge: Charge, casing: Float)], constructions: (UUID) -> EnvelopeConstruction
    ) throws -> [String: UFCSpallBreach.Outcome] {
        precondition(!batchInFlight, "Cannot set breaches during a batch")
        guard let venting = envelopeVenting else { return [:] }
        let dx = grid.cellSize
        let counts = [grid.nx, grid.ny, grid.nz]
        let mask = maskContents.bindMemory(to: UInt8.self, capacity: grid.cellCount)
        func range(_ low: Float, _ high: Float, _ axis: Int) -> Range<Int> {
            let lower = min(max(Int((low / dx - 0.5).rounded(.up)), 0), counts[axis])
            let upper = min(max(Int((high / dx - 0.5).rounded(.up)), lower), counts[axis])
            return lower..<upper
        }
        var outcomes: [String: UFCSpallBreach.Outcome] = [:]
        var list: [(component: Int, owner: Int, cells: [Int], time: Double, cause: String)] = []
        for (charge, casing) in charges where charge.mass > 0 {
            let mass = Double(charge.mass)
            let radius = cbrt(3 * mass / (4 * .pi * 1_600))
            let centre = SIMD3<Double>(charge.position)
            for (n, component) in venting.components.enumerated()
            where [.wall, .roof, .slab].contains(component.kind) {
                let construction = constructions(component.owner)
                let isRoof = component.kind != .wall
                let kind = isRoof ? construction.roof : construction.walls
                guard kind == .reinforcedConcrete || kind == .reinforcedBlockwork,
                    let owner = venting.owners.firstIndex(of: component.owner)
                else { continue }
                let thickness = Double(isRoof ? construction.roofThicknessM : construction.wallThicknessM)
                let material = isRoof ? StructureMaterial.reinforcedConcrete : construction.wallMaterial
                let region = component.region.holdingCells(of: dx)
                let axis = component.axis
                let (u, v) = component.inPlaneAxes
                // The face nearer the charge.
                let face =
                    abs(Double(region.min[axis]) - centre[axis])
                        < abs(Double(region.max[axis]) - centre[axis])
                    ? region.min[axis] : region.max[axis]
                var worst = UFCSpallBreach.Outcome.none
                for i in range(region.min[u], region.max[u], u) {
                    for j in range(region.min[v], region.max[v], v) {
                        var point = SIMD3<Double>(repeating: 0)
                        point[axis] = Double(face)
                        point[u] = (Double(i) + 0.5) * Double(dx)
                        point[v] = (Double(j) + 0.5) * Double(dx)
                        let distance = simd_distance(point, centre)
                        let contact = distance <= radius * 1.01
                        let surface = contact || centre.z <= 2 * radius
                        let outcome = UFCSpallBreach.outcome(
                            thickness: thickness, range: max(distance, radius),
                            strength: Double(material.compressiveStrength),
                            charge: mass, casing: Double(casing), surface: surface, contact: contact)
                        worst = max(worst, outcome)
                        guard outcome == .breached else { continue }
                        var cells: [Int] = []
                        for k in range(region.min[axis], region.max[axis], axis) {
                            var c = [0, 0, 0]
                            c[axis] = k
                            c[u] = i
                            c[v] = j
                            let index = grid.index(c[0], c[1], c[2])
                            if mask[index] != 0 { cells.append(index) }
                        }
                        guard !cells.isEmpty else { continue }
                        let arrival =
                            charge.firingTime
                            + (KingeryBulmash.point(at: distance / cbrt(mass))?.arrival(mass: mass) ?? 0)
                        list.append((n, owner, cells, arrival, "breach"))
                    }
                }
                if worst != .none { outcomes[component.id] = max(outcomes[component.id] ?? .none, worst) }
            }
        }
        venting.closeIn = outcomes
        breachOpenings = list
        try applyEnvelopeOpenings()
        return outcomes
    }

    /// The same from the fragments' perforations of walls, roofs and slabs (those without a pane).
    public func setEnvelopeWallHoles(_ holes: [EnvelopeHole]) throws {
        try setEnvelopeWallHoles(
            holes.filter { $0.pane == nil }.map { ($0.owner, $0.time, $0.position, $0.areaM2) })
    }

    /// Each venting pane's building, in the order `envelopePanesBroken()` gives them; empty
    /// without venting.
    public var envelopePaneOwners: [UUID] {
        envelopeVenting.map { venting in venting.paneComponents.map { venting.components[$0].owner } } ?? []
    }

    /// Whether each venting pane's glass has broken and its cells opened, as of the last batch:
    /// what `envelopeVentingSnapshot()` says of the panes, without the rest, for a recorded frame.
    public func envelopePanesBroken() -> [Bool] {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        guard let venting = envelopeVenting, venting.paneCount > 0 else { return [] }
        let state = venting.stateBuffer.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: 2 * venting.paneCount)
        return (0..<venting.paneCount).map { state[2 * $0 + 1].y >= 0 }
    }

    /// The panes broken so far and what each building's rooms have seen, with venting on.
    public func envelopeVentingSnapshot() -> EnvelopeVentingSnapshot? {
        precondition(!batchInFlight, "Cannot read observers during a batch")
        return envelopeVenting?.snapshot()
    }

    /// Steps the envelopes' panes on the step's loads, opens those that broke, and reads the rooms
    /// of buildings opened (EnvelopeVenting.swift).
    func encodeEnvelopeVenting(_ encoder: MTLComputeCommandEncoder) {
        guard let venting = envelopeVenting, let recorder = envelopeComponentRecorder else { return }
        var uniforms = makeUniforms()
        if venting.paneCount > 0 {
            var count = UInt32(venting.paneCount)
            encoder.setComputePipelineState(venting.stepPipeline)
            encoder.setBuffer(recorder.current, offset: 0, index: 0)
            encoder.setBuffer(venting.paneBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.glassBuffer, offset: 0, index: 2)
            encoder.setBuffer(venting.stateBuffer, offset: 0, index: 3)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 4)
            encoder.setBuffer(venting.openedBuffer, offset: 0, index: 5)
            encoder.setBuffer(controlBuffer, offset: 0, index: 6)
            encoder.setBytes(&count, length: 4, index: 7)
            encoder.setBuffer(venting.ownerRooms, offset: 0, index: 8)
            encoder.setBuffer(venting.roomDispatch, offset: 0, index: 9)
            encoder.setBuffer(venting.roomList, offset: 0, index: 10)
            encoder.setBuffer(venting.tableBuffer, offset: 0, index: 11)
            encoder.setBuffer(venting.holeBuffer, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: venting.paneCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        if venting.wallCount > 0 {
            var counts = SIMD2<UInt32>(UInt32(venting.wallCount), UInt32(venting.paneCount))
            encoder.setComputePipelineState(venting.wallPipeline)
            encoder.setBuffer(recorder.current, offset: 0, index: 0)
            encoder.setBuffer(venting.wallBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.wallSystemBuffer, offset: 0, index: 2)
            encoder.setBuffer(venting.wallTableBuffer, offset: 0, index: 3)
            encoder.setBuffer(venting.wallStateBuffer, offset: 0, index: 4)
            encoder.setBuffer(venting.wallClockBuffer, offset: 0, index: 5)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 6)
            encoder.setBuffer(venting.openedBuffer, offset: 0, index: 7)
            encoder.setBuffer(controlBuffer, offset: 0, index: 8)
            encoder.setBytes(&counts, length: 8, index: 9)
            encoder.setBuffer(venting.ownerRooms, offset: 0, index: 10)
            encoder.setBuffer(venting.roomDispatch, offset: 0, index: 11)
            encoder.setBuffer(venting.roomList, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: venting.wallCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        if !venting.breaches.isEmpty {
            var count = UInt32(venting.breaches.count)
            encoder.setComputePipelineState(venting.breachPipeline)
            encoder.setBuffer(venting.breachBuffer, offset: 0, index: 0)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.openedBuffer, offset: 0, index: 2)
            encoder.setBuffer(controlBuffer, offset: 0, index: 3)
            encoder.setBytes(&count, length: 4, index: 4)
            encoder.setBuffer(venting.ownerRooms, offset: 0, index: 5)
            encoder.setBuffer(venting.roomDispatch, offset: 0, index: 6)
            encoder.setBuffer(venting.roomList, offset: 0, index: 7)
            encoder.dispatchThreads(
                MTLSize(width: venting.breaches.count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
        }
        if venting.paneCellCount > 0 {
            var count = UInt32(venting.paneCellCount)
            encoder.setComputePipelineState(venting.openPipeline)
            encoder.setBuffer(venting.paneCellBuffer, offset: 0, index: 0)
            encoder.setBuffer(venting.statusBuffer, offset: 0, index: 1)
            encoder.setBuffer(maskBuffer, offset: 0, index: 2)
            encoder.setBuffer(rigidMaskBuffer, offset: 0, index: 3)
            encoder.setBuffer(stateBuffers[0], offset: 0, index: 4)
            encoder.setBuffer(stateBuffers[1], offset: 0, index: 5)
            encoder.setBuffer(hasSpecies ? speciesBuffers[0] : noSpecies, offset: 0, index: 6)
            encoder.setBuffer(hasSpecies ? speciesBuffers[1] : noSpecies, offset: 0, index: 7)
            encoder.setBuffer(tileFlagBuffer, offset: 0, index: 8)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 9)
            encoder.setBuffer(controlBuffer, offset: 0, index: 10)
            encoder.setBytes(&count, length: 4, index: 11)
            // Read only under gravity.
            encoder.setBuffer(gravityTable(scale: 1) ?? venting.statusBuffer, offset: 0, index: 12)
            encoder.dispatchThreads(
                MTLSize(width: venting.paneCellCount, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
            // And the refined levels' cells under them.
            if let refinement {
                refinement.encodeOpenPanes(
                    encoder,
                    uniforms: refinement.levelUniforms(
                        from: uniforms, threshold: configuration.refinementThreshold, grid: grid),
                    control: controlBuffer)
            }
            if let finerRefinement, let finer = finerUniforms(uniforms) {
                finerRefinement.encodeOpenPanes(encoder, uniforms: finer, control: controlBuffer)
            }
        }
        if !venting.rooms.isEmpty {
            encoder.setComputePipelineState(venting.roomPipeline)
            encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
            encoder.setBuffer(venting.roomBuffer, offset: 0, index: 1)
            encoder.setBuffer(venting.roomCellBuffer, offset: 0, index: 2)
            encoder.setBuffer(venting.roomList, offset: 0, index: 3)
            encoder.setBuffer(venting.roomResults, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
            encoder.setBuffer(controlBuffer, offset: 0, index: 6)
            encoder.setBuffer(gravityTable(scale: 1) ?? venting.roomResults, offset: 0, index: 7)
            encoder.dispatchThreadgroups(
                indirectBuffer: venting.roomDispatch, indirectBufferOffset: 0,
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
    }
}
