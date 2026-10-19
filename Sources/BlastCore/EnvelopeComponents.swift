import BlastModel
import Foundation
import Metal
import simd

/// Records each envelope component's two sides through a run, on the GPU after every complete
/// fluid step, as the surface recorder records faces: the same cell-centre pressures, the same
/// right-endpoint rule. Every face's pressure is taken a thread a face, then a SIMD group a component sums them in a fixed order, so the result
/// repeats bit for bit.
///
/// Each wall, slab, roof and pane is also recorded as two equivalent uniform loads, Biggs's ∫pφ /
/// ∫φ over its faces for its plastic mechanism's shape φ, which its damage is judged on rather
/// than its mean: a load spread unevenly (a close-in charge's, or one the blast's clearing round
/// the edges takes down) loads a span by where it bends. Along each in-plane axis φ is a hinge at
/// the middle, 1 − |2s − 1|, with both edges held, s from the one held, and 1 with neither; a
/// component held nowhere is taken as held on all four, as its damage takes it (`shape`):
/// - `plate`: every face, by the shape both ways, for a plate that spreads its load;
/// - `strip`: the middle third across the span (the axis held on neither edge, else the longer),
///   by the shape along it, for ribs that span on their own (ADBLAST's sheets: the side ribs a
///   quarter below the middle ones).
/// They are further entries after the components, their faces again with weights (1 for the
/// components'), summed as they are; kept only if they fit the memory at the bins' width the
/// components alone take, and left out where a side would not be seen as the component's is.
final class EnvelopeComponentRecorder {
    /// A component's faces: outer side then inner, as ranges into `faces`.
    struct Sides {
        var outerFirst: UInt32
        var outerCount: UInt32
        var innerFirst: UInt32
        var innerCount: UInt32
    }
    /// The fluid cell read and the solid cell that must stay solid (`noSolid` for an opening).
    struct Face {
        var fluid: UInt32
        var solid: UInt32
    }
    static let noSolid = UInt32.max
    /// Whether a face in a tile of still air reads the still air rather than its cell, which
    /// holds the same; off only to show that the two agree.
    var skipStillTiles = true
    /// Whether a face in refined air reads the finest cells against it (their mean), rather than
    /// its coarse cell, which averages them over the whole cell: the reflected load at a wall is
    /// sharper than the cell beside it. Off only to compare.
    var readsRefinedAir = true
    /// Components to a threadgroup, a SIMD group of 32 lanes each (SolverEnvelopes.metal).
    static let componentsPerGroup = 4

    let components: [EnvelopeComponent]
    /// The entries summed: the components, then their equivalent loads (`plateEntry`,
    /// `stripEntry`), and their sides; each face's weight (1 for the components').
    let entryCount: Int
    let plateEntry: [Int?]
    let stripEntry: [Int?]
    let entryRegions: [Box]
    let weights: [Float]
    let sides: [Sides]
    let faces: [Face]
    let binS: Double
    let capacity: Int
    let binMaxima: Bool
    let cellSize: Float
    let sideBuffer: MTLBuffer
    let faceBuffer: MTLBuffer
    /// Each face's pressure, as the last step left it, times its weight.
    let pressures: MTLBuffer
    let weightBuffer: MTLBuffer
    /// Each component's tiles of the air (ranges into `tiles`), whether any has woken this step,
    /// the components listed for the faces' pass and for the sums with their threadgroups (two
    /// indirect dispatches), and the still air's pressure, in 32 copies.
    let tileRanges: MTLBuffer
    let tiles: MTLBuffer
    let awake: MTLBuffer
    let faceList: MTLBuffer
    let faceDispatch: MTLBuffer
    let sumList: MTLBuffer
    let sumDispatch: MTLBuffer
    let stillPressure: MTLBuffer
    /// The bin the coming step starts in and how far into it (`ComponentClock`), kept on the GPU.
    let clock: MTLBuffer
    /// Each component's first bin: 0, or with `windowFromArrival` the clock's bin when the blast
    /// reached it (`arrivalPa`, or its air's first moving; `UInt32.max` until then).
    let starts: MTLBuffer
    let fromArrival: Bool
    /// The overpressure that starts a component's window (`EnvelopeHistoryOptions.arrivalPa`).
    let arrivalPa: Float
    let clockPipeline: MTLComputePipelineState
    let peaks: MTLBuffer
    let bins: MTLBuffer
    let maxima: MTLBuffer?
    let flags: MTLBuffer
    /// Each component's two sides' mean overpressures in the step just taken, for venting.
    let current: MTLBuffer
    let markPipeline: MTLComputePipelineState
    let facePipeline: MTLComputePipelineState
    let pipeline: MTLComputePipelineState

