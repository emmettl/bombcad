import Foundation
import Metal
import simd

/// Layout matches `DeflagrationUniforms` in `Deflagration.metal`.
struct DeflagrationUniforms {
    var nx: UInt32 = 0
    var ny: UInt32 = 0
    var nz: UInt32 = 0
    var dx: Float = 0
    var ignitionRadius: Float = 0
    var heat: Float = 0
    var cloudFraction: Float = 0
    var stoichiometricFraction: Float = 0
    var lowerLimit: Float = 0
    var upperLimit: Float = 0
    var speedScale: Float = 0
    var speedPower: Float = 0
    var speedWidth: Float = 0
    var speedFactor: Float = 1
    var wrinklingRadius: Float = 0
    var wrinklingPower: Float = 0
    var subgridCoefficient: Float = 0
    var turbulentSlope: Float = 0
    var ignitionX: Float = 0
    var ignitionY: Float = 0
    var ignitionZ: Float = 0
    var densityFloor: Float = 0
    var ambientPressure: Float = 0
    var gamma: Float = 0
    var airModel: UInt32 = 0
    var panelCellCount: UInt32 = 0
    var unburntDensity: Float = 0
    var unburntGamma: Float = 0
    var expansionRatio: Float = 0
}

/// The GPU side of a deflagration: the flame, if there is one, and the vent panels, which also
/// serve a charge (see `Deflagration.metal`).
final class DeflagrationStage {
    /// Peters' b3, the sub-grid turbulence's share of the burning velocity.
    static let turbulentSlope: Float = 1
    /// Exponent of the burning velocity's growth with radius (Gostintsev et al. 1988).
    static let wrinklingPower: Float = 1.0 / 3

    let deflagration: Deflagration?
    /// The panels with a release pressure, in the order of `openTimes`.
    let panels: [VentPanel]
    private(set) var uniforms: DeflagrationUniforms
    /// What each cell burns in the step under way.
    private let burningBuffer: MTLBuffer
    private let advancePipeline: MTLComputePipelineState
    private let applyPipeline: MTLComputePipelineState
    private let pressurePipeline: MTLComputePipelineState
    private let releasePipeline: MTLComputePipelineState
    private let panelCellBuffer: MTLBuffer
    private let panelPeakBuffer: MTLBuffer
    private let releaseBuffer: MTLBuffer
    private let panelOpenedBuffer: MTLBuffer
    private let openedAtBuffer: MTLBuffer
    /// When each panel opened (s), or nil while closed.
    private(set) var openTimes: [Double?]
    /// The unburnt mixture when the cloud was laid down, kg.
    var initialUnburnt: Double = 0

    /// The GPU resources a stage needs.
    private struct Resources {
        var burning: MTLBuffer
        var pipelines: [MTLComputePipelineState]
        var panelCells: MTLBuffer
        var peaks: MTLBuffer
        var releases: MTLBuffer
        var opened: MTLBuffer
        var openedAt: MTLBuffer
    }

