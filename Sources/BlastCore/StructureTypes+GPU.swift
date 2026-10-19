import BlastModel
import ContactSearchMetal
import Foundation
import Metal
import simd

extension KernelRounding {
    var mathMode: MTLMathMode? { self == .relaxed ? .relaxed : nil }
}

/// How the kernels are compiled, for measuring what fast math does to results: unchanged unless
/// set in the environment. `BOMBCAD_KERNEL_MATH` (fast, relaxed or safe) sets the math mode,
/// `BOMBCAD_KERNEL_CONTRACT` (off, on or fast) prepends Metal's contraction pragma, and
/// `BOMBCAD_STATE_PADDING` adds that many unused floats to the structure's element state, a change
/// to the source that alters no arithmetic, as an unrelated edit would: at its end, or with
/// `BOMBCAD_STATE_PADDING_AT=middle` after `compaction` (the last field read from Swift), which
/// moves the fields after it. `BOMBCAD_KERNEL_PERTURB`, a comma-separated list, makes other such
/// edits: `branch` a test in the element kernel that never passes, `kernel` an unused kernel calling
/// the element kernel's helpers. See "Fast math and the build" in docs/performance.md.
struct BuildProbe {
    var mathMode: MTLMathMode?
    var contract: String?
    var statePadding = 0
    var padInMiddle = false
    var perturbations: Set<String> = []

    static let current: BuildProbe = {
        let environment = ProcessInfo.processInfo.environment
        var probe = BuildProbe()
        switch environment["BOMBCAD_KERNEL_MATH"] {
        case "fast": probe.mathMode = .fast
        case "relaxed": probe.mathMode = .relaxed
        case "safe": probe.mathMode = .safe
        default: break
        }
        if let contract = environment["BOMBCAD_KERNEL_CONTRACT"], ["off", "on", "fast"].contains(contract) {
            probe.contract = contract
        }
        probe.statePadding = max(0, environment["BOMBCAD_STATE_PADDING"].flatMap(Int.init) ?? 0)
        probe.padInMiddle = environment["BOMBCAD_STATE_PADDING_AT"] == "middle"
        probe.perturbations = Set(
            (environment["BOMBCAD_KERNEL_PERTURB"] ?? "").split(separator: ",").map(String.init))
        return probe
    }()
}

extension ShaderLibrary {
    static func make(device: MTLDevice) throws -> MTLLibrary {
        let files = [
            "Solver", "Refine", "Structure", "Rubble", "Shell", "BodyContact", "Footing", "Extract",
            "Radiation",
            "Gravity",
            "Deflagration", "Mixing",
        ]
        var probe = BuildProbe.current
        if let rounding = KernelRounding.current {
            probe.mathMode = rounding.mathMode
            probe.contract = rounding.contract
        }
        var source = try files.map { name in
            guard
                let url = Bundle.module.url(
                    forResource: name, withExtension: "metal", subdirectory: "Shaders")
            else {
                throw BlastError.missingShader("\(name).metal")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.joined(separator: "\n")
        // Contact's table and search are ContinuumKit's (`ContactSearchMetal`), compiled ahead of
        // the kernels that use them.
        source = try MetalContactSearch.functionSource() + "\n" + source
        if probe.statePadding > 0 {
            // Unused floats in the element state: a change to the source that alters no
            // arithmetic, to see what results a rebuild moves.
            let padding = "    float unusedPadding[\(probe.statePadding)];\n"
            let size = "sizeof(ElementState) == \(StructureSolver.stateStride - 4 * probe.statePadding)"
            guard source.contains(size) else { throw BlastError.missingShader("ElementState's size check") }
            source = source.replacingOccurrences(
                of: size, with: "sizeof(ElementState) == \(StructureSolver.stateStride)")
            if probe.padInMiddle {
                let anchor =
                    "    float compaction;  // concrete: largest volumetric compression so far, mu = V0 / V - 1\n"
                guard let field = source.range(of: anchor) else {
                    throw BlastError.missingShader("ElementState's compaction, to pad after")
                }
                source.insert(contentsOf: padding, at: field.upperBound)
            } else {
                guard let start = source.range(of: "struct ElementState {"),
                    let end = source.range(of: "\n};", range: start.upperBound..<source.endIndex)
                else { throw BlastError.missingShader("ElementState's end, to pad") }
                source.insert(contentsOf: "\n" + padding.dropLast(), at: end.lowerBound)
            }
        }
        if probe.perturbations.contains("branch") {
            let load = "    ElementState state = states[compact];\n"
            guard source.contains(load) else {
                throw BlastError.missingShader("the element kernel's state load")
            }
            source = source.replacingOccurrences(
                of: load, with: load + "    if (state.plasticStrain < -1.0e30f) { state.display = 0.5f; }\n")
        }
        if probe.perturbations.contains("kernel") {
            source += """

                kernel void unusedProbe(device float *values [[buffer(0)]],
                                        constant MaterialParameters *materials [[buffer(1)]],
                                        uint id [[thread_position_in_grid]]) {
                    float3 eigen;
                    float3x3 vectors;
                    symmetricEigen(float3x3(values[id]), eigen, vectors);
                    values[id] = eigen.x + tensionEnvelope(values[id + 1], 1.0f, materials[0])
                        + compressionIncrease(values[id + 2], materials[0]);
                }

                """
        }
        if let contract = probe.contract { source = "#pragma METAL fp contract(\(contract))\n" + source }
        guard let mathMode = probe.mathMode else {
            return try device.makeLibrary(source: source, options: nil)
        }
        let options = MTLCompileOptions()
        options.mathMode = mathMode
        return try device.makeLibrary(source: source, options: options)
    }

    /// `constants` with the terrain's cut cells compiled in.
    static func withCutCells(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: cutCellsConstant)
        return constants
    }

    /// `constants` with structures' cut cells compiled in.
    static func withStructureCut(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: structureCutConstant)
        return constants
    }

    /// `constants` with congestion's porous cells compiled in.
    static func withPorousAir(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: porousAirConstant)
        return constants
    }

    /// `constants` with afterburning's extinction limit compiled in.
    static func withBurnLimit(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: burnLimitConstant)
        return constants
    }

    /// `constants` with sub-grid mixing compiled in.
    static func withMixing(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: airMixingConstant)
        return constants
    }

    /// `constants` with gravity in the air compiled in.
    static func withGravity(_ constants: MTLFunctionConstantValues) -> MTLFunctionConstantValues {
        var on = true
        constants.setConstantValue(&on, type: .bool, index: airGravityConstant)
        return constants
    }

    /// A compute pipeline for kernel `name`, specialised with `constants` (none by default).
    /// Every kernel is specialised: many read the optional gas-model constant through the gas
    /// functions, and Metal builds a pipeline from such a kernel only once it is specialised.
    static func pipeline(
        _ name: String, in library: MTLLibrary,
        constants: MTLFunctionConstantValues = MTLFunctionConstantValues()
    ) throws -> MTLComputePipelineState {
        guard let function = try? library.makeFunction(name: name, constantValues: constants) else {
            throw BlastError.missingFunction(name)
        }
        return try library.device.makeComputePipelineState(function: function)
    }
}
