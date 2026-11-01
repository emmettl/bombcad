import BlastModel
import Foundation
import Metal
import simd

/// A collapse's dust in the air (Dust.metal; emmettl/bombcad-work#36, docs/whole-event.md, "Dust,
/// stage 1"): fines made by a structure's fracture, crushing and rubble impacts (`DustSettings`),
/// two classes carried by the air and settling, deposited where they land, counted as they go.
/// Passive: neither the air nor the structure reads it. Off unless a run asks for it
/// (`BlastSolver.enableDust`); without it no kernel, buffer or checkpoint changes.
public final class AirDust {
    public let settings: DustSettings
    let cells: Int
    /// The fines' densities (fine, coarse; kg/m³), a copy for each of the air's state buffers.
    let fields: [MTLBuffer]
    /// Six counts a cell, in quanta: settled (fine, coarse), out of the domain, made there.
    let ledger: MTLBuffer
    /// The fines made in each air cell since its last injection (a 64-bit count a cell, in quanta),
    /// then the totals: made outside the domain, by the elements, by the rubble's impacts.
    let made: MTLBuffer
    /// The faces' mass fluxes (low, high) of the sweep just done; not state.
    let massFlux: MTLBuffer
    /// Each element's state (`dustFromElements`) and each rubble slot's impact losses
    /// (`dustFromImpacts`), for the first body's solids.
    let elementSources: MTLBuffer?
    let impacts: MTLBuffer?
    let sweep: MTLComputePipelineState
    let sweepTiles: MTLComputePipelineState
    let inject: MTLComputePipelineState
    let fromElements: MTLComputePipelineState
    let fromImpacts: MTLComputePipelineState

    /// kg a quantum: the ledger and the counters are exact in these.
    static let quantum: Float = 1e-15
    /// kg: fines an element or particle holds back before it gives them to the air.
    static let emitAt: Float = 1e-12

    init(
        settings: DustSettings, device: MTLDevice, library: MTLLibrary, constants: MTLFunctionConstantValues,
        cells: Int, elements: Int, rubbleSlots: Int
    ) throws {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            memset(buffer.contents(), 0, buffer.length)
            return buffer
        }
        self.settings = settings
        self.cells = cells
        fields = [try buffer(cells * 8, "dust A"), try buffer(cells * 8, "dust B")]
        ledger = try buffer(cells * 6 * 8, "dust ledger")
        made = try buffer((cells + 3) * 8, "dust made")
        massFlux = try buffer(cells * 8, "dust mass fluxes")
        elementSources = elements > 0 ? try buffer(elements * 32, "dust element sources") : nil
        impacts = rubbleSlots > 0 ? try buffer(rubbleSlots * 16, "dust impacts") : nil
        sweep = try ShaderLibrary.pipeline("dustSweep", in: library, constants: constants)
        sweepTiles = try ShaderLibrary.pipeline("dustSweepTiles", in: library, constants: constants)
        inject = try ShaderLibrary.pipeline("dustInject", in: library, constants: constants)
        fromElements = try ShaderLibrary.pipeline("dustFromElements", in: library)
        fromImpacts = try ShaderLibrary.pipeline("dustFromImpacts", in: library)
    }

    /// Everything made, carried and counted set back to none.
    func reset() {
        for buffer in [fields[0], fields[1], ledger, made, massFlux]
            + [elementSources, impacts].compactMap({ $0 })
        {
            memset(buffer.contents(), 0, buffer.length)
        }
    }

    /// The trace was folded (`StructureSolver.workTotals`): each element's last reading of it is
    /// zero again.
    func traceFolded() {
        guard let elementSources else { return }
        let states = elementSources.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: elementSources.length / 16)
        for n in 0..<(elementSources.length / 16) { states[n].x = 0 }
    }

    func uniforms(cellSize: Float, count: Int = 0) -> DustUniforms {
        DustUniforms(
            settlingFine: Float(settings.fineSettling), settlingCoarse: Float(settings.coarseSettling),
            quantum: Self.quantum, cellVolume: cellSize * cellSize * cellSize,
            energyPerKilogram: Float(settings.energyPerKilogram), impactShare: Float(settings.impactShare),
            fineShare: UInt32((settings.fineShare * 4096).rounded()), count: UInt32(count),
            emitAt: Self.emitAt,
            cells: UInt32(cells), spare0: 0, spare1: 0)
    }

    /// The ledger's counts summed over the cells, kg, with `ground(cell)` telling apart the cells
    /// whose floor is the ground and `within(cell)` those over the plan.
    func ledgerTotals(dims: SIMD3<Int>, plan: (min: SIMD2<Float>, max: SIMD2<Float>), cellSize: Float)
        -> DustLedger
    {
        var ledger = DustLedger()
        let q = Double(Self.quantum)
        let counts = self.ledger.contents().bindMemory(to: Int64.self, capacity: cells * 6)
        for n in 0..<cells {
            let base = 6 * n
            let settled = SIMD2(Double(counts[base]), Double(counts[base + 1])) * q
            let gone = SIMD2(Double(counts[base + 2]), Double(counts[base + 3])) * q
            let here = SIMD2(Double(counts[base + 4]), Double(counts[base + 5])) * q
            ledger.made += here
            ledger.leftDomain += gone
            if settled != .zero {
                let x = n % dims.x
                let y = (n / dims.x) % dims.y
                let z = n / (dims.x * dims.y)
                if z > 0 {
                    ledger.onSolids += settled
                } else {
                    let centre = (SIMD2(Float(x), Float(y)) + 0.5) * cellSize
                    let within = all(centre .>= plan.min) && all(centre .<= plan.max)
                    if within { ledger.onGroundWithin += settled } else { ledger.onGroundOutside += settled }
                }
            }
        }
        let totals = (made.contents() + cells * 8).bindMemory(to: Int64.self, capacity: 3)
        ledger.madeOutside = Double(totals[0]) * q
        ledger.fromElements = Double(totals[1]) * q
        ledger.fromImpacts = Double(totals[2]) * q
        return ledger
    }
}

