import BlastModel
import CryptoKit
import Foundation
import Metal
import RadialBlast
import simd

/// Read-only production recorder and accumulated-field samples after an active step.
/// Recorder-only observation changes command-buffer splitting and preserves batches and shaders.
public struct FirstPhaseDiagnosticSample: Sendable {
    public let step: Int
    public let time: Double
    public let dt: Float
    /// Per selected column: recorder peak, all-positive impulse, first-phase impulse, phase peak,
    /// open flag, interpolated accumulated peak, interpolated accumulated impulse, and dt.
    public let values: [[Float]]
}

/// Actual pressure consumed by an instrumented production recorder, followed by its resulting state.
/// Fields: pressure, peak, all-positive impulse, first-phase impulse, phase peak, open, dt, batch time.
public struct FirstPhasePressureSample: Sendable {
    public let step: Int
    public let time: Double
    public let values: [[Float]]
}

public struct FirstPhasePressureTrace: Sendable {
    public let columns: [Int]
    /// Recorder peak, all-positive impulse, first-phase impulse, phase peak and open before initialization.
    public let seedRecords: [[Float]]
    /// Includes the zero-dt initialization, followed by active steps.
    public let samples: [FirstPhasePressureSample]
}

final class FirstPhasePressureCapture {
    let slots: MTLBuffer
    let output: MTLBuffer
    let pipeline: MTLComputePipelineState
    let seeds: [[Float]]
    let initialTime: Double
    let maxSamples: Int
    var samples: [FirstPhasePressureSample] = []
    var overflow = false

    init(
        slots: MTLBuffer, output: MTLBuffer, pipeline: MTLComputePipelineState,
        seeds: [[Float]], initialTime: Double, maxSamples: Int
    ) {
        self.slots = slots
        self.output = output
        self.pipeline = pipeline
        self.seeds = seeds
        self.initialTime = initialTime
        self.maxSamples = maxSamples
    }
}

/// The first positive phase's impulse at a point over each plan cell, recorded as the run goes, by
/// the façade recorder's rule (`SurrogateBench.firstImpulse`, `HybridFarField.firstImpulse`): the
/// positive overpressure summed from the start until it first falls below nothing after reaching
/// half its peak. The field export's opt-in target for the learned field model
/// (docs/learned-models.md, "A first-phase impulse target"); off, nothing of it exists.
///
/// Each column reads the overpressure between two of its cells, `k0` and `k1`, as the field export
/// reads its height (`weight` the share of `k1`). Its record is the peak, the impulse of every
/// positive phase, the first phase's impulse and the peak that phase has reached; a second word
/// says whether that phase is still going. The rule wants the history's whole peak, which a run
/// does not know until its end: the phase stands while its peak is at least half the peak so far,
/// and when a later sample's overpressure is more than twice it, that sample's phase takes over,
/// counting the impulse of everything before it as the rule does. This is the rule exactly unless
/// a phase in between would have had half the final peak without being the largest so far.
///
/// The columns may come in several layers of the plan (`layers`, the field export's heights,
/// emmettl/bombcad-work#69): each its own plan of columns, records and flags, one after another in
/// the same buffers, swept by the same kernel at the layer's offset. One layer is the plan alone.
final class FirstPhaseColumns {
    let nx: Int
    let ny: Int
    let layers: Int
    /// Per column: `k0`, `k1`, the share of `k1`, and 1 to record (0 for none).
    let columns: MTLBuffer
    /// Per column: the peak, the impulse of every positive phase, the first phase's impulse and
    /// that phase's peak so far.
    let records: MTLBuffer
    /// Per column: 1 while the first phase is still going.
    let open: MTLBuffer
    var diagnosticIndices: [Int] = []
    var diagnosticSamples: [FirstPhaseDiagnosticSample] = []
    let pipeline: MTLComputePipelineState
    var pressureCapture: FirstPhasePressureCapture?