    // The resources are made before the stage, which keeps its initialiser simple.
    static func make(
        device: MTLDevice, library: MTLLibrary, grid: Grid, deflagration: Deflagration?, panels: [VentPanel],
        panelCells: [(index: Int, panel: Int)], heat: Float, unburntDensity: Float, expansionRatio: Float,
        configuration: SolverConfiguration
    ) throws -> DeflagrationStage {
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            memset(buffer.contents(), 0, buffer.length)
            return buffer
        }
        let cells = deflagration == nil ? 0 : grid.cellCount
        let resources = Resources(
            burning: try buffer(cells * MemoryLayout<Float>.stride, "burning"),
            pipelines: try ["advanceFlame", "applyBurning", "ventPressure", "ventRelease"].map {
                try ShaderLibrary.pipeline($0, in: library)
            },
            panelCells: try buffer(panelCells.count * MemoryLayout<SIMD2<UInt32>>.stride, "vent panel cells"),
            peaks: try buffer(panels.count * 4, "vent panel peaks"),
            releases: try buffer(panels.count * 4, "vent release pressures"),
            opened: try buffer(panels.count * 4, "vent panels opened"),
            openedAt: try buffer(panels.count * 4, "vent opening times"))
        let entries = resources.panelCells.contents().bindMemory(
            to: SIMD2<UInt32>.self, capacity: max(panelCells.count, 1))
        for (n, entry) in panelCells.enumerated() {
            entries[n] = SIMD2(UInt32(entry.index), UInt32(entry.panel))
        }
        let release = resources.releases.contents().bindMemory(to: Float.self, capacity: max(panels.count, 1))
        for (n, panel) in panels.enumerated() { release[n] = panel.releasePressure }
        return DeflagrationStage(
            resources: resources, grid: grid, deflagration: deflagration, panels: panels,
            panelCellCount: panelCells.count, heat: heat, unburntDensity: unburntDensity,
            expansionRatio: expansionRatio, configuration: configuration)
    }

    // Unoptimised: with optimisation, Swift 6's LLVM verifier rejects this initialiser ("Instruction
    // does not dominate all uses", a field of the class), and the whole release build fails.
    @_optimize(none)
    private init(
        resources: Resources, grid: Grid, deflagration: Deflagration?, panels: [VentPanel],
        panelCellCount: Int,
        heat: Float, unburntDensity: Float, expansionRatio: Float, configuration: SolverConfiguration
    ) {
        self.deflagration = deflagration
        self.panels = panels
        burningBuffer = resources.burning
        advancePipeline = resources.pipelines[0]
        applyPipeline = resources.pipelines[1]
        pressurePipeline = resources.pipelines[2]
        releasePipeline = resources.pipelines[3]
        panelCellBuffer = resources.panelCells
        panelPeakBuffer = resources.peaks
        releaseBuffer = resources.releases
        panelOpenedBuffer = resources.opened
        openedAtBuffer = resources.openedAt
        openTimes = Array(repeating: nil, count: panels.count)

        let dx = grid.cellSize
        var u = DeflagrationUniforms()
        u.nx = UInt32(grid.nx)
        u.ny = UInt32(grid.ny)
        u.nz = UInt32(grid.nz)
        u.dx = dx
        u.densityFloor = configuration.densityFloor
        u.ambientPressure = configuration.ambientPressure
        u.gamma = configuration.gamma
        u.airModel = configuration.airModel.rawValue
        u.panelCellCount = UInt32(panelCellCount)
        if let deflagration {
            let gas = deflagration.gas
            let fit = gas.burningVelocityFit
            u.heat = heat
            u.cloudFraction = deflagration.concentration
            u.stoichiometricFraction = gas.stoichiometricFraction
            u.lowerLimit = gas.flammableRange.lowerBound
            u.upperLimit = gas.flammableRange.upperBound
            u.speedScale = fit.scale
            u.speedPower = fit.power
            u.speedWidth = fit.width
            let acceleration = deflagration.acceleration
            u.speedFactor = max(acceleration.factor, 0)
            u.wrinklingRadius = max(acceleration.wrinklingRadius ?? 0, 0)
            u.wrinklingPower = Self.wrinklingPower
            u.subgridCoefficient = max(acceleration.subgridCoefficient ?? 0, 0)
            u.turbulentSlope = Self.turbulentSlope
            u.ignitionX = deflagration.ignition.x
            u.ignitionY = deflagration.ignition.y
            u.ignitionZ = deflagration.ignition.z
            u.unburntDensity = unburntDensity
            u.unburntGamma = 1.4
            u.expansionRatio = expansionRatio
        }
        uniforms = u
    }

    /// One step's flame and vents, after the air's sweeps. `species` holds the unburnt mixture.
    func encodeStep(
        _ encoder: MTLComputeCommandEncoder, state: MTLBuffer, species: MTLBuffer?, mask: MTLBuffer,
        rigidMask: MTLBuffer, control: MTLBuffer
    ) {
        if deflagration != nil, let species {
            encodeFlame(encoder, state: state, species: species, mask: mask, control: control)
        }
        if uniforms.panelCellCount > 0 {
            encodeVents(encoder, state: state, mask: mask, rigidMask: rigidMask, control: control)
        }
    }

    private func encodeFlame(
        _ encoder: MTLComputeCommandEncoder, state: MTLBuffer, species: MTLBuffer, mask: MTLBuffer,
        control: MTLBuffer
    ) {
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(species, offset: 0, index: 1)
        encoder.setBuffer(mask, offset: 0, index: 2)
        encoder.setBuffer(burningBuffer, offset: 0, index: 3)
        encoder.setBuffer(control, offset: 0, index: 5)
        dispatchCells(encoder, advancePipeline)
        dispatchCells(encoder, applyPipeline)
    }

    /// Runs `pipeline` once a cell, with the buffers already bound.
    private func dispatchCells(_ encoder: MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState) {
        var u = uniforms
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&u, length: MemoryLayout<DeflagrationUniforms>.stride, index: 6)
        let width = pipeline.threadExecutionWidth
        let height = max(pipeline.maxTotalThreadsPerThreadgroup / width / 4, 1)
        encoder.dispatchThreads(
            MTLSize(width: Int(u.nx), height: Int(u.ny), depth: Int(u.nz)),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
    }

    private func encodeVents(
        _ encoder: MTLComputeCommandEncoder, state: MTLBuffer, mask: MTLBuffer, rigidMask: MTLBuffer,
        control: MTLBuffer
    ) {
        var u = uniforms
        let threads = MTLSize(width: Int(u.panelCellCount), height: 1, depth: 1)
        encoder.setComputePipelineState(pressurePipeline)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(mask, offset: 0, index: 1)
        encoder.setBuffer(panelCellBuffer, offset: 0, index: 2)
        encoder.setBuffer(panelPeakBuffer, offset: 0, index: 3)
        encoder.setBuffer(control, offset: 0, index: 4)
        encoder.setBytes(&u, length: MemoryLayout<DeflagrationUniforms>.stride, index: 5)
        encoder.dispatchThreads(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: min(Int(u.panelCellCount), pressurePipeline.maxTotalThreadsPerThreadgroup), height: 1,
                depth: 1))
        encoder.setComputePipelineState(releasePipeline)
        encoder.setBuffer(mask, offset: 0, index: 0)
        encoder.setBuffer(rigidMask, offset: 0, index: 1)
        encoder.setBuffer(panelCellBuffer, offset: 0, index: 2)
        encoder.setBuffer(panelPeakBuffer, offset: 0, index: 3)
        encoder.setBuffer(releaseBuffer, offset: 0, index: 4)
        encoder.setBuffer(panelOpenedBuffer, offset: 0, index: 5)
        encoder.setBuffer(openedAtBuffer, offset: 0, index: 6)
        encoder.setBuffer(control, offset: 0, index: 7)
        encoder.setBytes(&u, length: MemoryLayout<DeflagrationUniforms>.stride, index: 8)
        encoder.dispatchThreads(
            threads,
            threadsPerThreadgroup: MTLSize(
                width: min(Int(u.panelCellCount), releasePipeline.maxTotalThreadsPerThreadgroup), height: 1,
                depth: 1))
    }

    /// Notes the panels that opened during the batch that started at `start`.
    func complete(batchStart start: Double) {
        guard !panels.isEmpty else { return }
        let opened = panelOpenedBuffer.contents().bindMemory(to: UInt32.self, capacity: panels.count)
        let at = openedAtBuffer.contents().bindMemory(to: Float.self, capacity: panels.count)
        for n in panels.indices where openTimes[n] == nil && opened[n] != 0 {
            openTimes[n] = start + Double(at[n])
        }
    }
}