/// Why a solver cannot carry dust (`BlastSolver.enableDust`).
public struct DustUnsupported: Error, CustomStringConvertible {
    public var description: String
}

/// Matches `DustUniforms` in Dust.metal.
struct DustUniforms {
    var settlingFine: Float
    var settlingCoarse: Float
    var quantum: Float
    var cellVolume: Float
    var energyPerKilogram: Float
    var impactShare: Float
    var fineShare: UInt32
    var count: UInt32
    var emitAt: Float
    var cells: UInt32
    var spare0: UInt32
    var spare1: UInt32
}

extension BlastSolver {
    /// Carries a collapse's dust from now on (`AirDust`): made by the first body's solids (from its
    /// work trace, `StructureSolver.tracesWork`, which must be on as it runs, and its rubble), carried
    /// by the air, which must stay awake to carry it. Call before the run, and before restoring a
    /// checkpoint saved with it. Not with refined air, cut cells, congestion, a deflagration,
    /// periodic sides or the sweep diagnostics.
    public func enableDust(_ settings: DustSettings) throws {
        guard dust == nil else { return }
        guard refinement == nil, terrainCut == nil, structureCut == nil, congestionBuffer == nil,
            deflagrationStage == nil, !configuration.periodicSides, sweepUpdateCapture == nil,
            compensatedSweep == nil
        else {
            throw DustUnsupported(
                description:
                    "dust: not with refined air, cut cells, congestion, a deflagration, periodic sides or the sweep diagnostics"
            )
        }
        let solids = bodies.first?.solids
        let constants = try cellKernels().constants
        let dust = try AirDust(
            settings: settings, device: device, library: library, constants: constants, cells: grid.cellCount,
            elements: solids?.elementCount ?? 0, rubbleSlots: solids?.rubbleSlotCount ?? 0)
        if let solids {
            try solids.attachDust(impacts: dust.impacts)
            solids.workFolded = { [weak dust] in dust?.traceFolded() }
        }
        self.dust = dust
        cellKernelsByModel = [:]
    }

    /// The dust's ledger and its field now (between batches), with the plan `plan` (x, y corners, m)
    /// to tell the ground under the pile from the ground beyond it; nil without dust.
    public func dustReading(plan: (min: SIMD2<Float>, max: SIMD2<Float>)) -> (
        ledger: DustLedger, field: DustField
    )? {
        precondition(!batchInFlight, "Wait for the batch before reading the dust")
        guard let dust else { return nil }
        let dims = SIMD3(grid.nx, grid.ny, grid.nz)
        var ledger = dust.ledgerTotals(dims: dims, plan: plan, cellSize: grid.cellSize)
        let values = dust.fields[current].contents().bindMemory(
            to: SIMD2<Float>.self, capacity: grid.cellCount)
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        var fine = [Float](repeating: 0, count: grid.cellCount)
        var coarse = fine
        var solid = [Bool](repeating: false, count: grid.cellCount)
        for n in 0..<grid.cellCount {
            fine[n] = values[n].x
            coarse[n] = values[n].y
            solid[n] = mask[n] != 0
        }
        let field = DustField(
            dims: dims, cellSize: Double(grid.cellSize), fine: fine, coarse: coarse, solid: solid)
        let airborne = field.airborne()
        ledger.airborne = airborne.all
        ledger.inSolids = airborne.inSolids
        return (ledger, field)
    }