    init(device: MTLDevice, library: MTLLibrary, grid: Grid, columns cells: [SIMD4<Float>]) throws {
        nx = grid.nx
        ny = grid.ny
        let count = cells.count
        layers = count / max(1, nx * ny)
        guard layers >= 1, count == layers * nx * ny,
            cells.allSatisfy({
                $0.w == 0
                    || ($0.x >= 0 && $0.y >= 0 && Int($0.x) < grid.nz && Int($0.y) < grid.nz && $0.z >= 0
                        && $0.z <= 1)
            }),
            let columns = device.makeBuffer(
                bytes: cells, length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let records = device.makeBuffer(
                length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let open = device.makeBuffer(
                length: count * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { throw BlastError.allocationFailed("valid first-phase columns") }
        self.columns = columns
        self.records = records
        self.open = open
        pipeline = try ShaderLibrary.pipeline("sampleFirstPhase", in: library)
        reset()
    }

    var memoryFootprint: Int {
        columns.length + records.length + open.length
            + (pressureCapture.map { $0.slots.length + $0.output.length } ?? 0)
    }

    func reset() {
        pressureCapture = nil
        diagnosticSamples.removeAll(keepingCapacity: true)
        memset(records.contents(), 0, records.length)
        memset(open.contents(), 0, open.length)
    }

    /// The peak and impulse `blast`, a one-dimensional solution about `centre`, left at the columns'
    /// points within `radius` of it, before the grid takes over: the first phase still going.
    func seed(_ blast: SphericalBlast, centre: SIMD3<Float>, radius: Float, cellSize: Float) {
        let count = layers * nx * ny
        let cells = columns.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let record = records.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let going = open.contents().bindMemory(to: Float.self, capacity: count)
        for layer in 0..<layers {
            for j in 0..<ny {
                for i in 0..<nx {
                    let n = i + nx * j + nx * ny * layer
                    let column = cells[n]
                    guard column.w != 0 else { continue }
                    let z = ((1 - column.z) * (column.x + 0.5) + column.z * (column.y + 0.5)) * cellSize
                    let point = SIMD3((Float(i) + 0.5) * cellSize, (Float(j) + 0.5) * cellSize, z)
                    let r = simd_distance(point, centre)
                    guard r < radius else { continue }
                    let extremes = blast.extremes(at: Double(r))
                    let peak = Float(extremes.x)
                    let impulse = Float(extremes.y)
                    record[n] = SIMD4(peak, impulse, impulse, peak)
                    going[n] = 1
                }
            }
        }
    }

    /// The records, x-fast, layer after layer: the peak (Pa), every positive phase's impulse and
    /// the first phase's (Pa s), and the first phase's peak; zero where a column records nothing.
    func snapshot() -> [SIMD4<Float>] {
        let count = layers * nx * ny
        let record = records.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: record, count: count))
    }
}

extension BlastSolver {
    /// Records the first positive phase's impulse over each plan cell (`FirstPhaseColumns`) as the
    /// run goes, before stepping. `columns`, x-fast over the plan, gives each column's two cells,
    /// the share of the second and 1 to record it (0 for none); a whole number of plans after one
    /// another records that many layers (`FirstPhaseColumns.layers`). Does not change the air
    /// solution.
    public func configureFirstPhaseColumns(_ columns: [SIMD4<Float>]) throws {
        precondition(!batchInFlight && stepCount == 0, "Configure the columns before stepping")
        let recorder = try FirstPhaseColumns(device: device, library: library, grid: grid, columns: columns)
        // A charge mapped from one dimension has already passed the columns within its mapped
        // radius: there they take the solution's own peak and impulse, its first phase still going.
        for mappedStart in mappedStart {
            recorder.seed(
                mappedStart.blast, centre: mappedStart.centre, radius: mappedStart.radius,
                cellSize: grid.cellSize)
        }
        firstPhaseColumns = recorder
        firstPhaseNeedsInitialSample = true
    }

    /// Each plan cell's record, x-fast, layer after layer (`FirstPhaseColumns.snapshot`); nil
    /// unless configured.
    public func firstPhaseSnapshot() -> [SIMD4<Float>]? {
        precondition(!batchInFlight, "Cannot read the columns while a batch is in flight")
        return firstPhaseColumns?.snapshot()
    }

    /// Keeps the tiled production kernel but starts with every air tile active. This isolates
    /// work selection from the separate full-grid kernel in controlled numerical diagnostics.
    public func activateAllAirTilesForDiagnostics() throws {
        precondition(!batchInFlight && stepCount == 0, "Activate tiles before stepping")
        guard tilesEnabled else { throw BlastError.allocationFailed("tiled air must be enabled") }
        memset(tileFlagBuffer.contents(), 1, tileFlagBuffer.length)
    }

