import Foundation
import Metal

/// The luminous gas losing the heat it radiates (see `Radiation.metal`): after each step, every
/// cell at least `luminousTemperature` hot absorbs and emits as the thermal radiation's volume
/// takes it to, the radiance is carried along the 26 directions of the lattice through the box of
/// luminous cells, and each cell gives up what it emits less what it absorbs. The energy given up
/// is `BlastSolver.radiatedEnergy`. Off by default (nil in `SolverConfiguration`).
public struct RadiativeCooling: Sendable, Hashable, Codable {
    /// The gas emits and absorbs at or above this, K; below it, it is transparent.
    public var luminousTemperature: Float = 1500
    /// The hot gas's own grey absorption coefficient, 1/m.
    public var absorption: Float = 0.1
    /// Soot as a share of the mass of unburnt detonation products (only with afterburning).
    public var sootYield: Float = 0.185
    /// The most of a cell's internal energy one step may take: a guard, never reached in practice
    /// (an opaque cell at 3,000 K loses about a hundredth of its heat in a step).
    public var largestShare: Float = 0.25

    public init(luminousTemperature: Float = 1500, absorption: Float = 0.1, sootYield: Float = 0.185) {
        self.luminousTemperature = luminousTemperature
        self.absorption = absorption
        self.sootYield = sootYield
    }

    /// The same medium as `spec`'s volume, so that the gas loses what the volume radiates.
    public init(spec: ThermalSpec) {
        self.init(
            luminousTemperature: spec.luminousTemperature, absorption: spec.absorption,
            sootYield: spec.sootYield)
    }

    /// The soot's absorption per kelvin and per kg/m³ of unburnt products, 1/(m K).
    var sootAbsorption: Float { ThermalMedium.sootAbsorption * sootYield / ThermalMedium.sootDensity }
}

/// Mirrors `RadiationUniforms` in Radiation.metal.
struct RadiationUniforms {
    var luminous: Float
    var absorption: Float
    var sootAbsorption: Float
    var hasSpecies: UInt32
    var largestShare: Float
}

/// The radiative cooling's kernels and buffers, made at `restart()` while it is on.
final class RadiativeCoolingStage {
    let settings: RadiativeCooling
    let airModel: AirModel
    private let reset: MTLComputePipelineState
    private let medium: MTLComputePipelineState
    private let mediumTiles: MTLComputePipelineState
    private let prepare: MTLComputePipelineState
    private let lines: MTLComputePipelineState
    private let apply: MTLComputePipelineState
    private let tally: MTLComputePipelineState
    /// Per cell: the medium (κ, B) and the loss, W/m³.
    private let mediumBuffer: MTLBuffer
    private let lossBuffer: MTLBuffer
    /// The luminous cells' box, lowest corner then highest (inclusive), four words each.
    private let boxBuffer: MTLBuffer
    private let arguments: MTLBuffer
    private let partials: MTLBuffer
    /// What each step of a batch radiated, J.
    private let radiated: MTLBuffer
    private let grid: Grid

    /// The lattice's 13 lines, each followed both ways.
    static let directions: [SIMD3<Int32>] = [
        [1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [1, -1, 0], [1, 0, 1], [1, 0, -1], [0, 1, 1], [0, 1, -1],
        [1, 1, 1], [1, 1, -1], [1, -1, 1], [1, -1, -1],
    ]
    static let group = MTLSize(width: 8, height: 8, depth: 4)

    init(settings: RadiativeCooling, device: MTLDevice, library: MTLLibrary, grid: Grid, airModel: AirModel)
        throws
    {
        self.settings = settings
        self.airModel = airModel
        self.grid = grid
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            try ShaderLibrary.pipeline(name, in: library)
        }
        // The kernels that work out temperatures are compiled for the gas model alone.
        let constants = MTLFunctionConstantValues()
        var model = airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        reset = try pipeline("radiationReset")
        medium = try ShaderLibrary.pipeline("radiationMedium", in: library, constants: constants)
        mediumTiles = try ShaderLibrary.pipeline("radiationMediumTiles", in: library, constants: constants)
        prepare = try pipeline("radiationPrepare")
        lines = try pipeline("radiationLines")
        apply = try ShaderLibrary.pipeline("radiationApply", in: library, constants: constants)
        tally = try pipeline("radiationTally")
        func buffer(_ length: Int, _ label: String) throws -> MTLBuffer {
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else {
                throw BlastError.allocationFailed("\(label) (\(length) bytes)")
            }
            buffer.label = label
            memset(buffer.contents(), 0, buffer.length)
            return buffer
        }
        mediumBuffer = try buffer(grid.cellCount * MemoryLayout<SIMD2<Float>>.stride, "radiating medium")
        lossBuffer = try buffer(grid.cellCount * MemoryLayout<Float>.stride, "radiative loss")
        boxBuffer = try buffer(8 * MemoryLayout<UInt32>.stride, "luminous box")
        arguments = try buffer(3 * MemoryLayout<UInt32>.stride, "radiation dispatch")
        let groups =
            ((grid.nx + Self.group.width - 1) / Self.group.width)
            * ((grid.ny + Self.group.height - 1) / Self.group.height)
            * ((grid.nz + Self.group.depth - 1) / Self.group.depth)
        partials = try buffer(groups * MemoryLayout<Float>.stride, "radiated partials")
        radiated = try buffer(BlastSolver.maxStepsPerBatch * MemoryLayout<Float>.stride, "radiated a step")
    }