    init(
        device: MTLDevice, library: MTLLibrary, grid: Grid, mask: UnsafeBufferPointer<UInt8>,
        objects: [SceneObject], options: EnvelopeHistoryOptions
    ) throws {
        guard options.binS > 0, options.windowS > 0, options.memoryBudget > 0 else {
            throw BlastError.allocationFailed("envelope history with a positive bin, window and budget")
        }
        let resolved = try EnvelopeExposure.resolvedFaces(grid: grid, mask: mask, objects: objects)
        let dx = grid.cellSize
        var components: [EnvelopeComponent] = []
        var outer: [[Face]] = []
        var inner: [[Face]] = []
        // Each owner's components by their source (a solid or a pane), and its façade strips, to
        // find a face's: a district holds thousands of owners.
        struct Source: Hashable {
            var owner: Int
            var pane: Bool
            var index: Int
        }
        var bySource: [Source: [Int]] = [:]
        var facades: [[Int]] = Array(repeating: [], count: objects.count)
        for (owner, object) in objects.enumerated() {
            let envelope = resolved.geometry[owner]
            for laid in envelope.componentLayout(owner: object.id, cellSize: dx) {
                if laid.component.kind == .facade {
                    facades[owner].append(components.count)
                } else {
                    bySource[
                        Source(
                            owner: owner, pane: laid.component.kind == .pane, index: laid.component.source),
                        default: []
                    ].append(components.count)
                }
                components.append(laid.component)
                outer.append([])
                inner.append([])
            }
        }
        func contains(_ region: Box, _ point: SIMD3<Float>) -> Bool {
            (0..<3).allSatisfy { point[$0] >= region.min[$0] && point[$0] <= region.max[$0] }
        }
        // The cells standing for each pane (`BuildingEnvelope.paneCells`) carry its load, whichever
        // block holds them.
        var paneOfCell: [Int: Int] = [:]
        for (owner, _) in objects.enumerated() {
            let envelope = resolved.geometry[owner]
            for pane in envelope.panes.indices {
                guard let component = bySource[Source(owner: owner, pane: true, index: pane)]?.first else {
                    continue
                }
                for cell in envelope.paneCells(pane, grid: grid) { paneOfCell[cell] = component }
            }
        }
        for face in resolved.faces {
            let envelope = resolved.geometry[face.owner]
            let cell = Int(face.face.solid)
            if let pane = paneOfCell[cell] {
                guard components[pane].axis == Int(face.face.axis) else { continue }
                let entry = Face(fluid: face.face.fluid, solid: face.face.solid)
                let sign = face.face.positive != 0 ? 1 : -1
                if sign == components[pane].outward {
                    outer[pane].append(entry)
                } else {
                    inner[pane].append(entry)
                }
                continue
            }
            let point = grid.cellCentre(
                cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
            let axis = Int(face.face.axis)
            let sign = face.face.positive != 0 ? 1 : -1
            let candidates: [Int]
            switch envelope.blockSources[face.block] {
            case .pane(let index):
                candidates = bySource[Source(owner: face.owner, pane: true, index: index)] ?? []
            case .solid(let index):
                let own = bySource[Source(owner: face.owner, pane: false, index: index)] ?? []
                switch BuildingEnvelope.role(envelope.solids[index]) {
                case .plate: candidates = own
                case .column: candidates = []
                case .block:
                    candidates = axis == 2 ? own.filter { components[$0].kind == .roof } : facades[face.owner]
                }
            }
            // Its own component: on the thin axis, holding the cell; a block's façade strip or roof
            // only on its outward side.
            guard
                let match = candidates.first(where: { n in
                    let component = components[n]
                    let oneSided =
                        component.kind == .facade
                        || component.kind == .roof
                            && BuildingEnvelope.role(envelope.solids[component.source]) == .block
                    return component.axis == axis && contains(component.region, point)
                        && (!oneSided || component.outward == sign)
                })
            else { continue }
            let entry = Face(fluid: face.face.fluid, solid: face.face.solid)
            if sign == components[match].outward {
                outer[match].append(entry)
            } else {
                inner[match].append(entry)
            }
        }
        if options.openingsAsPanes {
            for (owner, object) in objects.enumerated() {
                let envelope = resolved.geometry[owner]
                for (openingIndex, opening) in envelope.openings.enumerated() {
                    var crossings = 0
                    for (index, solid) in envelope.solids.enumerated() {
                        guard case .plate(let axis) = BuildingEnvelope.role(solid) else { continue }
                        var region = Box(
                            min: simd_max(solid.min, opening.min), max: simd_min(solid.max, opening.max))
                        guard (0..<3).allSatisfy({ region.max[$0] > region.min[$0] }) else { continue }
                        region.min[axis] = solid.min[axis]
                        region.max[axis] = solid.max[axis]
                        let wall = components.first {
                            $0.owner == object.id && $0.source == index && $0.kind != .pane
                        }
                        let outward = wall?.outward ?? 1
                        let (u, v) = ((0..<3).filter { $0 != axis }[0], (0..<3).filter { $0 != axis }[1])
                        var sideCells: [[Face]] = [[], []]
                        let low = grid.cell(containing: region.min + 0.5 * dx)
                        let high = grid.cell(containing: region.max - 0.5 * dx)
                        let lo = [low.i, low.j, low.k]
                        let hi = [high.i, high.j, high.k]
                        for (n, side) in [-1, 1].enumerated() {
                            var at = [0, 0, 0]
                            at[axis] = side < 0 ? lo[axis] - 1 : hi[axis] + 1
                            for b in lo[v]...hi[v] {
                                for a in lo[u]...hi[u] {
                                    at[u] = a
                                    at[v] = b
                                    guard grid.contains(at[0], at[1], at[2]) else { continue }
                                    let index = grid.index(at[0], at[1], at[2])
                                    guard mask[index] == 0 else { continue }
                                    sideCells[n].append(Face(fluid: UInt32(index), solid: Self.noSolid))
                                }
                            }
                        }
                        let id =
                            "\(object.id.uuidString)/opening/\(openingIndex)"
                            + (crossings > 0 ? ".\(crossings)" : "")
                        crossings += 1
                        components.append(
                            EnvelopeComponent(
                                id: id, owner: object.id, kind: .pane, region: region, axis: axis,
                                outward: outward,
                                source: openingIndex, panel: 0, supportEdges: [true, true, true, true]))
                        outer.append(outward > 0 ? sideCells[1] : sideCells[0])
                        inner.append(outward > 0 ? sideCells[0] : sideCells[1])
                    }
                }
            }
        }
        // Components with no face on the air (a block's sides against its neighbours, a wall buried
        // in the terrain) are left out: a district's map buildings have many.
        let kept = components.indices.filter { !outer[$0].isEmpty || !inner[$0].isEmpty }
        components = kept.map { components[$0] }
        outer = kept.map { outer[$0] }
        inner = kept.map { inner[$0] }
        // The bins: as wide as asked, or the least whole multiple of it that fits the budget.
        let perBin = max(1, components.count) * 8 * (options.binMaxima ? 2 : 1)
        var multiple = 1.0
        func bins(_ multiple: Double) -> Int {
            Int((options.windowS / (options.binS * multiple)).rounded(.up)) + 1
        }
        while perBin * bins(multiple) > options.memoryBudget && bins(multiple) > 2 { multiple += 1 }
        let width = options.binS * multiple
        let count = bins(multiple)
        // The equivalent loads, of the components laid out (not openings' panes), as entries after them.
        var plateOf: [Int?] = Array(repeating: nil, count: components.count)
        var stripOf: [Int?] = Array(repeating: nil, count: components.count)
        var extra:
            [(region: Box, outer: [Face], inner: [Face], outerWeights: [Float], innerWeights: [Float])] = []
        if options.governingBands {
            for n in components.indices
            where components[n].kind != .facade && !components[n].id.contains("/opening/") {
                let component = components[n]
                let region = component.region
                let axes = (0..<3).filter { $0 != component.axis }
                // Held nowhere, it is judged as a panel held on its edges.
                let edges =
                    component.supportEdges.count == 4 && component.supportEdges.contains(true)
                    ? component.supportEdges : [true, true, true, true]
                let held = [(edges[0], edges[1]), (edges[2], edges[3])]
                // Across: the axis held on neither edge, else the longer.
                let free = (0..<2).filter { !held[$0].0 && !held[$0].1 }
                let across = free.count == 1 ? free[0] : region.size[axes[1]] > region.size[axes[0]] ? 1 : 0
                func position(_ face: Face) -> SIMD2<Float> {
                    let cell = Int(face.solid)
                    let point = grid.cellCentre(
                        cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
                    func along(_ a: Int) -> Float {
                        let axis = axes[a]
                        return min(max((point[axis] - region.min[axis]) / max(region.size[axis], 1e-6), 0), 1)
                    }
                    return SIMD2(along(0), along(1))
                }
                for strip in [false, true] {
                    var band = region
                    if strip {
                        let third = region.size[axes[across]] / 3
                        band.min[axes[across]] += third
                        band.max[axes[across]] -= third
                    }
                    func weighted(_ list: [Face]) -> (faces: [Face], weights: [Float])? {
                        var kept: [Face] = []
                        var shapes: [Float] = []
                        for face in list {
                            let at = position(face)
                            if strip && abs(at[across] - 0.5) > 1.0 / 6 + 1e-6 { continue }
                            var phi: Float = 1
                            for a in 0..<2 where !(strip && a == across) {
                                phi *= Self.shape(at[a], low: held[a].0, high: held[a].1)
                            }
                            kept.append(face)
                            shapes.append(phi)
                        }
                        let total = shapes.reduce(0, +)
                        guard !kept.isEmpty, total > 0 else { return nil }
                        return (kept, shapes.map { $0 * Float(kept.count) / total })
                    }
                    let o = weighted(outer[n])
                    let i = weighted(inner[n])
                    guard (o == nil) == outer[n].isEmpty, (i == nil) == inner[n].isEmpty else { continue }
                    if strip {
                        stripOf[n] = components.count + extra.count
                    } else {
                        plateOf[n] = components.count + extra.count
                    }
                    extra.append((band, o?.faces ?? [], i?.faces ?? [], o?.weights ?? [], i?.weights ?? []))
                }
            }
            if (components.count + extra.count) * 8 * (options.binMaxima ? 2 : 1) * count
                > options.memoryBudget
            {
                plateOf = Array(repeating: nil, count: components.count)
                stripOf = plateOf
                extra = []
            }
        }
        let entries = components.count + extra.count
        var faces: [Face] = []
        var weights: [Float] = []
        var sides: [Sides] = []
        var lists: [(outer: [Face], inner: [Face], outerWeights: [Float], innerWeights: [Float])] = []
        for n in components.indices {
            lists.append(
                (
                    outer[n], inner[n], Array(repeating: 1, count: outer[n].count),
                    Array(repeating: 1, count: inner[n].count)
                ))
        }
        lists += extra.map { ($0.outer, $0.inner, $0.outerWeights, $0.innerWeights) }
        for list in lists {
            let first = UInt32(faces.count)
            faces += list.outer
            faces += list.inner
            weights += list.outerWeights
            weights += list.innerWeights
            sides.append(
                Sides(
                    outerFirst: first, outerCount: UInt32(list.outer.count),
                    innerFirst: first + UInt32(list.outer.count), innerCount: UInt32(list.inner.count)))
        }
        guard !components.isEmpty, perBin * count <= options.memoryBudget,
            let sideBuffer = device.makeBuffer(
                bytes: sides, length: max(1, sides.count) * MemoryLayout<Sides>.stride),
            let faceBuffer = device.makeBuffer(
                bytes: faces.isEmpty ? [Face(fluid: 0, solid: 0)] : faces,
                length: max(1, faces.count) * MemoryLayout<Face>.stride),
            let peaks = device.makeBuffer(length: entries * 16, options: .storageModeShared),
            let bins = device.makeBuffer(length: entries * count * 8, options: .storageModeShared),
            let flags = device.makeBuffer(length: 4, options: .storageModeShared),
            let current = device.makeBuffer(
                length: max(entries * 8, 16), options: .storageModeShared)
        else { throw BlastError.allocationFailed("envelope component histories") }
        self.components = components
        entryCount = entries
        plateEntry = plateOf
        stripEntry = stripOf
        entryRegions = components.map(\.region) + extra.map(\.region)
        self.weights = weights
        self.sides = sides
        self.faces = faces
        binS = width
        capacity = count
        binMaxima = options.binMaxima
        cellSize = dx
        self.sideBuffer = sideBuffer
        self.faceBuffer = faceBuffer
        self.peaks = peaks
        self.bins = bins
        self.flags = flags
        self.current = current
        maxima =
            options.binMaxima
            ? device.makeBuffer(length: entries * count * 8, options: .storageModeShared) : nil
        guard !options.binMaxima || maxima != nil else {
            throw BlastError.allocationFailed("envelope component bin maxima")
        }
        // The tiles of the air each component's faces lie in (as the solver's, 8 cells).
        var ranges: [SIMD2<UInt32>] = []
        var tileList: [UInt32] = []
        let tileNx = (grid.nx + 7) / 8
        let tileNy = (grid.ny + 7) / 8
        for side in sides {
            let own = faces[Int(side.outerFirst)..<Int(side.innerFirst + side.innerCount)]
            let tiles = Set(
                own.map { face -> UInt32 in
                    let cell = Int(face.fluid)
                    let (i, j, k) = (cell % grid.nx, (cell / grid.nx) % grid.ny, cell / (grid.nx * grid.ny))
                    return UInt32(i / 8 + tileNx * (j / 8 + tileNy * (k / 8)))
                }
            ).sorted()
            ranges.append(SIMD2(UInt32(tileList.count), UInt32(tiles.count)))
            tileList += tiles
        }
        guard
            let pressures = device.makeBuffer(length: max(1, faces.count) * 4, options: .storageModePrivate),
            let weightBuffer = device.makeBuffer(
                bytes: weights.isEmpty ? [Float(1)] : weights, length: max(1, weights.count) * 4),
            let tileRanges = device.makeBuffer(bytes: ranges, length: max(1, ranges.count) * 8),
            let tiles = device.makeBuffer(
                bytes: tileList.isEmpty ? [0] : tileList, length: max(1, tileList.count) * 4),
            let awake = device.makeBuffer(length: entries * 4, options: .storageModePrivate),
            let faceList = device.makeBuffer(length: entries * 4, options: .storageModePrivate),
            let faceDispatch = device.makeBuffer(length: 12),
            let sumList = device.makeBuffer(length: entries * 4, options: .storageModePrivate),
            let sumDispatch = device.makeBuffer(length: 12),
            let stillPressure = device.makeBuffer(length: 32 * 4, options: .storageModePrivate),
            let clock = device.makeBuffer(length: 8, options: .storageModeShared),
            let starts = device.makeBuffer(length: max(1, entries) * 4, options: .storageModeShared)
        else { throw BlastError.allocationFailed("envelope component face pressures") }
        self.pressures = pressures
        self.weightBuffer = weightBuffer
        self.tileRanges = tileRanges
        self.tiles = tiles
        self.awake = awake
        self.faceList = faceList
        self.faceDispatch = faceDispatch
        self.sumList = sumList
        self.sumDispatch = sumDispatch
        self.stillPressure = stillPressure
        self.clock = clock
        self.starts = starts
        fromArrival = options.windowFromArrival
        arrivalPa = options.arrivalPa
        clockPipeline = try ShaderLibrary.pipeline("advanceEnvelopeClock", in: library)
        markPipeline = try ShaderLibrary.pipeline("markEnvelopeComponents", in: library)
        facePipeline = try ShaderLibrary.pipeline("sampleEnvelopeComponentFaces", in: library)
        pipeline = try ShaderLibrary.pipeline("sampleEnvelopeComponents", in: library)
        reset()
    }

    /// The shape along one in-plane axis at s in [0, 1], its plastic mechanism's (Biggs's plastic
    /// load factor): a hinge at the middle held at both ends, rotation about the end held, 1 held at
    /// neither.
    static func shape(_ s: Float, low: Bool, high: Bool) -> Float {
        switch (low, high) {
        case (true, true): return 1 - abs(2 * s - 1)
        case (true, false): return s
        case (false, true): return 1 - s
        case (false, false): return 1
        }
    }

    var memoryFootprint: Int {
        [
            sideBuffer, faceBuffer, pressures, weightBuffer, tileRanges, tiles, awake, faceList, faceDispatch,
            sumList,
            sumDispatch, stillPressure, clock, starts,
            peaks,
            bins, flags, current,
        ]
        .reduce(0) { $0 + $1.length } + (maxima?.length ?? 0)
    }

    func reset() {
        let lowest = -Float.greatestFiniteMagnitude
        let peak = peaks.contents().bindMemory(to: SIMD4<Float>.self, capacity: entryCount)
        for n in 0..<entryCount { peak[n] = SIMD4(lowest, lowest, lowest, 0) }
        memset(bins.contents(), 0, bins.length)
        memset(current.contents(), 0, current.length)
        if let maxima {
            let values = maxima.contents().bindMemory(to: Float.self, capacity: maxima.length / 4)
            for n in 0..<(maxima.length / 4) { values[n] = lowest }
        }
        memset(flags.contents(), 0, flags.length)
        memset(clock.contents(), 0, clock.length)
        memset(starts.contents(), fromArrival ? 0xFF : 0, starts.length)
        // The first sample's faces' pass has one threadgroup to make the still air's row; the sums
        // none until components are listed.
        for (buffer, count) in [(faceDispatch, UInt32(1)), (sumDispatch, 0)] {
            for (n, value) in [count, 1, 1].enumerated() {
                buffer.contents().storeBytes(of: value, toByteOffset: 4 * n, as: UInt32.self)
            }
        }
    }

    /// The recording parameters for a step, or the first sample.
    func parameters(initial: Bool) -> Parameters {
        Parameters(
            components: UInt32(entryCount), capacity: UInt32(capacity), initial: initial ? 1 : 0,
            maxima: binMaxima ? 1 : 0, binWidth: Float(binS), faces: UInt32(faces.count),
            fromArrival: fromArrival ? 1 : 0, arrivalPa: fromArrival ? arrivalPa : 0)
    }

    struct Parameters {
        var components: UInt32
        var capacity: UInt32
        var initial: UInt32
        var maxima: UInt32
        var binWidth: Float
        var faces: UInt32
        var fromArrival: UInt32
        var readsRefined: UInt32 = 0
        var skipStill: UInt32 = 0
        var arrivalPa: Float = 0
    }

    func histories(elapsed: Double) -> [EnvelopeComponentHistory] {
        let recorded = min(capacity, Int((elapsed / binS - 1e-9).rounded(.up)))
        let peak = peaks.contents().bindMemory(to: SIMD4<Float>.self, capacity: entryCount)
        let binned = bins.contents().bindMemory(to: SIMD2<Float>.self, capacity: entryCount * capacity)
        let maximum = maxima?.contents().bindMemory(
            to: SIMD2<Float>.self, capacity: entryCount * capacity)
        let truncated = flags.contents().load(as: UInt32.self) != 0
        let area = Double(cellSize * cellSize)
        func finite(_ value: Float) -> Float { value == -.greatestFiniteMagnitude ? 0 : value }
        let elapsedBins = Int((elapsed / binS - 1e-9).rounded(.up))
        let first = starts.contents().bindMemory(to: UInt32.self, capacity: entryCount)
        return components.indices.map { n in
            let base = n * capacity
            let start = first[n] == .max ? nil : Int(first[n])
            let count = fromArrival ? start.map { min(capacity, max(elapsedBins - $0, 0)) } ?? 0 : recorded
            let values = (0..<max(count, 0)).map { binned[base + $0] }
            let largest = maximum.map { m in (0..<max(count, 0)).map { m[base + $0] } }
            // An equivalent load's bins from the component's start, so they line up with its own.
            func equivalent(_ entry: Int?) -> EnvelopeComponentHistory.Equivalent? {
                guard let entry else { return nil }
                let own = first[entry] == .max ? nil : Int(first[entry])
                let offset = fromArrival ? own.map { $0 - (start ?? $0) } : 0
                let values = (0..<max(count, 0)).map { k -> SIMD2<Float> in
                    guard let offset else { return .zero }
                    let at = k - offset
                    return at >= 0 && at < capacity ? binned[entry * capacity + at] : .zero
                }
                return EnvelopeComponentHistory.Equivalent(
                    region: entryRegions[entry], outerAreaM2: Double(sides[entry].outerCount) * area,
                    innerAreaM2: Double(sides[entry].innerCount) * area,
                    outerImpulsePaS: values.map(\.x), innerImpulsePaS: values.map(\.y),
                    peakNetPa: finite(peak[entry].z))
            }
            return EnvelopeComponentHistory(
                component: components[n], outerAreaM2: Double(sides[n].outerCount) * area,
                innerAreaM2: Double(sides[n].innerCount) * area,
                faceCount: Int(sides[n].outerCount + sides[n].innerCount), binS: binS,
                windowStartS: fromArrival ? start.map { Double($0) * binS } : nil,
                outerImpulsePaS: values.map(\.x), innerImpulsePaS: values.map(\.y),
                peakOuterPa: finite(peak[n].x), peakInnerPa: finite(peak[n].y), peakNetPa: finite(peak[n].z),
                outerMaxPa: largest?.map { finite($0.x) }, innerMaxPa: largest?.map { finite($0.y) },
                plate: equivalent(plateEntry[n]), strip: equivalent(stripEntry[n]),
                truncated: fromArrival ? start.map { elapsedBins - $0 > capacity } ?? false : truncated,
                invalid: peak[n].w != 0)
        }
    }
}

extension EnvelopeComponentRecorder {
    /// Starts the recorder's clock (`ComponentClock`: its bin and the seconds into it) at `start`,
    /// s since detonation, so that bins and windows are counted from detonation on the mapped start
    /// too, as the histories read them (`histories(elapsed:)` takes the run's time).
    func startClock(at start: Double) {
        let bin = (start / binS).rounded(.down)
        clock.contents().storeBytes(of: UInt32(bin), as: UInt32.self)
        clock.contents().storeBytes(of: Float(start - bin * binS), toByteOffset: 4, as: Float.self)
    }
}

extension EnvelopeComponentRecorder {
    /// Its state for a checkpoint (`SolverCheckpoint`): its shared buffers (the peaks, bins, maxima,
    /// clock, first bins, the step's means and the dispatches its first sample left) and the still
    /// air's pressure the first sample wrote, which is private. The other private buffers are
    /// rewritten every step.
    func checkpoint(queue: MTLCommandQueue) -> ClosureCheckpoint {
        let shared = ClosureCheckpoint.buffers(of: self, name: "envelopeComponents")
        return ClosureCheckpoint(
            checkpointName: "envelopeComponents", checkpointVersion: 1,
            parts: {
                shared.parts() + [
                    .bytes("stillPressure", SolverCheckpoint.readPrivate(self.stillPressure, queue: queue))
                ]
            },
            restore: { parts in
                try shared.restore(parts)
                try SolverCheckpoint.writePrivate(
                    parts["stillPressure"], into: self.stillPressure, queue: queue,
                    name: "envelopeComponents.stillPressure")
            })
    }
}