    /// Enables bounded-column host observation in the synchronous `advance` path. Each normal
    /// batch is split into one-step command buffers; its control and clock are not reset between
    /// parts. `capturePressure` additionally compiles an instrumented recorder and retains at most
    /// `maxPressureSamples` including initialization; overflow refuses a trace rather than truncating it.
    /// Indices are flattened across export layers. Samples may include sensitive model output.
    public func configureFirstPhaseDiagnostics(
        _ indices: [Int], capturePressure: Bool = false, maxPressureSamples: Int = 32768
    ) throws {
        precondition(!batchInFlight && stepCount == 0, "Configure diagnostics before stepping")
        guard let recorder = firstPhaseColumns, !indices.isEmpty, indices.count <= 64,
            Set(indices).count == indices.count,
            indices.allSatisfy({
                $0 >= 0 && $0 < (capturePressure ? recorder.layers : 1) * recorder.nx * recorder.ny
            })
        else { throw BlastError.allocationFailed("1–64 distinct configured first-phase columns") }
        let columns = recorder.columns.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: recorder.layers * recorder.nx * recorder.ny)
        guard indices.allSatisfy({ columns[$0].w != 0 }) else {
            throw BlastError.allocationFailed("diagnostics require enabled first-phase columns")
        }
        var capture: FirstPhasePressureCapture?
        if capturePressure {
            guard (2...32768).contains(maxPressureSamples),
                let slots = device.makeBuffer(
                    length: recorder.layers * recorder.nx * recorder.ny * MemoryLayout<UInt32>.stride,
                    options: .storageModeShared),
                let output = device.makeBuffer(
                    length: indices.count * 16 * MemoryLayout<Float>.stride, options: .storageModeShared)
            else { throw BlastError.allocationFailed("pressure trace buffers and a 2–32768 sample budget") }
            memset(slots.contents(), 0, slots.length)
            memset(output.contents(), 0, output.length)
            let mapping = slots.contents().bindMemory(to: UInt32.self, capacity: slots.length / 4)
            let count = recorder.layers * recorder.nx * recorder.ny
            let records = recorder.records.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
            let going = recorder.open.contents().bindMemory(to: Float.self, capacity: count)
            let seeds = indices.enumerated().map { q, n -> [Float] in
                mapping[n] = UInt32(q + 1)
                let r = records[n]
                return [r.x, r.y, r.z, r.w, going[n]]
            }
            let observedLibrary = try ShaderLibrary.make(device: device, firstPhasePressure: true)
            capture = FirstPhasePressureCapture(
                slots: slots, output: output,
                pipeline: try ShaderLibrary.pipeline("sampleFirstPhasePressure", in: observedLibrary),
                seeds: seeds, initialTime: time, maxSamples: maxPressureSamples)
        }
        recorder.pressureCapture = capture
        recorder.diagnosticIndices = indices
        recorder.diagnosticSamples.removeAll(keepingCapacity: true)
    }

    public func firstPhaseDiagnosticSamples() -> [FirstPhaseDiagnosticSample] {
        precondition(!batchInFlight, "Wait for the batch before reading diagnostics")
        return firstPhaseColumns?.diagnosticSamples ?? []
    }

    /// Explicit diagnostic readback of complete coarse fluid and first-phase buffers; no GPU pass.
    /// Excludes refinement/structural state. Ordinary runs never call this or allocate hash storage.
    public func firstPhaseDiagnosticStateHashes() -> [String: String] {
        precondition(!batchInFlight, "Wait for the batch before hashing diagnostic state")
        var buffers = [
            "state": stateBuffers[current], "peak": peakBuffer,
            "impulse": impulseBuffer, "mask": maskBuffer,
        ]
        if hasSpecies { buffers["species"] = speciesBuffers[current] }
        if let recorder = firstPhaseColumns {
            buffers["firstPhaseColumns"] = recorder.columns
            buffers["firstPhaseRecords"] = recorder.records
            buffers["firstPhaseOpen"] = recorder.open
        }
        return buffers.mapValues { buffer in
            var hash = SHA256()
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length))
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    public func firstPhasePressureTrace() throws -> FirstPhasePressureTrace {
        precondition(!batchInFlight, "Wait for the batch before reading pressure diagnostics")
        guard let recorder = firstPhaseColumns, let capture = recorder.pressureCapture else {
            throw BlastError.allocationFailed("pressure capture was not configured")
        }
        guard !capture.overflow, !capture.samples.isEmpty else {
            throw BlastError.allocationFailed("a complete pressure trace within its sample budget")
        }
        return FirstPhasePressureTrace(
            columns: recorder.diagnosticIndices,
            seedRecords: capture.seeds, samples: capture.samples)
    }