    private var uniforms: RadiationUniforms {
        RadiationUniforms(
            luminous: settings.luminousTemperature, absorption: settings.absorption,
            sootAbsorption: settings.sootAbsorption, hasSpecies: 0, largestShare: settings.largestShare)
    }

    /// Encodes one step's cooling of `state`, the step's new state. `tiles` are the awake tiles'
    /// list, their dispatch and its threadgroup, when still air is skipped.
    func encode(
        _ encoder: MTLComputeCommandEncoder, state: MTLBuffer, mask: MTLBuffer, species: MTLBuffer?,
        placeholder: MTLBuffer, control: MTLBuffer, uniforms solver: SolverUniforms,
        tiles: (list: MTLBuffer, dispatch: MTLBuffer, threads: MTLSize)?
    ) {
        var solver = solver
        var radiation = uniforms
        radiation.hasSpecies = species == nil ? 0 : 1
        let solverLength = MemoryLayout<SolverUniforms>.stride
        let radiationLength = MemoryLayout<RadiationUniforms>.stride

        encoder.setComputePipelineState(reset)
        encoder.setBuffer(boxBuffer, offset: 0, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        encoder.setComputePipelineState(tiles == nil ? medium : mediumTiles)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(mask, offset: 0, index: 1)
        encoder.setBuffer(species ?? placeholder, offset: 0, index: 2)
        encoder.setBuffer(mediumBuffer, offset: 0, index: 3)
        encoder.setBuffer(boxBuffer, offset: 0, index: 4)
        encoder.setBuffer(control, offset: 0, index: 5)
        encoder.setBytes(&solver, length: solverLength, index: 6)
        encoder.setBytes(&radiation, length: radiationLength, index: 7)
        if let tiles {
            encoder.setBuffer(tiles.list, offset: 0, index: 8)
            encoder.dispatchThreadgroups(
                indirectBuffer: tiles.dispatch, indirectBufferOffset: 0, threadsPerThreadgroup: tiles.threads)
        } else {
            let width = min(medium.threadExecutionWidth, grid.nx)
            let height = min(medium.maxTotalThreadsPerThreadgroup / width, grid.ny)
            encoder.dispatchThreads(
                MTLSize(width: grid.nx, height: grid.ny, depth: grid.nz),
                threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1))
        }

        encoder.setComputePipelineState(prepare)
        encoder.setBuffer(boxBuffer, offset: 0, index: 0)
        encoder.setBuffer(arguments, offset: 0, index: 1)
        encoder.setBuffer(control, offset: 0, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))

        encoder.setComputePipelineState(lines)
        encoder.setBuffer(mediumBuffer, offset: 0, index: 0)
        encoder.setBuffer(mask, offset: 0, index: 1)
        encoder.setBuffer(lossBuffer, offset: 0, index: 2)
        encoder.setBuffer(boxBuffer, offset: 0, index: 3)
        encoder.setBytes(&solver, length: solverLength, index: 4)
        for (n, direction) in Self.directions.enumerated() {
            var line = SIMD4<Int32>(direction, n == 0 ? 1 : 0)
            encoder.setBytes(&line, length: MemoryLayout<SIMD4<Int32>>.stride, index: 5)
            encoder.dispatchThreadgroups(
                indirectBuffer: arguments, indirectBufferOffset: 0, threadsPerThreadgroup: Self.group)
        }

        encoder.setComputePipelineState(apply)
        encoder.setBuffer(state, offset: 0, index: 0)
        encoder.setBuffer(mediumBuffer, offset: 0, index: 1)
        encoder.setBuffer(lossBuffer, offset: 0, index: 2)
        encoder.setBuffer(boxBuffer, offset: 0, index: 3)
        encoder.setBuffer(control, offset: 0, index: 4)
        encoder.setBytes(&solver, length: solverLength, index: 5)
        encoder.setBytes(&radiation, length: radiationLength, index: 6)
        encoder.setBuffer(partials, offset: 0, index: 7)
        encoder.dispatchThreadgroups(
            indirectBuffer: arguments, indirectBufferOffset: 0, threadsPerThreadgroup: Self.group)

        encoder.setComputePipelineState(tally)
        encoder.setBuffer(partials, offset: 0, index: 0)
        encoder.setBuffer(arguments, offset: 0, index: 1)
        encoder.setBuffer(control, offset: 0, index: 2)
        encoder.setBuffer(radiated, offset: 0, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    /// What the completed batch's `rows` steps radiated, J, added up in order.
    func collect(rows: Int) -> Double {
        let values = radiated.contents().bindMemory(to: Float.self, capacity: BlastSolver.maxStepsPerBatch)
        var total = 0.0
        for row in 0..<min(rows, BlastSolver.maxStepsPerBatch) {
            total += Double(values[row])
            values[row] = 0
        }
        return total
    }
}

extension BlastSolver {
    /// Makes, or drops, the radiative cooling's stage for the configuration, and forgets what was
    /// radiated. Called from `restart()`.
    func setUpRadiativeCooling() {
        radiatedEnergy = 0
        radiationHistory = []
        guard let settings = configuration.radiativeCooling else {
            radiativeCoolingStage = nil
            return
        }
        if let stage = radiativeCoolingStage, stage.settings == settings,
            stage.airModel == configuration.airModel
        {
            return
        }
        radiativeCoolingStage = try? RadiativeCoolingStage(
            settings: settings, device: device, library: library, grid: grid, airModel: configuration.airModel
        )
    }
}