/// What has burnt so far, and when the panels opened.
public struct DeflagrationState: Sendable, Hashable {
    /// Unburnt mixture left, kg, and what was laid down.
    public var unburnt: Double
    public var initialUnburnt: Double
    /// Volume of the cells of mostly cloud gas that is mostly burnt, m³.
    public var burntVolume: Double
    /// When each panel with a release pressure opened (s), in scenario order, or nil.
    public var panelOpenTimes: [Double?]

    public var burntFraction: Double { initialUnburnt > 0 ? 1 - unburnt / initialUnburnt : 0 }
}

extension BlastSolver {
    /// The deflagration's progress, or nil without one.
    public func deflagrationState() -> DeflagrationState? {
        guard let stage = deflagrationStage else { return nil }
        let volume = Double(grid.cellSize) * Double(grid.cellSize) * Double(grid.cellSize)
        var unburnt = 0.0
        var burnt = 0
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        if stage.deflagration != nil {
            let densities = withState { cells in cells.map(\.density) }
            readSpecies { species in
                guard let species else { return }
                for index in 0..<grid.cellCount where mask[index] == 0 {
                    let s = species[index]
                    unburnt += Double(s.x)
                    if s.y > 0.5 * densities[index] && s.x < 0.5 * s.y { burnt += 1 }
                }
            }
        }
        return DeflagrationState(
            unburnt: unburnt * volume, initialUnburnt: stage.initialUnburnt,
            burntVolume: Double(burnt) * volume,
            panelOpenTimes: stage.openTimes)
    }

    /// Sets up the scenario's deflagration and vent panels, if any, before the air is filled:
    /// places the panels in the mask and makes the stage that advances the flame and opens them.
    /// A deflagration takes the species for its unburnt mixture, so afterburning is turned off;
    /// neither works with refined air, which is turned off too.
    func loadDeflagration(_ scenario: Scenario) throws {
        deflagrationStage = nil
        let panels = (scenario.ventPanels ?? []).filter { $0.releasePressure > 0 }
        let panelCells = placeVentPanels(panels)
        guard scenario.deflagration != nil || !panels.isEmpty else { return }
        if scenario.deflagration != nil { configuration.afterburning = false }
        configuration.refinement = 1
        let heat =
            scenario.deflagration?.heatPerKilogram(
                atmosphere: scenario.atmosphere, airModel: configuration.airModel, gamma: configuration.gamma)
            ?? 0
        let expansion =
            scenario.deflagration?.modelExpansionRatio(
                atmosphere: scenario.atmosphere, airModel: configuration.airModel, gamma: configuration.gamma)
            ?? 1
        deflagrationStage = try DeflagrationStage.make(
            device: device, library: library, grid: grid, deflagration: scenario.deflagration, panels: panels,
            panelCells: panelCells, heat: heat, unburntDensity: scenario.atmosphere.density,
            expansionRatio: expansion, configuration: configuration)
    }