    /// Called only after a command buffer completed; a logical batch may still be in flight.
    func collectFirstPhaseDiagnostics() {
        guard let recorder = firstPhaseColumns, !recorder.diagnosticIndices.isEmpty else { return }
        let control = controlBuffer.contents().load(as: StepControl.self)
        guard control.dt > 0 else { return }
        let step = stepCount + Int(control.activeSteps)
        guard recorder.diagnosticSamples.last?.step != step else { return }
        if let capture = recorder.pressureCapture {
            if capture.samples.count >= capture.maxSamples {
                capture.overflow = true
                return
            }
            let output = capture.output.contents().bindMemory(
                to: Float.self,
                capacity: recorder.diagnosticIndices.count * 16)
            func values(_ offset: Int) -> [[Float]] {
                recorder.diagnosticIndices.indices.map { q in
                    Array(UnsafeBufferPointer(start: output + q * 16 + offset, count: 8))
                }
            }
            if capture.samples.isEmpty {
                capture.samples.append(
                    FirstPhasePressureSample(step: 0, time: capture.initialTime, values: values(0)))
            }
            if capture.samples.count >= capture.maxSamples {
                capture.overflow = true
                return
            }
            capture.samples.append(
                FirstPhasePressureSample(
                    step: step, time: Double(control.clock) / 1_099_511_627_776, values: values(8)))
        }
        let records = recorder.records.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: recorder.layers * recorder.nx * recorder.ny)
        let open = recorder.open.contents().bindMemory(
            to: Float.self, capacity: recorder.layers * recorder.nx * recorder.ny)
        let columns = recorder.columns.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: recorder.layers * recorder.nx * recorder.ny)
        let peak = peakBuffer.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        let impulse = impulseBuffer.contents().bindMemory(to: Float.self, capacity: grid.cellCount)
        let plan = recorder.nx * recorder.ny
        let values = recorder.diagnosticIndices.map { n -> [Float] in
            let c = columns[n]
            let lo = n % plan + plan * Int(c.x)
            let hi = n % plan + plan * Int(c.y)
            let r = records[n]
            return [
                r.x, r.y, r.z, r.w, open[n],
                (1 - c.z) * peak[lo] + c.z * peak[hi],
                (1 - c.z) * impulse[lo] + c.z * impulse[hi], control.dt,
            ]
        }
        recorder.diagnosticSamples.append(
            FirstPhaseDiagnosticSample(
                step: step, time: Double(control.clock) / 1_099_511_627_776,
                dt: control.dt, values: values))
    }

    func encodeFirstPhase(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let recorder = firstPhaseColumns else { return }
        var uniforms = makeUniforms()
        var parameters = SIMD4<UInt32>(UInt32(recorder.nx), UInt32(recorder.ny), initial ? 1 : 0, 0)
        encoder.setComputePipelineState(recorder.pressureCapture?.pipeline ?? recorder.pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(controlBuffer, offset: 0, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
        encoder.setBytes(&parameters, length: 16, index: 6)
        let plan = recorder.nx * recorder.ny
        for layer in 0..<recorder.layers {
            if let capture = recorder.pressureCapture {
                encoder.setBuffer(capture.slots, offset: layer * plan * MemoryLayout<UInt32>.stride, index: 7)
                encoder.setBuffer(capture.output, offset: 0, index: 8)
            }
            encoder.setBuffer(
                recorder.columns, offset: layer * plan * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setBuffer(
                recorder.records, offset: layer * plan * MemoryLayout<SIMD4<Float>>.stride, index: 3)
            encoder.setBuffer(recorder.open, offset: layer * plan * MemoryLayout<Float>.stride, index: 4)
            encoder.dispatchThreads(
                MTLSize(width: recorder.nx, height: recorder.ny, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        }
    }
}
