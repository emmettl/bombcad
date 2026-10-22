import BlastModel
import Foundation
import Metal

/// Raw Float32 words read from the same two cells as the native pressure recorder.
/// Per receiver: column (4), native interpolation weights (2), low Cell (5), high Cell (5).
public struct FirstPhaseInputSample: Sendable {
    public let step: Int
    public let time: Double
    public let values: [[Float]]
}

public struct FirstPhaseInputTrace: Sendable {
    public let columns: [Int]
    public let samples: [FirstPhaseInputSample]
}

/// Separate library: adding this observer never changes the producer's compilation unit.
final class FirstPhaseInputCapture {
    let output: MTLBuffer
    let pipeline: MTLComputePipelineState
    var samples: [FirstPhaseInputSample] = []

    init(device: MTLDevice, count: Int) throws {
        guard MemoryLayout<CellState>.stride == 5 * MemoryLayout<Float>.stride else {
            throw BlastError.allocationFailed("five-word Cell layout for raw pressure inputs")
        }
        guard
            let output = device.makeBuffer(
                length: count * 32 * MemoryLayout<Float>.stride, options: .storageModeShared)
        else { throw BlastError.allocationFailed("raw pressure inputs") }
        self.output = output
        memset(output.contents(), 0, output.length)
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void pressureInputs(
                const device uint *state [[buffer(0)]],
                const device float *control [[buffer(1)]],
                const device float4 *columns [[buffer(2)]],
                const device uint *slots [[buffer(3)]],
                device uint *output [[buffer(4)]],
                constant uint4 &p [[buffer(5)]],
                uint2 tid [[thread_position_in_grid]]) {
                if (tid.x >= p.x || tid.y >= p.y || (p.z == 0 && control[0] <= 0)) return;
                uint plane = p.x * p.y;
                uint n = tid.x + p.x * tid.y;
                for (uint layer = 0; layer < p.w; ++layer) {
                    uint slot = slots[n + layer * plane];
                    if (slot == 0) continue;
                    float4 c = columns[n + layer * plane];
                    uint o = (slot - 1) * 32 + (p.z != 0 ? 0 : 16);
                    uint4 words = as_type<uint4>(c);
                    output[o] = words.x; output[o+1] = words.y;
                    output[o+2] = words.z; output[o+3] = words.w;
                    output[o+4] = as_type<uint>(1.0f - c.z);
                    output[o+5] = words.z;
                    for (uint side = 0; side < 2; ++side) {
                        uint k = uint(side == 0 ? c.x : c.y);
                        uint base = 5 * (n + plane * k);
                        for (uint v = 0; v < 5; ++v)
                            output[o + 6 + side * 5 + v] = state[base + v];
                    }
                }
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        pipeline = try ShaderLibrary.pipeline("pressureInputs", in: library)
    }

    func encode(
        _ encoder: MTLComputeCommandEncoder, state: MTLBuffer, control: MTLBuffer,
        columns: MTLBuffer, slots: MTLBuffer, nx: Int, ny: Int, layers: Int, initial: Bool
    ) {
        var parameters = SIMD4<UInt32>(UInt32(nx), UInt32(ny), initial ? 1 : 0, UInt32(layers))
        encoder.setComputePipelineState(pipeline)
        for (index, buffer) in [state, control, columns, slots, output].enumerated() {
            encoder.setBuffer(buffer, offset: 0, index: index)
        }
        encoder.setBytes(&parameters, length: 16, index: 5)
        encoder.dispatchThreads(
            MTLSize(width: nx, height: ny, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
    }

    func collect(count: Int, initial: Bool, step: Int, time: Double, initialTime: Double) {
        let words = output.contents().bindMemory(to: Float.self, capacity: count * 32)
        func values(_ offset: Int) -> [[Float]] {
            (0..<count).map { q in
                Array(UnsafeBufferPointer(start: words + q * 32 + offset, count: 16))
            }
        }
        if initial {
            samples.append(FirstPhaseInputSample(step: 0, time: initialTime, values: values(0)))
        }
        samples.append(FirstPhaseInputSample(step: step, time: time, values: values(16)))
    }
}

extension BlastSolver {
    /// Independent host readback for checking raw trace endpoints. No GPU work or pressure calculation.
    public func firstPhaseInputStateSnapshot() throws -> [[Float]] {
        precondition(!batchInFlight, "Wait for the batch before reading input state")
        guard let recorder = firstPhaseColumns, recorder.pressureCapture?.inputs != nil else {
            throw BlastError.allocationFailed("raw input capture was not configured")
        }
        let plane = recorder.nx * recorder.ny
        let columns = recorder.columns.contents().bindMemory(
            to: SIMD4<Float>.self, capacity: plane * recorder.layers)
        let buffer = stateBuffers[current]
        let words = buffer.contents().bindMemory(to: Float.self, capacity: buffer.length / 4)
        return recorder.diagnosticIndices.map { n in
            let c = columns[n]
            var row = [c.x, c.y, c.z, c.w, 1 - c.z, c.z]
            for k in [Int(c.x), Int(c.y)] {
                let start = 5 * (n % plane + plane * k)
                row += Array(UnsafeBufferPointer(start: words + start, count: 5))
            }
            return row
        }
    }

    /// Refuses an incomplete or overflowed paired pressure/input trace.
    public func firstPhaseInputTrace() throws -> FirstPhaseInputTrace {
        let pressure = try firstPhasePressureTrace()
        guard let inputs = firstPhaseColumns?.pressureCapture?.inputs,
            inputs.samples.count == pressure.samples.count
        else { throw BlastError.allocationFailed("a complete raw pressure-input trace") }
        return FirstPhaseInputTrace(columns: pressure.columns, samples: inputs.samples)
    }
}
