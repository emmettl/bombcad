import BlastModel
import Foundation
import Metal

/// A production sweep's observed values. Skipped tiled cells have executed=false and zero slots.
public struct SweepUpdateSample: Sendable {
    public let step: Int
    public let time: Double
    public let dt: Float
    public let executed: [Bool]
    public let values: [[Float]]
}

public struct SweepUpdateTrace: Sendable {
    public static let fields = [
        "oldRho", "oldMx", "oldMy", "oldMz", "oldEnergy",
        "newRho", "newMx", "newMy", "newMz", "newEnergy",
        "lowMass", "lowMx", "lowMy", "lowMz", "lowEnergy",
        "highMass", "highMx", "highMy", "highMz", "highEnergy",
        "lambda", "dt", "axis", "batchActiveStep",
    ]
    public static let compensatedFields =
        fields + [
            "oldResidualRho", "oldResidualEnergy", "newResidualRho", "newResidualEnergy",
            "componentMask", "floorEventsBefore", "floorEventsAfter", "densityIncrement", "energyIncrement",
        ]
    public let capturedFields: [String]
    public let indices: [Int]
    public let initialStates: [[Float]]
    public let finalStates: [[Float]]
    public let samples: [SweepUpdateSample]
}

final class SweepUpdateCapture {
    let indices: [Int]
    let initialStates: [[Float]]
    let fields: [String]
    let buffer: MTLBuffer
    let outputOffset: Int
    let sweep: MTLComputePipelineState
    let sweepTiles: MTLComputePipelineState
    let maxSamples: Int
    var samples: [SweepUpdateSample] = []
    var overflow = false
    var sourceCapture: SweepSourceCapture?

    init(
        indices: [Int], initialStates: [[Float]], fields: [String], buffer: MTLBuffer, outputOffset: Int,
        sweep: MTLComputePipelineState, sweepTiles: MTLComputePipelineState, maxSamples: Int
    ) {
        self.indices = indices
        self.initialStates = initialStates
        self.fields = fields
        self.buffer = buffer
        self.outputOffset = outputOffset
        self.sweep = sweep
        self.sweepTiles = sweepTiles
        self.maxSamples = maxSamples
    }
}

extension BlastSolver {
    var supportsSweepUpdateDiagnostics: Bool {
        grid.nx > 1 && grid.ny == 1 && grid.nz == 1 && configuration.airModel == .idealGas
            && configuration.gravity == nil && configuration.mixing == nil
            && configuration.radiativeCooling == nil && !configuration.afterburning
            && configuration.afterburnLimit == nil && configuration.afterburnMixing == nil
            && !hasSpecies && bodies.isEmpty && refinement == nil && refinementLevels.isEmpty
            && terrainCut == nil && structureCut == nil && congestionBuffer == nil
            && {
                let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
                return (0..<grid.cellCount).allSatisfy { mask[$0] == 0 }
            }()
    }

