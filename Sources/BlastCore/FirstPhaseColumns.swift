import BlastModel
import Foundation
import Metal
import RadialBlast
import simd

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
final class FirstPhaseColumns {
    let nx: Int
    let ny: Int
    /// Per column: `k0`, `k1`, the share of `k1`, and 1 to record (0 for none).
    let columns: MTLBuffer
    /// Per column: the peak, the impulse of every positive phase, the first phase's impulse and
    /// that phase's peak so far.
    let records: MTLBuffer
    /// Per column: 1 while the first phase is still going.
    let open: MTLBuffer
    let pipeline: MTLComputePipelineState

    init(device: MTLDevice, library: MTLLibrary, grid: Grid, columns cells: [SIMD4<Float>]) throws {
        nx = grid.nx
        ny = grid.ny
        let count = nx * ny
        guard cells.count == count,
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

    var memoryFootprint: Int { columns.length + records.length + open.length }

    func reset() {
        memset(records.contents(), 0, records.length)
        memset(open.contents(), 0, open.length)
    }

    /// The peak and impulse `blast`, a one-dimensional solution about `centre`, left at the columns'
    /// points within `radius` of it, before the grid takes over: the first phase still going.
    func seed(_ blast: SphericalBlast, centre: SIMD3<Float>, radius: Float, cellSize: Float) {
        let cells = columns.contents().bindMemory(to: SIMD4<Float>.self, capacity: nx * ny)
        let record = records.contents().bindMemory(to: SIMD4<Float>.self, capacity: nx * ny)
        let going = open.contents().bindMemory(to: Float.self, capacity: nx * ny)
        for j in 0..<ny {
            for i in 0..<nx {
                let n = i + nx * j
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

    /// The records, x-fast: the peak (Pa), every positive phase's impulse and the first phase's
    /// (Pa s), and the first phase's peak; zero where a column records nothing.
    func snapshot() -> [SIMD4<Float>] {
        let record = records.contents().bindMemory(to: SIMD4<Float>.self, capacity: nx * ny)
        return Array(UnsafeBufferPointer(start: record, count: nx * ny))
    }
}

extension BlastSolver {
    /// Records the first positive phase's impulse over each plan cell (`FirstPhaseColumns`) as the
    /// run goes, before stepping. `columns`, x-fast over the plan, gives each column's two cells,
    /// the share of the second and 1 to record it (0 for none). Does not change the air solution.
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

    /// Each plan cell's record, x-fast (`FirstPhaseColumns.snapshot`); nil unless configured.
    public func firstPhaseSnapshot() -> [SIMD4<Float>]? {
        precondition(!batchInFlight, "Cannot read the columns while a batch is in flight")
        return firstPhaseColumns?.snapshot()
    }

    func encodeFirstPhase(_ encoder: MTLComputeCommandEncoder, initial: Bool) {
        guard let recorder = firstPhaseColumns else { return }
        var uniforms = makeUniforms()
        var parameters = SIMD4<UInt32>(UInt32(recorder.nx), UInt32(recorder.ny), initial ? 1 : 0, 0)
        encoder.setComputePipelineState(recorder.pipeline)
        encoder.setBuffer(stateBuffers[current], offset: 0, index: 0)
        encoder.setBuffer(controlBuffer, offset: 0, index: 1)
        encoder.setBuffer(recorder.columns, offset: 0, index: 2)
        encoder.setBuffer(recorder.records, offset: 0, index: 3)
        encoder.setBuffer(recorder.open, offset: 0, index: 4)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 5)
        encoder.setBytes(&parameters, length: 16, index: 6)
        encoder.dispatchThreads(
            MTLSize(width: recorder.nx, height: recorder.ny, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }
}