    /// When each vent panel with a release pressure opened (s), in scenario order, or nil while it
    /// holds; empty without panels.
    public var ventPanelOpenTimes: [Double?] { deflagrationStage?.openTimes ?? [] }

    /// The share of the cloud's gas still unburnt in each cell (1 where there is none), or nil
    /// without a flame.
    public func unburntShare() -> [Float]? {
        guard hasFlame else { return nil }
        var shares = [Float](repeating: 1, count: grid.cellCount)
        readSpecies { species in
            guard let species else { return }
            for index in 0..<grid.cellCount where species[index].y > 1e-6 {
                shares[index] = min(max(species[index].x / species[index].y, 0), 1)
            }
        }
        return shares
    }

    /// Cells of each vent panel with a release pressure that are not already solid, solid from
    /// now on; the panels' cells as (cell, panel) pairs, panels numbered among those with a
    /// release pressure.
    private func placeVentPanels(_ panels: [VentPanel]) -> [(index: Int, panel: Int)] {
        // Editing the mask forgets the blocks' outline, so leave it alone without panels.
        guard !panels.isEmpty else { return [] }
        var cells: [(index: Int, panel: Int)] = []
        let dx = grid.cellSize
        mutateMask { mask in
            for (n, panel) in panels.enumerated() {
                let low = panel.box.min / dx - 0.5
                let high = panel.box.max / dx - 0.5
                for k in cellSpan(low.z, high.z, count: grid.nz) {
                    for j in cellSpan(low.y, high.y, count: grid.ny) {
                        for i in cellSpan(low.x, high.x, count: grid.nx) {
                            let index = grid.index(i, j, k)
                            // A cell a block or the ground already fills stays solid.
                            guard mask[index] == 0 else { continue }
                            mask[index] = 1
                            cells.append((index, n))
                        }
                    }
                }
            }
        }
        return cells
    }

    /// Fills the cloud's region with unburnt mixture: each fluid cell takes the share of its
    /// volume inside the region (sampled at 4 x 4 x 4 points), as unburnt mixture density, and
    /// as the density of gas from the cloud.
    func depositCloud(_ deflagration: Deflagration) -> Double {
        let dx = grid.cellSize
        let region = deflagration.region
        let samples = 4
        var total = 0.0
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        let low = simd_max(region.min / dx - 1, .zero)
        let high = region.max / dx + 1
        withState { cells in
            mutateSpecies { species in
                for index in 0..<grid.cellCount { species[index] = .zero }
                for k in cellSpan(low.z, high.z, count: grid.nz) {
                    for j in cellSpan(low.y, high.y, count: grid.ny) {
                        for i in cellSpan(low.x, high.x, count: grid.nx) {
                            let index = grid.index(i, j, k)
                            guard mask[index] == 0 else { continue }
                            var inside = 0
                            for c in 0..<(samples * samples * samples) {
                                let offset =
                                    (SIMD3<Float>(
                                        Float(c % samples), Float((c / samples) % samples),
                                        Float(c / (samples * samples)))
                                        + 0.5) / Float(samples)
                                let point = (SIMD3<Float>(Float(i), Float(j), Float(k)) + offset) * dx
                                if region.contains(point) { inside += 1 }
                            }
                            guard inside > 0 else { continue }
                            let share = Float(inside) / Float(samples * samples * samples)
                            // Unburnt mixture, and all gas from the cloud (see Deflagration.metal).
                            let mixture = share * cells[index].density
                            species[index] = SIMD2(mixture, mixture)
                            total += Double(mixture)
                        }
                    }
                }
            }
        }
        return total * Double(dx * dx * dx)
    }
}

/// Cells whose centres lie in (low, high], in cell units offset by half a cell (as blocks are
/// voxelised).
private func cellSpan(_ low: Float, _ high: Float, count: Int) -> Range<Int> {
    let first = max(0, Int(low.rounded(.up)))
    let last = min(count, Int(high.rounded(.up)))
    return first < last ? first..<last : 0..<0
}