    /// Opt-in 1-D bare ideal-gas diagnostic. Use blocking advance; restart disables capture.
    /// Stores actual variables in sibling sweeps; added stores can perturb compiler arithmetic.
    /// Require independent plain/observed parity before interpreting these as ordinary-run evidence.
    public func configureSweepUpdateDiagnostics(
        _ indices: [Int], maxSamples: Int = 32768, captureHostSources: Bool = false
    ) throws {
        precondition(!batchInFlight && stepCount == 0, "Configure before stepping")
        guard supportsSweepUpdateDiagnostics, !captureHostSources || supportsHostSweepSourceDiagnostics,
            (1...16).contains(indices.count),
            Set(indices).count == indices.count,
            indices.allSatisfy({ $0 >= 0 && $0 < grid.cellCount }),
            (1...32768).contains(maxSamples)
        else {
            throw BlastError.allocationFailed(
                "1-D ideal-gas sweep diagnostics, 1–16 distinct cells and bounded samples")
        }
        let fields = compensatedSweep == nil ? SweepUpdateTrace.fields : SweepUpdateTrace.compensatedFields
        let mask = maskBuffer.contents().bindMemory(to: UInt8.self, capacity: grid.cellCount)
        guard (0..<grid.cellCount).allSatisfy({ mask[$0] == 0 }),
            let buffer = device.makeBuffer(
                length: (grid.cellCount + indices.count * fields.count) * 4, options: .storageModeShared)
        else { throw BlastError.allocationFailed("unmasked sweep cells and diagnostic buffers") }
        memset(buffer.contents(), 0, buffer.length)
        let mapping = buffer.contents().bindMemory(to: UInt32.self, capacity: grid.cellCount)
        for (q, index) in indices.enumerated() { mapping[index] = UInt32(q + 1) }
        let initial = withState { cells in
            indices.map { n in
                let c = cells[n]
                return [c.density, c.momentumX, c.momentumY, c.momentumZ, c.energy]
            }
        }
        let observed = try ShaderLibrary.make(
            device: device, sweepUpdates: true, compensatedSweep: compensatedSweep != nil)
        let suffix = compensatedSweep == nil ? "Updates" : "CompensatedUpdates"
        let constants = MTLFunctionConstantValues()
        var model = configuration.airModel.rawValue
        constants.setConstantValue(&model, type: .uint, index: ShaderLibrary.airModelConstant)
        sweepUpdateCapture = SweepUpdateCapture(
            indices: indices, initialStates: initial, fields: fields, buffer: buffer,
            outputOffset: grid.cellCount * 4,
            sweep: try ShaderLibrary.pipeline("sweep\(suffix)", in: observed, constants: constants),
            sweepTiles: try ShaderLibrary.pipeline("sweepTiles\(suffix)", in: observed, constants: constants),
            maxSamples: maxSamples)
        if captureHostSources {
            sweepUpdateCapture?.sourceCapture = SweepSourceCapture(
                indices: indices, nx: grid.nx, lowWall: configuration.reflectiveFaces.contains(.xMin),
                highWall: configuration.reflectiveFaces.contains(.xMax))
        }
    }

    /// Refuses overflow or a history not collected by blocking advance, rather than truncating.
    public func sweepUpdateTrace() throws -> SweepUpdateTrace {
        precondition(!batchInFlight)
        guard supportsSweepUpdateDiagnostics, let capture = sweepUpdateCapture, !capture.overflow,
            !capture.samples.isEmpty,
            capture.samples.count == stepCount, capture.samples.last?.step == stepCount
        else { throw BlastError.allocationFailed("a complete bounded sweep-update history") }
        let final = withState { cells in
            capture.indices.map { n in
                let c = cells[n]
                return [c.density, c.momentumX, c.momentumY, c.momentumZ, c.energy]
            }
        }
        return SweepUpdateTrace(
            capturedFields: capture.fields, indices: capture.indices, initialStates: capture.initialStates,
            finalStates: final, samples: capture.samples)
    }

    func collectSweepUpdateDiagnostics() {
        guard let capture = sweepUpdateCapture else { return }
        let control = controlBuffer.contents().load(as: StepControl.self)
        guard control.dt > 0 else { return }
        let step = stepCount + Int(control.activeSteps)
        guard capture.samples.last?.step != step else { return }
        guard capture.samples.count < capture.maxSamples else {
            capture.overflow = true
            return
        }
        let stride = capture.fields.count
        let data = (capture.buffer.contents() + capture.outputOffset).bindMemory(
            to: Float.self, capacity: capture.indices.count * stride)
        let values = capture.indices.indices.map { q in
            Array(UnsafeBufferPointer(start: data + q * stride, count: stride))
        }
        let sample = SweepUpdateSample(
            step: step, time: Double(control.clock) / 1_099_511_627_776, dt: control.dt,
            executed: values.map { $0[23] == Float(control.activeSteps) }, values: values)
        capture.samples.append(sample)
        collectHostSweepSources(sample)
    }
}

