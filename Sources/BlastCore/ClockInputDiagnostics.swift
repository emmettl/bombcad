import BlastModel
import Foundation
import Metal

/// Raw words immediately around the native prepare dispatch, including inactive iterations.
/// Record: speed before (2), tile count/dispatch before (4), control before, uniforms,
/// control after, speed after (2), tile count/dispatch after (4), markers (2).
public struct ClockInputTrace: Sendable {
    public let words: [UInt32]
    public let recordWords: Int
    public let controlWords: Int
    public let uniformWords: Int
    public let encodedSteps: [Int]
    public let batchBaseSteps: [Int]
}

/// Separate copy-only library; slots 24–30 preserve every native prepare binding (0–17).
final class ClockInputCapture {
    let output: MTLBuffer
    let pipeline: MTLComputePipelineState
    let controlWords = MemoryLayout<StepControl>.stride / 4
    let uniformWords = MemoryLayout<SolverUniforms>.stride / 4
    let maxSamples: Int
    var encodedSteps: [Int] = []
    var batchBaseSteps: [Int] = []
    var overflowed = false
    var recordWords: Int { 14 + 2 * controlWords + uniformWords }

    init(device: MTLDevice, maxSamples: Int) throws {
        guard (2...32768).contains(maxSamples), MemoryLayout<StepControl>.stride.isMultiple(of: 4),
            MemoryLayout<SolverUniforms>.stride.isMultiple(of: 4)
        else { throw BlastError.allocationFailed("clock trace: 2–32768 samples and word layouts") }
        self.maxSamples = maxSamples
        let bytes = maxSamples * (14 + 2 * controlWords + uniformWords) * 4
        guard bytes <= 32 * 1024 * 1024,
            let buffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        else { throw BlastError.allocationFailed("clock trace within 32 MiB") }
        output = buffer
        memset(output.contents(), 0, output.length)
        let source = """
            #include <metal_stdlib>
            using namespace metal;
            kernel void copyClockInputs(
                const device uint *tileCount [[buffer(24)]],
                constant uint4 &p [[buffer(25)]],
                const device uint *control [[buffer(26)]],
                const device uint *speed [[buffer(27)]],
                constant uint *uniforms [[buffer(28)]],
                device uint *output [[buffer(29)]],
                const device uint *tileDispatch [[buffer(30)]],
                uint tid [[thread_position_in_grid]]) {
                if (tid != 0) return;
                uint width = 14 + 2*p.y + p.z;
                uint o = p.x * width;
                if (p.w == 0) {
                    output[o] = speed[0]; output[o+1] = speed[1];
                    output[o+2] = tileCount[0];
                    for (uint i=0; i<3; ++i) output[o+3+i] = tileDispatch[i];
                    for (uint i=0; i<p.y; ++i) output[o+6+i] = control[i];
                    for (uint i=0; i<p.z; ++i) output[o+6+p.y+i] = uniforms[i];
                    output[o+width-2] = 0x43505245u;
                } else {
                    for (uint i=0; i<p.y; ++i) output[o+6+p.y+p.z+i] = control[i];
                    output[o+6+2*p.y+p.z] = speed[0];
                    output[o+7+2*p.y+p.z] = speed[1];
                    output[o+8+2*p.y+p.z] = tileCount[0];
                    for (uint i=0; i<3; ++i) output[o+9+2*p.y+p.z+i] = tileDispatch[i];
                    output[o+width-1] = 0x43504F53u;
                }
            }
            """
        let library = try device.makeLibrary(source: source, options: nil)
        pipeline = try ShaderLibrary.pipeline("copyClockInputs", in: library)
    }

    private func encode(
        _ encoder: MTLComputeCommandEncoder, control: MTLBuffer, speed: MTLBuffer,
        tileCount: MTLBuffer, tileDispatch: MTLBuffer, uniforms: inout SolverUniforms,
        slot: Int, after: Bool
    ) {
        var p = SIMD4<UInt32>(UInt32(slot), UInt32(controlWords), UInt32(uniformWords), after ? 1 : 0)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(tileCount, offset: 0, index: 24)
        encoder.setBytes(&p, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 25)
        encoder.setBuffer(control, offset: 0, index: 26)
        encoder.setBuffer(speed, offset: 0, index: 27)
        encoder.setBytes(&uniforms, length: MemoryLayout<SolverUniforms>.stride, index: 28)
        encoder.setBuffer(output, offset: 0, index: 29)
        encoder.setBuffer(tileDispatch, offset: 0, index: 30)
        encoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
    }

    func begin(
        _ encoder: MTLComputeCommandEncoder, control: MTLBuffer, speed: MTLBuffer,
        tileCount: MTLBuffer, tileDispatch: MTLBuffer, uniforms: inout SolverUniforms,
        encodedStep: Int, batchBaseStep: Int
    ) -> Int? {
        guard encodedSteps.count < maxSamples else {
            overflowed = true
            return nil
        }
        let slot = encodedSteps.count
        encodedSteps.append(encodedStep)
        batchBaseSteps.append(batchBaseStep)
        encode(
            encoder, control: control, speed: speed, tileCount: tileCount, tileDispatch: tileDispatch,
            uniforms: &uniforms, slot: slot, after: false)
        return slot
    }

    func end(
        _ encoder: MTLComputeCommandEncoder, control: MTLBuffer, speed: MTLBuffer,
        tileCount: MTLBuffer, tileDispatch: MTLBuffer, uniforms: inout SolverUniforms, slot: Int
    ) {
        encode(
            encoder, control: control, speed: speed, tileCount: tileCount, tileDispatch: tileDispatch,
            uniforms: &uniforms, slot: slot, after: true)
    }
}

extension BlastSolver {
    /// Copy-only diagnostics. Configure before stepping; no producer compilation or batch change.
    /// Overflow is retained and makes readback refuse an incomplete trace.
    public func configureClockInputDiagnostics(maxSamples: Int = 32768) throws {
        guard !batchInFlight && stepCount == 0 else {
            throw BlastError.allocationFailed("configure clock diagnostics before stepping")
        }
        clockInputCapture = try ClockInputCapture(device: device, maxSamples: maxSamples)
    }

    public func clockInputTrace() throws -> ClockInputTrace {
        guard !batchInFlight, let capture = clockInputCapture, !capture.overflowed,
            !capture.encodedSteps.isEmpty
        else {
            throw BlastError.allocationFailed("a complete configured clock input trace")
        }
        let count = capture.encodedSteps.count
        let words = Array(
            UnsafeBufferPointer(
                start: capture.output.contents().bindMemory(
                    to: UInt32.self, capacity: count * capture.recordWords),
                count: count * capture.recordWords))
        guard
            (0..<count).allSatisfy({
                words[($0 + 1) * capture.recordWords - 2] == 0x4350_5245
                    && words[($0 + 1) * capture.recordWords - 1] == 0x4350_4F53
            })
        else { throw BlastError.allocationFailed("both clock capture dispatches must complete") }
        return ClockInputTrace(
            words: words, recordWords: capture.recordWords, controlWords: capture.controlWords,
            uniformWords: capture.uniformWords, encodedSteps: capture.encodedSteps,
            batchBaseSteps: capture.batchBaseSteps)
    }
}