    /// Fines put straight into air cell (i, j, k), kg, as if made there (for tests): taken in with
    /// the next step's.
    public func addDust(_ i: Int, _ j: Int, _ k: Int, mass: Double) {
        guard let dust else { return }
        let n = i + grid.nx * (j + grid.ny * k)
        let counts = dust.made.contents().bindMemory(to: Int64.self, capacity: dust.cells + 3)
        counts[n] += Int64((mass / Double(AirDust.quantum)).rounded())
    }

    /// After each air sweep: the fines through the faces the sweep has just crossed, from copy
    /// `current` to the other.
    func encodeDustSweep(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms, tiles: MTLSize?) {
        guard let dust else { return }
        var uniforms = uniforms
        var settings = dust.uniforms(cellSize: grid.cellSize)
        encoder.setComputePipelineState(tiles == nil ? dust.sweep : dust.sweepTiles)
        encoder.setBuffer(dust.fields[current], offset: 0, index: 0)
        encoder.setBuffer(dust.fields[1 - current], offset: 0, index: 1)
        encoder.setBuffer(maskBuffer, offset: 0, index: 2)
        encoder.setBuffer(dust.massFlux, offset: 0, index: 3)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 4)
        encoder.setBuffer(controlBuffer, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 6)
        encoder.setBytes(&settings, length: MemoryLayout<DustUniforms>.stride, index: 7)
        encoder.setBuffer(dust.ledger, offset: 0, index: 8)
        encoder.setBuffer(tileListBuffer, offset: 0, index: 9)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 10)
        if let tiles {
            encoder.dispatchThreadgroups(
                indirectBuffer: tileDispatchBuffer, indirectBufferOffset: 0, threadsPerThreadgroup: tiles)
        } else {
            dispatchGrid(encoder, pipeline: dust.sweep)
        }
    }

    /// After the structure's substeps (and the outline's remask): the fines its elements and rubble
    /// made, counted to the air cells holding them.
    func encodeDustSources(_ encoder: MTLComputeCommandEncoder, fluid: StructureSolver.FluidBinding) {
        guard let dust, let solids = bodies.first?.solids else { return }
        solids.encodeDustSources(encoder, dust: dust, fluid: fluid)
    }

    /// Each step, after the structure's: each air cell takes the fines counted to it.
    func encodeDustInjection(_ encoder: MTLComputeCommandEncoder, uniforms: SolverUniforms) {
        guard let dust else { return }
        var uniforms = uniforms
        var settings = dust.uniforms(cellSize: grid.cellSize)
        encoder.setComputePipelineState(dust.inject)
        encoder.setBuffer(dust.fields[current], offset: 0, index: 0)
        encoder.setBuffer(dust.made, offset: 0, index: 1)
        encoder.setBuffer(dust.ledger, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 3)
        encoder.setBytes(&settings, length: MemoryLayout<DustUniforms>.stride, index: 4)
        encoder.setBuffer(tileFlagBuffer, offset: 0, index: 5)
        dispatchGrid(encoder, pipeline: dust.inject)
    }
}

extension StructureSolver {
    /// The rubble's slots, one per element the body started with (0 without rubble).
    var rubbleSlotCount: Int { rubbleSystem?.count ?? 0 }

    /// Specialises the rubble's move kernel to add up each particle's impact losses for the dust
    /// into `impacts` (`rubbleDust`, constant 31, in Rubble.metal).
    func attachDust(impacts: MTLBuffer?) throws {
        guard let rubble = rubbleSystem, let impacts else { return }
        rubble.dustImpactsHeld = BufferReference(impacts)
        try rubble.specialiseMove()
    }

