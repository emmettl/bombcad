import BlastModel
import CryptoKit
import Foundation
import Metal

/// Provenance of an opt-in selector experiment, not a production arithmetic policy.
public struct StepSelectorDiagnosticInfo: Codable, Sendable {
    public let sourceSHA256: String
    public let entryPoint: String
    public let mathMode: String
    public let mathFloatingPointFunctions: String
    public let languageVersion: UInt
    public let device: String
}

struct StepSelectorDiagnostic {
    let library: MTLLibrary
    let pipeline: MTLComputePipelineState
    let info: StepSelectorDiagnosticInfo

    init(device: MTLDevice) throws {
        let source = try ShaderLibrary.mainSource()
        let options = MTLCompileOptions()
        options.mathMode = .safe
        options.mathFloatingPointFunctions = .precise
        guard options.mathMode == .safe && options.mathFloatingPointFunctions == .precise else {
            throw BlastError.allocationFailed("explicit safe/precise step selector options")
        }
        library = try device.makeLibrary(source: source, options: options)
        pipeline = try ShaderLibrary.pipeline("prepareStep", in: library)
        info = StepSelectorDiagnosticInfo(
            sourceSHA256: SHA256.hash(data: Data(source.utf8))
                .map { String(format: "%02x", $0) }.joined(),
            entryPoint: "prepareStep", mathMode: "safe", mathFloatingPointFunctions: "precise",
            languageVersion: options.languageVersion.rawValue, device: device.name)
    }
}

extension BlastSolver {
    var supportsStepSelectorDiagnostics: Bool {
        let probe = BuildProbe.current
        return configuration.gravity == nil && configuration.mixing == nil
            && configuration.refinement == 1 && refinement == nil && refinementLevels.isEmpty
            && bodies.isEmpty && structureCut == nil && congestionBuffer == nil && !hasFlame
            && gaugeCount == 0
            && configuration.afterburnLimit == nil && configuration.afterburnMixing == nil
            && sweepUpdateCapture == nil && compensatedSweep == nil
            && probe.mathMode == nil && probe.contract == nil && probe.statePadding == 0
            && !probe.padInMiddle && probe.perturbations.isEmpty && KernelRounding.current == nil
    }

    /// Only `prepareStep` uses this sibling's safe/precise options; all other pipelines are unchanged.
    /// Configure before stepping. Restart disables it. Unsupported configurations refuse encoding.
    /// This diagnostic changes numerical results and does not admit generated training data.
    public func configureStepSelectorDiagnostics(enabled: Bool = true) throws {
        guard !batchInFlight && stepCount == 0 else {
            throw BlastError.allocationFailed("configure step selector diagnostics before stepping")
        }
        guard !enabled || supportsStepSelectorDiagnostics else {
            throw BlastError.allocationFailed(
                "step selector diagnostics require uniform fixed air without gauges or kernel-build overrides"
            )
        }
        stepSelectorDiagnostic = enabled ? try StepSelectorDiagnostic(device: device) : nil
    }

    public var stepSelectorDiagnosticInfo: StepSelectorDiagnosticInfo? { stepSelectorDiagnostic?.info }
}
