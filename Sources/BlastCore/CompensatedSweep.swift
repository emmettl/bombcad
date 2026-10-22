import BlastModel
import Metal

/// Experimental components only; no default or broad geometry support is implied.
public enum CompensatedSweepComponents: String, Sendable, CaseIterable {
    case density, energy, both

    var mask: Float {
        switch self {
        case .density: 1
        case .energy: 2
        case .both: 3
        }
    }
}

final class CompensatedSweep {
    let components: CompensatedSweepComponents
    /// Per cell: density error, energy error, component mask, component-floor event count.
    let residuals: MTLBuffer
    let sweep: MTLComputePipelineState
    let sweepTiles: MTLComputePipelineState

    init(
        components: CompensatedSweepComponents, residuals: MTLBuffer,
        sweep: MTLComputePipelineState, sweepTiles: MTLComputePipelineState
    ) {
        self.components = components
        self.residuals = residuals
        self.sweep = sweep
        self.sweepTiles = sweepTiles
    }
}

extension BlastSolver {
    var supportsCompensatedSweep: Bool {
        supportsSweepUpdateDiagnostics && pendingFirings.isEmpty && largestCharge == 0 && !hasFlame
    }

    /// Opt-in protected-kahan-v1. Configure after filling, before stepping/update capture.
    /// Restart disables the experiment. Unsupported geometry/configuration is refused.
    /// retainResiduals=false is the matching protected-arithmetic control, clearing errors each update.
    public func configureCompensatedSweep(
        _ components: CompensatedSweepComponents, retainResiduals: Bool = true
    ) throws {
        precondition(!batchInFlight && stepCount == 0, "Configure before stepping")
        guard supportsCompensatedSweep, sweepUpdateCapture == nil,
            let residuals = device.makeBuffer(
                length: grid.cellCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
        else { throw BlastError.allocationFailed("bare 1-D compensated sweep before update capture") }
        let values = residuals.contents().bindMemory(to: SIMD4<Float>.self, capacity: grid.cellCount)
        for i in 0..<grid.cellCount {
            values[i] = SIMD4(0, 0, components.mask + (retainResiduals ? 0 : 4), 0)
        }
        let library = try ShaderLibrary.make(device: device, compensatedSweep: true)
        let constants = MTLFunctionConstantValues()
        var model = configuration.airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        compensatedSweep = CompensatedSweep(
            components: components, residuals: residuals,
            sweep: try ShaderLibrary.pipeline("sweepCompensated", in: library, constants: constants),
            sweepTiles: try ShaderLibrary.pipeline("sweepTilesCompensated", in: library, constants: constants)
        )
    }

    /// Full experimental state. Slots: density error, energy error, mask, floor-event count.
    public func compensatedSweepState() -> [SIMD4<Float>]? {
        precondition(!batchInFlight, "Wait before reading experimental state")
        guard let experiment = compensatedSweep else { return nil }
        return Array(
            UnsafeBufferPointer(
                start: experiment.residuals.contents().bindMemory(
                    to: SIMD4<Float>.self, capacity: grid.cellCount),
                count: grid.cellCount))
    }
}

extension ShaderLibrary {
    /// Guarded sibling only. Slot 29 is otherwise-unused structure-cut defects in this scope.
    /// The ordinary source and Cell/uniform ABI remain untouched.
    static func addingCompensatedSweep(to source: String) throws -> String {
        func function(_ startText: String) throws -> String {
            guard let start = source.range(of: startText),
                let end = source.range(of: "\n}", range: start.upperBound..<source.endIndex)
            else { throw BlastError.missingShader("compensated sweep function: \(startText)") }
            return String(source[start.lowerBound..<end.upperBound])
        }
        func replace(_ text: String, _ anchor: String, _ replacement: String) throws -> String {
            guard text.components(separatedBy: anchor).count == 2 else {
                throw BlastError.missingShader("unique compensated sweep anchor: \(anchor)")
            }
            return text.replacingOccurrences(of: anchor, with: replacement)
        }
        var helper = try function("static inline void sweepCell(")
        helper = try replace(helper, "sweepCell(", "sweepCellCompensated(")
        helper = try replace(
            helper, "    float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);",
            """
                // With no cut geometry, slot 29 belongs solely to this experiment.
                float4 compensationBefore = structureCutDefects[index];
                float4 compensationAfter = compensationBefore;
                uint compensationMask = uint(compensationBefore.z);
                float compensatedDensityIncrement = 0.0f;
                float compensatedEnergyIncrement = 0.0f;
                float rho = c.rho - lambda * (fluxHigh.mass - fluxLow.mass);
                if ((compensationMask & 1u) != 0u) {
                    float3 update = protectedConservedUpdate(c.rho, compensationBefore.x, lambda,
                                                            fluxLow.mass, fluxHigh.mass);
                    rho = update.x;
                    compensationAfter.x = update.y;
                    compensatedDensityIncrement = update.z;
                }
            """)
        helper = try replace(
            helper, "    float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);",
            """
                float energy = c.energy - lambda * (fluxHigh.energy - fluxLow.energy);
                if ((compensationMask & 2u) != 0u) {
                    float3 update = protectedConservedUpdate(c.energy, compensationBefore.y, lambda,
                                                            fluxLow.energy, fluxHigh.energy);
                    energy = update.x;
                    compensationAfter.y = update.y;
                    compensatedEnergyIncrement = update.z;
                }
            """)
        helper = try replace(
            helper, "    rho = max(rho, u.densityFloor);",
            """
                if (rho < u.densityFloor && (compensationMask & 1u) != 0u) {
                    compensationAfter.x = 0.0f;
                    compensationAfter.w += 1.0f;
                }
                rho = max(rho, u.densityFloor);
            """)
        helper = try replace(
            helper, "    if (pressure < u.pressureFloor) {",
            """
                if (pressure < u.pressureFloor) {
                    if ((compensationMask & 2u) != 0u) {
                        compensationAfter.y = 0.0f;
                        compensationAfter.w += 1.0f;
                    }
            """)
        helper = try replace(
            helper, "    dst[index] = result;",
            "    if ((compensationMask & 4u) != 0u) compensationAfter.xy = float2(0.0f);\n    dst[index] = result;\n    structureCutDefects[index] = compensationAfter;"
        )
        var siblings = """
            static inline float3 protectedConservedUpdate(float old, float error, float lambda,
                                                         float low, float high) {
                #pragma METAL fp math_mode(safe)
                #pragma METAL fp contract(off)
                float difference = high - low;
                float delta = -lambda * difference;
                float corrected = delta - error;
                float next = old + corrected;
                float nextError = (next - old) - corrected;
                return float3(next, nextError, delta);
            }

            """ + helper
        for name in ["sweep", "sweepTiles"] {
            var kernel = try function("kernel void \(name)(")
            kernel = try replace(kernel, "kernel void \(name)(", "kernel void \(name)Compensated(")
            kernel = try replace(kernel, "sweepCell(", "sweepCellCompensated(")
            siblings += "\n" + kernel
        }
        return source + "\n" + siblings + "\n"
    }
}