extension ShaderLibrary {
    /// Appends diagnostic siblings; ordinary functions and their source bytes remain untouched.
    static func addingSweepUpdateCapture(to source: String, compensated: Bool = false) throws -> String {
        func function(_ startText: String) throws -> String {
            guard let start = source.range(of: startText),
                let end = source.range(of: "\n}", range: start.upperBound..<source.endIndex)
            else { throw BlastError.missingShader("sweep update diagnostic function: \(startText)") }
            return String(source[start.lowerBound..<end.upperBound])
        }
        func replace(_ value: String, _ anchor: String, _ replacement: String) throws -> String {
            guard value.components(separatedBy: anchor).count == 2 else {
                throw BlastError.missingShader("unique sweep update diagnostic anchor: \(anchor)")
            }
            return value.replacingOccurrences(of: anchor, with: replacement)
        }
        let cellName = compensated ? "sweepCellCompensated" : "sweepCell"
        let fieldCount =
            compensated ? SweepUpdateTrace.compensatedFields.count : SweepUpdateTrace.fields.count
        let extra =
            compensated
            ? """
                    updateTrace[q + 24] = as_type<uint>(compensationBefore.x);
                    updateTrace[q + 25] = as_type<uint>(compensationBefore.y);
                    updateTrace[q + 26] = as_type<uint>(compensationAfter.x);
                    updateTrace[q + 27] = as_type<uint>(compensationAfter.y);
                    updateTrace[q + 28] = as_type<uint>(compensationBefore.z);
                    updateTrace[q + 29] = as_type<uint>(compensationBefore.w);
                    updateTrace[q + 30] = as_type<uint>(compensationAfter.w);
                    updateTrace[q + 31] = as_type<uint>(compensatedDensityIncrement);
                    updateTrace[q + 32] = as_type<uint>(compensatedEnergyIncrement);
            """ : ""
        var helper = try function("static inline void \(cellName)(")
        helper = try replace(helper, "\(cellName)(", "\(cellName)Updates(")
        helper = try replace(
            helper, "device float4 *structureCutDefects) {",
            "device float4 *structureCutDefects, device uint *updateData) {"
        )
        helper = try replace(
            helper, "    dst[index] = result;",
            """
                dst[index] = result;
                uint updateSlot = updateData[index];
                device uint *updateTrace = updateData + u.nx * u.ny * u.nz;
                if (updateSlot != 0) {
                    uint q = (updateSlot - 1) * \(fieldCount);
                    updateTrace[q] = as_type<uint>(c.rho);
                    updateTrace[q + 1] = as_type<uint>(c.mx);
                    updateTrace[q + 2] = as_type<uint>(c.my);
                    updateTrace[q + 3] = as_type<uint>(c.mz);
                    updateTrace[q + 4] = as_type<uint>(c.energy);
                    updateTrace[q + 5] = as_type<uint>(result.rho);
                    updateTrace[q + 6] = as_type<uint>(result.mx);
                    updateTrace[q + 7] = as_type<uint>(result.my);
                    updateTrace[q + 8] = as_type<uint>(result.mz);
                    updateTrace[q + 9] = as_type<uint>(result.energy);
                    updateTrace[q + 10] = as_type<uint>(fluxLow.mass);
                    updateTrace[q + 11] = as_type<uint>(fluxLow.momentum.x);
                    updateTrace[q + 12] = as_type<uint>(fluxLow.momentum.y);
                    updateTrace[q + 13] = as_type<uint>(fluxLow.momentum.z);
                    updateTrace[q + 14] = as_type<uint>(fluxLow.energy);
                    updateTrace[q + 15] = as_type<uint>(fluxHigh.mass);
                    updateTrace[q + 16] = as_type<uint>(fluxHigh.momentum.x);
                    updateTrace[q + 17] = as_type<uint>(fluxHigh.momentum.y);
                    updateTrace[q + 18] = as_type<uint>(fluxHigh.momentum.z);
                    updateTrace[q + 19] = as_type<uint>(fluxHigh.energy);
                    updateTrace[q + 20] = as_type<uint>(lambda);
                    updateTrace[q + 21] = as_type<uint>(dt);
                    updateTrace[q + 22] = as_type<uint>(float(u.axis));
                    updateTrace[q + 23] = as_type<uint>(float(control.activeSteps));
                    \(extra)
                }
            """)
        var siblings = helper
        for name in (compensated ? ["sweepCompensated", "sweepTilesCompensated"] : ["sweep", "sweepTiles"]) {
            var kernel = try function("kernel void \(name)(")
            kernel = try replace(kernel, "kernel void \(name)(", "kernel void \(name)Updates(")
            let position =
                !name.hasPrefix("sweepTiles")
                ? "uint3 tid [[thread_position_in_grid]]) {"
                : "uint3 group [[threadgroup_position_in_grid]],"
            kernel = try replace(kernel, position, "device uint *updateData [[buffer(30)]],\n" + position)
            kernel = try replace(kernel, "\(cellName)(", "\(cellName)Updates(")
            kernel = try replace(
                kernel, "structureCutDefects);", "structureCutDefects, updateData);")
            siblings += "\n" + kernel
        }
        return source + "\n" + siblings + "\n"
    }
}