    /// Each air step, after the substeps: the fines its elements' fracture and crushing and its
    /// rubble's impacts have made, counted to the air cells holding them.
    func encodeDustSources(_ encoder: MTLComputeCommandEncoder, dust: AirDust, fluid: FluidBinding) {
        var uniforms = makeDustUniforms(fluid: fluid)
        let group = MTLSize(width: dust.fromElements.threadExecutionWidth, height: 1, depth: 1)
        if let work = workBuffer, let sources = dust.elementSources, elementCount > 0 {
            var settings = dust.uniforms(cellSize: fluid.grid.cellSize, count: elementCount)
            encoder.setComputePipelineState(dust.fromElements)
            encoder.setBuffer(work, offset: 0, index: 0)
            encoder.setBuffer(sources, offset: 0, index: 1)
            encoder.setBuffer(instanceBuffer, offset: 0, index: 2)
            encoder.setBuffer(nodeMapBuffer, offset: 0, index: 3)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 4)
            encoder.setBuffer(nodeListBuffer, offset: 0, index: 5)
            encoder.setBuffer(fluid.mask, offset: 0, index: 6)
            encoder.setBuffer(dust.made, offset: 0, index: 7)
            encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 8)
            encoder.setBytes(&settings, length: MemoryLayout<DustUniforms>.stride, index: 9)
            encoder.dispatchThreads(
                MTLSize(width: elementCount, height: 1, depth: 1), threadsPerThreadgroup: group)
        }
        if let rubble = rubbleSystem, let impacts = dust.impacts {
            var settings = dust.uniforms(cellSize: fluid.grid.cellSize, count: rubble.count)
            encoder.setComputePipelineState(dust.fromImpacts)
            encoder.setBuffer(rubble.particles, offset: 0, index: 0)
            encoder.setBuffer(impacts, offset: 0, index: 1)
            encoder.setBuffer(rubble.state, offset: 0, index: 2)
            encoder.setBuffer(fluid.mask, offset: 0, index: 3)
            encoder.setBuffer(dust.made, offset: 0, index: 4)
            encoder.setBytes(&uniforms, length: MemoryLayout<StructureUniforms>.stride, index: 5)
            encoder.setBytes(&settings, length: MemoryLayout<DustUniforms>.stride, index: 6)
            encoder.dispatchThreads(
                MTLSize(width: rubble.count, height: 1, depth: 1), threadsPerThreadgroup: group)
        }
    }
}

extension ShaderLibrary {
    /// The sweeps with the dust (`AirDust`): siblings of `sweep` and `sweepTiles` that also keep each
    /// cell's low and high faces' mass fluxes in buffer 30, for `dustSweep` to carry the fines by.
    /// The ordinary sweeps' source is unchanged. Not with porous cells, whose fluxes change after.
    static func addingDustSweep(to source: String) throws -> String {
        func function(_ startText: String) throws -> String {
            guard let start = source.range(of: startText),
                let end = source.range(of: "\n}", range: start.upperBound..<source.endIndex)
            else { throw BlastError.missingShader("dust sweep function: \(startText)") }
            return String(source[start.lowerBound..<end.upperBound])
        }
        func replace(_ value: String, _ anchor: String, _ replacement: String) throws -> String {
            guard value.components(separatedBy: anchor).count == 2 else {
                throw BlastError.missingShader("unique dust sweep anchor: \(anchor)")
            }
            return value.replacingOccurrences(of: anchor, with: replacement)
        }
        var helper = try function("static inline void sweepCell(")
        helper = try replace(helper, "sweepCell(", "sweepCellDust(")
        helper = try replace(
            helper, "device float4 *structureCutDefects) {",
            "device float4 *structureCutDefects, device float2 *dustFlux) {")
        helper = try replace(
            helper, "    Cell c = src[index];\n",
            "    dustFlux[index] = float2(fluxLow.mass, fluxHigh.mass);\n    Cell c = src[index];\n")
        var siblings = helper
        for name in ["sweep", "sweepTiles"] {
            var kernel = try function("kernel void \(name)(")
            kernel = try replace(kernel, "kernel void \(name)(", "kernel void \(name)Dust(")
            let position =
                name == "sweep"
                ? "uint3 tid [[thread_position_in_grid]]) {" : "uint3 group [[threadgroup_position_in_grid]],"
            kernel = try replace(kernel, position, "device float2 *dustFlux [[buffer(30)]],\n" + position)
            kernel = try replace(kernel, "sweepCell(", "sweepCellDust(")
            kernel = try replace(kernel, "structureCutDefects);", "structureCutDefects, dustFlux);")
            siblings += "\n" + kernel
        }
        return source + "\n" + siblings + "\n"
    }
}
